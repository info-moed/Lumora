import Foundation
import Metal
@testable import Lumora

// MARK: - The broken-tile definition (fixed by the harness; every design is scored against it)

/// A 64-px tile of a generated frame is BROKEN when the primary model's output there is
///   (a) clearly wrong in absolute terms: tile PSNR vs ground truth below `absoluteDB`, and
///   (b) clearly fixable: the best of the other run-time candidates (the other RIFE model, either model with
///       horizontal-flip test-time augmentation, a cross-fade, the nearest original) beats it by at least `marginDB`.
/// (a) keeps "hard but correct" texture out (fine detail always scores low-ish without being an artifact); (b) keeps
/// tiles where every candidate fails out (nothing a checker could pick would help) and keeps out the ~0.5 dB
/// candidate-to-candidate noise. PSNR is measured in the encoded signal the pipeline interpolates (BT.1886 gamma for
/// SDR, PQ for HDR10), RGB, per tile.
enum BrokenTile {
    static let absoluteDB = 30.0
    static let marginDB = 2.0
    static let requiredCandidates = ["img", "flow", "imgFlip", "flowFlip", "blend", "nearest"]
    static let definition = "primary tile PSNR < \(absoluteDB) dB AND best other candidate (of \(requiredCandidates.joined(separator: ", "))) at least \(marginDB) dB better (64-px tile, RGB PSNR in the pipeline's encoded signal)"

    static func isBroken(primary: Double, bestOther: Double) -> Bool { primary < absoluteDB && bestOther - primary >= marginDB }

    static func flags(_ r: RefFrame) -> [Bool] {
        let others = requiredCandidates.filter { $0 != r.primary }
        return (0..<r.px.count).map { i in
            let p = Double(r.candPSNR[r.primary]![i])
            let best = others.compactMap { r.candPSNR[$0]?[i] }.map(Double.init).max() ?? p
            return isBroken(primary: p, bestOther: best)
        }
    }
}

// MARK: - Dataset records

/// The truth for one generated frame of the dataset: every candidate's PSNR/SSIM per tile and per frame.
struct RefFrame: Codable {
    var key: String
    var window: String
    var split: String
    var mode: String
    var ti: Int
    var t: Float
    var frame: Int
    var stratum: String
    var motion: Float
    var primary: String
    var tilesX: Int, tilesY: Int
    var px: [Float]
    var candPSNR: [String: [Float]]
    var candSSIM: [String: [Float]]
    var framePSNR: [String: Double]
    var frameSSIM: [String: Double]
    /// What the current checker's rules see for the primary output: per-tile interpQCKernel counts at the thresholds of
    /// sensitivity 0 / 0.5 / 1 (and grain-aware 0.5), and frame-level flicker inputs.
    var qcCounts: [String: [Float]] = [:]
    var rules: [String: Float] = [:]

    /// Per-tile best of `cands` (by squared error), as a frame PSNR: the oracle that switches candidates per tile.
    func oraclePSNR(_ cands: [String]) -> Double {
        var sse = 0.0, n = 0.0
        for i in 0..<px.count {
            let best = cands.compactMap { candPSNR[$0]?[i] }.max() ?? 0
            sse += pow(10, -Double(best) / 10) * 3 * Double(px[i])
            n += Double(px[i])
        }
        return TileErr.psnr(sse / max(1, 3 * n))
    }
}

struct Triplet {
    var mode: String
    var a: Int, b: Int
    var times: [Float]
    var truths: [Int]

    static func of(_ w: QCWindow) -> [Triplet] {
        let c = w.center
        return [Triplet(mode: "30->60", a: c - 1, b: c + 1, times: [0.5], truths: [c]),
                Triplet(mode: "15->60", a: c - 2, b: c + 2, times: [0.25, 0.5, 0.75], truths: [c - 1, c, c + 1])]
    }
}

/// Builds every candidate, reference-free feature and true error for the dataset.
final class TripletLab {
    let gpu = BenchGPU.shared
    let provider: FrameProvider
    private var engines: [String: CoreMLInterpolator] = [:]
    private let grain = GrainProcessor()
    private let renderer = GradeRenderer()
    private(set) var modelMs: [String: [Double]] = [:]     // "<model> <width>" -> ms per generated frame

