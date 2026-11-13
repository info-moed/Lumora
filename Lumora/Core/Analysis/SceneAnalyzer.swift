import Foundation
import Metal

struct SceneStats: Codable, Hashable {
    var start: Int           // first frame
    var end: Int             // one past last frame
    var keyStops: Float      // mean log2(Y/0.18): overall brightness of the scene
    var p005: Float          // shadow floor (stops)
    var p50: Float
    var p995: Float          // highlight ceiling (stops)
    var skinFraction: Float
    var avgChroma: Float
}

/// Fades and dissolves: optical flow fails on them, so interpolation blends instead.
struct TransitionSpan: Codable, Hashable {
    enum Kind: String, Codable { case fadeOut, fadeIn, dissolve }
    var start: Int
    var end: Int
    var kind: Kind
}

struct AnalysisResult: Codable {
    var frameCount: Int
    var scenes: [SceneStats]
    var transitions: [TransitionSpan]
    var cutFrames: Set<Int>          // frame indices that begin a new shot
    var duplicateFrames: Set<Int>    // frame i repeats frame i-1 (animation on twos, padded VFR, telecine leftovers)
    var globalKey: Float
    var globalP005: Float
    var globalP995: Float
    var skinFraction: Float
    var avgChroma: Float
    var globalHistogram: [UInt32]
    var motion: [Float] = []         // per-frame change from the previous frame (0…1), from the analysis thumbnails
    var damage: DamageMap? = nil      // frames that couldn't be decoded correctly (found while analyzing)

    func sceneMotion(_ i: Int) -> Float {
        guard let s = scenes[safe: i], !motion.isEmpty else { return 0 }
        let r = max(0, s.start + 1)..<min(motion.count, s.end)
        guard !r.isEmpty else { return 0 }
        return motion[r].reduce(0, +) / Float(r.count)
    }

    func sceneIndex(for frame: Int) -> Int {
        var lo = 0, hi = scenes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if scenes[mid].start <= frame { lo = mid } else { hi = mid - 1 }
        }
        return max(0, lo)
    }

    func transition(containing frame: Int) -> TransitionSpan? {
        transitions.first { frame >= $0.start && frame < $0.end }
    }
}

