import Foundation
import VideoToolbox
import CoreMedia

/// What this Mac can decode, measured once at launch (ToolProbe.warmUp) so opening a file never waits for it.
struct DecoderCapabilities: Equatable {
    /// Codec types VideoToolbox decodes in hardware (VTIsHardwareDecodeSupported), as four-character codes.
    var vtHardware: Set<String> = []
    /// `ffmpeg -decoders` names.
    var ffmpegDecoders: Set<String> = []
    /// `ffmpeg -hwaccels` names.
    var ffmpegHWAccels: Set<String> = []
    var hasFFmpeg = false
    var hasFFprobe = false
    var hasAVMDec = false
    var avmdecVersion: String?
    var hasMP4Box = false

    /// An FFmpeg AV2 decoder, should a future FFmpeg ship one; preferred over avmdec when present.
    var ffmpegAV2Decoder: String? { ["libavm", "av2", "libdav2d"].first { ffmpegDecoders.contains($0) } }
    var hasVideoToolboxAccel: Bool { ffmpegHWAccels.contains("videotoolbox") }

    nonisolated(unsafe) private static var cached: DecoderCapabilities?
    private static let lock = NSLock()

    /// The capabilities of this Mac (measured on first use, then cached).
    static var current: DecoderCapabilities {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let c = detect()
        cached = c
        return c
    }

    /// Forgets the cached answer (after installing a tool, and in tests that fake a missing one).
    static func invalidate() { lock.lock(); cached = nil; lock.unlock() }

