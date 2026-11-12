import Foundation
import AVFoundation
import VideoToolbox
import Metal

/// What "visually indistinguishable" means for this export.
struct QualityTarget: Codable, Hashable {
    var vmaf: Double = 95
    var pool: VMAFRunner.Pool = .mean
    var floorMargin: Double = 3          // the worst 5% may sit at most this far below the target
    var model = "vmaf_v0.6.1"
    var fastValidation = true            // 4K scored at 1080p, every 2nd frame
    var fixDips = true                   // re-encode just the stretches that fall below target
    var maxTrials = 4                    // encodes per chunk while searching
    var profile: QualityProfile = QualityProfile.presets(hdr: true)[0]

    var plainEnglish: String {
        switch vmaf {
        case 97...: return "Practically identical to the master, even frame by frame on a large screen."
        case 94..<97: return "Visually indistinguishable at normal viewing distance. The sweet spot for archiving."
        case 90..<94: return "Excellent; differences only on close inspection of hard scenes."
        default: return "Good streaming quality; some loss is visible on careful viewing."
        }
    }
}

/// Live state for the encode monitor (charts and chunk map).
@MainActor
@Observable
final class EncodeMonitor {
    static let shared = EncodeMonitor()

    struct Chunk: Identifiable, Hashable {
        enum State: String { case waiting = "Waiting", rendering = "Rendering", searching = "Searching", verifying = "Perceptual check", fixing = "Fixing dips", done = "Done", failed = "Failed" }
        let id: Int
        var range: Range<Int>
        var state: State = .waiting
        var setting: String = ""
        var trials = 0
        var vmafMean: Double?
        var vmafLow: Double?
        var bytes: Int64 = 0
        var metrics: [String: Double] = [:]      // pooled score per metric for the accepted encode
        var failures: [String] = []              // gates that forced extra quality
    }

    var target: QualityTarget?
    var forecast: SizeForecast?
    var chunks: [Chunk] = []
    var frameScores: [Int: Double] = [:]          // output frame -> VMAF
    var totalFrames = 0
    var encodedBytes: Int64 { chunks.reduce(0) { $0 + $1.bytes } }

    /// Final size projected from finished chunks, blended with the forecast until enough of the film is done.
    var projectedBytes: Int64? {
        let done = chunks.filter { $0.state == .done }
        let framesDone = done.reduce(0) { $0 + $1.range.count }
        guard framesDone > 0, totalFrames > 0 else { return forecast?.mid }
        let progress = Double(framesDone) / Double(totalFrames)
        let other = forecast?.otherBytes ?? 0
        let measured = Double(done.reduce(0) { $0 + $1.bytes }) / Double(framesDone) * Double(totalFrames) + Double(other)
        guard let f = forecast else { return Int64(measured) }
        let w = min(1, progress * 3)          // trust measurements fully once a third of the film is encoded
        return Int64(measured * w + Double(f.mid) * (1 - w))
    }

    func reset(target: QualityTarget?, chunks: [Range<Int>], totalFrames: Int) {
        self.target = target
        self.chunks = chunks.enumerated().map { Chunk(id: $0.offset, range: $0.element) }
        frameScores = [:]
        self.totalFrames = totalFrames
    }

    func update(_ id: Int, _ f: (inout Chunk) -> Void) {
        guard let i = chunks.firstIndex(where: { $0.id == id }) else { return }
        f(&chunks[i])
    }
}

/// Encodes in scene-aligned chunks with a VMAF target:
///   1. Lumora renders each chunk once (decode → interpolate → upscale → grade) into RAM. No frame dumps.
///   2. A predictor trained on your past encodes proposes a starting setting.
///   3. The chunk is encoded, decoded and scored against the RAM master; the setting is refined (secant search)
///      until it is the cheapest one that meets the target.
///   4. Any stretch that still dips (1-second windows below target) is split out and re-encoded on its own,
///      so the weak spots get more bits without inflating the rest.
/// Several chunks run concurrently: GPU renders the next while CPU encoders and VMAF work on earlier ones.
final class TargetQualityEncoder {
    struct Piece { var start: Int; var url: URL; var count: Int = 0; var level: Double = 0 }

    private let engine: ExportEngine
    init(engine: ExportEngine) { self.engine = engine }

    /// Encoder "level": higher = better quality. CLI encoders: -CRF/QP. VideoToolbox: quality × 100.
    struct LevelRange { var low: Double; var high: Double; var step: Double; var start: Double }

