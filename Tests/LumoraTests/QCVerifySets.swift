import XCTest
import Metal
@testable import Lumora

/// Independent verification sets for the interpolation artifact checker.
///
/// Every window here is NEW: none of them is in the committed benchmark manifest, so no design was trained, tuned or
/// scored on them. They come from the test part of the story (80-100% of the film time) on a different sampling grid
/// (center not a multiple of 3, at least 8 frames from any manifest window), plus real cuts the cut split did not use,
/// other positions inside the real fades, new fades and dissolves, heavier grain, and new synthetic clips (text at two
/// new speeds, 1-px lines, rotating stripes, a second fine grating). Besides the 30->60 and 15->60 rebuilds of the
/// benchmark, two new strides are scored: "20->60" (n-1, n+2 -> n, n+1 at t = 1/3, 2/3) and "12->60" (n-2, n+3 ->
/// n-1 ... n+2 at t = 0.2, 0.4, 0.6, 0.8, the time positions of a 24 -> 60 conversion).
///
/// Extra measurements: temporal error (the frame-to-frame change of the output against the true change, which
/// exposes flicker between consecutive generated frames) and seams (the step across a 64-px tile edge between a
/// switched and an untouched tile, against the true step there).
enum VerifySets {
    static var dir: URL { QCBench.root.appendingPathComponent("qc-verify", isDirectory: true) }
    static func refURL(_ s: String) -> URL { dir.appendingPathComponent("ref-\(s).json") }
    static let splits = ["vtest", "vtest4k", "vtest720", "vtestHDR", "vtestGrain", "vsynth", "vnearcut", "vcut", "vfade", "vtest2", "vcut2"]

    struct ModeSpec { var a: Int; var b: Int; var times: [Float]; var truths: [Int] }
    static let modeSpecs: [String: ModeSpec] = [
        "30->60": ModeSpec(a: -1, b: 1, times: [0.5], truths: [0]),
        "15->60": ModeSpec(a: -2, b: 2, times: [0.25, 0.5, 0.75], truths: [-1, 0, 1]),
        "20->60": ModeSpec(a: -1, b: 2, times: [1.0 / 3, 2.0 / 3], truths: [0, 1]),
        "12->60": ModeSpec(a: -2, b: 3, times: [0.2, 0.4, 0.6, 0.8], truths: [-1, 0, 1, 2]),
    ]

    static func modes(for split: String) -> [String] {
        if let e = QCBench.env["LUMORA_QC_VMODES"] { return e.split(separator: ",").map(String.init) }
        return ["vtest", "vtest2", "vtestHDR", "vsynth"].contains(split) ? ["30->60", "15->60", "20->60", "12->60"] : ["30->60", "15->60"]
    }

    /// The benchmark split whose settings (primary model, grain-aware) and held-frame scoring apply.
    static func baseSplit(_ s: String) -> String {
        switch s {
        case "vtestHDR": return "testHDR"
        case "vtestGrain": return "testGrain"
        case "vcut", "vcut2": return "cut"
        case "vfade": return "fade"
        default: return "test"
        }
    }

    static let heavyGrain = "noise=c0s=30:c0f=t:c1s=10:c1f=t:c2s=10:c2f=t:all_seed=%d"

    static let clips: [SyntheticClips] = [
        SyntheticClips(name: "v-textslow", motion: 36, graph: "credits text cropped with y=n*9: slow vertical scroll") { _ in
            ["-loop", "1", "-framerate", "60", "-i", SyntheticClips.textImage.path, "-vf", "crop=1920:1080:0:'n*9'," + SyntheticClips.tagNV12]
        },
        SyntheticClips(name: "v-textfast", motion: 128, graph: "credits text cropped with y=n*32: very fast vertical scroll") { _ in
            ["-loop", "1", "-framerate", "60", "-i", SyntheticClips.textImage.path, "-vf", "crop=1920:1080:0:'n*32'," + SyntheticClips.tagNV12]
        },
        SyntheticClips(name: "v-hlines", motion: 16, graph: "1-px near-horizontal lines every 23 px moving 4 px/frame") { _ in
            ["-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=60,format=gray,geq=lum='if(lt(mod(Y+0.1*X+1000-N*4,23),1),235,30)',format=rgb24," + SyntheticClips.tagNV12]
        },
        SyntheticClips(name: "v-rotstripes", motion: 16, graph: "9-px stripes rotating 0.004 rad/frame about the center") { _ in
            ["-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=60,format=gray,geq=lum='128+100*sin(2*PI*((X-960)*cos(N*0.004)+(Y-540)*sin(N*0.004))/9)',format=rgb24," + SyntheticClips.tagNV12]
        },
        SyntheticClips(name: "v-grating2", motion: 10, graph: "grating 7.3 x 6.1 px moving (2.1, -1.3) px/frame") { _ in
            ["-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=60,format=gray,geq=lum='128+90*sin(2*PI*(X+N*2.1)/7.3)*cos(2*PI*(Y-N*1.3)/6.1)',format=rgb24," + SyntheticClips.tagNV12]
        },
    ]