    static let featureNames = ["tx", "ty", "edge", "luma", "d_ab", "grad_a", "grad_p", "d_alt", "d_flip", "d_altflip", "d_blend",
                               "d_near", "excess", "flipfrac", "dmax_alt", "dmax_flip",
                               "qc_s0", "qc_s05", "qc_s1", "qc_g05", "qc_alt_s05", "qc_px",
                               "fc_count", "fl_mask", "fl_occ", "fl_mag0", "fl_mag1", "fl_err", "fl_errfrac", "fl_errfrac_vis", "fl_px", "fl_max"]
    static let candidates = ["img", "flow", "imgFlip", "flowFlip", "imgTTA", "flowTTA", "blend", "nearest", "flickerFix"]

    init(provider: FrameProvider) { self.provider = provider }

    func engine(_ id: String, _ color: SourceColor) throws -> CoreMLInterpolator {
        let key = "\(id)|\(color.name)"
        if let e = engines[key] { return e }
        guard let spec = InterpolationModelSpec.all().first(where: { $0.id == id && $0.isInstalled }) else {
            throw LumoraError.unsupported("model \(id) is not installed")
        }
        let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        engines[key] = e
        return e
    }

    private func timed<T>(_ key: String, frames: Int, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = try body()
        modelMs[key, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(max(1, frames)))
        return r
    }

    struct Output {
        var refs: [RefFrame] = []
        var tileRows: [String] = []
        var frameRows: [String] = []
    }

    static var tileHeader: String {
        (["split", "window", "mode", "ti", "t", "frame", "stratum", "motion"] + featureNames
         + candidates.map { "p_\($0)" } + candidates.map { "s_\($0)" } + ["primary", "best", "broken"]).joined(separator: ",")
    }
    static var frameHeader: String {
        (["split", "window", "mode", "ti", "t", "frame", "stratum", "motion", "primary"] + candidates.map { "psnr_\($0)" }
         + candidates.map { "ssim_\($0)" }
         + ["psnr_oracle6", "psnr_oracleAll", "qcfrac_s0", "qcfrac_s05", "qcfrac_s1", "qcfrac_g05", "fcfrac", "replace_s0", "replace_s05",
            "replace_s1", "flick_before", "flick_after", "flick_median", "flick_flag", "broken_tiles", "tiles"]).joined(separator: ",")
    }

