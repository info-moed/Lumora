import Foundation

/// Repairs a damaged source into a NEW file (the original is never modified): a lossless remux rebuilds a missing or
/// damaged container index and the timestamps; damaged groups of pictures are re-encoded at high quality one by one,
/// with pictures that can't be decoded rebuilt by repeating the previous good frame; everything else is copied as is.
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
        var rebuiltFrames: [Range<Int>] = []      // repeated from the previous frame
        var reencoded: [Range<Int>] = []          // decoded with concealment and re-encoded
        var fps: Double
        var notes: [String] = []
        var decodeErrorsAfter = 0

        var summary: String {
            var parts = ["Repaired copy saved: “\(output.lastPathComponent)”."]
            for r in rebuiltFrames {
                parts.append("\(r.count) frame\(r.count == 1 ? "" : "s") rebuilt at \(FailureText.time(Double(r.lowerBound) / fps, precise: true))–\(FailureText.time(Double(r.upperBound - 1) / fps, precise: true)) (repeated from the previous frame).")
            }
            for r in reencoded {
                parts.append("\(r.count) frames re-encoded at high quality (\(FailureText.time(Double(r.lowerBound) / fps, precise: true))–\(FailureText.time(Double(r.upperBound) / fps, precise: true))).")
            }
            if methods.contains(.remux) { parts.append("The file structure was rebuilt without re-encoding; \(framesAfter) frames are readable.") }
            if methods.contains(.timestamps) { parts.append("The timestamps were rebuilt from the order of the pictures.") }
            if !reencoded.isEmpty || !rebuiltFrames.isEmpty { parts.append("All other frames are untouched.") }
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

    // MARK: c) Re-encode only the damaged groups of pictures

    static func reencodeDamaged(_ source: URL, to dest: URL, fps: Double, work: URL, framesBefore: Int,
                                progress: @escaping (Double, String) -> Void) throws -> Report {
        let probe = SourceIntegrity.Probe.run(source)
        let (num, den) = rationalFrameRate(fps)
        // Split at keyframes (Matroska: MPEG-TS's Annex-B filter rejects corrupt packets).
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let segDir = work.appendingPathComponent("gops", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-fflags", "+genpts", "-i", source.path, "-map", "0:v:0", "-c", "copy",
                                       "-f", "segment", "-segment_format", "matroska", "-segment_time", "0.001", "-reset_timestamps", "1",
                                       "-break_non_keyframes", "0", segDir.appendingPathComponent("g%05d.mkv").path])
        let gops = ((try? FileManager.default.contentsOfDirectory(at: segDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mkv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !gops.isEmpty else { throw CannotRepair(reason: "Lumora couldn't split “\(source.lastPathComponent)” into readable parts.") }
        // Expected frames per GOP from the source's own packet timing: each GOP holds the frames from its first
        // timestamp up to the next GOP's (so a lost frame is counted and rebuilt).
        let starts = gops.map { firstTime($0) }
        let firstGOPTime = keyframeTimes(source).first ?? 0
        let keyTimes = keyframeTimes(source)
        let totalSeconds = probe.duration ?? Double(framesBefore) / fps
        var list: [String] = []
        var report = Report(output: dest, methods: [.reencodeDamaged], framesBefore: framesBefore, framesAfter: 0, fps: fps)
        var frameCursor = 0
        for (i, g) in gops.enumerated() {
            progress(0.1 + 0.8 * Double(i) / Double(gops.count), "Checking part \(i + 1) of \(gops.count)")
            let startT = i < keyTimes.count ? keyTimes[i] - firstGOPTime : starts[i]
            let endT = i + 1 < keyTimes.count ? keyTimes[i + 1] - firstGOPTime : totalSeconds
            let expected = max(1, Int(((endT - startT) * fps).rounded()))
            let errors = decodeErrorCount(g)
            let decoded = countFrames(g)
            if errors == 0 && decoded == expected {
                list.append(FFConcat.line(g))
                frameCursor += expected
                continue
            }
            // Re-encode this GOP: decoder's best effort, missing pictures held from the previous one, exact frame count.
            let fixed = work.appendingPathComponent(String(format: "fix%05d.mkv", i))
            let enc = encoderArgs(codec: probe.codec ?? "h264", source: source)
            try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-err_detect", "ignore_err", "-i", g.path,
                                           "-vf", "fps=\(num)/\(den),tpad=stop_mode=clone:stop=\(expected)",
                                           "-frames:v", "\(expected)", "-an"] + enc + [fixed.path])
            list.append(FFConcat.line(fixed))
            let r = frameCursor..<(frameCursor + expected)
            if decoded < expected { report.rebuiltFrames.append((frameCursor + decoded)..<(frameCursor + expected)) }
            report.reencoded.append(r)
            RenderLog.current?.info("Part \(i + 1): \(decoded) of \(expected) frames decodable, \(errors) decoder messages → re-encoded", tag: "repair")
            frameCursor += expected
        }
        let listURL = work.appendingPathComponent("list.txt")
        try list.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
        progress(0.92, "Joining")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listURL.path,
                                       "-fflags", "+discardcorrupt", "-err_detect", "ignore_err", "-i", source.path,
                                       "-map", "0:v:0", "-map", "1:a?", "-c", "copy", dest.path])
        report.framesAfter = countFrames(dest)
        report.decodeErrorsAfter = decodeErrorCount(dest)
        if probe.codec == "hevc", SourceStreams.probe(source).subtitles.isEmpty == false {
            report.notes.append("Subtitles were not copied.")
        }
        progress(1, "Done")
        return report
    }

    /// The same codec family at very high quality, parameter sets in every keyframe.
    static func encoderArgs(codec: String, source: URL) -> [String] {
        switch codec {
        case "hevc":
            return ["-c:v", "libx265", "-crf", "12", "-pix_fmt", "yuv420p10le", "-x265-params", "repeat-headers=1:bframes=0:log-level=error"]
        case "prores":
            return ["-c:v", "prores_ks", "-profile:v", "3"]
        case "av1":
            return ["-c:v", "libsvtav1", "-crf", "12"]
        default:
            // No B-frames: the rebuilt part's timestamps then join the copied parts exactly.
            return ["-c:v", "libx264", "-crf", "10", "-preset", "medium", "-bf", "0", "-pix_fmt", "yuv420p", "-x264-params", "repeat-headers=1"]
        }
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
