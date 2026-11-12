import XCTest
@testable import Lumora

/// ColorVideoVDP, PU21-PSNR and SSIMULACRA 2, end to end: installed through Lumora's own path (Model Lab for the
/// Python metrics, scripts/install-ssimulacra2.sh for SSIMULACRA 2), scored on real footage in SDR and HDR10, and
/// run as gates of the "Imperceptible" standard during real quality-target exports.
///
/// Model Lab installs from PyPI the first time (skipped with LUMORA_SKIP_MODEL_LAB=1, or when it is already
/// installed; LUMORA_INSTALL_METRICS=1 forces a reinstall).
@MainActor
final class PerceptualMetricsTests: XCTestCase {

    nonisolated override class func setUp() {
        super.setUp()
        CQState.snapshot("quality-predictor.json")
        CQState.snapshot("forecast-learning.json")
        CQState.snapshotFolder("Manifests")
    }

    nonisolated override class func tearDown() {
        CQState.restoreAll()
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// Inside CampaignQualityTests' folder, so export manifests written for these outputs are cleaned up with its own.
    nonisolated static let work: URL = {
        let d = CampaignQualityTests.work.appendingPathComponent("pm", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let bench = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/Lumora-Bench/preset-clips")

    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static func report(_ s: String) { print("PMREPORT " + s) }

    // MARK: - Installation through Model Lab

    func testInstallMetricsThroughModelLab() async throws {
        let py = ModelLab.lab.appendingPathComponent("venv/bin/python")
        let force = Self.env["LUMORA_INSTALL_METRICS"] == "1"
        if !force && MetricSuite.pythonMetricsReady {
            // Already installed: check what is there instead of reinstalling.
        } else {
            if Self.env["LUMORA_SKIP_MODEL_LAB"] == "1" { throw XCTSkip("LUMORA_SKIP_MODEL_LAB=1") }
            let t0 = Date()
            do {
                try await ModelLab.shared.installMetrics()
            } catch {
                XCTFail("installMetrics failed: \(error.localizedDescription) (pip output is in ~/Library/Logs/Lumora)")
                throw error
            }
            Self.report(String(format: "installMetrics took %.0f s", Date().timeIntervalSince(t0)))
        }
        XCTAssertTrue(MetricSuite.pythonMetricsReady)
        XCTAssertTrue(QualityMetric.cvvdp.isAvailable)
        XCTAssertTrue(QualityMetric.puPsnr.isAvailable)
        let marker = try String(contentsOf: ModelLab.metricsMarker, encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), "cvvdp \(ModelLab.cvvdpVersion)")
        // The pinned release is what's installed, and the unrelated source-only "ffmpeg" package is not: the
        // `ffmpeg` module pycvvdp imports is ffmpeg-python's.
        let probe = try CampaignQualityTests.run(py.path, ["-I", "-c", """
            import importlib.metadata as m, ffmpeg, pycvvdp
            names = {d.metadata['Name'].lower() for d in m.distributions()}
            print(m.version('cvvdp'), 'ffmpeg' in names, hasattr(ffmpeg, 'input'), m.version('torch'))
            """])
        let parts = probe.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        Self.report("installed: cvvdp \(parts[0]), torch \(parts[3])")
        XCTAssertEqual(parts[0], ModelLab.cvvdpVersion)
        XCTAssertEqual(parts[1], "False", "the source-only 'ffmpeg' PyPI package must not be installed")
        XCTAssertEqual(parts[2], "True", "`import ffmpeg` must be ffmpeg-python")
    }

    // MARK: - Fixtures (real footage from the local benchmark cache)

    static func requireMetrics(_ metrics: [QualityMetric]) throws {
        for m in metrics where !m.isAvailable { throw XCTSkip("\(m.displayName) isn't installed (\(m.source))") }
    }

    static func ff(_ args: [String]) throws { try CampaignQualityTests.ff(args) }

    /// The first `frames` frames of a benchmark clip as 10-bit 4:2:0 Y4M: the master the metrics compare against.
    static func master(_ name: String, frames: Int = 48) throws -> URL {
        let src = bench.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: src.path) else { throw XCTSkip("benchmark clip \(name) not in the benchmark cache") }
        let out = work.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(frames).y4m")
        if !FileManager.default.fileExists(atPath: out.path) {
            try ff(["-i", src.path, "-frames:v", "\(frames)", "-pix_fmt", "yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", out.path])
        }
        return out
    }

    /// x265 10-bit copy (optionally filtered first), or a lossless FFV1 copy without a CRF; as MKV and as Y4M.
    static func distorted(_ master: URL, tag: String, crf: Int?, filter: String? = nil) throws -> (mkv: URL, y4m: URL) {
        let mkv = work.appendingPathComponent("\(master.deletingPathExtension().lastPathComponent)-\(tag).mkv")
        let y4m = mkv.deletingPathExtension().appendingPathExtension("y4m")
        var args = ["-i", master.path]
        if let filter { args += ["-vf", filter] }
        if let crf {
            args += ["-c:v", "libx265", "-preset", "fast", "-crf", "\(crf)", "-x265-params", "log-level=error:pools=4", "-pix_fmt", "yuv420p10le"]
        } else {
            args += ["-c:v", "ffv1", "-pix_fmt", "yuv420p10le"]
        }
        try ff(args + [mkv.path])
        try ff(["-i", mkv.path, "-pix_fmt", "yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", y4m.path])
        return (mkv, y4m)
    }

    static func context(_ master: URL, hdr: Bool, frames: Int, fast: Bool = false) throws -> MetricSuite.Context {
        let header = try FileHandle(forReadingFrom: master).read(upToCount: 200) ?? Data()
        let tokens = String(decoding: header, as: UTF8.self).split(separator: "\n")[0].split(separator: " ")
        let w = try XCTUnwrap(tokens.first { $0.hasPrefix("W") }.flatMap { Int($0.dropFirst()) })
        let h = try XCTUnwrap(tokens.first { $0.hasPrefix("H") }.flatMap { Int($0.dropFirst()) })
        return MetricSuite.Context(width: w, height: h, rate: (24, 1), hdr: hdr, frames: frames, threads: 8, fast: fast, workDir: work)
    }

    static func writer(_ y4m: URL) -> (FileHandle) throws -> Void {
        { h in
            let r = try FileHandle(forReadingFrom: y4m)
            defer { try? r.close() }
            while let chunk = try r.read(upToCount: 8 << 20), !chunk.isEmpty { try h.write(contentsOf: chunk) }
        }
    }

    /// Lumora's metrics helper run directly on two Y4M files (it reads files as well as pipes).
    static func helper(_ ref: URL, _ dist: URL, mode: String, frames: Int) throws -> [String: Any] {
        let script = try XCTUnwrap(Bundle.main.url(forResource: "lumora_metrics", withExtension: "py"), "helper not bundled")
        let p = Process()
        p.executableURL = ModelLab.lab.appendingPathComponent("venv/bin/python")
        p.arguments = ["-I", script.path, "--ref", ref.path, "--dist", dist.path, "--hdr", mode, "--total-frames", "\(frames)",
                       "--metrics", "cvvdp", "--windows", "6", "--threads", "4"]
        p.environment = ModelLab.pythonEnvironment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let exited = p.exitSignal()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        XCTAssertEqual(p.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], String(decoding: data, as: UTF8.self))
    }

