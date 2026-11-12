import XCTest
import Metal
@testable import Lumora

/// Training and validation data for the learned artifact scorer (ArtifactScorer), built with the app's own feature
/// code so the trees see exactly what FrameStream measures at run time. Skipped unless LUMORA_QC_BENCH=1.
///
/// Only the train and validation parts of the story are used. Besides the plain SDR windows it builds variants of
/// those same windows: HDR10 (primary = flow model), SDR with the flow model as primary, film grain (validation only),
/// UHD from the 2160p render (validation only), and fake shot changes (frame A of one window, frame B of another) for
/// the shot-change test. Output: ~/Library/Caches/Lumora-Bench/qc-scorer/<set>.csv (one row per tile) and
/// <set>-frames.csv (one row per generated frame). Train with scripts/qc_scorer/train.py.
///
///   LUMORA_QC_SCORER_SETS=train,val,...   which sets to build (default: all of them)
final class QCScorerTrainingTests: XCTestCase {
    static let out = QCBench.root.appendingPathComponent("qc-scorer", isDirectory: true)
    static let candidates = ["P", "Q", "blend", "nearest", "average"]

    override func setUpWithError() throws {
        guard QCBench.env["LUMORA_QC_BENCH"] == "1" else { throw XCTSkip("QC scorer data: set LUMORA_QC_BENCH=1") }
        try TestHardware.requireGPU()
        let installed = InterpolationModelSpec.all().filter(\.isInstalled).map(\.id)
        guard installed.contains(QCBench.imageModel), installed.contains(QCBench.flowModel) else {
            throw XCTSkip("RIFE 4.25 image and flow models must be installed")
        }
        QCBench.ensureDir(Self.out)
    }

    struct DataSet {
        var name: String
        var windows: [QCWindow]
        var primary: String
        var grain = false
        var fakeCuts = false
    }

    static func sets(_ m: QCManifest) -> [DataSet] {
        let train = m.windows.filter { $0.split == "train" }, val = m.windows.filter { $0.split == "val" }
        func variant(_ ws: [QCWindow], _ name: String, _ v: String, source: String? = nil) -> [QCWindow] {
            ws.enumerated().map { i, w in
                var c = w
                c.id = WindowSelector.id(name, i)
                c.split = name
                c.variant = v
                if let source { c.source = source }
                c.note = "same frames as \(w.id)"
                return c
            }
        }
        func perStratum(_ ws: [QCWindow], _ k: Int) -> [QCWindow] {
            QCBench.strata.flatMap { st in ws.filter { $0.stratum == st.0 }.prefix(k) }
        }
        return [
            DataSet(name: "train", windows: train, primary: QCBench.imageModel),
            DataSet(name: "val", windows: val, primary: QCBench.imageModel),
            DataSet(name: "trainFlow", windows: train, primary: QCBench.flowModel),
            DataSet(name: "valFlow", windows: val, primary: QCBench.flowModel),
            DataSet(name: "trainHDR", windows: variant(train, "trainHDR", "hdr"), primary: QCBench.flowModel),
            DataSet(name: "valHDR", windows: variant(val, "valHDR", "hdr"), primary: QCBench.flowModel),
            DataSet(name: "valGrain", windows: variant(perStratum(val, 6), "valGrain", "grain"), primary: QCBench.imageModel, grain: true),
            DataSet(name: "val4k", windows: variant(perStratum(val, 4), "val4k", "sdr", source: "bbb2160"), primary: QCBench.imageModel),
            DataSet(name: "trainCuts", windows: train, primary: QCBench.imageModel, fakeCuts: true),
            DataSet(name: "valCuts", windows: val, primary: QCBench.imageModel, fakeCuts: true),
            DataSet(name: "trainHDRCuts", windows: variant(train, "trainHDR", "hdr"), primary: QCBench.flowModel, fakeCuts: true),
        ]
    }

