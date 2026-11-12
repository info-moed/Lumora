import Foundation
import Metal

enum ChromaFormat: Int, Codable, CaseIterable, Hashable {
    case c420 = 0, c422 = 1, c444 = 2
    var label: String { ["4:2:0", "4:2:2", "4:4:4"][rawValue] }
    var y4mTag: String { ["420", "422", "444"][rawValue] }
}

/// Output codecs. Lumora outputs 10-bit or 12-bit only, minimum 4:2:0 (8-bit sources are accepted).
enum Codec: String, CaseIterable, Identifiable, Codable, Hashable {
    case hevc, prores422HQ, prores4444XQ, av1, av1Pro, vvc, av2, hevc12

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevc: return "HEVC (H.265) · hardware"
        case .prores422HQ: return "ProRes 422 HQ · hardware"
        case .prores4444XQ: return "ProRes 4444 XQ · hardware"
        case .av1: return "AV1 · SVT-AV1"
        case .av1Pro: return "AV1 12-bit / 4:4:4 · libaom"
        case .vvc: return "H.266 / VVC · VVenC"
        case .av2: return "AV2 · AVM reference (experimental)"
        case .hevc12: return "HEVC · x265 (10/12-bit, archival)"
        }
    }

    var plainEnglish: String {
        switch self {
        case .hevc: return "Plays almost everywhere, small files, very fast on Apple's media engine."
        case .prores422HQ: return "Editing/mastering format. Huge files, perfect quality, fast."
        case .prores4444XQ: return "Top-quality 12-bit master for archives and studio delivery. Enormous files."
        case .av1: return "Smaller than HEVC at the same quality. Great for web and modern TVs; slower to encode."
        case .av1Pro: return "AV1 with 12-bit or full colour. Very slow; for archives, not everyday playback."
        case .vvc: return "Newest broadcast codec, ~30–40% smaller than HEVC. Few players support it yet."
        case .av2: return "Next-gen open codec. Brand new: almost nothing plays it and encoding is extremely slow."
        case .hevc12: return "Software HEVC with full archival tuning. Smaller files than the hardware encoder at the same quality; much slower. 12-bit has limited player support."
        }
    }

    var isHardware: Bool { [.hevc, .prores422HQ, .prores4444XQ].contains(self) }
    var bitDepths: [Int] {
        switch self {
        case .prores4444XQ, .av1Pro, .hevc12: return [12, 10]
        case .av2: return [10, 12]   // 12-bit: experimental in the AVM reference encoder
        default: return [10]
        }
    }
    var chromaFormats: [ChromaFormat] {
        switch self {
        case .prores422HQ: return [.c422]
        case .prores4444XQ: return [.c444]
        case .av1Pro: return [.c420, .c422, .c444]
        case .hevc12: return [.c420, .c422, .c444]
        default: return [.c420]
        }
    }
    /// Key into encoders.json for the software encoders.
    var cliKey: String? {
        switch self {
        case .av1: return "svtav1"
        case .av1Pro: return "aomenc"
        case .vvc: return "vvenc"
        case .av2: return "avm"
        case .hevc12: return "x265"
        default: return nil
        }
    }
    var supportsHDR10Plus: Bool { self == .hevc || self == .hevc12 || self == .av1 }
    var supportsDolbyVision: Bool { self == .hevc }
    var defaultContainer: String {
        switch self {
        case .prores422HQ, .prores4444XQ, .hevc: return "mov"
        case .av2: return "obu"      // no ISO-BMFF binding for AV2 yet
        default: return "mkv"
        }
    }
    var isExperimental: Bool { self == .av2 }

    var available: Bool {
        guard let key = cliKey else { return true }
        return EncoderCatalog.shared.spec(for: key).map { ToolLocator.isAvailable($0.binary) } ?? false
    }
}

/// The HDR (or SDR) format of the delivered file.
enum DeliveryFormat: String, CaseIterable, Identifiable, Codable, Hashable {
    case sdr, hdr10, hdr10Plus, hlg, dolbyVision81, dolbyVision84
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sdr: return "SDR (Rec.709)"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .dolbyVision81: return "Dolby Vision 8.1 (HDR10-compatible)"
        case .dolbyVision84: return "Dolby Vision 8.4 (HLG-compatible, iPhone-style)"
        }
    }

    var plainEnglish: String {
        switch self {
        case .sdr: return "Normal video. Looks right on every screen, but no bright HDR highlights."
        case .hdr10: return "The standard HDR format. Every HDR TV, YouTube, Apple TV, Plex and Infuse handle it."
        case .hdr10Plus: return "HDR10 plus scene-by-scene brightness hints. Samsung TVs and Amazon use it; others fall back to HDR10."
        case .hlg: return "Broadcast-style HDR that still looks decent on non-HDR screens. Great for phones and social media."
        case .dolbyVision81: return "HDR10 plus Dolby's scene-by-scene hints. Best on LG, Sony, TCL, Apple TV; falls back to HDR10 elsewhere."
        case .dolbyVision84: return "What iPhones record. HLG underneath, Dolby Vision on top. Great on Apple devices and Instagram."
        }
    }

    var target: (OutputTarget.Kind, needsHEVC: Bool) {
        switch self {
        case .sdr: return (.sdr, false)
        case .hdr10, .hdr10Plus, .dolbyVision81: return (.hdr10, self != .hdr10)
        case .hlg, .dolbyVision84: return (.hlg, self == .dolbyVision84)
        }
    }

    func supported(by codec: Codec) -> Bool {
        switch self {
        case .hdr10Plus: return codec.supportsHDR10Plus
        // 8.1 is HDR10 plus an RPU that dovi_tool injects after encoding, so x265 HEVC carries it too;
        // 8.4 (HLG-based) is written by the hardware encoder only.
        case .dolbyVision81: return codec.supportsDolbyVision || codec == .hevc12
        case .dolbyVision84: return codec.supportsDolbyVision
        default: return true
        }
    }
}

/// CPU-visible planar 16-bit Y'CbCr frame for the software encoders (unified memory: the GPU writes it,
/// the CPU streams it to the encoder's stdin with no copies in between).
final class PlanarFrame {
    let width: Int, height: Int, bits: Int, chroma: ChromaFormat
    let y: MTLBuffer, cb: MTLBuffer, cr: MTLBuffer

    var chromaWidth: Int { chroma == .c444 ? width : width / 2 }
    var chromaHeight: Int { chroma == .c420 ? height / 2 : height }

    init(device: MTLDevice, width: Int, height: Int, bits: Int, chroma: ChromaFormat) {
        self.width = width; self.height = height; self.bits = bits; self.chroma = chroma
        let cw = chroma == .c444 ? width : width / 2
        let ch = chroma == .c420 ? height / 2 : height
        y = device.makeBuffer(length: width * height * 2, options: .storageModeShared)!
        cb = device.makeBuffer(length: cw * ch * 2, options: .storageModeShared)!
        cr = device.makeBuffer(length: cw * ch * 2, options: .storageModeShared)!
    }

    func write(to handle: FileHandle) throws {
        try handle.write(contentsOf: Data("FRAME\n".utf8))
        for b in [y, cb, cr] {
            try handle.write(contentsOf: Data(bytesNoCopy: b.contents(), count: b.length, deallocator: .none))
        }
    }

    func y4mHeader(fpsNum: Int, fpsDen: Int) -> String {
        let tag = "\(chroma.y4mTag)p\(bits)"
        return "YUV4MPEG2 W\(width) H\(height) F\(fpsNum):\(fpsDen) Ip A1:1 C\(tag) XYSCSS=\(tag.uppercased())\n"
    }
}
