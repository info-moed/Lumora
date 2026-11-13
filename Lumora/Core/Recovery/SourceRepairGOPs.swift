import Foundation

/// Re-encoding only the damaged groups of pictures (GOPs) of a source, and proving the result before it is offered.
///
/// Measured during the design (FFmpeg 9, 4 s clips, 24-frame GOPs, 4000 bytes overwritten in one GOP):
/// - Joining stream-copied GOPs to a re-encoded one in Matroska breaks HEVC: the copied GOPs carry no parameter sets
///   of their own, so after the re-encoded part the decoder applies the new encoder's to them (garbage at 10 dB, or
///   46 undecodable frames from a VideoToolbox source). Every part is therefore joined as MPEG-TS, where each keyframe
///   carries its own parameter sets, and the re-encoded part keeps the source's pixel format.
/// - The concat demuxer places each part after the previous one's duration; a B-frame part's container start is its
///   reorder delay, which pushed every later frame 2 frames late. Each part gets its real duration from the source's
///   keyframe times.
/// - The decoder's concealed pictures decode "without errors" afterwards but are visibly broken, and so is every frame
///   that refers to them. A damaged GOP keeps only the frames before its first damaged picture (found by decoding
///   ever longer prefixes of its packets); the rest are rebuilt from the last good frame, at their real place.
/// - After the join, the copy is decoded once more: the frame count, every timestamp and every frame outside the
///   re-encoded parts must match the source exactly, or no repaired copy is saved.
extension SourceRepair {

    /// One decoded file: frame hashes and presentation times (seconds), and the decoder's error lines.
    struct Decoded {
        var hashes: [String] = []
        var times: [Double] = []
        var errors = 0
        var count: Int { hashes.count }
    }

