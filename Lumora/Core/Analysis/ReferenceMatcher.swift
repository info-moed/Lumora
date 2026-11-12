import Foundation

/// Fits Lumora's HDR grade to an official reference release of the same film or show (e.g. the 4K UHD).
/// 1. Finds the time offset between the two files by correlating tiny luma thumbnails.
/// 2. Measures both on matched frames: our graded output vs the reference decoded straight to nits.
/// 3. Matches the brightness distributions (quantile mapping) into a smooth, monotonic correction curve.
/// 4. Reports, per brightness band, how far apart the grades were before and after.
enum ReferenceMatcher {
    struct Band: Hashable { var name: String; var beforeStops: Float; var afterStops: Float }
    struct Report {
        var offsetSeconds: Double
        var bands: [Band]
        var oursHighlightNits: Float
        var referenceHighlightNits: Float
        var summary: String
    }

    static let gridCount = 64

    static func match(source d: SourceDescriptor, color: SourceColor, preset: PresetCandidate, analysis: AnalysisResult,
                      target: OutputTarget, reference url: URL,
                      progress: @escaping (Double) -> Void) async throws -> ([Float], Report) {
        var (ref, refColors) = try await SourceInspector.inspect(url)
        guard let refColor = refColors.first, refColor.transfer == .pq else {
            throw LumoraError.unsupported("The reference must be HDR10 / Dolby Vision (PQ), like a 4K UHD release.")
        }
        ref.crop = try await CropDetector.detect(ref)
        let ours = try await d.makeFrameSource()
        let theirs = try await ref.makeFrameSource()
        let renderer = GradeRenderer()
        var params = preset.params
        params.matchCurve = nil

        // --- 1. Alignment
        let probeU = UniformBuilder.analysis(source: color, gridW: 320, gridH: 180, crop: d.crop)
        let refProbeU = UniformBuilder.analysis(source: refColor, gridW: 320, gridH: 180, crop: ref.crop)
        var offsets: [Double] = []
        for f in [0.2, 0.35, 0.5, 0.65, 0.8] {
            let t = d.durationSeconds * f
            try ours.start(at: Int(t * d.fps), count: 1)
            guard let a = try ours.nextFrame() else { continue }
            let thumbA = zscore(renderer.analyze(a.texture, uniforms: probeU, gridWidth: 320).thumbnail)
            let window = Int(ref.fps * 3)
            let start = max(0, Int(t * ref.fps) - window)
            try theirs.start(at: start, count: window * 2)
            var best = (score: -Float.infinity, frame: start)
            var i = start
            while let b = try theirs.nextFrame() {
                let thumbB = zscore(renderer.analyze(b.texture, uniforms: refProbeU, gridWidth: 320).thumbnail)
                let s = zip(thumbA, thumbB).reduce(0) { $0 + $1.0 * $1.1 }
                if s > best.score { best = (s, i) }
                i += 1
            }
            offsets.append(Double(best.frame) / ref.fps - t)
            progress(Double(offsets.count) / 15)
        }
        let offset = offsets.sorted()[offsets.count / 2]

        // --- 2. Paired measurements
        var hOurs = [Double](repeating: 0, count: Int(NITS_BINS)), hRef = hOurs
        let samples = 40
        for k in 0..<samples {
            try Task.checkCancellation()
            let t = d.durationSeconds * (0.05 + 0.9 * Double(k) / Double(samples - 1))
            let rt = t + offset
            guard rt >= 0, rt < ref.durationSeconds else { continue }
            try ours.start(at: Int(t * d.fps), count: 1)
            try theirs.start(at: Int(rt * ref.fps), count: 1)
            guard let a = try ours.nextFrame(), let b = try theirs.nextFrame() else { continue }
            let scene = analysis.sceneIndex(for: Int(t * d.fps))
            let uo = UniformBuilder.make(source: color, params: params, target: target,
                                         sceneExposureStops: preset.sceneExposures[safe: scene] ?? 0,
                                         viewport: .zero, crop: d.crop)
            let ur = UniformBuilder.make(source: refColor, params: .neutral, target: target, sceneExposureStops: 0,
                                         viewport: .zero, crop: ref.crop)
            for (i, c) in renderer.nitsHistogram(a.texture, uniforms: uo, graded: true).enumerated() { hOurs[i] += Double(c) }
            for (i, c) in renderer.nitsHistogram(b.texture, uniforms: ur, graded: false).enumerated() { hRef[i] += Double(c) }
            progress(0.33 + 0.67 * Double(k + 1) / Double(samples))
        }
        ours.cancel(); theirs.cancel()

        // --- 3. Quantile matching -> correction curve over log2(nits)
        let qs = (0..<240).map { 0.002 + 0.9975 * Double($0) / 239 }
        let pairs = qs.map { (quantile(hOurs, $0), quantile(hRef, $0)) }
        let lo = Float(MATCH_LOG_MIN), hi = Float(MATCH_LOG_MAX)
        var curve = (0..<gridCount).map { g -> Float in
            let x = lo + (hi - lo) * Float(g) / Float(gridCount - 1)
            if x <= pairs.first!.0 { return pairs.first!.1 - pairs.first!.0 }
            if x >= pairs.last!.0 { return pairs.last!.1 - pairs.last!.0 }
            for j in 1..<pairs.count where pairs[j].0 >= x {
                let (x0, y0) = pairs[j - 1], (x1, y1) = pairs[j]
                let f = x1 > x0 ? (x - x0) / (x1 - x0) : 0
                return (y0 - x0) + f * ((y1 - x1) - (y0 - x0))
            }
            return 0
        }
        // Smooth, clamp, and keep the mapping monotonic so gradients can never invert.
        curve = curve.indices.map { i in
            let w = curve[max(0, i - 2)...min(curve.count - 1, i + 2)]
            return max(-3, min(3, w.reduce(0, +) / Float(w.count)))
        }
        var lastY = -Float.infinity
        for i in curve.indices {
            let x = lo + (hi - lo) * Float(i) / Float(gridCount - 1)
            let y = max(x + curve[i], lastY)
            curve[i] = y - x
            lastY = y
        }

        // --- 4. Report
        func correction(_ x: Float) -> Float {
            let p = (x - lo) / (hi - lo) * Float(gridCount - 1)
            let i = max(0, min(gridCount - 2, Int(p)))
            return curve[i] + (curve[i + 1] - curve[i]) * max(0, min(1, p - Float(i)))
        }
        func band(_ name: String, _ a: Float, _ b: Float) -> Band {
            let sel = pairs.filter { $0.0 >= log2f(a) && $0.0 < log2f(b) }
            guard !sel.isEmpty else { return Band(name: name, beforeStops: 0, afterStops: 0) }
            let before = sel.map { $0.1 - $0.0 }.reduce(0, +) / Float(sel.count)
            let after = sel.map { $0.1 - ($0.0 + correction($0.0)) }.reduce(0, +) / Float(sel.count)
            return Band(name: name, beforeStops: before, afterStops: after)
        }
        let bands = [band("Shadows (0.05–5 nits)", 0.05, 5), band("Mid-tones (5–60 nits)", 5, 60),
                     band("Bright tones (60–600 nits)", 60, 600), band("Highlights (600+ nits)", 600, 10000)]
        let hiOurs = powf(2, quantile(hOurs, 0.9995)), hiRef = powf(2, quantile(hRef, 0.9995))
        let mids = bands[1].beforeStops, highs = bands[3].beforeStops
        func describe(_ s: Float, _ what: String) -> String {
            abs(s) < 0.1 ? "\(what) already matched" : String(format: "\(what) were %.1f stops %@", abs(s), s > 0 ? "darker" : "brighter")
        }
        let summary = "\(describe(mids, "Mid-tones")); \(describe(highs, "highlights")) than the reference. "
            + "Lumora now follows the reference grade (offset \(String(format: "%.2f", offset)) s)."
        return (curve, Report(offsetSeconds: offset, bands: bands, oursHighlightNits: hiOurs,
                              referenceHighlightNits: hiRef, summary: summary))
    }

    private static func zscore(_ v: [Float]) -> [Float] {
        let n = Float(max(1, v.count))
        let mean = v.reduce(0, +) / n
        let sd = max(1e-5, sqrtf(v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n))
        return v.map { ($0 - mean) / sd / n }
    }

    /// log2(nits) at quantile q of a NITS_BINS histogram.
    private static func quantile(_ h: [Double], _ q: Double) -> Float {
        let total = h.reduce(0, +)
        guard total > 0 else { return 0 }
        var cum = 0.0
        let lo = Float(MATCH_LOG_MIN), hi = Float(MATCH_LOG_MAX)
        for (i, c) in h.enumerated() {
            cum += c
            if cum >= total * q { return lo + (hi - lo) * (Float(i) + 0.5) / Float(h.count) }
        }
        return hi
    }
}