    static func windows(_ m: QCManifest) async throws -> [QCWindow] {
        let scan = try await QCBenchmarkTests.loadOrScan()
        let shots = ShotAnalysis(scan)
        let story = shots.creditsStart
        let used = m.windows.filter { $0.source.hasPrefix("bbb") }.map(\.center).sorted()
        func far(_ c: Int, _ d: Int) -> Bool {
            var lo = 0, hi = used.count
            while lo < hi { let mid = (lo + hi) / 2; if used[mid] < c - d { lo = mid + 1 } else { hi = mid } }
            return lo == used.count || used[lo] > c + d
        }
        let lo = Int(0.8 * Double(story)) + 8, hi = story - 8
        var byStratum: [String: [(Int, Float)]] = [:]
        let cuts = shots.cuts
        for c in lo..<hi where c % 3 != 0 && far(c, 8) {
            if cuts.contains(where: { $0 > c - 5 && $0 <= c + 5 }) { continue }
            if shots.inTransition(c, margin: 5) { continue }
            if scan.thumbMAD(c - 2, c + 2) < 0.0015 { continue }
            let mo = scan.windowMotion(c).p90
            byStratum[QCBench.stratum(mo), default: []].append((c, mo))
        }
        var rng = SplitMix(state: 0x5EED_2026_1112)
        var chosen: [Int] = []
        var picked: [String: [(Int, Float)]] = [:]
        var spare = 0
        for (st, _, _) in QCBench.strata.reversed() {
            var cands = byStratum[st] ?? []
            cands.shuffle(using: &rng)
            let want = 16 + spare
            var taken = 0
            for (c, mo) in cands where taken < want {
                if chosen.contains(where: { abs($0 - c) < 20 }) { continue }
                chosen.append(c); picked[st, default: []].append((c, mo)); taken += 1
            }
            spare = want - taken
        }
        var out: [QCWindow] = []
        func add(_ split: String, _ list: [(Int, Float, String)], variant: String = "sdr", source: String = "bbb1080") {
            for (i, p) in list.sorted(by: { $0.0 < $1.0 }).enumerated() {
                out.append(QCWindow(id: "\(split)-\(String(format: "%03d", i))", split: split, source: source, center: p.0,
                                    stratum: p.2, motion: p.1, variant: variant))
            }
        }
        func slice(_ r: Range<Int>) -> [(Int, Float, String)] {
            QCBench.strata.flatMap { st in (picked[st.0] ?? []).enumerated().filter { r.contains($0.offset) }.map { ($0.element.0, $0.element.1, st.0) } }
        }
        add("vtest", slice(0..<8))
        add("vtest4k", slice(0..<3), source: "bbb2160")
        add("vtest720", slice(3..<6), variant: "s720")
        add("vtestHDR", slice(8..<12), variant: "hdr")
        add("vtestGrain", slice(12..<16), variant: "grain")
        // A second fresh draw (own seed, none of the windows above), weighted to fast motion: scored only once, after
        // every fix made on the sets above.
        var rng2 = SplitMix(state: 0xF2E5_4002)
        var fresh: [(Int, Float, String)] = []
        for (st, want) in [("extreme", 12), ("high", 12), ("medium", 8), ("low", 4)] {
            var cands = byStratum[st] ?? []
            cands.shuffle(using: &rng2)
            var taken = 0
            for (c, mo) in cands where taken < want {
                if chosen.contains(where: { abs($0 - c) < 20 }) { continue }
                chosen.append(c); fresh.append((c, mo, st)); taken += 1
            }
        }
        add("vtest2", fresh)
        // Synthetic clips: 40 frames each, windows need center-2 ... center+3.
        for clip in clips {
            for (i, c) in [6, 13, 20, 27, 33].enumerated() {
                out.append(QCWindow(id: "vsynth-\(clip.name)-\(i)", split: "vsynth", source: "synth-\(clip.name)", center: c,
                                    stratum: clip.name, motion: clip.motion, variant: "sdr"))
            }
        }
        // Real cuts the cut split did not use (no other cut within 8 frames, not inside a fade); late story first.
        let cutSplit = Set(m.windows.filter { $0.split == "cut" }.map(\.center))
        let clean = cuts.enumerated().filter { i, c in
            c > 10 && c < story - 10 && (i == 0 || c - cuts[i - 1] > 8) && (i + 1 == cuts.count || cuts[i + 1] - c > 8)
                && !shots.inTransition(c, margin: 4) && !cutSplit.contains(c)
        }.map(\.1)
        let late = clean.filter { Double($0) >= 0.8 * Double(story) }, early = clean.filter { Double($0) < 0.8 * Double(story) }
        var cutPick = Array(late.prefix(16))
        if cutPick.count < 16, !early.isEmpty {
            let need = 16 - cutPick.count
            let step = max(1, early.count / need)
            cutPick += stride(from: 0, to: early.count, by: step).prefix(need).map { early[$0] }
        }
        cutPick.sort()
        for (i, c) in cutPick.enumerated() {
            out.append(QCWindow(id: "vcut-\(String(format: "%03d", i))", split: "vcut", source: "bbb1080", center: c, stratum: "cut",
                                motion: -1, variant: "sdr", note: "frame \(c) starts a new shot"))
        }
        // Fresh cuts for the final check: the next clean cuts none of the sets above uses.
        let usedCuts = Set(cutPick)
        let rest = (late + early.reversed()).filter { !usedCuts.contains($0) }
        for (i, c) in rest.prefix(16).sorted().enumerated() {
            out.append(QCWindow(id: "vcut2-\(String(format: "%03d", i))", split: "vcut2", source: "bbb1080", center: c, stratum: "cut",
                                motion: -1, variant: "sdr", note: "frame \(c) starts a new shot"))
        }
        // Near cuts: the whole window inside one shot, its last (or first) frame right next to the cut.
        for (i, c) in cutPick.prefix(8).enumerated() {
            out.append(QCWindow(id: "vnearcut-\(String(format: "%03d", 2 * i))", split: "vnearcut", source: "bbb1080", center: c - 4,
                                stratum: "before", motion: -1, variant: "sdr", note: "frames c-6 ... c-1 of cut \(c)"))
            out.append(QCWindow(id: "vnearcut-\(String(format: "%03d", 2 * i + 1))", split: "vnearcut", source: "bbb1080", center: c + 3,
                                stratum: "after", motion: -1, variant: "sdr", note: "frames c+1 ... c+6 of cut \(c)"))
        }
        // Fades: other positions inside the real transitions than the fade split, then new synthetic fades.
        let fadeSplit = m.windows.filter { $0.split == "fade" && $0.variant == "sdr" }.map(\.center)
        var fi = 0
        for r in shots.transitions {
            var c = r.lowerBound + 6
            while c + 3 <= r.upperBound && fi < 10 {
                if !fadeSplit.contains(where: { abs($0 - c) < 3 }) {
                    out.append(QCWindow(id: "vfade-\(String(format: "%03d", fi))", split: "vfade", source: "bbb1080", center: c, stratum: "real",
                                        motion: -1, variant: "sdr", note: "inside detected transition \(r.lowerBound)-\(r.upperBound)"))
                    fi += 1
                }
                c += 8
            }
        }
        let movers = out.filter { $0.split == "vtest" && $0.stratum != "low" }
        let synthFades: [(String, Float, Float, Bool)] = [   // stratum, alpha, step, partner is another window
            ("fadeIn", 0.95, -1.0 / 30, false), ("fadeIn", 0.8, -1.0 / 30, false), ("fadeIn", 0.6, -1.0 / 30, false),
            ("fadeIn", 0.4, -1.0 / 30, false), ("fadeInFast", 0.9, -1.0 / 10, false), ("fadeInFast", 0.5, -1.0 / 10, false),
            ("fadeOutFast", 0.5, 1.0 / 10, false), ("dissolveFast", 0.3, 1.0 / 15, true), ("dissolveFast", 0.6, 1.0 / 15, true),
        ]
        for (k, f) in synthFades.enumerated() where movers.count > 2 * k + 1 {
            let a = movers[k], b = movers[movers.count - 1 - k]
            out.append(QCWindow(id: "vfade-\(String(format: "%03d", fi))", split: "vfade", source: "bbb1080", center: a.center, stratum: f.0,
                                motion: a.motion, variant: "dissolve", note: "\(f.0) of \(a.id)\(f.3 ? " into \(b.id)" : "")",
                                partner: f.3 ? b.center : -1, alpha: f.1, alphaStep: f.2))
            fi += 1
        }
        return out
    }

