import XCTest
import Metal
@testable import Lumora

/// Quality targets, metrics and forecasting, end to end: real clips (FFmpeg), the real GPU grade, the real encoders
/// (VideoToolbox HEVC, SVT-AV1, libaom, x265) and the real metric tools (vmaf CLI, FFmpeg libvmaf/xpsnr).
/// Every check reads the output back (ffprobe, an independent vmaf run, file contents); nothing passes merely
/// because no error was thrown.
///
/// Persistent learning files under ~/Library/Application Support/Lumora that these tests write
/// (quality-predictor.json, forecast-learning.json, Calibration/, Manifests/) are snapshotted first and restored.
@MainActor
final class CampaignQualityTests: XCTestCase {

    // MARK: - Fixtures

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraCQ-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    nonisolated override class func setUp() {
        super.setUp()
        CQState.snapshot("quality-predictor.json")
        CQState.snapshot("forecast-learning.json")
        CQState.snapshotFolder("Manifests")
        CQState.snapshotFolder("Calibration")
    }

    nonisolated override class func tearDown() {
        CQState.restoreAll()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoraCQ-\(ProcessInfo.processInfo.processIdentifier)"))
        super.tearDown()
    }

    static func report(_ s: String) { print("CQREPORT " + s) }

    static var ffmpegPath: String {
        get throws { guard let f = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }; return f }
    }

    /// Runs a tool, returning stdout; on failure the error carries the tail of stderr.
    @discardableResult
    nonisolated static func run(_ exe: String, _ args: [String], stdin: URL? = nil, cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin { p.standardInput = try FileHandle(forReadingFrom: stdin) }
        let exited = p.exitSignal()
        try p.run()
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        exited.wait()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "run", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                "\((exe as NSString).lastPathComponent) exited \(p.terminationStatus): \(String(decoding: errData.suffix(1500), as: UTF8.self))"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func ff(_ args: [String]) throws {
        try run(try ffmpegPath, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    /// Shots of lavfi sources joined with hard cuts, SDR BT.709 H.264 at a high quality (CRF 10).
    static func clip(_ name: String, size: String, shots: [(source: String, seconds: Double)]) throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var graph = ""
        for (i, s) in shots.enumerated() {
            graph += "\(s.source)=s=\(size):r=24,trim=duration=\(s.seconds),setpts=PTS-STARTPTS,format=yuv420p[s\(i)];"
        }
        graph += shots.indices.map { "[s\($0)]" }.joined() + "concat=n=\(shots.count):v=1[v]"
        try ff(["-filter_complex", graph, "-map", "[v]", "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", url.path])
        return url
    }

    /// 10-bit 4:2:0 Y4M copy of a file (what the metric tools read).
    static func y4m(_ src: URL, filter: String? = nil, name: String) throws -> URL {
        let out = work.appendingPathComponent(name)
        try ff(["-i", src.path, "-vf", (filter.map { $0 + "," } ?? "") + "format=yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", out.path])
        return out
    }

    static func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    /// Independent VMAF (vmaf CLI, every frame, v0.6.1) between two files of the same size and frame count.
    static func independentVMAF(reference: URL, distorted: URL) throws -> (mean: Double, frames: Int) {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/vmaf") else { throw XCTSkip("vmaf CLI not installed") }
        let tag = UUID().uuidString.prefix(6)
        let r = try y4m(reference, name: "iv-ref-\(tag).y4m"), d = try y4m(distorted, name: "iv-dist-\(tag).y4m")
        let json = work.appendingPathComponent("iv-\(tag).json")
        defer { for u in [r, d, json] { try? FileManager.default.removeItem(at: u) } }
        try run("/opt/homebrew/bin/vmaf", ["--reference", r.path, "--distorted", d.path, "--threads", "6", "--json",
                                         "--output", json.path, "--quiet", "--model", "version=vmaf_v0.6.1"])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        let frames = (obj["frames"] as? [[String: Any]])?.count ?? 0
        let mean = try XCTUnwrap(((obj["pooled_metrics"] as? [String: Any])?["vmaf"] as? [String: Any])?["mean"] as? Double)
        return (mean, frames)
    }

    /// Inspect → analyze → presets → job, as AppModel does it (SDR sources only here, so no report card).
    static func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out: String) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        let job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: work.appendingPathComponent(out))
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    static func vmafOnly(_ threshold: Double, hdr: Bool = false) -> QualityTarget {
        var p = QualityProfile.presets(hdr: hdr).first { $0.name == "VMAF only" }!
        p.rules[0].threshold = threshold
        var t = QualityTarget()
        t.vmaf = threshold
        t.profile = p
        return t
    }

    static func requireVMAFCLI() throws {
        guard VMAFRunner.backend == .vmafCLI else { throw XCTSkip("vmaf CLI (libvmaf) not installed") }
    }

    /// Reads N frames of raw 10-bit 4:2:0 into PlanarFrames (as the engine holds them in RAM).
    static func planarFrames(from src: URL, width: Int, height: Int) throws -> [PlanarFrame] {
        let raw = work.appendingPathComponent("raw-\(UUID().uuidString.prefix(6)).yuv")
        defer { try? FileManager.default.removeItem(at: raw) }
        try ff(["-i", src.path, "-vf", "scale=\(width):\(height),format=yuv420p10le", "-f", "rawvideo", raw.path])
        let data = try Data(contentsOf: raw)
        let ySize = width * height * 2, cSize = width / 2 * height / 2 * 2
        let frameSize = ySize + 2 * cSize
        let device = MetalContext.shared.device
        return stride(from: 0, to: data.count - frameSize + 1, by: frameSize).map { off in
            let f = PlanarFrame(device: device, width: width, height: height, bits: 10, chroma: .c420)
            data.withUnsafeBytes { p in
                memcpy(f.y.contents(), p.baseAddress! + off, ySize)
                memcpy(f.cb.contents(), p.baseAddress! + off + ySize, cSize)
                memcpy(f.cr.contents(), p.baseAddress! + off + ySize + cSize, cSize)
            }
            return f
        }
    }

    // MARK: - Metric availability is truthful

    func testMetricAvailabilityMatchesInstalledTools() throws {
        let exe = { (name: String) in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin"]
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
            || (Bundle.main.resourceURL.map { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/\(name)").path) } ?? false) }
        let filters = try Self.run(try Self.ffmpegPath, ["-hide_banner", "-filters"])
        let hasVMAF = exe("vmaf")
        XCTAssertEqual(VMAFRunner.backend == .vmafCLI, hasVMAF)
        if !hasVMAF { XCTAssertEqual(VMAFRunner.backend == .ffmpegLibvmaf, filters.contains("libvmaf")) }
        XCTAssertEqual(VMAFRunner.available, hasVMAF || filters.contains("libvmaf"))
        for m: QualityMetric in [.vmafNeg, .cambi, .msssim, .psnrHvs, .ciede] {
            XCTAssertEqual(m.isAvailable, hasVMAF, "\(m.displayName) needs the vmaf CLI (the FFmpeg filter path only returns VMAF)")
        }
        XCTAssertEqual(QualityMetric.vmaf.isAvailable, VMAFRunner.available)
        XCTAssertEqual(QualityMetric.xpsnr.isAvailable, filters.contains(" xpsnr "))
        XCTAssertEqual(QualityMetric.ssimulacra2.isAvailable, exe("ssimulacra2_rs"))
        XCTAssertEqual(QualityMetric.avqt.isAvailable, exe("AVQT"))
        // ColorVideoVDP: available only when Model Lab's venv can actually import it.
        let py = ModelLab.lab.appendingPathComponent("venv/bin/python")
        var cvvdpImports = false
        if FileManager.default.isExecutableFile(atPath: py.path) {
            cvvdpImports = (try? Self.run(py.path, ["-c", "import pycvvdp"])) != nil
        }
        if QualityMetric.cvvdp.isAvailable { XCTAssertTrue(cvvdpImports, "cvvdp reported available but pycvvdp doesn't import") }
        XCTAssertEqual(QualityMetric.cvvdp.isAvailable, QualityMetric.puPsnr.isAvailable)
        Self.report("availability: " + QualityMetric.allCases.map { "\($0.rawValue)=\($0.isAvailable)" }.joined(separator: " ")
                    + " cvvdpImports=\(cvvdpImports)")

        // effective() drops what isn't installed, and compensates for a missing ColorVideoVDP gate.
        let imperceptible = QualityProfile.presets(hdr: false)[0]
        let (eff, notes) = imperceptible.effective()
        for r in eff.rules where r.role != .off { XCTAssertTrue(r.metric.isAvailable, "\(r.metric) left active but not installed") }
        if !QualityMetric.cvvdp.isAvailable {
            XCTAssertEqual(eff.primary?.threshold, 95, "without ColorVideoVDP the VMAF search target is raised to 95")
            XCTAssertTrue(notes.contains { $0.contains("raised to 95") })
        }
        XCTAssertEqual(notes.filter { $0.contains("isn't installed") }.count,
                       imperceptible.rules.filter { $0.role != .off && !$0.metric.isAvailable }.count)
    }

    // MARK: - VMAFRunner (both backends)

    func testVMAFRunnerScoresIdenticalAboveDegradedOnBothBackends() async throws {
        try Self.requireVMAFCLI()
        let src = try Self.clip("cq-vmaf.mp4", size: "320x180", shots: [("testsrc2", 1)])
        let ref = try Self.y4m(src, name: "cq-vmaf-ref.y4m")
        let lossless = Self.work.appendingPathComponent("cq-vmaf-ffv1.mkv")
        try Self.ff(["-i", ref.path, "-c:v", "ffv1", lossless.path])
        let bad = Self.work.appendingPathComponent("cq-vmaf-bad.mp4")
        try Self.ff(["-i", src.path, "-vf", "boxblur=2", "-c:v", "libx264", "-crf", "40", bad.path])
        let writer: (FileHandle) throws -> Void = { h in try h.write(contentsOf: Data(contentsOf: ref)) }
        let opts = VMAFRunner.Options(model: "vmaf_v0.6.1", subsample: 1, threads: 4, downscaleHeight: nil)

        var results: [VMAFRunner.Backend: (good: VMAFRunner.Result, bad: VMAFRunner.Result)] = [:]
        for backend: VMAFRunner.Backend in [.vmafCLI, .ffmpegLibvmaf] {
            let good = try await VMAFRunner.score(writeReference: writer, distorted: lossless, frameRate: (24, 1), options: opts,
                                                  workDir: Self.work, using: backend)
            let worse = try await VMAFRunner.score(writeReference: writer, distorted: bad, frameRate: (24, 1), options: opts,
                                                   workDir: Self.work, using: backend)
            XCTAssertEqual(good.frames.count, 24, "\(backend): one score per frame")
            XCTAssertEqual(worse.frames.count, 24)
            XCTAssertGreaterThan(good.mean, 97, "\(backend): a lossless copy must score near 100")
            XCTAssertLessThan(worse.mean, good.mean - 10, "\(backend): blur + CRF 40 must score clearly lower")
            for r in [good, worse] {
                XCTAssertLessThanOrEqual(r.min, r.p5 + 1e-9)
                XCTAssertLessThanOrEqual(r.p5, r.mean + 1e-9)
                XCTAssertLessThanOrEqual(r.harmonic, r.mean + 1e-9)
                XCTAssertEqual(r.pooled(.mean), r.mean); XCTAssertEqual(r.pooled(.p5), r.p5); XCTAssertEqual(r.pooled(.harmonic), r.harmonic)
            }
            results[backend] = (good, worse)
        }
        // Same libvmaf model either way: the two backends must agree.
        let cli = results[.vmafCLI]!, ffm = results[.ffmpegLibvmaf]!
        XCTAssertEqual(cli.bad.mean, ffm.bad.mean, accuracy: 1.0, "CLI and FFmpeg libvmaf disagree")
        XCTAssertEqual(cli.good.mean, ffm.good.mean, accuracy: 1.0)
        Self.report(String(format: "VMAF CLI good %.2f bad %.2f | ffmpeg good %.2f bad %.2f", cli.good.mean, cli.bad.mean, ffm.good.mean, ffm.bad.mean))

        // Subsampling and the fast-validation downscale.
        var sub = opts; sub.subsample = 2
        let s2 = try await VMAFRunner.score(writeReference: writer, distorted: bad, frameRate: (24, 1), options: sub, workDir: Self.work)
        XCTAssertEqual(s2.frames.count, 12, "every 2nd frame")
        XCTAssertEqual(s2.mean, cli.bad.mean, accuracy: 3)
        var down = opts; down.downscaleHeight = 90
        let d = try await VMAFRunner.score(writeReference: writer, distorted: bad, frameRate: (24, 1), options: down, workDir: Self.work)
        XCTAssertEqual(d.frames.count, 24)
        XCTAssertGreaterThan(d.mean, 0)

        // No backend: a clean, named error.
        do {
            _ = try await VMAFRunner.score(writeReference: writer, distorted: bad, frameRate: (24, 1), options: opts, workDir: Self.work, using: VMAFRunner.Backend.none)
            XCTFail("expected missingTool")
        } catch LumoraError.missingTool(let t) {
            XCTAssertTrue(t.contains("vmaf"))
        }
        // The job folder holds no leftover pipes or logs.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: Self.work.path).filter { $0.hasPrefix("vmaf-") || $0.hasPrefix("ref-") || $0.hasPrefix("dist-") }
        XCTAssertEqual(leftovers, [], "VMAFRunner left files behind")
    }

    // MARK: - MetricSuite: every libvmaf metric, XPSNR, CAMBI, in the right direction

    func testMetricSuiteScoresIdenticalAboveDegradedForEveryMetric() async throws {
        try Self.requireVMAFCLI()
        let src = try Self.clip("cq-suite.mp4", size: "320x180", shots: [("testsrc2", 1)])
        let ref = try Self.y4m(src, name: "cq-suite-ref.y4m")
        // Degraded: blur, a color shift and heavy compression, so every metric has something to see.
        let bad = Self.work.appendingPathComponent("cq-suite-bad.mkv")
        try Self.ff(["-i", ref.path, "-vf", "boxblur=1,eq=saturation=1.4:gamma_r=1.1", "-c:v", "libx265", "-crf", "34",
                     "-x265-params", "log-level=error", "-pix_fmt", "yuv420p10le", bad.path])
        let same = Self.work.appendingPathComponent("cq-suite-same.mkv")
        try Self.ff(["-i", ref.path, "-c:v", "ffv1", same.path])
        let writer: (FileHandle) throws -> Void = { h in try h.write(contentsOf: Data(contentsOf: ref)) }
        let ctx = MetricSuite.Context(width: 320, height: 180, rate: (24, 1), hdr: false, frames: 24, threads: 4, fast: false, workDir: Self.work)
        let metrics: Set<QualityMetric> = Set([.vmaf, .vmafNeg, .cambi, .msssim, .psnrHvs, .ciede, .xpsnr].filter(\.isAvailable))

        let good = try await MetricSuite.measure(metrics, reference: writer, distorted: same, ctx: ctx)
        let worse = try await MetricSuite.measure(metrics, reference: writer, distorted: bad, ctx: ctx)
        Self.report("suite identical: " + good.pooled.map { "\($0.key.rawValue)=\(String(format: "%.3f", $0.value.mean))" }.sorted().joined(separator: " "))
        Self.report("suite degraded:  " + worse.pooled.map { "\($0.key.rawValue)=\(String(format: "%.3f", $0.value.mean))" }.sorted().joined(separator: " "))
        for m in metrics {
            let g = try XCTUnwrap(good.pooled[m]?.mean, "\(m.displayName) missing for identical input")
            let b = try XCTUnwrap(worse.pooled[m]?.mean, "\(m.displayName) missing for degraded input")
            XCTAssertFalse(b.isNaN || b.isInfinite, "\(m.displayName) degraded score isn't finite")
            if m == .cambi {
                XCTAssertGreaterThanOrEqual(b, g, "CAMBI never improves with degradation")
            } else if m.higherIsBetter {
                XCTAssertGreaterThan(g, b, "\(m.displayName): identical must score higher than degraded")
            } else {
                XCTAssertLessThan(g, b, "\(m.displayName): identical must score lower (better) than degraded")
            }
            XCTAssertEqual(worse.perFrame[m]?.count ?? 0, 24, "\(m.displayName): one value per frame")
        }
        // Units and ranges a profile threshold relies on.
        if metrics.contains(.ciede) {
            XCTAssertEqual(good.pooled[.ciede]!.mean, 0, accuracy: 0.05, "an identical picture has ΔE 0")
            XCTAssertGreaterThan(worse.pooled[.ciede]!.mean, 1.5, "a 1.4× saturation boost is a visible color shift (ΔE > 1.5)")
            XCTAssertLessThan(worse.pooled[.ciede]!.mean, 30, "ΔE2000 values live roughly in 0–30")
            XCTAssertFalse(MetricRule(metric: .ciede, role: .mustPass, threshold: 1.5).passes(worse.pooled[.ciede]!.mean))
            XCTAssertTrue(MetricRule(metric: .ciede, role: .mustPass, threshold: 1.5).passes(good.pooled[.ciede]!.mean))
        }
        if metrics.contains(.msssim) { XCTAssertEqual(good.pooled[.msssim]!.mean, 1, accuracy: 0.001) }
        if metrics.contains(.vmafNeg) { XCTAssertGreaterThan(good.pooled[.vmafNeg]!.mean, 95) }
        // Worst-5% pooling is never better than the mean.
        for (m, p) in worse.pooled { XCTAssertTrue(m.higherIsBetter ? p.worst <= p.mean + 1e-9 : p.worst >= p.mean - 1e-9, "\(m) pooling") }
    }

    func testCAMBIMeasuresBandingAddedByTheEncodeInSDRAndPQ() async throws {
        try Self.requireVMAFCLI()
        // A smooth 10-bit ramp, and the same ramp posterized into wide steps (what an over-compressed sky looks like).
        // CAMBI looks for the low-contrast steps an encoder leaves in gradients (a few code values wide); hard steps
        // are edges, not banding. Reference: a dithered 10-bit ramp (no visible steps). Distorted: the same ramp
        // quantized to 4-code steps every 16 px, which is what a starved encode does to a sky.
        let smooth = Self.work.appendingPathComponent("cq-ramp.y4m"), banded = Self.work.appendingPathComponent("cq-ramp-banded.mkv")
        try Self.ff(["-f", "lavfi", "-i", "color=c=gray:s=640x360:r=24:d=0.5,format=yuv420p10le,geq=lum='200+X/4+4*random(1)':cb=512:cr=512",
                     "-strict", "-1", "-f", "yuv4mpegpipe", smooth.path])
        try Self.ff(["-i", smooth.path, "-vf", "geq=lum='floor((200+X/4)/4)*4':cb=512:cr=512", "-c:v", "ffv1", banded.path])
        let sameCopy = Self.work.appendingPathComponent("cq-ramp-same.mkv")
        try Self.ff(["-i", smooth.path, "-c:v", "ffv1", sameCopy.path])
        let writer: (FileHandle) throws -> Void = { h in try h.write(contentsOf: Data(contentsOf: smooth)) }
        for hdr in [false, true] {
            let ctx = MetricSuite.Context(width: 640, height: 360, rate: (24, 1), hdr: hdr, frames: 12, threads: 4, fast: false, workDir: Self.work)
            let clean = try await MetricSuite.measure([.cambi], reference: writer, distorted: sameCopy, ctx: ctx)
            let bandedScore = try await MetricSuite.measure([.cambi], reference: writer, distorted: banded, ctx: ctx)
            let c = try XCTUnwrap(clean.pooled[.cambi]?.mean), b = try XCTUnwrap(bandedScore.pooled[.cambi]?.mean)
            Self.report(String(format: "CAMBI %@ clean %.3f banded %.3f", hdr ? "PQ" : "SDR", c, b))
            XCTAssertLessThan(c, 0.2, "no banding added by an identical copy")
            XCTAssertGreaterThan(b, c + 0.5, "posterized ramp must register as added banding")
            let gate = MetricRule(metric: .cambi, role: .mustPass, threshold: 1.0)
            XCTAssertTrue(gate.passes(c))
        }
    }

    func testPoolingAndProfilePassRules() {
        XCTAssertEqual(MetricScores.pool([], higherIsBetter: true).mean, 0)
        let few = MetricScores.pool([90, 80, 70], higherIsBetter: true)
        XCTAssertEqual(few.worst, 70, "with fewer than 20 frames the worst 5% is the single worst frame")
        XCTAssertEqual(MetricScores.pool([1, 2, 3], higherIsBetter: false).worst, 3)
        var s = MetricScores()
        s.pooled[.vmaf] = (96, 80)
        let worst = MetricRule(metric: .vmaf, role: .target, threshold: 90, useWorstFrames: true)
        XCTAssertEqual(s.value(worst), 80)
        XCTAssertEqual(s.value(MetricRule(metric: .vmaf, role: .target, threshold: 90)), 96)
        let p = QualityProfile(name: "t", summary: "", rules: [worst, MetricRule(metric: .ciede, role: .mustPass, threshold: 1.5),
                                                              MetricRule(metric: .xpsnr, role: .report, threshold: 99)])
        s.pooled[.xpsnr] = (10, 10)
        let v = s.passes(p, includeSlow: false)
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.failures.count, 1, "report-only rules and unmeasured metrics never block: \(v.failures)")
        XCTAssertTrue(v.failures[0].hasPrefix("VMAF 80.00 <"))
        for (vmaf, words) in [(98.0, "Practically identical"), (95.0, "indistinguishable"), (91.0, "Excellent"), (85.0, "streaming")] {
            var t = QualityTarget(); t.vmaf = vmaf
            XCTAssertTrue(t.plainEnglish.contains(words), "\(vmaf): \(t.plainEnglish)")
        }
        XCTAssertEqual(TargetQualityEncoder.describe(.hevc, level: 62), "quality 0.62")
        XCTAssertEqual(TargetQualityEncoder.describe(.av1, level: -30), "CRF 30")
        XCTAssertEqual(TargetQualityEncoder.describe(.vvc, level: -30), "QP 30")
    }

    /// The reference Y4M carries no color matrix, real encodes are tagged. Two-input FFmpeg graphs (XPSNR, the
    /// libvmaf filter fallback) must score the coded values, not a matrix-converted copy of one side.
    func testFFmpegComparisonsIgnoreColourTags() async throws {
        try Self.requireVMAFCLI()
        let src = try Self.clip("cq-tags.mp4", size: "320x180", shots: [("testsrc2", 1)])
        let ref = try Self.y4m(src, name: "cq-tags-ref.y4m")
        let tagged = Self.work.appendingPathComponent("cq-tags-crf18.mp4")
        try Self.ff(["-i", src.path, "-c:v", "libx264", "-crf", "18", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", tagged.path])
        XCTAssertTrue(try Self.run(EndToEndTests.ffprobe!, ["-v", "error", "-show_entries", "stream=color_space", "-of", "csv=p=0", tagged.path]).contains("bt709"))
        let plain = Self.work.appendingPathComponent("cq-tags-plain.mkv")     // same pixels, no tags
        try Self.ff(["-i", tagged.path, "-vf", "setparams=range=unknown:color_primaries=unknown:color_trc=unknown:colorspace=unknown",
                     "-c:v", "ffv1", plain.path])
        let writer: (FileHandle) throws -> Void = { h in try h.write(contentsOf: Data(contentsOf: ref)) }
        let ctx = MetricSuite.Context(width: 320, height: 180, rate: (24, 1), hdr: false, frames: 24, threads: 4, fast: false, workDir: Self.work)
        if QualityMetric.xpsnr.isAvailable {
            let a = try await MetricSuite.measure([.xpsnr], reference: writer, distorted: tagged, ctx: ctx)
            let b = try await MetricSuite.measure([.xpsnr], reference: writer, distorted: plain, ctx: ctx)
            let xa = try XCTUnwrap(a.pooled[.xpsnr]?.mean), xb = try XCTUnwrap(b.pooled[.xpsnr]?.mean)
            Self.report(String(format: "XPSNR CRF18 tagged %.2f dB, untagged %.2f dB", xa, xb))
            XCTAssertEqual(xa, xb, accuracy: 0.1, "XPSNR changed with color tags alone")
            XCTAssertGreaterThan(xa, 35, "a CRF 18 encode is well above 35 dB XPSNR")
        }
        let opts = VMAFRunner.Options(model: "vmaf_v0.6.1", subsample: 1, threads: 4, downscaleHeight: nil)
        let cli = try await VMAFRunner.score(writeReference: writer, distorted: tagged, frameRate: (24, 1), options: opts, workDir: Self.work, using: .vmafCLI)
        let ffTagged = try await VMAFRunner.score(writeReference: writer, distorted: tagged, frameRate: (24, 1), options: opts, workDir: Self.work, using: .ffmpegLibvmaf)
        let ffPlain = try await VMAFRunner.score(writeReference: writer, distorted: plain, frameRate: (24, 1), options: opts, workDir: Self.work, using: .ffmpegLibvmaf)
        Self.report(String(format: "VMAF CRF18 CLI %.2f, ffmpeg tagged %.2f, ffmpeg untagged %.2f", cli.mean, ffTagged.mean, ffPlain.mean))
        XCTAssertEqual(ffTagged.mean, ffPlain.mean, accuracy: 0.2)
        XCTAssertEqual(ffTagged.mean, cli.mean, accuracy: 0.5)
        XCTAssertGreaterThan(cli.mean, 90)
    }

    // MARK: - FileMetrics

    func testFileMetricsComparesTwoFiles() async throws {
        try Self.requireVMAFCLI()
        let src = try Self.clip("cq-files.mp4", size: "320x180", shots: [("testsrc2", 1)])
        let copy = Self.work.appendingPathComponent("cq-files-copy.mkv")
        try Self.ff(["-i", src.path, "-c:v", "ffv1", copy.path])
        let bad = Self.work.appendingPathComponent("cq-files-bad.mp4")
        try Self.ff(["-i", src.path, "-vf", "boxblur=2", "-c:v", "libx264", "-crf", "42", bad.path])
        let same = try await FileMetrics.measure(reference: src, test: copy, hdr: false, width: 320, height: 180, frames: 24, rate: (24, 1))
        let worse = try await FileMetrics.measure(reference: src, test: bad, hdr: false, width: 320, height: 180, frames: 24, rate: (24, 1))
        let expected = Set(QualityMetric.allCases.filter { $0.isAvailable && $0 != .avqt })
        XCTAssertEqual(Set(worse.scores.pooled.keys), expected, "every installed metric is reported")
        let g = try XCTUnwrap(same.scores.pooled[.vmaf]?.mean), b = try XCTUnwrap(worse.scores.pooled[.vmaf]?.mean)
        XCTAssertGreaterThan(g, 97)
        XCTAssertLessThan(b, g - 10)
        if let gx = same.scores.pooled[.xpsnr]?.mean, let bx = worse.scores.pooled[.xpsnr]?.mean { XCTAssertGreaterThan(gx, bx) }
        if let gc = same.scores.pooled[.ciede]?.mean, let bc = worse.scores.pooled[.ciede]?.mean { XCTAssertLessThan(gc, bc) }
        XCTAssertNil(worse.avqt, "AVQT isn't installed here")
        XCTAssertEqual(worse.notes, [])
        Self.report(String(format: "FileMetrics VMAF copy %.2f degraded %.2f", g, b))
    }

    // MARK: - Quality-target export (TargetQualityEncoder through ExportEngine.run)

    /// Exports at two VMAF targets and checks: frame count, per-chunk VMAF meets each target (as reported and by an
    /// independent vmaf run against a ProRes render of the same grade), and the higher target makes a bigger file.
    private func targetExport(codec: Codec, low: Double, high: Double, size: String) async throws {
        try Self.requireVMAFCLI()
        try TestHardware.requireGPU()
        let src = try Self.clip("cq-target-\(size).mp4", size: size, shots: [("testsrc2", 1), ("mandelbrot", 1)])
        // Reference: the same grade as near-lossless ProRes 422 HQ.
        var refJob = try await Self.makeJob(src, delivery: .sdr, codec: .prores422HQ, out: "cq-ref-\(codec.rawValue).mov")
        refJob.chroma = .c422
        let ref = try await ExportEngine().run(refJob) { _, _ in }
        var sizes: [Double: Int64] = [:]
        let ext = codec == .hevc ? "mov" : "mkv"
        for target in [low, high] {
            var job = try await Self.makeJob(src, delivery: .sdr, codec: codec, out: "cq-\(codec.rawValue)-t\(Int(target)).\(ext)")
            job.qualityTarget = Self.vmafOnly(target)
            let t0 = Date()
            let url = try await ExportEngine().run(job) { _, _ in }
            let p = try EndToEndTests.probe(url)
            XCTAssertEqual(p.codec, codec == .hevc ? "hevc" : "av1")
            XCTAssertEqual(p.frames, 48)
            let mon = EncodeMonitor.shared
            XCTAssertEqual(mon.totalFrames, 48)
            XCTAssertEqual(mon.target?.vmaf, target)
            XCTAssertFalse(mon.chunks.isEmpty)
            XCTAssertEqual(mon.chunks.reduce(0) { $0 + $1.range.count }, 48, "chunks cover the film")
            let range = TargetQualityEncoder.levelRange(codec)
            for c in mon.chunks {
                XCTAssertEqual(c.state, .done)
                XCTAssertGreaterThanOrEqual(c.trials, 1)
                XCTAssertGreaterThan(c.bytes, 0)
                let v = try XCTUnwrap(c.vmafMean, "chunk \(c.id) has no VMAF")
                // The reported score belongs to the accepted encode; it meets the target unless the encoder topped out.
                if !c.setting.contains(TargetQualityEncoder.describe(codec, level: range.high)) {
                    XCTAssertGreaterThanOrEqual(v, target, "chunk \(c.id) accepted at \(c.setting) but reports VMAF \(v) < \(target)")
                }
            }
            XCTAssertEqual(Double(mon.encodedBytes), Double(Self.size(url)), accuracy: Double(Self.size(url)) * 0.15 + 4096,
                           "monitor bytes should match the file (container overhead only)")
            XCTAssertEqual(mon.projectedBytes, mon.encodedBytes, "all done, no forecast: projection = measured")
            XCTAssertFalse(mon.frameScores.isEmpty)
            // Independent check against the ProRes render of the same grade.
            let iv = try Self.independentVMAF(reference: ref, distorted: url)
            XCTAssertEqual(iv.frames, 48)
            XCTAssertGreaterThanOrEqual(iv.mean, target - 1.5, "independent VMAF \(iv.mean) misses target \(target)")
            let manifest = try XCTUnwrap(ExportManifest.load(for: url), "target exports record a repair manifest")
            XCTAssertEqual(manifest.chunks.reduce(0) { $0 + $1.count }, 48)
            XCTAssertEqual(manifest.codec, codec)
            sizes[target] = Self.size(url)
            Self.report(String(format: "%@ target %.0f: %d bytes, chunks %@, reported %@, independent %.2f, %.1fs", codec.rawValue, target,
                               Int(Self.size(url)), mon.chunks.map(\.setting).joined(separator: "/"),
                               mon.chunks.map { String(format: "%.2f", $0.vmafMean ?? -1) }.joined(separator: "/"), iv.mean,
                               Date().timeIntervalSince(t0)))
        }
        XCTAssertGreaterThan(sizes[high]!, sizes[low]!, "a higher VMAF target must give a bigger file")
    }

    func testTargetQualityHEVCMeetsTargetAndHigherTargetIsBigger() async throws {
        try TestHardware.requireHardwareHEVC()
        try await targetExport(codec: .hevc, low: 84, high: 96, size: "640x360")
    }

    func testTargetQualityAV1MeetsTargetAndHigherTargetIsBigger() async throws {
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        try await targetExport(codec: .av1, low: 84, high: 95, size: "480x270")
    }

    /// The shipped default standard (Imperceptible, with its banding/color/NEG gates) must be reachable at a
    /// sensible setting: a gate in the wrong units would push every chunk to the encoder's maximum.
    func testImperceptibleProfileGatesPassAtASensibleSetting() async throws {
        try Self.requireVMAFCLI()
        try TestHardware.requireHardwareHEVC()
        let src = try Self.clip("cq-target-640x360.mp4", size: "640x360", shots: [("testsrc2", 1), ("mandelbrot", 1)])
        var job = try await Self.makeJob(src, delivery: .sdr, codec: .hevc, out: "cq-imperceptible.mov")
        var t = QualityTarget()
        t.profile = QualityProfile.presets(hdr: false)[0]
        job.qualityTarget = t
        let url = try await ExportEngine().run(job) { _, _ in }
        XCTAssertEqual(try EndToEndTests.probe(url).frames, 48)
        let (eff, _) = t.profile.effective()
        let threshold = eff.primary!.threshold
        for c in EncodeMonitor.shared.chunks {
            Self.report("imperceptible chunk \(c.id): \(c.setting) trials \(c.trials) " + c.metrics.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.sorted().joined(separator: " "))
            XCTAssertEqual(c.state, .done)
            XCTAssertFalse(c.setting.contains("quality 0.96"), "chunk \(c.id) was pushed to the encoder's maximum quality")
            XCTAssertGreaterThanOrEqual(c.vmafMean ?? 0, threshold)
            if let x = c.metrics["xpsnr"] { XCTAssertGreaterThan(x, 30, "XPSNR of an encode at VMAF \(c.vmafMean ?? 0) can't be \(x) dB") }
            for gate in eff.gates where !gate.metric.slow {
                let v = try XCTUnwrap(c.metrics[gate.metric.rawValue], "\(gate.metric.displayName) gate was not measured")
                if gate.useWorstFrames == false { XCTAssertTrue(gate.passes(v), "\(gate.metric.displayName) \(v) fails \(gate.threshold)") }
            }
        }
    }

    // MARK: - Dip re-encoding (TargetQualityEncoder.encode directly)

    private final class DipEncoder: @unchecked Sendable {
        let lock = NSLock()
        var firstLevel: Double?
        var calls: [(count: Int, level: Double, corrupted: Bool)] = []
        let bad: Set<ObjectIdentifier>
        let full: Int
        let ffmpeg: String
        init(bad: Set<ObjectIdentifier>, full: Int, ffmpeg: String) { self.bad = bad; self.full = full; self.ffmpeg = ffmpeg }

        /// A stand-in encoder whose full-chunk encodes starve one hard stretch (it comes out flat gray), while a
        /// separate, higher-level encode of that stretch gets it right. Real x265 via FFmpeg; real files.
        func encode(_ frames: [PlanarFrame], _ level: Double, _ url: URL) async throws {
            lock.lock()
            if firstLevel == nil { firstLevel = level }
            let corrupt = frames.count == full || level < firstLevel! + 1
            calls.append((frames.count, level, corrupt))
            lock.unlock()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "yuv4mpegpipe", "-i", "pipe:0", "-c:v", "libx265",
                           "-preset", "ultrafast", "-crf", "\(Int(-level))", "-x265-params", "log-level=error",
                           "-pix_fmt", "yuv420p10le", "-f", "hevc", url.path]
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.runWatched()
            let h = pipe.fileHandleForWriting
            try h.write(contentsOf: Data(frames[0].y4mHeader(fpsNum: 24, fpsDen: 1).utf8))
            for f in frames {
                if corrupt && bad.contains(ObjectIdentifier(f)) {
                    try h.write(contentsOf: Data("FRAME\n".utf8))
                    try h.write(contentsOf: Data(repeating: 0, count: f.y.length).withGray(512))
                    try h.write(contentsOf: Data(bytesNoCopy: f.cb.contents(), count: f.cb.length, deallocator: .none))
                    try h.write(contentsOf: Data(bytesNoCopy: f.cr.contents(), count: f.cr.length, deallocator: .none))
                } else {
                    try f.write(to: h)
                }
            }
            try h.close()
            await p.exited()
            guard p.terminationStatus == 0 else { throw LumoraError.toolFailed("ffmpeg", "exit \(p.terminationStatus)") }
        }
    }

    func testDipsAreReencodedSeparatelyAndFixed() async throws {
        try Self.requireVMAFCLI()
        try TestHardware.requireGPU()
        let src = try Self.clip("cq-dip.mp4", size: "320x180", shots: [("testsrc2", 6)])
        let frames = try Self.planarFrames(from: src, width: 320, height: 180)
        XCTAssertEqual(frames.count, 144)
        let badRange = 72..<96
        let enc = DipEncoder(bad: Set(frames[badRange].map(ObjectIdentifier.init)), full: frames.count, ffmpeg: try Self.ffmpegPath)
        var target = Self.vmafOnly(75)
        target.floorMargin = 100           // let the stretch hide inside a passing chunk average
        target.maxTrials = 1
        target.fastValidation = false
        let start = 1000
        let jobDir = Self.work.appendingPathComponent("dip-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        EncodeMonitor.shared.reset(target: target, chunks: [start..<(start + frames.count)], totalFrames: frames.count)
        let scene = SceneStats(start: 0, end: 144, keyStops: -1, p005: -6, p50: -1, p995: 2, skinFraction: 0, avgChroma: 0.05)
        let pieces = try await TargetQualityEncoder(engine: ExportEngine()).encode(
            frames: frames, chunkID: 0, start: start, sceneStats: scene, interpolatedShare: 0, kind: .realLife,
            encodeOne: { try await enc.encode($0, $1, $2) }, target: target, rate: (24, 1), workDir: jobDir, threads: 4,
            codec: .hevc12, hdr: false)
        Self.report("dip calls: " + enc.calls.map { "\($0.count)@\(Int($0.level))\($0.corrupted ? "*" : "")" }.joined(separator: " ")
                    + " pieces: " + pieces.map { "\($0.start)+\($0.count)@\(Int($0.level))" }.joined(separator: " "))
        XCTAssertGreaterThanOrEqual(pieces.count, 2, "the gray stretch must be split out")
        XCTAssertEqual(pieces.first?.start, start)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.count }, frames.count)
        for (a, b) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(a.start + a.count, b.start, "pieces are contiguous") }
        let chosen = try XCTUnwrap(enc.firstLevel)
        let dip = try XCTUnwrap(pieces.first { $0.level > chosen }, "the dip piece is re-encoded at a higher level")
        XCTAssertLessThanOrEqual(dip.start - start, badRange.lowerBound)
        XCTAssertGreaterThanOrEqual(dip.start - start + dip.count, badRange.upperBound, "dip piece covers the bad stretch")
        for p in pieces where p.url != dip.url { XCTAssertEqual(p.level, chosen) }
        // The repaired piece really is good now (independent vmaf on its frames).
        let refY4M = Self.work.appendingPathComponent("dip-ref.y4m")
        FileManager.default.createFile(atPath: refY4M.path, contents: nil)
        let h = try FileHandle(forWritingTo: refY4M)
        let local = (dip.start - start)..<(dip.start - start + dip.count)
        try h.write(contentsOf: Data(PlanarFrame.y4mHeader420p10(width: 320, height: 180, fps: (24, 1)).utf8))
        for f in frames[local] { try f.writeY4M420p10(to: h) }
        try h.close()
        let iv = try Self.independentVMAF(reference: refY4M, distorted: dip.url)
        XCTAssertEqual(iv.frames, dip.count)
        XCTAssertGreaterThanOrEqual(iv.mean, 75, "re-encoded dip still scores \(iv.mean)")
        // Monitor: done, bytes = the pieces on disk, per-frame scores in output frame numbers.
        let c = try XCTUnwrap(EncodeMonitor.shared.chunks.first)
        XCTAssertEqual(c.state, .done)
        XCTAssertEqual(c.bytes, pieces.reduce(0) { $0 + Self.size($1.url) })
        let dipScores = badRange.compactMap { EncodeMonitor.shared.frameScores[start + $0] }
        XCTAssertFalse(dipScores.isEmpty)
        XCTAssertGreaterThanOrEqual(dipScores.reduce(0, +) / Double(dipScores.count), 75, "monitor shows the repaired scores")
        // Every trial file except the pieces was cleaned up.
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: jobDir.path).filter { $0.hasPrefix("chunk0-") })
        XCTAssertEqual(left, Set(pieces.map(\.url.lastPathComponent)))

        // fixDips off: one piece, no extra encodes.
        let enc2 = DipEncoder(bad: Set(frames[badRange].map(ObjectIdentifier.init)), full: frames.count, ffmpeg: try Self.ffmpegPath)
        target.fixDips = false
        EncodeMonitor.shared.reset(target: target, chunks: [0..<frames.count], totalFrames: frames.count)
        let one = try await TargetQualityEncoder(engine: ExportEngine()).encode(
            frames: frames, chunkID: 0, start: 0, sceneStats: scene, interpolatedShare: 0, kind: .realLife,
            encodeOne: { try await enc2.encode($0, $1, $2) }, target: target, rate: (24, 1), workDir: jobDir, threads: 4,
            codec: .hevc12, hdr: false)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(enc2.calls.count, 1)
        try? FileManager.default.removeItem(at: jobDir)
    }

    // MARK: - EncodeMonitor

    func testEncodeMonitorProjectionBlendsForecastAndMeasurement() {
        let m = EncodeMonitor.shared
        m.reset(target: QualityTarget(), chunks: [0..<10, 10..<200], totalFrames: 200)
        // The forecast belongs to the caller (AppModel sets it just before an export starts; reset happens inside
        // the export), so reset() keeps it. With no forecast there's no projection.
        m.forecast = nil
        XCTAssertEqual(m.chunks.map(\.state), [.waiting, .waiting])
        XCTAssertNil(m.projectedBytes)
        m.forecast = SizeForecast(low: 800_000, mid: 1_000_000, high: 1_200_000, videoMid: 1_000_000, otherBytes: 0, sourceBytes: 5_000_000,
                                  method: .quick, learnedFrom: 0, key: "t")
        XCTAssertEqual(m.projectedBytes, 1_000_000, "nothing done yet: the forecast")
        m.update(0) { $0.state = .done; $0.bytes = 20_000 }          // 2 000 bytes/frame → 400 000 measured
        let w = min(1, 10.0 / 200 * 3)
        XCTAssertEqual(Double(m.projectedBytes!), 400_000 * w + 1_000_000 * (1 - w), accuracy: 1)
        m.update(1) { $0.state = .done; $0.bytes = 380_000 }
        XCTAssertEqual(m.projectedBytes, 400_000, "everything measured: the forecast no longer counts")
        XCTAssertEqual(m.encodedBytes, 400_000)
        m.update(99) { $0.state = .failed }                           // unknown chunk: ignored
        XCTAssertEqual(m.chunks.count, 2)
        m.forecast = nil
        m.reset(target: nil, chunks: [], totalFrames: 0)
    }

    // MARK: - Size forecast vs the real encode

    func testQuickAndSampledForecastAgainstActualHEVCExport() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.clip("cq-forecast.mp4", size: "640x360", shots: [("testsrc2", 2), ("mandelbrot", 2)])
        var job = try await Self.makeJob(src, delivery: .sdr, codec: .hevc, out: "cq-forecast.mov")
        job.quality = 0.6
        XCTAssertGreaterThanOrEqual(job.analysis.scenes.count, 2)
        let sizes = await StreamSizes.probe(job.descriptor)
        XCTAssertEqual(sizes.total, Self.size(src))
        XCTAssertGreaterThan(sizes.video, sizes.total / 2)
        let engine = ExportEngine()
        let r = try await engine.forecastSamples(job, sampleCount: 2, progress: ProgressReporter(task: nil))
        XCTAssertEqual(r.outputFrames, 96)
        XCTAssertEqual(r.sampleFrames, 48)
        XCTAssertEqual(r.sceneOutputFrames.values.reduce(0, +), 96)
        XCTAssertEqual(r.samples.count, 2, "one sample per contrasting scene")
        for s in r.samples { XCTAssertGreaterThan(s.bytesPerFrame, 0) }
        let sampled = SizeForecaster.fromSamples(r.samples, analysis: job.analysis, sceneOutputFrames: r.sceneOutputFrames,
                                                 chunkFrames: r.chunkFrames, sampleFrames: r.sampleFrames, codec: .hevc, kind: .realLife,
                                                 source: sizes, carryOther: false, key: "cq")
        let quick = SizeForecaster.quick(width: 640, height: 360, outputFrames: 96, outputFps: 24, codec: .hevc, kind: .realLife,
                                         grainSynthesis: false, target: nil, quality: job.quality, bitDepth: 10, chroma: .c420,
                                         source: sizes, carryOther: false, key: "cq")
        let url = try await engine.run(job) { _, _ in }
        let actual = Self.size(url)
        XCTAssertEqual(try EndToEndTests.probe(url).frames, 96)
        let sErr = Double(sampled.mid - actual) / Double(actual) * 100, qErr = Double(quick.mid - actual) / Double(actual) * 100
        Self.report(String(format: "HEVC q0.6 forecast: actual %d, sampled %d (%.1f%%, range %d–%d), quick %d (%.1f%%)",
                           Int(actual), Int(sampled.mid), sErr, Int(sampled.low), Int(sampled.high), Int(quick.mid), qErr))
        XCTAssertEqual(sampled.method, .sampled)
        XCTAssertLessThan(sampled.low, sampled.mid); XCTAssertLessThan(sampled.mid, sampled.high)
        XCTAssertLessThan(abs(sErr), 35, "sampled forecast should land within ±35% on a 4-second clip")
        XCTAssertGreaterThan(quick.mid, 0)
    }

    func testSampledForecastForAV1QualityTargetAgainstActual() async throws {
        try Self.requireVMAFCLI()
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try Self.clip("cq-forecast-av1.mp4", size: "480x270", shots: [("testsrc2", 2), ("mandelbrot", 2)])
        var job = try await Self.makeJob(src, delivery: .sdr, codec: .av1, out: "cq-forecast-av1.mkv")
        job.qualityTarget = Self.vmafOnly(90)
        let sizes = await StreamSizes.probe(job.descriptor)
        let engine = ExportEngine()
        let r = try await engine.forecastSamples(job, sampleCount: 2, progress: ProgressReporter(task: nil))
        XCTAssertEqual(r.samples.count, 2)
        XCTAssertTrue(EncodeMonitor.shared.chunks.isEmpty, "forecast sampling leaves the monitor clean")
        let sampled = SizeForecaster.fromSamples(r.samples, analysis: job.analysis, sceneOutputFrames: r.sceneOutputFrames,
                                                 chunkFrames: r.chunkFrames, sampleFrames: r.sampleFrames, codec: .av1, kind: .realLife,
                                                 source: sizes, carryOther: false, key: "cq")
        let quick = SizeForecaster.quick(width: 480, height: 270, outputFrames: 96, outputFps: 24, codec: .av1, kind: .realLife,
                                         grainSynthesis: false, target: job.qualityTarget, quality: job.quality, bitDepth: 10, chroma: .c420,
                                         source: sizes, carryOther: false, key: "cq")
        let url = try await engine.run(job) { _, _ in }
        let actual = Self.size(url)
        let sErr = Double(sampled.mid - actual) / Double(actual) * 100, qErr = Double(quick.mid - actual) / Double(actual) * 100
        Self.report(String(format: "AV1 VMAF90 forecast: actual %d, sampled %d (%.1f%%), quick %d (%.1f%%)", Int(actual), Int(sampled.mid), sErr, Int(quick.mid), qErr))
        XCTAssertLessThan(abs(sErr), 40, "sampled forecast for a VMAF-target AV1 export should be within ±40%")
    }

    func testForecastLearningCorrectsAndPersists() throws {
        let key = ForecastLearner.key(.vvc, .screenContent, .quick)
        XCTAssertEqual(key, "vvc-screenContent-q")
        let before = ForecastLearner.shared.correction(key)
        try XCTSkipIf(before.count != 0, "this Mac already has learning for \(key)")
        func q() -> SizeForecast {
            SizeForecaster.quick(width: 1920, height: 1080, outputFrames: 2400, outputFps: 24, codec: .vvc, kind: .screenContent,
                                 grainSynthesis: false, target: nil, quality: 0.8, bitDepth: 10, chroma: .c420,
                                 source: StreamSizes(total: 1, video: 1, other: 0), carryOther: false, key: "")
        }
        let base = q()
        XCTAssertEqual(base.learnedFrom, 0)
        ForecastLearner.shared.record(key, forecast: 1_000, actual: 1_200)
        ForecastLearner.shared.record(key, forecast: 1_000, actual: 1_300)
        XCTAssertEqual(ForecastLearner.shared.correction(key).factor, 1, "fewer than 3 finished encodes: no correction yet")
        ForecastLearner.shared.record(key, forecast: 1_000, actual: 1_250)
        ForecastLearner.shared.record(key, forecast: 0, actual: 1_250)        // ignored
        let c = ForecastLearner.shared.correction(key)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.factor, 1.25, accuracy: 1e-9, "median ratio")
        XCTAssertEqual(c.spread ?? 0, 0.06, accuracy: 1e-9)
        let learned = q()
        XCTAssertEqual(Double(learned.videoMid) / Double(base.videoMid), 1.25, accuracy: 0.001)
        XCTAssertEqual(learned.learnedFrom, 3)
        XCTAssertEqual(Double(learned.low) / Double(learned.mid), 0.94, accuracy: 0.001, "learned spread replaces the ±32% default")
        // Persisted to disk.
        let file = CQState.support.appendingPathComponent("forecast-learning.json")
        let onDisk = try JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk[key]?.map { ($0 * 100).rounded() / 100 }, [1.2, 1.3, 1.25])
    }

    // MARK: - QualityPredictor

    func testQualityPredictorLearnsAndPersists() throws {
        let key = "cq-test-\(UUID().uuidString.prefix(8))"
        XCTAssertNil(QualityPredictor.shared.predict(codecKey: key, x: [1]))
        var rng = SystemRandomNumberGenerator()
        func sample() -> (x: [Double], y: Double) {
            let stops = Float(Double.random(in: -3...0, using: &rng))
            let target = Double.random(in: 88...97, using: &rng)
            let scene = SceneStats(start: 0, end: 48, keyStops: stops, p005: -6, p50: stops, p995: 2, skinFraction: 0, avgChroma: 0.05)
            let x = QualityPredictor.features(scene: scene, interpolatedShare: 0, pixels: 1920 * 1080, kind: .anime, target: target)
            return (x, -30 - 2 * (target - 95) + 3 * Double(stops))     // a lower CRF for higher targets and darker scenes
        }
        for i in 0..<30 {
            let s = sample()
            QualityPredictor.shared.record(codecKey: key, x: s.x, level: s.y)
            if i == 10 { XCTAssertNil(QualityPredictor.shared.predict(codecKey: key, x: s.x), "needs 12 samples before predicting") }
        }
        XCTAssertEqual(QualityPredictor.shared.sampleCounts[key], 30)
        var worst = 0.0
        for _ in 0..<10 {
            let s = sample()
            let p = try XCTUnwrap(QualityPredictor.shared.predict(codecKey: key, x: s.x))
            worst = max(worst, abs(p - s.y))
        }
        Self.report(String(format: "predictor worst error %.2f levels", worst))
        XCTAssertLessThan(worst, 1.0, "ridge fit should recover a linear rule within one encoder step")
        let file = CQState.support.appendingPathComponent("quality-predictor.json")
        let onDisk = try JSONDecoder().decode([String: [QualityPredictor.Sample]].self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk[key]?.count, 30, "samples persist between sessions")
    }

    // MARK: - EncodePlanner and EncodeRecipes against the real encoders

    func testPlanModesWithInstalledEncoders() throws {
        try CQState.withoutCalibration(.av1, .realLife) {
            func plan(_ mode: PlanMode, budget: Double = 3600, overrides: [String: Bool] = [:]) -> EncodePlan {
                EncodePlanner.plan(codec: .av1, kind: .realLife, frames: 2400, width: 1920, height: 1080, vmafMode: true,
                                   renderFps: 60, mode: mode, budget: budget, overrides: overrides, metricSecondsPerFrame: 0.004)
            }
            let fastest = plan(.fastest), best = plan(.bestForMac), maximum = plan(.maximum)
            XCTAssertLessThanOrEqual(fastest.seconds, best.seconds)
            XCTAssertLessThanOrEqual(best.seconds, maximum.seconds)
            XCTAssertLessThan(fastest.saving, maximum.saving)
            XCTAssertEqual(fastest.choice.rungID, "p9")
            XCTAssertFalse(fastest.measured)
            XCTAssertTrue(fastest.notes.contains { $0.contains("Measure on this Mac") })
            for b: Double in [600, 3600, 21_600, 172_800] {
                let p = plan(.budget, budget: b)
                XCTAssertTrue(p.seconds <= b || p.seconds == fastest.seconds, "budget \(b): plan takes \(p.seconds)")
                XCTAssertGreaterThanOrEqual(p.saving, fastest.saving)
            }
            XCTAssertGreaterThanOrEqual(plan(.budget, budget: 48 * 3600).saving, plan(.budget, budget: 3600).saving)
            for p in [fastest, best, maximum] {
                let offered = Dictionary(uniqueKeysWithValues: p.options.map { ($0.id, $0) })
                var expectedArgs: [String] = []
                for id in p.choice.optionIDs {
                    let o = try XCTUnwrap(offered[id], "\(id) enabled but not offered")
                    XCTAssertTrue(EncodeRecipes.available(o, codec: .av1))
                    expectedArgs += o.args
                }
                XCTAssertEqual(p.choice.extraArgs, expectedArgs)
                XCTAssertEqual(Set(p.choice.optionIDs), p.enabled)
                if let u = p.upgrade { XCTAssertGreaterThan(u.extraSeconds, 0); XCTAssertGreaterThan(u.smallerFraction, 0.01) }
                Self.report(String(format: "AV1 plan %@: %@ +%@ ~%.0fs saving %.3f", p.choice.rungLabel, p.headline,
                                   p.choice.optionIDs.joined(separator: ","), p.seconds, p.saving))
            }
            if ToolLocator.isAvailable("aomenc") {
                XCTAssertTrue(EncodeRecipes.recipe(codec: .av1, kind: .realLife).rungs.filter { $0.encoderKey == "aomenc" }
                              .allSatisfy { EncodeRecipes.available($0, codec: .av1) })
            }
            // Overrides force an extra on (or off).
            XCTAssertTrue(plan(.fastest, overrides: ["sharp": true]).enabled.contains("sharp"))
            XCTAssertFalse(plan(.maximum, overrides: ["varboost": false]).enabled.contains("varboost"))
        }
        // Hardware HEVC: one rung, no "measure" note.
        let hw = EncodePlanner.plan(codec: .hevc, kind: .realLife, frames: 2400, width: 1920, height: 1080, vmafMode: false,
                                    renderFps: 60, mode: .maximum, budget: 3600, overrides: [:])
        XCTAssertEqual(hw.choice.rungID, "vt")
        XCTAssertFalse(hw.notes.contains { $0.contains("Measure on this Mac") })
        // AV2 plans with or without avmenc (the export itself refuses without it), always naming a real --cpu-used
        // value. AVM is so slow that a 10-second 1080p clip outgrows an hour even at speed 6, so a one-hour budget
        // stays on the fastest speed.
        let av2 = EncodePlanner.plan(codec: .av2, kind: .realLife, frames: 240, width: 1920, height: 1080, vmafMode: false,
                                     renderFps: 60, mode: .bestForMac, budget: 3600, overrides: [:])
        XCTAssertTrue(["6", "5", "4"].contains(av2.choice.presetValue), av2.choice.presetValue)
        let av2Budget = EncodePlanner.plan(codec: .av2, kind: .realLife, frames: 240, width: 1920, height: 1080, vmafMode: false,
                                           renderFps: 60, mode: .budget, budget: 3600, overrides: [:])
        XCTAssertEqual(av2Budget.choice.rungID, "s6")
        XCTAssertEqual(av2Budget.choice.presetValue, "6")
    }

    func testRecipeFlagsMatchAndWorkWithTheRealEncoders() throws {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        func helpFlags(_ binary: String) throws -> Set<String> {
            let p = Process()
            p.executableURL = ToolLocator.url(for: binary)
            p.arguments = ["--help"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            let exited = p.exitSignal()
            try p.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            exited.wait()
            // Independent parse: any "--name" token, cut at the first character that can't be part of a flag name.
            var out = Set<String>()
            let re = try NSRegularExpression(pattern: "--[A-Za-z0-9][A-Za-z0-9-]*")
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) { out.insert(String(text[Range(m.range, in: text)!])) }
            return out
        }
        let in8 = Self.work.appendingPathComponent("cq-flags.y4m")
        try Self.ff(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=0.5", "-pix_fmt", "yuv420p10le", "-strict", "-1", in8.path])
        var tested: [String] = []
        let encoders: [(codec: Codec, key: String, kinds: [ContentKind])] = [
            (.av1, "svtav1", [.realLife, .realLifeHeavyGrain, .anime, .screenContent]),
            (.av1, "aomenc", [.realLife, .realLifeHeavyGrain]),
            (.hevc12, "x265", [.realLife, .anime, .realLifeHeavyGrain]),
            (.av1Pro, "aomenc", [.realLife, .oldAnime])]
        for (codec, key, kinds) in encoders {
            let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: key))
            guard ToolLocator.isAvailable(spec.binary) else { continue }
            let help = try helpFlags(spec.binary)
            let parsed = try XCTUnwrap(EncodeRecipes.supportedFlags(spec.binary))
            for kind in kinds {
                let recipe = EncodeRecipes.recipe(codec: codec, kind: kind)
                let mine = recipe.options.filter { ($0.encoderKey ?? codec.cliKey) == key }
                for o in mine {
                    if let flag = o.probeFlag {
                        XCTAssertEqual(EncodeRecipes.available(o, codec: codec), help.contains(flag),
                                       "\(spec.binary) \(flag): offered=\(EncodeRecipes.available(o, codec: codec)) but --help lists it=\(help.contains(flag))")
                        XCTAssertEqual(parsed.contains(flag), help.contains(flag))
                    }
                }
                // Every offered extra (bar the measured grain table, which needs a file) must be accepted by the encoder.
                let args = mine.filter { EncodeRecipes.available($0, codec: codec) && !$0.args.contains { $0.contains("{") } }.flatMap(\.args)
                let out = Self.work.appendingPathComponent("cq-flags-\(key)-\(kind.rawValue).\(spec.ext)")
                let exe = ToolLocator.url(for: spec.binary)!.path
                switch key {
                case "svtav1":
                    try Self.run(exe, ["-i", in8.path, "-b", out.path, "--preset", "12", "--crf", "45", "--input-depth", "10"] + args)
                case "aomenc":
                    try Self.run(exe, [in8.path, "--ivf", "-o", out.path, "--cpu-used=9", "--end-usage=q", "--cq-level=50",
                                       "--bit-depth=10", "--input-bit-depth=10", "--profile=0",
                                       "--rt", "--limit=6"] + args)
                default:
                    try Self.run(exe, ["--input", in8.path, "--y4m", "--output", out.path, "--preset", "ultrafast", "--crf", "35",
                                       "--output-depth", "10", "--log-level", "error"] + args)
                }
                let frames = try EndToEndTests.probe(out).frames
                XCTAssertGreaterThan(frames, 0, "\(spec.binary) with \(args.joined(separator: " ")) produced no decodable video")
                tested.append("\(spec.binary)/\(kind.rawValue): \(args.joined(separator: " "))")
            }
        }
        _ = ffmpeg
        // The catalog's own libaom command line, fed through stdin as the app does it, must encode every frame.
        // (libaom defaults to two passes, and a second pass over a pipe silently gets nothing.)
        if let spec = EncoderCatalog.shared.spec(for: "aomenc"), let exe = ToolLocator.url(for: spec.binary) {
            let out = Self.work.appendingPathComponent("cq-aom-spec.ivf")
            let args = spec.render(["in": spec.inputArg, "out": out.path, "preset": "9", "quality": "50", "bits": "10", "aom_profile": "0",
                                    "threads": "4", "cp_name": "bt709", "tc_name": "bt709", "mc_name": "bt709"], hdr: false)
            try Self.run(exe.path, args, stdin: in8)
            XCTAssertEqual(try EndToEndTests.probe(out).frames, 12, "libaom from stdin must encode every frame: \(args.joined(separator: " "))")
        }
        for t in tested { Self.report("flags OK " + t) }
        XCTAssertFalse(tested.isEmpty)
        // A flag the encoder doesn't know is filtered out; an encoder that isn't installed never blocks the recipe.
        let fake = EncodeOption(id: "fake", title: "", detail: "", args: ["--no-such-flag"], probeFlag: "--no-such-flag-xyz")
        if Codec.av1.available { XCTAssertFalse(EncodeRecipes.available(fake, codec: .av1)) }
        if ToolLocator.isAvailable("avmenc") {
            XCTAssertTrue(EncodeRecipes.supportedFlags("avmenc")?.contains("--cpu-used") == true, "avmenc --help should list --cpu-used")
        } else {
            XCTAssertNil(EncodeRecipes.supportedFlags("avmenc"), "AV2 encoder isn't installed")
        }
    }

    // MARK: - Measure on this Mac (ExportEngine.calibrate)

    func testCalibrateMeasuresSpeedAndSavingOnATinyClip() async throws {
        try Self.requireVMAFCLI()
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try Self.clip("cq-cal.mp4", size: "320x180", shots: [("testsrc2", 1.5), ("smptehdbars", 1.5)])
        var job = try await Self.makeJob(src, delivery: .sdr, codec: .av1, out: "cq-cal.mkv")
        job.contentKind = .realLife
        XCTAssertTrue(job.analysis.scenes.contains { $0.end - $0.start >= 30 }, "calibration needs scenes of 30+ frames")
        try await CQState.withoutCalibrationAsync(.av1, .realLife) {
            let t0 = Date()
            let cal: EncodeCalibration
            do { cal = try await ExportEngine().calibrate(job, target: 95, progress: ProgressReporter(task: nil)) }
            catch { Self.report("calibrate threw \(String(reflecting: error))"); throw error }
            var expected: Set<String> = ["p8", "p5", "p3", "p2"]
            if ToolLocator.isAvailable("aomenc") { expected.insert("aom4") }
            XCTAssertEqual(Set(cal.rungs.keys), expected)
            for (id, r) in cal.rungs {
                XCTAssertGreaterThan(r.fps1080, 0, id)
                XCTAssertTrue((0...0.6).contains(r.saving), "\(id) saving \(r.saving) is implausible (seeds top out near 0.24)")
            }
            XCTAssertGreaterThan(try XCTUnwrap(cal.vmafFps1080), 0)
            XCTAssertGreaterThan(cal.rungs["p8"]!.fps1080, cal.rungs["p2"]!.fps1080, "preset 8 is faster than preset 2")
            Self.report(String(format: "calibrate %.1fs: ", Date().timeIntervalSince(t0)) + cal.rungs.sorted { $0.key < $1.key }
                .map { String(format: "%@ %.1ffps saving %.3f", $0.key, $0.value.fps1080, $0.value.saving) }.joined(separator: "; ")
                + String(format: "; VMAF %.1ffps", cal.vmafFps1080 ?? 0))
            // Saved and picked up by the planner.
            let loaded = try XCTUnwrap(EncodeCalibration.load(.av1, .realLife))
            XCTAssertEqual(Set(loaded.rungs.keys), expected)
            let plan = EncodePlanner.plan(codec: .av1, kind: .realLife, frames: 2400, width: 1920, height: 1080, vmafMode: true,
                                          renderFps: 60, mode: .fastest, budget: 3600, overrides: [:])
            XCTAssertTrue(plan.measured)
            XCTAssertFalse(plan.notes.contains { $0.contains("Measure on this Mac") })
        }
        // Hardware HEVC has nothing to measure.
        var hw = job; hw.codec = .hevc
        do { _ = try await ExportEngine().calibrate(hw, target: 95, progress: ProgressReporter(task: nil)); XCTFail("expected unsupported") }
        catch LumoraError.unsupported(let s) { XCTAssertTrue(s.contains("hardware")) }
    }

    // MARK: - AV2 (not installed) is reported cleanly

    func testMissingAV2EncoderIsReportedCleanly() async throws {
        try XCTSkipIf(ToolLocator.isAvailable("avmenc"), "avmenc is installed on this Mac")
        XCTAssertFalse(Codec.av2.available)
        let src = try Self.clip("cq-cal.mp4", size: "320x180", shots: [("testsrc2", 1.5), ("smptehdbars", 1.5)])
        var job = try await Self.makeJob(src, delivery: .sdr, codec: .av2, out: "cq-av2.obu")
        job.qualityTarget = Self.vmafOnly(93)
        let msg = try XCTUnwrap(ExportEngine.validate(job))
        XCTAssertTrue(msg.contains("isn't installed"), msg)
        do { _ = try await ExportEngine().run(job) { _, _ in }; XCTFail("expected a refusal") }
        catch LumoraError.unsupported(let s) { XCTAssertEqual(s, msg) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.outputURL.path))
        try TestHardware.requireGPU()
        do { _ = try await ExportEngine().calibrate(job, target: 95, progress: ProgressReporter(task: nil)); XCTFail("expected missingTool") }
        catch LumoraError.missingTool(let t) { XCTAssertEqual(t, "avmenc") }
        XCTAssertNil(EncodeCalibration.load(.av2, .realLife))
    }
}

