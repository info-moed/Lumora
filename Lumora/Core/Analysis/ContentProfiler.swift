import Foundation

/// The kinds of picture Lumora tunes for. Each one changes interpolation, artifact repair, grain handling,
/// encoder tuning and the quality target, because what looks best differs a lot between them.
enum ContentKind: String, CaseIterable, Codable, Identifiable {
    case realLife, realLifeHeavyGrain, anime, oldAnime, cgiAnimation, screenContent, lowLightNoisy, fastMotion
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realLife: return "Real life"
        case .realLifeHeavyGrain: return "Real life, heavy grain"
        case .anime: return "Anime"
        case .oldAnime: return "Old anime"
        case .cgiAnimation: return "3D animation / CGI"
        case .screenContent: return "Screen recording / games UI"
        case .lowLightNoisy: return "Low light, noisy"
        case .fastMotion: return "Sports / fast motion"
        }
    }

    var symbol: String {
        switch self {
        case .realLife: return "camera"
        case .realLifeHeavyGrain: return "film"
        case .anime: return "pencil.and.scribble"
        case .oldAnime: return "film.stack"
        case .cgiAnimation: return "cube.transparent"
        case .screenContent: return "display"
        case .lowLightNoisy: return "moon.stars"
        case .fastMotion: return "figure.run"
        }
    }
}

enum GrainHandling: String, Codable { case keep, synthesize }

/// Everything a content type changes. Model order is a starting point drawn from the RIFE author's notes and
/// community testing; Model Lab benchmarks on your own footage and overrides it per content type.
struct ContentTuning: Codable, Hashable {
    var kind: ContentKind
    var summary: String
    var interpolationModels: [String]
    var repairModel: String?
    var qcSensitivity: Float
    var smoothDuplicates: Bool
    var deband: Float
    var edgeProtection: Float
    var punchScale: Float              // multiplies the look's local contrast
    var grain: GrainHandling
    var encoderTune: String            // key into encoders.json "tunes"
    var vmafModel: String
    var targetVMAF: Double
    var upscaleModel: String?

    static func preset(_ k: ContentKind) -> ContentTuning {
        switch k {
        case .realLife:
            return ContentTuning(kind: k, summary: "Natural camera footage. Balanced motion model, standard artifact checks.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.18-flow", "rife-4.26-flow", "rife-4.25", "rife-4"],
                                 repairModel: "film", qcSensitivity: 0.5, smoothDuplicates: false, deband: 0, edgeProtection: 0.6,
                                 punchScale: 1, grain: .keep, encoderTune: "default", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 95, upscaleModel: "realesrgan-x2plus")
        case .realLifeHeavyGrain:
            return ContentTuning(kind: k, summary: "Film or high-ISO grain. Grain is random by nature, so the artifact check relies more on motion agreement; the encoder models grain instead of spending bits on it.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.18-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.15, smoothDuplicates: false, deband: 0, edgeProtection: 0.8,
                                 punchScale: 0.7, grain: .synthesize, encoderTune: "grain", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 93, upscaleModel: "realesrgan-x2plus")
        case .anime:
            return ContentTuning(kind: k, summary: "Modern digital animation. Interpolates between real drawings (skips held frames), protects line art, prevents banding in flat colour.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.22-flow", "rife-4.6-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.6, smoothDuplicates: true, deband: 0.4, edgeProtection: 0.9,
                                 punchScale: 0.6, grain: .keep, encoderTune: "anime", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 95, upscaleModel: "realesr-animevideov3")
        case .oldAnime:
            return ContentTuning(kind: k, summary: "Cel or early-digital animation: film grain, telecine, softer lines. Restores 24p, interpolates between real drawings, keeps the grain's character.",
                                 interpolationModels: ["rife-4.22-flow", "rife-4.25-flow", "rife-4.6-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.3, smoothDuplicates: true, deband: 0.5, edgeProtection: 0.9,
                                 punchScale: 0.5, grain: .synthesize, encoderTune: "grain", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 94, upscaleModel: "realesr-animevideov3")
        case .cgiAnimation:
            return ContentTuning(kind: k, summary: "Rendered 3D animation: clean surfaces, smooth gradients, real motion on every frame.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.26-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.6, smoothDuplicates: false, deband: 0.3, edgeProtection: 0.7,
                                 punchScale: 0.8, grain: .keep, encoderTune: "default", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 95, upscaleModel: "realesrgan-x2plus")
        case .screenContent:
            return ContentTuning(kind: k, summary: "Text, UI and sharp graphics. Interpolation is usually unnecessary; the encoder uses screen-content tools.",
                                 interpolationModels: ["rife-4.25-lite", "rife-4.25"],
                                 repairModel: nil, qcSensitivity: 0.7, smoothDuplicates: false, deband: 0, edgeProtection: 1,
                                 punchScale: 0, grain: .keep, encoderTune: "screen", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 96, upscaleModel: nil)
        case .lowLightNoisy:
            return ContentTuning(kind: k, summary: "Dark, noisy footage. Gentler artifact checks (noise isn't an artifact), banding protection in the shadows.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.18-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.2, smoothDuplicates: false, deband: 0.3, edgeProtection: 0.8,
                                 punchScale: 0.6, grain: .synthesize, encoderTune: "grain", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 93, upscaleModel: "realesrgan-x2plus")
        case .fastMotion:
            return ContentTuning(kind: k, summary: "Big, fast movement. Strongest motion models first and a strict artifact check, since large motion is where interpolation breaks.",
                                 interpolationModels: ["rife-4.25-flow", "rife-4.26-flow", "rife-4.18-flow", "rife-4.25"],
                                 repairModel: "film", qcSensitivity: 0.7, smoothDuplicates: false, deband: 0, edgeProtection: 0.6,
                                 punchScale: 0.9, grain: .keep, encoderTune: "default", vmafModel: "vmaf_v0.6.1",
                                 targetVMAF: 95, upscaleModel: "realesrgan-x2plus")
        }
    }
}