    /// Caches every frame the verification windows need (center-2 ... center+3, partners too).
    static func ensureFrames(_ m: QCManifest, _ ws: [QCWindow]) async throws {
        var pad = m
        pad.windows = ws.filter { $0.source.hasPrefix("bbb") && $0.variant != "grain" }.flatMap { w -> [QCWindow] in
            var w1 = w
            w1.center += 1
            if let p = w.partner, p >= 0 { w1.partner = p + 1 }
            var w0 = w
            w0.variant = "sdr"
            w1.variant = "sdr"
            return [w0, w1]
        } + ws.filter { $0.variant == "grain" }.flatMap { w -> [QCWindow] in
            var a = w, b = w
            a.variant = "sdr"; b.variant = "sdr"; b.center += 1
            return [a, b]
        }
        try await QCBenchmarkTests.ensureFrames(pad)
        try SyntheticClips.renderText()
        for clip in clips { try clip.ensureCached() }
        for w in ws where w.variant == "grain" { try ensureHeavyGrain(w) }
    }

    /// Heavier film grain than the benchmark's grain split (about twice the strength), seeded per window.
    static func ensureHeavyGrain(_ w: QCWindow) throws {
        let range = (w.center - 2)...(w.center + 3)
        let keys = range.map { "\(w.id)_\($0)" }
        if keys.allSatisfy({ FrameCache.exists("bbb1080-grain", $0) }) { return }
        let tmpIn = dir.appendingPathComponent("tmp/\(w.id)-in.nv12"), tmpOut = dir.appendingPathComponent("tmp/\(w.id)-out.nv12")
        QCBench.ensureDir(tmpIn.deletingLastPathComponent())
        var raw = Data()
        for n in range {
            guard let f = FrameCache.load("bbb1080", "\(n)") else { throw LumoraError.decodeFailed("frame \(n) not cached") }
            raw += f.raw
        }
        try raw.write(to: tmpIn)
        try QCBench.ffmpegRun(["-f", "rawvideo", "-pix_fmt", "nv12", "-s", "1920x1080", "-r", "60", "-i", tmpIn.path,
                               "-vf", "format=yuv420p," + String(format: heavyGrain, 7000 + w.center % 100_000) + ",format=nv12",
                               "-f", "rawvideo", "-pix_fmt", "nv12", tmpOut.path])
        let d = try Data(contentsOf: tmpOut)
        let fsz = 1920 * 1080 * 3 / 2
        guard d.count == fsz * range.count else { throw LumoraError.unsupported("grain output \(d.count) bytes") }
        for (k, key) in keys.enumerated() {
            try FrameCache.save(NV12Frame(raw: d.subdata(in: (k * fsz)..<((k + 1) * fsz)), width: 1920, height: 1080)!, "bbb1080-grain", key)
        }
        try? FileManager.default.removeItem(at: tmpIn); try? FileManager.default.removeItem(at: tmpOut)
    }

