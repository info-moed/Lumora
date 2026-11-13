import XCTest
import Metal
@testable import Lumora

/// Ground-truth comparison of other interpolation models against the dataset's RIFE 4.25 candidates (QC benchmark,
/// Big Buck Bunny 60 fps). Skipped unless LUMORA_QC_BENCH=1; run it with `scripts/qc-bench.sh candidates`.
///
/// For every window of the chosen splits it runs each candidate model the way the app would (image models on the
/// encoded signal, flow models on the SDR proxy, grain windows de-grained and re-grained like FrameStream), scores it
/// per 64-px tile against the real frame, and joins the result with the dataset's RIFE candidates (qc-dataset/<split>/
/// ref.json). It reports, per split, mode and motion stratum:
///   - each candidate as the primary model vs raw RIFE 4.25 (PSNR, SSIM, share of frames better),
///   - the per-tile oracle ceiling over the RIFE candidates alone and with each candidate added,
///   - the artifact checker's run-time ceiling (primary, second opinion at about 960 px wide, cross-fade, nearest
///     original, average of the two) with RIFE flow or the candidate as the second opinion, or both,
///   - model time per generated frame at the split's resolution, next to RIFE's measured in the same run.
/// Output: qc-results/candidates-<label>.md and candidates-<label>-<split>.json.
///
///   LUMORA_QC_CANDIDATES=ifrnet-l,ifrnet-l-flow   model ids (default: every installed model that isn't RIFE 4.25)
///   LUMORA_QC_SPLITS=test,test4k                  splits (default: the held-out ones)
///   LUMORA_QC_LABEL=<name>                        report name (default "candidates")
///   LUMORA_QC_LIMIT=<n>                           first n windows per split
final class QCCandidateTests: XCTestCase {

    override func setUpWithError() throws {
        guard QCBench.env["LUMORA_QC_BENCH"] == "1" else { throw XCTSkip("QC benchmark: set LUMORA_QC_BENCH=1 (scripts/qc-bench.sh)") }
        try TestHardware.requireGPU()
        guard FileManager.default.fileExists(atPath: QCBench.film1080.path) else { throw XCTSkip("Big Buck Bunny 60 fps render not found") }
        let installed = InterpolationModelSpec.all().filter(\.isInstalled).map(\.id)
        guard installed.contains(QCBench.imageModel), installed.contains(QCBench.flowModel) else {
            throw XCTSkip("RIFE 4.25 image and flow models must be installed (Model Lab)")
        }
        QCBench.ensureDir(QCBench.results)
    }

    /// Benchmark-only variants that aren't in the app's catalog (Resources/interpolation_models.json), used when their
    /// files are installed: IFRNet's flow exports and the midpoint-only Vimeo90K checkpoints
    /// (scripts/convert_ifrnet_coreml.py; docs/command-line.md has the commands).
    static let experimental: [InterpolationModelSpec] = {
        func spec(_ id: String, _ file: String, flow: Bool) -> InterpolationModelSpec {
            InterpolationModelSpec(id: id, displayName: id, file: file, inputA: "img0", inputB: "img1", timestep: "timestep",
                                   timestepKind: "map", output: "output", padMultiple: 16, tier: "balanced",
                                   license: "MIT (ltkong218/IFRNet)", notes: "QC benchmark only",
                                   outputKind: flow ? "flow" : nil, flowOutput: flow ? "flow" : nil, maskOutput: flow ? "mask" : nil,
                                   computeUnits: "cpuAndGPU")
        }
        return [spec("ifrnet-l-flow", "IFRNet-L-Flow.mlpackage", flow: true), spec("ifrnet-flow", "IFRNet-Flow.mlpackage", flow: true),
                spec("ifrnet-l-vimeo", "IFRNet-L-Vimeo.mlpackage", flow: false),
                spec("ifrnet-l-vimeo-flow", "IFRNet-L-Vimeo-Flow.mlpackage", flow: true)]
    }()

    /// The app's models plus the benchmark-only ones, installed only.
    static func installedSpecs() -> [InterpolationModelSpec] {
        let app = InterpolationModelSpec.all()
        return (app + experimental.filter { e in !app.contains { $0.id == e.id } }).filter(\.isInstalled)
    }

    static func candidateIDs() -> [String] {
        let installed = installedSpecs()
        if let e = QCBench.env["LUMORA_QC_CANDIDATES"] {
            return e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { id in installed.contains { $0.id == id } }
        }
        return installed.filter { !$0.id.hasPrefix("rife") }.map(\.id)
    }