    static func jod(_ d: [String: Any]) -> Double { (d["cvvdp"] as? [String: Any])?["mean"] as? Double ?? -1 }

    static func fmt(_ s: MetricScores) -> String {
        s.pooled.map { "\($0.key.rawValue)=\(String(format: "%.3f", $0.value.mean))" }.sorted().joined(separator: " ")
    }

    /// Scores each metric on its own (so each one's cost is visible) and merges the results.
    static func measureEach(_ set: [QualityMetric], master: URL, distorted: URL, ctx: MetricSuite.Context,
                            label: String) async throws -> MetricScores {
        var all = MetricScores()
        var costs: [String] = []
        for m in set {
            let t0 = Date()
            let s = try await MetricSuite.measure([m], reference: writer(master), distorted: distorted, ctx: ctx)
            let secs = Date().timeIntervalSince(t0)
            costs.append(String(format: "%@ %.1f s (%.0f ms/frame)", m.rawValue, secs, secs * 1000 / Double(ctx.frames)))
            all.perFrame.merge(s.perFrame) { a, _ in a }
            all.pooled.merge(s.pooled) { a, _ in a }
        }
        report("\(label): \(fmt(all)) | cost \(costs.joined(separator: ", "))")
        return all
    }

    // MARK: - SSIMULACRA 2 tool