    /// Decodes every picture once (framemd5), counting the decoder's complaints.
    static func decode(_ url: URL, work: URL) -> Decoded {
        let md5 = work.appendingPathComponent("frames-\(UUID().uuidString.prefix(8)).md5")
        defer { try? FileManager.default.removeItem(at: md5) }
        let err = (try? ToolLocator.runCapturingStderr("ffmpeg", ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:v:0",
                                                                  "-fps_mode", "passthrough", "-f", "framemd5", "-y", md5.path])) ?? ""
        var d = Decoded()
        d.errors = RenderLog.splitLines(err).count
        guard let text = try? String(contentsOf: md5, encoding: .utf8) else { return d }
        var tb = 1.0 / 1000
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#tb 0:") {
                let r = line.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/").compactMap { Double($0) }
                if r.count == 2, r[1] > 0 { tb = r[0] / r[1] }
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 6, f[0] == "0", let pts = Double(f[2]) else { continue }
            d.times.append(pts * tb)
            d.hashes.append(f[5])
        }
        return d
    }

    /// The video stream's pixel format and reorder depth (B-frames), and its color tags.
    struct StreamInfo {
        var pixFmt: String?
        var reorder = 0
        var color: [String] = []

        static func of(_ url: URL) -> StreamInfo {
            var s = StreamInfo()
            guard let out = try? ToolLocator.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                            "stream=pix_fmt,has_b_frames,color_primaries,color_transfer,color_space,color_range",
                                                            "-of", "default=nw=1", url.path]) else { return s }
            for l in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2, kv[1] != "unknown", kv[1] != "N/A", !kv[1].isEmpty else { continue }
                switch kv[0] {
                case "pix_fmt": s.pixFmt = kv[1]
                case "has_b_frames": s.reorder = Int(kv[1]) ?? 0
                case "color_primaries": s.color += ["-color_primaries", kv[1]]
                case "color_transfer": s.color += ["-color_trc", kv[1]]
                case "color_space": s.color += ["-colorspace", kv[1]]
                case "color_range": s.color += ["-color_range", kv[1]]
                default: break
                }
            }
            return s
        }
    }

    /// The same codec family at very high quality, the source's pixel format and color tags, no B-frames, parameter
    /// sets in every keyframe.
    static func encoderArgs(codec: String, stream: StreamInfo) -> [String] {
        func pix(_ allowed: [String], _ fallback: String) -> [String] {
            ["-pix_fmt", stream.pixFmt.flatMap { allowed.contains($0) ? $0 : nil } ?? fallback]
        }
        let depths = ["", "10le", "12le"]
        let x265 = ["yuv420p", "yuv422p", "yuv444p"].flatMap { b in depths.map { b + $0 } } + ["gray", "gray10le", "gray12le"]
        let x264 = ["yuv420p", "yuv422p", "yuv444p", "yuv420p10le", "yuv422p10le", "yuv444p10le", "nv12", "gray"]
        switch codec {
        case "hevc":
            return ["-c:v", "libx265", "-crf", "12"] + pix(x265, "yuv420p10le")
                + ["-x265-params", "repeat-headers=1:bframes=0:open-gop=0:log-level=error"] + stream.color
        case "prores":
            return ["-c:v", "prores_ks", "-profile:v", "3"] + stream.color
        case "av1":
            return ["-c:v", "libsvtav1", "-crf", "12"] + stream.color
        default:
            return ["-c:v", "libx264", "-crf", "10", "-preset", "medium", "-bf", "0"] + pix(x264, "yuv420p")
                + ["-x264-params", "repeat-headers=1"] + stream.color
        }
    }

    /// One part of the repaired copy, in order.
    private struct Part {
        var url: URL
        var start: Double          // source time of its first frame, relative to the first keyframe
        var duration: Double
        var frames: Int
        var copied: Decoded?       // a stream-copied GOP: how it decodes on its own (must not change in the join)
    }

    static func reencodeDamaged(_ source: URL, to dest: URL, fps: Double, work: URL, framesBefore: Int,
                                progress: @escaping (Double, String) -> Void) throws -> Report {
        let probe = SourceIntegrity.Probe.run(source)
        let codec = probe.codec ?? "h264"
        let stream = StreamInfo.of(source)
        let (num, den) = rationalFrameRate(fps)
        let rate = "\(num)/\(den)"
        // H.264 and HEVC parts are joined as MPEG-TS (parameter sets at every keyframe); others as Matroska.
        let ts = ["h264", "hevc"].contains(codec)
        let partExt = ts ? "ts" : "mkv"
        let partFormat = ts ? ["-f", "mpegts"] : ["-f", "matroska"]
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
        // Expected frames per GOP from the source's own keyframe times: each GOP holds the frames from its keyframe up
        // to the next one (so a lost frame is counted and rebuilt).
        let keyTimes = keyframeTimes(source)
        let firstGOPTime = keyTimes.first ?? 0
        let totalSeconds = probe.duration ?? Double(framesBefore) / fps
        var report = Report(output: dest, methods: [.reencodeDamaged], framesBefore: framesBefore, framesAfter: 0, fps: fps)
        var parts: [Part] = []
        var frameCursor = 0
        let log = RenderLog.current
        for (i, g) in gops.enumerated() {
            progress(0.1 + 0.75 * Double(i) / Double(gops.count), "Checking part \(i + 1) of \(gops.count)")
            let startT = i < keyTimes.count ? keyTimes[i] - firstGOPTime : (parts.last.map { $0.start + $0.duration } ?? 0)
            // The last GOP ends with its own last picture (the container's duration can include longer audio).
            let lastSpan = i + 1 < keyTimes.count ? nil : packetTimes(g).minMax.map { $0.max - $0.min + 1 / fps }
            let endT = i + 1 < keyTimes.count ? keyTimes[i + 1] - firstGOPTime
                : startT + (lastSpan ?? max(1 / fps, totalSeconds - firstGOPTime - startT))
            let expected = max(1, Int(((endT - startT) * fps).rounded()))
            let d = decode(g, work: work)
            let partURL = work.appendingPathComponent(String(format: "part%05d.%@", i, partExt))
            if d.errors == 0 && d.count == expected {
                try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", g.path, "-map", "0:v:0", "-c", "copy"] + partFormat + [partURL.path])
                parts.append(Part(url: partURL, start: startT, duration: endT - startT, frames: expected, copied: d))
                frameCursor += expected
                continue
            }
            // A damaged GOP: keep the frames before its first damaged picture, rebuild the rest from the last good frame.
            let (intact, prefix) = intactFrames(g, decoded: d, expected: expected, fps: fps, reorder: stream.reorder, work: work)
            let enc = encoderArgs(codec: codec, stream: stream) + ["-an"] + partFormat + [partURL.path]
            if intact > 0 {
                // Decoded from the packets before the damage only (every intact frame comes from them), so the
                // decoder never sees the damaged data and can't reorder or conceal anything.
                var input = g
                if let k = prefix {
                    input = work.appendingPathComponent(String(format: "intact%05d.mkv", i))
                    try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", g.path, "-map", "0:v:0", "-c", "copy", "-frames:v", "\(k)", input.path])
                }
                let cut = gopStart(g) + (Double(intact) - 0.5) / fps
                let vf = "select='lt(t\\,\(String(format: "%.6f", cut)))',setpts=N/(\(rate))/TB,tpad=stop_mode=clone:stop=\(expected - intact)"
                try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", input.path, "-map", "0:v:0",
                                               "-vf", vf, "-frames:v", "\(expected)", "-fps_mode", "passthrough"] + enc)
                if intact < expected { report.rebuiltFrames.append((frameCursor + intact)..<(frameCursor + expected)) }
            } else {
                // The keyframe itself is damaged: nothing in this GOP can be trusted. Hold the previous part's last frame,
                // or at the very start the next GOP's first one.
                let filler = work.appendingPathComponent(String(format: "filler%05d.mkv", i))
                if let prev = parts.last {
                    try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", prev.url.path, "-map", "0:v:0",
                                                   "-vf", "select='eq(n\\,\(prev.frames - 1))'", "-frames:v", "1", "-c:v", "ffv1", filler.path])
                    report.rebuiltFrames.append(frameCursor..<(frameCursor + expected))
                } else if i + 1 < gops.count, decodeErrorCount(gops[i + 1]) == 0 {
                    try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", gops[i + 1].path, "-map", "0:v:0",
                                                   "-frames:v", "1", "-c:v", "ffv1", filler.path])
                    report.heldFromNext.append(frameCursor..<(frameCursor + expected))
                }
                guard FileManager.default.fileExists(atPath: filler.path) else {
                    throw CannotRepair(reason: "The beginning of “\(source.lastPathComponent)” is too damaged: no good frame is left to rebuild it from.")
                }
                try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", filler.path, "-map", "0:v:0",
                                               "-vf", "loop=loop=-1:size=1,setpts=N/(\(rate))/TB", "-frames:v", "\(expected)",
                                               "-fps_mode", "passthrough"] + enc)
            }
            parts.append(Part(url: partURL, start: startT, duration: endT - startT, frames: expected, copied: nil))
            report.reencoded.append(frameCursor..<(frameCursor + expected))
            log?.info("Part \(i + 1): \(d.count) of \(expected) frames decodable, \(d.errors) decoder messages; the first \(intact) are intact → re-encoded, \(expected - intact) rebuilt", tag: "repair")
            frameCursor += expected
        }
        // Join: each part placed at its real duration (B-frame reorder delays don't add up), audio from the source.
        var list: [String] = []
        for (k, p) in parts.enumerated() {
            let shift = k == 0 ? (FaultInjection.repairPartShift ?? 0) : 0       // tests: a part placed wrongly
            list += [FFConcat.line(p.url), "duration \(String(format: "%.6f", p.duration + shift))"]
        }
        let listURL = work.appendingPathComponent("list.txt")
        try list.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
        progress(0.88, "Joining")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listURL.path,
                                       "-fflags", "+discardcorrupt", "-err_detect", "ignore_err", "-i", source.path,
                                       "-map", "0:v:0", "-map", "1:a?", "-c", "copy", dest.path])
        progress(0.94, "Checking the repaired copy")
        let out = decode(dest, work: work)
        report.framesAfter = out.count
        report.decodeErrorsAfter = out.errors
        if let problem = verify(out, parts: parts, fps: fps) {
            log?.error("Repaired copy rejected: \(problem)", tag: "repair")
            try? FileManager.default.removeItem(at: dest)
            throw CannotRepair(reason: "Lumora rebuilt the damaged part of “\(source.lastPathComponent)”, but the repaired copy didn't come out right (\(problem)), so it wasn't saved. Your original is unchanged. You can still export it as it is: Lumora rebuilds the damaged frames during the export.")
        }
        if !SourceStreams.probe(source).subtitles.isEmpty { report.notes.append("Subtitles were not copied.") }
        log?.info("Repaired copy checked: \(out.count) frames, every timestamp and every untouched frame as in the source", tag: "repair")
        progress(1, "Done")
        return report
    }

    /// The first presentation time in a GOP file.
    private static func gopStart(_ g: URL) -> Double { packetTimes(g).min() ?? 0 }

    /// The GOP's packets' presentation times, in decode order.
    static func packetTimes(_ url: URL) -> [Double] {
        guard let out = try? ToolLocator.run("ffprobe", ["-v", "quiet", "-select_streams", "v:0", "-show_entries", "packet=pts_time",
                                                        "-of", "csv=p=0", url.path]) else { return [] }
        return String(decoding: out, as: UTF8.self).split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
    }

    /// How many frames at the start of a damaged GOP can be trusted: those before its first damaged picture, before
    /// a lost one, and before one the decoder didn't output. Pictures after a damaged one refer to it (directly or
    /// through others), so they can't be trusted either; with B-frames, the `reorder` pictures before it in display
    /// order can refer to it too.
    /// Returns the count and, when a damaged packet was found, how many packets (in decode order) come before it.
    static func intactFrames(_ g: URL, decoded d: Decoded, expected: Int, fps: Double, reorder: Int, work: URL) -> (Int, Int?) {
        let pkts = packetTimes(g)
        guard let start = pkts.min() else { return (0, nil) }
        let half = 0.5 / fps
        var t0 = Double.infinity
        var prefix: Int?
        if d.errors > 0, let first = firstDamagedPacket(g, packets: pkts.count, work: work), first < pkts.count {
            t0 = min(t0, pkts[first...].min() ?? start)
            prefix = first
        }
        let decodedTimes = d.times.sorted()
        for k in 0..<expected {
            let t = start + Double(k) / fps
            if !pkts.contains(where: { abs($0 - t) < half }) {
                // A lost picture: the B-frames shown just before it can refer to it as well.
                t0 = min(t0, t - Double(reorder) / fps); break
            }
            if !decodedTimes.contains(where: { abs($0 - t) < half }) { t0 = min(t0, t); break }
        }
        guard t0.isFinite else { return (expected, nil) }
        let n = (0..<expected).first { start + Double($0) / fps >= t0 - 1e-6 } ?? expected
        // The prefix holds every intact frame only when the damage is what limits them.
        return (n, prefix.flatMap { p in n > 0 && t0 >= (pkts[p...].min() ?? start) - 1e-6 ? p : nil })
    }

    /// The decode-order index of the first packet whose decoding reports an error: ever longer prefixes of the GOP are
    /// decoded (binary search, a few small decodes).
    static func firstDamagedPacket(_ g: URL, packets n: Int, work: URL) -> Int? {
        guard n > 0 else { return nil }
        let pre = work.appendingPathComponent("prefix.mkv")
        defer { try? FileManager.default.removeItem(at: pre) }
        func errors(_ k: Int) -> Int {
            guard (try? ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", g.path, "-map", "0:v:0", "-c", "copy",
                                                   "-frames:v", "\(k)", pre.path])) != nil else { return 1 }
            return decodeErrorCount(pre)
        }
        guard errors(n) > 0 else { return nil }
        var lo = 1, hi = n           // errors(hi) > 0; find the smallest such prefix
        while lo < hi {
            let mid = (lo + hi) / 2
            if errors(mid) > 0 { hi = mid } else { lo = mid + 1 }
        }
        return lo - 1
    }

    /// The joined copy against what each part promised: nil when it is right, otherwise what is wrong, in words.
    private static func verify(_ out: Decoded, parts: [Part], fps: Double) -> String? {
        let total = parts.reduce(0) { $0 + $1.frames }
        if out.errors > 0 { return "\(out.errors) decoding error\(out.errors == 1 ? "" : "s") remain" }
        if out.count != total { return "it has \(out.count) frames instead of \(total)" }
        let outTimes = out.times.sorted()
        guard let t0 = outTimes.first else { return "it has no frames" }
        let tolerance = min(0.25 / fps, 0.003)
        var k = 0
        for p in parts {
            let own = p.copied?.times.sorted() ?? []
            for j in 0..<p.frames {
                let want = j < own.count ? p.start + (own[j] - own[0]) : p.start + Double(j) / fps
                let got = outTimes[k] - t0
                if abs(got - want) > tolerance {
                    return "frame \(k) is at \(FailureText.time(got, precise: true)) instead of \(FailureText.time(want, precise: true))"
                }
                if let c = p.copied, j < c.hashes.count, c.hashes[j] != out.hashes[k] {
                    return "frame \(k) at \(FailureText.time(want, precise: true)) changed although it wasn't damaged"
                }
                k += 1
            }
        }
        return nil
    }
}

private extension Array where Element == Double {
    var minMax: (min: Double, max: Double)? { guard let a = self.min(), let b = self.max() else { return nil }; return (a, b) }
}
