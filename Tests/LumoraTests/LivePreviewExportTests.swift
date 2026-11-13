import XCTest
import Metal
@testable import Lumora

/// Real exports through the real pipeline with the render monitor attached: previews arrive, stages are timed,
/// lanes are tracked, the summary is written, and the monitor costs next to nothing. Small clips, headless.
@MainActor
final class LivePreviewExportTests: XCTestCase {
    private var savedInterval = 0.25

    override func setUp() async throws {
        try TestHardware.requireGPU()
        savedInterval = LivePreviewHub.interval
        LivePreviewHub.interval = 0.05          // several previews even in a two-second export
        LoadGovernor.shared.reset()
    }

    override func tearDown() async throws {
        LivePreviewHub.interval = savedInterval
    }

    /// Inspect → analyze → presets → job, as EndToEndTests does it.
    func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out: String) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        let job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: EndToEndTests.dir.appendingPathComponent(out))
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    func check(_ engine: ExportEngine, target: OutputTarget.Kind, wall: Double, label: String) throws -> MonitoredRun {
        let run = try XCTUnwrap(engine.probe.lastRun)
        XCTAssertTrue(run.ended)
        XCTAssertGreaterThanOrEqual(run.hub.published, 2, "previews published")
        let f = try XCTUnwrap(run.hub.frame(for: nil))
        XCTAssertEqual(f.texture.width, LivePreviewHub.width)
        XCTAssertEqual(f.texture.pixelFormat, .rgba16Float)
        XCTAssertEqual(f.target.kind, target)
        let summary = try XCTUnwrap(run.summary)
        XCTAssertEqual(summary.outcome, "finished")
        XCTAssertTrue(summary.line.contains("bottleneck "), summary.line)
        XCTAssertTrue(summary.line.contains("CPU Lumora"), summary.line)
        XCTAssertTrue(summary.line.contains("per frame decode"), summary.line)
        XCTAssertGreaterThan(summary.frames, 0)
        // The producer's measured parts (decode, upscale, pause gate, waiting on the grader) explain its wall time.
        for t in run.laneTotals() where t.kind != "trial" && t.producerWall > 0.2 {
            let explained = (t.decode + t.upscale + t.pause + t.producerBlocked) / t.producerWall
            print(String(format: "%@ lane %@: producer wall %.2f s, decode %.2f, upscale %.2f, pause gate %.2f, waiting on grader %.2f → %.0f%% explained; grader starved %.2f s, GPU %.2f s%@",
                         label, t.lane, t.producerWall, t.decode, t.upscale, t.pause, t.producerBlocked, explained * 100, t.graderStarved, t.gpu,
                         t.writerStarved.map { String(format: ", writer starved %.2f s", $0) } ?? String(format: ", engine not ready %.2f s", t.engineNotReady)))
            XCTAssertGreaterThan(explained, 0.85, "stage timings should explain the producer's time within 15%")
            XCTAssertLessThan(explained, 1.05)
        }
        let cost = run.selfCost
        print(String(format: "%@: wall %.2f s, monitor taps and ticks %.1f ms (%.3f%%: %@); summary: %@", label, wall, cost * 1000, cost / wall * 100, run.costBreakdown, summary.line))
        XCTAssertLessThan(cost, wall * 0.01, "the monitor must cost under 1% of the export")
        return run
    }

    func testHardwareHEVCPreviewAndSummary() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        let job = try await makeJob(src, delivery: .hdr10, codec: .hevc, out: "monitor-hevc.mov")
        let engine = ExportEngine()
        let t0 = Date()
        _ = try await engine.run(job) { _, _ in }
        let run = try check(engine, target: .hdr10, wall: Date().timeIntervalSince(t0), label: "HEVC")
        XCTAssertTrue(run.context.hardware)
    }

    func testSoftwareAV1PreviewAndSummary() async throws {
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .sdr, codec: .av1, out: "monitor-av1.mkv")
        job.quality = 0.5
        let engine = ExportEngine()
        let t0 = Date()
        _ = try await engine.run(job) { _, _ in }
        let run = try check(engine, target: .sdr, wall: Date().timeIntervalSince(t0), label: "SVT-AV1")
        XCTAssertNotNil(run.laneTotals().first?.writerStarved, "the CLI writer's waits are measured")
        XCTAssertTrue(run.summary?.line.contains("encoder starved") ?? false)
    }

    func testParallelSegmentsShowAsLanes() async throws {
        try TestHardware.requireHardwareHEVC()
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let src = EndToEndTests.dir.appendingPathComponent("monitor-600.mp4")
        if !FileManager.default.fileExists(atPath: src.path) {
            try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=25",
                                          "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", src.path])
        }
        let job = try await makeJob(src, delivery: .sdr, codec: .hevc, out: "monitor-lanes.mov")
        let segments = ChipProfile.current.segments(for: .hevc, frameCount: 600)
        guard segments >= 2 else { throw XCTSkip("This Mac uses one hardware encode segment") }
        let engine = ExportEngine()
        let t0 = Date()
        _ = try await engine.run(job) { _, _ in }
        let run = try check(engine, target: .sdr, wall: Date().timeIntervalSince(t0), label: "HEVC lanes")
        let lanes = run.laneTotals().filter { $0.kind == "segment" && $0.graded > 0 }
        XCTAssertGreaterThanOrEqual(lanes.count, 2, "\(lanes.map(\.lane))")
        let positions = run.snapshot.lanes.filter { $0.kind == "segment" }.compactMap(\.position)
        XCTAssertEqual(Set(positions).count, positions.count, "each lane reports its own position: \(positions)")
        XCTAssertTrue(run.snapshot.lanes.contains { $0.label.hasPrefix("Segment 2 · frames ") }, "\(run.snapshot.lanes.map(\.label))")
    }

    func testTargetQualityTrialsAreLabeled() async throws {
        guard Codec.av1.available, VMAFRunner.available else { throw XCTSkip("SVT-AV1 or VMAF not installed") }
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .sdr, codec: .av1, out: "monitor-tq.mkv")
        var target = QualityTarget()
        target.vmaf = 90; target.maxTrials = 2; target.fixDips = false
        target.profile = QualityProfile.presets(hdr: false)[0]
        job.qualityTarget = target
        let engine = ExportEngine()
        let t0 = Date()
        _ = try await engine.run(job) { _, _ in }
        let run = try XCTUnwrap(engine.probe.lastRun)
        let trials = run.snapshot.lanes.filter { $0.kind == "trial" }
        print("Target quality lanes after \(Int(Date().timeIntervalSince(t0))) s: " + run.snapshot.lanes.map(\.label).joined(separator: " | "))
        XCTAssertFalse(trials.isEmpty, "trial encodes appear as lanes")
        XCTAssertTrue(trials.allSatisfy { $0.label.contains("Chunk ") && ($0.label.contains("quality search") || $0.label.contains("perceptual")) },
                      "\(trials.map(\.label))")
        // The quality search after the last rendered frame is measured too: helpers' CPU (trial encodes, metrics,
        // many of them shorter than a sampling tick) is counted, and the run gets a verdict.
        let summary = try XCTUnwrap(run.summary)
        print("Target quality summary: " + summary.line)
        XCTAssertGreaterThan(summary.encoderCores, 0.05, summary.line)
        XCTAssertNotEqual(summary.bottleneckKind, Bottleneck.measuring.rawValue, summary.line)
    }

    /// Measuring film grain renders three frames before the export; they are not lanes, so the real segments are
    /// numbered from 1 and none shows as a phantom finished segment.
    func testGrainMeasurementAddsNoLanes() async throws {
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .sdr, codec: .av1, out: "monitor-grain.mkv")
        job.quality = 0.5
        job.filmTexture = .fine
        XCTAssertTrue(ExportEngine.grainRoles(job).texture)
        let engine = ExportEngine()
        _ = try await engine.run(job) { _, _ in }
        let run = try XCTUnwrap(engine.probe.lastRun)
        let lanes = run.snapshot.lanes
        print("Grain export lanes: " + lanes.map { "\($0.label) \($0.detail)" }.joined(separator: " | "))
        let segments = ChipProfile.current.segments(for: .av1, frameCount: run.totalFrames)
        XCTAssertEqual(lanes.count, segments, "\(lanes.map(\.label))")
        XCTAssertTrue(lanes.first?.label.hasPrefix("Segment 1 · frames 0–") ?? false, "\(lanes.map(\.label))")
        XCTAssertTrue(run.laneTotals().allSatisfy { $0.graded > 0 }, "a lane with no frames: \(run.laneTotals().map(\.lane))")
    }

    /// Responsiveness before and during an export (reported; loose limits because the Mac is shared).
    func testResponsivenessDuringExport() async throws {
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let probe = ResponsivenessProbe.shared
        probe.resetReadings()
        probe.retain()
        defer { probe.release() }
        try await Task.sleep(nanoseconds: 3_000_000_000)          // baseline, nothing rendering
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .hdr10, codec: .av1, out: "monitor-resp.mkv")
        job.quality = 0.5
        _ = try await ExportEngine().run(job) { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)
        let r = probe.report
        print(String(format: "Responsiveness: main thread idle p50 %.1f / p95 %.1f / max %.1f ms (%d), during export p50 %.1f / p95 %.1f / max %.1f ms (%d); user-interactive wake idle p95 %.1f, during %.1f ms; GPU round trip idle p95 %.1f, during %.1f ms",
                     r.mainIdle.p50, r.mainIdle.p95, r.mainIdle.max, r.mainIdle.count, r.mainBusy.p50, r.mainBusy.p95, r.mainBusy.max, r.mainBusy.count,
                     r.wakeIdle.p95, r.wakeBusy.p95, r.gpuIdle.p95, r.gpuBusy.p95))
        XCTAssertGreaterThan(r.mainIdle.count, 5)
        XCTAssertGreaterThan(r.mainBusy.count, 5)
        XCTAssertLessThan(r.mainBusy.p95, 100, "the UI thread must keep answering during an export")
        XCTAssertLessThan(r.mainBusy.max, 500, "no hang over half a second")
    }

    /// A longer real export (8 s of 720p; SVT-AV1, or LUMORA_MONITOR_CODEC=av1Pro etc.) long enough for a verdict;
    /// prints what the monitor showed each second and the summary. On demand only: LUMORA_MONITOR_MEASURE=1.
    func testMeasuredVerdictOnLongerExport() async throws {
        guard ProcessInfo.processInfo.environment["LUMORA_MONITOR_MEASURE"] == "1" else { throw XCTSkip("Measurement run on demand") }
        guard Codec.av1.available, let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("SVT-AV1 or FFmpeg not installed") }
        LivePreviewHub.interval = 0.25
        let src = EndToEndTests.dir.appendingPathComponent("monitor-8s.mp4")
        if !FileManager.default.fileExists(atPath: src.path) {
            try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=8",
                                          "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", src.path])
        }
        let codec = Codec(rawValue: ProcessInfo.processInfo.environment["LUMORA_MONITOR_CODEC"] ?? "") ?? .av1
        guard codec.available else { throw XCTSkip("\(codec.displayName) not installed") }
        var job = try await makeJob(src, delivery: .hdr10, codec: codec, out: "monitor-8s.mkv")
        job.quality = 0.8
        let engine = ExportEngine()
        let t0 = Date()
        let export = Task { try await engine.run(job) { _, _ in } }
        var seen: [String] = []
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let run = engine.probe.lastRun else { continue }
            let s = run.snapshot
            let line = String(format: "t=%.0fs %@ · %@ · score %@ · CPU %.1f (Lumora %.1f, encoders %.1f, others %.1f) · GPU %@ · %.1f fps",
                              Date().timeIntervalSince(t0), s.status.text, s.verdict.headline, s.verdict.score.map { "\(Int($0 * 100))%" } ?? "–",
                              s.sample.busyCores, s.sample.selfCores, s.sample.childCores, s.sample.othersCores,
                              s.sample.gpuDevice.map { "\(Int($0 * 100))%" } ?? "n/a", s.fps)
            seen.append(line)
            print("Monitor: " + line)
            if run.ended { break }
        }
        _ = try await export.value
        let run = try XCTUnwrap(engine.probe.lastRun)
        print("Measured export: \(run.costBreakdown); summary: \(run.summary?.line ?? "none")")
        XCTAssertNotNil(run.summary)
    }
}
