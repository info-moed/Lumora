import Foundation
import AVFoundation
import CoreImage

/// Works out what a file is and how its signal should be interpreted. Uses, in order:
/// container tags (transfer, primaries, Apple's log tag, Dolby Vision config), camera make/model
/// metadata, and finally the picture itself (log footage has lifted blacks, low contrast, low saturation).
enum SourceInspector {
    static let rawStillExtensions: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "nrw", "raf", "rw2", "orf",
                                                  "pef", "srw", "x3f", "3fr", "iiq", "erf", "kdc", "dcr", "mos"]
    static let ffmpegFirstExtensions: Set<String> = ["mkv", "webm", "avi", "mxf", "ts", "m2ts", "mts", "flv",
                                                     "wmv", "266", "vvc", "obu", "ivf", "y4m", "hevc", "h265"]

    static func inspect(_ url: URL) async throws -> (SourceDescriptor, [SourceColor]) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()

        if isDir.boolValue || rawStillExtensions.contains(ext) {
            let raw = try inspectRAW(url, isDirectory: isDir.boolValue)
            try validateGeometry(raw.0)
            return raw
        }
        if VendorRAWRegistry.vendorExtensions.contains(ext) {
            guard let plugin = VendorRAWRegistry.plugin(for: url) else { throw LumoraError.needsVendorSDK(ext) }
            let src = try plugin.makeFrameSource(url: url)
            var d = SourceDescriptor(url: url, kind: .vendorRAW)
            d.width = src.width; d.height = src.height; d.frameCount = src.frameCount
            (d.fpsNum, d.fpsDen) = rationalFrameRate(src.fps)
            d.codec = ext.uppercased() + " RAW"
            return (d, [plugin.outputColor])
        }
        var result: (SourceDescriptor, [SourceColor])
        if !ffmpegFirstExtensions.contains(ext), let r = try? await inspectAVFoundation(url) {
            result = r
        } else {
            result = try await inspectFFmpeg(url)
        }
        try validateGeometry(result.0)
        result.0.suggestedScanFix = detectScanFix(result.0)
        if result.0.suggestedScanFix != .none { result.0 = result.0.applying(result.0.suggestedScanFix) }
        return result
    }

    /// Lumora's GPU textures are 16…16384 px per side; anything outside that is a broken or hostile file.
    static func validateGeometry(_ d: SourceDescriptor) throws {
        guard d.width >= 16, d.height >= 16 else {
            throw LumoraError.decodeFailed("The video reports an impossible size (\(d.width)×\(d.height)).")
        }
        guard d.width <= 16384, d.height <= 16384 else {
            throw LumoraError.unsupported("Videos larger than 16384 pixels on a side aren't supported (\(d.width)×\(d.height)).")
        }
        guard d.frameCount >= 1 else { throw LumoraError.decodeFailed("The video has no frames.") }
    }

    /// Uses FFmpeg's `idet` field detector on ~400 frames when a source might be interlaced or telecined.
    static func detectScanFix(_ d: SourceDescriptor) -> ScanFix {
        let flagged = d.fieldOrder.map { $0 != "progressive" && $0 != "unknown" } ?? false
        let legacy = d.height <= 576 || ["mpeg2video", "vc1", "mpeg1video"].contains(d.codec)
        guard flagged || legacy, ToolLocator.isAvailable("ffmpeg") else { return .none }
        guard let log = try? ToolLocator.runCapturingStderr("ffmpeg", ["-hide_banner", "-nostdin", "-i", d.url.path,
                                                                       "-vf", "idet", "-frames:v", "400", "-an", "-f", "null", "-"]) else { return .none }
        func numbers(after label: String) -> [Int] {
            guard let line = log.split(separator: "\n").last(where: { $0.contains(label) }) else { return [] }
            return line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.suffix(4).map { $0 }
        }
        let repeated = numbers(after: "Repeated Fields")          // neither, top, bottom
        let multi = numbers(after: "Multi frame detection")       // tff, bff, progressive, undetermined
        if repeated.count >= 3 {
            let total = max(1, repeated.suffix(3).reduce(0, +))
            let rep = repeated.suffix(2).reduce(0, +)
            if Double(rep) / Double(total) > 0.12 { return .inverseTelecine }
        }
        if multi.count == 4, multi[0] + multi[1] > multi[2] { return .deinterlace }
        return flagged ? .deinterlace : .none
    }

    // MARK: AVFoundation

    private static func inspectAVFoundation(_ url: URL) async throws -> (SourceDescriptor, [SourceColor]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LumoraError.noVideoTrack }
        var d = SourceDescriptor(url: url, kind: .avfoundation)
        let (size, rate, range, formats) = try await track.load(.naturalSize, .nominalFrameRate, .timeRange, .formatDescriptions)
        d.width = Int(size.width) & ~1
        d.height = Int(size.height) & ~1
        (d.fpsNum, d.fpsDen) = rationalFrameRate(Double(rate > 0 ? rate : 24))
        d.frameCount = safeFrameCount(seconds: range.duration.seconds, fps: d.fps)
        d.hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty

        if let fd = formats.first {
            d.codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
            let ext = (CMFormatDescriptionGetExtensions(fd) as? [String: Any]) ?? [:]
            d.transferTag = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            d.primariesTag = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            d.matrixTag = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            d.bitDepth = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int
            if let fields = ext[kCMFormatDescriptionExtension_FieldCount as String] as? Int {
                d.fieldOrder = fields == 2 ? "interlaced" : "progressive"
            }
            // Apple tags log recordings with a log-transfer extension; match by name so this keeps
            // working whatever the exact key/value spelling is in a given OS release.
            for (k, v) in ext where k.localizedCaseInsensitiveContains("log") {
                if let s = v as? String { d.logTag = s }
            }
            let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
            d.isDolbyVision = ["dvh1", "dvhe", "dav1"].contains(d.codec) || atoms.keys.contains { $0 == "dvcC" || $0 == "dvvC" }
            // Dolby Vision decoder configuration record: version major, minor, then profile (7 bits), level (6),
            // rpu / el / bl present flags. The profile decides whether the original can be kept (never profile 5).
            if let record = (atoms["dvcC"] ?? atoms["dvvC"] ?? atoms["dvwC"]) as? Data, record.count >= 4 {
                let b = [UInt8](record.prefix(4))
                d.dvProfile = Int(b[2] >> 1)
                d.dvHasEnhancementLayer = (b[3] >> 1) & 1 == 1
            }
        }
        for item in try await asset.load(.metadata) {
            if item.identifier == .quickTimeMetadataMake { d.make = try? await item.load(.stringValue) }
            if item.identifier == .quickTimeMetadataModel { d.model = try? await item.load(.stringValue) }
        }
        let probe = try await probeSignal(d)
        return (d, rankCandidates(d, probe: probe))
    }

    // MARK: FFmpeg / ffprobe

    private static func inspectFFmpeg(_ url: URL) async throws -> (SourceDescriptor, [SourceColor]) {
        let json = try ToolLocator.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams",
                                                   "-show_format", url.path])
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let v = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw LumoraError.noVideoTrack
        }
        var d = SourceDescriptor(url: url, kind: .ffmpeg)
        d.width = (v["width"] as? Int ?? 0) & ~1
        d.height = (v["height"] as? Int ?? 0) & ~1
        d.codec = v["codec_name"] as? String ?? "?"
        if let r = v["avg_frame_rate"] as? String ?? v["r_frame_rate"] as? String {
            let p = r.split(separator: "/").compactMap { Double($0) }
            if p.count == 2, p[1] > 0 { (d.fpsNum, d.fpsDen) = rationalFrameRate(p[0] / p[1]) }
        }
        let duration = Double(v["duration"] as? String ?? "") ??
                       Double((root["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        d.frameCount = Int(v["nb_frames"] as? String ?? "").map { min(max(1, $0), 10_000_000) }
            ?? safeFrameCount(seconds: duration, fps: d.fps)
        d.fieldOrder = v["field_order"] as? String
        if let pix = v["pix_fmt"] as? String {
            d.bitDepth = pix.contains("12") ? 12 : pix.contains("10") ? 10 : 8
        }
        switch v["color_transfer"] as? String {
        case "smpte2084": d.transferTag = "SMPTE_ST_2084_PQ"
        case "arib-std-b67": d.transferTag = "ITU_R_2100_HLG"
        case "bt709", "bt1886": d.transferTag = "ITU_R_709_2"
        default: break
        }
        if v["color_primaries"] as? String == "bt2020" { d.primariesTag = "ITU_R_2020" }
        let sideData = v["side_data_list"] as? [[String: Any]] ?? []
        d.isDolbyVision = sideData.contains { ($0["side_data_type"] as? String)?.contains("DOVI") == true }
        if let dovi = sideData.first(where: { ($0["side_data_type"] as? String)?.contains("DOVI") == true }) {
            d.dvProfile = dovi["dv_profile"] as? Int
            d.dvHasEnhancementLayer = (dovi["el_present_flag"] as? Int ?? 0) == 1
        }
        d.hasAudio = streams.contains { $0["codec_type"] as? String == "audio" }
        let tags = (root["format"] as? [String: Any])?["tags"] as? [String: Any] ?? [:]
        d.make = tags["com.apple.quicktime.make"] as? String
        d.model = tags["com.apple.quicktime.model"] as? String
        let probe = try await probeSignal(d)
        return (d, rankCandidates(d, probe: probe))
    }

    // MARK: RAW

    private static func inspectRAW(_ url: URL, isDirectory: Bool) throws -> (SourceDescriptor, [SourceColor]) {
        let files: [URL]
        if isDirectory {
            files = (try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
                .filter { rawStillExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            files = [url]
        }
        guard let first = files.first, let f = CIRAWFilter(imageURL: first) else {
            throw LumoraError.unsupported("No camera RAW files Core Image can read were found.")
        }
        var d = SourceDescriptor(url: url, kind: .rawSequence, files: files)
        d.width = Int(f.nativeSize.width) & ~1
        d.height = Int(f.nativeSize.height) & ~1
        d.frameCount = files.count
        d.codec = first.pathExtension.uppercased() + (files.count > 1 ? " sequence" : "")
        d.bitDepth = 14
        // Core Image develops RAW straight to scene-linear Rec.2020 (we disable its tone curve).
        return (d, [SourceColor(name: "Camera RAW (scene-linear)", transfer: .linear, gamut: .rec2020,
                                legalToFull: false, confidence: 1)])
    }

    // MARK: Signal probe

    struct SignalProbe {
        var p01: Float, median: Float, p995: Float, chroma: Float
        /// Lifted blacks, compressed whites, mid-heavy, desaturated: the fingerprint of log footage.
        var looksLog: Bool { p01 > 0.04 && p995 < 0.93 && median > 0.25 && median < 0.62 && chroma < 0.07 }
    }

    /// Looks at a few frames' *encoded* values (no decode curve) to see whether the picture behaves like log.
    static func probeSignal(_ d: SourceDescriptor) async throws -> SignalProbe {
        let src = try await d.makeFrameSource()
        let renderer = GradeRenderer()
        let neutral = SourceColor(name: "probe", transfer: .linear, gamut: .rec2020, legalToFull: false, confidence: 0)
        let u = UniformBuilder.analysis(source: neutral, gridW: 256, gridH: 144)
        var hist = [UInt32](repeating: 0, count: Int(HIST_BINS))
        var chroma: Float = 0, samples: Float = 0
        for f in [0.2, 0.5, 0.8].map({ Int(Double(d.frameCount) * $0) }) {
            try src.start(at: f, count: 1)
            guard let frame = try src.nextFrame() else { continue }
            let s = renderer.analyze(frame.texture, uniforms: u, gridWidth: 256)
            for i in 0..<hist.count { hist[i] += s.histogram[i] }
            chroma += Float(s.chromaSum) / 1000
            samples += Float(s.count)
        }
        src.cancel()
        let value = { (p: Float) in 0.18 * powf(2, Histogram.percentileStop(hist, p)) }
        return SignalProbe(p01: value(0.01), median: value(0.5), p995: value(0.995),
                           chroma: samples > 0 ? chroma / samples : 0)
    }

    // MARK: Ranking

    static func rankCandidates(_ d: SourceDescriptor, probe: SignalProbe) -> [SourceColor] {
        let make = (d.make ?? "").lowercased()
        let model = (d.model ?? "").lowercased()
        var out: [SourceColor] = []

        // 1. Explicit HDR tags.
        if d.transferTag?.contains("2084") == true {
            out.append(SourceColor(name: d.isDolbyVision ? "Dolby Vision / PQ HDR" : "HDR10 (PQ)", transfer: .pq,
                                   gamut: .rec2020, legalToFull: false, confidence: 0.95))
        } else if d.transferTag?.contains("HLG") == true {
            out.append(SourceColor(name: d.isDolbyVision ? "Dolby Vision 8.4 / HLG" : "HLG", transfer: .hlg,
                                   gamut: .rec2020, legalToFull: false, confidence: 0.95))
        }

        // 2. Apple Log / Apple Log 2.
        let appleLogTagged = d.logTag?.localizedCaseInsensitiveContains("apple") == true
        let isIPhone = make.contains("apple") || model.contains("iphone")
        if appleLogTagged || (isIPhone && probe.looksLog) {
            var gen = 0
            if let r = model.range(of: #"iphone (\d+)"#, options: .regularExpression) {
                gen = Int(model[r].split(separator: " ").last ?? "") ?? 0
            }
            let log2Capable = gen >= 17 && model.contains("pro")
            let taggedLog2 = d.logTag?.contains("2") == true || (d.primariesTag != nil && d.primariesTag != "ITU_R_2020")
            let log2Conf: Float = taggedLog2 ? 0.85 : (log2Capable ? 0.6 : 0.15)
            let note = Gamut.appleWideGamut.isVerified ? nil : "Apple Wide Gamut primaries not yet verified — colour approximate."
            out.append(SourceColor(name: "Apple Log 2", transfer: .appleLog, gamut: .appleWideGamut,
                                   legalToFull: false, confidence: log2Conf, note: note))
            out.append(SourceColor(name: "Apple Log", transfer: .appleLog, gamut: .rec2020,
                                   legalToFull: false, confidence: 1 - log2Conf))
        }

        // 3. Other camera logs, by maker, when the picture looks like log.
        if probe.looksLog && !isIPhone {
            if make.contains("sony") {
                out.append(SourceColor(name: "S-Log3 / S-Gamut3.Cine", transfer: .sLog3, gamut: .sGamut3Cine, legalToFull: true, confidence: 0.85))
            } else if make.contains("arri") {
                let alexa35 = model.contains("35")
                out.append(SourceColor(name: alexa35 ? "LogC4 / AWG4" : "LogC3 / AWG3", transfer: alexa35 ? .logC4 : .logC3,
                                       gamut: alexa35 ? .arriWideGamut4 : .arriWideGamut3, legalToFull: true, confidence: 0.85))
            } else if make.contains("panasonic") {
                out.append(SourceColor(name: "V-Log / V-Gamut", transfer: .vLog, gamut: .vGamut, legalToFull: true, confidence: 0.85))
            } else {
                for (n, t, g) in [("S-Log3 / S-Gamut3.Cine", Transfer.sLog3, Gamut.sGamut3Cine),
                                  ("LogC3 / AWG3", .logC3, .arriWideGamut3), ("V-Log / V-Gamut", .vLog, .vGamut)] {
                    out.append(SourceColor(name: n, transfer: t, gamut: g, legalToFull: true, confidence: 0.3,
                                           note: "Camera unknown — compare the previews and pick the one that looks right."))
                }
            }
        }

        // 4. Plain SDR is always offered as a fallback.
        let sdrConf: Float = out.isEmpty ? 0.9 : 0.1
        out.append(SourceColor(name: "SDR Rec.709", transfer: .bt1886, gamut: .rec709, legalToFull: false, confidence: sdrConf))
        return out.sorted { $0.confidence > $1.confidence }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Helpers for the analysis histogram (bins of log2(Y / 0.18)).
enum Histogram {
    static let lowStop: Float = -12
    static let stopsPerBin: Float = 20.0 / 128.0

    static func percentileStop(_ h: [UInt32], _ p: Float) -> Float {
        let total = h.reduce(0) { $0 + UInt64($1) }
        guard total > 0 else { return 0 }
        let target = UInt64(Double(total) * Double(p))
        var cum: UInt64 = 0
        for (i, c) in h.enumerated() {
            cum += UInt64(c)
            if cum >= target { return lowStop + (Float(i) + 0.5) * stopsPerBin }
        }
        return lowStop + Float(h.count) * stopsPerBin
    }

    static func meanStop(_ h: [UInt32]) -> Float {
        var sum: Double = 0, n: Double = 0
        for (i, c) in h.enumerated() { sum += Double(c) * Double(lowStop + (Float(i) + 0.5) * stopsPerBin); n += Double(c) }
        return n > 0 ? Float(sum / n) : 0
    }

    static func fraction(_ h: [UInt32], aboveStop s: Float) -> Float {
        let total = h.reduce(0) { $0 + UInt64($1) }
        guard total > 0 else { return 0 }
        let first = max(0, min(h.count, Int(((s - lowStop) / stopsPerBin).rounded(.up))))
        return Float(h[first...].reduce(0) { $0 + UInt64($1) }) / Float(total)
    }
}
