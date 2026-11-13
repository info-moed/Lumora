import Foundation
import AVFoundation
import CoreMedia

/// Reads what the player needs to know about a file, fast: no frames are analyzed (SourceInspector.inspect runs
/// GPU signal probes and FFmpeg's idet, which take seconds; opening a file to watch it must not).
/// Blocking: call it off the main thread.
enum MediaProbe {
    /// Extensions of raw elementary streams: no container, no timestamps, no index.
    static let rawStreamExtensions: Set<String> = ["266", "vvc", "h266", "265", "hevc", "h265", "264", "h264", "avc", "obu", "av1"]
    static let probeTimeout: TimeInterval = 10

    static func probe(_ url: URL, caps: DecoderCapabilities = .current, fpsOverride: (Int, Int)? = nil) throws -> MediaInfo {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw PlayerError.notAFile }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw PlayerError.damaged("the file is empty.") }
        let ext = url.pathExtension.lowercased()
        var info = MediaInfo(url: url, container: ext)
        info.fileSize = size
        info.isRawElementaryStream = rawStreamExtensions.contains(ext)

        if let av2 = try sniffAV2(url, ext: ext, caps: caps) {
            info = try probeAV2(url, base: info, kind: av2, caps: caps)
        } else {
            if info.isAVFContainer { probeAVFoundation(url, into: &info) }
            if caps.hasFFprobe {
                do { try probeFFprobe(url, into: &info) } catch let e as PlayerError {
                    if !info.avfDecodable { throw e }
                } catch {
                    if !info.avfDecodable { throw PlayerError.damaged(error.localizedDescription) }
                }
            } else if !info.avfDecodable {
                throw PlayerError.missingTool("ffprobe", PlayerError.ffmpegHint)
            }
        }
        guard info.video.width > 0, info.video.height > 0 else { throw PlayerError.noVideoTrack }
        guard (16...16384).contains(info.video.width), (16...16384).contains(info.video.height) else {
            throw PlayerError.tooLarge(info.video.width, info.video.height)
        }
        applyManifest(&info)
        if let (n, d) = fpsOverride, n > 0, d > 0 { info.rateNum = n; info.rateDen = d; info.frameRateKnown = true }
        if !info.frameRateKnown {
            info.notes.append("The stream carries no frame rate; playing at \(formatRate(info.fps)) fps. Pick the right rate in the controls.")
        }
        info.video.color.resolve(height: info.video.height, chroma: info.video.chroma)
        if info.duration <= 0 || !info.duration.isFinite, let n = info.frameCount { info.duration = Double(n) / info.fps }
        if info.duration > 864_000 { info.duration = 864_000 }         // a container claiming years of video
        addNotes(&info)
        return info
    }

    static func formatRate(_ f: Double) -> String {
        f == f.rounded() ? String(Int(f)) : String(format: "%.3f", f)
    }

    // MARK: AV2

    enum AV2Kind { case obu, ivf, matroska }

    /// AV2 can't be read by FFmpeg yet, so it is recognized from its own bytes.
    static func sniffAV2(_ url: URL, ext: String, caps: DecoderCapabilities) throws -> AV2Kind? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw PlayerError.notAFile }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 65536)) ?? Data()
        if head.count >= 32, head.prefix(4) == Data("DKIF".utf8) {
            let fourcc = String(decoding: head[8..<12], as: UTF8.self)
            if fourcc == "AV02" || fourcc == "av02" { return .ivf }
            return nil
        }
        if head.count >= 4, head.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) {
            return head.range(of: Data("V_AV2".utf8)) != nil ? .matroska : nil
        }
        if ext == "obu" {
            // An AV1 .obu is FFmpeg's; only a stream ffprobe can't read and AV2Stream can is AV2.
            if caps.hasFFprobe, (try? ToolLocator.run("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path],
                                                   timeout: probeTimeout)).map({ !$0.isEmpty }) == true {
                return nil
            }
            if (try? AV2Stream.summary(of: head.count < 65536 ? head : try Data(contentsOf: url, options: .mappedIfSafe))) != nil { return .obu }
        }
        return nil
    }

    static func probeAV2(_ url: URL, base: MediaInfo, kind: AV2Kind, caps: DecoderCapabilities) throws -> MediaInfo {
        var info = base
        info.container = kind == .obu ? "AV2 OBU stream" : kind == .ivf ? "IVF" : "Matroska / WebM"
        info.isRawElementaryStream = kind == .obu
        info.video.codec = .av2
        info.video.fourCC = "av02"
        var units = 0
        var raps: [Int] = [0]
        info.frameRateKnown = false
        info.rateNum = 24; info.rateDen = 1
        switch kind {
        case .obu:
            let s: AV2Stream.Summary
            do { s = try AV2Stream.summary(of: url) } catch { throw PlayerError.damaged(error.localizedDescription) }
            units = s.units.count
            raps = s.randomAccessFrames
            applyAV2Color(s, to: &info)
        case .ivf:
            do {
                guard let (s, rate) = try AV2Stream.ivfSummary(of: url) else { throw PlayerError.damaged("not an IVF file.") }
                units = s.units.count
                raps = s.randomAccessFrames
                applyAV2Color(s, to: &info)
                if let (n, d) = rate, n > 0, d > 0, Double(n) / Double(d) >= 1, Double(n) / Double(d) <= 1000 {
                    (info.rateNum, info.rateDen) = rationalFrameRate(Double(n) / Double(d))
                    info.frameRateKnown = true
                }
            } catch let e as PlayerError { throw e } catch { throw PlayerError.damaged(error.localizedDescription) }
        case .matroska:
            // ffprobe reads the Matroska framing (packets, key-frame flags, rate) even though it can't decode AV2.
            if caps.hasFFprobe, let table = try? FrameTable.read(url, timeout: 30), !table.pts.isEmpty {
                units = table.pts.count
                raps = table.keyFrames.isEmpty ? [0] : table.keyFrames
                if let r = table.rate { (info.rateNum, info.rateDen) = r; info.frameRateKnown = true }
            }
        }
        if units > 0 { info.frameCount = units }
        if raps.first != 0 { raps.insert(0, at: 0) }

        // Geometry and bit depth from the decoder itself: one frame as Y4M, and one as raw samples for the sample size.
        guard caps.hasAVMDec else {
            // Without avmdec only the color OBU is known; the selector reports the missing tool.
            info.video.width = 1920; info.video.height = 1080
            info.av2 = AV2Details(temporalUnits: units, randomAccessPoints: raps, sampleBytes: 2)
            return info
        }
        let y4m = try ChildProcess(tool: "avmdec", args: ["--limit=1", "-o", "-", url.path], qos: .userInitiated)
        let head = y4m.readAll(limit: 256 << 20)
        _ = y4m.waitForExit(timeout: 30)
        y4m.terminate()
        guard let nl = head.firstIndex(of: 0x0A), head.starts(with: Data("YUV4MPEG2".utf8)) else {
            throw PlayerError.decoderFailed("avmdec", y4m.stderrTail.isEmpty ? "it couldn't decode the first frame." : y4m.stderrTail)
        }
        let header = String(decoding: head[..<nl], as: UTF8.self)
        guard let y = parseY4MHeader(header) else { throw PlayerError.damaged("avmdec wrote an unreadable frame header.") }
        info.video.width = y.width; info.video.height = y.height
        info.video.bitDepth = y.bits; info.video.chroma = y.chroma
        guard (16...16384).contains(y.width), (16...16384).contains(y.height) else { throw PlayerError.tooLarge(y.width, y.height) }
        // Sample size of avmdec's --rawvideo output (what the player reads): measure one frame of it.
        let samples = y.width * y.height + 2 * planeSamples(y.width, y.height, y.chroma)
        let raw = try ChildProcess(tool: "avmdec", args: ["--rawvideo", "--limit=1", "-o", "-", url.path], qos: .userInitiated)
        let rawBytes = raw.readAll(limit: samples * 2 + 1).count
        raw.terminate()
        let sampleBytes = rawBytes >= samples * 2 ? 2 : 1
        info.av2 = AV2Details(temporalUnits: units, randomAccessPoints: raps, sampleBytes: sampleBytes)
        if !info.frameRateKnown, kind != .obu, let r = y.rate, r.0 > 0, r.1 > 0 {
            let f = Double(r.0) / Double(r.1)
            if f >= 1 && f <= 300 { (info.rateNum, info.rateDen) = rationalFrameRate(f); info.frameRateKnown = true }
        }
        return info
    }

    static func planeSamples(_ w: Int, _ h: Int, _ c: PlayerChroma) -> Int {
        let (sx, sy) = c.subsampling
        return c == .mono ? 0 : ((w + sx - 1) / sx) * ((h + sy - 1) / sy)
    }

    private static func applyAV2Color(_ s: AV2Stream.Summary, to info: inout MediaInfo) {
        if let c = s.color {
            info.video.color.primaries = c.primaries; info.video.color.primariesTagged = true
            info.video.color.transfer = c.transfer; info.video.color.transferTagged = true
            info.video.color.matrix = c.matrix; info.video.color.matrixTagged = true
            info.video.color.fullRange = c.fullRange; info.video.color.rangeTagged = true
        }
        if let csp = s.chromaSamplePosition, let loc = ChromaLocation(rawValue: csp), loc != .unknown {
            info.video.color.chromaLocation = loc
            info.video.color.chromaLocationTagged = true
        }
    }

    struct Y4MHeader { var width: Int; var height: Int; var bits: Int; var chroma: PlayerChroma; var rate: (Int, Int)? }

    static func parseY4MHeader(_ line: String) -> Y4MHeader? {
        var w = 0, h = 0, bits = 8, chroma = PlayerChroma.c420
        var rate: (Int, Int)?
        for t in line.split(separator: " ").dropFirst() {
            let v = t.dropFirst()
            switch t.first {
            case "W": w = Int(v) ?? 0
            case "H": h = Int(v) ?? 0
            case "F":
                let p = v.split(separator: ":").compactMap { Int($0) }
                if p.count == 2 { rate = (p[0], p[1]) }
            case "C":
                let s = String(v)
                chroma = s.hasPrefix("444") ? .c444 : s.hasPrefix("422") ? .c422 : s.hasPrefix("mono") ? .mono : .c420
                if let r = s.range(of: "p") , let b = Int(s[r.upperBound...]) { bits = b }
            default: break
            }
        }
        guard w > 0, h > 0 else { return nil }
        return Y4MHeader(width: w, height: h, bits: bits, chroma: chroma, rate: rate)
    }

    // MARK: AVFoundation

    /// Runs an async AVFoundation load from synchronous code (never call this on the main thread).
    static func blocking<T>(timeout: TimeInterval, _ op: @escaping @Sendable () async throws -> T) -> T? {
        let box = BlockingBox<T>()
        let sem = DispatchSemaphore(value: 0)
        let task = Task.detached { box.value = try? await op(); sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); return nil }
        return box.value
    }

    final class BlockingBox<T>: @unchecked Sendable { var value: T? }

    struct AVFFacts: @unchecked Sendable {
        var decodable = false
        var width = 0, height = 0
        var rate: Float = 0
        var duration: Double = 0
        var format: CMFormatDescription?
        var audioTracks = 0
    }

    static func probeAVFoundation(_ url: URL, into info: inout MediaInfo) {
        let facts = blocking(timeout: probeTimeout) { () async throws -> AVFFacts in
            let asset = AVURLAsset(url: url)
            var f = AVFFacts()
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { return f }
            let (rate, range, fds, decodable) = try await t.load(.nominalFrameRate, .timeRange, .formatDescriptions, .isDecodable)
            f.decodable = decodable
            f.rate = rate
            f.duration = range.duration.seconds
            f.format = fds.first
            if let fd = fds.first {
                let d = CMVideoFormatDescriptionGetDimensions(fd)
                f.width = Int(d.width); f.height = Int(d.height)
            }
            f.audioTracks = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            return f
        }
        guard let facts, let fd = facts.format else { return }
        info.avfDecodable = facts.decodable
        let code = SourceInspector.fourCC(CMFormatDescriptionGetMediaSubType(fd))
        var v = info.video
        v.fourCC = code
        v.codec = PlayerCodec.fourCC(code)
        v.width = facts.width; v.height = facts.height
        let ext = (CMFormatDescriptionGetExtensions(fd) as? [String: Any]) ?? [:]
        if let b = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int, b >= 8, b <= 16 { v.bitDepth = b }
        if code == "ap4h" || code == "ap4x" { v.chroma = .c444; v.bitDepth = max(v.bitDepth, 12) }
        else if code.hasPrefix("apc") { v.chroma = .c422; v.bitDepth = max(v.bitDepth, 10) }
        if let s = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, let n = cicpPrimaries(coreMedia: s) {
            v.color.primaries = n; v.color.primariesTagged = true
        }
        if let s = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String, let n = cicpTransfer(coreMedia: s) {
            v.color.transfer = n; v.color.transferTagged = true
        }
        if let s = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, let n = cicpMatrix(coreMedia: s) {
            v.color.matrix = n; v.color.matrixTagged = true
        }
        if let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
            v.color.fullRange = full; v.color.rangeTagged = true
        }
        if let loc = ext[kCMFormatDescriptionExtension_ChromaLocationTopField as String] as? String {
            let l = ChromaLocation.coreMedia(loc)
            if l != .unknown { v.color.chromaLocation = l; v.color.chromaLocationTagged = true }
        }
        var hdr = HDRStatic()
        if let d = ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data,
           let m = HDRMetadata.parseMasteringDisplay(d) {
            hdr.mdcvMaxNits = m.maxNits; hdr.mdcvMinNits = m.minNits; hdr.mdcvPrimaries = m.primaries
        }
        if let d = ext[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data,
           let c = HDRMetadata.parseContentLightLevel(d) {
            if c.maxCLL > 0 { hdr.maxCLL = c.maxCLL }
            if c.maxFALL > 0 { hdr.maxFALL = c.maxFALL }
        }
        if !hdr.isEmpty { v.hdr = hdr }
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        if let record = (atoms["dvcC"] ?? atoms["dvvC"] ?? atoms["dvwC"]) as? Data { v.dolbyVision = parseDOVIRecord(record) }
        info.video = v
        if facts.rate > 0 { (info.rateNum, info.rateDen) = rationalFrameRate(Double(facts.rate)) }
        if facts.duration.isFinite, facts.duration > 0 { info.duration = facts.duration }
        info.frameCount = safeFrameCount(seconds: info.duration, fps: info.fps)
        if facts.audioTracks > 0 && info.audio.isEmpty {
            info.audio = (0..<facts.audioTracks).map { AudioInfo(index: $0, codec: "audio", channels: 2, sampleRate: 48000) }
        }
    }

    /// Dolby Vision decoder configuration record: version major, minor, then profile (7 bits), level (6 bits),
    /// rpu / el / bl present flags, then the base layer's signal compatibility id (4 bits).
    static func parseDOVIRecord(_ record: Data) -> DolbyVisionInfo? {
        guard record.count >= 5 else { return nil }
        let b = [UInt8](record.prefix(5))
        let profile = Int(b[2] >> 1)
        let level = Int((b[2] & 1) << 5 | b[3] >> 3)
        return DolbyVisionInfo(profile: profile, level: level, blCompatibilityID: Int(b[4] >> 4),
                               hasEnhancementLayer: (b[3] >> 1) & 1 == 1)
    }

    // MARK: ffprobe

    static func probeFFprobe(_ url: URL, into info: inout MediaInfo) throws {
        let json: Data
        do {
            json = try ToolLocator.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_format",
                                                   "-show_frames", "-read_intervals", "%+#1", url.path], timeout: probeTimeout)
        } catch LumoraError.toolFailed(_, let msg) {
            throw PlayerError.damaged(msg.contains("timed out") ? "reading it took too long (\(msg))." : firstLine(msg))
        }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { throw PlayerError.damaged("FFmpeg can't read it.") }
        guard let s = streams.first(where: { $0["codec_type"] as? String == "video" && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 })
        else { throw PlayerError.noVideoTrack }
        let format = root["format"] as? [String: Any] ?? [:]
        let frames = (root["frames"] as? [[String: Any]] ?? []).filter { $0["media_type"] as? String == "video" }
        let firstFrame = frames.first
        var v = info.video
        let codecName = s["codec_name"] as? String ?? "?"
        let ffCodec = PlayerCodec.ffmpeg(codecName)
        if !info.avfDecodable || v.codec == .other("?") { v.codec = ffCodec }
        if case .other = v.codec { v.codec = ffCodec }
        v.profile = s["profile"] as? String
        v.width = s["width"] as? Int ?? v.width
        v.height = s["height"] as? Int ?? v.height
        if let sar = s["sample_aspect_ratio"] as? String {
            let p = sar.split(separator: ":").compactMap { Int($0) }
            if p.count == 2, p[0] > 0, p[1] > 0 { v.sarNum = p[0]; v.sarDen = p[1] }
        }
        if let pix = s["pix_fmt"] as? String ?? firstFrame?["pix_fmt"] as? String {
            v.pixelFormat = pix
            if let l = FrameLayout.ffmpeg(pix, width: 16, height: 16) {
                v.bitDepth = l.bits; v.chroma = l.chroma
                if l.forcesFullRange && !v.color.rangeTagged { v.color.fullRange = true; v.color.rangeTagged = true }
            } else {
                v.bitDepth = pix.contains("16") ? 16 : pix.contains("12") ? 12 : pix.contains("10") ? 10 : 8
                v.chroma = pix.contains("444") || pix.contains("rgb") || pix.contains("gbr") ? .c444 : pix.contains("422") ? .c422 : .c420
            }
        }
        if let b = Int(s["bits_per_raw_sample"] as? String ?? ""), b >= 8, b <= 16, v.pixelFormat == nil { v.bitDepth = b }

        // Color: the stream's tags, overridden by the first decoded frame (decoders apply SEI such as HEVC's
        // alternative transfer characteristics there).
        func apply(_ dict: [String: Any], isFrame: Bool) {
            if let p = dict["color_primaries"] as? String, let n = cicpPrimaries(ffmpeg: p), n != 2 { v.color.primaries = n; v.color.primariesTagged = true }
            if let t = dict["color_transfer"] as? String, let n = cicpTransfer(ffmpeg: t), n != 2 {
                if isFrame, v.color.transferTagged, n != v.color.transfer { v.alternativeTransfer = n }
                v.color.transfer = n; v.color.transferTagged = true
            }
            if let m = dict["color_space"] as? String, let n = cicpMatrix(ffmpeg: m), n != 2 { v.color.matrix = n; v.color.matrixTagged = true }
            if let r = dict["color_range"] as? String, r == "tv" || r == "pc" { v.color.fullRange = r == "pc"; v.color.rangeTagged = true }
            if let l = dict["chroma_location"] as? String {
                let loc = ChromaLocation.ffmpeg(l)
                if loc != .unknown { v.color.chromaLocation = loc; v.color.chromaLocationTagged = true }
            }
        }
        if !info.avfDecodable || !v.color.transferTagged { apply(s, isFrame: false) }
        else if !v.color.chromaLocationTagged, let l = s["chroma_location"] as? String {
            let loc = ChromaLocation.ffmpeg(l)
            if loc != .unknown { v.color.chromaLocation = loc; v.color.chromaLocationTagged = true }
        }
        if let f = firstFrame { apply(f, isFrame: true) }

        // HDR10 static metadata, Dolby Vision, HDR10+.
        var hdr = v.hdr ?? HDRStatic()
        let sideData = (s["side_data_list"] as? [[String: Any]] ?? []) + (firstFrame?["side_data_list"] as? [[String: Any]] ?? [])
        for sd in sideData {
            let type = sd["side_data_type"] as? String ?? ""
            if type.contains("Mastering display") {
                if hdr.mdcvMaxNits == nil, let m = rational(sd["max_luminance"]), m > 0, m <= 100_000 { hdr.mdcvMaxNits = m }
                if hdr.mdcvMinNits == nil, let m = rational(sd["min_luminance"]), m >= 0 { hdr.mdcvMinNits = m }
                if hdr.mdcvPrimaries == nil {
                    let keys = ["red_x", "red_y", "green_x", "green_y", "blue_x", "blue_y", "white_point_x", "white_point_y"]
                    let p = keys.compactMap { rational(sd[$0]) }
                    if p.count == 8 { hdr.mdcvPrimaries = p }
                }
            } else if type.contains("Content light level") {
                if hdr.maxCLL == nil, let c = sd["max_content"] as? Int, c > 0 { hdr.maxCLL = Double(c) }
                if hdr.maxFALL == nil, let a = sd["max_average"] as? Int, a > 0 { hdr.maxFALL = Double(a) }
            } else if type.contains("DOVI") {
                if v.dolbyVision == nil, let p = sd["dv_profile"] as? Int {
                    v.dolbyVision = DolbyVisionInfo(profile: p, level: sd["dv_level"] as? Int ?? 0,
                                                    blCompatibilityID: sd["dv_bl_signal_compatibility_id"] as? Int ?? 0,
                                                    hasEnhancementLayer: (sd["el_present_flag"] as? Int ?? 0) == 1)
                }
            } else if type.contains("2094-40") || type.contains("HDR10+") {
                v.hdr10Plus = true
            }
        }
        if !hdr.isEmpty { v.hdr = hdr }
        info.video = v

        // Timing.
        let ext = info.url.pathExtension.lowercased()
        if !info.avfDecodable || info.fps <= 0 {
            let rate = parseRate(s["avg_frame_rate"] as? String) ?? parseRate(s["r_frame_rate"] as? String)
            if let r = rate {
                (info.rateNum, info.rateDen) = rationalFrameRate(r)
                // Raw elementary streams without VUI timing get FFmpeg's default of 25: treat that as unknown.
                if info.isRawElementaryStream && info.rateNum == 25 && info.rateDen == 1 { info.frameRateKnown = false; info.rateNum = 24 }
            } else {
                info.frameRateKnown = false
            }
        }
        if !info.avfDecodable {
            let dur = Double(s["duration"] as? String ?? "") ?? Double(format["duration"] as? String ?? "") ?? 0
            info.duration = info.isRawElementaryStream ? 0 : (dur.isFinite && dur > 0 ? min(dur, 864_000) : 0)
            if let n = Int(s["nb_frames"] as? String ?? ""), n > 0 { info.frameCount = min(n, 50_000_000) }
            else if info.duration > 0 { info.frameCount = safeFrameCount(seconds: info.duration, fps: info.fps) }
            else { info.frameCount = nil }
        }
        if ext == "y4m" { info.isRawElementaryStream = false; info.frameRateKnown = true }
        if let name = format["format_name"] as? String, !info.avfDecodable { info.container = name.split(separator: ",").first.map(String.init) ?? name }

        // Audio.
        if !streams.isEmpty {
            var n = 0
            var tracks: [AudioInfo] = []
            for a in streams where a["codec_type"] as? String == "audio" {
                tracks.append(AudioInfo(index: n, codec: a["codec_name"] as? String ?? "audio", channels: a["channels"] as? Int ?? 2,
                                        sampleRate: Int(a["sample_rate"] as? String ?? "") ?? 48000,
                                        language: (a["tags"] as? [String: Any])?["language"] as? String))
                n += 1
            }
            info.audio = tracks
        }
    }

    private static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((t.split(separator: "\n").last ?? Substring(t)).prefix(300))
    }

    static func parseRate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let p = s.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] > 0, p[0] > 0 else { return nil }
        let f = p[0] / p[1]
        return f.isFinite && f >= 1 && f <= 1000 ? f : nil
    }

    private static func rational(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        guard let s = any as? String else { return nil }
        let p = s.split(separator: "/").compactMap { Double($0) }
        if p.count == 2, p[1] != 0 { return p[0] / p[1] }
        return Double(s)
    }

    // MARK: Lumora's own exports

    static func applyManifest(_ info: inout MediaInfo) {
        guard let m = ExportManifest.load(for: info.url) else { return }
        if !info.frameRateKnown || info.video.codec == .av2, m.rateNum > 0, m.rateDen > 0 {
            let f = Double(m.rateNum) / Double(m.rateDen)
            if f >= 1 && f <= 1000 { info.rateNum = m.rateNum; info.rateDen = m.rateDen; info.frameRateKnown = true }
        }
        if info.frameCount == nil, m.frames > 0 { info.frameCount = m.frames }
        if let p = m.peakNits, p > 0 { info.manifestPeakNits = Double(p) }
    }

    // MARK: Notes for the info overlay

    static func addNotes(_ info: inout MediaInfo) {
        let v = info.video
        if let dv = v.dolbyVision { info.notes.append(dv.summary) }
        if v.hdr10Plus { info.notes.append("HDR10+: dynamic metadata ignored, static HDR10 used.") }
        if v.color.matrix == 10 || v.color.matrix == 14 { info.notes.append("\(v.color.matrixName): shown with the BT.2020 NCL matrix.") }
        if v.codec == .vvc, v.color.transfer == 14 || v.color.transfer == 15 {
            info.notes.append("Tagged BT.2020 SDR. If this is HLG carried with an alternative-transfer SEI (FFmpeg's VVC decoder doesn't apply it), choose Interpret as HLG.")
        }
        if let alt = v.alternativeTransfer, alt == 18 { info.notes.append("Alternative transfer SEI: playing as HLG.") }
        if v.codec == .av2 { info.notes.append("AV2 can't carry mastering metadata; the HDR peak comes from Lumora's export record or Settings → Player.") }
    }

    // MARK: CICP mappings

    static func cicpPrimaries(coreMedia s: String) -> Int? {
        switch s {
        case "ITU_R_709_2": return 1
        case "EBU_3213": return 5
        case "SMPTE_C": return 6
        case "ITU_R_2020": return 9
        case "DCI_P3": return 11
        case "P3_D65": return 12
        default: return nil
        }
    }
    static func cicpTransfer(coreMedia s: String) -> Int? {
        switch s {
        case "ITU_R_709_2": return 1
        case "SMPTE_240M_1995": return 7
        case "Linear": return 8
        case "IEC_sRGB": return 13
        case "ITU_R_2020": return 14
        case "SMPTE_ST_2084_PQ": return 16
        case "ITU_R_2100_HLG": return 18
        default: return nil
        }
    }
    static func cicpMatrix(coreMedia s: String) -> Int? {
        switch s {
        case "ITU_R_709_2": return 1
        case "ITU_R_601_4": return 6
        case "SMPTE_240M_1995": return 7
        case "ITU_R_2020": return 9
        default: return nil
        }
    }
    static func cicpPrimaries(ffmpeg s: String) -> Int? {
        ["bt709": 1, "unknown": 2, "bt470m": 4, "bt470bg": 5, "smpte170m": 6, "smpte240m": 7, "film": 8, "bt2020": 9,
         "smpte428": 10, "smpte431": 11, "smpte432": 12, "jedec-p22": 22, "ebu3213": 22][s]
    }
    static func cicpTransfer(ffmpeg s: String) -> Int? {
        ["bt709": 1, "unknown": 2, "gamma22": 4, "bt470m": 4, "gamma28": 5, "bt470bg": 5, "smpte170m": 6, "smpte240m": 7,
         "linear": 8, "iec61966-2-4": 11, "bt1361e": 12, "iec61966-2-1": 13, "bt2020-10": 14, "bt2020-12": 15,
         "smpte2084": 16, "smpte428": 17, "arib-std-b67": 18][s]
    }
    static func cicpMatrix(ffmpeg s: String) -> Int? {
        ["gbr": 0, "bt709": 1, "unknown": 2, "fcc": 4, "bt470bg": 5, "smpte170m": 6, "smpte240m": 7, "ycgco": 8,
         "bt2020nc": 9, "bt2020c": 10, "smpte2085": 11, "chroma-derived-nc": 12, "chroma-derived-c": 13, "ictcp": 14][s]
    }
}