    func test4_ScorerDataset() async throws {
        let (m, provider) = try await QCBenchmarkTests.prepare()
        let wanted = QCBench.env["LUMORA_QC_SCORER_SETS"].map { Set($0.split(separator: ",").map(String.init)) }
        let all = Self.sets(m).filter { wanted?.contains($0.name) ?? true }
        // Extra frames (UHD, grain) for the variant windows.
        var extra = m
        extra.windows = all.flatMap(\.windows).filter { $0.source == "bbb2160" || $0.variant == "grain" }
        if !extra.windows.isEmpty { try await QCBenchmarkTests.ensureFrames(extra) }
        let builder = ScorerDataBuilder(provider: provider)
        for set in all {
            let started = Date()
            var tiles = (["set", "window", "mode", "ti", "t", "stratum", "motion", "primary", "tilesX", "tilesY", "scale", "tile"]
                         + ArtifactScorer.featureNames + ["px"] + Self.candidates.map { "p_\($0)" } + ["broken"]).joined(separator: ",") + "\n"
            var frames = (["set", "window", "mode", "ti", "t", "stratum", "motion", "primary", "fakeCut"] + ArtifactScorer.frameFeatureNames
                          + Self.candidates.map { "psnr_\($0)" }).joined(separator: ",") + "\n"
            let refs = (try? QCBenchmarkTests.loadRefs(set.name)) ?? [:]
            var ws = set.windows
            if let l = QCBench.env["LUMORA_QC_LIMIT"].flatMap(Int.init) { ws = Array(ws.prefix(l)) }
            for (i, w) in ws.enumerated() {
                let partner = set.fakeCuts ? ws[(i + ws.count / 2 + 1) % ws.count] : nil
                let o = try autoreleasepool { try builder.process(w, set: set, partner: partner, refs: set.primary == QCBench.imageModel ? refs : [:]) }
                tiles += o.tiles.joined(separator: "\n") + (o.tiles.isEmpty ? "" : "\n")
                frames += o.frames.joined(separator: "\n") + "\n"
                if i % 20 == 19 || i == ws.count - 1 { QCBench.log("scorer data \(set.name): \(i + 1)/\(ws.count) windows, \(Int(Date().timeIntervalSince(started))) s") }
            }
            if !set.fakeCuts { try tiles.write(to: Self.out.appendingPathComponent("\(set.name).csv"), atomically: true, encoding: .utf8) }
            try frames.write(to: Self.out.appendingPathComponent("\(set.name)-frames.csv"), atomically: true, encoding: .utf8)
        }
        let timing = builder.ms.mapValues { v -> Double in let s = v.sorted(); return s[s.count / 2] }
        QCBench.log("scorer timing (median ms per generated frame): \(timing.sorted { $0.key < $1.key }.map { "\($0.key) \(fmt($0.value, 1))" }.joined(separator: ", "))")
        try QCBenchmarkTests.encoder.encode(timing).write(to: Self.out.appendingPathComponent("timing-\(Int(Date().timeIntervalSince1970)).json"))
    }
}

/// Runs the real engines and the app's ArtifactScorer feature code on one window and scores every candidate tile
/// against ground truth.
final class ScorerDataBuilder {
    let gpu = BenchGPU.shared
    let provider: FrameProvider
    let scorer = ArtifactScorer()
    private let grain = GrainProcessor()
    private var engines: [String: CoreMLInterpolator] = [:]
    var ms: [String: [Double]] = [:]

    init(provider: FrameProvider) { self.provider = provider }

    func engine(_ id: String, _ color: SourceColor, alternative: Bool) throws -> CoreMLInterpolator {
        let key = "\(id)|\(color.name)|\(alternative)"
        if let e = engines[key] { return e }
        guard let spec = InterpolationModelSpec.all().first(where: { $0.id == id && $0.isInstalled }) else { throw LumoraError.unsupported("\(id) missing") }
        let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        engines[key] = e
        return e
    }

    private func timed<T>(_ key: String, _ frames: Int, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = try body()
        ms[key, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(max(1, frames)))
        return r
    }

    /// Per-tile squared error on the scorer's tile grid (64 px x scale).
    func tileErrors(_ pairs: [(MTLTexture, MTLTexture)], tile: Int, tilesX: Int, tilesY: Int) -> [TileErr] {
        var tp = SIMD4<Int32>(Int32(tile), Int32(tilesX), Int32(tilesY), 0)
        let n = tilesX * tilesY
        let bufs = pairs.map { _ in gpu.zeroed(n * 16) }
        gpu.run { cb in
            for (k, (a, b)) in pairs.enumerated() {
                gpu.dispatch(cb, "tileErr", w: (a.width + 7) / 8, h: (a.height + 7) / 8) { e in
                    e.setTexture(a, index: 0); e.setTexture(b, index: 1)
                    e.setBuffer(bufs[k], offset: 0, index: 0)
                    e.setBytes(&tp, length: 16, index: 1)
                }
            }
        }
        return bufs.map { b in
            let p = b.contents().bindMemory(to: Float.self, capacity: n * 4)
            var e = TileErr(sse: [], ssimSum: [], ssimN: [], px: [])
            for i in 0..<n { e.sse.append(p[i * 4]); e.ssimSum.append(p[i * 4 + 1]); e.ssimN.append(p[i * 4 + 2]); e.px.append(p[i * 4 + 3]) }
            return e
        }
    }