    func testSSIMULACRA2ToolIsInstalledAndReadsY4MFiles() throws {
        try Self.requireMetrics([.ssimulacra2])
        let exe = try XCTUnwrap(ToolLocator.url(for: "ssimulacra2_rs"))
        let version = try CampaignQualityTests.run(exe.path, ["--version"])
        Self.report("ssimulacra2_rs: \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertTrue(version.contains("0.5.2"), version)
        // This build reads Y4M files and named pipes itself (no VapourSynth), which is how MetricSuite feeds it.
        let master = try Self.master("la_sky_720.y4m", frames: 12)
        let out = try CampaignQualityTests.run(exe.path, ["video", master.path, master.path, "--verbose"])
        XCTAssertEqual(out.split(separator: "\n").filter { $0.hasPrefix("Frame ") }.count, 12, out)
        XCTAssertTrue(out.contains("Mean: 100.0"), out)
    }

    // MARK: - Direction: identical > mild > heavy, SDR and HDR10

    func testSDRScoresIdenticalAboveMildAboveHeavy() async throws {
        try Self.requireMetrics([.cvvdp, .puPsnr, .ssimulacra2])
        let frames = 48
        let master = try Self.master("la_sky_720.y4m", frames: frames)
        let same = try Self.distorted(master, tag: "ffv1", crf: nil)
        let mild = try Self.distorted(master, tag: "crf20", crf: 20)
        let heavy = try Self.distorted(master, tag: "crf34blur", crf: 34, filter: "boxblur=1")
        let ctx = try Self.context(master, hdr: false, frames: frames)
        let set: [QualityMetric] = [.cvvdp, .puPsnr, .ssimulacra2, .vmaf]
        let i = try await Self.measureEach(set, master: master, distorted: same.mkv, ctx: ctx, label: "SDR identical")
        let m = try await Self.measureEach(set, master: master, distorted: mild.mkv, ctx: ctx, label: "SDR crf20")
        let h = try await Self.measureEach(set, master: master, distorted: heavy.mkv, ctx: ctx, label: "SDR crf34+blur")
        for s in [i, m, h] {
            for metric in set { XCTAssertNotNil(s.pooled[metric], "\(metric.displayName) missing") }
            XCTAssertEqual(s.perFrame[.ssimulacra2]?.count, frames, "SSIMULACRA 2: one score per frame")
        }
        XCTAssertGreaterThan(i.pooled[.cvvdp]!.mean, 9.99, "identical is 10 JOD")
        XCTAssertGreaterThan(i.pooled[.ssimulacra2]!.mean, 99.9, "identical is 100")
        for metric: QualityMetric in [.cvvdp, .puPsnr, .ssimulacra2] {
            XCTAssertGreaterThan(i.pooled[metric]!.mean, m.pooled[metric]!.mean, "\(metric.displayName): identical > CRF 20")
            XCTAssertGreaterThan(m.pooled[metric]!.mean, h.pooled[metric]!.mean, "\(metric.displayName): CRF 20 > CRF 34 + blur")
        }
        // The Imperceptible gates separate them: the heavy encode fails both, the identical copy passes both.
        let gates = QualityProfile.presets(hdr: false)[0].gates.filter(\.metric.slow)
        XCTAssertEqual(Set(gates.map(\.metric)), [.cvvdp, .ssimulacra2])
        for g in gates {
            XCTAssertTrue(g.passes(i.value(g)!), "\(g.metric.displayName) gate on identical")
            XCTAssertFalse(g.passes(h.value(g)!), "\(g.metric.displayName) gate on CRF 34 + blur")
        }
        // Lumora's JOD equals the helper's own SDR-display result on the same files.
        let direct = try Self.helper(master, heavy.y4m, mode: "0", frames: frames)
        XCTAssertEqual(direct["display"] as? String, "standard_4k")
        XCTAssertEqual(Self.jod(direct), h.pooled[.cvvdp]!.mean, accuracy: 0.02)
    }

    func testHDR10ScoresInHDRModeIdenticalAboveMildAboveHeavy() async throws {
        try Self.requireMetrics([.cvvdp, .puPsnr])
        let frames = 48
        let master = try Self.master("hdr_sky_720.y4m", frames: frames)       // PQ BT.2020 footage
        let same = try Self.distorted(master, tag: "ffv1", crf: nil)
        let mild = try Self.distorted(master, tag: "crf20", crf: 20)
        let heavy = try Self.distorted(master, tag: "crf32", crf: 32)
        let ctx = try Self.context(master, hdr: true, frames: frames)
        let set: [QualityMetric] = [.cvvdp, .puPsnr, .vmaf]
        let i = try await Self.measureEach(set, master: master, distorted: same.mkv, ctx: ctx, label: "HDR10 identical")
        let m = try await Self.measureEach(set, master: master, distorted: mild.mkv, ctx: ctx, label: "HDR10 crf20")
        let h = try await Self.measureEach(set, master: master, distorted: heavy.mkv, ctx: ctx, label: "HDR10 crf32")
        XCTAssertGreaterThan(i.pooled[.cvvdp]!.mean, 9.99)
        for metric: QualityMetric in [.cvvdp, .puPsnr] {
            XCTAssertGreaterThan(i.pooled[metric]!.mean, m.pooled[metric]!.mean, "\(metric.displayName): identical > CRF 20")
            XCTAssertGreaterThan(m.pooled[metric]!.mean, h.pooled[metric]!.mean, "\(metric.displayName): CRF 20 > CRF 32")
        }
        // SSIMULACRA 2 is SDR-only: asked for on HDR, it is not run.
        let s2 = try await MetricSuite.measure([.ssimulacra2], reference: Self.writer(master), distorted: heavy.mkv, ctx: ctx)
        XCTAssertNil(s2.pooled[.ssimulacra2], "SSIMULACRA 2 must not score HDR")
        // HDR mode, proven: Lumora's score equals the helper's PQ-display result and differs from what the same
        // pixels score when read as SDR (a 200-nit sRGB display). The HLG display model loads too.
        let pq = try Self.helper(master, heavy.y4m, mode: "pq", frames: frames)
        let sdr = try Self.helper(master, heavy.y4m, mode: "0", frames: frames)
        let hlg = try Self.helper(master, master, mode: "hlg", frames: 24)
        Self.report(String(format: "HDR10 crf32 JOD: Lumora %.3f, helper PQ %.3f, same pixels as SDR %.3f; HLG identical %.3f",
                           h.pooled[.cvvdp]!.mean, Self.jod(pq), Self.jod(sdr), Self.jod(hlg))
                    + "; helper seconds " + String(decoding: (try? JSONSerialization.data(withJSONObject: pq["seconds"] ?? [:], options: .sortedKeys)) ?? Data(), as: UTF8.self))
        XCTAssertEqual(pq["display"] as? String, "standard_hdr_pq")
        XCTAssertEqual(Self.jod(pq), h.pooled[.cvvdp]!.mean, accuracy: 0.02, "MetricSuite ran ColorVideoVDP in its PQ mode")
        XCTAssertGreaterThan(abs(Self.jod(pq) - Self.jod(sdr)), 0.05, "the display model must matter")
        XCTAssertEqual(hlg["display"] as? String, "standard_hdr_hlg")
        XCTAssertEqual(Self.jod(hlg), 10, accuracy: 0.01)
    }

    // MARK: - Imperceptible gates in real quality-target exports

    /// 48 frames of footage as an encoded source file: H.264 (SDR BT.709) or HEVC 10-bit (HDR10, PQ BT.2020).
    static func sourceFile(hdr: Bool) throws -> URL {
        let master = try master(hdr ? "hdr_sky_720.y4m" : "la_action_720.y4m")
        let out = work.appendingPathComponent(hdr ? "src-hdr10.mov" : "src-sdr.mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        if hdr {
            try ff(["-i", master.path, "-c:v", "libx265", "-preset", "fast", "-tag:v", "hvc1", "-pix_fmt", "yuv420p10le",
                    "-x265-params", "log-level=error:pools=4:crf=6:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                    "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", out.path])
        } else {
            try ff(["-i", master.path, "-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", out.path])
        }
        return out
    }

    static func job(_ src: URL, hdr: Bool, out: String, profile: QualityProfile) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first)
        if hdr { XCTAssertEqual(color.transfer, .pq, "the HDR10 source must be read as PQ") }
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let report = hdr ? HDRReportCard.make(title: src.lastPathComponent, descriptor: d, color: color, analysis: a) : nil
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: report)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: hdr ? .hdr10 : .sdr, codec: .hevc,
                            outputURL: work.appendingPathComponent(out))
        job.sourcePeakNits = report?.p999Nits ?? 1000
        var t = QualityTarget()
        t.profile = profile
        job.qualityTarget = t
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    struct ExportRun {
        var url: URL
        var seconds: Double
        var chunks: [EncodeMonitor.Chunk]
        var levels: [Int: Double]            // chunk start -> accepted level (from the export manifest)
        var bytes: Int64
    }

