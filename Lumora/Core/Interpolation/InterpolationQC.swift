import Foundation
import Metal
import MetalPerformanceShaders

struct QCEvent: Codable, Hashable, Identifiable {
    enum Action: String, Codable {
        case accepted = "Clean"
        case reRendered = "Re-rendered with stronger model"
        case patched = "Bad regions patched"
        case replaced = "Frame replaced (too broken to patch)"
    }
    var id: Int { outputIndex }
    var outputIndex: Int
    var sourceA: Int
    var t: Float
    var badFraction: Float
    var action: Action
}

/// Finds interpolation artifacts and repairs only what's broken.
/// Repair ladder: 1) re-run that one frame with the stronger model and keep whichever is cleaner,
/// 2) patch only the bad tiles through a feathered mask, 3) if most of the frame is broken, replace it.
final class InterpolationQC {
    let tileSize = 64
    private let ctx = MetalContext.shared
    private var tileBuffer: MTLBuffer?
    private var maskTexture: MTLTexture?
    private var tiles = (x: 0, y: 0)

    /// Grain-aware scoring ignores film grain (it's random by nature) and looks only at real structure.
    var grainAware = false

    func score(a: MTLTexture, b: MTLTexture, mid: MTLTexture, sensitivity: Float) -> (fraction: Float, bad: [Bool]) {
        let tx = (mid.width + tileSize - 1) / tileSize, ty = (mid.height + tileSize - 1) / tileSize
        if tx != tiles.x || ty != tiles.y || tileBuffer == nil {
            tiles = (tx, ty)
            tileBuffer = ctx.device.makeBuffer(length: tx * ty * 4, options: .storageModeShared)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: tx, height: ty, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            maskTexture = ctx.device.makeTexture(descriptor: d)
        }
        memset(tileBuffer!.contents(), 0, tileBuffer!.length)
        var q = InterpQCUniforms(tileSize: Int32(tileSize), threshold: 0.10 - 0.06 * sensitivity,
                                 tilesX: Int32(tx), tilesY: Int32(ty), smooth: grainAware ? 1 : 0, pad0: 0, pad1: 0, pad2: 0)
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(a, index: 0)
        enc.setTexture(b, index: 1)
        enc.setTexture(mid, index: 2)
        enc.setBytes(&q, length: MemoryLayout<InterpQCUniforms>.stride, index: 0)
        enc.setBuffer(tileBuffer, offset: 0, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("interpQCKernel"), width: mid.width, height: mid.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let counts = tileBuffer!.contents().bindMemory(to: UInt32.self, capacity: tx * ty)
        let sampled = Float(tileSize * tileSize / 4)
        let limit = sampled * (0.08 - 0.05 * sensitivity)
        let bad = (0..<(tx * ty)).map { Float(counts[$0]) > limit }
        return (Float(bad.filter { $0 }.count) / Float(max(1, bad.count)), bad)
    }

    /// Blends `fallback` over `generated` only inside the (dilated, feathered) bad tiles.
    func patch(generated: MTLTexture, fallback: MTLTexture, bad: [Bool], into dst: MTLTexture) {
        var mask = [Float](repeating: 0, count: tiles.x * tiles.y)
        for y in 0..<tiles.y {
            for x in 0..<tiles.x where bad[y * tiles.x + x] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, ny >= 0, nx < tiles.x, ny < tiles.y { mask[ny * tiles.x + nx] = 1 }
                    }
                }
            }
        }
        mask.withUnsafeBytes {
            maskTexture!.replace(region: MTLRegionMake2D(0, 0, tiles.x, tiles.y), mipmapLevel: 0,
                                 withBytes: $0.baseAddress!, bytesPerRow: tiles.x * 4)
        }
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(generated, index: 0)
        enc.setTexture(fallback, index: 1)
        enc.setTexture(maskTexture, index: 2)
        enc.setTexture(dst, index: 3)
        ctx.dispatch2D(enc, ctx.pipeline("repairKernel"), width: dst.width, height: dst.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

struct StreamFrame {
    let texture: MTLTexture
    let outputIndex: Int
    let sourceIndex: Int      // nearest source frame: used for per-scene grading
    let backing: [AnyObject]
}

/// Produces the output frame sequence: originals untouched, generated frames checked and repaired.
/// Frames between the same pair of originals are generated in one batched model call. With a motion map, each scene
/// uses its own winning model; uncertain or painful scenes are generated twice and the cleaner frame is kept.
final class FrameStream {
    let plan: ArraySlice<PlannedFrame>
    private let source: FrameSource
    private let settings: InterpolationSettings
    private let sceneOf: (Int) -> Int
    private let proxy: GradeUniforms
    private var engines: [String: InterpolationEngine] = [:]
    private let repairEngine: InterpolationEngine?
    private let blend = BlendInterpolator()
    private let qc = InterpolationQC()
    private let grain = GrainProcessor()
    private var grainSigma: Float?
    private var cleanCache: [Int: MTLTexture] = [:]
    private let proxyWidth: Int?
    private let ctx = MetalContext.shared
    private var window: [Int: DecodedFrame] = [:]
    private var nextSourceIndex: Int
    private var cursor: Int
    private var ready: [StreamFrame] = []
    private var ring: [MTLTexture] = []
    private var ringIndex = 0
    private(set) var events: [QCEvent] = []

    /// - proxyUniforms: decode uniforms for the source colour (flow models estimate motion on an SDR-like proxy).
    /// - sceneOf: source frame → scene index (for per-scene routing).
    init(source: FrameSource, plan: ArraySlice<PlannedFrame>, settings: InterpolationSettings,
         proxyUniforms: GradeUniforms, proxyWidth: Int? = nil, sceneOf: @escaping (Int) -> Int = { _ in 0 }) throws {
        self.source = source
        self.plan = plan
        self.settings = settings
        self.proxyWidth = proxyWidth
        self.sceneOf = sceneOf
        self.proxy = proxyUniforms
        self.cursor = plan.startIndex
        qc.grainAware = settings.grainAware
        let specs = InterpolationModelSpec.all()
        if plan.contains(where: { $0.kind == .generated }), settings.artifactRepair, let id = settings.repairModelID,
           let s = specs.first(where: { $0.id == id }), s.isInstalled {
            repairEngine = try CoreMLInterpolator(spec: s, proxyUniforms: proxyUniforms)
        } else {
            repairEngine = nil
        }
        let first = plan.first.map { min($0.a, $0.b) } ?? 0
        let last = plan.last.map { max($0.a, $0.b) } ?? 0
        try source.start(at: first, count: last - first + 1)
        nextSourceIndex = first
    }

    /// The model for a scene: its motion-map route, else the film-wide choice. Loaded once, then reused.
    private func engine(forScene scene: Int) -> (InterpolationEngine?, SceneRoute?) {
        let route = settings.routes[scene]
        let id = route?.model ?? settings.primaryModelID
        if let e = engines[id] { return (e, route) }
        guard let spec = InterpolationModelSpec.all().first(where: { $0.id == id && $0.isInstalled }),
              let e = try? CoreMLInterpolator(spec: spec, proxyUniforms: proxy) else { return (nil, route) }
        engines[id] = e
        return (e, route)
    }

    private func load(upTo index: Int) throws {
        while nextSourceIndex <= index {
            guard var f = try source.nextFrame() else { break }
            if let pw = proxyWidth, f.texture.width > pw {
                let ph = (pw * f.texture.height / f.texture.width) & ~1
                let small = ctx.makeTexture(width: pw, height: ph, format: f.texture.pixelFormat)
                let cb = ctx.queue.makeCommandBuffer()!
                MPSImageBilinearScale(device: ctx.device).encode(commandBuffer: cb, sourceTexture: f.texture, destinationTexture: small)
                cb.commit()
                cb.waitUntilCompleted()
                f = DecodedFrame(texture: small, index: f.index, backing: [])
            }
            window[nextSourceIndex] = DecodedFrame(texture: f.texture, index: nextSourceIndex, backing: f.backing)
            nextSourceIndex += 1
        }
    }

    private func scratch(like t: MTLTexture) -> MTLTexture {
        if ring.isEmpty || ring[0].width != t.width || ring[0].height != t.height || ring[0].pixelFormat != t.pixelFormat {
            ring = (0..<32).map { _ in ctx.makeTexture(width: t.width, height: t.height, format: t.pixelFormat) }
        }
        ringIndex = (ringIndex + 1) % ring.count
        return ring[ringIndex]
    }

    /// Grain-free version of a source frame (cached while it's in the window).
    private func clean(_ f: DecodedFrame) -> MTLTexture {
        if let c = cleanCache[f.index] { return c }
        if grainSigma == nil { grainSigma = max(0.002, grain.measure(f.texture).overall) }
        let out = ctx.makeTexture(width: f.texture.width, height: f.texture.height, format: f.texture.pixelFormat)
        let cb = ctx.queue.makeCommandBuffer()!
        grain.denoise(cb, f.texture, into: out, sigma: grainSigma!)
        cb.commit(); cb.waitUntilCompleted()
        cleanCache[f.index] = out
        return out
    }

    func next() throws -> StreamFrame? {
        if !ready.isEmpty { return ready.removeFirst() }
        guard cursor < plan.endIndex else { return nil }
        let p = plan[cursor]
        try load(upTo: max(p.a, p.b))
        let keep = min(p.a, p.b)
        window = window.filter { $0.key >= keep }
        cleanCache = cleanCache.filter { $0.key >= keep }
        guard let fa = window[p.a] else { return nil }
        let nearest = p.t < 0.5 ? p.a : p.b

        switch p.kind {
        case .original, .holdAcrossCut:
            cursor += 1
            return StreamFrame(texture: fa.texture, outputIndex: cursor - 1, sourceIndex: p.a, backing: fa.backing)
        case .transitionBlend:
            cursor += 1
            guard let fb = window[p.b] else { return nil }
            let dst = scratch(like: fa.texture)
            blend.encode(nil, fa.texture, fb.texture, t: p.t, into: dst)
            return StreamFrame(texture: dst, outputIndex: cursor - 1, sourceIndex: nearest, backing: [])
        case .generated:
            guard let fb = window[p.b] else { cursor += 1; return nil }
            var batch: [(index: Int, t: Float)] = []
            while cursor < plan.endIndex, plan[cursor].kind == .generated, plan[cursor].a == p.a, plan[cursor].b == p.b {
                batch.append((cursor, plan[cursor].t))
                cursor += 1
            }
            try generate(batch, a: fa, b: fb, pa: p.a, pb: p.b)
            return ready.isEmpty ? nil : ready.removeFirst()
        }
    }

    private func generate(_ batch: [(index: Int, t: Float)], a fa: DecodedFrame, b fb: DecodedFrame, pa: Int, pb: Int) throws {
        let scene = sceneOf(pa)
        let (engine, route) = engine(forScene: scene)
        // Grain-aware: interpolate the clean picture; grain is put back afterwards from the nearest real frame.
        let ga = settings.grainAware ? clean(fa) : fa.texture
        let gb = settings.grainAware ? clean(fb) : fb.texture
        let tiles = ((ga.width + qc.tileSize - 1) / qc.tileSize, (ga.height + qc.tileSize - 1) / qc.tileSize)
        // Scenes the map isn't sure about (or that are hard) get two independent generations; keep the cleaner one.
        let doubleUp = settings.intelligence == .exhaustive && (route.map { $0.status == .uncertain || $0.pain > 0.04 } ?? true)

        var results: [InterpolationOutput]
        if let engine {
            let outs = batch.map { _ in scratch(like: ga) }
            results = try engine.interpolate(ga, gb, times: batch.map(\.t), into: outs, qcTiles: tiles)
        } else {
            results = batch.map { item in
                let o = scratch(like: ga)
                blend.encode(nil, ga, gb, t: item.t, into: o)
                return InterpolationOutput(texture: o, motionBad: nil)
            }
        }

        func score(_ tex: MTLTexture, _ motion: [Bool]?) -> (Float, [Bool]) {
            var (_, bad) = qc.score(a: ga, b: gb, mid: tex, sensitivity: settings.sensitivity)
            if let motion, motion.count == bad.count { bad = zip(bad, motion).map { $0 || $1 } }
            return (Float(bad.filter { $0 }.count) / Float(max(1, bad.count)), bad)
        }

        var finals: [(tex: MTLTexture, fraction: Float, action: QCEvent.Action)] = []
        for (k, item) in batch.enumerated() {
            var result = results[k].texture
            var action = QCEvent.Action.accepted
            guard settings.artifactRepair, engine != nil else { finals.append((result, 0, .accepted)); continue }
            var (fraction, bad) = score(result, results[k].motionBad)
            if (fraction > 0 || doubleUp), let repairEngine {
                let alt = scratch(like: ga)
                let r2 = try repairEngine.interpolate(ga, gb, times: [item.t], into: [alt], qcTiles: tiles)
                let s2 = score(alt, r2[0].motionBad)
                if s2.0 < fraction { result = alt; fraction = s2.0; bad = s2.1; action = .reRendered }
            }
            if fraction > 0.35 {
                result = (item.t < 0.5 ? ga : gb)
                action = .replaced
            } else if fraction > 0 {
                let fallback = scratch(like: ga)
                blend.encode(nil, ga, gb, t: item.t, into: fallback)
                let patched = scratch(like: ga)
                qc.patch(generated: result, fallback: fallback, bad: bad, into: patched)
                result = patched
                action = .patched
            }
            finals.append((result, fraction, action))
        }

        // Flicker check: steps between consecutive frames (real → generated… → real) should be even.
        if settings.flickerCheck, finals.count >= 2 {
            let r = GradeRenderer()
            var chain = [ga] + finals.map(\.tex) + [gb]
            var steps: [Float] = []
            for i in 0..<(chain.count - 1) { steps.append(r.blendErrors(chain[i], chain[i + 1], chain[i + 1], t: 0).motion) }
            let median = steps.sorted()[steps.count / 2]
            for k in finals.indices where median > 0.002 {
                // Generated frame k sits between steps k and k+1; a spike on both sides means it jumps out of line.
                if steps[k] > median * 2.2 && steps[k + 1] > median * 2.2 {
                    let fixed = scratch(like: ga)
                    blend.encode(nil, chain[k], chain[k + 2], t: 0.5, into: fixed)
                    finals[k].tex = fixed
                    finals[k].action = .patched
                    finals[k].fraction = max(finals[k].fraction, 0.01)
                    chain[k + 1] = fixed
                }
            }
        }

        for (k, item) in batch.enumerated() {
            var out = finals[k].tex
            if settings.grainAware {
                // Put grain back: real grain from the nearest frame, freshly offset so it never freezes.
                let near = item.t < 0.5 ? fa : fb
                let regrained = scratch(like: fa.texture)
                let cb = ctx.queue.makeCommandBuffer()!
                grain.regrain(cb, cleanMid: out, origNear: near.texture, cleanNear: clean(near), into: regrained, seed: item.index)
                cb.commit(); cb.waitUntilCompleted()
                out = regrained
            }
            if finals[k].fraction > 0 || finals[k].action != .accepted {
                events.append(QCEvent(outputIndex: item.index, sourceA: pa, t: item.t, badFraction: finals[k].fraction, action: finals[k].action))
            }
            ready.append(StreamFrame(texture: out, outputIndex: item.index, sourceIndex: item.t < 0.5 ? pa : pb, backing: []))
        }
    }

    func cancel() { source.cancel() }
}

/// "Scan & repair" preview: runs the interpolation plan at proxy resolution and reports every frame that
/// needed fixing, so you can review the trouble spots before the full-resolution export.
enum InterpolationScanner {
    static func scan(_ d: SourceDescriptor, color: SourceColor, analysis: AnalysisResult, settings: InterpolationSettings,
                     progress: @escaping (Double) -> Void) async throws -> [QCEvent] {
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen),
                                                  settings: settings, analysis: analysis)
        let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: settings,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1),
                                     proxyWidth: 960, sceneOf: { analysis.sceneIndex(for: $0) })
        var n = 0
        while try stream.next() != nil {
            try Task.checkCancellation()
            n += 1
            if n % 24 == 0 { progress(Double(n) / Double(plan.count)) }
        }
        return stream.events
    }
}