    func test5_Candidates() async throws {
        let ids = Self.candidateIDs()
        guard !ids.isEmpty else { throw XCTSkip("no candidate model installed (LUMORA_QC_CANDIDATES)") }
        let (m, provider) = try await QCBenchmarkTests.prepare()
        let label = QCBench.env["LUMORA_QC_LABEL"] ?? "candidates"
        let lab = CandidateLab(provider: provider, candidates: ids)
        var sections: [String] = []
        for split in QCBenchmarkTests.splits(default: QCBench.heldOut) {
            let refs = try QCBenchmarkTests.loadRefs(split)
            let ws = QCBenchmarkTests.windows(m, split)
            var recs: [CandidateFrame] = []
            let started = Date()
            for (i, w) in ws.enumerated() {
                recs += try autoreleasepool { try lab.process(w, refs: refs) }
                if i % 20 == 19 || i == ws.count - 1 {
                    QCBench.log("candidates \(split): \(i + 1)/\(ws.count) windows, \(Int(Date().timeIntervalSince(started))) s")
                }
            }
            let drift = recs.map(\.primaryCheckDB).max() ?? 0
            QCBench.log("candidates \(split): \(recs.count) frames; regenerated RIFE primary vs dataset max |Δ| \(fmt(drift, 3)) dB")
            XCTAssertLessThan(drift, 0.05, "\(split): the regenerated RIFE primary doesn't match the dataset")
            let report = CandidateReport(split: split, frames: recs, timing: lab.timing(split: split))
            try QCBenchmarkTests.encoder.encode(report).write(to: QCBench.results.appendingPathComponent("\(label)-\(split).json"))
            sections.append(report.markdown(candidates: ids))
        }
        let md = """
        # Second model family: candidates vs RIFE 4.25 (ground truth, Big Buck Bunny 60 fps)

        PSNR is RGB in the pipeline's encoded signal, per generated frame, averaged; gain = candidate (or oracle) minus raw
        RIFE 4.25 primary (RIFE 4.25 HDR flow on testHDR). "better %" = frames where the candidate beats the primary by
        more than 0.1 dB. Oracles pick the best candidate per 64-px tile with the truth known (an upper bound for any
        checker): rife6 = \(BrokenTile.requiredCandidates.joined(separator: ", ")); runtime = what the artifact checker
        chooses between (primary, second opinion at about 960 px wide, cross-fade, nearest original, average of primary
        and second opinion). `X@960` is flow model X run as the second opinion; `avg(P,X)` the average of the primary and X.

        \(sections.joined(separator: "\n\n"))
        """
        try md.write(to: QCBench.results.appendingPathComponent("\(label).md"), atomically: true, encoding: .utf8)
        print(md)
    }
}

/// One generated frame: every candidate's frame PSNR/SSIM and the oracle ceilings, next to the raw primary.
struct CandidateFrame: Codable {
    var key: String
    var mode: String
    var stratum: String
    var rawPSNR: Double, rawSSIM: Double
    var psnr: [String: Double]
    var ssim: [String: Double]
    var oracle: [String: Double]
    /// |regenerated RIFE primary - dataset primary| frame PSNR (instrument check).
    var primaryCheckDB: Double
}

struct CandidateReport: Codable {
    var split: String
    var frames: [CandidateFrame]
    var timing: [String: Double]

    struct Row: Codable { var frames: Int; var psnr: Double; var gain: Double; var ssimGain: Double; var betterPct: Double; var worsePct: Double }

    static func row(_ f: [CandidateFrame], _ name: String) -> Row? {
        let have = f.filter { $0.psnr[name] != nil || $0.oracle[name] != nil }
        guard !have.isEmpty else { return nil }
        let v = have.map { $0.psnr[name] ?? $0.oracle[name]! }
        let d = zip(have, v).map { $1 - $0.rawPSNR }
        let s = have.compactMap { r in r.ssim[name].map { $0 - r.rawSSIM } }
        func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }
        return Row(frames: have.count, psnr: mean(v), gain: mean(d), ssimGain: mean(s),
                   betterPct: 100 * Double(d.filter { $0 > 0.1 }.count) / Double(d.count),
                   worsePct: 100 * Double(d.filter { $0 < -0.1 }.count) / Double(d.count))
    }

    func markdown(candidates ids: [String]) -> String {
        let models = (frames.first?.psnr.keys.sorted() ?? []).filter { !$0.hasPrefix("rife:") }
        let oracles = frames.first?.oracle.keys.sorted { a, b in a.count == b.count ? a < b : a.count < b.count } ?? []
        let groups: [(String, [CandidateFrame])] = [("all", frames)]
            + ["30->60", "15->60"].map { m in (m, frames.filter { $0.mode == m }) }
            + Set(frames.map(\.stratum)).sorted().map { s in (s, frames.filter { $0.stratum == s }) }
        var out = "## \(split) (\(frames.count) frames, raw primary \(fmt(frames.map(\.rawPSNR).reduce(0, +) / Double(max(1, frames.count)), 2)) dB)\n\n"
        out += "Model time per generated frame: " + timing.sorted { $0.key < $1.key }.map { "\($0.key) \(fmt($0.value, 1)) ms" }.joined(separator: ", ") + "\n\n"
        out += "| group | candidate | frames | PSNR | gain dB | SSIM gain | better % | worse % |\n|---|---|---|---|---|---|---|---|\n"
        for (g, f) in groups where !f.isEmpty {
            for name in models + ["rife:flow@960"] {
                guard let r = Self.row(f, name) else { continue }
                out += "| \(g) | \(name) | \(r.frames) | \(fmt(r.psnr, 2)) | \(fmt(r.gain, 3)) | \(fmt(r.ssimGain, 4)) | \(fmt(r.betterPct, 1)) | \(fmt(r.worsePct, 1)) |\n"
            }
        }
        out += "\n| group | oracle | gain dB |\n|---|---|---|\n"
        for (g, f) in groups where !f.isEmpty {
            for name in oracles { if let r = Self.row(f, name) { out += "| \(g) | \(name) | \(fmt(r.gain, 3)) |\n" } }
        }
        _ = ids
        return out
    }
}

