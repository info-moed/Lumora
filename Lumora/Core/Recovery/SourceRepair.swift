import Foundation

/// Repairs a damaged source into a NEW file (the original is never modified): a lossless remux rebuilds a missing or
/// damaged container index and the timestamps; damaged groups of pictures are re-encoded at high quality one by one,
/// with the damaged pictures (and the ones that depend on them) rebuilt by repeating the last good frame; everything
/// else is copied as is, and checked to decode exactly as before (see SourceRepairGOPs.swift).
enum SourceRepair {
    enum Method: String, Codable {
        case remux = "Rebuilt the file structure without re-encoding"
        case timestamps = "Rebuilt the timestamps from the order of the pictures"
        case reencodeDamaged = "Re-encoded only the damaged parts"
    }

    struct Report: Codable, Hashable {
        var output: URL
        var methods: [Method]
        var framesBefore: Int
        var framesAfter: Int
        var rebuiltFrames: [Range<Int>] = []      // replaced by the last good frame before them
        var heldFromNext: [Range<Int>] = []       // replaced by the next good frame (damage at the very start)
        var reencoded: [Range<Int>] = []          // the good frames of a damaged part, re-encoded with the rebuilt ones
        var fps: Double
        var notes: [String] = []
        var decodeErrorsAfter = 0

        var summary: String {
            var parts = ["Repaired copy saved: “\(output.lastPathComponent)”."]
            func span(_ r: Range<Int>) -> String {
                let a = FailureText.time(Double(r.lowerBound) / fps, precise: true), b = FailureText.time(Double(r.upperBound - 1) / fps, precise: true)
                return "\(r.count) frame\(r.count == 1 ? "" : "s") at \(a == b ? a : "\(a)–\(b)")"
            }
            for r in rebuiltFrames {
                parts.append("\(span(r).prefix(1).uppercased() + span(r).dropFirst()) couldn't be decoded correctly and now repeat the last good frame before them.")
            }
            for r in heldFromNext {
                parts.append("\(span(r).prefix(1).uppercased() + span(r).dropFirst()) couldn't be decoded correctly and now repeat the next good frame.")
            }
            if !rebuiltFrames.isEmpty || !heldFromNext.isEmpty {
                parts.append("Frames that depend on a damaged picture are rebuilt too, because they would show its damage.")
            }
            for r in reencoded {
                parts.append("The part from \(FailureText.time(Double(r.lowerBound) / fps, precise: true)) to \(FailureText.time(Double(r.upperBound) / fps, precise: true)) was re-encoded at high quality.")
            }
            if methods.contains(.remux) { parts.append("The file structure was rebuilt without re-encoding; \(framesAfter) frames are readable.") }
            if methods.contains(.timestamps) { parts.append("The timestamps were rebuilt from the order of the pictures.") }
            if !reencoded.isEmpty { parts.append("All other frames are untouched (checked frame by frame).") }
            return (parts + notes).joined(separator: " ")
        }
    }