    static func export(_ src: URL, hdr: Bool, out: String, profile: QualityProfile) async throws -> ExportRun {
        let job = try await job(src, hdr: hdr, out: out, profile: profile)
        let t0 = Date()
        let url = try await ExportEngine().run(job) { _, _ in }
        let secs = Date().timeIntervalSince(t0)
        let probe = try EndToEndTests.probe(url)
        XCTAssertEqual(probe.frames, 48)
        if hdr { XCTAssertEqual(probe.transfer, "smpte2084") }
        let manifest = try XCTUnwrap(ExportManifest.load(for: url))
        let chunks = EncodeMonitor.shared.chunks
        for c in chunks { XCTAssertEqual(c.state, .done, "chunk \(c.id)") }
        let run = ExportRun(url: url, seconds: secs, chunks: chunks,
                            levels: Dictionary(manifest.chunks.map { ($0.start, $0.level) }, uniquingKeysWith: max),
                            bytes: CampaignQualityTests.size(url))
        for c in chunks {
            report(String(format: "%@ chunk %d (%d frames): %@, trials %d, gate raises %d, perceptual %.1f s, failures [%@] | %@",
                          out, c.id, c.range.count, c.setting, c.trials, c.gateRaises, c.perceptualSeconds,
                          c.failures.joined(separator: "; "),
                          c.metrics.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.sorted().joined(separator: " ")))
        }
        report(String(format: "%@: %.1f s total, %d bytes, %d chunks, perceptual checks %.1f s", out, secs, Int(run.bytes),
                      chunks.count, chunks.reduce(0) { $0 + $1.perceptualSeconds }))
        return run
    }

