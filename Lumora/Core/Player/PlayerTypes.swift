import Foundation
import CoreVideo
import Metal

// Types shared by the built-in player: what a file is (MediaInfo), how its signal is coded (SignalColor), and the
// frames the decoders hand to the renderer (PlayerFrame).

enum PlayerCodec: Hashable, CustomStringConvertible {
    case h264, hevc, av1, av2, vvc, vp9, vp8, prores, ffv1, rawvideo, mpeg2, other(String)

    var description: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .av2: return "AV2"
        case .vvc: return "H.266 / VVC"
        case .vp9: return "VP9"
        case .vp8: return "VP8"
        case .prores: return "ProRes"
        case .ffv1: return "FFV1"
        case .rawvideo: return "Uncompressed"
        case .mpeg2: return "MPEG-2"
        case .other(let s): return s
        }
    }

    /// FFmpeg's codec_name.
    static func ffmpeg(_ name: String) -> PlayerCodec {
        switch name {
        case "h264": return .h264
        case "hevc": return .hevc
        case "av1": return .av1
        case "vvc", "h266": return .vvc
        case "vp9": return .vp9
        case "vp8": return .vp8
        case "prores": return .prores
        case "ffv1": return .ffv1
        case "rawvideo", "wrapped_avframe": return .rawvideo
        case "mpeg2video", "mpeg1video": return .mpeg2
        default: return .other(name)
        }
    }

    /// QuickTime / ISO sample-entry four-character code.
    static func fourCC(_ code: String) -> PlayerCodec {
        switch code {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1", "dvh1", "dvhe": return .hevc
        case "av01", "dav1": return .av1
        case "vvc1", "vvi1": return .vvc
        case "vp09": return .vp9
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return .prores
        default: return .other(code)
        }
    }

    /// The name FFmpeg's decoder for this codec goes by, when it has a dedicated one.
    var ffmpegName: String? {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .av1: return "av1"
        case .vvc: return "vvc"
        case .vp9: return "vp9"
        case .vp8: return "vp8"
        case .prores: return "prores"
        case .ffv1: return "ffv1"
        case .mpeg2: return "mpeg2video"
        default: return nil
        }
    }
}

enum PlayerChroma: Int, Codable, CustomStringConvertible {
    case mono, c420, c422, c444
    var description: String { ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][rawValue] }
    /// Horizontal and vertical subsampling factors.
    var subsampling: (Int, Int) {
        switch self {
        case .c420: return (2, 2)
        case .c422: return (2, 1)
        default: return (1, 1)
        }
    }
}

/// Where chroma samples sit relative to luma (H.273 ChromaSampleLocType order).
enum ChromaLocation: Int, Codable, CaseIterable, CustomStringConvertible {
    case left = 0, center, topLeft, top, bottomLeft, bottom, unknown

    var description: String {
        ["left", "center", "top-left", "top", "bottom-left", "bottom", "unknown"][rawValue]
    }

    /// FFmpeg's chroma_location strings.
    static func ffmpeg(_ s: String?) -> ChromaLocation {
        switch s {
        case "left": return .left
        case "center": return .center
        case "topleft": return .topLeft
        case "top": return .top
        case "bottomleft": return .bottomLeft
        case "bottom": return .bottom
        default: return .unknown
        }
    }

    /// CoreMedia's kCMFormatDescriptionExtension_ChromaLocationTopField values.
    static func coreMedia(_ s: String?) -> ChromaLocation {
        switch s {
        case "Left": return .left
        case "Center": return .center
        case "TopLeft": return .topLeft
        case "Top": return .top
        case "BottomLeft": return .bottomLeft
        case "Bottom": return .bottom
        default: return .unknown
        }
    }