enum SceneAnalyzer {
    /// Scans every frame on a low-res grid (hardware decode + one tiny GPU pass per frame).
    /// - proxy: also writes a small preview proxy to the scratch SSD during this single read of the file.
    /// - readAhead: keeps a slow (hard) drive's read-ahead filled in front of the decoder.
    static func analyze(_ d: SourceDescriptor, color: SourceColor, chip: ChipProfile = .current,
                        proxy: ProxyWriter? = nil, readAhead: ReadAheadAdvisor? = nil,
                        progress: @escaping (Double) -> Void) async throws -> AnalysisResult {
        let src = ConcealingFrameSource.wrap(try await d.makeFrameSource(), descriptor: d)   // reads on past damage
        try src.start(at: 0, count: nil)
        let renderer = GradeRenderer()
        let gw = chip.analysisWidth
        let u = UniformBuilder.analysis(source: color, gridW: gw, gridH: gw * 9 / 16, crop: d.crop)

        var hists: [[UInt32]] = []
        var duplicates = Set<Int>()
        var lastThumb: [Float]?
        var motionPerFrame: [Float] = []
        var skin: [Float] = [], chroma: [Float] = [], means: [Float] = []
        hists.reserveCapacity(min(d.frameCount, 1 << 16))   // the container's frame count can be a lie (100 h claimed, 2 s real)
        // Up to 3 frames in flight on the GPU while the media engine decodes the next ones.
        var inFlight: [Task<GradeRenderer.FrameStats, Never>] = []
        func consume(_ s: GradeRenderer.FrameStats) {
            if let prev = lastThumb {
                let mad = zip(prev, s.thumbnail).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(s.thumbnail.count)
                if mad < 0.0015 { duplicates.insert(hists.count) }
                motionPerFrame.append(mad)
            } else { motionPerFrame.append(0) }
            lastThumb = s.thumbnail
            hists.append(s.histogram)
            let n = max(1, Float(s.count))
            skin.append(Float(s.skin) / n)
            chroma.append(Float(s.chromaSum) / 1000 / n)
            means.append(Histogram.meanStop(s.histogram))
            if hists.count % 24 == 0 { progress(Double(hists.count) / Double(max(1, d.frameCount))) }
        }
        var decoded = 0
        while let frame = try src.nextFrame() {
            try Task.checkCancellation()
            decoded += 1
            readAhead?.advance(toFraction: Double(decoded) / Double(max(1, d.frameCount)))
            if let proxy { await proxy.append(frame.texture) }
            inFlight.append(Task { await renderer.analyzeAsync(frame.texture, uniforms: u, gridWidth: gw) })
            if inFlight.count >= 3 { consume(await inFlight.removeFirst().value) }
        }
        for t in inFlight { consume(await t.value) }
        guard !hists.isEmpty else { throw LumoraError.decodeFailed("no frames") }

        // --- Cuts: chi-square distance on coarse histograms, adaptive threshold, minimum shot length.
        let coarse = hists.map { h -> [Float] in
            let total = Float(max(1, h.reduce(0) { $0 + Int($1) }))
            return stride(from: 0, to: h.count, by: 4).map { i in Float(h[i] + h[i+1] + h[i+2] + h[i+3]) / total }
        }
        var dist = [Float](repeating: 0, count: hists.count)
        for i in 1..<max(1, coarse.count) {
            var s: Float = 0
            for k in 0..<coarse[i].count {
                let a = coarse[i][k], b = coarse[i - 1][k]
                if a + b > 0 { s += (a - b) * (a - b) / (a + b) }
            }
            dist[i] = 0.5 * s
        }
        var cuts: [Int] = [0]
        for i in 1..<dist.count {
            let window = dist[max(0, i - 24)..<i].sorted()
            let median = window.isEmpty ? 0 : window[window.count / 2]
            if dist[i] > 0.3, dist[i] > 2.5 * median + 0.05, i - (cuts.last ?? 0) >= 12 { cuts.append(i) }
        }

        // --- Fades (steady brightness ramp to/from black) and dissolves (sustained moderate change).
        var transitions: [TransitionSpan] = []
        var i = 1
        while i < means.count {
            var j = i
            while j < means.count, abs(means[j] - means[j - 1]) > 0.2, (means[j] - means[j - 1]) * (means[i] - means[i - 1]) > 0 { j += 1 }
            if j - i >= 8 {
                let falling = means[i] > means[j - 1]
                let darkEnd = min(means[i - 1], means[j - 1]) < -6
                transitions.append(TransitionSpan(start: i - 1, end: j, kind: darkEnd ? (falling ? .fadeOut : .fadeIn) : .dissolve))
                i = j
                continue
            }
            var k = i
            while k < dist.count, dist[k] > 0.06, dist[k] < 0.3 { k += 1 }
            if k - i >= 6 { transitions.append(TransitionSpan(start: i - 1, end: k, kind: .dissolve)); i = k; continue }
            i += 1
        }

        // --- Per-scene statistics.
        var scenes: [SceneStats] = []
        for (n, start) in cuts.enumerated() {
            let end = n + 1 < cuts.count ? cuts[n + 1] : hists.count
            var h = [UInt32](repeating: 0, count: Int(HIST_BINS))
            for f in start..<end { for b in 0..<h.count { h[b] &+= hists[f][b] } }
            let count = Float(end - start)
            scenes.append(SceneStats(start: start, end: end, keyStops: Histogram.meanStop(h),
                                     p005: Histogram.percentileStop(h, 0.005), p50: Histogram.percentileStop(h, 0.5),
                                     p995: Histogram.percentileStop(h, 0.995),
                                     skinFraction: skin[start..<end].reduce(0, +) / count,
                                     avgChroma: chroma[start..<end].reduce(0, +) / count))
        }
        var all = [UInt32](repeating: 0, count: Int(HIST_BINS))
        for h in hists { for b in 0..<all.count { all[b] &+= h[b] } }
        progress(1)
        // Only call it "duplicated" if it's a pattern (>10% of frames), not a few static moments.
        let dupes = Double(duplicates.count) / Double(hists.count) > 0.1 ? duplicates : []
        return AnalysisResult(frameCount: hists.count, scenes: scenes, transitions: transitions, cutFrames: Set(cuts),
                              duplicateFrames: dupes,
                              globalKey: Histogram.meanStop(all), globalP005: Histogram.percentileStop(all, 0.005),
                              globalP995: Histogram.percentileStop(all, 0.995),
                              skinFraction: skin.reduce(0, +) / Float(skin.count),
                              avgChroma: chroma.reduce(0, +) / Float(chroma.count), globalHistogram: all,
                              motion: motionPerFrame.enumerated().map { cuts.contains($0.offset) ? 0 : $0.element },
                              damage: (src as? ConcealingFrameSource).flatMap { $0.damage.isEmpty ? nil : $0.damage })
    }

    // MARK: Graded light levels (HDR10 / HDR10+ / Dolby Vision metadata)

    struct LightLevels {
        var maxCLL: Float
        var maxFALL: Float
        var perFrameMax: [Float]
        var perFrameAvg: [Float]
    }

    /// Measures the actual graded output, frame by frame, with the exact export grade.
    /// The grid is ~1K wide, so the tiniest specular glints read slightly low; a 10% margin covers that.
    static func measureLightLevels(_ d: SourceDescriptor, color: SourceColor, preset: PresetCandidate,
                                   analysis: AnalysisResult, target: OutputTarget, sourcePeakNits: Float,
                                   progress: @escaping (Double) -> Void) async throws -> LightLevels {
        let src = ConcealingFrameSource.wrap(try await d.makeFrameSource(), descriptor: d)   // reads on past damage
        try src.start(at: 0, count: nil)
        let renderer = GradeRenderer()
        var maxes: [Float] = [], avgs: [Float] = []
        while let frame = try src.nextFrame() {
            try Task.checkCancellation()
            let scene = analysis.sceneIndex(for: frame.index)
            let u = UniformBuilder.make(source: color, params: preset.params, target: target,
                                        sceneExposureStops: preset.sceneExposures[safe: scene] ?? 0,
                                        viewport: .zero, sourcePeakNits: sourcePeakNits, crop: d.crop)
            let m = renderer.measure(frame.texture, uniforms: u, gridWidth: 1024)
            maxes.append(m.max)
            avgs.append(m.avg)
            if maxes.count % 24 == 0 { progress(Double(maxes.count) / Double(max(1, d.frameCount))) }
        }
        let peak = target.effectivePeak
        return LightLevels(maxCLL: min(peak, (maxes.max() ?? 0) * 1.1), maxFALL: min(peak, avgs.max() ?? 0),
                           perFrameMax: maxes, perFrameAvg: avgs)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