private extension Data {
    /// Fills 16-bit little-endian samples with one value.
    func withGray(_ v: UInt16) -> Data {
        var d = self
        d.withUnsafeMutableBytes { p in
            let s = p.bindMemory(to: UInt16.self)
            for i in s.indices { s[i] = v.littleEndian }
        }
        return d
    }
}

/// Snapshot/restore of the learning files the tests write in Application Support.
enum CQState {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
    private static var files: [String: Data?] = [:]
    private static var folders: [String: Set<String>] = [:]
    private static let lock = NSLock()

    static func snapshot(_ rel: String) {
        lock.lock(); defer { lock.unlock() }
        // updateValue: assigning a nil Data? through the subscript would drop the key, and an absent file would never be removed.
        files.updateValue(try? Data(contentsOf: support.appendingPathComponent(rel)), forKey: rel)
    }

    static func snapshotFolder(_ rel: String) {
        lock.lock(); defer { lock.unlock() }
        folders[rel] = Set((try? FileManager.default.contentsOfDirectory(atPath: support.appendingPathComponent(rel).path)) ?? [])
    }

    static func restoreAll() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        for (rel, data) in files {
            let url = support.appendingPathComponent(rel)
            if let data { try? data.write(to: url) } else { try? fm.removeItem(at: url) }
        }
        // Only remove what these tests created: manifests for outputs in our temp folder, calibrations are restored per test.
        for (rel, before) in folders {
            let dir = support.appendingPathComponent(rel)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !before.contains(name) && name.contains("LumoraCQ_") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private static func calibrationURL(_ c: Codec, _ k: ContentKind) -> URL {
        support.appendingPathComponent("Calibration/\(EncodeCalibration.key(c, k)).json")
    }

    /// Runs `body` with no calibration for this codec/kind, then puts back whatever was there.
    static func withoutCalibration(_ c: Codec, _ k: ContentKind, _ body: () throws -> Void) throws {
        let url = calibrationURL(c, k)
        let saved = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        defer { if let saved { try? saved.write(to: url) } else { try? FileManager.default.removeItem(at: url) } }
        try body()
    }

    static func withoutCalibrationAsync(_ c: Codec, _ k: ContentKind, _ body: () async throws -> Void) async throws {
        let url = calibrationURL(c, k)
        let saved = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        defer { if let saved { try? saved.write(to: url) } else { try? FileManager.default.removeItem(at: url) } }
        try await body()
    }
}