    /// Offset added to (luma coordinate × 1/subsampling) to land on the chroma plane, for one axis.
    /// Co-sited samples sit on the first luma sample of their group; centered ones between them.
    func offset(horizontal: Bool, subsampling s: Int) -> Float {
        guard s > 1 else { return 0 }
        let cosited = 0.5 - 0.5 / Float(s)
        if horizontal {
            switch self {
            case .left, .topLeft, .bottomLeft, .unknown: return cosited
            default: return 0
            }
        }
        switch self {
        case .topLeft, .top: return cosited
        case .bottomLeft, .bottom: return -cosited
        default: return 0
        }
    }
}

/// How the picture's signal is coded, as CICP code points (ITU-T H.273), plus which values were tagged in the
/// file and which Lumora had to guess.
struct SignalColor: Equatable, Codable {
    var primaries = 2          // 2 = unspecified
    var transfer = 2
    var matrix = 2
    var fullRange = false
    var chromaLocation = ChromaLocation.unknown
    var primariesTagged = false
    var transferTagged = false
    var matrixTagged = false
    var rangeTagged = false
    var chromaLocationTagged = false

    static func isRGBMatrix(_ m: Int) -> Bool { m == 0 }

    /// Fills in whatever the file left unspecified (or got wrong) with the conventions players follow.
    mutating func resolve(height: Int, chroma: PlayerChroma) {
        let hdrTransfer = transfer == 16 || transfer == 18
        if !matrixTagged || matrix == 2 || matrix == 3 || (Self.isRGBMatrix(matrix) && chroma != .c444 && chroma != .mono) {
            // An RGB matrix on subsampled video is impossible (some muxers write it by mistake): guess instead.
            matrix = (primaries == 9 || hdrTransfer) ? 9 : (height >= 720 ? 1 : 6)
            matrixTagged = false
        }
        if !primariesTagged || primaries == 2 || primaries == 0 || primaries == 3 {
            primaries = (matrix == 9 || matrix == 10 || hdrTransfer) ? 9 : (height >= 720 ? 1 : (height == 576 ? 5 : 6))
            primariesTagged = false
        }
        if !transferTagged || transfer == 2 || transfer == 0 || transfer == 3 {
            transfer = 1
            transferTagged = false
        }
        if chromaLocation == .unknown {
            chromaLocation = .left        // the MPEG default for 4:2:0
            chromaLocationTagged = false
        }
    }

    var primariesName: String {
        switch primaries {
        case 1: return "BT.709"
        case 4: return "BT.470 M"
        case 5: return "BT.601 625"
        case 6, 7: return "BT.601 525"
        case 9: return "BT.2020"
        case 10: return "XYZ"
        case 11: return "DCI-P3"
        case 12: return "Display P3"
        case 22: return "EBU 3213"
        default: return "code \(primaries)"
        }
    }

    var transferName: String {
        switch transfer {
        case 1, 6, 14, 15: return "SDR (BT.1886)"
        case 4: return "Gamma 2.2"
        case 5: return "Gamma 2.8"
        case 8: return "Linear"
        case 13: return "sRGB"
        case 16: return "PQ (SMPTE ST 2084)"
        case 18: return "HLG (BT.2100)"
        default: return "code \(transfer)"
        }
    }

    var matrixName: String {
        switch matrix {
        case 0: return "GBR (RGB)"
        case 1: return "BT.709"
        case 5, 6: return "BT.601"
        case 7: return "SMPTE 240M"
        case 8: return "YCgCo"
        case 9: return "BT.2020 NCL"
        case 10: return "BT.2020 CL (shown as NCL)"
        case 14: return "ICtCp (shown as BT.2020 NCL)"
        default: return "code \(matrix)"
        }
    }

    var isHDR: Bool { transfer == 16 || transfer == 18 }

    /// Lumora's gamut for these primaries, for ColorScience.matrix(from:to:).
    var gamut: Gamut {
        switch primaries {
        case 9: return .rec2020
        case 11, 12: return .p3d65
        default: return .rec709
        }
    }
}