    struct Output { var tiles: [String] = []; var frames: [String] = [] }

    func process(_ w: QCWindow, set: QCScorerTrainingTests.DataSet, partner: QCWindow?, refs: [String: RefFrame]) throws -> Output {
        var out = Output()
        let color = provider.color(w)
        let primary = try engine(set.primary, color, alternative: false)
        let alt = try engine(QCBench.flowModel, color, alternative: true)
        let primaryIsFlow = primary.spec.isFlow
        for tr in Triplet.of(w) {
            var A = try provider.frame(w, tr.a)
            var B = try provider.frame(partner ?? w, partner.map { Triplet.of($0).first { $0.mode == tr.mode }!.b } ?? tr.b)
            if B.width != A.width { continue }
            let rawA = A, rawB = B
            if set.grain {
                let sigma = max(0.002, grain.measure(A).overall)
                let ca = gpu.like(A), cbT = gpu.like(B)
                gpu.run { cb in grain.denoise(cb, A, into: ca, sigma: sigma); grain.denoise(cb, B, into: cbT, sigma: sigma) }
                A = ca; B = cbT
            }
            let n = tr.times.count
            let res = "\(A.width)"
            let P = (0..<n).map { _ in gpu.like(A) }
            _ = try timed("primary \(set.primary) \(res)", n) { try primary.interpolate(A, B, times: tr.times, into: P, qcTiles: (1, 1)) }
            alt.modelScaleOverride = ArtifactScorer.alternativeModelScale(forWidth: A.width)
            for k in 0..<n {
                let t = tr.times[k]
                let Q = gpu.like(A)
                _ = try timed("alternative \(res)", 1) { try alt.interpolate(A, B, times: [t], into: [Q], qcTiles: (1, 1)) }
                let meas = timed("measure \(res)", 1) {
                    scorer.measure(a: A, b: B, primary: P[k], alternative: Q, alternativeEngine: alt, t: t, primaryIsFlow: primaryIsFlow)
                }
                var cands: [String: MTLTexture] = ["P": P[k], "Q": Q, "blend": gpu.blend(A, B, t: t), "nearest": gpu.copy(t < 0.5 ? A : B),
                                                   "average": gpu.blend(P[k], Q, t: 0.5)]
                // Time the compose path once per frame (all tiles switched to the alternative: the worst case).
                let dst = gpu.like(A)
                let all = ArtifactScorer.Decision(choices: [UInt8](repeating: 1, count: meas.count), shotChange: false)
                timed("compose \(res)", 1) { scorer.compose(primary: P[k], alternative: Q, a: A, b: B, t: t, decision: all, into: dst) }
                if set.grain {
                    let near = t < 0.5 ? rawA : rawB, cleanNear = t < 0.5 ? A : B
                    for (name, tex) in cands {
                        let o = gpu.like(tex)
                        gpu.run { cb in grain.regrain(cb, cleanMid: tex, origNear: near, cleanNear: cleanNear, into: o, seed: k + 1) }
                        cands[name] = o
                    }
                }
                let truth = try provider.frame(w, tr.truths[k])
                let names = QCScorerTrainingTests.candidates
                let errs = tileErrors(names.map { (cands[$0]!, truth) }, tile: 64 * meas.scale, tilesX: meas.tilesX, tilesY: meas.tilesY)
                let key = "\(w.id)|\(tr.mode)|\(k)"
                let broken = refs[key].map(BrokenTile.flags)
                let head = [set.name, w.id, tr.mode, "\(k)", "\(t)", w.stratum, fmt(w.motion), set.primary]
                if partner == nil {
                    for i in 0..<meas.count {
                        var row = head + ["\(meas.tilesX)", "\(meas.tilesY)", "\(meas.scale)", "\(i)"]
                        row += meas.features[i].map { fmt($0, 6) }
                        row.append(fmt(errs[0].px[i], 0))
                        row += errs.map { fmt(Float($0.tilePSNR(i)), 3) }
                        row.append(broken.map { $0.count == meas.count && $0[i] ? "1" : "0" } ?? "")
                        out.tiles.append(row.joined(separator: ","))
                    }
                }
                out.frames.append((head + [partner == nil ? "0" : "1"] + meas.frame.map { fmt($0, 6) } + errs.map { fmt(Float($0.psnr), 3) }).joined(separator: ","))
            }
        }
        return out
    }
}