    static func detect() -> DecoderCapabilities {
        var c = DecoderCapabilities()
        for (code, type) in [("avc1", kCMVideoCodecType_H264), ("hvc1", kCMVideoCodecType_HEVC), ("av01", kCMVideoCodecType_AV1),
                             ("apch", kCMVideoCodecType_AppleProRes422HQ), ("ap4h", kCMVideoCodecType_AppleProRes4444),
                             ("vp09", kCMVideoCodecType_VP9)] where VTIsHardwareDecodeSupported(type) {
            c.vtHardware.insert(code)
        }
        c.hasFFmpeg = ToolLocator.isAvailable("ffmpeg")
        c.hasFFprobe = ToolLocator.isAvailable("ffprobe")
        c.hasMP4Box = ToolLocator.isAvailable("MP4Box")
        if c.hasFFmpeg {
            if let d = try? ToolLocator.run("ffmpeg", ["-hide_banner", "-decoders"], timeout: 10) {
                c.ffmpegDecoders = parseDecoders(String(decoding: d, as: UTF8.self))
            }
            if let h = try? ToolLocator.run("ffmpeg", ["-hide_banner", "-hwaccels"], timeout: 10) {
                c.ffmpegHWAccels = Set(String(decoding: h, as: UTF8.self).split(separator: "\n").dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        }
        c.hasAVMDec = ToolLocator.isAvailable("avmdec")
        if c.hasAVMDec, let help = try? ToolLocator.runCapturingStderrAndOutput("avmdec", ["--help"], timeout: 5),
           let r = help.range(of: #"AV2 Decoder [0-9][0-9.]*"#, options: .regularExpression) {
            c.avmdecVersion = String(help[r].split(separator: " ").last ?? "")
        }
        return c
    }

    /// Lines of `ffmpeg -decoders` look like " V....D hevc   HEVC (High Efficiency Video Coding)".
    static func parseDecoders(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var started = false
        for line in text.split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("------") { started = true; continue }
            guard started else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { out.insert(String(parts[1])) }
        }
        return out
    }
}

extension ToolLocator {
    /// stdout and stderr together, for tools that print their help or version to either.
    static func runCapturingStderrAndOutput(_ name: String, _ args: [String], timeout: TimeInterval) throws -> String {
        guard let exe = url(for: name) else { throw LumoraError.missingTool(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = FFHarden.args(name, args)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let exited = p.exitSignal()
        try p.run()
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = done.wait(timeout: .now() + 2)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The player's preferences (Settings → Player).
struct PlayerSettings: Equatable {
    enum ToneMapping: String, CaseIterable, Identifiable {
        case lumora, macOS
        var id: String { rawValue }
        var label: String { self == .lumora ? "Lumora (BT.2390)" : "macOS" }
    }

    var toneMapping = ToneMapping.lumora
    /// Nits shown as SDR white: 100 (Apple's EDR convention, what the grading viewer uses) or 203 (BT.2408).
    var referenceWhite: Float = 100
    /// Peak assumed for HDR that carries no mastering metadata (AV2, untagged files).
    var assumedPeak: Float = 1000
    var preferHardware = true
    /// RAM for decoded frames waiting to be shown.
    var bufferBudgetMB = PlayerSettings.defaultBufferMB
    /// Most disk the pre-decode cache may use for one file, in GB.
    var cacheCapGB: Double = 16
    var parallelDecoders = PlayerSettings.defaultParallel
    var skipFilmGrain = false

    static var defaultBufferMB: Int {
        min(1536, Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.04 / 1_048_576))
    }
    static var defaultParallel: Int { max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 4)) }

    private static let prefix = "player."

    static var current: PlayerSettings {
        let d = Prefs.store
        var s = PlayerSettings()
        if let v = d.string(forKey: prefix + "toneMapping"), let t = ToneMapping(rawValue: v) { s.toneMapping = t }
        if let v = d.object(forKey: prefix + "referenceWhite") as? Double, v == 100 || v == 203 { s.referenceWhite = Float(v) }
        if let v = d.object(forKey: prefix + "assumedPeak") as? Double, (100...10_000).contains(v) { s.assumedPeak = Float(v) }
        if let v = d.object(forKey: prefix + "preferHardware") as? Bool { s.preferHardware = v }
        if let v = d.object(forKey: prefix + "bufferBudgetMB") as? Int, (64...16_384).contains(v) { s.bufferBudgetMB = v }
        if let v = d.object(forKey: prefix + "cacheCapGB") as? Double, (1...1000).contains(v) { s.cacheCapGB = v }
        if let v = d.object(forKey: prefix + "parallelDecoders") as? Int, (1...16).contains(v) { s.parallelDecoders = v }
        if let v = d.object(forKey: prefix + "skipFilmGrain") as? Bool { s.skipFilmGrain = v }
        return s
    }

    func save() {
        let d = Prefs.store
        d.set(toneMapping.rawValue, forKey: Self.prefix + "toneMapping")
        d.set(Double(referenceWhite), forKey: Self.prefix + "referenceWhite")
        d.set(Double(assumedPeak), forKey: Self.prefix + "assumedPeak")
        d.set(preferHardware, forKey: Self.prefix + "preferHardware")
        d.set(bufferBudgetMB, forKey: Self.prefix + "bufferBudgetMB")
        d.set(cacheCapGB, forKey: Self.prefix + "cacheCapGB")
        d.set(parallelDecoders, forKey: Self.prefix + "parallelDecoders")
        d.set(skipFilmGrain, forKey: Self.prefix + "skipFilmGrain")
    }
}

enum PlayerBackendKind: String, Equatable {
    case avfoundation, ffmpeg, avm
}

/// How a backend reaches an arbitrary frame.
enum SeekModel: Equatable {
    /// Jumps straight there (AVFoundation, FFmpeg on an indexed container).
    case random
    /// Has to decode forward from a random access point it can start at (avmdec).
    case fromRandomAccessPoint
    /// Has to decode forward from the start (raw elementary streams that couldn't be indexed).
    case fromStart
}

struct DecoderChoice: Equatable {
    var backend: PlayerBackendKind
    /// What the info overlay shows, e.g. "ffmpeg hevc + VideoToolbox".
    var tool: String
    var hardware: Bool
    /// FFmpeg: the decoder passed to -c:v (nil = FFmpeg's default for the codec).
    var ffmpegDecoder: String?
    var hwaccel = false
    /// FFmpeg: the rawvideo pixel format read from the pipe (the decoder's own output, so nothing is converted).
    var pixelFormat: String?
    /// FFmpeg: a software decoder to retry with when VideoToolbox can't start on this stream.
    var softwareFallback: String?
    var reason: String
    var seekModel: SeekModel = .random
}

enum DecoderSelector {
    /// Picks the decoder for a file. Pure: everything it needs is in its arguments, so it is tested as a table.
    static func choose(_ info: MediaInfo, caps: DecoderCapabilities, prefs: PlayerSettings = PlayerSettings()) throws -> DecoderChoice {
        let v = info.video
        let hw = prefs.preferHardware

        // 1. AV2: no fast decoder exists yet.
        if v.codec == .av2 {
            if let dec = caps.ffmpegAV2Decoder, caps.hasFFmpeg {
                return DecoderChoice(backend: .ffmpeg, tool: "ffmpeg \(dec)", hardware: false, ffmpegDecoder: dec,
                                     pixelFormat: softwarePixelFormat(v), reason: "This FFmpeg has an AV2 decoder.")
            }
            guard caps.hasAVMDec else { throw PlayerError.missingTool("avmdec", PlayerError.avmHint) }
            return DecoderChoice(backend: .avm, tool: "avmdec" + (caps.avmdecVersion.map { " \($0)" } ?? ""), hardware: false,
                                 reason: "AV2 has no fast decoder yet: the AVM reference decoder pre-decodes it.",
                                 seekModel: .fromRandomAccessPoint)
        }

        let profileMain = v.chroma == .c420 && v.bitDepth <= 10
        let vtCode: String? = {
            switch v.codec {
            case .h264: return v.chroma == .c420 && v.bitDepth == 8 ? "avc1" : nil
            case .hevc: return v.bitDepth <= 10 ? "hvc1" : nil       // VT decodes 12-bit HEVC in software, 10x slower
            case .av1: return profileMain ? "av01" : nil              // VT is AV1 Main only
            case .prores: return (v.fourCC == "ap4h" || v.fourCC == "ap4x") ? "ap4h" : "apch"
            default: return nil
            }
        }()
        let vtHardware = vtCode.map { caps.vtHardware.contains($0) } ?? false

        // 2. Containers AVFoundation opens, decoded by VideoToolbox in hardware, zero copies.
        if hw, info.isAVFContainer, info.avfDecodable, vtHardware {
            return DecoderChoice(backend: .avfoundation, tool: "AVFoundation (VideoToolbox)", hardware: true,
                                 reason: "Hardware decode, frames go to the GPU without a copy.")
        }
        // Dolby Vision profile 5 (and AV1 profile 10.0) only converts correctly through macOS, from MP4 / MOV.
        if let dv = v.dolbyVision, dv.blCompatibilityID == 0, dv.profile == 5 || dv.profile == 10 {
            if info.isAVFContainer && info.avfDecodable {
                return DecoderChoice(backend: .avfoundation, tool: "AVFoundation (VideoToolbox)", hardware: vtHardware,
                                     reason: "Dolby Vision \(dv.profile) is converted to PQ by macOS.")
            }
            throw PlayerError.dvProfile5InMKV
        }

        guard caps.hasFFmpeg else {
            if info.isAVFContainer && info.avfDecodable {
                return DecoderChoice(backend: .avfoundation, tool: "AVFoundation", hardware: false,
                                     reason: "FFmpeg isn't installed; macOS decodes this file in software.")
            }
            throw PlayerError.missingTool("ffmpeg", PlayerError.ffmpegHint)
        }
        let seek: SeekModel = info.isRawElementaryStream ? .fromStart : .random

        // 3. Hardware decode through FFmpeg for everything AVFoundation can't open (MKV, WebM, TS, IVF…).
        if hw, vtHardware, caps.hasVideoToolboxAccel, [.h264, .hevc, .av1].contains(v.codec), let fmt = vtPixelFormat(v) {
            let name = v.codec.ffmpegName!
            let fallback = v.codec == .av1 ? (caps.ffmpegDecoders.contains("libdav1d") ? "libdav1d" : nil) : name
            return DecoderChoice(backend: .ffmpeg, tool: "ffmpeg \(name) + VideoToolbox", hardware: true, ffmpegDecoder: name,
                                 hwaccel: true, pixelFormat: fmt, softwareFallback: fallback,
                                 reason: info.isAVFContainer ? "Hardware decode through FFmpeg (AVFoundation can't read this file)."
                                     : "Hardware decode; FFmpeg reads the .\(info.url.pathExtension.lowercased()) container.",
                                 seekModel: seek)
        }

        switch v.codec {
        case .av1:
            // 4. AV1 High / Professional (4:4:4, 4:2:2, 12-bit), or no VideoToolbox: dav1d. FFmpeg's own av1 decoder
            // has no software path at all.
            guard caps.ffmpegDecoders.contains("libdav1d") else {
                if caps.ffmpegDecoders.contains("libaom-av1") {
                    return sw("libaom-av1", v, seek, "AV1 in software (libaom; this FFmpeg has no dav1d).")
                }
                throw PlayerError.missingTool("FFmpeg with dav1d", "FFmpeg was built without dav1d; install Homebrew's: \(PlayerError.ffmpegHint)")
            }
            return sw("libdav1d", v, seek, profileMain ? "AV1 in software (dav1d)." : "AV1 \(v.chroma) \(v.bitDepth)-bit is beyond VideoToolbox (Main only): dav1d.")
        case .vvc:
            // 5. H.266: FFmpeg's native decoder (7.1 and newer), else libvvdec.
            if caps.ffmpegDecoders.contains("vvc") { return sw("vvc", v, seek, "H.266 has no hardware decoder; FFmpeg's native VVC decoder.") }
            if caps.ffmpegDecoders.contains("libvvdec") { return sw("libvvdec", v, seek, "H.266 through vvdec.") }
            throw PlayerError.missingTool("FFmpeg 7.1 or newer", "This FFmpeg can't decode H.266. \(PlayerError.ffmpegHint)")
        case .vp9:
            // 6. VP9: FFmpeg's native decoder is faster than libvpx and VideoToolbox's software one.
            if caps.ffmpegDecoders.contains("vp9") { return sw("vp9", v, seek, "VP9 has no hardware decoder on this Mac; FFmpeg's vp9.") }
            if caps.ffmpegDecoders.contains("libvpx-vp9") { return sw("libvpx-vp9", v, seek, "VP9 through libvpx.") }
        case .hevc where v.bitDepth > 10:
            if caps.ffmpegDecoders.contains("hevc") {
                return sw("hevc", v, seek, "12-bit HEVC: VideoToolbox decodes it only in software (about 10x slower than FFmpeg).")
            }
        default:
            break
        }

        // 7. Everything else FFmpeg can decode.
        let name = v.codec.ffmpegName ?? {
            if case .other(let s) = v.codec { return s }
            return v.codec == .rawvideo ? "rawvideo" : nil
        }()
        if let name, caps.ffmpegDecoders.contains(name) || caps.ffmpegDecoders.isEmpty {
            return sw(name, v, seek, hw && vtCode != nil && !vtHardware ? "No hardware decoder for this stream on this Mac."
                                       : hw ? "Software decode (FFmpeg)." : "Software decode (hardware decode is off in Settings).")
        }
        throw PlayerError.unsupportedCodec(v.codec.description)
    }