/// HDR10 static metadata.
struct HDRStatic: Equatable, Codable {
    var mdcvMaxNits: Double?
    var mdcvMinNits: Double?
    /// Display primaries as (x, y) for R, G, B, then the white point.
    var mdcvPrimaries: [Double]?
    var maxCLL: Double?
    var maxFALL: Double?

    var isEmpty: Bool { mdcvMaxNits == nil && maxCLL == nil }
}

struct DolbyVisionInfo: Equatable, Codable {
    var profile: Int
    var level: Int
    var blCompatibilityID: Int
    var hasEnhancementLayer: Bool

    var summary: String {
        let name = blCompatibilityID > 0 ? "\(profile).\(blCompatibilityID)" : "\(profile)"
        switch profile {
        case 5: return "Dolby Vision \(name): converted to PQ by macOS"
        case 7: return "Dolby Vision \(name): playing the HDR10 base layer" + (hasEnhancementLayer ? ", enhancement layer ignored" : "")
        case 8, 9: return "Dolby Vision \(name): playing the \(blCompatibilityID == 4 ? "HLG" : blCompatibilityID == 2 ? "SDR" : "HDR10") base layer"
        case 10: return "Dolby Vision \(name) (AV1): " + (blCompatibilityID == 0 ? "converted to PQ by macOS" : "playing the base layer")
        default: return "Dolby Vision \(name): playing the base layer"
        }
    }
}

struct VideoInfo: Equatable {
    var codec: PlayerCodec = .other("?")
    var profile: String?
    var fourCC: String?
    var width = 0
    var height = 0
    var sarNum = 1
    var sarDen = 1
    var bitDepth = 8
    var chroma = PlayerChroma.c420
    var pixelFormat: String?            // FFmpeg pix_fmt, when FFmpeg read the file
    var color = SignalColor()
    var hdr: HDRStatic?
    var dolbyVision: DolbyVisionInfo?
    var hdr10Plus = false
    /// The alternative transfer characteristics SEI (e.g. 18 for HLG carried as BT.2020 SDR).
    var alternativeTransfer: Int?

    var displayAspect: Double {
        guard height > 0 else { return 16.0 / 9 }
        let sar = sarNum > 0 && sarDen > 0 ? Double(sarNum) / Double(sarDen) : 1
        return Double(width) * min(4, max(0.25, sar)) / Double(height)
    }
}

struct AudioInfo: Equatable, Identifiable {
    var id: Int { index }
    var index: Int                       // n in -map 0:a:n
    var codec: String
    var channels: Int
    var sampleRate: Int
    var language: String?

    var label: String {
        let ch = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) ch"
        return [language?.uppercased(), codec.uppercased(), ch].compactMap { $0 }.joined(separator: " · ")
    }
}

/// AV2-specific facts read from the stream itself (FFmpeg can't read AV2).
struct AV2Details: Equatable {
    var temporalUnits: Int
    /// Frame index of each random access point (temporal unit with a sequence header), ascending.
    var randomAccessPoints: [Int]
    var sampleBytes: Int                 // avmdec output bytes per sample
}

struct MediaInfo: Equatable {
    var url: URL
    var container: String                // file extension or FFmpeg's format name
    var isRawElementaryStream = false
    var duration: Double = 0
    var rateNum = 24
    var rateDen = 1
    var frameRateKnown = true
    var frameCount: Int?
    var video = VideoInfo()
    var audio: [AudioInfo] = []
    var notes: [String] = []
    /// AVFoundation opened the file and can decode its video track.
    var avfDecodable = false
    var av2: AV2Details?
    var fileSize: Int64 = 0
    /// The peak Lumora graded this file to, from its export record (AV2 can't carry mastering metadata).
    var manifestPeakNits: Double?
    /// The container's first video timestamp (FFmpeg's start_time), for exact seeks with -copyts.
    var startTime: Double = 0

    var fps: Double { Double(rateNum) / Double(max(1, rateDen)) }
    var estimatedFrameCount: Int { frameCount ?? safeFrameCount(seconds: duration, fps: fps) }
    var isAVFContainer: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
}