    func process(_ w: QCWindow) throws -> Output {
        var out = Output()
        let color = provider.color(w)
        var frames: [Int: MTLTexture] = [:]
        for n in (w.center - 2)...(w.center + 2) { frames[n] = try provider.frame(w, n) }
        let primaryIsFlow = w.variant == "hdr"
        let img = try engine(QCBench.imageModel, color), flow = try engine(QCBench.flowModel, color)
        let isGrain = w.variant == "grain"
        let first = frames[w.center]!
        let grid = TileGrid(first)
        let res = "\(first.width)"
        var sigma: Float = 0
        if isGrain { sigma = max(0.002, grain.measure(frames[w.center - 2]!).overall) }
        func clean(_ t: MTLTexture) -> MTLTexture {
            guard isGrain else { return t }
            let o = gpu.like(t)
            gpu.run { cb in grain.denoise(cb, t, into: o, sigma: sigma) }
            return o
        }
        for tr in Triplet.of(w) {
            let A = frames[tr.a]!, B = frames[tr.b]!
            let ga = clean(A), gb = clean(B)
            let af = gpu.flip(ga), bf = gpu.flip(gb)
            let n = tr.times.count
            let tiles = (grid.tilesX, grid.tilesY)
            let imgOut = (0..<n).map { _ in gpu.like(ga) }
            _ = try timed("\(QCBench.imageModel) \(res)", frames: n) { try img.interpolate(ga, gb, times: tr.times, into: imgOut, qcTiles: tiles) }
            let imgFlipRaw = (0..<n).map { _ in gpu.like(ga) }
            _ = try img.interpolate(af, bf, times: tr.times, into: imgFlipRaw, qcTiles: tiles)
            var flowOut: [MTLTexture] = [], flowFeat: [[[Float]]] = []
            for t in tr.times {
                let o = gpu.like(ga)
                _ = try timed("\(QCBench.flowModel) \(res)", frames: 1) { try flow.interpolate(ga, gb, times: [t], into: [o], qcTiles: tiles) }
                flowOut.append(o)
                flowFeat.append(gpu.flowStats(flow, t: t, full: grid))
            }
            let flowFlipRaw = (0..<n).map { _ in gpu.like(ga) }
            _ = try flow.interpolate(af, bf, times: tr.times, into: flowFlipRaw, qcTiles: tiles)
            let imgFlip = imgFlipRaw.map { gpu.flip($0) }, flowFlip = flowFlipRaw.map { gpu.flip($0) }

            var cands: [[String: MTLTexture]] = []
            for k in 0..<n {
                let t = tr.times[k]
                var c: [String: MTLTexture] = ["img": imgOut[k], "flow": flowOut[k], "imgFlip": imgFlip[k], "flowFlip": flowFlip[k]]
                c["imgTTA"] = gpu.blend(imgOut[k], imgFlip[k], t: 0.5)
                c["flowTTA"] = gpu.blend(flowOut[k], flowFlip[k], t: 0.5)
                c["blend"] = gpu.blend(ga, gb, t: t)
                c["nearest"] = gpu.copy(t < 0.5 ? ga : gb)
                cands.append(c)
            }
            let pKey = primaryIsFlow ? "flow" : "img", qKey = primaryIsFlow ? "img" : "flow"
            // Flicker check inputs, exactly as FrameStream computes them (on the primary chain, before regraining).
            var flick: [(Float, Float, Float, Bool)] = Array(repeating: (.nan, .nan, .nan, false), count: n)
            if n >= 2 {
                let chain = [ga] + cands.map { $0[pKey]! } + [gb]
                let steps = (0..<(chain.count - 1)).map { renderer.blendErrors(chain[$0], chain[$0 + 1], chain[$0 + 1], t: 0).motion }
                let median = steps.sorted()[steps.count / 2]
                for k in 0..<n {
                    let flag = median > 0.002 && steps[k] > median * 2.2 && steps[k + 1] > median * 2.2
                    flick[k] = (steps[k], steps[k + 1], median, flag)
                    cands[k]["flickerFix"] = gpu.blend(chain[k], chain[k + 2], t: 0.5)
                }
            }
            for k in 0..<n {
                let t = tr.times[k]
                let c = cands[k]
                let P = c[pKey]!, Q = c[qKey]!
                let feat = gpu.tileFeatures(a: ga, b: gb, primary: P, alt: Q, primaryFlip: c[pKey + "Flip"]!, altFlip: c[qKey + "Flip"]!, blend: c["blend"]!)
                let q0 = gpu.qcCounts(a: ga, b: gb, mid: P, threshold: 0.10, smooth: false)
                let q5 = gpu.qcCounts(a: ga, b: gb, mid: P, threshold: 0.07, smooth: false)
                let q1 = gpu.qcCounts(a: ga, b: gb, mid: P, threshold: 0.04, smooth: false)
                let qg = gpu.qcCounts(a: ga, b: gb, mid: P, threshold: 0.07, smooth: true)
                let qa = gpu.qcCounts(a: ga, b: gb, mid: Q, threshold: 0.07, smooth: false)
                // Grain-aware: every candidate gets its grain back the way FrameStream does (nearest real frame, offset).
                var final = c
                if isGrain {
                    let near = t < 0.5 ? A : B, cleanNear = t < 0.5 ? ga : gb
                    for (name, tex) in c {
                        let o = gpu.like(tex)
                        gpu.run { cb in grain.regrain(cb, cleanMid: tex, origNear: near, cleanNear: cleanNear, into: o, seed: k + 1) }
                        final[name] = o
                    }
                }
                let truth = frames[tr.truths[k]]!
                let names = Self.candidates.filter { final[$0] != nil }
                let errs = gpu.tileErrors(names.map { (final[$0]!, truth) })
                var ref = RefFrame(key: "\(w.id)|\(tr.mode)|\(k)", window: w.id, split: w.split, mode: tr.mode, ti: k, t: t, frame: tr.truths[k],
                                   stratum: w.stratum, motion: w.motion, primary: pKey, tilesX: grid.tilesX, tilesY: grid.tilesY,
                                   px: errs[0].px, candPSNR: [:], candSSIM: [:], framePSNR: [:], frameSSIM: [:])
                for (j, name) in names.enumerated() {
                    ref.candPSNR[name] = (0..<grid.count).map { Float(errs[j].tilePSNR($0)) }
                    ref.candSSIM[name] = (0..<grid.count).map { Float(errs[j].tileSSIM($0)) }
                    ref.framePSNR[name] = errs[j].psnr
                    ref.frameSSIM[name] = errs[j].ssim
                }
                ref.qcCounts = ["s0": q0, "s05": q5, "s1": q1, "g05": qg]
                ref.rules = ["flickBefore": flick[k].0, "flickAfter": flick[k].1, "flickMedian": flick[k].2, "flickFlag": flick[k].3 ? 1 : 0]
                let broken = BrokenTile.flags(ref)
                let fl = flowFeat[k]
                // Current rule (InterpolationQC.score): a tile is bad when its count exceeds 1024 * (0.08 - 0.05 s).
                let lim: (Float) -> Float = { s in Float(QCBench.tile * QCBench.tile / 4) * (0.08 - 0.05 * s) }
                func frac(_ q: [Float], _ s: Float) -> Float { Float(q.filter { $0 > lim(s) }.count) / Float(grid.count) }
                let perTileModel = Float(flow.dims.cw * flow.dims.ch) / Float(grid.count)
                let fcfrac = Float(fl.filter { $0[0] > perTileModel * 0.06 }.count) / Float(grid.count)
                for i in 0..<grid.count {
                    let tx = i % grid.tilesX, ty = i / grid.tilesX
                    let edge = tx == 0 || ty == 0 || tx == grid.tilesX - 1 || ty == grid.tilesY - 1
                    let f = feat[i]
                    var row: [String] = [w.split, w.id, tr.mode, "\(k)", "\(t)", "\(tr.truths[k])", w.stratum, fmt(w.motion), "\(tx)", "\(ty)", edge ? "1" : "0"]
                    row += [f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[10], f[11], f[12], f[13]].map { fmt($0) }
                    row += [q0[i], q5[i], q1[i], qg[i], qa[i], Float(grid.sampledPixels(i))].map { fmt($0) }
                    row += (fl.isEmpty ? [Float](repeating: .nan, count: 10) : fl[i]).map { fmt($0) }
                    row += Self.candidates.map { ref.candPSNR[$0].map { fmt($0[i]) } ?? "" }
                    row += Self.candidates.map { ref.candSSIM[$0].map { fmt($0[i], 4) } ?? "" }
                    let best = BrokenTile.requiredCandidates.max { (ref.candPSNR[$0]?[i] ?? 0) < (ref.candPSNR[$1]?[i] ?? 0) }!
                    row += [pKey, best, broken[i] ? "1" : "0"]
                    out.tileRows.append(row.joined(separator: ","))
                }
                func replace(_ q: [Float], _ s: Float) -> String { frac(q, s) > 0.35 ? "1" : "0" }
                var frow: [String] = [w.split, w.id, tr.mode, "\(k)", "\(t)", "\(tr.truths[k])", w.stratum, fmt(w.motion), pKey]
                frow += Self.candidates.map { ref.framePSNR[$0].map { fmt(Float($0)) } ?? "" }
                frow += Self.candidates.map { ref.frameSSIM[$0].map { fmt(Float($0), 4) } ?? "" }
                frow += [fmt(Float(ref.oraclePSNR(BrokenTile.requiredCandidates))), fmt(Float(ref.oraclePSNR(names)))]
                frow += [frac(q0, 0), frac(q5, 0.5), frac(q1, 1), frac(qg, 0.5), fcfrac].map { fmt($0, 4) }
                frow += [replace(q0, 0), replace(q5, 0.5), replace(q1, 1)]
                frow += [fmt(flick[k].0, 5), fmt(flick[k].1, 5), fmt(flick[k].2, 5), flick[k].3 ? "1" : "0", "\(broken.filter { $0 }.count)", "\(grid.count)"]
                out.frameRows.append(frow.joined(separator: ","))
                out.refs.append(ref)
            }
        }
        return out
    }
}

