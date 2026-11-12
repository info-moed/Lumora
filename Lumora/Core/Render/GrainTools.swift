import Foundation
import Metal

/// Grain strength per brightness band (standard deviation, in signal units 0…1).
struct GrainStats: Codable, Hashable {
    var sigmaPerBin: [Float]   // GRAIN_BINS values
    var overall: Float

    static let none = GrainStats(sigmaPerBin: Array(repeating: 0, count: Int(GRAIN_BINS)), overall: 0)
}

/// "Restore film texture": adds organic grain to over-processed or grain-scrubbed transfers, stored as a few
/// bytes of AV1 grain parameters and re-created by the player (no bitrate cost).
enum FilmTexture: String, CaseIterable, Codable, Identifiable {
    case off = "Off", fine = "Fine 35mm", film35 = "35mm", heavy = "16mm / heavy"
    var id: String { rawValue }
    /// Typical grain strength (signal units), strongest in the mid-tones like real negative film.
    func stats(strength: Float) -> GrainStats {
        let base: Float = switch self { case .off: 0; case .fine: 0.0025; case .film35: 0.0045; case .heavy: 0.008 }
        let bins = (0..<Int(GRAIN_BINS)).map { i -> Float in
            let x = (Float(i) + 0.5) / Float(GRAIN_BINS)
            return base * strength * (0.55 + 0.45 * sin(.pi * min(1, x * 1.25)))   // peaks in mid-tones, softer in deep blacks
        }
        return GrainStats(sigmaPerBin: bins, overall: base * strength)
    }
}

/// Splits frames into clean picture + grain, measures grain, and re-grains interpolated frames.
final class GrainProcessor {
    private let ctx = MetalContext.shared

    func denoise(_ cb: MTLCommandBuffer, _ src: MTLTexture, into dst: MTLTexture, sigma: Float) {
        var d = DenoiseUniforms(sigmaSpatial: 1.6, sigmaRange: max(0.004, sigma * 2.5), radius: 3, pad: 0)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&d, length: MemoryLayout<DenoiseUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("bilateralKernel"), width: src.width, height: src.height)
        enc.endEncoding()
    }

    func regrain(_ cb: MTLCommandBuffer, cleanMid: MTLTexture, origNear: MTLTexture, cleanNear: MTLTexture,
                 into dst: MTLTexture, seed: Int) {
        var offset = SIMD2<Int32>(Int32((seed * 7919) % 509) + 17, Int32((seed * 104729) % 457) + 23)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(cleanMid, index: 0)
        enc.setTexture(origNear, index: 1)
        enc.setTexture(cleanNear, index: 2)
        enc.setTexture(dst, index: 3)
        enc.setBytes(&offset, length: 8, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("regrainKernel"), width: dst.width, height: dst.height)
        enc.endEncoding()
    }

    /// Measures grain per brightness band on a frame (denoise with a generous setting, then look at the residual).
    func measure(_ frame: MTLTexture) -> GrainStats {
        let clean = ctx.makeTexture(width: frame.width, height: frame.height, format: frame.pixelFormat)
        let sums = ctx.device.makeBuffer(length: Int(GRAIN_BINS) * 4, options: .storageModeShared)!
        let counts = ctx.device.makeBuffer(length: Int(GRAIN_BINS) * 4, options: .storageModeShared)!
        memset(sums.contents(), 0, sums.length); memset(counts.contents(), 0, counts.length)
        let cb = ctx.queue.makeCommandBuffer()!
        denoise(cb, frame, into: clean, sigma: 0.012)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(frame, index: 0)
        enc.setTexture(clean, index: 1)
        enc.setBuffer(sums, offset: 0, index: 0)
        enc.setBuffer(counts, offset: 0, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("grainStatsKernel"), width: frame.width, height: frame.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let s = sums.contents().bindMemory(to: Float.self, capacity: Int(GRAIN_BINS))
        let c = counts.contents().bindMemory(to: UInt32.self, capacity: Int(GRAIN_BINS))
        var bins: [Float] = [], total: Float = 0, n: Float = 0
        for i in 0..<Int(GRAIN_BINS) {
            let v = c[i] > 50 ? sqrtf(s[i] / Float(c[i])) : 0
            bins.append(v)
            total += s[i]; n += Float(c[i])
        }
        // Fill empty bands from neighbors so the curve is continuous.
        for i in bins.indices where bins[i] == 0 {
            bins[i] = bins[..<i].last(where: { $0 > 0 }) ?? bins[i...].first(where: { $0 > 0 }) ?? 0
        }
        return GrainStats(sigmaPerBin: bins, overall: n > 0 ? sqrtf(total / n) : 0)
    }
}

/// Writes an AV1 film-grain table (libaom "filmgrn1" text format) usable by SVT-AV1 (--fgs-table) and
/// libaom (--film-grain-table). Luma grain only, white-noise shape (lag 0), scaled per brightness.
/// VERIFY: the gaussian-sequence scale constant against your encoder build, and tune "strength" by eye.
enum GrainTable {
    static func write(_ stats: GrainStats, bitDepth: Int, strength: Float = 1, seed: Int = 7391, to url: URL) throws {
        let scalingShift = 11
        // Approximate std of the AV1 gaussian sequence after the bit-depth shift, in output code values.
        let gaussSigma: Float = bitDepth >= 10 ? 128 : 32
        let codeScale = Float((1 << bitDepth) - 1)
        let picks = stride(from: 0, to: Int(GRAIN_BINS), by: max(1, Int(GRAIN_BINS) / 10)).map { $0 }
        var points: [String] = []
        for i in picks {
            let x = Int(((Float(i) + 0.5) / Float(GRAIN_BINS) * 255).rounded())
            let sigmaCodes = stats.sigmaPerBin[i] * strength * codeScale
            let y = Int(min(255, max(0, (sigmaCodes * Float(1 << scalingShift) / gaussSigma).rounded())))
            points.append("\(x) \(y)")
        }
        let text = """
        filmgrn1
        E 0 9223372036854775807 1 \(seed) 1
        \tp 0 6 0 \(scalingShift) 0 1 128 192 256 128 192 256
        \tsY \(points.count) \(points.joined(separator: " "))
        \tsCb 0
        \tsCr 0
        \tcY
        \tcCb 0
        \tcCr 0

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
