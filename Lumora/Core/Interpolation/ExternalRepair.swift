import Foundation
import Metal

/// How to repair an interpolated file made by any app: which of its frames are the original film frames, and
/// which generated frames failed the check against the true original.
struct ExternalRepairPlan: Codable, Hashable {
    var flagged: Set<Int>          // interpolated-file frame indices to rebuild
    var originalFps: Double
    var interpolatedFps: Double
    var offsetSeconds: Double
    /// Damaged-source mode (render recovery): the flagged frames are the undecodable ones and every other frame is a
    /// good neighbor to rebuild them from.
    var damagedFrames: Bool? = nil

    /// True when frame `j` of the interpolated file coincides with a frame of the original.
    func isOriginal(_ j: Int) -> Bool {
        if damagedFrames == true { return !flagged.contains(j) }
        let posA = (Double(j) / interpolatedFps - offsetSeconds) * originalFps
        return abs(posA - posA.rounded()) < 0.02
    }
}

/// Reads the interpolated file in order and, for flagged frames, regenerates them from the nearest original frames
/// *of that same file* (so its grade and HDR match exactly), using the strongest installed models and the full
/// repair ladder. Everything else passes through untouched.
final class PatchedFrameSource: FrameSource {
    private let base: FrameSource
    private let plan: ExternalRepairPlan
    private let primary: InterpolationEngine?
    private let repair: InterpolationEngine?
    private let qc = InterpolationQC()
    private let blend = BlendInterpolator()
    private let ctx = MetalContext.shared
    private var buffer: [Int: DecodedFrame] = [:]
    private var nextRead = 0
    private var cursor = 0
    private var end = 0
    private(set) var rebuilt = 0

    var width: Int { base.width }
    var height: Int { base.height }
    var fps: Double { base.fps }
    var frameCount: Int { base.frameCount }

    init(base: FrameSource, plan: ExternalRepairPlan, proxyUniforms: GradeUniforms) {
        self.base = base
        self.plan = plan
        let installed = InterpolationModelSpec.all().filter(\.isInstalled)
        let order = installed.sorted { ($0.tier == "best" ? 0 : ($0.isFlow ? 1 : 2)) < ($1.tier == "best" ? 0 : ($1.isFlow ? 1 : 2)) }
        primary = order.first.flatMap { try? CoreMLInterpolator(spec: $0, proxyUniforms: proxyUniforms) }
        repair = order.dropFirst().first.flatMap { try? CoreMLInterpolator(spec: $0, proxyUniforms: proxyUniforms) }
        qc.grainAware = true
    }

    func start(at frame: Int, count: Int?) throws {
        // Start a little earlier so the original frame before the first flagged frame is available.
        let lead = max(0, frame - 12)
        try base.start(at: lead, count: count.map { $0 + (frame - lead) + 12 })
        nextRead = lead
        cursor = frame
        end = count.map { frame + $0 } ?? frameCount
        buffer = [:]
    }

    private func fill(through index: Int) throws {
        while nextRead <= index {
            guard let f = try base.nextFrame() else { break }
            buffer[nextRead] = DecodedFrame(texture: f.texture, index: nextRead, backing: f.backing)
            nextRead += 1
        }
    }

    func nextFrame() throws -> DecodedFrame? {
        guard cursor < end else { return nil }
        let j = cursor
        cursor += 1
        try fill(through: j)
        guard let current = buffer[j] else { return nil }
        defer {
            let prevOriginal = (0...j).reversed().first { plan.isOriginal($0) } ?? j
            buffer = buffer.filter { $0.key >= prevOriginal }
        }
        guard plan.flagged.contains(j), !plan.isOriginal(j) else { return current }
        // Neighboring original frames inside this file.
        guard let a = (max(0, j - 12)...j).reversed().first(where: { plan.isOriginal($0) }),
              let b = (j...(j + 12)).first(where: { plan.isOriginal($0) }), b > a else { return current }
        try fill(through: b)
        guard let fa = buffer[a], let fb = buffer[b] else { return current }
        let t = Float(j - a) / Float(b - a)
        let out = ctx.makeTexture(width: current.texture.width, height: current.texture.height, format: current.texture.pixelFormat)
        let tiles = ((out.width + qc.tileSize - 1) / qc.tileSize, (out.height + qc.tileSize - 1) / qc.tileSize)
        var best = out
        var bestScore: (Float, [Bool]) = (1, [])
        for e in [primary, repair].compactMap({ $0 }) {
            let candidate = ctx.makeTexture(width: out.width, height: out.height, format: out.pixelFormat)
            let r = try e.interpolate(fa.texture, fb.texture, times: [t], into: [candidate], qcTiles: tiles)
            var (frac, bad) = qc.score(a: fa.texture, b: fb.texture, mid: candidate, sensitivity: 0.7)
            if let m = r[0].motionBad, m.count == bad.count {
                bad = zip(bad, m).map { $0 || $1 }
                frac = Float(bad.filter { $0 }.count) / Float(max(1, bad.count))
            }
            if frac < bestScore.0 || best === out { best = candidate; bestScore = (frac, bad) }
        }
        if primary == nil { blend.encode(nil, fa.texture, fb.texture, t: t, into: best); bestScore = (0, []) }
        if bestScore.0 > 0.35 {
            best = (t < 0.5 ? fa : fb).texture
        } else if bestScore.0 > 0 {
            let fallback = ctx.makeTexture(width: out.width, height: out.height, format: out.pixelFormat)
            blend.encode(nil, fa.texture, fb.texture, t: t, into: fallback)
            qc.patch(generated: best, fallback: fallback, bad: bestScore.1, into: out)
            best = out
        }
        rebuilt += 1
        return DecodedFrame(texture: best, index: j, backing: [])
    }

    func cancel() { base.cancel() }
}