/// Exact per-frame timing from the container (ffprobe's packet list): frame count, presentation times for
/// variable frame rates, and key frames for the scrubber and segment-parallel pre-decode.
struct FrameTable: Codable, Equatable {
    var pts: [Double]               // presentation order, seconds from the first frame
    var keyFrames: [Int]            // frame indices
    /// false for raw elementary streams, whose packets carry no timestamps (pts then only counts frames).
    var timed = true
    var count: Int { pts.count }
    var rate: (Int, Int)? {
        guard timed, pts.count >= 2 else { return nil }
        let n = min(pts.count - 1, 120)
        let span = pts[n] - pts[0]
        guard span > 0 else { return nil }
        let f = Double(n) / span
        return f >= 1 && f <= 1000 ? rationalFrameRate(f) : nil
    }

    static func read(_ url: URL, timeout: TimeInterval) throws -> FrameTable {
        let csv = try ToolLocator.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags",
                                                  "-of", "csv=p=0", url.path], timeout: timeout, maxOutput: 512 << 20)
        var rows: [(Double?, Bool)] = []
        for line in String(decoding: csv, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 2 else { continue }
            let t = Double(f[0]).flatMap { $0.isFinite ? $0 : nil }
            rows.append((t, f[1].hasPrefix("K")))
        }
        if rows.contains(where: { $0.0 == nil }) {
            // No timestamps (raw stream): decode order is display order only without reordering, so keep counts only.
            return FrameTable(pts: rows.indices.map { Double($0) }, keyFrames: rows.indices.filter { rows[$0].1 }, timed: false)
        }
        let sorted = rows.map { ($0.0!, $0.1) }.sorted { $0.0 < $1.0 }
        guard let t0 = sorted.first?.0 else { return FrameTable(pts: [], keyFrames: []) }
        return FrameTable(pts: sorted.map { $0.0 - t0 }, keyFrames: sorted.indices.filter { sorted[$0].1 })
    }
}