    struct CannotRepair: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// Where the repaired copy goes: next to the source if that folder is writable, otherwise the fallback folder.
    static func destination(for source: URL, fallback: URL?) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let folder = FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path)
            ? source.deletingLastPathComponent() : (fallback ?? FileManager.default.temporaryDirectory)
        var u = folder.appendingPathComponent("\(base) (repaired).mkv")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = folder.appendingPathComponent("\(base) (repaired \(n)).mkv"); n += 1 }
        return u
    }

    /// Chooses the method from the source's health and runs it.
    static func repair(_ source: URL, health: SourceHealth, to out: URL? = nil, fallbackFolder: URL? = nil,
                       progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> Report {
        let name = source.lastPathComponent
        if let p = health.problems.first(where: { $0.blocking }) {
            throw CannotRepair(reason: p.explanation(name))
        }
        guard ToolLocator.isAvailable("ffmpeg") else { throw LumoraError.missingTool("ffmpeg") }
        let dest = out ?? destination(for: source, fallback: fallbackFolder)
        let work = try ScratchManager.jobDirectory("repair-source")
        defer { try? FileManager.default.removeItem(at: work) }
        let probe = SourceIntegrity.Probe.run(source)
        let fps = probe.fps
        let before = countFrames(source)
        RenderLog.current?.info("Repairing \(name): \(health.problems.map(\.kind.rawValue).joined(separator: ", "))", tag: "repair")
        let damaged = health.problems.contains(where: { $0.kind == .damaged }) || (health.damage.map { !$0.spans.isEmpty } ?? false)
        if health.problems.contains(where: { $0.kind == .truncated }) {
            // Cut short: rebuild the file structure first (keeps every frame that is there); if what is there still
            // has damaged pictures, re-encode only those parts of the rebuilt copy.
            progress(0.1, "Rebuilding the file structure")
            let remuxed = work.appendingPathComponent("remuxed.mkv")
            var r = try remux(source, to: remuxed, fps: fps, framesBefore: before)
            if r.decodeErrorsAfter > 0 {
                progress(0.4, "Finding the damaged parts")
                var d = try reencodeDamaged(remuxed, to: dest, fps: fps, work: work.appendingPathComponent("fix", isDirectory: true),
                                            framesBefore: before, progress: progress)
                d.methods = [.remux, .reencodeDamaged]
                return d
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: remuxed, to: dest)
            r.output = dest
            return r
        }
        if damaged {
            progress(0.05, "Finding the damaged parts")
            return try reencodeDamaged(source, to: dest, fps: fps, work: work, framesBefore: before, progress: progress)
        }
        if health.problems.contains(where: { $0.kind == .brokenTimestamps }) {
            progress(0.1, "Rebuilding the timestamps")
            return try rebuildTimestamps(source, to: dest, fps: fps, work: work, framesBefore: before)
        }
        progress(0.1, "Rebuilding the file structure")
        return try remux(source, to: dest, fps: fps, framesBefore: before)
    }

    // MARK: a) Lossless remux

    static func remux(_ source: URL, to dest: URL, fps: Double, framesBefore: Int) throws -> Report {
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-fflags", "+genpts+discardcorrupt", "-err_detect", "ignore_err",
                                       "-i", source.path, "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-c", "copy",
                                       "-ignore_unknown", dest.path])
        let after = countFrames(dest)
        guard after > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw CannotRepair(reason: "No readable frames could be recovered from “\(source.lastPathComponent)”.")
        }
        var r = Report(output: dest, methods: [.remux], framesBefore: framesBefore, framesAfter: after, fps: fps)
        r.decodeErrorsAfter = decodeErrorCount(dest)
        return r
    }

    // MARK: b) Timestamps

    static func rebuildTimestamps(_ source: URL, to dest: URL, fps: Double, work: URL, framesBefore: Int) throws -> Report {
        let codec = SourceIntegrity.Probe.run(source).codec ?? "h264"
        guard ["h264", "hevc"].contains(codec), ToolLocator.isAvailable("MP4Box") else {
            return try remux(source, to: dest, fps: fps, framesBefore: framesBefore)
        }
        let es = work.appendingPathComponent(codec == "hevc" ? "video.hevc" : "video.h264")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", source.path, "-map", "0:v:0", "-c:v", "copy",
                                       "-bsf:v", codec == "hevc" ? "hevc_mp4toannexb" : "h264_mp4toannexb", "-f", codec, es.path])
        let (num, den) = rationalFrameRate(fps)
        try ToolLocator.run("MP4Box", ["-quiet", "-add", "\(es.lastPathComponent):fps=\(num)/\(den)", "-new", "video.mp4"], in: work)
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", work.appendingPathComponent("video.mp4").path,
                                       "-fflags", "+discardcorrupt", "-i", source.path,
                                       "-map", "0:v:0", "-map", "1:a?", "-c", "copy", dest.path])
        var r = Report(output: dest, methods: [.timestamps], framesBefore: framesBefore, framesAfter: countFrames(dest), fps: fps)
        r.decodeErrorsAfter = decodeErrorCount(dest)
        return r
    }

    // MARK: Measuring

    static func countFrames(_ url: URL) -> Int {
        guard let out = try? ToolLocator.run("ffprobe", ["-v", "quiet", "-select_streams", "v:0", "-count_frames",
                                                        "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", url.path]) else { return 0 }
        return Int(String(decoding: out, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))) ?? 0
    }

    static func decodeErrorCount(_ url: URL) -> Int {
        let text = (try? ToolLocator.runCapturingStderr("ffmpeg", ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:v:0", "-f", "null", "-"])) ?? ""
        return RenderLog.splitLines(text).count
    }

    static func firstTime(_ url: URL) -> Double {
        guard let out = try? ToolLocator.run("ffprobe", ["-v", "quiet", "-select_streams", "v:0", "-read_intervals", "%+#1",
                                                        "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path]) else { return 0 }
        return Double(String(decoding: out, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: ", \n"))) ?? 0
    }

    /// Presentation times of the source's keyframe packets, in order.
    static func keyframeTimes(_ url: URL) -> [Double] {
        guard let out = try? ToolLocator.run("ffprobe", ["-v", "quiet", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags",
                                                        "-of", "csv=p=0", url.path]) else { return [] }
        return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { l -> Double? in
            let f = l.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 2, f[1].contains("K") else { return nil }
            return Double(f[0])
        }.sorted()
    }
}