func fmt(_ v: Float, _ digits: Int = 3) -> String { v.isFinite ? String(format: "%.\(digits)f", v) : "" }
func fmt(_ v: Double, _ digits: Int = 3) -> String { v.isFinite ? String(format: "%.\(digits)f", v) : "" }

// MARK: - Policy evaluation through the real FrameStream

/// One generated frame of one configuration, scored against ground truth and against the raw primary output.
struct FrameEval: Codable {
    var key: String
    var mode: String
    var stratum: String
    var psnrRaw: Double, psnrPolicy: Double
    var ssimRaw: Double, ssimPolicy: Double
    var tiles: Int
    var broken: Int
    var changed: Int
    var brokenChanged: Int
    var brokenFixed: Int
    var harmful: Int
    var held: Bool?
    var datasetPrimaryPSNR: Double?
}

struct Metrics: Codable {
    var frames: Int
    var psnrRaw: Double, psnrPolicy: Double, gainMean: Double
    var gainWorst10: Double, worst10RawPSNR: Double
    var ssimRaw: Double, ssimPolicy: Double
    var fracDropOver0_1dB: Double, worstDropDB: Double, framesChanged: Int
    var brokenTiles: Int, changedTiles: Int, brokenChanged: Int, brokenFixed: Int, harmfulChanges: Int
    var recall: Double, precision: Double, fixedRecall: Double
    var heldFraction: Double?
    var rawVsDatasetMaxAbsDB: Double?

