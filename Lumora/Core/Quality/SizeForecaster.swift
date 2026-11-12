import Foundation
import AVFoundation

/// "≈16 GB (14–18), 73% smaller, looks identical, about 9 hr" — before you encode, refined while you encode,
/// and more accurate after every finished export.
struct SizeForecast: Equatable {
    enum Method: String { case quick = "quick estimate", sampled = "measured on samples of this film" }
    var low: Int64
    var mid: Int64
    var high: Int64
    var videoMid: Int64
    var otherBytes: Int64          // audio, subtitles and chapters carried over unchanged
    var sourceBytes: Int64
    var method: Method
    var learnedFrom: Int           // finished encodes used to correct this kind of forecast
    var key: String                // settings this forecast belongs to

    var savingFraction: Double { sourceBytes > 0 ? 1 - Double(mid) / Double(sourceBytes) : 0 }
    var confidenceText: String {
        let spread = Double(high - low) / Double(max(1, mid)) / 2
        return "±\(Int((spread * 100).rounded()))%"
    }

    static func gb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// Sizes of the source's streams, measured from the container (exact where the container records it).
struct StreamSizes {
    var total: Int64
    var video: Int64
    var other: Int64

    static func probe(_ d: SourceDescriptor) async -> StreamSizes {
        if d.kind == .rawSequence {
            let total = d.files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return StreamSizes(total: total, video: total, other: 0)
        }
        let total = Int64((try? d.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if d.kind == .avfoundation {
            let asset = AVURLAsset(url: d.url)
            var video: Int64 = 0, other: Int64 = 0
            for t in (try? await asset.load(.tracks)) ?? [] {
                let bytes = (try? await t.load(.totalSampleDataLength)) ?? 0
                if t.mediaType == .video { video += bytes } else { other += bytes }
            }
            if video > 0 { return StreamSizes(total: total, video: video, other: other) }
        }
        // FFmpeg containers (MKV etc.): mkvmerge writes NUMBER_OF_BYTES tags; otherwise bit_rate × duration.
        guard let json = try? ToolLocator.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", d.url.path]),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            return StreamSizes(total: total, video: total, other: 0)
        }
        let duration = Double((root["format"] as? [String: Any])?["duration"] as? String ?? "") ?? d.durationSeconds
        var video: Int64 = 0, other: Int64 = 0
        for s in streams {
            let tags = s["tags"] as? [String: Any] ?? [:]
            var bytes: Int64 = 0
            if let k = tags.keys.first(where: { $0.uppercased().hasPrefix("NUMBER_OF_BYTES") }), let v = Int64("\(tags[k]!)") { bytes = v }
            else if let br = Double(s["bit_rate"] as? String ?? "") { bytes = Int64(br * duration / 8) }
            else if let k = tags.keys.first(where: { $0.uppercased().hasPrefix("BPS") }), let br = Double("\(tags[k]!)") { bytes = Int64(br * duration / 8) }
            if s["codec_type"] as? String == "video" { video += bytes } else if s["codec_type"] as? String != "attachment" { other += bytes }
        }
        if video == 0 { video = max(0, total - other) }
        return StreamSizes(total: total, video: video, other: other)
    }
}

/// Learns how far forecasts land from reality, per codec and content type, and corrects future ones.
final class ForecastLearner: @unchecked Sendable {
    static let shared = ForecastLearner()
    private var ratios: [String: [Double]] = [:]
    private let lock = NSLock()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("forecast-learning.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([String: [Double]].self, from: d) { ratios = r }
    }

    static func key(_ codec: Codec, _ kind: ContentKind, _ method: SizeForecast.Method) -> String {
        "\(codec.rawValue)-\(kind.rawValue)-\(method == .quick ? "q" : "s")"
    }

    /// Median actual/forecast ratio and the spread of past errors.
    func correction(_ key: String) -> (factor: Double, spread: Double?, count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let r = ratios[key], r.count >= 3 else { return (1, nil, ratios[key]?.count ?? 0) }
        let s = r.sorted()
        let median = s[s.count / 2]
        let mad = s.map { abs($0 - median) }.sorted()[s.count / 2]
        return (median, max(0.04, mad * 1.5 / median), r.count)
    }