    /// One standard, three ways: perceptual gates off (the search and fast gates only), the shipped Imperceptible
    /// standard, and the same standard with one gate set just above what the shipped run reached, so it must fail
    /// and force a higher setting.
    private func imperceptibleExports(hdr: Bool) async throws {
        try CampaignQualityTests.requireVMAFCLI()
        try TestHardware.requireHardwareHEVC()
        let gate: QualityMetric = hdr ? .cvvdp : .ssimulacra2
        try Self.requireMetrics([.cvvdp, gate])
        let src = try Self.sourceFile(hdr: hdr)
        let tag = hdr ? "hdr10" : "sdr"
        let shipped = QualityProfile.presets(hdr: hdr)[0]
        XCTAssertEqual(shipped.name, "Imperceptible")
        XCTAssertEqual(shipped.effective().notes, [], "every Imperceptible metric is installed")
        var off = shipped
        for i in off.rules.indices where off.rules[i].metric.slow { off.rules[i].role = .off }

        let base = try await Self.export(src, hdr: hdr, out: "imp-\(tag)-gates-off.mov", profile: off)
        for c in base.chunks {
            XCTAssertNil(c.metrics["cvvdp"], "slow metrics off: not measured")
            XCTAssertEqual(c.perceptualSeconds, 0)
        }

        let real = try await Self.export(src, hdr: hdr, out: "imp-\(tag).mov", profile: shipped)
        for c in real.chunks {
            // The slow gates ran on the accepted encode of every chunk.
            let jod = try XCTUnwrap(c.metrics["cvvdp"], "chunk \(c.id): the ColorVideoVDP gate didn't run")
            XCTAssertGreaterThan(c.perceptualSeconds, 0)
            if hdr {
                XCTAssertNil(c.metrics["ssimulacra2"], "SSIMULACRA 2 is off for HDR")
            } else {
                XCTAssertNotNil(c.metrics["ssimulacra2"], "chunk \(c.id): the SSIMULACRA 2 gate didn't run")
            }
            let passed = shipped.gates.filter(\.metric.slow).allSatisfy { g in c.metrics[g.metric.rawValue].map(g.passes) ?? true }
            if c.gateRaises == 0 {
                XCTAssertTrue(passed, "chunk \(c.id) accepted without a raise but fails a gate (JOD \(jod))")
            } else {
                XCTAssertFalse(c.failures.isEmpty, "a raise records the failing gate")
            }
        }
        let checks = real.chunks.reduce(0) { $0 + $1.gateRaises + 1 }
        let perceptual = real.chunks.reduce(0) { $0 + $1.perceptualSeconds }
        let framesChecked = real.chunks.reduce(0) { $0 + ($1.gateRaises + 1) * $1.range.count }
        Self.report(String(format: "%@ timing: gates off %.1f s, Imperceptible %.1f s (%+.0f%%); %d perceptual checks, %.1f s each on average (%.0f ms per frame checked)",
                           tag, base.seconds, real.seconds, (real.seconds / base.seconds - 1) * 100, checks,
                           perceptual / Double(max(1, checks)), perceptual * 1000 / Double(max(1, framesChecked))))

        // A gate that fails: just above the best value the shipped run accepted.
        let reached = real.chunks.compactMap { $0.metrics[gate.rawValue] }.max() ?? 0
        let tight = min(gate == .cvvdp ? 9.95 : 97, reached + (gate == .cvvdp ? 0.1 : 2))
        var strict = shipped
        let gi = try XCTUnwrap(strict.rules.firstIndex { $0.metric == gate })
        strict.rules[gi].threshold = tight
        let raised = try await Self.export(src, hdr: hdr, out: "imp-\(tag)-strict.mov", profile: strict)
        let range = TargetQualityEncoder.levelRange(.hevc)
        for c in raised.chunks {
            XCTAssertGreaterThanOrEqual(c.gateRaises, 1, "chunk \(c.id): a failing \(gate.displayName) gate must raise quality")
            XCTAssertTrue(c.failures.contains { $0.hasPrefix(gate.displayName) }, "chunk \(c.id) failures: \(c.failures)")
            let level = try XCTUnwrap(raised.levels[c.range.lowerBound])
            if let before = real.levels[c.range.lowerBound] {
                XCTAssertGreaterThan(level, before, "chunk \(c.id): the strict gate must end at a higher setting")
            }
            let v = try XCTUnwrap(c.metrics[gate.rawValue])
            if level < range.high { XCTAssertGreaterThanOrEqual(v, tight, "chunk \(c.id): stopped raising before the gate passed") }
        }
        XCTAssertGreaterThan(raised.bytes, real.bytes, "more quality, more bytes")
        Self.report(String(format: "%@ strict %@ >= %.2f (shipped run reached %.2f): %d -> %d bytes, levels %@ -> %@", tag,
                           gate.displayName, tight, reached, Int(real.bytes), Int(raised.bytes),
                           real.levels.sorted { $0.key < $1.key }.map { String(format: "%.0f", $0.value) }.joined(separator: "/"),
                           raised.levels.sorted { $0.key < $1.key }.map { String(format: "%.0f", $0.value) }.joined(separator: "/")))
    }

