import simd

/// Color primaries Lumora understands. All are D65-white, so no chromatic adaptation is needed.
enum Gamut: String, Codable, CaseIterable, Hashable {
    case rec709, p3d65, rec2020, sGamut3Cine, arriWideGamut3, arriWideGamut4, vGamut, appleWideGamut

    var displayName: String {
        switch self {
        case .rec709: return "Rec.709"
        case .p3d65: return "P3-D65"
        case .rec2020: return "Rec.2020"
        case .sGamut3Cine: return "S-Gamut3.Cine"
        case .arriWideGamut3: return "ARRI Wide Gamut 3"
        case .arriWideGamut4: return "ARRI Wide Gamut 4"
        case .vGamut: return "V-Gamut"
        case .appleWideGamut: return "Apple Wide Gamut"
        }
    }

    /// CIE 1931 xy chromaticities (R, G, B).
    var primaries: (r: SIMD2<Double>, g: SIMD2<Double>, b: SIMD2<Double>) {
        switch self {
        case .rec709:         return ([0.640, 0.330], [0.300, 0.600], [0.150, 0.060])
        case .p3d65:          return ([0.680, 0.320], [0.265, 0.690], [0.150, 0.060])
        case .rec2020:        return ([0.708, 0.292], [0.170, 0.797], [0.131, 0.046])
        case .sGamut3Cine:    return ([0.766, 0.275], [0.225, 0.800], [0.089, -0.087])
        case .arriWideGamut3: return ([0.6840, 0.3130], [0.2210, 0.8480], [0.0861, -0.1020])
        case .arriWideGamut4: return ([0.7347, 0.2653], [0.1424, 0.8576], [0.0991, -0.0308])
        case .vGamut:         return ([0.730, 0.280], [0.165, 0.840], [0.100, -0.030])
        case .appleWideGamut:
            // VERIFY: replace with the primaries from Apple's "Apple Log Profile" white paper
            // (developer.apple.com/download, search "Apple log profile"). Until then this falls back to
            // Rec.2020 so Apple Log 2 renders plausibly; the UI flags it as approximate.
            return Gamut.rec2020.primaries
        }
    }

    /// False until the Apple Wide Gamut primaries above have been filled in from Apple's white paper.
    var isVerified: Bool { self != .appleWideGamut }
}

/// Scene-referred transfer functions, mirrored by TF_* in ShaderTypes.h.
enum Transfer: String, Codable, CaseIterable, Hashable {
    case linear, appleLog, sLog3, logC3, logC4, vLog, bt1886, sRGB, pq, hlg

    var shaderID: Int32 {
        switch self {
        case .linear: return TF_LINEAR
        case .appleLog: return TF_APPLE_LOG
        case .sLog3: return TF_SLOG3
        case .logC3: return TF_LOGC3
        case .logC4: return TF_LOGC4
        case .vLog: return TF_VLOG
        case .bt1886: return TF_BT1886
        case .sRGB: return TF_SRGB
        case .pq: return TF_PQ
        case .hlg: return TF_HLG
        }
    }

    var isCameraLog: Bool { [.appleLog, .sLog3, .logC3, .logC4, .vLog].contains(self) }
    var isSDR: Bool { self == .bt1886 || self == .sRGB }
}

enum ColorScience {
    static let d65 = SIMD2<Double>(0.3127, 0.3290)
    static let luma2020 = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    private static func xyz(_ c: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y)
    }

    /// Normalized primary matrix (RGB -> XYZ) per SMPTE RP 177.
    static func rgbToXYZ(_ gamut: Gamut) -> simd_double3x3 {
        let p = gamut.primaries
        let P = simd_double3x3([xyz(p.r), xyz(p.g), xyz(p.b)])
        let S = P.inverse * xyz(d65)
        return P * simd_double3x3(diagonal: S)
    }

    static func matrix(from a: Gamut, to b: Gamut) -> simd_float3x3 {
        if a == b { return matrix_identity_float3x3 }
        return float(rgbToXYZ(b).inverse * rgbToXYZ(a))
    }

    static func toXYZ(_ g: Gamut) -> simd_float3x3 { float(rgbToXYZ(g)) }
    static func fromXYZ(_ g: Gamut) -> simd_float3x3 { float(rgbToXYZ(g).inverse) }

    /// Luma coefficients are the Y row of the RGB -> XYZ matrix.
    static func luma(_ g: Gamut) -> SIMD3<Float> {
        let m = rgbToXYZ(g)
        return SIMD3<Float>(Float(m.columns.0.y), Float(m.columns.1.y), Float(m.columns.2.y))
    }

    static func float(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2))
    }
}
