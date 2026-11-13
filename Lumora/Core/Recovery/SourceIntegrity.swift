import Foundation
import AVFoundation

/// One thing wrong with a source file, explained in plain words.
struct SourceProblem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case empty, indexMissing, truncated, damaged, brokenTimestamps, mislabeled, unsupported }
    var id: String { kind.rawValue + "\(seconds ?? -1)" }
    var kind: Kind
    var seconds: Double? = nil          // where it starts
    var claimedSeconds: Double? = nil
    var detail: String = ""

    var blocking: Bool { [.empty, .indexMissing, .unsupported].contains(kind) }
    var repairable: Bool { [.truncated, .damaged, .brokenTimestamps].contains(kind) }

    func summary(_ name: String) -> String {
        switch kind {
        case .empty: return "The file is empty."
        case .indexMissing: return "Incomplete: the index is missing, so no frames can be read."
        case .truncated:
            return "Cut short: stops at \(FailureText.time(seconds ?? 0, precise: true))" + (claimedSeconds.map { " of \(FailureText.time($0, precise: true))" } ?? "")
        case .damaged: return detail.isEmpty ? "Damaged frames near \(FailureText.time(seconds ?? 0, precise: true))" : detail
        case .brokenTimestamps: return "Broken timestamps near \(FailureText.time(seconds ?? 0, precise: true)): frames may play at the wrong time."
        case .mislabeled: return "Named .\(URL(fileURLWithPath: name).pathExtension) but it is really \(detail). Lumora reads it anyway."
        case .unsupported: return "Uses \(detail), which this Mac can't decode."
        }
    }

    /// A paragraph for the repair sheet: what is wrong and what a repair can and can't do.
    func explanation(_ name: String) -> String {
        switch kind {
        case .empty: return "“\(name)” has no data at all. It can't be repaired; find another copy."
        case .indexMissing:
            return "The end of “\(name)” is missing, including the index that tells players where every frame is. This happens when a recording or a copy is interrupted. The index can't be rebuilt from this file alone: find the original on the camera card or another complete copy. A recovery tool that uses a working clip from the same camera and settings as a pattern may be able to rescue it."
        case .truncated:
            return "“\(name)” says it is \(FailureText.time(claimedSeconds ?? 0)) long, but the video stops at \(FailureText.time(seconds ?? 0)). The rest of the file is missing and can't be recovered from it. A repaired copy keeps everything that's there."
        case .damaged:
            return "Some frames of “\(name)” can't be read correctly\(seconds.map { " (from \(FailureText.time($0, precise: true)))" } ?? ""). A repaired copy re-encodes only the damaged parts at high quality and rebuilds frames that can't be decoded; every other frame stays untouched."
        case .brokenTimestamps:
            return "The timing information in “\(name)” jumps\(seconds.map { " near \(FailureText.time($0, precise: true))" } ?? ""), so players may skip or stall. A repaired copy rebuilds the timing from the order of the pictures, without re-encoding anything."
        case .mislabeled: return "The file name says one format but the content is another. This is harmless; Lumora reads it anyway."
        case .unsupported: return "“\(name)” uses \(detail), which this Mac can't decode. Converting it with another app first may help."
        }
    }
}

/// The result of checking a source.
struct SourceHealth: Codable, Hashable {
    var problems: [SourceProblem] = []
    var damage: DamageMap?
    var checkedSeconds: Double = 0
    var full = false

    var ok: Bool { problems.allSatisfy { $0.kind == .mislabeled } }
    var repairable: Bool { problems.contains { $0.repairable } }
    func summary(_ name: String) -> String {
        let real = problems.filter { $0.kind != .mislabeled }
        guard let first = real.first else { return full ? "Full check: OK" : "File check: OK" }
        return first.summary(name) + (real.count > 1 ? " (+\(real.count - 1) more)" : "")
    }
}

enum SourceIntegrity {
    // MARK: Quick check (well under a second for intact files)