    func record(_ key: String, forecast: Int64, actual: Int64) {
        guard forecast > 0, actual > 0 else { return }
        lock.lock()
        ratios[key, default: []].append(Double(actual) / Double(forecast))
        if ratios[key]!.count > 200 { ratios[key]!.removeFirst(50) }
        let snapshot = ratios
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
        Log.notice(.encode, "Forecast learning (\(key)): forecast \(SizeForecast.gb(forecast)), actual \(SizeForecast.gb(actual))")
    }
}

enum SizeForecaster {
    /// Bits per pixel per frame for a visually-indistinguishable encode of 24 fps 4K, by content type (AV1 baseline).
    /// Seeds from typical results; replaced by sampling and learning.
    static func baseBPP(_ kind: ContentKind, grainSynthesis: Bool) -> Double {
        switch kind {
        case .realLife: return 0.060
        case .realLifeHeavyGrain: return grainSynthesis ? 0.066 : 0.12
        case .anime: return 0.032
        case .oldAnime: return grainSynthesis ? 0.035 : 0.05
        case .cgiAnimation: return 0.040
        case .screenContent: return 0.020
        case .lowLightNoisy: return grainSynthesis ? 0.06 : 0.09
        case .fastMotion: return 0.080
        }
    }

    static func codecFactor(_ c: Codec) -> Double {
        switch c {
        case .av1: return 1.0
        case .av1Pro: return 0.95
        case .hevc12: return 1.35
        case .hevc: return 1.7
        case .vvc: return 0.85
        case .av2: return 0.75
        case .prores422HQ, .prores4444XQ: return 1
        }
    }

    /// How strict the quality standard is, relative to "imperceptible".
    static func qualityFactor(_ target: QualityTarget?, quality: Float) -> Double {
        guard let t = target else { return pow(1.1, Double(quality - 0.8) * 20) }   // fixed-quality slider
        switch t.profile.name {
        case "Imperceptible": return 1.0
        case "Visually lossless": return 0.88
        case "Transparent streaming": return 0.8
        default: return pow(1.08, (t.profile.primary?.threshold ?? t.vmaf) - 95)
        }
    }

    /// Instant estimate from duration, resolution, frame rate, content and settings. Typically within ±30%.
    static func quick(width: Int, height: Int, outputFrames: Int, outputFps: Double, codec: Codec, kind: ContentKind,
                      grainSynthesis: Bool, target: QualityTarget?, quality: Float, bitDepth: Int, chroma: ChromaFormat,
                      source: StreamSizes, carryOther: Bool, key: String) -> SizeForecast {
        let pixels = Double(width * height)
        var videoBytes: Double
        if codec == .prores422HQ || codec == .prores4444XQ {
            // Apple's published ProRes data rates, expressed per pixel per frame.
            let bpp = codec == .prores422HQ ? 3.54 : 8.04
            videoBytes = bpp * pixels * Double(outputFrames) / 8
        } else {
            var bpp = baseBPP(kind, grainSynthesis: grainSynthesis) * codecFactor(codec) * qualityFactor(target, quality: quality)
            bpp *= pow(pixels / 8_294_400, -0.25)                         // lower resolutions need more bits per pixel
            bpp *= pow(max(1, outputFps / 24), -0.55)                     // extra (interpolated) frames are cheap
            if bitDepth >= 12 { bpp *= 1.15 }
            if chroma == .c444 { bpp *= 1.35 } else if chroma == .c422 { bpp *= 1.15 }
            videoBytes = bpp * pixels * Double(outputFrames) / 8
        }
        let other = carryOther ? source.other : 0
        let corr = ForecastLearner.shared.correction(ForecastLearner.key(codec, kind, .quick))
        let mid = videoBytes * corr.factor
        let spread = corr.spread ?? 0.32
        return SizeForecast(low: Int64(mid * (1 - spread)) + other, mid: Int64(mid) + other, high: Int64(mid * (1 + spread * 1.1)) + other,
                            videoMid: Int64(mid), otherBytes: other, sourceBytes: source.total, method: .quick,
                            learnedFrom: corr.count, key: key)
    }

