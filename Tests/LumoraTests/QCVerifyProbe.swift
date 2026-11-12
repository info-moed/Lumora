import XCTest
import Metal
@testable import Lumora

/// Diagnostics of the learned scorer's frame-level decisions (shot-change logit, blatant-damage tiles) on benchmark and
/// verification windows, computed exactly as FrameStream does (primary model, then the flow second opinion at about
/// 960 px wide). Writes <bench root>/qc-verify/probe.csv. Skipped unless LUMORA_QC_VERIFY=1.
final class QCVerifyProbeTests: XCTestCase {
    override func setUpWithError() throws {
        guard QCBench.env["LUMORA_QC_VERIFY"] == "1" else { throw XCTSkip("QC verification: set LUMORA_QC_VERIFY=1") }
        try TestHardware.requireGPU()
        guard FileManager.default.fileExists(atPath: QCBench.film1080.path) else { throw XCTSkip("film not found") }
    }

    func test3_ScorerProbe() async throws {
        let (m, provider) = try await QCBenchmarkTests.prepare()
        let vws = try await VerifySets.windows(m)
        try await VerifySets.ensureFrames(m, vws)
        let wanted = (QCBench.env["LUMORA_QC_PROBE"] ?? "synthetic,fade,cut,test,testHDR,credits,vsynth,vfade,vcut,vnearcut,vtest,vtestHDR")
            .split(separator: ",").map(String.init)
        let all = m.windows + vws
        let scorer = ArtifactScorer()
        let model = try XCTUnwrap(QCScorerModel.shared)
        let set = try XCTUnwrap(model.set(alternative: true))
        let gpu = BenchGPU.shared
        var engines: [String: CoreMLInterpolator] = [:]
        func engine(_ id: String, _ color: SourceColor, alt: Bool) throws -> CoreMLInterpolator {
            let key = "\(id)|\(color.name)|\(alt)"
            if let e = engines[key] { return e }
            let spec = try XCTUnwrap(InterpolationModelSpec.all().first { $0.id == id && $0.isInstalled })
            let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
            engines[key] = e
            return e
        }
        var lines = ["split,window,stratum,mode,t,z,threshold,blatant,tiles," + ArtifactScorer.frameFeatureNames.joined(separator: ",")]
        for split in wanted {
            let modes = split.hasPrefix("v") ? VerifySets.modes(for: split) : ["30->60", "15->60"]
            for w in all where w.split == split && w.variant != "grain" {
                for mode in modes {
                    let spec = VerifySets.modeSpecs[mode]!
                    try autoreleasepool {
                        let A = try provider.frame(w, w.center + spec.a), B = try provider.frame(w, w.center + spec.b)
                        let color = provider.color(w)
                        let primaryIsFlow = w.variant == "hdr"
                        let pe = try engine(primaryIsFlow ? QCBench.flowModel : QCBench.imageModel, color, alt: false)
                        let ae = try engine(QCBench.flowModel, color, alt: true)
                        ae.modelScaleOverride = ArtifactScorer.alternativeModelScale(forWidth: A.width)
                        for t in spec.times {
                            let P = gpu.like(A), Q = gpu.like(A)
                            _ = try pe.interpolate(A, B, times: [t], into: [P], qcTiles: (1, 1))
                            _ = try ae.interpolate(A, B, times: [t], into: [Q], qcTiles: (1, 1))
                            let ms = scorer.measure(a: A, b: B, primary: P, alternative: Q, alternativeEngine: ae, t: t, primaryIsFlow: primaryIsFlow)
                            var z = set.cutWeights[ms.frame.count]
                            for (wt, v) in zip(set.cutWeights, ms.frame) { z += wt * v }
                            let blatant = set.blatant.map { b in ms.features.filter { b.predict($0) > set.policy.blatantThreshold }.count } ?? 0
                            lines.append("\(split),\(w.id),\(w.stratum),\(mode),\(fmt(t, 3)),\(fmt(z, 3)),\(fmt(set.cutThreshold, 3)),\(blatant),\(ms.count),"
                                         + ms.frame.map { fmt($0, 5) }.joined(separator: ","))
                        }
                    }
                }
            }
            QCBench.log("probe \(split) done (\(lines.count - 1) rows)")
        }
        QCBench.ensureDir(VerifySets.dir)
        let name = QCBench.env["LUMORA_QC_PROBE_OUT"] ?? "probe.csv"
        try lines.joined(separator: "\n").write(to: VerifySets.dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
