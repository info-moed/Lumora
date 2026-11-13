import XCTest
@testable import Lumora

/// SVT-AV1 preset tuning (docs/encoding/tuning-svtav1.md). The unit tests pin the measured decisions; the export
/// tests run the real ExportEngine with the tuned planner choice on short generated clips, then check each file
/// with ffprobe, the encoder command line Lumora logged, and Lumora's own metrics against a ProRes 4444 XQ export
/// of the same job (same grade, near-lossless).
@MainActor
final class SVTAV1TuningTests: XCTestCase {

    // MARK: - Measured decisions

    func testParallelismIsALevelNotAThreadCount() throws {
        var last = 0
        for cores in 1...128 {
            let level = EncodeRecipes.svtParallelism(cores: cores)
            XCTAssertTrue((1...6).contains(level), "\(cores) cores -> --lp \(level)")
            XCTAssertGreaterThanOrEqual(level, last, "more cores never lower the level")
            last = level
        }
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "svtav1"))
        for cores in [1, 3, 7, 14, 24] {
            let args = spec.render(["threads": "\(cores)"], hdr: false)
            let i = try XCTUnwrap(args.firstIndex(of: "--lp"))
            XCTAssertEqual(args[i + 1], "\(EncodeRecipes.svtParallelism(cores: cores))")
        }
        // Other encoders still receive a thread count.
        let x265 = try XCTUnwrap(EncoderCatalog.shared.spec(for: "x265"))
        XCTAssertTrue(x265.render(["threads": "14"], hdr: false).contains { $0.contains("14") })
    }

    func testLuminanceBiasNeverReachesPQ() {
        let args = ["--enable-variance-boost", "1", "--enable-qm", "1", "--qm-min", "6", "--luminance-qp-bias", "25", "--sharpness", "1"]
        XCTAssertEqual(EncodeRecipes.svtArgs(args, pq: true),
                       ["--enable-variance-boost", "1", "--enable-qm", "1", "--qm-min", "8", "--sharpness", "1"])
        XCTAssertEqual(EncodeRecipes.svtArgs(args, pq: false), args, "SDR and HLG keep their settings")
        // Every kind that gets the bias from the planner loses it for PQ.
        for kind in ContentKind.allCases {
            let planned = EncodeRecipes.recipe(codec: .av1, kind: kind).options.filter { $0.encoderKey == nil }.flatMap(\.args)
            XCTAssertFalse(EncodeRecipes.svtArgs(planned, pq: true).contains("--luminance-qp-bias"), "\(kind)")
        }
    }

    func testContentSettingsFromTheMeasurements() throws {
        func args(_ kind: ContentKind) -> [String] {
            EncodeRecipes.recipe(codec: .av1, kind: kind).options.filter { $0.encoderKey == nil && $0.recommendedFor.contains(kind) }.flatMap(\.args)
        }
        func value(_ flag: String, _ a: [String]) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(value("--qm-min", args(.realLife)), "6")
        XCTAssertEqual(value("--qm-min", args(.anime)), "8")
        XCTAssertEqual(value("--qm-min", args(.cgiAnimation)), "8")
        XCTAssertEqual(value("--tune", args(.anime)), "0")
        XCTAssertNil(value("--tune", args(.realLife)), "live action keeps the default tune")
        XCTAssertEqual(value("--enable-tf", args(.anime)), "0")
        for kind in [ContentKind.realLifeHeavyGrain, .oldAnime, .lowLightNoisy, .realLife] {
            XCTAssertEqual(value("--tf-strength", args(kind)), "1", "\(kind): grain is synthesized, so the encoder filters a clean picture")
        }
        XCTAssertEqual(value("--variance-boost-curve", args(.lowLightNoisy)), "1")
        XCTAssertEqual(value("--variance-boost-strength", args(.fastMotion)), "1")
        XCTAssertNil(value("--variance-boost-strength", args(.realLife)), "live action keeps the default strength")
        XCTAssertEqual(value("--ac-bias", args(.realLifeHeavyGrain)), "1.0")
        XCTAssertEqual(value("--ac-bias", args(.lowLightNoisy)), "1.0")
        XCTAssertEqual(value("--ac-bias", args(.realLife)), "1.0")
        XCTAssertEqual(value("--ac-bias", args(.cgiAnimation)), "1.0")
        XCTAssertNil(value("--ac-bias", args(.anime)))
        XCTAssertNil(value("--lookahead", args(.realLife)), "--lookahead 120 changed nothing; it is no longer offered")
        XCTAssertEqual(value("--film-grain", args(.realLifeHeavyGrain)), "12")
        XCTAssertEqual(value("--film-grain", args(.oldAnime)), "8")
        XCTAssertEqual(value("--film-grain", args(.lowLightNoisy)), "4")
        for kind in ContentKind.allCases {
            XCTAssertNotEqual(value("--film-grain-denoise", args(kind)), "0", "\(kind): denoise off would stack synthetic grain on coded grain")
        }
    }

    func testEncoderGrainSynthesisOnlyOnPreset6AndSlower() throws {
        let r = EncodeRecipes.recipe(codec: .av1, kind: .lowLightNoisy)
        let grain = try XCTUnwrap(r.options.first { $0.id == "grain" })
        for rung in r.rungs where rung.encoderKey == nil {
            let preset = try XCTUnwrap(Int(rung.presetValue))
            XCTAssertEqual(grain.offered(onRung: rung.id), preset <= 6, "preset \(preset)")
        }
        // The fastest plan for a noisy film runs a fast preset, so it must not carry encoder grain synthesis,
        // even when asked for: SVT-AV1's grain estimation would cost more time than the fast preset saves.
        let fast = EncodePlanner.plan(codec: .av1, kind: .lowLightNoisy, frames: 2400, width: 1920, height: 1080, vmafMode: false,
                                      renderFps: 200, mode: .fastest, budget: 3600, overrides: ["grain": true])
        if let p = Int(fast.choice.presetValue), p > 6, fast.choice.encoderKey == nil {
            XCTAssertFalse(fast.choice.extraArgs.contains("--film-grain"), "grain at preset \(p)")
        }
        let slow = EncodePlanner.plan(codec: .av1, kind: .lowLightNoisy, frames: 2400, width: 1920, height: 1080, vmafMode: false,
                                      renderFps: 200, mode: .maximum, budget: 3600, overrides: ["grain": true])
        if slow.choice.encoderKey == nil { XCTAssertTrue(slow.choice.extraArgs.contains("--film-grain")) }
    }

    func testGrainTuneAndPlannerUseTheSameSynthesis() throws {
        // Without a plan the content tune applies; with a plan the recipe option does. Both must describe the same grain.
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "svtav1"))
        for kind in [ContentKind.realLifeHeavyGrain, .oldAnime, .lowLightNoisy] {
            let tune = ContentTuning.preset(kind).encoderTune
            let values = ["svt_grain": "\(EncodeRecipes.svtGrainLevel(kind))"]
            let tuneArgs = spec.render(values, hdr: false, tune: tune).suffix(spec.tunes?[tune]?.count ?? 0)
            let option = try XCTUnwrap(EncodeRecipes.recipe(codec: .av1, kind: kind).options.first { $0.id == "grain" })
            XCTAssertEqual(Array(tuneArgs), option.args, "\(kind)")
        }
    }

    // MARK: - Real exports

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraSVTTuning-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// 2 s at 24 fps, 640x360: moving test pattern, optionally darkened with sensor-like noise.
    static func makeSource(_ name: String, noisy: Bool) throws -> URL {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        var vf = "testsrc2=s=640x360:r=24:d=2,format=yuv420p"
        if noisy { vf += ",lutyuv=y='16+(val-16)*0.35',noise=alls=10:allf=t+u" }
        try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", vf,
                                      "-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p",
                                      "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", url.path])
        return url
    }

    func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out: String, kind: ContentKind) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: Self.work.appendingPathComponent(out))
        job.contentKind = kind
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    /// What the planner picks at a given SVT-AV1 rung for this content kind when time allows every recommended extra
    /// (the "grainTable" extra is left out: it replaces the encoder's grain synthesis with Lumora's own table).
    func choice(kind: ContentKind, rung: String, width: Int, height: Int) throws -> EncodeChoice {
        let recipe = EncodeRecipes.recipe(codec: .av1, kind: kind)
        let r = try XCTUnwrap(recipe.rungs.first { $0.id == rung })
        let options = recipe.options.filter { o in
            o.encoderKey == nil && o.id != "grainTable" && o.offered(onRung: r.id) && o.recommendedFor.contains(kind)
                && EncodeRecipes.available(o, codec: .av1)
        }
        return EncodeChoice(codec: .av1, rungID: r.id, rungLabel: r.label, presetValue: r.presetValue,
                            optionIDs: options.map(\.id), extraArgs: options.flatMap(\.args))
    }

    /// Runs the export with verbose logging on (restored afterwards) and returns the SVT-AV1 command lines it logged.
    func exportLoggingEncoder(_ job: ExportJob) async throws -> (URL, [String]) {
        // LogStore.verbose persists itself in the defaults; put back exactly what was there.
        let stored = Prefs.store.object(forKey: "verboseLogging")
        LogStore.shared.verbose = true
        defer {
            LogStore.shared.verbose = (stored as? Bool) ?? false
            if stored == nil { Prefs.store.removeObject(forKey: "verboseLogging") }
        }
        let before = LogStore.shared.entries.count
        let url = try await ExportEngine().run(job) { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)      // log entries reach the store on the main actor
        let lines = LogStore.shared.entries.dropFirst(before).map(\.message).filter { $0.hasPrefix(EncodeRecipes.svtBinary + " ") }
        return (url, lines)
    }

    /// VMAF, XPSNR and CAMBI of `test` against `reference`, both decoded by FFmpeg to 10-bit 4:2:0, as Lumora scores.
    func scores(reference: URL, test: URL, hdr: Bool, width: Int, height: Int, frames: Int) async throws -> MetricScores {
        guard VMAFRunner.available else { throw XCTSkip("libvmaf not installed") }
        let work = Self.work.appendingPathComponent("metrics-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let writeReference: (FileHandle) throws -> Void = { handle in
            let p = Process()
            p.executableURL = ToolLocator.url(for: "ffmpeg")
            p.arguments = ["-v", "error", "-nostdin", "-i", reference.path, "-vf", "format=yuv420p10le", "-strict", "-1",
                           "-f", "yuv4mpegpipe", "-"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            p.waitUntilExit()
        }
        let ctx = MetricSuite.Context(width: width, height: height, rate: (24, 1), hdr: hdr, frames: frames, threads: 4,
                                      fast: false, workDir: work)
        return try await MetricSuite.measure([.vmaf, .xpsnr, .cambi], reference: writeReference, distorted: test, ctx: ctx)
    }

    func lpValue(_ line: String) -> Int? {
        let parts = line.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: "--lp"), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    func runTuned(kind: ContentKind, delivery: DeliveryFormat, noisy: Bool, rung: String) async throws
        -> (url: URL, commands: [String], vmaf: Double, xpsnr: Double, cambi: Double) {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try Self.makeSource(noisy ? "noisy.mp4" : "clean.mp4", noisy: noisy)
        let tag = "\(kind.rawValue)-\(delivery.rawValue)"
        var reference = try await makeJob(src, delivery: delivery, codec: .prores4444XQ, out: "ref-\(tag).mov", kind: kind)
        reference.bitDepth = 12
        reference.chroma = .c444
        let refURL = try await ExportEngine().run(reference) { _, _ in }
        var job = try await makeJob(src, delivery: delivery, codec: .av1, out: "svt-\(tag).mkv", kind: kind)
        job.quality = 0.5
        job.encodeChoice = try choice(kind: kind, rung: rung, width: 640, height: 360)
        let (url, commands) = try await exportLoggingEncoder(job)

        let p = try EndToEndTests.probe(url)
        XCTAssertEqual(p.codec, "av1")
        XCTAssertTrue(p.pixFmt.contains("10"), "expected 10-bit, got \(p.pixFmt)")
        XCTAssertEqual(p.frames, 48)
        XCTAssertFalse(commands.isEmpty, "the SVT-AV1 command line was logged")
        for c in commands {
            let lp = try XCTUnwrap(lpValue(c), "no --lp in \(c)")
            XCTAssertTrue((1...6).contains(lp), "--lp \(lp) is not a 0-6 level")
            XCTAssertEqual(lp, EncodeRecipes.svtParallelism(cores: ChipProfile.current.cpuCores))
        }
        let s = try await scores(reference: refURL, test: url, hdr: delivery == .hdr10, width: 640, height: 360, frames: 48)
        let vmaf = try XCTUnwrap(s.pooled[.vmaf]?.mean), xpsnr = try XCTUnwrap(s.pooled[.xpsnr]?.mean)
        let cambi = s.pooled[.cambi]?.mean ?? 0
        print(String(format: "SVT-AV1 tuned export %@ %@ %@: VMAF %.2f XPSNR %.2f CAMBI %.3f; %@", kind.rawValue, delivery.rawValue,
                     rung, vmaf, xpsnr, cambi, commands.first ?? "no command logged"))
        return (url, commands, vmaf, xpsnr, cambi)
    }

    func testTunedLiveActionExportSDR() async throws {
        let r = try await runTuned(kind: .realLife, delivery: .sdr, noisy: false, rung: "p4")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--luminance-qp-bias 25") }, "SDR keeps the luminance bias")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--qm-min 6") && $0.contains("--ac-bias 1.0") && $0.contains("--tf-strength 1") },
                      "\(r.commands)")
        XCTAssertGreaterThan(r.vmaf, 85, "VMAF \(r.vmaf)")
        XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
        XCTAssertLessThan(r.cambi, 1, "CAMBI \(r.cambi)")
    }

    func testTunedLiveActionExportHDR10DropsLuminanceBias() async throws {
        let r = try await runTuned(kind: .realLife, delivery: .hdr10, noisy: false, rung: "p4")
        XCTAssertTrue(r.commands.allSatisfy { !$0.contains("--luminance-qp-bias") }, "PQ must not get the luminance bias")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--qm-min 8") }, "PQ keeps flatter quantization matrices")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--transfer-characteristics 16") })
        XCTAssertEqual(try EndToEndTests.probe(r.url).transfer, "smpte2084")
        XCTAssertGreaterThan(r.vmaf, 80, "VMAF \(r.vmaf)")
        XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
    }

    func testTunedLowLightExportCarriesGrainOnSlowRungOnly() async throws {
        let slow = try await runTuned(kind: .lowLightNoisy, delivery: .sdr, noisy: true, rung: "p4")
        let level = EncodeRecipes.svtGrainLevel(.lowLightNoisy)
        XCTAssertTrue(slow.commands.allSatisfy { $0.contains("--film-grain \(level) --film-grain-denoise 1") }, "\(slow.commands)")
        XCTAssertTrue(slow.commands.allSatisfy { $0.contains("--tf-strength 1") && !$0.contains("--enable-tf 0") }, "\(slow.commands)")
        // The AV1 frames carry film grain parameters for the player.
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let side = try EndToEndTests.sh(ffprobe, ["-v", "error", "-export_side_data", "film_grain", "-select_streams", "v:0",
                                                  "-read_intervals", "%+#2", "-show_frames", "-show_entries", "side_data=side_data_type",
                                                  "-of", "default=nw=1", slow.url.path])
        XCTAssertTrue(side.lowercased().contains("film grain"), "no film grain side data: \(side)")
        XCTAssertGreaterThan(slow.vmaf, 60, "VMAF \(slow.vmaf) (synthetic grain applied; the reference has the real noise)")

        let fast = try await runTuned(kind: .lowLightNoisy, delivery: .sdr, noisy: true, rung: "p8")
        XCTAssertTrue(fast.commands.allSatisfy { !$0.contains("--film-grain") }, "no encoder grain synthesis at preset 8")
    }
}
