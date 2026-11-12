import Foundation
import Metal

/// Learned, reference-free artifact scorer for generated frames.
///
/// For every 64-px tile of an analysis copy (at most about 1920 px wide, so a tile covers the same share of the
/// picture at every resolution) it measures how the primary model's output relates to the two real neighbors and to
/// the alternatives it could be replaced with: a second opinion from the flow model at about 960 px wide, a plain
/// cross-fade, the nearest original, and the average of the two models. Small gradient-boosted tree ensembles,
/// trained against ground truth (Big Buck Bunny's native 60 fps render, see scripts/qc_scorer), predict
///   1. how good the primary output is in that tile (its PSNR), and
///   2. how many dB each alternative would gain there.
/// A tile is switched only when it is predicted to be poor AND an alternative is predicted to gain more than a
/// margin; both thresholds come from the sensitivity setting. A third ensemble, trained on copies of the training
/// frames with planted artifacts (holes, checkerboards, noise, tears, misplaced content, color shifts), recognizes
/// blatant damage; such tiles are replaced at every sensitivity. A frame pair that straddles a shot change the
/// analyzer missed is detected from frame-level statistics and held on the nearest original instead.
final class ArtifactScorer {
    enum Choice: UInt8 { case primary = 0, alternative = 1, blend = 2, nearest = 3, average = 4 }

    /// Reference-free per-tile features, in model-input order. scripts/qc_scorer reads the same names.
    static let featureNames = [
        "lumaP", "dAB", "dPQ", "dPBlend", "dQBlend", "dPNear", "dQNear", "texture", "gradP", "excessP", "excessQ",
        "novP", "novQ", "novP04", "novP10", "novQ04", "novQ10", "movingAB", "disagreePQ", "dMeanAB",
        "maxPQ", "maxAB", "maxNovP", "maxNovQ",
        "flMag0", "flMag1", "flErr", "flErrFrac", "flOcc", "flMax",
        "edge", "tDist", "frDAB", "frDPQ", "frNovP04", "frFlErr", "relDPQ", "relNovP", "relDAB",
        "nbDPQ", "nbNovP04", "nbDAB", "flowPrimary",
    ]
    /// Frame-level statistics for the shot-change test.
    static let frameFeatureNames = ["corrAB", "frDAB", "meanTileDiff", "frNovP04", "frFlErr", "frDPQ"]

    struct Measurement {
        var tilesX: Int, tilesY: Int, scale: Int
        var features: [[Float]]
        var frame: [Float]
        var hasAlternative: Bool
        var count: Int { tilesX * tilesY }
    }

    struct Decision {
        var choices: [UInt8]
        var shotChange: Bool
        var switched: Int { choices.filter { $0 != Choice.primary.rawValue }.count }
        var fraction: Float { choices.isEmpty ? 0 : Float(switched) / Float(choices.count) }
    }

    static let sums = 22, maxes = 4, flowSlots = 8
    static var featureCount: Int { sums + maxes }

    private let ctx = MetalContext.shared
    private var pack: MTLTexture?
    private var featBuffer: MTLBuffer?, flowBuffer: MTLBuffer?, flowMax: MTLBuffer?, choiceBuffer: MTLBuffer?
    let model = QCScorerModel.shared

    /// Full-resolution pixels per analysis pixel: 1 up to ~2.5K, 2 for UHD, ...
    static func scale(forWidth w: Int) -> Int { max(1, Int((Double(w) / 1920).rounded())) }

    /// Model scale for the alternative flow model's second opinion (about 960 px wide).
    static func alternativeModelScale(forWidth w: Int) -> Float { w > 1280 ? 960 / Float(w) : 0.5 }

    private func uniforms(_ w: Int, _ h: Int, t: Float) -> QCScoreUniforms {
        let s = Self.scale(forWidth: w)
        let aw = max(1, w / s), ah = max(1, h / s)
        return QCScoreUniforms(scale: Int32(s), tilesX: Int32((aw + 63) / 64), tilesY: Int32((ah + 63) / 64),
                               analysisWidth: Int32(aw), analysisHeight: Int32(ah), t: t, modelWidth: 0, modelHeight: 0,
                               tensorWidth: 0, tensorHeight: 0, pad0: 0, pad1: 0)
    }

