import Foundation
import Metal
import MetalPerformanceShaders

/// The interpolation pain-point map of a whole film: per scene, which model wins, how sure we are, and how hard it is.
struct MotionMap: Codable {
    var sourceKey: String
    var created: Date
    var mode: MotionIntelligence
    var confidenceTarget: Double
    var routes: [SceneRoute]

    var confidentShare: Double {
        let r = routes.filter { $0.status != .skipped }
        return r.isEmpty ? 1 : Double(r.filter { $0.status != .uncertain }.count) / Double(r.count)
    }
    var hardest: [SceneRoute] { routes.filter { $0.status != .skipped }.sorted { $0.pain > $1.pain }.prefix(20).map { $0 } }

    private static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/MotionMaps")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func key(for d: SourceDescriptor) -> String {
        let v = try? d.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(d.url.lastPathComponent)-\(v?.fileSize ?? 0)-\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))-\(d.scanFix.rawValue)"
            .replacingOccurrences(of: "/", with: "_")
    }
    static func load(_ key: String) -> MotionMap? {
        try? JSONDecoder().decode(MotionMap.self, from: Data(contentsOf: folder.appendingPathComponent(key + ".json")))
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.folder.appendingPathComponent(sourceKey + ".json")) }
}

/// Picks the best interpolation model per scene by rebuilding real frames that were removed (ground truth) with
/// each candidate and testing the differences statistically until the requested confidence is reached.
enum MotionRouter {
    static func build(_ d: SourceDescriptor, color: SourceColor, analysis a: AnalysisResult, settings: InterpolationSettings,
                      kind: ContentKind, progress: ProgressReporter) async throws -> MotionMap {
        let installed = InterpolationModelSpec.all().filter(\.isInstalled)
        guard !installed.isEmpty else { throw LumoraError.unsupported("Install interpolation models in Model Lab first.") }
        let proxy = UniformBuilder.analysis(source: color, gridW: 1, gridH: 1)
        var engines: [String: InterpolationEngine] = [:]
        func engine(_ id: String) -> InterpolationEngine? {
            if let e = engines[id] { return e }
            guard let spec = installed.first(where: { $0.id == id }), let e = try? CoreMLInterpolator(spec: spec, proxyUniforms: proxy) else { return nil }
            engines[id] = e
            return e
        }
        // Candidates: the content type's preference list, plus every installed model in exhaustive mode.
        let preferred = ContentTuning.preset(kind).interpolationModels.filter { id in installed.contains { $0.id == id } }
        let heavy = installed.filter { $0.tier == "best" }.map(\.id)
        let baseCandidates = settings.intelligence == .exhaustive ? installed.map(\.id) : Array(Set(preferred.prefix(3) + heavy.prefix(1)))
        let src = try await d.makeFrameSource()
        let r = GradeRenderer()
        let qc = InterpolationQC()
        qc.grainAware = settings.grainAware
        let width = 960
        let maxTrials = settings.intelligence == .exhaustive ? 40 : 12
        var routes: [SceneRoute] = []
        let start = Date()

        for (si, scene) in a.scenes.enumerated() {
            try Task.checkCancellation()
            let usable = (scene.start + 1..<(scene.end - 1)).filter { !a.duplicateFrames.contains($0) && a.transition(containing: $0) == nil }
            guard usable.count >= 6 else {
                routes.append(SceneRoute(scene: si, model: preferred.first ?? installed[0].id, runnerUp: nil, confidence: 1,
                                         status: .skipped, trials: 0, motion: 0, pain: 0, advantage: 0))
                continue
            }
            // Motion of this scene decides how hard to look (and whether the heavy model is worth trying).
            var candidates = baseCandidates
            var scores: [String: [Double]] = [:]
            var artifacts: [String: [Double]] = [:]
            var motions: [Double] = []
            var trial = 0
            var verdict: (best: String, second: String?, conf: Double, tied: Bool) = (candidates.first ?? "", nil, 0, false)
            while trial < maxTrials {
                let i = usable[(trial * 7919 + si * 31) % usable.count]
                try src.start(at: i - 1, count: 3)
                guard let f0 = try src.nextFrame(), let truth = try src.nextFrame(), let f2 = try src.nextFrame() else { break }
                let T = r.comparable(truth.texture, color: color, width: width)
                let C0 = r.comparable(f0.texture, color: color, width: width), C2 = r.comparable(f2.texture, color: color, width: width)
                motions.append(Double(r.blendErrors(C0, C2, C2, t: 0).motion))
                if trial == 2, settings.intelligence == .perScene, (motions.reduce(0, +) / Double(motions.count)) < 0.004 {
                    candidates = Array(candidates.prefix(1))      // near-static: any good model is fine
                }
                for id in candidates {
                    guard let e = engine(id) else { continue }
                    let out = MetalContext.shared.makeTexture(width: f0.texture.width, height: f0.texture.height, format: f0.texture.pixelFormat)
                    _ = try e.interpolate(f0.texture, f2.texture, times: [0.5], into: [out], qcTiles: (1, 1))
                    let G = r.comparable(out, color: color, width: width)
                    scores[id, default: []].append(Double(r.compare(T, G).ssim))
                    artifacts[id, default: []].append(Double(qc.score(a: C0, b: C2, mid: G, sensitivity: settings.sensitivity).fraction))
                }
                trial += 1
                if trial >= 4 { verdict = decide(scores, target: settings.confidence) }
                if trial >= 4, verdict.conf >= settings.confidence || verdict.tied { break }
            }
            let chosen = verdict.best.isEmpty ? (candidates.first ?? installed[0].id) : verdict.best
            let pain = (artifacts[chosen] ?? []).reduce(0, +) / Double(max(1, artifacts[chosen]?.count ?? 0))
            let adv = verdict.second.map { (mean(scores[chosen] ?? []) - mean(scores[$0] ?? [])) } ?? 0
            routes.append(SceneRoute(scene: si, model: chosen, runnerUp: verdict.second, confidence: verdict.conf,
                                     status: verdict.tied ? .tied : (verdict.conf >= settings.confidence ? .confident : .uncertain),
                                     trials: trial, motion: mean(motions), pain: pain, advantage: adv))
            let done = Double(si + 1) / Double(a.scenes.count)
            let rate = Double(si + 1) / max(1, Date().timeIntervalSince(start))
            progress.update(done, detail: "Scene \(si + 1) of \(a.scenes.count): \(InterpolationModelSpec.all().first { $0.id == chosen }?.displayName ?? chosen), \(Int(verdict.conf * 100))% sure",
                            rate: String(format: "%.1f scenes/s", rate))
        }
        src.cancel()
        let map = MotionMap(sourceKey: MotionMap.key(for: d), created: Date(), mode: settings.intelligence,
                            confidenceTarget: settings.confidence, routes: routes)
        map.save()
        Log.notice(.interpolation, "Motion map: \(routes.count) scenes, \(Int(map.confidentShare * 100))% confident at \(Int(settings.confidence * 100))%; hardest scenes: \(map.hardest.prefix(5).map { "#\($0.scene) pain \(String(format: "%.2f", $0.pain))" }.joined(separator: ", "))")
        return map
    }

    private static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    /// Paired comparison of the leader against every other model: probability the leader is genuinely better
    /// (one-sided normal approximation). If all differences are negligible and tightly estimated, it's a tie.
    static func decide(_ scores: [String: [Double]], target: Double) -> (best: String, second: String?, conf: Double, tied: Bool) {
        let ranked = scores.filter { !$0.value.isEmpty }.sorted { mean($0.value) > mean($1.value) }
        guard let best = ranked.first else { return ("", nil, 0, false) }
        guard ranked.count > 1 else { return (best.key, nil, 1, false) }
        var minConf = 1.0
        var allTiny = true
        for other in ranked.dropFirst() {
            let n = min(best.value.count, other.value.count)
            let diffs = (0..<n).map { best.value[$0] - other.value[$0] }
            let m = mean(diffs)
            let sd = sqrt(diffs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, n - 1)))
            let se = max(1e-6, sd / sqrt(Double(n)))
            let z = m / se
            minConf = min(minConf, 0.5 * (1 + erf(z / sqrt(2))))
            if !(abs(m) < 0.0015 && se < 0.001) { allTiny = false }
        }
        return (best.key, ranked[1].key, minConf, allTiny)
    }
}
