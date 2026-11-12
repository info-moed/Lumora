import Foundation

/// CPU versions of the transfer functions in Grade.metal. Used by the UI (scope markers, metadata) and by the
/// unit tests, which pin every curve to published reference values so a typo can never shift colours silently.
enum TransferMath {
    // MARK: PQ (SMPTE ST 2084)
    static let m1: Float = 0.1593017578125, m2: Float = 78.84375
    static let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875

    static func nitsToPQ(_ n: Float) -> Float {
        let y = powf(max(0, min(1, n / 10000)), m1)
        return powf((c1 + c2 * y) / (1 + c3 * y), m2)
    }
    static func pqToNits(_ v: Float) -> Float {
        let p = powf(max(v, 0), 1 / m2)
        return 10000 * powf(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    // MARK: HLG (BT.2100)
    static let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
    static func hlgOETF(_ e: Float) -> Float { e <= 1.0 / 12 ? sqrtf(3 * e) : a * logf(12 * e - b) + c }
    static func hlgInverse(_ v: Float) -> Float { v <= 0.5 ? v * v / 3 : (expf((v - c) / a) + b) / 12 }

    // MARK: Apple Log
    static func appleLogEncode(_ r: Float) -> Float {
        let R0: Float = -0.05641088, Rt: Float = 0.01, sigma: Float = 47.28711236
        let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
        if r >= Rt { return gamma * log2f(r + beta) + delta }
        if r >= R0 { return sigma * (r - R0) * (r - R0) }
        return 0
    }
    static func appleLogDecode(_ p: Float) -> Float {
        let R0: Float = -0.05641088, Rt: Float = 0.01, sigma: Float = 47.28711236
        let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
        let Pt = sigma * (Rt - R0) * (Rt - R0)
        if p >= Pt { return powf(2, (p - delta) / gamma) - beta }
        if p >= 0 { return sqrtf(p / sigma) + R0 }
        return R0
    }

    // MARK: Sony S-Log3
    static func sLog3Encode(_ x: Float) -> Float {
        x >= 0.01125000 ? (420 + log10f((x + 0.01) / 0.19) * 261.5) / 1023
                        : (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
    }
    static func sLog3Decode(_ y: Float) -> Float {
        y >= 171.2102946929 / 1023 ? powf(10, (y * 1023 - 420) / 261.5) * 0.19 - 0.01
                                   : (y * 1023 - 95) * 0.01125 / (171.2102946929 - 95)
    }

    // MARK: ARRI LogC3 (EI 800)
    static func logC3Encode(_ x: Float) -> Float {
        x > 0.010591 ? 0.247190 * log10f(5.555556 * x + 0.052272) + 0.385537 : 5.367655 * x + 0.092809
    }
    static func logC3Decode(_ t: Float) -> Float {
        t > 5.367655 * 0.010591 + 0.092809 ? (powf(10, (t - 0.385537) / 0.247190) - 0.052272) / 5.555556
                                           : (t - 0.092809) / 5.367655
    }

    // MARK: ARRI LogC4
    static let l4a: Float = (262144 - 16) / 117.45, l4b: Float = (1023 - 95) / 1023, l4c: Float = 95 / 1023
    static func logC4Encode(_ x: Float) -> Float {
        let t = (powf(2, 14 * (-l4c / l4b) + 6) - 64) / l4a
        let s = (7 * logf(2) * powf(2, 7 - 14 * l4c / l4b)) / (l4a * l4b)
        return x >= t ? (log2f(l4a * x + 64) - 6) / 14 * l4b + l4c : (x - t) / s
    }
    static func logC4Decode(_ v: Float) -> Float {
        let t = (powf(2, 14 * (-l4c / l4b) + 6) - 64) / l4a
        let s = (7 * logf(2) * powf(2, 7 - 14 * l4c / l4b)) / (l4a * l4b)
        return v >= 0 ? (powf(2, 14 * (v - l4c) / l4b + 6) - 64) / l4a : v * s + t
    }

    // MARK: Panasonic V-Log
    static func vLogEncode(_ x: Float) -> Float { x < 0.01 ? 5.6 * x + 0.125 : 0.241514 * log10f(x + 0.00873) + 0.598206 }
    static func vLogDecode(_ v: Float) -> Float { v < 0.181 ? (v - 0.125) / 5.6 : powf(10, (v - 0.598206) / 0.241514) - 0.00873 }
}