    private static func sw(_ decoder: String, _ v: VideoInfo, _ seek: SeekModel, _ reason: String) -> DecoderChoice {
        DecoderChoice(backend: .ffmpeg, tool: "ffmpeg \(decoder)", hardware: false, ffmpegDecoder: decoder,
                      pixelFormat: softwarePixelFormat(v), reason: reason, seekModel: seek)
    }

    /// What VideoToolbox hands FFmpeg when frames are downloaded: semi-planar, MSB-aligned for 10-bit.
    static func vtPixelFormat(_ v: VideoInfo) -> String? {
        switch (v.bitDepth, v.chroma) {
        case (8, .c420): return "nv12"
        case (8, .c422): return "nv16"
        case (8, .c444): return "nv24"
        case (10, .c420): return "p010le"
        case (10, .c422): return "p210le"
        case (10, .c444): return "p410le"
        default: return nil
        }
    }

    /// The software decoder's own output format when the player reads it directly, else the nearest lossless one.
    static func softwarePixelFormat(_ v: VideoInfo) -> String {
        if let p = v.pixelFormat {
            if FrameLayout.ffmpeg(p, width: 16, height: 16) != nil { return p }
            if p.hasPrefix("yuva") {                                   // drop alpha
                let stripped = "yuv" + p.dropFirst(4)
                if FrameLayout.ffmpeg(stripped, width: 16, height: 16) != nil { return stripped }
            }
            if p.contains("rgb") || p.contains("bgr") || p.contains("gbr") { return v.bitDepth > 8 ? "gbrp16le" : "gbrp" }
        }
        let suffix = v.bitDepth > 12 ? "16le" : v.bitDepth > 10 ? "12le" : v.bitDepth > 8 ? "10le" : ""
        switch v.chroma {
        case .mono: return v.bitDepth > 8 ? "gray16le" : "gray"
        case .c420: return "yuv420p" + suffix
        case .c422: return "yuv422p" + suffix
        case .c444: return "yuv444p" + suffix
        }
    }
}