    /// Measures one generated frame. `alternativeEngine`'s flow buffers must still hold the prediction that made `q`
    /// (call right after generating q for this time).
    func measure(a: MTLTexture, b: MTLTexture, primary p: MTLTexture, alternative q: MTLTexture?,
                 alternativeEngine alt: CoreMLInterpolator?, t: Float, primaryIsFlow: Bool) -> Measurement {
        var u = uniforms(p.width, p.height, t: t)
        let tx = Int(u.tilesX), ty = Int(u.tilesY), n = tx * ty
        let aw = Int(u.analysisWidth), ah = Int(u.analysisHeight)
        if pack == nil || pack!.width != aw || pack!.height != ah {
            pack = ctx.makeTexture(width: aw, height: ah, format: .rgba32Float)
        }
        if featBuffer == nil || featBuffer!.length < n * Self.featureCount * 4 {
            featBuffer = ctx.device.makeBuffer(length: n * Self.featureCount * 4, options: .storageModeShared)
            flowBuffer = ctx.device.makeBuffer(length: n * Self.flowSlots * 4, options: .storageModeShared)
            flowMax = ctx.device.makeBuffer(length: n * 4, options: .storageModeShared)
        }
        memset(flowBuffer!.contents(), 0, n * Self.flowSlots * 4)
        memset(flowMax!.contents(), 0, n * 4)
        let qt = q ?? p
        let cb = ctx.queue.makeCommandBuffer()!
        var enc = cb.makeComputeCommandEncoder()!
        for (i, tex) in [a, b, p, qt, pack!].enumerated() { enc.setTexture(tex, index: i) }
        enc.setBytes(&u, length: MemoryLayout<QCScoreUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("qcLumaPackKernel"), width: aw, height: ah)
        enc.endEncoding()
        enc = cb.makeComputeCommandEncoder()!
        let pso = ctx.pipeline("qcFeatureKernel")
        enc.setComputePipelineState(pso)
        enc.setTexture(pack, index: 0)
        enc.setBuffer(featBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<QCScoreUniforms>.stride, index: 1)
        let rows = max(1, min(32, pso.maxTotalThreadsPerThreadgroup / 32))
        enc.dispatchThreadgroups(MTLSize(width: tx, height: ty, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: rows, depth: 1))
        enc.endEncoding()
        let hasFlow = q != nil && alt?.spec.isFlow == true && alt?.bufFlow != nil && alt?.bufMask != nil
        if hasFlow, let alt {
            u.modelWidth = Int32(alt.dims.cw); u.modelHeight = Int32(alt.dims.ch)
            u.tensorWidth = Int32(alt.dims.tw); u.tensorHeight = Int32(alt.dims.th)
            enc = cb.makeComputeCommandEncoder()!
            enc.setBuffer(alt.bufFlow, offset: 0, index: 0)
            enc.setBuffer(alt.bufMask, offset: 0, index: 1)
            enc.setBuffer(flowBuffer, offset: 0, index: 2)
            enc.setBuffer(flowMax, offset: 0, index: 3)
            enc.setBytes(&u, length: MemoryLayout<QCScoreUniforms>.stride, index: 4)
            ctx.dispatch2D(enc, ctx.pipeline("qcFlowStatsKernel"), width: alt.dims.cw, height: alt.dims.ch)
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return assemble(tilesX: tx, tilesY: ty, scale: Int(u.scale), t: t, hasAlternative: q != nil, hasFlow: hasFlow,
                        primaryIsFlow: primaryIsFlow)
    }

    private func assemble(tilesX tx: Int, tilesY ty: Int, scale: Int, t: Float, hasAlternative: Bool, hasFlow: Bool,
                          primaryIsFlow: Bool) -> Measurement {
        let n = tx * ty, F = Self.featureCount
        let raw = featBuffer!.contents().bindMemory(to: Float.self, capacity: n * F)
        let fl = flowBuffer!.contents().bindMemory(to: Float.self, capacity: n * Self.flowSlots)
        let fm = flowMax!.contents().bindMemory(to: Float.self, capacity: n)
        var means = [[Float]](repeating: [], count: n)
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let c = max(1, raw[i * F + 21])
            w[i] = raw[i * F + 21]
            means[i] = (0..<21).map { raw[i * F + $0] / c } + (22..<26).map { raw[i * F + $0] }
        }
        // means[i]: 0..20 = sums 0..20 as means, 21..24 = maxima (|P-Q|, |A-B|, novelty P, novelty Q)
        func frameMean(_ k: Int) -> Float {
            let tw = w.reduce(0, +)
            return tw > 0 ? zip(means, w).reduce(0) { $0 + $1.0[k] * $1.1 } / tw : 0
        }
        var flow = [[Float]](repeating: [0, 0, 0, 0, 0, 0], count: n)
        if hasFlow {
            for i in 0..<n {
                let c = max(1, fl[i * Self.flowSlots + 5])
                flow[i] = [fl[i * 8] / c, fl[i * 8 + 1] / c, fl[i * 8 + 2] / c, fl[i * 8 + 3] / c, fl[i * 8 + 4] / c, fm[i]]
            }
        }
        let fw = (0..<n).map { i in hasFlow ? max(0, fl[i * Self.flowSlots + 5]) : 0 }
        let frFlErr: Float = hasFlow ? zip(flow, fw).reduce(0) { $0 + $1.0[2] * $1.1 } / max(1, fw.reduce(0, +)) : 0
        let frDAB = frameMean(1), frDPQ = hasAlternative ? frameMean(2) : 0, frNov = frameMean(13)
        func neighbors(_ i: Int, _ k: Int) -> Float {
            let x = i % tx, y = i / tx
            var s: Float = 0, c: Float = 0
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < tx, ny < ty, w[ny * tx + nx] > 0 { s += means[ny * tx + nx][k]; c += 1 }
            } }
            return c > 0 ? s / c : means[i][k]
        }
        var features: [[Float]] = []
        features.reserveCapacity(n)
        for i in 0..<n {
            let m = means[i]
            let x = i % tx, y = i / tx
            var f: [Float] = [m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10],
                              m[11], m[12], m[13], m[14], m[15], m[16], m[17], m[18], abs(m[19] - m[20]),
                              m[21], m[22], m[23], m[24]]
            f += flow[i]
            f += [(x == 0 || y == 0 || x == tx - 1 || y == ty - 1) ? 1 : 0, abs(t - 0.5), frDAB, frDPQ, frNov, frFlErr,
                  m[2] / (frDPQ + 1e-3), m[13] / (frNov + 1e-2), m[1] / (frDAB + 1e-3),
                  neighbors(i, 2), neighbors(i, 13), neighbors(i, 1), primaryIsFlow ? 1 : 0]
            if !hasAlternative {
                for k in [2, 4, 6, 10, 12, 15, 16, 18, 20, 23] { f[k] = 0 }
            }
            features.append(f)
        }
        // Shot-change statistics: tile-mean luma correlation of A and B, mean |A-B|, mean tile brightness change.
        let la = means.map { $0[19] }, lb = means.map { $0[20] }
        let ma = la.reduce(0, +) / Float(max(1, n)), mb = lb.reduce(0, +) / Float(max(1, n))
        var sab: Float = 0, saa: Float = 0, sbb: Float = 0, mtd: Float = 0
        for i in 0..<n {
            sab += (la[i] - ma) * (lb[i] - mb); saa += (la[i] - ma) * (la[i] - ma); sbb += (lb[i] - mb) * (lb[i] - mb)
            mtd += abs(la[i] - lb[i])
        }
        let corr = saa > 1e-9 && sbb > 1e-9 ? sab / (saa * sbb).squareRoot() : 1
        let frame: [Float] = [corr, frDAB, mtd / Float(max(1, n)), frNov, frFlErr, frDPQ]
        return Measurement(tilesX: tx, tilesY: ty, scale: scale, features: features, frame: frame, hasAlternative: hasAlternative)
    }

    /// Chooses a candidate per tile (mirrors `decide` in scripts/qc_scorer/train.py).
    ///
    /// A tile is a candidate when its predicted primary PSNR is below the ceiling and the best predicted gain, among
    /// alternatives whose pessimistic (20% quantile) gain is above the floor, exceeds the margin. Candidates are then
    /// accepted in order of expected benefit while the frame's pessimistic total stays within a small budget of its
    /// predicted error, so a few wrong calls can never cost a frame much. Sensitivity 0 = only obvious problems (low
    /// ceiling, big margin, small budget); 1 = strict. `refine` (exhaustive intelligence) also takes any tile where
    /// an alternative is better with high confidence, broken or not. Tiles the blatant-damage classifier flags are
    /// replaced at every sensitivity by the alternative with the best predicted gain.
    func decide(_ m: Measurement, sensitivity: Float, refine: Bool = false) -> Decision {
        var choices = [UInt8](repeating: Choice.primary.rawValue, count: m.count)
        guard let model, let set = model.set(alternative: m.hasAlternative), !set.options.isEmpty else {
            return Decision(choices: choices, shotChange: false)
        }
        if set.isShotChange(m.frame) {
            return Decision(choices: [UInt8](repeating: Choice.nearest.rawValue, count: m.count), shotChange: true)
        }
        let p = set.policy.at(min(1, max(0, sensitivity)))
        let k = set.options.count
        var best = [Int](repeating: 0, count: m.count), bestRisk = [Int](repeating: 0, count: m.count)
        var benefit = [Double](repeating: 0, count: m.count), worst = [Double](repeating: 0, count: m.count)
        var riskBest = [Float](repeating: 0, count: m.count)
        var candidates: [Int] = []
        var errorSum = 0.0
        var g = [Float](repeating: 0, count: k), r = [Float](repeating: 0, count: k)
        var blatant = [Int](repeating: -1, count: m.count)
        for i in 0..<m.count {
            let x = m.features[i]
            let q = set.quality.predict(x)
            let mse = pow(10, -Double(q) / 10)
            errorSum += mse
            let isBlatant = set.blatant.map { $0.predict(x) > set.policy.blatantThreshold } ?? false
            guard q < p.ceiling || refine || isBlatant else { continue }      // the gain and risk trees only matter here
            for j in 0..<k { g[j] = set.options[j].gain.predict(x); r[j] = set.options[j].risk.predict(x) }
            if isBlatant { blatant[i] = (0..<k).max { g[$0] < g[$1] } ?? 0 }
            var b = 0, bv: Float = r[0] > p.floor ? g[0] : -99
            var rb = 0
            for j in 1..<k {
                let v: Float = r[j] > p.floor ? g[j] : -99
                if v > bv { bv = v; b = j }
                if r[j] > r[rb] { rb = j }
            }
            best[i] = b; bestRisk[i] = rb; riskBest[i] = r[rb]
            benefit[i] = mse * (1 - pow(10, -Double(bv) / 10))
            worst[i] = mse * (1 - pow(10, -Double(r[b]) / 10))
            if q < p.ceiling && bv > p.margin { candidates.append(i) }
        }
        candidates.sort { benefit[$0] != benefit[$1] ? benefit[$0] > benefit[$1] : $0 < $1 }
        let allowed = Double(p.budget) * errorSum
        var acc = 0.0
        for i in candidates where acc + worst[i] >= -allowed {
            acc += worst[i]
            choices[i] = set.options[best[i]].choice.rawValue
        }
        if refine {
            for i in 0..<m.count where choices[i] == Choice.primary.rawValue && riskBest[i] > set.policy.refineMargin {
                choices[i] = set.options[bestRisk[i]].choice.rawValue
            }
        }
        for i in 0..<m.count where blatant[i] >= 0 { choices[i] = set.options[blatant[i]].choice.rawValue }
        return Decision(choices: choices, shotChange: false)
    }

    /// Writes the per-tile composite of the chosen candidates into `dst` (a, b: the generation's inputs).
    func compose(primary p: MTLTexture, alternative q: MTLTexture?, a: MTLTexture, b: MTLTexture, t: Float,
                 decision: Decision, into dst: MTLTexture) {
        var u = uniforms(p.width, p.height, t: t)
        let n = decision.choices.count
        if choiceBuffer == nil || choiceBuffer!.length < n { choiceBuffer = ctx.device.makeBuffer(length: max(16, n), options: .storageModeShared) }
        decision.choices.withUnsafeBytes { memcpy(choiceBuffer!.contents(), $0.baseAddress!, n) }
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        for (i, tex) in [p, q ?? p, a, b, dst].enumerated() { enc.setTexture(tex, index: i) }
        enc.setBuffer(choiceBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<QCScoreUniforms>.stride, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("qcComposeKernel"), width: dst.width, height: dst.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

// MARK: - The trained ensembles

/// Gradient-boosted regression trees: every tree is a complete binary tree of fixed depth. A sample goes left when
/// feature < threshold.
struct TreeEnsemble {
    var depth: Int
    var base: Float
    var features: [UInt16]    // trees * (2^depth - 1)
    var thresholds: [Float]
    var leaves: [Float]       // trees * 2^depth
    var trees: Int { leaves.count >> depth }

    func predict(_ x: [Float]) -> Float {
        let inner = (1 << depth) - 1, leafCount = 1 << depth, d = depth, n = trees
        var sum = base
        x.withUnsafeBufferPointer { xs in
            features.withUnsafeBufferPointer { fs in
                thresholds.withUnsafeBufferPointer { ts in
                    leaves.withUnsafeBufferPointer { ls in
                        for k in 0..<n {
                            var node = 0
                            let off = k * inner
                            for _ in 0..<d {
                                node = 2 * node + (xs[Int(fs[off + node])] < ts[off + node] ? 1 : 2)
                            }
                            sum += ls[k * leafCount + node - inner]
                        }
                    }
                }
            }
        }
        return sum
    }
}

/// Thresholds as straight lines in the sensitivity s (0...1): [ceiling, margin, floor, budget] at s = 0 and 1, then the
/// exhaustive refinement margin and the blatant-damage threshold (classifier logit, the same at every sensitivity).
struct ScorerPolicy {
    var values: [Float]
    struct Point { var ceiling: Float, margin: Float, floor: Float, budget: Float }
    func at(_ s: Float) -> Point {
        func v(_ k: Int) -> Float { values[2 * k] + (values[2 * k + 1] - values[2 * k]) * s }
        return Point(ceiling: v(0), margin: v(1), floor: v(2), budget: v(3))
    }
    var refineMargin: Float { values.count > 8 ? values[8] : .infinity }
    var blatantThreshold: Float { values.count > 9 ? values[9] : .infinity }
}

struct ScorerSet {
    struct Option { var choice: ArtifactScorer.Choice; var gain: TreeEnsemble; var risk: TreeEnsemble }
    var quality: TreeEnsemble
    var blatant: TreeEnsemble?     // logit that the tile shows blatant damage
    var options: [Option]          // in training order (scripts/qc_scorer/train.py GAIN_CANDIDATES)
    var policy: ScorerPolicy
    var cutWeights: [Float]      // logistic regression on frameFeatureNames, then bias
    var cutThreshold: Float
    func isShotChange(_ f: [Float]) -> Bool {
        guard cutWeights.count == f.count + 1 else { return false }
        var z = cutWeights[f.count]
        for (w, v) in zip(cutWeights, f) { z += w * v }
        return z > cutThreshold
    }
}

/// Loads the ensembles that scripts/qc_scorer/train.py writes into QCScorerWeights.swift.
final class QCScorerModel {
    static let shared: QCScorerModel? = QCScorerModel()
    private var sets: [Bool: ScorerSet] = [:]

    func set(alternative: Bool) -> ScorerSet? { sets[alternative] }

    private init?() {
        guard let data = Data(base64Encoded: QCScorerWeights.trees, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        var r = Reader(data: data)
        guard r.u32() == 0x5143_5331 else { return nil }                       // "QCS1"
        let names = (0..<Int(r.u32())).map { _ in r.string() }
        guard names == ArtifactScorer.featureNames else {
            Log.error(.interpolation, "Artifact scorer weights were trained on different features; artifact repair is off")
            return nil
        }
        var ensembles: [String: TreeEnsemble] = [:]
        for _ in 0..<Int(r.u32()) {
            let name = r.string()
            let depth = Int(r.u32()), trees = Int(r.u32())
            let base = r.f32()
            let inner = (1 << depth) - 1
            var e = TreeEnsemble(depth: depth, base: base, features: [], thresholds: [], leaves: [])
            for _ in 0..<trees {
                for _ in 0..<inner { e.features.append(UInt16(r.u32())); e.thresholds.append(r.f32()) }
                for _ in 0..<(1 << depth) { e.leaves.append(r.f32()) }
            }
            ensembles[name] = e
        }
        guard !r.failed else { return nil }
        for alt in [true, false] {
            let tag = alt ? "alt" : "noalt"
            guard let q = ensembles["quality.\(tag)"], let p = QCScorerWeights.policies[tag], p.count >= 8,
                  let cut = QCScorerWeights.cut[tag] else { continue }
            var options: [ScorerSet.Option] = []
            for (key, choice) in [("alternative", ArtifactScorer.Choice.alternative), ("blend", .blend), ("nearest", .nearest), ("average", .average)] {
                if let g = ensembles["gain.\(key).\(tag)"], let r = ensembles["risk.\(key).\(tag)"] {
                    options.append(ScorerSet.Option(choice: choice, gain: g, risk: r))
                }
            }
            sets[alt] = ScorerSet(quality: q, blatant: ensembles["blatant.\(tag)"], options: options, policy: ScorerPolicy(values: p),
                                  cutWeights: Array(cut.dropLast()), cutThreshold: cut.last ?? .infinity)
        }
        if sets.isEmpty { return nil }
    }

    private struct Reader {
        let data: Data
        var pos = 0
        var failed = false
        mutating func bytes(_ n: Int) -> Data {
            guard pos + n <= data.count else { failed = true; return Data(count: n) }
            defer { pos += n }
            return data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + n))
        }
        mutating func u32() -> UInt32 { bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        mutating func f32() -> Float { Float(bitPattern: u32()) }
        mutating func string() -> String { String(decoding: bytes(Int(u32())), as: UTF8.self) }
    }
}