    static func levelRange(_ codec: Codec) -> LevelRange {
        switch codec {
        case .av1: return LevelRange(low: -55, high: -10, step: 1, start: -30)
        case .av1Pro: return LevelRange(low: -50, high: -8, step: 1, start: -28)
        case .vvc: return LevelRange(low: -45, high: -15, step: 1, start: -30)
        case .hevc12: return LevelRange(low: -35, high: -8, step: 1, start: -20)
        case .hevc: return LevelRange(low: 30, high: 96, step: 2, start: 62)
        default: return LevelRange(low: 0, high: 100, step: 1, start: 80)
        }
    }

    static func describe(_ codec: Codec, level: Double) -> String {
        codec == .hevc ? String(format: "quality %.2f", level / 100) : (codec == .vvc ? "QP \(Int(-level))" : "CRF \(Int(-level))")
    }

    func encode(frames: [PlanarFrame], chunkID: Int, start: Int, sceneStats: SceneStats, interpolatedShare: Double,
                kind: ContentKind, encodeOne: @escaping ([PlanarFrame], Double, URL) async throws -> Void,
                target: QualityTarget, rate: (Int, Int), workDir: URL, threads: Int, codec: Codec, hdr: Bool = true,
                referenceFrames: [PlanarFrame]? = nil, stripSyntheticGrain: Bool = false) async throws -> [Piece] {
        let range = Self.levelRange(codec)
        let key = codec.rawValue
        let (profile, _) = target.profile.effective()
        let primary = profile.primary ?? MetricRule(metric: .vmaf, role: .target, threshold: target.vmaf)
        let x = QualityPredictor.features(scene: sceneStats, interpolatedShare: interpolatedShare,
                                          pixels: (frames.first?.width ?? 0) * (frames.first?.height ?? 0), kind: kind, target: primary.threshold)
        var level = min(range.high, max(range.low, (QualityPredictor.shared.predict(codecKey: key, x: x) ?? range.start).rounded()))
        let w = frames.first?.width ?? 0, h = frames.first?.height ?? 0
        let active = profile.rules.filter { $0.role != .off && $0.metric != .avqt }
        let fastSet = Set(active.filter { !$0.metric.slow }.map(\.metric)).union([primary.metric])
        let slowSet = Set(active.filter { $0.metric.slow }.map(\.metric))
        var mctx = MetricSuite.Context(width: w, height: h, rate: rate, hdr: hdr, frames: frames.count, threads: threads,
                                       fast: target.fastValidation, workDir: workDir)
        mctx.stripSyntheticGrain = stripSyntheticGrain
        // With grain synthesis, metrics compare against the de-grained master (what the encoder actually keeps).
        let reference = referenceFrames ?? frames

        func measure(_ f: ArraySlice<PlanarFrame>, _ url: URL, slow: Bool) async throws -> MetricScores {
            var c = mctx
            c.frames = f.count
            let refSlice = reference[f.startIndex..<f.endIndex]
            return try await MetricSuite.measure(slow ? fastSet.union(slowSet) : fastSet, reference: { handle in
                try handle.write(contentsOf: Data(PlanarFrame.y4mHeader420p10(width: w, height: h, fps: rate).utf8))
                for p in refSlice { try p.writeY4M420p10(to: handle) }
            }, distorted: url, ctx: c)
        }
        func primaryScore(_ s: MetricScores) -> Double { s.value(primary) ?? 0 }
        /// Fast check: search target + fast gates + the worst-frames floor on the search metric.
        func passesFast(_ s: MetricScores) -> Bool {
            guard s.passes(profile, includeSlow: false).ok else { return false }
            if let worst = s.pooled[primary.metric]?.worst, primary.metric.higherIsBetter {
                return worst >= primary.threshold - target.floorMargin
            }
            return true
        }
        /// How far a trial clears the fast check (negative = short of it): the mean against the target and, for a
        /// higher-is-better search metric, the worst frames against the floor. The search interpolates on this, so a
        /// chunk held back by its worst frames is steered by them rather than by a mean that already passes.
        func margin(_ s: MetricScores) -> Double {
            let score = primaryScore(s)
            guard primary.metric.higherIsBetter else { return primary.threshold - score }
            var m = score - primary.threshold
            if let worst = s.pooled[primary.metric]?.worst { m = min(m, worst - (primary.threshold - target.floorMargin)) }
            return m
        }
        func fastFailures(_ s: MetricScores) -> [String] {
            var f = s.passes(profile, includeSlow: false).failures
            if primary.metric.higherIsBetter, let worst = s.pooled[primary.metric]?.worst, worst < primary.threshold - target.floorMargin {
                f.append("worst 5% \(String(format: "%.2f", worst)) < floor \(String(format: "%.2f", primary.threshold - target.floorMargin))")
            }
            return f
        }
        func file(_ tag: String) -> URL {
            let ext = codec == .hevc ? "mov" : (EncoderCatalog.shared.spec(for: codec.cliKey ?? "")?.ext ?? "bin")
            return workDir.appendingPathComponent("chunk\(chunkID)-\(tag).\(ext)")
        }
        func publish(_ s: MetricScores, offset: Int = 0) async {
            let per = s.perFrame[primary.metric] ?? []
            let pooled = Dictionary(uniqueKeysWithValues: s.pooled.map { ($0.key.rawValue, $0.value.mean) })
            await MainActor.run {
                for (f, v) in per { EncodeMonitor.shared.frameScores[start + offset + f] = v }
                EncodeMonitor.shared.update(chunkID) { c in
                    c.vmafMean = s.pooled[.vmaf]?.mean ?? c.vmafMean
                    c.vmafLow = s.pooled[.vmaf]?.worst ?? c.vmafLow
                    c.metrics.merge(pooled) { _, new in new }
                }
            }
        }

        // --- 1. Search: cheapest level meeting the search target and fast gates.
        var tried: [(level: Double, score: Double, margin: Double, ok: Bool, scores: MetricScores, url: URL)] = []
        await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.state = .searching } }
        for trial in 0..<target.maxTrials {
            try Task.checkCancellation()
            let url = file("t\(trial)")
            try await encodeOne(frames, level, url)
            let sc = try await measure(frames[...], url, slow: false)
            let ok = passesFast(sc)
            tried.append((level, primaryScore(sc), margin(sc), ok, sc, url))
            Log.info(.quality, "Chunk \(chunkID) trial \(trial + 1): \(Self.describe(codec, level: level)) → \(primary.metric.displayName) \(String(format: "%.2f", primaryScore(sc)))\(ok ? "" : " (" + fastFailures(sc).joined(separator: ", ") + ")")")
            let lvl = level
            await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.trials += 1; $0.setting = Self.describe(codec, level: lvl) } }
            await publish(sc)
            let bestPass = tried.filter(\.ok).min { $0.level < $1.level }
            let failBelow = tried.filter { t in !t.ok && (bestPass.map { t.level < $0.level } ?? true) }.max { $0.level < $1.level }
            if let p = bestPass, let f = failBelow, p.level - f.level <= range.step { break }
            var next: Double
            let gap = -margin(sc)
            if let p = bestPass, let f = failBelow {
                let t = -f.margin / max(0.01, p.margin - f.margin)
                next = f.level + (p.level - f.level) * min(0.9, max(0.1, t))
            } else if bestPass != nil {
                next = level - max(range.step, -gap * (codec == .hevc ? 3 : 1.2) + range.step)
            } else {
                next = level + max(range.step, max(0, gap) * (codec == .hevc ? 3 : 1.2) + range.step)
            }
            next = min(range.high, max(range.low, (next / range.step).rounded() * range.step))
            if tried.contains(where: { $0.level == next }) { break }
            level = next
        }
        var chosen = tried.filter(\.ok).min { $0.level < $1.level } ?? tried.max { $0.score < $1.score }!
        for t in tried where t.url != chosen.url { try? FileManager.default.removeItem(at: t.url) }
        // The monitor shows the accepted encode, not whichever trial happened to run last.
        do {
            let lvl = chosen.level
            await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.setting = Self.describe(codec, level: lvl) } }
            await publish(chosen.scores)
        }

        // --- 2. Prove it: perceptual gates (ColorVideoVDP, SSIMULACRA 2) on the chosen encode; step up if needed.
        var chosenScores = chosen.scores
        if !slowSet.isEmpty {
            await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.state = .verifying } }
            for attempt in 0..<4 {
                let slow = try await measure(frames[...], chosen.url, slow: true)
                chosenScores = slow
                await publish(slow)
                let verdict = slow.passes(profile, includeSlow: true)
                if verdict.ok || chosen.level >= range.high {
                    if !verdict.ok { Log.warning(.quality, "Chunk \(chunkID): best possible setting still fails \(verdict.failures.joined(separator: ", "))") }
                    break
                }
                Log.notice(.quality, "Chunk \(chunkID): perceptual check failed (\(verdict.failures.joined(separator: ", "))); raising quality (attempt \(attempt + 1))")
                let failures = verdict.failures
                await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.failures = failures } }
                let lvl = min(range.high, chosen.level + range.step * (codec == .hevc ? 4 : 2))
                let url = file("g\(attempt)")
                try await encodeOne(frames, lvl, url)
                try? FileManager.default.removeItem(at: chosen.url)
                chosen = (lvl, 0, 0, true, MetricScores(), url)
                await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.setting = Self.describe(codec, level: lvl); $0.trials += 1 } }
            }
        }
        QualityPredictor.shared.record(codecKey: key, x: x, level: chosen.level)

        // --- 3. Fix dips: 1-second windows of the search metric clearly below target get re-encoded on their own.
        let second = max(12, rate.0 / max(1, rate.1))
        let scored = Dictionary((chosenScores.perFrame[primary.metric] ?? []).map { ($0.index, $0.value) }, uniquingKeysWith: { a, _ in a })
        var dips: [Range<Int>] = []
        if target.fixDips, frames.count > second * 2, primary.metric.higherIsBetter {
            var i = 0
            while i < frames.count {
                let window = i..<min(frames.count, i + second)
                let vals = window.compactMap { scored[$0] }
                if !vals.isEmpty, vals.reduce(0, +) / Double(vals.count) < primary.threshold - 2 {
                    if let last = dips.last, last.upperBound >= window.lowerBound { dips[dips.count - 1] = last.lowerBound..<window.upperBound }
                    else { dips.append(window) }
                }
                i += second / 2
            }
        }
        guard !dips.isEmpty else {
            let size = (try? chosen.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.state = .done; $0.bytes = Int64(size) } }
            return [Piece(start: start, url: chosen.url, count: frames.count, level: chosen.level)]
        }
        await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.state = .fixing } }
        Log.notice(.quality, "Chunk \(chunkID): \(dips.count) stretch(es) dip below target; re-encoding them separately")
        try? FileManager.default.removeItem(at: chosen.url)
        var bounds = [0]
        for d in dips { bounds.append(d.lowerBound); bounds.append(d.upperBound) }
        bounds.append(frames.count)
        bounds = Array(Set(bounds)).sorted()
        var pieces: [Piece] = []
        var totalBytes: Int64 = 0
        for (n, (a, b)) in zip(bounds, bounds.dropFirst()).enumerated() where b > a {
            let isDip = dips.contains { $0.lowerBound == a }
            var lvl = chosen.level
            var url = file("p\(n)")
            try await encodeOne(Array(frames[a..<b]), lvl, url)
            if isDip {
                for _ in 0..<3 {
                    let r = try await measure(frames[a..<b], url, slow: false)
                    await publish(r, offset: a)
                    if passesFast(r) || lvl >= range.high { break }
                    lvl = min(range.high, lvl + range.step * (codec == .hevc ? 4 : 2))
                    try? FileManager.default.removeItem(at: url)
                    url = file("p\(n)-\(Int(abs(lvl)))")
                    try await encodeOne(Array(frames[a..<b]), lvl, url)
                }
                Log.info(.quality, "Chunk \(chunkID) dip \(a)–\(b) fixed at \(Self.describe(codec, level: lvl))")
            }
            totalBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            pieces.append(Piece(start: start + a, url: url, count: b - a, level: lvl))
        }
        let bytes = totalBytes
        await MainActor.run { EncodeMonitor.shared.update(chunkID) { $0.state = .done; $0.bytes = bytes } }
        return pieces
    }
}

extension PlanarFrame {
    /// CPU copy into a 10-bit biplanar pixel buffer (x420) for the VideoToolbox HEVC encoder.
    func fill(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let shiftUp = UInt16(16 - bits)
        let ys = y.contents().bindMemory(to: UInt16.self, capacity: width * height)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                let dst = (base + row * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { dst[x] = ys[row * width + x] << shiftUp }
            }
        }
        let cbs = cb.contents().bindMemory(to: UInt16.self, capacity: chromaWidth * chromaHeight)
        let crs = cr.contents().bindMemory(to: UInt16.self, capacity: chromaWidth * chromaHeight)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<(height / 2) {
                let dst = (base + row * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<(width / 2) {
                    let i = row * chromaWidth + x
                    dst[2 * x] = cbs[i] << shiftUp
                    dst[2 * x + 1] = crs[i] << shiftUp
                }
            }
        }
    }
}