    static func loadRefs(_ split: String) -> [String: RefFrame] {
        guard let d = try? Data(contentsOf: refURL(split)), let list = try? QCBenchmarkTests.decoder.decode([RefFrame].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }
}

// MARK: - Temporal and seam measurements

final class VerifyKernels {
    static let shared = VerifyKernels()
    let gpu = BenchGPU.shared
    private var psos: [String: MTLComputePipelineState] = [:]

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    constant float3 kL = float3(0.2126f, 0.7152f, 0.0722f);
    struct VP { int tile; int tilesX; int tilesY; int pad; };

    // Per 64-px tile: squared RGB error of the frame-to-frame change, (o1 - o0) - (t1 - t0). 8x8 pixels per thread.
    kernel void vTemporal(texture2d<float, access::read> o0 [[texture(0)]],
                          texture2d<float, access::read> o1 [[texture(1)]],
                          texture2d<float, access::read> t0 [[texture(2)]],
                          texture2d<float, access::read> t1 [[texture(3)]],
                          device atomic_float* out          [[buffer(0)]],
                          constant VP& p                    [[buffer(1)]],
                          uint2 gid                         [[thread_position_in_grid]]) {
        uint W = o0.get_width(), H = o0.get_height();
        uint2 o = gid * 8;
        if (o.x >= W || o.y >= H) return;
        float se = 0.0f;
        for (uint y = 0; y < 8; y++) for (uint x = 0; x < 8; x++) {
            uint2 q = o + uint2(x, y);
            if (q.x >= W || q.y >= H) continue;
            float3 d = (o1.read(q).rgb - o0.read(q).rgb) - (t1.read(q).rgb - t0.read(q).rgb);
            se += dot(d, d);
        }
        uint tx = min(o.x / uint(p.tile), uint(p.tilesX - 1)), ty = min(o.y / uint(p.tile), uint(p.tilesY - 1));
        atomic_fetch_add_explicit(&out[ty * uint(p.tilesX) + tx], se, memory_order_relaxed);
    }

