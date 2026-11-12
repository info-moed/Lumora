import XCTest
import Metal
import CoreML
@testable import Lumora

/// Frame interpolation and Model Lab, end to end: the planner's frame math, FrameStream + QC on real decoded
/// frames, exports whose frame counts and timestamps are checked with ffprobe, the evaluator / benchmark /
/// external repair / motion tools, and (in the `testModelLab…` methods, which use the network) the real
/// RIFE 4.25 download → Core ML conversion → interpolation quality against the blend fallback.
@MainActor
final class CampaignInterpolationTests: XCTestCase {

    // MARK: - Helpers

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraInterp-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoraInterp-\(ProcessInfo.processInfo.processIdentifier)"))
        super.tearDown()
    }

    /// An id no model will ever have: forces the blend fallback even when Model Lab models are installed.
    static let noModel = "campaign-no-such-model"

    static func ffmpeg(_ args: [String]) throws {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        try EndToEndTests.sh(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    static func ffprobe(_ args: [String]) throws -> String {
        guard let fp = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        return try EndToEndTests.sh(fp, ["-v", "error"] + args)
    }

    /// Frame-level color tags (FFmpeg 9 writes the frames' tags, not -color_trc, into the file).
    static let tag709 = ",setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    static let tagPQ = ",setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"

    /// A panning crop of testsrc2: smooth, real motion everywhere (what flow models are built for).
    /// `rate` is the clip rate; `step` the pan in pixels per frame.
    static func makePan(_ name: String, rate: String, frames: Int, step: Int = 6, hdr: Bool = false,
                        size: (Int, Int) = (320, 180)) throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (w, h) = size
        // A 2x-size pattern: dense enough detail that every frame really moves (the evaluator ignores tiny motion).
        let graph = "testsrc2=s=\(w * 2)x\(h * 2):r=\(rate),crop=w=\(w):h=\(h):x='mod(n*\(step)\\,\(w))':y='mod(n*\(step / 2)\\,\(h))'"
            + (hdr ? ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv422p10le" + tagPQ : ",scale=out_color_matrix=bt709:out_range=tv,format=yuv422p10le" + tag709)
        var args = ["-f", "lavfi", "-i", graph, "-frames:v", "\(frames)", "-c:v", "prores_ks", "-profile:v", "3"]
        args += hdr ? ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
                    : ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        try ffmpeg(args + [url.path])
        return url
    }

    /// Every other frame of `truth` at half its rate: the frames an interpolator has to rebuild are known.
    static func evenFrames(of truth: URL, name: String, rate: String, hdr: Bool) throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var args = ["-i", truth.path, "-vf", "select='not(mod(n\\,2))',setpts=N/(\(rate))/TB" + (hdr ? tagPQ : tag709), "-r", rate,
                    "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]
        args += hdr ? ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
                    : ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        try ffmpeg(args + [url.path])
        return url
    }

    static func inspect(_ url: URL) async throws -> (SourceDescriptor, SourceColor) {
        let (d, colors) = try await SourceInspector.inspect(url)
        return (d, try XCTUnwrap(colors.first, "no color interpretation for \(url.lastPathComponent)"))
    }

    /// One scene, no cuts, no fades, no repeats, for `n` frames (so the planner's output is fully predictable).
    static func plainAnalysis(_ n: Int, cuts: [Int] = [], transitions: [TransitionSpan] = [], dupes: Set<Int> = [],
                              motion: [Float] = []) -> AnalysisResult {
        let starts = [0] + cuts
        let scenes = starts.enumerated().map { k, s in
            SceneStats(start: s, end: k + 1 < starts.count ? starts[k + 1] : n, keyStops: 0, p005: -6, p50: 0, p995: 3,
                       skinFraction: 0, avgChroma: 0)
        }
        return AnalysisResult(frameCount: n, scenes: scenes, transitions: transitions, cutFrames: Set(starts),
                              duplicateFrames: dupes, globalKey: 0, globalP005: -6, globalP995: 3, skinFraction: 0,
                              avgChroma: 0, globalHistogram: [], motion: motion)
    }

    static func blendSettings(_ mode: InterpolationSettings.Mode) -> InterpolationSettings {
        var s = InterpolationSettings()
        s.mode = mode
        s.primaryModelID = noModel
        s.repairModelID = nil
        return s
    }

    /// Decodes every frame of a file (via the app's own frame source).
    static func decodeAll(_ d: SourceDescriptor) async throws -> [MTLTexture] {
        let src = try await d.makeFrameSource()
        try src.start(at: 0, count: nil)
        var out: [MTLTexture] = []
        while let f = try src.nextFrame() { out.append(copy(f.texture)) }
        src.cancel()
        return out
    }

    /// Private copy of a texture (decoded textures can be recycled by the decoder).
    static func copy(_ t: MTLTexture) -> MTLTexture {
        let ctx = MetalContext.shared
        let dst = ctx.makeTexture(width: t.width, height: t.height, format: t.pixelFormat)
        let cb = ctx.queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: t, to: dst)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    /// PSNR (dB, PQ domain) of `b` against `a`, both in source color `color`.
    static func psnr(_ a: MTLTexture, _ b: MTLTexture, color: SourceColor) -> Float {
        let r = GradeRenderer()
        return r.compare(r.comparable(a, color: color, width: 320), r.comparable(b, color: color, width: 320)).psnr
    }

    /// Rebuilds the odd (removed) frames of `truth` from `half` with a 2x FrameStream and returns mean PSNR.
    static func rebuildPSNR(half: SourceDescriptor, color: SourceColor, truth: [MTLTexture],
                            settings: InterpolationSettings) async throws -> (psnr: Float, frames: Int, events: [QCEvent]) {
        var s = settings
        s.mode = .multiply(2)
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: half.frameCount, sourceRate: (half.fpsNum, half.fpsDen),
                                                  settings: s, analysis: plainAnalysis(half.frameCount))
        let stream = try FrameStream(source: try await half.makeFrameSource(), plan: plan[...], settings: s,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        var sum: Float = 0, n = 0, total = 0
        while let f = try stream.next() {
            if plan[f.outputIndex].kind == .generated, f.outputIndex < truth.count {
                sum += psnr(truth[f.outputIndex], f.texture, color: color); n += 1
            }
            total += 1
        }
        return (n == 0 ? 0 : sum / Float(n), total, stream.events)
    }

    /// A flat gray field whose level rises by `step` (8-bit codes) every frame, with a sine track. Any output
    /// frame's expected level follows from its timestamp alone, so frame order, timing and blend weights are checked.
    static func makeRamp(_ name: String, rate: String, fps: Double, frames: Int, step: Int = 6) throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let dur = String(format: "%.4f", Double(frames) / fps)
        try ffmpeg(["-f", "lavfi", "-i", "color=c=black:s=320x180:r=\(rate),format=gray,geq=lum='24+\(step)*N'",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(dur)",
                    "-map", "0:v", "-map", "1:a", "-frames:v", "\(frames)",
                    "-vf", "scale=out_color_matrix=bt2020:out_range=tv,format=yuv422p10le" + tagPQ,
                    "-c:v", "prores_ks", "-profile:v", "3", "-color_primaries", "bt2020", "-color_trc", "smpte2084",
                    "-colorspace", "bt2020nc", "-c:a", "aac", "-b:a", "96k", url.path])
        return url
    }

    /// Mean luma of every frame (0...1), in presentation order.
    static func frameLumas(_ url: URL) throws -> [Double] {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-i", url.path, "-map", "0:v:0", "-vf",
                       "format=gray16le,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").compactMap { l -> Double? in
            guard let r = l.range(of: "YAVG=") else { return nil }
            return Double(l[r.upperBound...].trimmingCharacters(in: .whitespaces)).map { $0 / 65535 }
        }
    }

    struct Timing {
        var timeBase: (num: Int, den: Int)
        var rate: (num: Int, den: Int)
        var pts: [Int]
        var hasAudio: Bool
    }

    static func rational(_ s: String) -> (Int, Int) {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (p.first ?? 0, 1)
    }

    static func timing(_ url: URL) throws -> Timing {
        let s = try ffprobe(["-select_streams", "v:0", "-show_entries", "stream=time_base,r_frame_rate", "-of", "default=nw=1", url.path])
        var kv: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        let pts = try ffprobe(["-select_streams", "v:0", "-show_entries", "packet=pts", "-of", "csv=p=0", url.path])
            .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        let audio = try ffprobe(["-select_streams", "a", "-show_entries", "stream=codec_type", "-of", "csv=p=0", url.path])
        return Timing(timeBase: rational(kv["time_base"] ?? ""), rate: rational(kv["r_frame_rate"] ?? ""), pts: pts,
                      hasAudio: audio.contains("audio"))
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
    static func reduced(_ r: (Int, Int)) -> (Int, Int) { let g = max(1, gcd(r.0, r.1)); return (r.0 / g, r.1 / g) }

    /// Expected output length for `n` source frames: every output instant from the first to the last source frame.
    static func expectedCount(_ n: Int, src: (Int, Int), gen: (Int, Int)) -> Int {
        (n - 1) * gen.0 * src.1 / (gen.1 * src.0) + 1
    }

    static func keepLook(_ color: SourceColor, scenes: Int) -> PresetCandidate {
        PresetCandidate(name: "Keep original look", look: .original, color: color, params: Look.original.params,
                        sceneExposures: Array(repeating: 0, count: scenes), reason: "test")
    }

    static func proresJob(_ d: SourceDescriptor, color: SourceColor, analysis: AnalysisResult,
                          settings: InterpolationSettings, out: String, delivery: DeliveryFormat = .sdr) -> ExportJob {
        var job = ExportJob(descriptor: d, preset: keepLook(color, scenes: analysis.scenes.count), analysis: analysis,
                            delivery: delivery, codec: .prores422HQ, outputURL: work.appendingPathComponent(out))
        job.bitDepth = 10
        job.chroma = .c422
        job.interpolation = settings
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    func waitFor(_ what: String, timeout: TimeInterval = 120, _ done: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static var installedModels: [InterpolationModelSpec] { InterpolationModelSpec.all().filter(\.isInstalled) }

    // MARK: - Planner (pure frame math)

    func testPlannerOffIsIdentity() {
        let (plan, rate) = InterpolationPlanner.plan(sourceFrames: 30, sourceRate: (24000, 1001), settings: InterpolationSettings(),
                                                     analysis: Self.plainAnalysis(30))
        XCTAssertEqual(plan.count, 30)
        XCTAssertEqual(rate.num, 24000); XCTAssertEqual(rate.den, 1001)
        XCTAssertTrue(plan.enumerated().allSatisfy { $0.element == PlannedFrame(a: $0.offset, b: $0.offset, t: 0, kind: .original) })
    }

    /// For every mode: exact count, exact output rate, and each output frame sits at exactly k * src/gen source frames
    /// (originals where that is a whole frame, generated frames with the right pair and weight elsewhere).
    func testPlannerModesExactCountsRatesAndPositions() {
        let n = 48
        let cases: [(InterpolationSettings.Mode, (Int, Int), gen: (Int, Int), out: (Int, Int))] = [
            (.multiply(2), (24000, 1001), (48000, 1001), (48000, 1001)),
            (.multiply(3), (24000, 1001), (72000, 1001), (72000, 1001)),
            (.multiply(4), (24000, 1001), (96000, 1001), (96000, 1001)),
            (.multiply(8), (24000, 1001), (192000, 1001), (192000, 1001)),
            (.multiply(3), (25, 1), (75, 1), (75, 1)),
            (.targetFPS(num: 60, den: 1), (24000, 1001), (60, 1), (60, 1)),
            (.targetFPS(num: 60000, den: 1001), (24000, 1001), (60000, 1001), (60000, 1001)),
            (.targetFPS(num: 60, den: 1), (25, 1), (60, 1), (60, 1)),
            (.targetFPS(num: 60000, den: 1001), (25, 1), (60000, 1001), (60000, 1001)),
            (.slowMotion(factor: 2), (24000, 1001), (48000, 1001), (24000, 1001)),
            (.slowMotion(factor: 4), (24000, 1001), (96000, 1001), (24000, 1001)),
            (.slowMotion(factor: 4), (25, 1), (100, 1), (25, 1)),
        ]
        for (mode, src, gen, out) in cases {
            let s = Self.blendSettings(mode)
            let (plan, rate) = InterpolationPlanner.plan(sourceFrames: n, sourceRate: src, settings: s, analysis: Self.plainAnalysis(n))
            let label = "\(mode) from \(src.0)/\(src.1)"
            XCTAssertEqual(plan.count, Self.expectedCount(n, src: src, gen: gen), "count, \(label)")
            XCTAssertEqual(rate.num, out.0, "rate, \(label)"); XCTAssertEqual(rate.den, out.1, "rate, \(label)")
            for (k, p) in plan.enumerated() {
                // Exact source position of output frame k: k * (gen.den * src.num) / (gen.num * src.den).
                let num = k * gen.1 * src.0, den = gen.0 * src.1
                let a = num / den, rem = num % den
                if rem == 0 {
                    XCTAssertEqual(p.kind, .original, "frame \(k) lands exactly on source frame \(a), \(label)")
                    XCTAssertEqual(p.a, a, "frame \(k), \(label)"); XCTAssertEqual(p.t, 0)
                } else {
                    XCTAssertEqual(p.kind, .generated, "frame \(k), \(label)")
                    XCTAssertEqual(p.a, a, "frame \(k), \(label)"); XCTAssertEqual(p.b, a + 1, "frame \(k), \(label)")
                    XCTAssertEqual(Double(p.t), Double(rem) / Double(den), accuracy: 1e-5, "frame \(k), \(label)")
                }
            }
        }
    }

    func testPlannerNeverInterpolatesAcrossACut() {
        let n = 48
        let a = Self.plainAnalysis(n, cuts: [24])
        for mode: InterpolationSettings.Mode in [.multiply(2), .multiply(4), .targetFPS(num: 60000, den: 1001), .slowMotion(factor: 4)] {
            let (plan, _) = InterpolationPlanner.plan(sourceFrames: n, sourceRate: (24000, 1001), settings: Self.blendSettings(mode), analysis: a)
            for p in plan where p.kind == .generated || p.kind == .transitionBlend {
                XCTAssertFalse(p.a < 24 && p.b >= 24, "\(mode): \(p) mixes the two shots")
            }
            let holds = plan.filter { $0.kind == .holdAcrossCut }
            XCTAssertFalse(holds.isEmpty, "\(mode): the gap over the cut should be held")
            XCTAssertTrue(holds.allSatisfy { $0.a == $0.b && ($0.a == 23 || $0.a == 24) && $0.t == 0 }, "\(mode): \(holds)")
        }
    }

    func testPlannerBlendsThroughFades() {
        let n = 48
        let a = Self.plainAnalysis(n, transitions: [TransitionSpan(start: 30, end: 40, kind: .fadeOut)])
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: n, sourceRate: (24, 1), settings: Self.blendSettings(.multiply(2)), analysis: a)
        for p in plan where p.kind != .original {
            let inFade = (30..<40).contains(p.a) || (30..<40).contains(p.b)
            XCTAssertEqual(p.kind, inFade ? .transitionBlend : .generated, "\(p)")
        }
        XCTAssertEqual(plan.filter { $0.kind == .transitionBlend }.count, 11)   // gaps 29-30 … 39-40
    }

    func testPlannerSmoothsAnimationOnTwos() {
        let n = 24
        let dupes = Set(stride(from: 1, to: n, by: 2))       // every odd frame repeats the one before it
        // A new shot starting on an (odd) frame flagged as a repeat: a cut frame is never skipped.
        let a = Self.plainAnalysis(n, cuts: [13], dupes: dupes)
        var s = Self.blendSettings(.multiply(2))
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: n, sourceRate: (24, 1), settings: s, analysis: a)
        XCTAssertEqual(plan.count, 47)
        // Generated frames always go between two different drawings (and never from a repeat).
        for p in plan where p.kind == .generated {
            XCTAssertFalse(a.duplicateFrames.contains(p.a) && !a.cutFrames.contains(p.a), "\(p) starts on a repeated frame")
            XCTAssertFalse(a.duplicateFrames.contains(p.b) && !a.cutFrames.contains(p.b), "\(p) ends on a repeated frame")
            XCTAssertEqual(p.b - p.a, p.a == 13 ? 1 : 2, "\(p)")
        }
        XCTAssertTrue(plan.contains(PlannedFrame(a: 13, b: 13, t: 0, kind: .original)), "the cut frame must be shown")
        XCTAssertTrue(plan.contains { $0.kind == .holdAcrossCut }, "the 12→13 gap crosses the cut")
        // The repeat at source frame 1 is replaced by real motion, halfway between drawings 0 and 2.
        XCTAssertEqual(plan[2], PlannedFrame(a: 0, b: 2, t: 0.5, kind: .generated))
        s.smoothDuplicates = false
        let (plain, _) = InterpolationPlanner.plan(sourceFrames: n, sourceRate: (24, 1), settings: s, analysis: a)
        XCTAssertEqual(plain[2], PlannedFrame(a: 1, b: 1, t: 0, kind: .original))
        XCTAssertEqual(plain.count, 47)
    }

    // MARK: - FrameStream on real decoded frames

    func testFrameStreamKeepsOriginalsAndBlendsExactly() async throws {
        try TestHardware.requireGPU()
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        XCTAssertEqual(d.frameCount, 13)
        let src = try await Self.decodeAll(d)
        XCTAssertEqual(src.count, 13)
        let s = Self.blendSettings(.multiply(4))
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s,
                                                  analysis: Self.plainAnalysis(d.frameCount))
        let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: s,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        let blend = BlendInterpolator()
        let ref = MetalContext.shared.makeTexture(width: src[0].width, height: src[0].height, format: src[0].pixelFormat)
        var k = 0
        while let f = try stream.next() {
            XCTAssertEqual(f.outputIndex, k)
            let p = plan[k]
            XCTAssertEqual(f.sourceIndex, p.t < 0.5 ? p.a : p.b)
            if p.kind == .original {
                XCTAssertGreaterThan(Self.psnr(src[p.a], f.texture, color: color), 90, "original \(p.a) was altered")
            } else {
                blend.encode(nil, src[p.a], src[p.b], t: p.t, into: ref)
                XCTAssertGreaterThan(Self.psnr(ref, f.texture, color: color), 60, "frame \(k) isn't the blend at t=\(p.t)")
                XCTAssertLessThan(Self.psnr(src[p.a], f.texture, color: color), 45, "frame \(k) is just a copy")
            }
            k += 1
        }
        XCTAssertEqual(k, plan.count)
        XCTAssertEqual(k, 49)
        XCTAssertTrue(stream.events.isEmpty, "the blend fallback has nothing to repair")
    }

    /// Every intelligence level, with no model available (blend fallback), finishes with every planned frame.
    func testIntelligenceLevelsWithoutModelFinish() async throws {
        try TestHardware.requireGPU()
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        for level in MotionIntelligence.allCases {
            for grain in [false, true] {
                var s = Self.blendSettings(.multiply(3))
                s.intelligence = level
                s.grainAware = grain
                s.repairModelID = "film"            // listed but not installed: must be ignored cleanly
                s.routes = [0: SceneRoute(scene: 0, model: Self.noModel, runnerUp: nil, confidence: 0.5, status: .uncertain,
                                          trials: 4, motion: 0.02, pain: 0.1, advantage: 0)]
                let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s,
                                                          analysis: Self.plainAnalysis(d.frameCount))
                let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: s,
                                             proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
                var idx: [Int] = []
                while let f = try stream.next() { idx.append(f.outputIndex) }
                XCTAssertEqual(idx, Array(0..<plan.count), "\(level), grain-aware \(grain)")
                XCTAssertTrue(stream.events.isEmpty, "\(level): no model ran, so nothing should be reported as repaired")
            }
        }
    }

    func testRealCutIsHeldNotMorphed() async throws {
        try TestHardware.requireGPU()
        let url = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        let (d, color) = try await Self.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        XCTAssertTrue(a.cutFrames.contains(24), "cut not found: \(a.cutFrames.sorted())")
        let s = Self.blendSettings(.multiply(2))
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s, analysis: a)
        XCTAssertEqual(plan[47].kind, .holdAcrossCut)
        let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[44..<50], settings: s,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1),
                                     sceneOf: { a.sceneIndex(for: $0) })
        var out: [Int: MTLTexture] = [:]
        while let f = try stream.next() { out[f.outputIndex] = Self.copy(f.texture) }
        XCTAssertEqual(out.keys.sorted(), Array(44..<50))
        let srcFrames = try await Self.decodeAll(d)
        let held = try XCTUnwrap(out[47])
        let hold = plan[47]
        XCTAssertGreaterThan(Self.psnr(srcFrames[hold.a], held, color: color), 90, "the frame over the cut must be a real frame")
        XCTAssertLessThan(Self.psnr(srcFrames[hold.a == 24 ? 23 : 24], held, color: color), 30)
    }

    func testRealFadeIsBlended() async throws {
        try TestHardware.requireGPU()
        let url = Self.work.appendingPathComponent("fade.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=2,fade=t=out:st=0.5:d=1,format=yuv422p10le" + Self.tag709,
                             "-c:v", "prores_ks", "-profile:v", "3", "-color_primaries", "bt709", "-color_trc", "bt709",
                             "-colorspace", "bt709", url.path])
        }
        let (d, color) = try await Self.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        XCTAssertFalse(a.transitions.isEmpty, "the 1 s fade to black wasn't detected")
        let s = Self.blendSettings(.multiply(2))
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s, analysis: a)
        let blends = plan.filter { $0.kind == .transitionBlend }
        XCTAssertFalse(blends.isEmpty)
        let src = try await Self.decodeAll(d)
        let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: s,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
        let ref = MetalContext.shared.makeTexture(width: src[0].width, height: src[0].height, format: src[0].pixelFormat)
        var n = 0
        while let f = try stream.next() {
            let p = plan[f.outputIndex]
            if p.kind == .transitionBlend {
                BlendInterpolator().encode(nil, src[p.a], src[p.b], t: p.t, into: ref)
                XCTAssertGreaterThan(Self.psnr(ref, f.texture, color: color), 60, "fade frame \(f.outputIndex)")
            }
            n += 1
        }
        XCTAssertEqual(n, plan.count)
    }

    func testAnimationOnTwosIsSmoothedEndToEnd() async throws {
        try TestHardware.requireGPU()
        let url = Self.work.appendingPathComponent("twos.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            // 12 drawings per second shown on twos at 24 fps.
            try Self.ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=12,crop=w=320:h=180:x='n*12':y='n*6',fps=24,format=yuv422p10le" + Self.tag709,
                             "-frames:v", "24", "-c:v", "prores_ks", "-profile:v", "3", "-color_primaries", "bt709",
                             "-color_trc", "bt709", "-colorspace", "bt709", url.path])
        }
        let (d, color) = try await Self.inspect(url)
        XCTAssertEqual(d.frameCount, 24)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let odd = Set(stride(from: 1, to: 24, by: 2))
        XCTAssertTrue(odd.isSubset(of: a.duplicateFrames), "repeats not detected: \(a.duplicateFrames.sorted())")
        func run(_ smooth: Bool) async throws -> [MTLTexture] {
            var s = Self.blendSettings(.multiply(2))
            s.smoothDuplicates = smooth
            let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s, analysis: a)
            let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: s,
                                         proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
            var out: [MTLTexture] = []
            while let f = try stream.next() { out.append(Self.copy(f.texture)) }
            XCTAssertEqual(out.count, plan.count)
            return out
        }
        func frozenSteps(_ frames: [MTLTexture]) -> [Int] {
            (1..<frames.count).filter { Self.psnr(frames[$0 - 1], frames[$0], color: color) > 80 }
        }
        let smooth = try await run(true)
        // Only the tail after the last drawing (source frames 22–23) may stand still.
        XCTAssertTrue(frozenSteps(smooth).allSatisfy { $0 >= 45 }, "frozen steps with smoothing: \(frozenSteps(smooth))")
        let plain = try await run(false)
        XCTAssertGreaterThan(frozenSteps(plain).count, 15, "without smoothing, repeated drawings stay frozen")
    }

    // MARK: - QC

    func testQCScoresBrokenFramesAndPatchesOnlyBadTiles() async throws {
        try TestHardware.requireGPU()
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        let src = try await Self.decodeAll(d)
        let qc = InterpolationQC()
        let clean = qc.score(a: src[4], b: src[6], mid: src[5], sensitivity: 0.5)
        XCTAssertLessThan(clean.fraction, 0.1, "a real in-between frame should pass")
        // A frame from further along the pan has structure the neighbors don't have in many places.
        let far = qc.score(a: src[4], b: src[6], mid: src[12], sensitivity: 0.5)
        XCTAssertGreaterThan(far.fraction, clean.fraction + 0.2)
        XCTAssertEqual(far.bad.count, 5 * 3)    // 64-px tiles over 320x180
        let strict = qc.score(a: src[4], b: src[6], mid: src[12], sensitivity: 1).fraction
        XCTAssertGreaterThanOrEqual(strict, far.fraction)
        _ = color

        let ctx = MetalContext.shared
        func texture(_ value: (Int, Int) -> Float) -> MTLTexture {
            let t = ctx.makeTexture(width: 320, height: 180, format: .rgba32Float, storage: .shared)
            var px = [Float](repeating: 1, count: 320 * 180 * 4)
            for y in 0..<180 { for x in 0..<320 { let v = value(x, y); for c in 0..<3 { px[(y * 320 + x) * 4 + c] = v } } }
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 320, 180), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 320 * 16) }
            return t
        }
        func solid(_ v: Float) -> MTLTexture { texture { _, _ in v } }
        // Garbage (a 1-pixel checkerboard, the kind of tearing a broken warp makes) fails almost everywhere.
        let garbage = qc.score(a: src[4], b: src[6], mid: texture { x, y in (x + y) % 2 == 0 ? 0 : 1 }, sensitivity: 0.5)
        XCTAssertGreaterThan(garbage.fraction, 0.6)

        // Patch: tile (0,0) bad → its 3x3 neighbourhood takes the fallback; far tiles keep the generated frame.
        let gen = solid(0), fallback = solid(1), dst = solid(0.5)
        var bad = [Bool](repeating: false, count: 15); bad[0] = true
        qc.patch(generated: gen, fallback: fallback, bad: bad, into: dst)
        var px = [Float](repeating: 0, count: 4)
        func at(_ x: Int, _ y: Int) -> Float {
            px.withUnsafeMutableBytes { dst.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0) }
            return px[0]
        }
        XCTAssertEqual(at(10, 10), 1, accuracy: 0.01, "inside the bad tile → fallback")
        XCTAssertEqual(at(310, 170), 0, accuracy: 0.01, "far from it → generated frame untouched")
    }

    // MARK: - Export: frame counts, timestamps, pixels, audio

    /// Every mode, exported through the real engine (ProRes): ffprobe frame count and every PTS exact, the output rate
    /// right, audio kept (or dropped for slow motion), and every frame's level what its timestamp implies.
    func testExportEveryModeExactFramesTimestampsAndLevels() async throws {
        try TestHardware.requireProRes()
        let ramps: [(url: URL, src: (Int, Int), n: Int)] = [
            (try Self.makeRamp("ramp23976.mov", rate: "24000/1001", fps: 24000.0 / 1001, frames: 20), (24000, 1001), 20),
            (try Self.makeRamp("ramp25.mov", rate: "25", fps: 25, frames: 20), (25, 1), 20),
        ]
        // The level each source frame comes out at (HDR10 "keep original look": PQ in, PQ out, no interpolation).
        var srcLumas: [Int: [Double]] = [:]
        for (i, r) in ramps.enumerated() {
            XCTAssertEqual(try Self.frameLumas(r.url).count, r.n)
            let (d, color) = try await Self.inspect(r.url)
            XCTAssertEqual(color.transfer, .pq)
            let plain = try await ExportEngine().run(Self.proresJob(d, color: color, analysis: Self.plainAnalysis(r.n),
                                                                    settings: Self.blendSettings(.off), out: "ramp-off-\(i).mov",
                                                                    delivery: .hdr10)) { _, _ in }
            let l = try Self.frameLumas(plain)
            XCTAssertEqual(l.count, r.n)
            XCTAssertEqual(l, l.sorted(), "the ramp must stay a ramp")
            srcLumas[i] = l
        }
        let cases: [(Int, InterpolationSettings.Mode, gen: (Int, Int))] = [
            (0, .multiply(2), (48000, 1001)), (0, .multiply(3), (72000, 1001)), (0, .multiply(4), (96000, 1001)),
            (0, .multiply(8), (192000, 1001)),
            (0, .targetFPS(num: 60, den: 1), (60, 1)), (0, .targetFPS(num: 60000, den: 1001), (60000, 1001)),
            (1, .targetFPS(num: 60, den: 1), (60, 1)), (1, .targetFPS(num: 60000, den: 1001), (60000, 1001)),
            (0, .slowMotion(factor: 2), (48000, 1001)), (0, .slowMotion(factor: 4), (96000, 1001)),
        ]
        for (ri, mode, gen) in cases {
            let r = ramps[ri]
            let label = "\(mode) from \(r.src.0)/\(r.src.1)"
            let (d, color) = try await Self.inspect(r.url)
            XCTAssertEqual(d.frameCount, r.n)
            XCTAssertTrue(d.hasAudio)
            var slow = false
            if case .slowMotion = mode { slow = true }
            let outRate = slow ? r.src : gen
            let job = Self.proresJob(d, color: color, analysis: Self.plainAnalysis(r.n), settings: Self.blendSettings(mode),
                                     out: "mode-\(ri)-\(String(describing: mode).filter { $0.isLetter || $0.isNumber }).mov",
                                     delivery: .hdr10)
            let engine = ExportEngine()
            let url = try await engine.run(job) { _, _ in }
            XCTAssertTrue(engine.qcEvents.isEmpty)
            let expected = Self.expectedCount(r.n, src: r.src, gen: gen)
            let tm = try Self.timing(url)
            XCTAssertEqual(tm.pts.count, expected, "frame count, \(label)")
            XCTAssertEqual(try EndToEndTests.probe(url).frames, expected, "decoded frames, \(label)")
            let rr = Self.reduced(tm.rate), er = Self.reduced(outRate)
            XCTAssertTrue(rr == er, "r_frame_rate \(tm.rate) ≠ \(outRate), \(label)")
            // pts_i * tb == i / rate, exactly.
            let wrong = tm.pts.enumerated().filter { i, p in p * tm.timeBase.num * outRate.0 != i * outRate.1 * tm.timeBase.den }
            XCTAssertTrue(wrong.isEmpty, "\(wrong.count) timestamps off, first \(wrong.prefix(3)) (tb \(tm.timeBase)), \(label)")
            XCTAssertEqual(tm.hasAudio, !slow, "audio \(slow ? "must be dropped" : "must be kept"), \(label)")
            // Picture: the level of output frame k is the source ramp sampled at k's exact source position.
            let lum = try Self.frameLumas(url)
            XCTAssertEqual(lum.count, expected)
            let y = srcLumas[ri]!
            let perOut = Double(r.src.0 * gen.1) / Double(r.src.1 * gen.0)     // source frames per output frame
            var worst = (k: -1, err: 0.0, tol: 0.0)
            for (k, v) in lum.enumerated() {
                let num = k * gen.1 * r.src.0, den = gen.0 * r.src.1
                let a = num / den, t = Double(num % den) / Double(den)
                let e = a + 1 < y.count ? y[a] + t * (y[a + 1] - y[a]) : y[a]
                // A third of one output frame's change: a frame shown at the wrong time or with the wrong weight fails.
                let tol = max(0.001, 0.3 * perOut * abs(y[min(a + 1, y.count - 1)] - y[max(0, min(a, y.count - 2))]))
                if abs(v - e) / tol > worst.err / max(worst.tol, 1e-9) { worst = (k, abs(v - e), tol) }
            }
            XCTAssertLessThan(worst.err, worst.tol, "frame \(worst.k) level off by \(worst.err) (tolerance \(worst.tol)), \(label)")
        }
    }

    func testExportExhaustiveIntelligenceWithoutModelFinishes() async throws {
        try TestHardware.requireProRes()
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        var s = Self.blendSettings(.multiply(2))
        s.intelligence = .exhaustive
        s.grainAware = true
        let out = try await ExportEngine().run(Self.proresJob(d, color: color, analysis: Self.plainAnalysis(13), settings: s, out: "exhaustive.mov")) { _, _ in }
        XCTAssertEqual(try EndToEndTests.probe(out).frames, 25)
    }

    func testAV2AbsenceIsReportedCleanly() async throws {
        try XCTSkipIf(Codec.av2.available, "avmenc is installed on this Mac")
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        var job = Self.proresJob(d, color: color, analysis: Self.plainAnalysis(13), settings: Self.blendSettings(.slowMotion(factor: 2)), out: "x.obu")
        job.codec = .av2; job.chroma = .c420
        let msg = try XCTUnwrap(ExportEngine.validate(job))
        XCTAssertTrue(msg.contains("avm") && msg.contains("isn't installed"), msg)
        do { _ = try await ExportEngine().run(job) { _, _ in }; XCTFail("AV2 export without avmenc should fail") } catch {
            XCTAssertEqual(error.localizedDescription, msg)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.outputURL.path))
    }

    // MARK: - App model: scan, trial, motion map cache

    func loadedModel() async throws -> AppModel {
        try TestHardware.requireGPU()
        let model = AppModel()
        model.open(try EndToEndTests.makeClip("sdr.mp4", hdr: false))
        try await waitFor("presets", timeout: 90) { !model.presets.isEmpty || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.analysis)
        return model
    }

    func testScanInterpolationOnAppModel() async throws {
        let model = try await loadedModel()
        model.interpolation = Self.blendSettings(.multiply(2))
        model.qcEvents = [QCEvent(outputIndex: 99, sourceA: 0, t: 0.5, badFraction: 1, action: .replaced)]   // stale
        model.scanInterpolation()
        XCTAssertEqual(model.status, "Scanning interpolation for artifacts")
        try await waitFor("scan") { model.progress == nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.qcEvents.isEmpty, "stale events must be replaced by the scan's result")
        XCTAssertEqual(model.status, "No interpolation problems found.")
    }

    func testHotspotsAndRunTrialOnAppModel() async throws {
        let model = try await loadedModel()
        let a = try XCTUnwrap(model.analysis)
        let spots = model.hotspots
        XCTAssertEqual(spots.count, a.scenes.filter { $0.end - $0.start >= 24 }.count)
        XCTAssertEqual(spots.map(\.motion), spots.map(\.motion).sorted(by: >))
        let h = try XCTUnwrap(spots.first)
        model.interpolation = Self.blendSettings(.off)       // a trial still needs something to interpolate: 2x
        model.runTrial(h)
        XCTAssertTrue(model.trialBusy)
        try await waitFor("trial") { !model.trialBusy }
        XCTAssertNil(model.errorMessage)
        let trial = try XCTUnwrap(model.trial)
        XCTAssertEqual(trial.hotspot, h)
        XCTAssertEqual(trial.outputFps, 48, accuracy: 0.01)
        XCTAssertEqual(trial.model, "Blend (no model installed)")
        XCTAssertEqual(trial.interpolated.count, trial.original.count)
        XCTAssertEqual(trial.generatedMask.count, trial.interpolated.count)
        let len = h.end - h.start
        XCTAssertTrue((2 * len - 1)...(2 * len) ~= trial.interpolated.count, "\(trial.interpolated.count) frames for a \(len)-frame scene")
        XCTAssertGreaterThanOrEqual(trial.generatedMask.filter { $0 }.count, len - 2)
        XCTAssertTrue(trial.verdict.hasPrefix("All "), trial.verdict)
        XCTAssertEqual(trial.interpolated.first?.width, 640)
    }

    func testMotionHotspotsRanking() {
        var a = Self.plainAnalysis(120, cuts: [30, 40, 80])
        a.motion = (0..<120).map { i in i < 30 ? 0.01 : (i < 40 ? 0.5 : (i < 80 ? 0.03 : 0.02)) }
        let spots = MotionScan.hotspots(a, fps: 24)
        // Scene 1 (10 frames) is too short to judge, however busy.
        XCTAssertEqual(spots.map(\.scene), [2, 3, 0])
        XCTAssertEqual(spots[0].start, 40); XCTAssertEqual(spots[0].end, 80)
        XCTAssertEqual(spots[0].seconds, 40.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(spots[0].label, "00:01  scene 3")
        XCTAssertEqual(MotionScan.hotspots(a, fps: 24, count: 1).count, 1)
    }

    func testMotionMapSaveLoadAndAppReuse() async throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/MotionMaps")
        let routes = [
            SceneRoute(scene: 0, model: "rife-4.25-flow", runnerUp: "rife-4.25", confidence: 0.99, status: .confident, trials: 6,
                       motion: 0.02, pain: 0.01, advantage: 0.004),
            SceneRoute(scene: 1, model: "rife-4.25", runnerUp: nil, confidence: 1, status: .skipped, trials: 0, motion: 0, pain: 0, advantage: 0),
            SceneRoute(scene: 2, model: "rife-4.25", runnerUp: "rife-4.25-flow", confidence: 0.7, status: .uncertain, trials: 12,
                       motion: 0.05, pain: 0.2, advantage: 0.001),
        ]
        let key = "campaign-\(UUID().uuidString)"
        let map = MotionMap(sourceKey: key, created: Date(), mode: .perScene, confidenceTarget: 0.97, routes: routes)
        XCTAssertEqual(map.confidentShare, 0.5, accuracy: 1e-9)
        XCTAssertEqual(map.hardest.map(\.scene), [2, 0])
        map.save()
        defer { try? FileManager.default.removeItem(at: folder.appendingPathComponent(key + ".json")) }
        let back = try XCTUnwrap(MotionMap.load(key))
        XCTAssertEqual(back.routes, routes)
        XCTAssertEqual(back.mode, .perScene)
        XCTAssertNil(MotionMap.load("campaign-missing-\(UUID().uuidString)"))

        // The app reuses a saved map for the same file and applies its routes (skipped scenes excluded).
        let model = try await loadedModel()
        let d = try XCTUnwrap(model.descriptor)
        let fileKey = MotionMap.key(for: d)
        let fileMapURL = folder.appendingPathComponent(fileKey + ".json")
        let hadUserMap = FileManager.default.fileExists(atPath: fileMapURL.path)
        let saved = hadUserMap ? try Data(contentsOf: fileMapURL) : nil
        defer {
            if let saved { try? saved.write(to: fileMapURL) } else { try? FileManager.default.removeItem(at: fileMapURL) }
        }
        MotionMap(sourceKey: fileKey, created: Date(), mode: .perScene, confidenceTarget: 0.99, routes: routes).save()
        model.interpolation.intelligence = .perScene
        model.interpolation.confidence = 0.97
        model.buildMotionMap()
        XCTAssertEqual(model.status, "Motion map reused (3 scenes)")
        XCTAssertEqual(model.motionMap?.routes, routes)
        XCTAssertEqual(Set(model.interpolation.routes.keys), [0, 2])
        XCTAssertEqual(model.interpolation.routes[0]?.model, "rife-4.25-flow")
    }

    func testMotionRouterWithoutModelsReportsCleanly() async throws {
        try XCTSkipIf(!Self.installedModels.isEmpty, "models are installed (covered by testModelLab4)")
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        let reporter = ProgressReporter(task: TaskCenter.shared.begin("router test"))
        do {
            _ = try await MotionRouter.build(d, color: color, analysis: Self.plainAnalysis(13), settings: InterpolationSettings(),
                                             kind: .realLife, progress: reporter)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Install interpolation models in Model Lab first.")
        }
    }

    // MARK: - Evaluator, benchmark, external repair

    /// truth48: real 48 fps motion; half24: its even frames (the "original"); then four 48 fps versions of half24.
    func evaluationSet() async throws -> (truth: URL, half: URL, versions: [String: URL]) {
        let truth = try Self.makePan("truth48.mov", rate: "48", frames: 49, step: 6)
        let half = try Self.evenFrames(of: truth, name: "half24.mov", rate: "24", hdr: false)
        var v: [String: URL] = ["truth": truth]
        // Exact 50/50 cross-fades: Lumora's own 2x export with the blend fallback. (FFmpeg's minterpolate "blend"
        // weights its frames unevenly, so it isn't a clean test of cross-fade detection.)
        let blend = Self.work.appendingPathComponent("blend48.mov")
        if !FileManager.default.fileExists(atPath: blend.path) {
            let (d, c) = try await Self.inspect(half)
            _ = try await ExportEngine().run(Self.proresJob(d, color: c, analysis: Self.plainAnalysis(d.frameCount),
                                                            settings: Self.blendSettings(.multiply(2)), out: "blend48.mov")) { _, _ in }
        }
        v["blend"] = blend
        for (name, filter) in [("dup", "fps=48"), ("mci", "minterpolate=fps=48:mi_mode=mci:mc_mode=aobmc:me_mode=bidir")] {
            let u = Self.work.appendingPathComponent("\(name)48.mov")
            if !FileManager.default.fileExists(atPath: u.path) {
                try Self.ffmpeg(["-i", half.path, "-vf", filter + Self.tag709, "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", u.path])
            }
            v[name] = u
        }
        return (truth, half, v)
    }

    func testEvaluatorGradesInterpolatedFilesAgainstOriginal() async throws {
        try TestHardware.requireGPU()
        let set = try await evaluationSet()
        let (o, oc) = try await Self.inspect(set.half)
        XCTAssertEqual(o.frameCount, 25)
        var reports: [String: InterpolationEvaluator.Report] = [:]
        for (name, u) in set.versions {
            let (b, bc) = try await Self.inspect(u)
            var last = 0.0
            let r = try await InterpolationEvaluator.evaluate(original: o, originalColor: oc, analysis: nil, interpolated: b,
                                                              interpolatedColor: bc, fullScan: true) { last = $0 }
            XCTAssertEqual(last, 1, accuracy: 1e-9, "\(name): progress should end at 1")
            XCTAssertEqual(r.rateRatio, 2, accuracy: 0.01, name)
            XCTAssertEqual(r.offsetSeconds, 0, accuracy: 0.5 / 48, name)
            XCTAssertGreaterThan(r.generatedChecked, 15, name)
            XCTAssertGreaterThan(r.originalsPSNR, 40, "\(name): the original frames survive")
            XCTAssertFalse(r.toneMatched, "\(name): same grade")
            XCTAssertTrue((0...100).contains(r.score))
            reports[name] = r
        }
        let dup = try XCTUnwrap(reports["dup"]), blend = try XCTUnwrap(reports["blend"]), truth = try XCTUnwrap(reports["truth"])
        XCTAssertGreaterThan(dup.duplicateRate, 0.8, "frame repeats must be called copies")
        XCTAssertGreaterThan(blend.ghostingRate, 0.8, "cross-fades must be called ghosting")
        XCTAssertLessThan(truth.duplicateRate + truth.ghostingRate, 0.1, "real motion isn't a copy or a fade")
        XCTAssertGreaterThan(truth.score, dup.score)
        XCTAssertGreaterThan(truth.score, blend.score)
        XCTAssertTrue(dup.flagged.allSatisfy { $0.outputIndex % 2 == 1 }, "only generated (odd) frames can be flagged")
    }

    func testEvaluatorFindsTimeOffset() async throws {
        try TestHardware.requireGPU()
        let set = try await evaluationSet()
        let late = Self.work.appendingPathComponent("truth48-late.mov")
        if !FileManager.default.fileExists(atPath: late.path) {
            // Starts 4 output frames (2 original frames) into the film.
            try Self.ffmpeg(["-i", set.truth.path, "-vf", "trim=start_frame=4,setpts=PTS-STARTPTS" + Self.tag709, "-c:v", "prores_ks", "-profile:v", "3",
                             "-pix_fmt", "yuv422p10le", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", late.path])
        }
        let (o, oc) = try await Self.inspect(set.half)
        let (b, bc) = try await Self.inspect(late)
        let r = try await InterpolationEvaluator.evaluate(original: o, originalColor: oc, analysis: nil, interpolated: b,
                                                          interpolatedColor: bc) { _ in }
        XCTAssertEqual(r.offsetSeconds, -4.0 / 48, accuracy: 0.5 / 48)
        XCTAssertGreaterThan(r.originalsPSNR, 40)
    }

    func testBenchmarkRemovesRealFrames() async throws {
        try TestHardware.requireGPU()
        let set = try await evaluationSet()
        let (o, oc) = try await Self.inspect(set.half)
        var last = 0.0
        let bm = try await InterpolationEvaluator.benchmark(original: o, color: oc, analysis: Self.plainAnalysis(o.frameCount)) { last = $0 }
        XCTAssertEqual(last, 1, accuracy: 1e-9)
        XCTAssertEqual(bm.samples, 21)       // frames 2…22 (of 25) qualify: away from the ends, no cut
        let blend = try XCTUnwrap(bm.scores.first { $0.name == "Blend" })
        XCTAssertGreaterThan(blend.psnr, 15); XCTAssertLessThan(blend.psnr, 60)
        XCTAssertTrue((0...1).contains(blend.ssim))
        XCTAssertTrue([0, 0.25, 0.5, 0.75, 1].contains(bm.recommendedSensitivity))
        if Self.installedModels.isEmpty {
            XCTAssertEqual(bm.scores.count, 1)
            XCTAssertNil(bm.recommendedModel)
            XCTAssertTrue(bm.summary.contains("Install an interpolation model"))
        } else {
            let best = try XCTUnwrap(bm.scores.first { $0.name != "Blend" })
            XCTAssertEqual(bm.recommendedModel, best.name)
            XCTAssertGreaterThan(best.psnr, blend.psnr, "\(best.name) should rebuild removed frames better than a cross-fade")
        }
        // Too short to benchmark.
        let short = try Self.makePan("pan8.mov", rate: "24", frames: 8)
        let (sd, sc) = try await Self.inspect(short)
        do { _ = try await InterpolationEvaluator.benchmark(original: sd, color: sc, analysis: Self.plainAnalysis(8)) { _ in }; XCTFail("expected an error") } catch {
            XCTAssertEqual(error.localizedDescription, "The clip is too short to benchmark.")
        }
    }

    func testExternalRepairPlanFindsOriginalFrames() {
        let p = ExternalRepairPlan(flagged: [], originalFps: 24000.0 / 1001, interpolatedFps: 60000.0 / 1001, offsetSeconds: 0)
        XCTAssertEqual((0..<21).filter(p.isOriginal), [0, 5, 10, 15, 20])
        let q = ExternalRepairPlan(flagged: [], originalFps: 24, interpolatedFps: 48, offsetSeconds: 1.0 / 48)
        XCTAssertEqual((0..<8).filter(q.isOriginal), [1, 3, 5, 7])
    }

    /// Repeats (fake interpolation) in a 48 fps file are rebuilt from the file's own original frames and get closer
    /// to the real motion; every other frame passes through untouched.
    func testPatchedFrameSourceRebuildsFlaggedFrames() async throws {
        try TestHardware.requireGPU()
        let set = try await evaluationSet()
        let (b, bc) = try await Self.inspect(try XCTUnwrap(set.versions["dup"]))
        let (t, _) = try await Self.inspect(set.truth)
        let dupFrames = try await Self.decodeAll(b)
        let truth = try await Self.decodeAll(t)
        let flagged = Set(stride(from: 1, to: 47, by: 2))
        let plan = ExternalRepairPlan(flagged: flagged, originalFps: 24, interpolatedFps: 48, offsetSeconds: 0)
        let src = PatchedFrameSource(base: try await b.makeFrameSource(), plan: plan,
                                     proxyUniforms: UniformBuilder.analysis(source: bc, gridW: 1, gridH: 1))
        XCTAssertEqual(src.frameCount, b.frameCount)
        try src.start(at: 0, count: nil)
        var j = 0, gainDB: [Float] = []
        while let f = try src.nextFrame() {
            XCTAssertEqual(f.index, j)
            if flagged.contains(j) {
                let before = Self.psnr(truth[j], dupFrames[j], color: bc), after = Self.psnr(truth[j], f.texture, color: bc)
                gainDB.append(after - before)
            } else {
                XCTAssertGreaterThan(Self.psnr(dupFrames[j], f.texture, color: bc), 90, "frame \(j) should pass through")
            }
            j += 1
        }
        XCTAssertEqual(j, b.frameCount)
        XCTAssertEqual(src.rebuilt, flagged.count)
        let mean = gainDB.reduce(0, +) / Float(max(1, gainDB.count))
        XCTAssertGreaterThan(mean, 1, "rebuilt frames should be closer to the real motion than the repeats (gain \(mean) dB)")
        // Starting mid-file still finds the original before the first frame.
        try src.start(at: 9, count: 3)
        var got: [Int] = []
        while let f = try src.nextFrame() { got.append(f.index) }
        XCTAssertEqual(got, [9, 10, 11])
    }

    func testRepairExternalOnAppModel() async throws {
        try TestHardware.requireProRes()
        let set = try await evaluationSet()
        // Its own copy, because the repaired file is written next to the interpolated one.
        let dir = Self.work.appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dupURL = dir.appendingPathComponent("dup48.mov")
        try FileManager.default.copyItem(at: try XCTUnwrap(set.versions["dup"]), to: dupURL)
        let (o, oc) = try await Self.inspect(set.half)
        let (b, bc) = try await Self.inspect(dupURL)
        let model = AppModel()
        model.compare.colorA = oc
        model.codec = .prores422HQ
        model.bitDepth = 10
        model.repairExternal(original: o, interpolated: b, interpolatedColor: bc, report: nil)
        try await waitFor("repair", timeout: 180) { model.status.hasPrefix("Saved") || model.status.hasPrefix("No problem") || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.status.hasPrefix("Saved dup48.repaired.mkv with "), model.status)
        let out = dir.appendingPathComponent("dup48.repaired.mkv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let p = try EndToEndTests.probe(out)
        XCTAssertEqual(p.codec, "prores")
        XCTAssertEqual(p.frames, b.frameCount)
        // The repaired file is closer to the true 48 fps motion than the repeats were.
        let (t, _) = try await Self.inspect(set.truth)
        let (r, rc) = try await Self.inspect(out)
        let truth = try await Self.decodeAll(t), before = try await Self.decodeAll(b), after = try await Self.decodeAll(r)
        let odd = Array(stride(from: 1, to: 47, by: 2))
        let pb = odd.map { Self.psnr(truth[$0], before[$0], color: bc) }.reduce(0, +) / Float(odd.count)
        let pa = odd.map { Self.psnr(truth[$0], after[$0], color: rc) }.reduce(0, +) / Float(odd.count)
        XCTAssertGreaterThan(pa, pb + 1, "repair should improve the in-between frames (\(pb) → \(pa) dB)")
        // The file's original frames pass through (only a ProRes re-encode).
        XCTAssertEqual(bc.transfer, .bt1886, "interpolated file read as \(bc.name)")
        let even = Array(stride(from: 0, to: 48, by: 2))
        let kept = even.map { Self.psnr(before[$0], after[$0], color: rc) }.min() ?? 0
        XCTAssertGreaterThan(kept, 45, "original frames were altered by the repair export")
    }

    // MARK: - Model Lab (network; installs into ~/Library/Application Support/Lumora — the app's intended state)

    func skipModelLabUnlessWanted() throws {
        if ProcessInfo.processInfo.environment["LUMORA_SKIP_MODEL_LAB"] == "1" { throw XCTSkip("LUMORA_SKIP_MODEL_LAB=1") }
    }

    var rife425: RIFERelease {
        get throws { try XCTUnwrap(ModelLab.shared.catalog.first { $0.id == "4.25" }, "RIFE 4.25 missing from rife_catalog.json") }
    }

    func testModelLab1_PrepareEnvironment() async throws {
        try skipModelLabUnlessWanted()
        let lab = ModelLab.shared
        do {
            try await lab.prepareEnvironment()
        } catch {
            XCTFail("prepareEnvironment failed: \(error.localizedDescription) (pip/git output is in ~/Library/Logs/Lumora)")
            throw error
        }
        XCTAssertTrue(lab.environmentReady)
        let py = ModelLab.lab.appendingPathComponent("venv/bin/python")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: py.path))
        // The interpreter really has the converter's dependencies.
        let out = try EndToEndTests.sh(py.path, ["-I", "-c", "import torch, coremltools, numpy; print(torch.__version__, coremltools.__version__)"])
        XCTAssertFalse(out.isEmpty)
        // Practical-RIFE is checked out at the pinned commit.
        let head = try EndToEndTests.sh("/usr/bin/git", ["-C", ModelLab.lab.appendingPathComponent("Practical-RIFE").path, "rev-parse", "HEAD"])
        XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), ModelLab.practicalRIFECommit)
    }

    func testModelLab2_DownloadRIFE425MatchesPinnedChecksum() async throws {
        try skipModelLabUnlessWanted()
        let lab = ModelLab.shared
        let r = try rife425
        let pinned = try XCTUnwrap(r.sha256, "RIFE 4.25 has no pinned checksum")
        try await lab.download(r)
        let zip = lab.zipURL(r)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        let digest = try ModelLab.sha256(of: zip)
        XCTAssertEqual(digest, pinned.lowercased(), "downloaded zip doesn't match the pinned SHA-256")
        let rec = try XCTUnwrap(lab.provenance(r))
        XCTAssertEqual(rec.sha256, digest)
        XCTAssertTrue(rec.verified)
        // A file that isn't the release is refused by Import, and the good zip stays in place.
        let bogus = Self.work.appendingPathComponent("bogus.zip")
        try Data("not a model".utf8).write(to: bogus)
        XCTAssertThrowsError(try lab.importZip(bogus, for: r))
        XCTAssertEqual(try ModelLab.sha256(of: zip), digest)
        // A release without a direct URL reports that cleanly instead of trying to download.
        if let manual = lab.catalog.first(where: { $0.url == nil }) {
            do { try await lab.download(manual); XCTFail("expected an error for \(manual.id)") } catch {
                XCTAssertTrue(error.localizedDescription.contains("No direct download"), error.localizedDescription)
            }
        }
    }

    func testModelLab3_ConvertRIFE425ImageAndFlow() async throws {
        try skipModelLabUnlessWanted()
        let lab = ModelLab.shared
        let r = try rife425
        guard lab.environmentReady else { throw XCTSkip("converter environment not prepared (testModelLab1 failed or was skipped)") }
        guard FileManager.default.fileExists(atPath: lab.zipURL(r).path) else { throw XCTSkip("RIFE 4.25 not downloaded (testModelLab2)") }
        let started = Date()
        do {
            try await lab.convert(r)
        } catch {
            XCTFail("convert failed: \(error.localizedDescription) (converter output is in ~/Library/Logs/Lumora)")
            throw error
        }
        XCTAssertEqual(lab.status[r.id], .converted)
        // No compiled model from an earlier conversion may survive (it would run instead of the new one).
        for stem in [r.fileStem, "\(r.fileStem)-Flow"] {
            let compiled = ModelLab.root.appendingPathComponent("\(stem).mlmodelc")
            if let made = try? compiled.resourceValues(forKeys: [.creationDateKey]).creationDate {
                XCTAssertGreaterThanOrEqual(made, started, "\(stem).mlmodelc predates this conversion")
            }
        }
        let image = ModelLab.root.appendingPathComponent("\(r.fileStem).mlpackage")
        let flow = ModelLab.root.appendingPathComponent("\(r.fileStem)-Flow.mlpackage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flow.path))
        let specs = InterpolationModelSpec.all()
        let img = try XCTUnwrap(specs.first { $0.id == r.imageModelID })
        let fl = try XCTUnwrap(specs.first { $0.id == r.flowModelID })
        XCTAssertTrue(img.isInstalled); XCTAssertTrue(fl.isInstalled)
        XCTAssertFalse(img.isFlow); XCTAssertTrue(fl.isFlow)
        // Both load in Core ML and expose the inputs/outputs Lumora feeds and reads.
        for spec in [img, fl] {
            let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: .testSDR, gridW: 1, gridH: 1))
            XCTAssertEqual(e.spec.id, spec.id)
        }
        XCTAssertNotNil(lab.bestModel(for: .realLife))
    }

    /// The converted RIFE 4.25 models, used through the app's own paths, rebuild removed real frames better than
    /// the blend fallback: image model on SDR, HDR flow model on a 10-bit PQ source, both at 320x180 and 1280x720.
    func testModelLab4_ConvertedRIFEBeatsBlend() async throws {
        try skipModelLabUnlessWanted()
        try TestHardware.requireGPU()
        let specs = InterpolationModelSpec.all()
        guard let img = specs.first(where: { $0.id == "rife-4.25" && $0.isInstalled }),
              let flow = specs.first(where: { $0.id == "rife-4.25-flow" && $0.isInstalled }) else {
            throw XCTSkip("RIFE 4.25 isn't converted (testModelLab3)")
        }
        XCTAssertEqual(img.padMultiple, 64, "5-block RIFE 4.25 needs inputs divisible by 64")
        var blend = InterpolationSettings()
        blend.primaryModelID = Self.noModel
        blend.repairModelID = nil
        blend.artifactRepair = false
        for (hdr, spec, size) in [(false, img, (320, 180)), (true, flow, (320, 180)), (false, img, (1280, 720)), (true, flow, (1280, 720))] {
            let label = "\(spec.id) \(hdr ? "HDR10 10-bit" : "SDR") \(size.0)x\(size.1)"
            let frames = size.0 > 320 ? 9 : 33
            let truthURL = try Self.makePan("ml-truth-\(hdr)-\(size.0).mov", rate: "48", frames: frames, step: size.0 / 53, hdr: hdr, size: size)
            let halfURL = try Self.evenFrames(of: truthURL, name: "ml-half-\(hdr)-\(size.0).mov", rate: "24", hdr: hdr)
            let (t, _) = try await Self.inspect(truthURL)
            let (h, hc) = try await Self.inspect(halfURL)
            XCTAssertEqual(hc.transfer, hdr ? .pq : .bt1886, label)
            let truth = try await Self.decodeAll(t)
            var model = blend
            model.primaryModelID = spec.id
            let b = try await Self.rebuildPSNR(half: h, color: hc, truth: truth, settings: blend)
            let m = try await Self.rebuildPSNR(half: h, color: hc, truth: truth, settings: model)
            XCTAssertEqual(m.frames, 2 * h.frameCount - 1, label)
            XCTAssertEqual(b.frames, m.frames, label)
            XCTAssertGreaterThan(m.psnr, b.psnr + 3, "\(label): model \(m.psnr) dB vs blend \(b.psnr) dB on the removed frames")
            // With artifact checks and repair on, it must still beat the blend clearly.
            model.artifactRepair = true
            let q = try await Self.rebuildPSNR(half: h, color: hc, truth: truth, settings: model)
            XCTAssertGreaterThan(q.psnr, b.psnr + 2, "\(label): with QC \(q.psnr) dB (\(q.events.count) repairs) vs blend \(b.psnr) dB")
            print("MODEL-LAB \(label): blend \(b.psnr) dB, model \(m.psnr) dB, model+QC \(q.psnr) dB, repairs \(q.events.count)")
            if spec.isFlow {
                // The forward/backward motion check must not condemn correct motion (it flagged 23-47% of the tiles
                // of these frames when flat, textureless areas counted).
                let frames = try await Self.decodeAll(h)
                let e = try CoreMLInterpolator(spec: spec, proxyUniforms: UniformBuilder.analysis(source: hc, gridW: 1, gridH: 1))
                var bad = 0, all = 0
                for k in 0..<(frames.count - 1) {
                    let o = MetalContext.shared.makeTexture(width: frames[k].width, height: frames[k].height, format: frames[k].pixelFormat)
                    let r = try e.interpolate(frames[k], frames[k + 1], times: [0.5], into: [o], qcTiles: ((size.0 + 63) / 64, (size.1 + 63) / 64))
                    let mb = try XCTUnwrap(r[0].motionBad, "flow models report the motion check")
                    bad += mb.filter { $0 }.count; all += mb.count
                }
                XCTAssertLessThan(Float(bad) / Float(max(1, all)), 0.05, "\(label): \(bad) of \(all) tiles failed the motion check")
            }
        }

        // The hold-out benchmark ranks the converted models above the blend.
        let half = try Self.evenFrames(of: try Self.makePan("ml-truth-false-320.mov", rate: "48", frames: 33, step: 6),
                                       name: "ml-half-false-320.mov", rate: "24", hdr: false)
        let (h, hc) = try await Self.inspect(half)
        let bm = try await InterpolationEvaluator.benchmark(original: h, color: hc, analysis: Self.plainAnalysis(h.frameCount)) { _ in }
        let blendScore = try XCTUnwrap(bm.scores.first { $0.name == "Blend" })
        let best = try XCTUnwrap(bm.scores.first { $0.name != "Blend" })
        XCTAssertTrue(best.name.hasPrefix("RIFE 4.25"), best.name)
        XCTAssertGreaterThan(best.psnr, blendScore.psnr + 3, bm.summary)
        XCTAssertEqual(bm.recommendedModel, best.name)
        print("MODEL-LAB benchmark: \(bm.summary)")

        // A real export through Core ML: exact frame count and timestamps.
        var s = blend
        s.mode = .multiply(2)
        s.primaryModelID = img.id
        s.artifactRepair = true
        let engine = ExportEngine()
        let out = try await engine.run(Self.proresJob(h, color: hc, analysis: Self.plainAnalysis(h.frameCount), settings: s, out: "ml-export.mov")) { _, _ in }
        let tm = try Self.timing(out)
        XCTAssertEqual(tm.pts.count, 2 * h.frameCount - 1)
        XCTAssertTrue(tm.pts.enumerated().allSatisfy { i, p in p * tm.timeBase.num * 48 == i * tm.timeBase.den })

        // The motion router picks an installed model per scene and saves the map; trials name the model.
        var routed = InterpolationSettings()
        routed.intelligence = .perScene
        let map = try await MotionRouter.build(h, color: hc, analysis: Self.plainAnalysis(h.frameCount), settings: routed,
                                               kind: .realLife, progress: ProgressReporter(task: nil))
        defer {
            let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lumora/MotionMaps/\(map.sourceKey).json")
            try? FileManager.default.removeItem(at: f)
        }
        XCTAssertEqual(map.routes.count, 1)
        let route = try XCTUnwrap(map.routes.first)
        XCTAssertNotEqual(route.status, .skipped)
        XCTAssertTrue([img.id, flow.id].contains(route.model), route.model)
        XCTAssertGreaterThanOrEqual(route.trials, 4)
        XCTAssertNotNil(MotionMap.load(map.sourceKey))
    }

    /// Frames handed out by FrameStream must stay intact while the export pipeline still holds them (channel depth +
    /// grader), even at 8x with a model, strict artifact checks and grain-aware regraining (the most scratch use).
    func testModelLab5_StreamFramesSurviveThePipeline() async throws {
        try skipModelLabUnlessWanted()
        try TestHardware.requireGPU()
        guard let img = InterpolationModelSpec.all().first(where: { $0.id == "rife-4.25" && $0.isInstalled }) else {
            throw XCTSkip("RIFE 4.25 isn't converted (testModelLab3)")
        }
        let url = try Self.makePan("pan24.mov", rate: "24", frames: 13)
        let (d, color) = try await Self.inspect(url)
        let hold = max(6, (MacProfile.current?.pipelineDepth ?? 4) + 2)
        for (model, grain) in [(Self.noModel, false), (img.id, false), (img.id, true)] {
            var s = Self.blendSettings(.multiply(8))
            s.primaryModelID = model
            s.sensitivity = 1
            s.grainAware = grain
            let (plan, _) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s,
                                                      analysis: Self.plainAnalysis(d.frameCount))
            let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[...], settings: s,
                                         proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1))
            var held: [(StreamFrame, MTLTexture)] = []
            var changed: [Int] = []
            var n = 0
            func release() {
                let (f, snap) = held.removeFirst()
                if Self.psnr(snap, f.texture, color: color) < 90 { changed.append(f.outputIndex) }
            }
            while let f = try stream.next() {
                held.append((f, Self.copy(f.texture)))
                if held.count > hold { release() }
                n += 1
            }
            while !held.isEmpty { release() }
            XCTAssertEqual(n, plan.count)
            XCTAssertTrue(changed.isEmpty, "\(model), grain \(grain): \(changed.count) frames changed while still in the pipeline (first \(changed.prefix(5))), \(stream.events.count) repairs")
            print("MODEL-LAB hold \(model) grain \(grain): \(stream.events.count) repair events, actions \(Set(stream.events.map(\.action.rawValue)))")
        }
    }
}