    init(_ f: [FrameEval]) {
        frames = f.count
        func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }
        psnrRaw = mean(f.map(\.psnrRaw)); psnrPolicy = mean(f.map(\.psnrPolicy)); gainMean = psnrPolicy - psnrRaw
        let worst = f.sorted { $0.psnrRaw < $1.psnrRaw }.prefix(max(1, f.count / 10))
        gainWorst10 = mean(worst.map { $0.psnrPolicy - $0.psnrRaw }); worst10RawPSNR = mean(worst.map(\.psnrRaw))
        ssimRaw = mean(f.map(\.ssimRaw)); ssimPolicy = mean(f.map(\.ssimPolicy))
        let d = f.map { $0.psnrPolicy - $0.psnrRaw }
        fracDropOver0_1dB = f.isEmpty ? 0 : Double(d.filter { $0 < -0.1 }.count) / Double(f.count)
        worstDropDB = max(0, -(d.min() ?? 0))
        framesChanged = f.filter { $0.changed > 0 }.count
        brokenTiles = f.reduce(0) { $0 + $1.broken }; changedTiles = f.reduce(0) { $0 + $1.changed }
        brokenChanged = f.reduce(0) { $0 + $1.brokenChanged }; brokenFixed = f.reduce(0) { $0 + $1.brokenFixed }
        harmfulChanges = f.reduce(0) { $0 + $1.harmful }
        recall = brokenTiles > 0 ? Double(brokenChanged) / Double(brokenTiles) : .nan
        precision = changedTiles > 0 ? Double(brokenChanged) / Double(changedTiles) : .nan
        fixedRecall = brokenTiles > 0 ? Double(brokenFixed) / Double(brokenTiles) : .nan
        let held = f.compactMap(\.held)
        heldFraction = held.isEmpty ? nil : Double(held.filter { $0 }.count) / Double(held.count)
        let dd = f.compactMap { r in r.datasetPrimaryPSNR.map { abs($0 - r.psnrRaw) } }
        rawVsDatasetMaxAbsDB = dd.max()
    }
}

struct ConfigResult: Codable {
    var label: String
    var split: String
    var analysis: String
    var settings: String
    var all: Metrics
    var byMode: [String: Metrics]
    var byStratum: [String: Metrics]
    var actions: [String: Int]
    var msPerFrameRaw: Double, msPerFramePolicy: Double, addedMs: Double, addedPct: Double
    var resolution: String
    var frames: [FrameEval]
}