// MARK: Frames

/// How a frame's samples are laid out, enough for the player kernel to read them.
struct FrameLayout: Equatable {
    enum Storage: Int { case biplanarTexture = 0, semiPlanarBuffer = 1, planarBuffer = 2, rgbaTexture = 3 }
    var storage: Storage
    var width: Int
    var height: Int
    var chroma: PlayerChroma
    var sampleBytes: Int                 // 1 or 2
    var bits: Int                        // significant bits
    var msbAligned: Bool
    var strides: [Int] = [0, 0, 0]
    var offsets: [Int] = [0, 0, 0]
    var frameBytes = 0
    /// The kernel should treat the planes as G, B, R (MatrixCoefficients 0) regardless of the stream's tag.
    var forcesGBR = false
    var forcesFullRange = false

    var chromaWidth: Int { chroma == .mono ? 0 : (width + chroma.subsampling.0 - 1) / chroma.subsampling.0 }
    var chromaHeight: Int { chroma == .mono ? 0 : (height + chroma.subsampling.1 - 1) / chroma.subsampling.1 }

    /// Planar (three planes, or one for monochrome) tightly packed, as FFmpeg's rawvideo and avmdec write them.
    static func planar(width: Int, height: Int, chroma: PlayerChroma, sampleBytes: Int, bits: Int, msbAligned: Bool = false) -> FrameLayout {
        var l = FrameLayout(storage: .planarBuffer, width: width, height: height, chroma: chroma, sampleBytes: sampleBytes,
                            bits: bits, msbAligned: msbAligned)
        let y = width * sampleBytes, c = l.chromaWidth * sampleBytes
        l.strides = [y, c, c]
        l.offsets = [0, y * height, y * height + c * l.chromaHeight]
        l.frameBytes = y * height + 2 * c * l.chromaHeight
        return l
    }

    /// One luma plane and one interleaved CbCr plane (nv12, p010…).
    static func semiPlanar(width: Int, height: Int, chroma: PlayerChroma, sampleBytes: Int, bits: Int, msbAligned: Bool) -> FrameLayout {
        var l = FrameLayout(storage: .semiPlanarBuffer, width: width, height: height, chroma: chroma, sampleBytes: sampleBytes,
                            bits: bits, msbAligned: msbAligned)
        let y = width * sampleBytes, c = 2 * l.chromaWidth * sampleBytes
        l.strides = [y, c, 0]
        l.offsets = [0, y * height, 0]
        l.frameBytes = y * height + c * l.chromaHeight
        return l
    }