    func testImperceptibleSDRExportRunsPerceptualGatesAndRaisesQualityWhenOneFails() async throws {
        try await imperceptibleExports(hdr: false)
    }

    func testImperceptibleHDR10ExportRunsPerceptualGatesAndRaisesQualityWhenOneFails() async throws {
        try await imperceptibleExports(hdr: true)
    }

    // MARK: - AVQT

    func testAVQTIsReportedUnavailable() throws {
        // Apple's AVQT is a developer download behind a sign-in; Lumora never fetches it.
        guard !ToolLocator.isAvailable("AVQT") else { throw XCTSkip("AVQT is installed on this Mac") }
        XCTAssertFalse(QualityMetric.avqt.isAvailable)
        XCTAssertTrue(QualityMetric.avqt.source.contains("developer.apple.com"))
        var p = QualityProfile.presets(hdr: true)[0]
        p.rules.append(MetricRule(metric: .avqt, role: .report, threshold: 4))
        let (eff, notes) = p.effective()
        XCTAssertEqual(eff.rules.first { $0.metric == .avqt }?.role, .off)
        XCTAssertTrue(notes.contains { $0.hasPrefix("AVQT (Apple) isn't installed") }, "\(notes)")
        Self.report("AVQT: available=\(QualityMetric.avqt.isAvailable); note: \(notes.first { $0.hasPrefix("AVQT") } ?? "-")")
    }
}