/// Runs the raw primary model (artifact repair off) and any number of policies in lockstep through the real
/// `FrameStream`, over every window of a split, and scores each generated frame.
final class PolicyEvaluator {
    let gpu = BenchGPU.shared
    let provider: FrameProvider
    let refs: [String: RefFrame]

    init(provider: FrameProvider, refs: [String: RefFrame]) { self.provider = provider; self.refs = refs }

    static func baseSettings(split: String) -> InterpolationSettings {
        var s = InterpolationSettings()
        s.primaryModelID = split == "testHDR" ? QCBench.flowModel : QCBench.imageModel
        if let r = QCBench.env["LUMORA_QC_REPAIR_MODEL"] { s.repairModelID = r == "none" ? nil : r }
        s.grainAware = split == "testGrain"
        s.intelligence = MotionIntelligence.allCases.first { "\($0)" == (QCBench.env["LUMORA_QC_INTELLIGENCE"] ?? "") } ?? .eachFrame
        if QCBench.env["LUMORA_QC_FLICKER"] == "0" { s.flickerCheck = false }
        return s
    }

    static func describe(_ s: InterpolationSettings) -> String {
        "primary \(s.primaryModelID), repair \(s.repairModelID ?? "none") (installed: \(s.repairModelID.map { id in InterpolationModelSpec.all().contains { $0.id == id && $0.isInstalled } } ?? false)), artifactRepair \(s.artifactRepair), sensitivity \(s.sensitivity), grainAware \(s.grainAware), flickerCheck \(s.flickerCheck), intelligence \(s.intelligence)"
    }

