import Foundation
import simd

/// Everything a user (or the auto-preset engine) can dial in. Target-agnostic: the same params
/// render to HDR10, HLG or SDR.
struct GradeParams: Codable, Hashable {
    var exposureStops: Float = 0
    var temperature: Float = 0      // -1 (cool) ... +1 (warm)
    var tint: Float = 0             // -1 (green) ... +1 (magenta)
    var midGreyStops: Float = 0     // moves where mid gray lands on the display
    var contrast: Float = 1.0
    var toe: Float = 0.2
    var shoulder: Float = 2.0
    var localContrast: Float = 0.1
    var saturation: Float = 1.0
    var vibrance: Float = 0.1
    var skinProtect: Float = 1.0
    var highlightDesat: Float = 0.35
    var highlightExpansion: Float = 5.0  // SDR->HDR, or adding punch to a dim HDR master
    var expandHDRSources = false          // "Rip revive": also expand highlights of HDR sources
    var deband: Float = 0                 // 0 = off ... 1 = strong (for compressed sources: rips, phone video)
    var edgeProtection: Float = 0.5       // punch filter: 0 = classic clarity, 1 = strongly edge-aware (no halos)
    var matchCurve: [Float]? = nil        // reference-match correction (stops over log2 nits), from ReferenceMatcher
    var passthrough = false               // "Keep original look": no regrade for HDR/SDR masters (e.g. interpolate only)

    static let neutral = GradeParams(contrast: 1, toe: 0, shoulder: 2, localContrast: 0,
                                     saturation: 1, vibrance: 0, skinProtect: 0, highlightDesat: 0,
                                     highlightExpansion: 0)
}

/// The looks the auto-preset engine starts from before adapting them to the footage.
enum Look: String, CaseIterable, Codable, Hashable {
    case original, natural, punchy, superPunchy, cinematic, brightClean, moody, ripRevive

    var displayName: String {
        switch self {
        case .original: return "Keep original look"
        case .natural: return "Natural"
        case .punchy: return "Punchy"
        case .superPunchy: return "Super Punchy"
        case .cinematic: return "Cinematic"
        case .brightClean: return "Bright & Clean"
        case .moody: return "Moody"
        case .ripRevive: return "Rip Revive"
        }
    }

    var params: GradeParams {
        switch self {
        case .original:
            var p = GradeParams.neutral
            p.passthrough = true
            return p
        case .natural:
            return GradeParams(midGreyStops: 0, contrast: 1.00, toe: 0.15, shoulder: 2.0, localContrast: 0.08,
                               saturation: 1.00, vibrance: 0.12, skinProtect: 1.0, highlightDesat: 0.35)
        case .punchy:
            return GradeParams(midGreyStops: 0.15, contrast: 1.16, toe: 0.45, shoulder: 2.6, localContrast: 0.30,
                               saturation: 1.05, vibrance: 0.35, skinProtect: 0.9, highlightDesat: 0.22)
        case .superPunchy:
            return GradeParams(midGreyStops: 0.20, contrast: 1.26, toe: 0.55, shoulder: 3.0, localContrast: 0.45,
                               saturation: 1.08, vibrance: 0.50, skinProtect: 0.85, highlightDesat: 0.15)
        case .cinematic:
            return GradeParams(midGreyStops: -0.2, contrast: 1.08, toe: 0.30, shoulder: 1.6, localContrast: 0.15,
                               saturation: 0.95, vibrance: 0.15, skinProtect: 1.0, highlightDesat: 0.50)
        case .brightClean:
            return GradeParams(midGreyStops: 0.35, contrast: 0.98, toe: 0.08, shoulder: 2.2, localContrast: 0.12,
                               saturation: 1.02, vibrance: 0.22, skinProtect: 1.0, highlightDesat: 0.30)
        case .moody:
            return GradeParams(midGreyStops: -0.45, contrast: 1.22, toe: 0.60, shoulder: 1.8, localContrast: 0.25,
                               saturation: 0.90, vibrance: 0.10, skinProtect: 1.0, highlightDesat: 0.45)
        case .ripRevive:
            // For dim/flat HDR masters: keep the colorist's mid-tones, rebuild highlights, add clarity.
            return GradeParams(midGreyStops: 0.05, contrast: 1.06, toe: 0.25, shoulder: 2.8, localContrast: 0.22,
                               saturation: 1.03, vibrance: 0.25, skinProtect: 1.0, highlightDesat: 0.2,
                               highlightExpansion: 3.0, expandHDRSources: true)
        }
    }

    /// How strongly each scene is pulled toward a common brightness (0 = keep the source's scene-to-scene
    /// variation, 1 = flatten it). Natural keeps night scenes dark; Punchy evens things out more.
    var sceneNormalization: Float {
        switch self {
        case .original: return 0
        case .natural: return 0.5
        case .punchy, .superPunchy: return 0.65
        case .cinematic: return 0.35
        case .brightClean: return 0.6
        case .moody: return 0.25
        case .ripRevive: return 0.0   // never re-balance a finished film's scene-to-scene exposure
        }
    }
}