struct ContentProfile: Codable, Hashable {
    var kind: ContentKind
    var confidence: Float
    var evidence: [String]
    var detail: Float
    var flatShare: Float
    var grain: Float
    var motion: Float
    var repeatedFrameShare: Float
}

enum ContentProfiler {
    /// Samples ~40 moments across the file (pairs of consecutive frames for motion) and classifies it.
    static func profile(_ d: SourceDescriptor, color: SourceColor, analysis a: AnalysisResult,
                        progress: ProgressReporter) async throws -> ContentProfile {
        let src = try await d.makeFrameSource()
        let r = GradeRenderer()
        let u = UniformBuilder.analysis(source: color, gridW: 320, gridH: 180, crop: d.crop)
        var stats: [GradeRenderer.ContentFrameStats] = []
        var motion: [Float] = []
        let n = min(40, max(4, d.frameCount / 24))
        for k in 0..<n {
            try Task.checkCancellation()
            let f = Int(Double(d.frameCount - 2) * (0.02 + 0.96 * Double(k) / Double(n - 1)))
            try src.start(at: f, count: 2)
            guard let f0 = try src.nextFrame() else { continue }
            stats.append(await r.contentStats(f0.texture))
            if let f1 = try src.nextFrame() {
                let t0 = r.analyze(f0.texture, uniforms: u, gridWidth: 320).thumbnail
                let t1 = r.analyze(f1.texture, uniforms: u, gridWidth: 320).thumbnail
                motion.append(zip(t0, t1).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(max(1, t0.count)))
            }
            progress.update(Double(k + 1) / Double(n), detail: "Content test \(k + 1)/\(n)")
        }
        src.cancel()
        func median(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        let flat = median(stats.map(\.flatShare)), grain = median(stats.map(\.grain))
        let edges = median(stats.map(\.edgeDensity)), detail = median(stats.map(\.detail))
        let mot = median(motion)
        let repeats = Float(a.duplicateFrames.count) / Float(max(1, a.frameCount))
        let aspect = Float(d.outputWidth) / Float(max(1, d.outputHeight))
        let legacy = d.height <= 576 || d.scanFix != .none || aspect < 1.45

        var ev: [String] = []
        var kind = ContentKind.realLife
        var conf: Float = 0.6
        let animation = (flat > 0.38 && repeats > 0.15) || flat > 0.55 || (flat > 0.3 && edges > 0.03 && repeats > 0.25)
        // Screen content is flat, sharp and mostly unchanging. It has to be tested before animation: every screen
        // recording also passes the flat-colour animation test, so checked afterwards it could never be chosen.
        // Animation on twos/threes repeats about half to two thirds of its frames; a screen far more.
        if flat > 0.6 && edges > 0.03 && mot < 0.003 && repeats > 0.8 {
            kind = .screenContent; conf = 0.7
            ev.append("large flat areas with sharp edges and little motion")
        } else if animation {
            ev.append(String(format: "%.0f%% of the picture is flat colour", flat * 100))
            if repeats > 0.1 { ev.append(String(format: "%.0f%% of frames repeat (drawn on twos/threes)", repeats * 100)) }
            if legacy || grain > 0.008 {
                kind = .oldAnime
                if grain > 0.008 { ev.append("film grain in flat areas") }
                if d.scanFix != .none { ev.append("telecined/interlaced source") }
                if d.height <= 576 { ev.append("standard-definition source") }
                if aspect < 1.45 { ev.append("4:3 picture") }
            } else {
                kind = .anime
            }
            conf = min(0.95, 0.55 + flat * 0.4 + repeats * 0.5)
        } else if grain > 0.011 && a.globalKey < -3.5 {
            kind = .lowLightNoisy; conf = 0.7
            ev.append("dark picture with heavy noise")
        } else if grain > 0.011 {
            kind = .realLifeHeavyGrain; conf = min(0.9, 0.5 + grain * 30)
            ev.append(String(format: "strong grain (%.3f) in smooth areas", grain))
        } else if mot > 0.04 {
            kind = .fastMotion; conf = 0.65
            ev.append("large frame-to-frame changes")
        } else if flat > 0.3 && grain < 0.004 && repeats < 0.05 {
            kind = .cgiAnimation; conf = 0.5
            ev.append("very clean surfaces and gradients, motion on every frame")
        } else {
            ev.append(String(format: "natural texture (detail %.2f), grain %.3f", detail, grain))
        }
        let profile = ContentProfile(kind: kind, confidence: conf, evidence: ev, detail: detail, flatShare: flat,
                                     grain: grain, motion: mot, repeatedFrameShare: repeats)
        Log.notice(.analysis, "Content test: \(kind.displayName) (\(Int(conf * 100))%) — \(ev.joined(separator: "; ")). flat \(flat) grain \(grain) edges \(edges) motion \(mot) repeats \(repeats)")
        return profile
    }
}