    /// - analysis: "plain" (one shot), "cutKnown" (the analyzer found the cut between the two inputs) or
    ///   "fadeKnown" (the analyzer found a dissolve spanning them). Decides what the planner does.
    func run(split: String, windows: [QCWindow], configs: [(String, InterpolationSettings)], analysis: String = "plain") throws -> [ConfigResult] {
        var evals = [[FrameEval]](repeating: [], count: configs.count)
        var times = [Double](repeating: 0, count: configs.count + 1)
        var timedFrames = 0
        var generated = 0
        var actions = [[String: Int]](repeating: [:], count: configs.count)
        var resolution = ""
        for mode in ["30->60", "15->60"] {
            let factor = mode == "30->60" ? 2 : 4
            let (plan, sources, genInfo) = Self.build(windows, mode: mode, analysis: analysis, settings: configs[0].1)
            // Source frames are prepared outside the timed region and shared by every stream (FrameStream never writes them).
            var pool: [Int: MTLTexture] = [:]
            let first = try provider.frame(sources[0].0, sources[0].1)
            resolution = "\(first.width)x\(first.height)"
            pool[0] = first
            let loaders: [() throws -> MTLTexture] = sources.indices.map { i in { pool[i]! } }
            let color = provider.color(windows[0])
            let proxy = UniformBuilder.analysis(source: color, gridW: 1, gridH: 1)
            // streams[0] is the raw reference (configs[0] with artifact repair off), streams[1...] the configs.
            var raw0 = configs[0].1
            raw0.artifactRepair = false
            var streams: [FrameStream] = []
            for cs in [raw0] + configs.map(\.1) {
                var s = cs
                s.mode = .multiply(factor)
                streams.append(try FrameStream(source: SequenceFrameSource(width: first.width, height: first.height, loaders: loaders),
                                               plan: plan[...], settings: s, proxyUniforms: proxy, sceneOf: { $0 / 2 }))
            }
            // Every step drains its own autorelease pool: command buffers and per-frame buffers otherwise pile up
            // until the test host is killed (measured: SIGKILL after ~2.5 min on the train split).
            for i in plan.indices { try autoreleasepool {
                let need = max(plan[i].a, plan[i].b)
                for j in 0...need where pool[j] == nil { pool[j] = try provider.frame(sources[j].0, sources[j].1) }
                let keep = min(plan[i].a, plan[i].b)
                for j in pool.keys where j < keep - 1 { pool[j] = nil }
                var outs: [StreamFrame] = []
                for (k, st) in streams.enumerated() {
                    guard let f = try st.next() else { throw LumoraError.decodeFailed("stream \(k) ended early at \(i)") }
                    precondition(f.outputIndex == i, "stream \(k) out of step: \(f.outputIndex) vs \(i)")
                    outs.append(f)
                }
                guard let (w, ti, truthIdx) = genInfo[i] else { return }
                generated += 1
                let truth = try provider.frame(w, truthIdx)
                let ref = refs["\(w.id)|\(mode)|\(ti)"]
                let broken = ref.map(BrokenTile.flags)
                var pairs: [(MTLTexture, MTLTexture)] = [(outs[0].texture, truth)]
                for k in 1..<outs.count { pairs.append((outs[k].texture, truth)); pairs.append((outs[k].texture, outs[0].texture)) }
                let errs = gpu.tileErrors(pairs)
                let rawErr = errs[0]
                var heldInputs: [TileErr] = []
                if split == "cut" || split == "fade" {
                    let tr = Triplet.of(w).first { $0.mode == mode }!
                    let A = try provider.frame(w, tr.a), B = try provider.frame(w, tr.b)
                    heldInputs = gpu.tileErrors(outs.flatMap { [($0.texture, A), ($0.texture, B)] })
                }
                for k in 1..<outs.count {
                    let e = errs[1 + (k - 1) * 2], d = errs[2 + (k - 1) * 2]
                    var fe = FrameEval(key: "\(w.id)|\(mode)|\(ti)", mode: mode, stratum: w.stratum, psnrRaw: rawErr.psnr, psnrPolicy: e.psnr,
                                       ssimRaw: rawErr.ssim, ssimPolicy: e.ssim, tiles: e.px.count, broken: 0, changed: 0, brokenChanged: 0,
                                       brokenFixed: 0, harmful: 0, held: nil, datasetPrimaryPSNR: ref?.framePSNR[ref!.primary])
                    for t in 0..<e.px.count {
                        // Changed: the policy's tile differs from the raw output by more than rounding (PSNR vs raw < 70 dB).
                        let changed = d.tilePSNR(t) < 70
                        let gain = e.tilePSNR(t) - rawErr.tilePSNR(t)
                        let isBroken = broken?[t] ?? false
                        if changed { fe.changed += 1 }
                        if isBroken { fe.broken += 1 }
                        if changed && isBroken { fe.brokenChanged += 1 }
                        if isBroken && gain >= 1 { fe.brokenFixed += 1 }
                        if changed && gain < -0.5 { fe.harmful += 1 }
                    }
                    if !heldInputs.isEmpty {
                        fe.held = max(heldInputs[k * 2].psnr, heldInputs[k * 2 + 1].psnr) > 60
                    }
                    evals[k - 1].append(fe)
                }
            } }
            for k in 1..<streams.count {
                for ev in streams[k].events { actions[k - 1][ev.action.rawValue, default: 0] += 1 }
            }
            streams.forEach { $0.cancel() }
            streams.removeAll()
            pool.removeAll()
            // Cost: each configuration alone (lockstep timings interfere), on a subset, after one warm-up window.
            let t = try timing(Array(windows.prefix(Self.timingWindows + 1)), mode: mode, analysis: analysis,
                               settings: [raw0] + configs.map(\.1))
            for k in times.indices { times[k] += t.ms[k] * Double(t.frames) }
            timedFrames += t.frames
        }
        var results: [ConfigResult] = []
        let rawMs = times[0] / Double(max(1, timedFrames))
        for (k, (label, s)) in configs.enumerated() {
            let f = evals[k]
            var byMode: [String: Metrics] = [:], bySt: [String: Metrics] = [:]
            for m in Set(f.map(\.mode)) { byMode[m] = Metrics(f.filter { $0.mode == m }) }
            for st in Set(f.map(\.stratum)) { bySt[st] = Metrics(f.filter { $0.stratum == st }) }
            let ms = times[k + 1] / Double(max(1, timedFrames))
            results.append(ConfigResult(label: label, split: split, analysis: analysis, settings: Self.describe(s), all: Metrics(f),
                                        byMode: byMode, byStratum: bySt, actions: actions[k], msPerFrameRaw: rawMs, msPerFramePolicy: ms,
                                        addedMs: ms - rawMs, addedPct: rawMs > 0 ? 100 * (ms - rawMs) / rawMs : .nan,
                                        resolution: resolution, frames: f))
        }
        return results
    }