    static func quickCheck(_ url: URL) async -> SourceHealth {
        let t0 = Date()
        var h = SourceHealth()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return h }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size == 0 { h.problems.append(SourceProblem(kind: .empty)); return h }
        let format = sniff(url)
        let ext = url.pathExtension.lowercased()
        if let f = format, !f.extensions.contains(ext), !ext.isEmpty {
            h.problems.append(SourceProblem(kind: .mislabeled, detail: f.name))
        }
        let probe = Probe.run(url)
        if format?.isMP4 == true {
            let atoms = topLevelAtoms(url, size: size)
            if atoms.hasMdat && !atoms.hasMoov {
                h.problems.append(SourceProblem(kind: .indexMissing, detail: "no moov atom"))
                h.checkedSeconds = Date().timeIntervalSince(t0)
                return h
            }
            if let t = await lastCompleteSampleTime(url, fileSize: size), let claimed = probe.duration, claimed - t > 0.25 {
                h.problems.append(SourceProblem(kind: .truncated, seconds: t, claimedSeconds: claimed,
                                                detail: "the video data ends at \(FailureText.time(t, precise: true))"))
            }
        }
        if !h.problems.contains(where: { $0.kind == .truncated }), let claimed = probe.duration,
           let last = probe.lastPacketTime(url, claimed: claimed) {
            let frame = 1 / max(1, probe.fps)
            if claimed - last.time > max(0.5, 3 * frame) || last.corrupt || last.endedPrematurely {
                h.problems.append(SourceProblem(kind: .truncated, seconds: last.time, claimedSeconds: claimed,
                                                detail: last.endedPrematurely ? "the file ended prematurely" : "the last packet is at \(FailureText.time(last.time, precise: true))"))
            }
        }
        if let jump = probe.timestampJump(url) {
            h.problems.append(SourceProblem(kind: .brokenTimestamps, seconds: jump, detail: ""))
        }
        if probe.codec == nil && format != nil {
            h.problems.append(SourceProblem(kind: .unsupported, detail: "a video format FFmpeg doesn't recognize"))
        }
        // Three quick 1-second decodes (start, middle, end).
        if let d = probe.duration, d > 0, ToolLocator.isAvailable("ffmpeg"), !h.problems.contains(where: { $0.blocking }) {
            // A file that is cut short fails to decode at its end; that is the truncation, not extra damage.
            let cut = h.problems.first { $0.kind == .truncated }?.seconds
            let end = cut ?? d
            for t in [0, max(0, end / 2 - 0.5), max(0, end - 1.2)] where t + 1 <= (cut == nil ? end + 0.01 : end - 1) {
                let errs = decodeErrors(url, from: t, seconds: 1)
                if !errs.isEmpty {
                    h.problems.append(SourceProblem(kind: .damaged, seconds: t, detail: "Damaged frames near \(FailureText.time(t, precise: true))"))
                    break
                }
            }
        }
        h.checkedSeconds = Date().timeIntervalSince(t0)
        return h
    }

    // MARK: Full scan: every frame

    /// Decodes every frame with FFmpeg (one thread, so messages line up with frames) and maps the damage to frames.
    static func fullScan(_ url: URL, fps hint: Double? = nil) -> SourceHealth {
        let t0 = Date()
        var h = SourceHealth()
        h.full = true
        let probe = Probe.run(url)
        let fps = hint ?? probe.fps
        var map = DamageMap()
        map.fps = fps
        map.claimedSeconds = probe.duration
        guard ToolLocator.isAvailable("ffmpeg") else { return h }
        let text = (try? ToolLocator.runCapturingStderr("ffmpeg", ["-hide_banner", "-nostdin", "-v", "info", "-threads", "1",
                                                                 "-i", url.path, "-map", "0:v:0", "-vf", "showinfo=checksum=0",
                                                                 "-f", "null", "-"])) ?? ""
        var lastTime: Double?
        var firstTime: Double?
        var pendingError: String?
        var frames = 0
        for line in RenderLog.splitLines(text) {
            if line.contains("Parsed_showinfo"), let r = line.range(of: "pts_time:") {
                let rest = line[r.upperBound...]
                guard let t = Double(rest.prefix { !$0.isWhitespace }) else { continue }
                if firstTime == nil { firstTime = t }
                let idx = Int(((t - (firstTime ?? 0)) * fps).rounded())
                if let lt = lastTime {
                    let gap = Int(((t - lt) * fps).rounded()) - 1
                    if gap > 0 {
                        let start = Int(((lt - (firstTime ?? 0)) * fps).rounded()) + 1
                        map.add(.init(start: start, count: gap, kind: .missing, note: "can't be decoded"))
                    }
                }
                if let e = pendingError {
                    map.add(.init(start: idx, count: 1, kind: .concealed, note: e))
                    pendingError = nil
                }
                lastTime = t
                frames += 1
            } else if isDecoderError(line) {
                map.decoderMessages.append(line)
                if map.decoderMessages.count > 200 { map.decoderMessages.removeFirst() }
                pendingError = line
            } else if line.contains("moov atom not found") {
                h.problems.append(SourceProblem(kind: .indexMissing, detail: "moov atom not found"))
            }
        }
        if let lt = lastTime, let claimed = probe.duration, claimed - lt > max(0.5, 3 / max(1, fps)) {
            map.truncatedAtSeconds = lt + 1 / max(1, fps)
            h.problems.append(SourceProblem(kind: .truncated, seconds: map.truncatedAtSeconds, claimedSeconds: claimed))
        }
        if let first = map.places.first {
            let n = map.damagedFrames
            h.problems.append(SourceProblem(kind: .damaged, seconds: map.seconds(first.start),
                                            detail: "Damaged: \(n) frame\(n == 1 ? "" : "s") at \(FailureText.time(map.seconds(first.start), precise: true))"
                                                + (map.places.count > 1 ? ", and \(map.places.count - 1) more place\(map.places.count == 2 ? "" : "s")" : "")))
        }
        if let jump = probe.timestampJump(url) { h.problems.append(SourceProblem(kind: .brokenTimestamps, seconds: jump)) }
        h.damage = map
        h.checkedSeconds = Date().timeIntervalSince(t0)
        RenderLog.current?.info("Full source check: \(frames) frames decoded, \(map.damagedFrames) damaged, \(map.decoderMessages.count) decoder messages", tag: "source")
        return h
    }

    static func isDecoderError(_ l: String) -> Bool {
        let s = l.lowercased()
        return s.contains("error while decoding") || s.contains("concealing") || s.contains("invalid nal unit size")
            || s.contains("missing picture in access unit") || s.contains("partial file") || s.contains("invalid data found")
            || s.contains("corrupt") || s.contains("ended prematurely") || s.contains("invalid obu") || s.contains("decode_slice")
    }

    static func decodeErrors(_ url: URL, from t: Double, seconds: Double) -> [String] {
        let text = (try? ToolLocator.runCapturingStderr("ffmpeg", ["-hide_banner", "-nostdin", "-v", "error", "-threads", "1", "-ss", String(format: "%.3f", t),
                                                                 "-i", url.path, "-t", String(format: "%.3f", seconds),
                                                                 "-map", "0:v:0", "-f", "null", "-"])) ?? ""
        return RenderLog.splitLines(text).filter(isDecoderError)
    }

    // MARK: Container facts

    struct Format { var name: String; var extensions: [String]; var isMP4: Bool }

    static func sniff(_ url: URL) -> Format? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 400)) ?? Data())
        guard b.count >= 12 else { return nil }
        if ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(String(decoding: b[4..<8], as: UTF8.self)) {
            return Format(name: "an MP4 or QuickTime movie", extensions: ["mp4", "mov", "m4v", "3gp", "mp4v"], isMP4: true)
        }
        if Array(b[0..<4]) == [0x1A, 0x45, 0xDF, 0xA3] { return Format(name: "a Matroska file", extensions: ["mkv", "webm", "mk3d"], isMP4: false) }
        if b[0] == 0x47, b.count > 376, b[188] == 0x47, b[376] == 0x47 {
            return Format(name: "an MPEG transport stream", extensions: ["ts", "m2ts", "mts"], isMP4: false)
        }
        if Array(b[0..<4]) == Array("RIFF".utf8) { return Format(name: "an AVI file", extensions: ["avi"], isMP4: false) }
        if Array(b[0..<4]) == Array("DKIF".utf8) { return Format(name: "an IVF stream", extensions: ["ivf"], isMP4: false) }
        return nil
    }

    struct Atoms { var hasFtyp = false; var hasMoov = false; var hasMdat = false; var overrun: String? }

    /// Walks the top-level boxes of an MP4/MOV (sizes and types only; reads a few bytes per box).
    static func topLevelAtoms(_ url: URL, size: Int64) -> Atoms {
        var a = Atoms()
        guard let h = try? FileHandle(forReadingFrom: url) else { return a }
        defer { try? h.close() }
        var offset: Int64 = 0
        var guardCount = 0
        while offset + 8 <= size, guardCount < 10_000 {
            guardCount += 1
            try? h.seek(toOffset: UInt64(offset))
            guard let hdr = try? h.read(upToCount: 16), hdr.count >= 8 else { break }
            let b = [UInt8](hdr)
            var boxSize = Int64(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if boxSize == 1, b.count >= 16 {
                boxSize = b[8..<16].reduce(Int64(0)) { $0 << 8 | Int64($1) }
            } else if boxSize == 0 {
                boxSize = size - offset
            }
            switch type {
            case "ftyp": a.hasFtyp = true
            case "moov": a.hasMoov = true
            case "mdat": a.hasMdat = true
            default: break
            }
            guard boxSize >= 8 else { break }
            if offset + boxSize > size { a.overrun = type; break }
            offset += boxSize
        }
        return a
    }

    /// The presentation time of the last video sample whose bytes are all inside the file (AVSampleCursor), or nil when
    /// the last sample is complete.
    static func lastCompleteSampleTime(_ url: URL, fileSize: Int64) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, track.canProvideSampleCursors,
              let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { return nil }
        func endOf(_ c: AVSampleCursor) -> Int64 {
            let r = c.currentSampleStorageRange
            return r.offset + r.length
        }
        guard endOf(cursor) > fileSize else { return nil }
        var steps = 0
        while endOf(cursor) > fileSize, steps < 200_000 {
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
            steps += 1
        }
        return cursor.presentationTimeStamp.seconds + (cursor.currentSampleDuration.seconds.isFinite ? cursor.currentSampleDuration.seconds : 0)
    }

    // MARK: ffprobe facts

    struct Probe {
        var duration: Double?
        var fps: Double = 24
        var codec: String?
        var cfr = true

        static func run(_ url: URL) -> Probe {
            var p = Probe()
            guard let out = try? ToolLocator.run("ffprobe", ["-v", "error", "-select_streams", "v:0",
                                                            "-show_entries", "format=duration:stream=codec_name,r_frame_rate,avg_frame_rate,duration",
                                                            "-of", "default=nw=1", url.path]) else { return p }
            var kv: [String: String] = [:]
            for l in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let parts = l.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, kv[parts[0]] == nil || parts[0] == "duration" && kv["duration"] == "N/A" { kv[parts[0]] = parts[1] }
            }
            func rate(_ s: String?) -> Double? {
                guard let s else { return nil }
                let a = s.split(separator: "/").compactMap { Double($0) }
                return a.count == 2 && a[1] > 0 ? a[0] / a[1] : Double(s)
            }
            p.codec = kv["codec_name"]
            if let r = rate(kv["r_frame_rate"]), r > 0, r.isFinite { p.fps = r }
            if let a = rate(kv["avg_frame_rate"]), a > 0 { p.cfr = abs(a - p.fps) < 0.01 }
            p.duration = kv["duration"].flatMap(Double.init)
            return p
        }

        struct Last { var time: Double; var corrupt: Bool; var endedPrematurely: Bool }

        /// Reads only the last few seconds' packets.
        func lastPacketTime(_ url: URL, claimed: Double) -> Last? {
            let start = max(0, claimed - 5)
            guard let exe = ToolLocator.url(for: "ffprobe") else { return nil }
            let p = Process()
            p.executableURL = exe
            p.arguments = FFHarden.args("ffprobe", ["-v", "error", "-select_streams", "v:0", "-read_intervals", String(format: "%.3f%%", start),
                                                    "-show_entries", "packet=pts_time,dts_time,flags", "-of", "csv=p=0", url.path])
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            let done = p.exitSignal()
            guard (try? p.run()) != nil else { return nil }
            var errData = Data()
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            g.wait(); done.wait()
            var best: Double?
            var corrupt = false
            for l in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let f = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard let t = Double(f.first ?? "") ?? Double(f.count > 1 ? f[1] : "") else { continue }
                best = max(best ?? t, t)
                if f.last?.contains("C") == true { corrupt = true }
            }
            let errText = String(decoding: errData, as: UTF8.self)
            guard let best else { return nil }
            return Last(time: best + 1 / max(1, fps), corrupt: corrupt || errText.contains("partial file"),
                        endedPrematurely: errText.contains("ended prematurely"))
        }

        /// The first place where packet decode timestamps go backwards or jump by more than two frames, sampled at the
        /// start, middle and end of the file.
        func timestampJump(_ url: URL) -> Double? {
            guard let d = duration, d > 0 else { return nil }
            // Three 10-second windows (start, middle, end): packet headers only, so this stays fast on long files.
            for t in Array(Set([0, max(0, d / 2 - 5), max(0, d - 10)])).sorted() {
                guard let out = try? ToolLocator.run("ffprobe", ["-v", "quiet", "-select_streams", "v:0",
                                                                "-read_intervals", String(format: "%.3f%%+10", t),
                                                                "-show_entries", "packet=pts_time,dts_time", "-of", "csv=p=0", url.path]) else { continue }
                // Decode times when the container has them (MP4); Matroska keeps only presentation times, which are
                // in display order, so those are sorted first (a jump is still a gap; a step back can't be told).
                let rows = String(decoding: out, as: UTF8.self).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) } }
                let dts = rows.compactMap { $0.count > 1 ? $0[1] : nil }
                let times = dts.count >= max(2, rows.count - 1) ? dts : rows.compactMap { $0.first ?? nil }.sorted()
                for (a, b) in zip(times, times.dropFirst()) where b < a - 1e-6 || b - a > 2.5 / max(1, fps) {
                    return a
                }
            }
            return nil
        }
    }
}