/// Runs the candidate models and RIFE's run-time second opinion on one window and joins them with the dataset.
final class CandidateLab {
    let gpu = BenchGPU.shared
    let provider: FrameProvider
    let candidates: [InterpolationModelSpec]
    private var engines: [String: CoreMLInterpolator] = [:]
    private let grain = GrainProcessor()
    private var ms: [String: [String: [Double]]] = [:]       // split -> "<model> <width>" -> ms per generated frame

    init(provider: FrameProvider, candidates ids: [String]) {
        self.provider = provider
        let all = QCCandidateTests.installedSpecs()
        candidates = ids.compactMap { id in all.first { $0.id == id } }
    }

    func engine(_ spec: InterpolationModelSpec, _ color: SourceColor, secondOpinion: Bool) throws -> CoreMLInterpolator {
        let key = "\(spec.id)|\(color.name)|\(secondOpinion)"
        if let e = engines[key] { return e }
        let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        engines[key] = e
        return e
    }

    func spec(_ id: String) throws -> InterpolationModelSpec {
        guard let s = InterpolationModelSpec.all().first(where: { $0.id == id && $0.isInstalled }) else { throw LumoraError.unsupported("\(id) missing") }
        return s
    }

    func timing(split: String) -> [String: Double] {
        (ms[split] ?? [:]).mapValues { v in let s = v.sorted(); return s[s.count / 2] }
    }

    private func run(_ split: String, _ key: String, frames: Int, _ body: () throws -> Void) rethrows {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        ms[split, default: [:]][key, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(max(1, frames)))
    }

    /// Generates `times` with an engine; flow engines optionally at the second opinion's scale.
    private func generate(_ e: CoreMLInterpolator, _ a: MTLTexture, _ b: MTLTexture, _ times: [Float], secondOpinion: Bool,
                          split: String, label: String) throws -> [MTLTexture] {
        e.modelScaleOverride = secondOpinion ? ArtifactScorer.alternativeModelScale(forWidth: a.width) : nil
        let outs = times.map { _ in gpu.like(a) }
        if secondOpinion {
            // The app runs the second opinion one time at a time (FrameStream), so time it that way.
            for (k, t) in times.enumerated() {
                try run(split, "\(label) \(a.width)", frames: 1) { _ = try e.interpolate(a, b, times: [t], into: [outs[k]], qcTiles: (1, 1)) }
            }
        } else {
            try run(split, "\(label) \(a.width)", frames: times.count) { _ = try e.interpolate(a, b, times: times, into: outs, qcTiles: (1, 1)) }
        }
        return outs
    }