    // Step across every 64-px tile edge against the true step there (luma, absolute). out[2 * tile + 0]: the edge to
    // the right of the tile, out[2 * tile + 1]: the edge below it.
    kernel void vSeam(texture2d<float, access::read> o [[texture(0)]],
                      texture2d<float, access::read> t [[texture(1)]],
                      device atomic_float* out         [[buffer(0)]],
                      constant VP& p                   [[buffer(1)]],
                      uint2 gid                        [[thread_position_in_grid]]) {
        uint W = o.get_width(), H = o.get_height();
        if (gid.x >= W || gid.y >= H) return;
        uint T = uint(p.tile);
        float lo = dot(o.read(gid).rgb, kL), lt = dot(t.read(gid).rgb, kL);
        if (gid.x > 0 && gid.x % T == 0) {
            uint2 q = gid - uint2(1, 0);
            float e = abs((lo - dot(o.read(q).rgb, kL)) - (lt - dot(t.read(q).rgb, kL)));
            uint tx = gid.x / T - 1, ty = min(gid.y / T, uint(p.tilesY - 1));
            atomic_fetch_add_explicit(&out[(ty * uint(p.tilesX) + tx) * 2], e, memory_order_relaxed);
        }
        if (gid.y > 0 && gid.y % T == 0) {
            uint2 q = gid - uint2(0, 1);
            float e = abs((lo - dot(o.read(q).rgb, kL)) - (lt - dot(t.read(q).rgb, kL)));
            uint ty = gid.y / T - 1, tx = min(gid.x / T, uint(p.tilesX - 1));
            atomic_fetch_add_explicit(&out[(ty * uint(p.tilesX) + tx) * 2 + 1], e, memory_order_relaxed);
        }
    }
    """

    private init() {
        let lib = try! gpu.ctx.device.makeLibrary(source: Self.source, options: nil)
        for n in ["vTemporal", "vSeam"] { psos[n] = try! gpu.ctx.device.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ name: String, w: Int, h: Int, _ setup: (MTLComputeCommandEncoder) -> Void) {
        let enc = cb.makeComputeCommandEncoder()!
        setup(enc)
        gpu.ctx.dispatch2D(enc, psos[name]!, width: w, height: h)
        enc.endEncoding()
    }

    /// PSNR of the frame-to-frame change against the true change, for several (o0, o1) pairs sharing one (t0, t1).
    func temporalPSNR(_ pairs: [(MTLTexture, MTLTexture)], t0: MTLTexture, t1: MTLTexture) -> [Double] {
        let g = TileGrid(t0)
        var vp = SIMD4<Int32>(Int32(g.tile), Int32(g.tilesX), Int32(g.tilesY), 0)
        let bufs = pairs.map { _ in gpu.zeroed(g.count * 4) }
        gpu.run { cb in
            for (k, (a, b)) in pairs.enumerated() {
                dispatch(cb, "vTemporal", w: (t0.width + 7) / 8, h: (t0.height + 7) / 8) { e in
                    e.setTexture(a, index: 0); e.setTexture(b, index: 1); e.setTexture(t0, index: 2); e.setTexture(t1, index: 3)
                    e.setBuffer(bufs[k], offset: 0, index: 0); e.setBytes(&vp, length: 16, index: 1)
                }
            }
        }
        let n = Double(t0.width * t0.height * 3)
        return bufs.map { b in
            let p = b.contents().bindMemory(to: Float.self, capacity: g.count)
            var s = 0.0
            for i in 0..<g.count { s += Double(p[i]) }
            return TileErr.psnr(s / n)
        }
    }

    /// Per-tile edge errors (right, below) of several outputs against one truth.
    func seams(_ outs: [MTLTexture], truth: MTLTexture) -> [[Float]] {
        let g = TileGrid(truth)
        var vp = SIMD4<Int32>(Int32(g.tile), Int32(g.tilesX), Int32(g.tilesY), 0)
        let bufs = outs.map { _ in gpu.zeroed(g.count * 8) }
        gpu.run { cb in
            for (k, o) in outs.enumerated() {
                dispatch(cb, "vSeam", w: truth.width, h: truth.height) { e in
                    e.setTexture(o, index: 0); e.setTexture(truth, index: 1)
                    e.setBuffer(bufs[k], offset: 0, index: 0); e.setBytes(&vp, length: 16, index: 1)
                }
            }
        }
        return bufs.map { b in Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: Float.self, capacity: g.count * 2), count: g.count * 2)) }
    }
}

// MARK: - Evaluation through the real FrameStream

struct VStep: Codable { var key: String; var mode: String; var tdRaw: Double; var tdPolicy: Double }

struct VSeamStats: Codable {
    var mixedEdges = 0           // tile edges between a switched and an untouched tile
    var seamEdges = 0            // ... whose step error is > 2 code values (8-bit) above raw's on average
    var policySum = 0.0, rawSum = 0.0, pixels = 0.0
    var worstExcess = 0.0        // worst mean excess step error on one edge, code values
}

struct VResult: Codable {
    var label: String
    var split: String
    var mode: String
    var settings: String
    var frames: [FrameEval] = []
    var steps: [VStep] = []
    var seam = VSeamStats()
    var msRaw = 0.0, msPolicy = 0.0
    var generated = 0
    var actions: [String: Int] = [:]
}

final class VerifyEvaluator {
    let gpu = BenchGPU.shared
    let provider: FrameProvider
    let refs: [String: RefFrame]
    let k = VerifyKernels.shared

    init(provider: FrameProvider, refs: [String: RefFrame]) { self.provider = provider; self.refs = refs }

    func run(split: String, windows: [QCWindow], mode: String, configs: [(String, InterpolationSettings)]) throws -> [VResult] {
        let spec = VerifySets.modeSpecs[mode]!
        let factor = spec.times.count + 1
        let base = VerifySets.baseSplit(split)
        var plan: [PlannedFrame] = []
        var sources: [(QCWindow, Int)] = []
        var info: [Int: (QCWindow, Int, Int)] = [:]
        for w in windows {
            let b0 = sources.count
            sources.append((w, w.center + spec.a)); sources.append((w, w.center + spec.b))
            var s = configs[0].1
            s.mode = .multiply(factor)
            let (p, _) = InterpolationPlanner.plan(sourceFrames: 2, sourceRate: (60 / factor, 1), settings: s, analysis: PolicyEvaluator.analysis())
            var ti = 0
            for f in p {
                if f.kind != .original { info[plan.count] = (w, ti, w.center + spec.truths[min(ti, spec.truths.count - 1)]); ti += 1 }
                plan.append(PlannedFrame(a: f.a + b0, b: f.b + b0, t: f.t, kind: f.kind))
            }
        }
        var results = configs.map { VResult(label: $0.0, split: split, mode: mode, settings: PolicyEvaluator.describe($0.1)) }
        var pool: [Int: MTLTexture] = [:]
        let first = try provider.frame(sources[0].0, sources[0].1)
        pool[0] = first
        let loaders: [() throws -> MTLTexture] = sources.indices.map { i in { pool[i]! } }
        let proxy = UniformBuilder.analysis(source: provider.color(windows[0]), gridW: 1, gridH: 1)
        var raw0 = configs[0].1
        raw0.artifactRepair = false
        var streams: [FrameStream] = []
        for cs in [raw0] + configs.map(\.1) {
            var s = cs
            s.mode = .multiply(factor)
            streams.append(try FrameStream(source: SequenceFrameSource(width: first.width, height: first.height, loaders: loaders),
                                           plan: plan[...], settings: s, proxyUniforms: proxy, sceneOf: { $0 / 2 }))
        }
        var times = [Double](repeating: 0, count: streams.count)
        var generated = 0
        var prev: [StreamFrame] = []
        var prevTruth: MTLTexture?
        var prevWindow = ""
        let grid = TileGrid(first)
        for i in plan.indices { try autoreleasepool {
            let need = max(plan[i].a, plan[i].b)
            for j in 0...need where pool[j] == nil { pool[j] = try provider.frame(sources[j].0, sources[j].1) }
            let keep = min(plan[i].a, plan[i].b)
            for j in pool.keys where j < keep - 1 { pool[j] = nil }
            var outs: [StreamFrame] = []
            for (s, st) in streams.enumerated() {
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard let f = try st.next() else { throw LumoraError.decodeFailed("stream \(s) ended early at \(i)") }
                times[s] += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                precondition(f.outputIndex == i, "stream \(s) out of step")
                outs.append(f)
            }
            let wid = sources[plan[i].a].0.id
            let truth: MTLTexture
            if let (w, _, idx) = info[i] { truth = try provider.frame(w, idx) } else { truth = pool[plan[i].a]! }
            if wid == prevWindow, let pt = prevTruth, prev.count == outs.count {
                let td = k.temporalPSNR(zip(prev, outs).map { ($0.texture, $1.texture) }, t0: pt, t1: truth)
                for c in configs.indices { results[c].steps.append(VStep(key: "\(wid)|\(mode)|\(i)", mode: mode, tdRaw: td[0], tdPolicy: td[c + 1])) }
            }
            prev = outs; prevTruth = truth; prevWindow = wid
            guard let (w, ti, _) = info[i] else { return }
            generated += 1
            let key = "\(w.id)|\(mode)|\(ti)"
            let ref = refs[key]
            let broken = ref.map(BrokenTile.flags)
            var pairs: [(MTLTexture, MTLTexture)] = [(outs[0].texture, truth)]
            for c in 1..<outs.count { pairs.append((outs[c].texture, truth)); pairs.append((outs[c].texture, outs[0].texture)) }
            let errs = gpu.tileErrors(pairs)
            let rawErr = errs[0]
            var heldInputs: [TileErr] = []
            if base == "cut" || base == "fade" {
                let A = pool[plan[i].a]!, B = pool[plan[i].b]!
                heldInputs = gpu.tileErrors(outs.flatMap { [($0.texture, A), ($0.texture, B)] })
            }
            let edges = k.seams(outs.map(\.texture), truth: truth)
            for c in 1..<outs.count {
                let e = errs[1 + (c - 1) * 2], d = errs[2 + (c - 1) * 2]
                var fe = FrameEval(key: key, mode: mode, stratum: w.stratum, psnrRaw: rawErr.psnr, psnrPolicy: e.psnr,
                                   ssimRaw: rawErr.ssim, ssimPolicy: e.ssim, tiles: e.px.count, broken: 0, changed: 0, brokenChanged: 0,
                                   brokenFixed: 0, harmful: 0, held: nil, datasetPrimaryPSNR: ref?.framePSNR[ref!.primary])
                var changed = [Bool](repeating: false, count: e.px.count)
                for t in 0..<e.px.count {
                    changed[t] = d.tilePSNR(t) < 70
                    let gain = e.tilePSNR(t) - rawErr.tilePSNR(t)
                    let isBroken = broken?[t] ?? false
                    if changed[t] { fe.changed += 1 }
                    if isBroken { fe.broken += 1 }
                    if changed[t] && isBroken { fe.brokenChanged += 1 }
                    if isBroken && gain >= 1 { fe.brokenFixed += 1 }
                    if changed[t] && gain < -0.5 { fe.harmful += 1 }
                }
                if !heldInputs.isEmpty { fe.held = max(heldInputs[c * 2].psnr, heldInputs[c * 2 + 1].psnr) > 60 }
                // Seams: only edges between a switched and an untouched tile, and only when the frame isn't all switched.
                let all = changed.allSatisfy { $0 }
                if !all {
                    for t in 0..<grid.count {
                        let tx = t % grid.tilesX, ty = t / grid.tilesX
                        for (dir, nb) in [(0, tx + 1 < grid.tilesX ? t + 1 : -1), (1, ty + 1 < grid.tilesY ? t + grid.tilesX : -1)] where nb >= 0 {
                            guard changed[t] != changed[nb] else { continue }
                            let len = Double(dir == 0 ? min(grid.tile, grid.height - ty * grid.tile) : min(grid.tile, grid.width - tx * grid.tile))
                            let ep = Double(edges[c][2 * t + dir]), er = Double(edges[0][2 * t + dir])
                            results[c - 1].seam.mixedEdges += 1
                            results[c - 1].seam.policySum += ep; results[c - 1].seam.rawSum += er; results[c - 1].seam.pixels += len
                            let excess = (ep - er) / len * 255
                            if excess > 2 { results[c - 1].seam.seamEdges += 1 }
                            results[c - 1].seam.worstExcess = max(results[c - 1].seam.worstExcess, excess)
                        }
                    }
                }
                results[c - 1].frames.append(fe)
            }
        } }
        for c in configs.indices {
            for ev in streams[c + 1].events { results[c].actions[ev.action.rawValue, default: 0] += 1 }
            results[c].generated = generated
            results[c].msRaw = times[0] / Double(max(1, generated))
            results[c].msPolicy = times[c + 1] / Double(max(1, generated))
        }
        streams.forEach { $0.cancel() }
        return results
    }

    static func row(_ r: VResult) -> String {
        let m = Metrics(r.frames)
        let td = r.steps.map { $0.tdPolicy - $0.tdRaw }
        let tdMean = td.isEmpty ? Double.nan : td.reduce(0, +) / Double(td.count)
        let tdDrop = td.isEmpty ? Double.nan : Double(td.filter { $0 < -0.1 }.count) / Double(td.count)
        let tdWorst = max(0, -(td.min() ?? 0))
        let s = r.seam
        let seamP = s.pixels > 0 ? s.policySum / s.pixels * 255 : .nan, seamR = s.pixels > 0 ? s.rawSum / s.pixels * 255 : .nan
        let held = m.heldFraction.map { fmt(100 * $0, 1) } ?? "-"
        let acts = r.actions.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "| \(r.split) | \(r.mode) | \(r.label) | \(m.frames) | \(fmt(m.psnrRaw, 2)) | \(fmt(m.psnrPolicy, 2)) | \(fmt(m.gainMean, 3)) | \(fmt(m.gainWorst10, 3)) | \(fmt(100 * m.fracDropOver0_1dB, 1)) | \(fmt(m.worstDropDB, 2)) | \(m.brokenTiles) | \(fmt(100 * m.recall, 1)) / \(fmt(100 * m.precision, 1)) / \(fmt(100 * m.fixedRecall, 1)) | \(held) | \(fmt(tdMean, 3)) / \(fmt(100 * tdDrop, 1)) / \(fmt(tdWorst, 2)) | \(s.mixedEdges) / \(s.seamEdges) / \(fmt(seamR, 2))->\(fmt(seamP, 2)) / \(fmt(s.worstExcess, 1)) | \(fmt(r.msRaw, 1)) / +\(fmt(r.msPolicy - r.msRaw, 1)) | \(acts) |"
    }

    static let header = """
    | split | mode | config | frames | raw PSNR | PSNR | gain | w10 | drop>0.1 % | max drop | broken | R / P / F % | held % | temporal gain / drop>0.1 % / max drop dB | mixed edges / seams / step err raw->policy / worst excess (8-bit codes) | ms raw / added (lockstep) | actions |
    |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
    """
}

final class QCVerifyTests: XCTestCase {
    override func setUpWithError() throws {
        guard QCBench.env["LUMORA_QC_VERIFY"] == "1" else { throw XCTSkip("QC verification: set LUMORA_QC_VERIFY=1") }
        try TestHardware.requireGPU()
        guard FileManager.default.fileExists(atPath: QCBench.film1080.path) else { throw XCTSkip("film not found") }
        QCBench.ensureDir(VerifySets.dir)
    }

    static func splits() -> [String] {
        QCBench.env["LUMORA_QC_SPLITS"].map { $0.split(separator: ",").map(String.init) } ?? VerifySets.splits
    }

    func test1_VerifyDataset() async throws {
        let (m, provider) = try await QCBenchmarkTests.prepare()
        let ws = try await VerifySets.windows(m)
        var counts: [String: Int] = [:]
        for w in ws { counts[w.split, default: 0] += 1 }
        QCBench.log("verify windows: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        try QCBenchmarkTests.encoder.encode(ws).write(to: VerifySets.dir.appendingPathComponent("windows.json"))
        try await VerifySets.ensureFrames(m, ws)
        let lab = TripletLab(provider: provider)
        for split in Self.splits() {
            let url = VerifySets.refURL(split)
            if FileManager.default.fileExists(atPath: url.path), QCBench.env["LUMORA_QC_REBUILD"] != "1" { continue }
            var refs: [RefFrame] = []
            for w in ws where w.split == split {
                var lw = w
                lw.split = split
                refs += try autoreleasepool { try lab.process(lw) }.refs
            }
            try QCBenchmarkTests.compact.encode(refs).write(to: url, options: .atomic)
            let broken = refs.reduce(0) { $0 + BrokenTile.flags($1).filter { $0 }.count }, total = refs.reduce(0) { $0 + $1.px.count }
            QCBench.log("verify refs \(split): \(refs.count) frames, \(broken) of \(total) tiles broken")
        }
    }

    func test2_VerifyEvaluate() async throws {
        let (m, provider) = try await QCBenchmarkTests.prepare()
        let ws = try await VerifySets.windows(m)
        try await VerifySets.ensureFrames(m, ws)
        let label = QCBench.env["LUMORA_QC_LABEL"] ?? "verify"
        let spec = (QCBench.env["LUMORA_QC_VCONFIGS"] ?? "s0,s0.5,s1,exh0.5").split(separator: ",").map(String.init)
        var rows: [String] = []
        let out = VerifySets.dir.appendingPathComponent("results", isDirectory: true)
        QCBench.ensureDir(out)
        for split in Self.splits() {
            var sw = ws.filter { $0.split == split }
            if let l = QCBench.env["LUMORA_QC_LIMIT"].flatMap(Int.init) { sw = Array(sw.prefix(l)) }
            guard !sw.isEmpty else { continue }
            let configs: [(String, InterpolationSettings)] = spec.map { c in
                var s = PolicyEvaluator.baseSettings(split: VerifySets.baseSplit(split))
                s.artifactRepair = true
                if c.hasPrefix("exh") { s.intelligence = .exhaustive; s.sensitivity = Float(c.dropFirst(3)) ?? 0.5 }
                else { s.intelligence = .eachFrame; s.sensitivity = Float(c.dropFirst(1)) ?? 0.5 }
                return ("\(label)-\(c)", s)
            }
            let refs = VerifySets.loadRefs(split)
            for mode in VerifySets.modes(for: split) {
                let started = Date()
                let res = try VerifyEvaluator(provider: provider, refs: refs).run(split: split, windows: sw, mode: mode, configs: configs)
                for r in res {
                    let name = "\(r.label)-\(split)-\(mode.replacingOccurrences(of: "->", with: "to")).json"
                    try QCBenchmarkTests.encoder.encode(r).write(to: out.appendingPathComponent(name))
                    rows.append(VerifyEvaluator.row(r))
                    QCBench.log("VROW " + VerifyEvaluator.row(r))
                }
                QCBench.log("verify \(split) \(mode): \(Int(Date().timeIntervalSince(started))) s")
            }
        }
        let table = VerifyEvaluator.header + "\n" + rows.joined(separator: "\n") + "\n"
        try table.write(to: out.appendingPathComponent("\(label).md"), atomically: true, encoding: .utf8)
        print(table)
    }
}