    struct Sample { var scene: Int; var bytesPerFrame: Double }

    /// Extrapolates from sample encodes across every scene of the film, weighting by how alike scenes are.
    static func fromSamples(_ samples: [Sample], analysis a: AnalysisResult, sceneOutputFrames: [Int: Int],
                            chunkFrames: Int, sampleFrames: Int, codec: Codec, kind: ContentKind,
                            source: StreamSizes, carryOther: Bool, key: String) -> SizeForecast {
        func features(_ s: SceneStats) -> [Double] {
            [Double(s.p995 - s.p005), Double(s.avgChroma) * 20, Double(s.keyStops), Double(s.skinFraction) * 5]
        }
        let all = a.scenes.map(features)
        let dims = all.first?.count ?? 0
        let std = (0..<dims).map { d -> Double in
            let v = all.map { $0[d] }, m = v.reduce(0, +) / Double(max(1, v.count))
            return max(0.05, sqrt(v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, v.count))))
        }
        func dist(_ x: [Double], _ y: [Double]) -> Double { sqrt(zip(zip(x, y), std).reduce(0) { $0 + pow(($1.0.0 - $1.0.1) / $1.1, 2) }) }

        // A sample starts with a keyframe (~6× a normal frame); real chunks have one per `chunkFrames`.
        let keyframeFix = (Double(chunkFrames - 1) + 6) / Double(chunkFrames) / ((Double(sampleFrames - 1) + 6) / Double(sampleFrames))
        var video = 0.0, coverage = 0.0
        for (i, s) in a.scenes.enumerated() {
            let frames = Double(sceneOutputFrames[i] ?? 0)
            guard frames > 0 else { continue }
            let f = features(s)
            var wsum = 0.0, bsum = 0.0, nearest = Double.infinity
            for smp in samples {
                guard let sf = a.scenes[safe: smp.scene].map(features) else { continue }
                let d = dist(f, sf)
                nearest = min(nearest, d)
                let w = 1 / (d * d + 0.05)
                wsum += w; bsum += w * smp.bytesPerFrame
            }
            video += frames * (wsum > 0 ? bsum / wsum : 0) * keyframeFix
            coverage += frames * min(nearest, 4)
        }
        let totalFrames = Double(max(1, sceneOutputFrames.values.reduce(0, +)))
        let values = samples.map(\.bytesPerFrame)
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        let cv = values.count > 1 ? sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)) / max(1, mean) : 0.5
        let corr = ForecastLearner.shared.correction(ForecastLearner.key(codec, kind, .sampled))
        var spread = max(0.06, 0.5 * cv / sqrt(Double(max(1, samples.count)))) + 0.04 * coverage / totalFrames
        if let learned = corr.spread { spread = min(spread, learned) }
        let mid = video * corr.factor
        let other = carryOther ? source.other : 0
        return SizeForecast(low: Int64(mid * (1 - spread)) + other, mid: Int64(mid) + other, high: Int64(mid * (1 + spread)) + other,
                            videoMid: Int64(mid), otherBytes: other, sourceBytes: source.total, method: .sampled,
                            learnedFrom: corr.count, key: key)
    }

    /// Which scenes to sample: spread across difficulty (range, color, darkness), largest scenes first on ties.
    static func pickScenes(_ a: AnalysisResult, count: Int) -> [Int] {
        let usable = a.scenes.enumerated().filter { $0.element.end - $0.element.start >= 24 }
        guard !usable.isEmpty else { return a.scenes.indices.prefix(count).map { $0 } }
        let scored = usable.map { (i: $0.offset, d: Double($0.element.p995 - $0.element.p005) + Double($0.element.avgChroma) * 20 - Double($0.element.keyStops) * 0.3) }
            .sorted { $0.d < $1.d }
        let n = min(count, scored.count)
        return (0..<n).map { scored[Int(Double($0) / Double(max(1, n - 1)) * Double(scored.count - 1))].i }
    }
}