    static let timingWindows = 12

    /// The concatenated plan for a split: each window's two inputs become two source frames, planned by the real
    /// InterpolationPlanner with the window's analysis. Returns output index -> (window, ti, truth frame) for every
    /// non-original output.
    static func build(_ windows: [QCWindow], mode: String, analysis: String, settings: InterpolationSettings)
        -> ([PlannedFrame], [(QCWindow, Int)], [Int: (QCWindow, Int, Int)]) {
        let factor = mode == "30->60" ? 2 : 4
        var plan: [PlannedFrame] = []
        var sources: [(QCWindow, Int)] = []
        var genInfo: [Int: (QCWindow, Int, Int)] = [:]
        for w in windows {
            let tr = Triplet.of(w).first { $0.mode == mode }!
            let base = sources.count
            sources.append((w, tr.a)); sources.append((w, tr.b))
            let a: AnalysisResult
            switch analysis {
            case "cutKnown": a = Self.analysis(cuts: [1])
            case "fadeKnown": a = Self.analysis(transitions: [TransitionSpan(start: 0, end: 2, kind: .dissolve)])
            default: a = Self.analysis()
            }
            var s = settings
            s.mode = .multiply(factor)
            let (p, _) = InterpolationPlanner.plan(sourceFrames: 2, sourceRate: (30 / (factor / 2), 1), settings: s, analysis: a)
            var ti = 0
            for f in p {
                if f.kind != .original { genInfo[plan.count] = (w, ti, tr.truths[min(ti, tr.truths.count - 1)]); ti += 1 }
                plan.append(PlannedFrame(a: f.a + base, b: f.b + base, t: f.t, kind: f.kind))
            }
        }
        return (plan, sources, genInfo)
    }

    /// Wall time per generated frame of each settings run alone through FrameStream (source frames preloaded, the
    /// first window is warm-up and not counted).
    func timing(_ windows: [QCWindow], mode: String, analysis: String, settings: [InterpolationSettings]) throws -> (ms: [Double], frames: Int) {
        let (plan, sources, genInfo) = Self.build(windows, mode: mode, analysis: analysis, settings: settings[0])
        let textures = try sources.map { try provider.frame($0.0, $0.1) }
        let proxy = UniformBuilder.analysis(source: provider.color(windows[0]), gridW: 1, gridH: 1)
        let factor = mode == "30->60" ? 2 : 4
        let warm = plan.firstIndex { $0.a >= 2 } ?? plan.count
        var ms: [Double] = []
        var counted = 0
        for cs in settings {
            var s = cs
            s.mode = .multiply(factor)
            let st = try FrameStream(source: SequenceFrameSource(width: textures[0].width, height: textures[0].height,
                                                                 loaders: textures.map { t in { t } }),
                                     plan: plan[...], settings: s, proxyUniforms: proxy, sceneOf: { $0 / 2 })
            var total = 0.0
            counted = 0
            var i = 0
            var done = false
            while !done { try autoreleasepool {
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard let f = try st.next() else { done = true; return }
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                if i >= warm { total += dt; if genInfo[f.outputIndex] != nil { counted += 1 } }
                i += 1
            } }
            st.cancel()
            ms.append(total / Double(max(1, counted)))
        }
        return (ms, counted)
    }

    static func analysis(cuts: [Int] = [], transitions: [TransitionSpan] = []) -> AnalysisResult {
        let starts = [0] + cuts
        let scenes = starts.enumerated().map { k, s in
            SceneStats(start: s, end: k + 1 < starts.count ? starts[k + 1] : 2, keyStops: 0, p005: -6, p50: 0, p995: 3, skinFraction: 0, avgChroma: 0)
        }
        return AnalysisResult(frameCount: 2, scenes: scenes, transitions: transitions, cutFrames: Set(starts), duplicateFrames: [],
                              globalKey: 0, globalP005: -6, globalP995: 3, skinFraction: 0, avgChroma: 0, globalHistogram: [], motion: [])
    }
}