struct OutputTarget: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case hdr10, hlg, sdr }
    var kind: Kind
    var peakNits: Float

    static let hdr10_1000 = OutputTarget(kind: .hdr10, peakNits: 1000)
    static let hdr10_2000 = OutputTarget(kind: .hdr10, peakNits: 2000)
    static let hdr10_4000 = OutputTarget(kind: .hdr10, peakNits: 4000)
    static let hlg = OutputTarget(kind: .hlg, peakNits: 1000)
    static let sdr = OutputTarget(kind: .sdr, peakNits: 100)
    static let all: [OutputTarget] = [.hdr10_1000, .hdr10_2000, .hdr10_4000, .hlg, .sdr]

    var displayName: String {
        switch kind {
        case .hdr10: return "HDR10 · \(Int(peakNits)) nits"
        case .hlg: return "HLG"
        case .sdr: return "SDR Rec.709"
        }
    }
    var outputGamut: Gamut { kind == .sdr ? .rec709 : .rec2020 }
    var effectivePeak: Float { kind == .sdr ? 100 : (kind == .hlg ? 1000 : peakNits) }
    /// Scene 0.18 placement. HDR: ~26 nits (BT.2408 graphics white at 203). SDR: ~18% of 100 nits.
    var baseMidGreyNits: Float { kind == .sdr ? 18 : 26 }
    var shaderOutput: Int32 {
        switch kind { case .hdr10: return OUT_PQ; case .hlg: return OUT_HLG; case .sdr: return OUT_SDR }
    }
    var isHDR: Bool { kind != .sdr }
}

/// How the incoming signal is interpreted. The inspector proposes ranked candidates.
struct SourceColor: Codable, Hashable, Identifiable {
    var name: String
    var transfer: Transfer
    var gamut: Gamut
    var legalToFull: Bool
    var confidence: Float
    var note: String? = nil
    var id: String { name }
}

enum UniformBuilder {
    /// `sourcePeakNits`: measured brightest highlights of an HDR source (from the HDR Report Card).
    static let fullFrame = SIMD4<Float>(0, 0, 1, 1)

    /// - crop: region of the decoded frame to use (black bars removed), uv origin + size.
    /// - ditherBits: output bit depth for TPDF dithering (nil = no dither, e.g. preview).
    static func make(source: SourceColor, params: GradeParams, target: OutputTarget,
                     sceneExposureStops: Float, viewport: SIMD4<Float>, split: Float = 0,
                     sourcePeakNits: Float = 1000, crop: SIMD4<Float> = fullFrame,
                     ditherBits: Int? = nil, frameSeed: Int = 0, falseColor: Bool = false) -> GradeUniforms {
        var u = GradeUniforms()
        u.inputToWorking = ColorScience.matrix(from: source.gamut, to: .rec2020)
        u.workingToOutput = ColorScience.matrix(from: .rec2020, to: target.outputGamut)
        u.workingToXYZ = ColorScience.toXYZ(.rec2020)
        u.xyzToWorking = ColorScience.fromXYZ(.rec2020)
        u.outputToXYZ = ColorScience.toXYZ(target.outputGamut)
        u.sourceRect = crop

        var gain = SIMD3<Float>(powf(2, params.temperature * 0.5),
                                powf(2, -params.tint * 0.3),
                                powf(2, -params.temperature * 0.5))
        gain /= simd_dot(gain, ColorScience.luma2020)
        u.wbGain = SIMD4<Float>(gain, 1)
        u.outputLuma = SIMD4<Float>(ColorScience.luma(target.outputGamut), 0)
        u.viewport = viewport

        u.exposure = powf(2, params.exposureStops + sceneExposureStops)
        u.midGreyNits = target.baseMidGreyNits * powf(2, params.midGreyStops)
        u.peakNits = target.effectivePeak
        u.contrast = params.contrast
        u.toe = params.toe
        u.shoulder = params.shoulder
        u.localContrast = params.localContrast
        u.saturation = params.saturation
        u.vibrance = params.vibrance
        u.skinProtect = params.skinProtect
        u.highlightDesat = params.highlightDesat
        u.blackNits = target.isHDR ? 0.005 : 0.05
        if source.transfer.isSDR && target.isHDR {
            u.highlightExpansion = params.highlightExpansion
            u.expansionKnee = 0.72
            u.expansionCeiling = 1.0
        } else if (source.transfer == .pq || source.transfer == .hlg) && params.expandHDRSources && target.isHDR {
            // Decoded HDR is nits/144 in scene-linear terms. Expand above ~100 nits up to the source's own peak,
            // so a master that tops out at 300-500 nits regains highlights that reach the new target peak.
            u.highlightExpansion = params.highlightExpansion
            u.expansionKnee = 100.0 / 144.0
            u.expansionCeiling = max(sourcePeakNits, 150) / 144.0
        }
        u.split = split
        u.inputTransfer = source.transfer.shaderID
        u.outputTransfer = target.shaderOutput
        u.legalToFull = source.legalToFull ? 1 : 0
        u.gamutCompress = 1
        if let bits = ditherBits { u.ditherAmplitude = 1 / (powf(2, Float(bits)) - 1) }
        u.debandThreshold = params.deband * 0.006           // ~6 ten-bit code values at full strength
        u.debandRadius = 8 + params.deband * 16
        u.guidedEpsilon = 0.01 + (1 - params.edgeProtection) * 0.5
        u.falseColor = falseColor ? 1 : 0
        u.frameSeed = Int32(frameSeed & 0xFFFF)
        u.passthrough = params.passthrough ? 1 : 0
        if let curve = params.matchCurve, curve.count >= 2 {
            let n = min(64, curve.count)
            u.matchCurveSize = Int32(n)
            withUnsafeMutableBytes(of: &u.matchCurve) { raw in
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<n { p[i] = curve[i] }
            }
        }
        return u
    }

    /// Decode-only uniforms used for analysis (no exposure, no look).
    static func analysis(source: SourceColor, gridW: Int, gridH: Int, crop: SIMD4<Float> = fullFrame) -> GradeUniforms {
        make(source: source, params: .neutral, target: .sdr, sceneExposureStops: 0,
             viewport: SIMD4<Float>(0, 0, Float(gridW), Float(gridH)), crop: crop)
    }
}