    func process(_ w: QCWindow, refs: [String: RefFrame]) throws -> [CandidateFrame] {
        let color = provider.color(w)
        var frames: [Int: MTLTexture] = [:]
        for n in (w.center - 2)...(w.center + 2) { frames[n] = try provider.frame(w, n) }
        let primaryIsFlow = w.variant == "hdr"
        let primary = try engine(try spec(primaryIsFlow ? QCBench.flowModel : QCBench.imageModel), color, secondOpinion: false)
        let rifeFlow = try engine(try spec(QCBench.flowModel), color, secondOpinion: true)
        let isGrain = w.variant == "grain"
        var sigma: Float = 0
        if isGrain { sigma = max(0.002, grain.measure(frames[w.center - 2]!).overall) }
        func clean(_ t: MTLTexture) -> MTLTexture {
            guard isGrain else { return t }
            let o = gpu.like(t)
            gpu.run { cb in grain.denoise(cb, t, into: o, sigma: sigma) }
            return o
        }
        var out: [CandidateFrame] = []
        for tr in Triplet.of(w) {
            let A = frames[tr.a]!, B = frames[tr.b]!
            let ga = clean(A), gb = clean(B)
            let P = try generate(primary, ga, gb, tr.times, secondOpinion: false, split: w.split, label: "rife:" + primary.spec.id)
            let Q = try generate(rifeFlow, ga, gb, tr.times, secondOpinion: true, split: w.split, label: "rife:flow@960")
            var cand: [[String: MTLTexture]] = tr.times.map { _ in [:] }
            for (k, _) in tr.times.enumerated() {
                cand[k]["rife:P"] = P[k]
                cand[k]["rife:flow@960"] = Q[k]
                cand[k]["rife:avg(P,flow@960)"] = gpu.blend(P[k], Q[k], t: 0.5)
            }
            for s in candidates {
                let e = try engine(s, color, secondOpinion: false)
                let C = try generate(e, ga, gb, tr.times, secondOpinion: false, split: w.split, label: s.id)
                for k in C.indices {
                    cand[k][s.id] = C[k]
                    cand[k]["avg(P,\(s.id))"] = gpu.blend(P[k], C[k], t: 0.5)
                }
                if s.isFlow {
                    let e2 = try engine(s, color, secondOpinion: true)
                    let C2 = try generate(e2, ga, gb, tr.times, secondOpinion: true, split: w.split, label: "\(s.id)@960")
                    for k in C2.indices {
                        cand[k]["\(s.id)@960"] = C2[k]
                        cand[k]["avg(P,\(s.id)@960)"] = gpu.blend(P[k], C2[k], t: 0.5)
                    }
                }
            }
            for k in tr.times.indices {
                let t = tr.times[k]
                let key = "\(w.id)|\(tr.mode)|\(k)"
                guard var ref = refs[key] else { continue }
                var c = cand[k]
                if isGrain {
                    let near = t < 0.5 ? A : B, cleanNear = t < 0.5 ? ga : gb
                    for (name, tex) in c {
                        let o = gpu.like(tex)
                        gpu.run { cb in grain.regrain(cb, cleanMid: tex, origNear: near, cleanNear: cleanNear, into: o, seed: k + 1) }
                        c[name] = o
                    }
                }
                let truth = frames[tr.truths[k]]!
                let names = c.keys.sorted()
                let errs = gpu.tileErrors(names.map { (c[$0]!, truth) })
                var rec = CandidateFrame(key: key, mode: tr.mode, stratum: w.stratum, rawPSNR: ref.framePSNR[ref.primary]!,
                                         rawSSIM: ref.frameSSIM[ref.primary]!, psnr: [:], ssim: [:], oracle: [:], primaryCheckDB: 0)
                for (j, name) in names.enumerated() {
                    precondition(errs[j].px.count == ref.px.count, "tile grid differs from the dataset's")
                    rec.psnr[name] = errs[j].psnr
                    rec.ssim[name] = errs[j].ssim
                    if name != "rife:P" { ref.candPSNR[name] = (0..<errs[j].px.count).map { Float(errs[j].tilePSNR($0)) } }
                }
                rec.primaryCheckDB = abs(rec.psnr["rife:P"]! - rec.rawPSNR)
                // Oracle ceilings. The dataset's primary is "img" (or "flow" on HDR); "P" below means that one.
                let p = ref.primary
                let rife6 = BrokenTile.requiredCandidates
                rec.oracle["rife6"] = ref.oraclePSNR(rife6)
                rec.oracle["rifeAll9"] = ref.oraclePSNR(TripletLab.candidates)
                let runtime = [p, "rife:flow@960", "blend", "nearest", "rife:avg(P,flow@960)"]
                rec.oracle["runtime (RIFE flow@960)"] = ref.oraclePSNR(runtime)
                var everything = TripletLab.candidates + runtime
                for s in candidates {
                    everything += [s.id, "avg(P,\(s.id))"]
                    rec.oracle["P+\(s.id)"] = ref.oraclePSNR([p, s.id])
                    rec.oracle["rife6+\(s.id)"] = ref.oraclePSNR(rife6 + [s.id])
                    rec.oracle["rife6+\(s.id)+avg"] = ref.oraclePSNR(rife6 + [s.id, "avg(P,\(s.id))"])
                    rec.oracle["runtime+\(s.id)+avg"] = ref.oraclePSNR(runtime + [s.id, "avg(P,\(s.id))"])
                    if s.isFlow {
                        let so = "\(s.id)@960"
                        everything += [so, "avg(P,\(so))"]
                        rec.oracle["runtime with \(so)"] = ref.oraclePSNR([p, so, "blend", "nearest", "avg(P,\(so))"])
                        rec.oracle["runtime+\(so)+avg"] = ref.oraclePSNR(runtime + [so, "avg(P,\(so))"])
                    }
                }
                rec.oracle["everything"] = ref.oraclePSNR(everything)
                out.append(rec)
            }
        }
        return out
    }
}
