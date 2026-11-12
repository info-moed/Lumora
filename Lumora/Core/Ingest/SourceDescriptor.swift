import Foundation
import AVFoundation

enum SourceKind: String, Codable, Hashable {
    case avfoundation   // MOV/MP4/M4V incl. ProRes, ProRes RAW, HEVC, H.264, AV1 (decode), Dolby Vision
    case ffmpeg         // MKV, WebM, AVI, MXF, TS, VVC, AV2 (dav2d), anything else FFmpeg reads
    case rawSequence    // DNG / CinemaDNG / camera RAW stills via Core Image's RAW pipeline
    case vendorRAW      // BRAW, R3D, ARRIRAW, Canon RAW via vendor SDK plug-ins
}

/// Interlaced and telecined sources (DVD, broadcast, many Blu-ray extras) must be fixed before grading,
/// upscaling or interpolation, or combing and judder get baked in.
enum ScanFix: String, Codable, CaseIterable, Hashable {
    case none, deinterlace, deinterlaceDouble, inverseTelecine
    var displayName: String {
        switch self {
        case .none: return "Progressive (no fix)"
        case .deinterlace: return "Deinterlace (same frame rate)"
        case .deinterlaceDouble: return "Deinterlace to double rate (smoother motion)"
        case .inverseTelecine: return "Inverse telecine (restore 24p film)"
        }
    }
    var ffmpegFilter: String? {
        switch self {
        case .none: return nil
        case .deinterlace: return "bwdif=mode=send_frame:deint=interlaced"
        case .deinterlaceDouble: return "bwdif=mode=send_field:deint=interlaced"
        case .inverseTelecine: return "fieldmatch,bwdif=deint=interlaced,decimate"
        }
    }
}

/// What the inspector learned about a source.
struct SourceDescriptor: Hashable {
    var url: URL
    var kind: SourceKind
    var files: [URL] = []            // for RAW sequences
    var width = 0
    var height = 0
    var fpsNum = 24
    var fpsDen = 1
    var frameCount = 0
    var codec = "?"
    var bitDepth: Int?
    var primariesTag: String?
    var transferTag: String?
    var matrixTag: String?
    var logTag: String?
    var isDolbyVision = false
    var dvProfile: Int?              // 5, 7, 8 … (from the Dolby Vision configuration record)
    var dvHasEnhancementLayer = false
    var make: String?
    var model: String?
    var hasAudio = false
    var fieldOrder: String?
    var scanFix: ScanFix = .none
    var suggestedScanFix: ScanFix = .none
    var originalKind: SourceKind?
    var originalFpsNum = 24
    var originalFpsDen = 1
    var originalFrameCount = 0
    var crop = SIMD4<Float>(0, 0, 1, 1)   // black bars removed (uv origin + size)
    var outputWidth: Int { Int(Float(width) * crop.z) & ~1 }
    var outputHeight: Int { Int(Float(height) * crop.w) & ~1 }

    var fps: Double { Double(fpsNum) / Double(fpsDen) }
    var durationSeconds: Double { Double(frameCount) / fps }
    var isHDRSource: Bool {
        isDolbyVision || [transferTag].compactMap { $0 }.contains { $0.contains("2084") || $0.contains("HLG") }
    }

    var summary: String {
        var parts = ["\(width)×\(height)", String(format: "%.3g fps", fps), codec]
        if let b = bitDepth { parts.append("\(b)-bit") }
        if isDolbyVision { parts.append("Dolby Vision") }
        if suggestedScanFix != .none { parts.append(suggestedScanFix == .inverseTelecine ? "telecined" : "interlaced") }
        if let m = model { parts.append(m) }
        return parts.joined(separator: " · ")
    }

    /// Returns a copy that decodes with the scan fix applied (frame rate and count adjusted to match).
    /// Always computed from the file's original timing, so fixes can be switched freely.
    func applying(_ fix: ScanFix) -> SourceDescriptor {
        var d = self
        if d.originalKind == nil {
            d.originalKind = kind; d.originalFpsNum = fpsNum; d.originalFpsDen = fpsDen; d.originalFrameCount = frameCount
        }
        let fps = Double(d.originalFpsNum) / Double(d.originalFpsDen)
        d.kind = fix == .none ? d.originalKind! : .ffmpeg
        d.scanFix = fix
        switch fix {
        case .inverseTelecine:
            (d.fpsNum, d.fpsDen) = rationalFrameRate(fps * 4 / 5); d.frameCount = d.originalFrameCount * 4 / 5
        case .deinterlaceDouble:
            (d.fpsNum, d.fpsDen) = rationalFrameRate(fps * 2); d.frameCount = d.originalFrameCount * 2
        default:
            (d.fpsNum, d.fpsDen) = (d.originalFpsNum, d.originalFpsDen); d.frameCount = d.originalFrameCount
        }
        return d
    }

    func makeFrameSource(highPrecision: Bool = false) async throws -> FrameSource {
        switch kind {
        case .avfoundation:
            let s = AVFoundationFrameSource(url: url,
                                            convertDolbyVisionToPQ: isDolbyVision && transferTag?.contains("HLG") != true,
                                            highPrecision: highPrecision)
            try await s.prepare()
            return s
        case .ffmpeg:
            return try FFmpegFrameSource(descriptor: self)
        case .rawSequence:
            return try RAWSequenceFrameSource(files: files, fps: fps)
        case .vendorRAW:
            guard let plugin = VendorRAWRegistry.plugin(for: url) else {
                throw LumoraError.needsVendorSDK(url.pathExtension)
            }
            return try plugin.makeFrameSource(url: url)
        }
    }
}

/// Converts a float frame rate to the usual broadcast rationals. Rates outside 1…1000 fps (or NaN) come from
/// broken or hostile files; they are treated as unknown (24 fps) rather than overflowing timescales later.
/// Frames in `seconds` at `fps`, safe against NaN, infinity, negative and absurd values (capped at ~10 M frames,
/// which is 46 hours at 60 fps). Never traps.
func safeFrameCount(seconds: Double, fps: Double) -> Int {
    let v = seconds * fps
    guard v.isFinite, v >= 1 else { return 1 }
    return Int(min(v.rounded(), 10_000_000))
}

/// The frame index for a timestamp, safe against invalid timestamps.
func safeFrameIndex(seconds: Double, fps: Double) -> Int {
    let v = seconds * fps
    guard v.isFinite, v >= 0 else { return 0 }
    return Int(min(v.rounded(), 10_000_000))
}

func rationalFrameRate(_ fps: Double) -> (Int, Int) {
    guard fps.isFinite, fps >= 1, fps <= 1000 else { return (24, 1) }
    let known: [(Double, Int, Int)] = [(23.976, 24000, 1001), (29.97, 30000, 1001), (59.94, 60000, 1001),
                                       (119.88, 120000, 1001), (47.952, 48000, 1001)]
    for (f, n, d) in known where abs(fps - f) < 0.01 { return (n, d) }
    let r = Int(fps.rounded())
    return abs(fps - Double(r)) < 0.01 ? (r, 1) : (Int((fps * 1000).rounded()), 1000)
}