    /// The layout of an FFmpeg rawvideo pixel format, or nil when the player doesn't read that format directly.
    static func ffmpeg(_ pixFmt: String, width: Int, height: Int) -> FrameLayout? {
        func depth(_ s: String) -> Int { s.contains("16") ? 16 : s.contains("14") ? 14 : s.contains("12") ? 12 : s.contains("10") ? 10 : s.contains("9") ? 9 : 8 }
        switch pixFmt {
        case "nv12": return semiPlanar(width: width, height: height, chroma: .c420, sampleBytes: 1, bits: 8, msbAligned: false)
        case "nv16": return semiPlanar(width: width, height: height, chroma: .c422, sampleBytes: 1, bits: 8, msbAligned: false)
        case "nv24": return semiPlanar(width: width, height: height, chroma: .c444, sampleBytes: 1, bits: 8, msbAligned: false)
        case "p010le": return semiPlanar(width: width, height: height, chroma: .c420, sampleBytes: 2, bits: 10, msbAligned: true)
        case "p012le": return semiPlanar(width: width, height: height, chroma: .c420, sampleBytes: 2, bits: 12, msbAligned: true)
        case "p016le": return semiPlanar(width: width, height: height, chroma: .c420, sampleBytes: 2, bits: 16, msbAligned: false)
        case "p210le": return semiPlanar(width: width, height: height, chroma: .c422, sampleBytes: 2, bits: 10, msbAligned: true)
        case "p212le": return semiPlanar(width: width, height: height, chroma: .c422, sampleBytes: 2, bits: 12, msbAligned: true)
        case "p410le": return semiPlanar(width: width, height: height, chroma: .c444, sampleBytes: 2, bits: 10, msbAligned: true)
        case "p412le": return semiPlanar(width: width, height: height, chroma: .c444, sampleBytes: 2, bits: 12, msbAligned: true)
        default: break
        }
        let fmt = pixFmt.hasPrefix("yuvj") ? "yuv" + pixFmt.dropFirst(4) : pixFmt
        if fmt.hasPrefix("gray") {
            let b = depth(fmt)
            guard b == 8 || fmt.hasSuffix("le") else { return nil }
            return planar(width: width, height: height, chroma: .mono, sampleBytes: b > 8 ? 2 : 1, bits: b)
        }
        if fmt.hasPrefix("gbrp") {
            let b = depth(String(fmt.dropFirst(4)))
            guard b == 8 || fmt.hasSuffix("le") else { return nil }
            var l = planar(width: width, height: height, chroma: .c444, sampleBytes: b > 8 ? 2 : 1, bits: b)
            l.forcesGBR = true
            return l
        }
        for (prefix, chroma) in [("yuv420p", PlayerChroma.c420), ("yuv422p", .c422), ("yuv444p", .c444)] where fmt.hasPrefix(prefix) {
            let rest = String(fmt.dropFirst(prefix.count))
            guard rest.isEmpty || rest.hasSuffix("le") else { return nil }
            let b = rest.isEmpty ? 8 : depth(rest)
            var l = planar(width: width, height: height, chroma: chroma, sampleBytes: b > 8 ? 2 : 1, bits: b)
            if pixFmt.hasPrefix("yuvj") { l.forcesFullRange = true }
            return l
        }
        return nil
    }
}

/// A reusable shared-memory buffer for one decoded frame. Returned to its pool when the last reference goes away.
final class PooledBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    weak var pool: BufferPool?
    init(buffer: MTLBuffer, pool: BufferPool?) { self.buffer = buffer; self.pool = pool }
    var bytes: UnsafeMutableRawPointer { buffer.contents() }
    var capacity: Int { buffer.length }
    deinit { pool?.recycle(buffer) }
}

/// Fixed set of MTLBuffers of one size. `acquire` blocks while all of them are in use, which is the decoder's
/// back-pressure: a decode thread can never run further ahead than the pool allows.
final class BufferPool: @unchecked Sendable {
    let length: Int
    let capacity: Int
    private let device: MTLDevice
    private let cond = NSCondition()
    private var free: [MTLBuffer] = []
    private var created = 0
    private var closed = false

    init(device: MTLDevice, length: Int, capacity: Int) {
        self.device = device
        self.length = max(16, length)
        self.capacity = max(2, capacity)
    }

    /// nil when the pool was closed (the player stopped) while waiting.
    func acquire() -> PooledBuffer? {
        cond.lock()
        defer { cond.unlock() }
        while free.isEmpty && created >= capacity && !closed { cond.wait() }
        if closed { return nil }
        if let b = free.popLast() { return PooledBuffer(buffer: b, pool: self) }
        guard let b = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        created += 1
        return PooledBuffer(buffer: b, pool: self)
    }

    fileprivate func recycle(_ b: MTLBuffer) {
        cond.lock()
        free.append(b)
        cond.signal()
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    var inUse: Int {
        cond.lock(); defer { cond.unlock() }
        return created - free.count
    }
}

enum FramePlanes {
    case pixelBuffer(CVPixelBuffer)
    case buffer(PooledBuffer)
}

struct PlayerFrame {
    let index: Int
    let pts: Double
    let layout: FrameLayout
    let planes: FramePlanes
    let color: SignalColor
}
