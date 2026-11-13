import XCTest
@testable import Lumora

/// x265 preset tuning (docs/encoding/tuning-x265.md). The unit tests pin the measured decisions and the command-line
/// rules; the container tests check that HEVC copied into MP4 is tagged `hvc1` and keeps its Dolby Vision record;
/// the export tests run the real ExportEngine with the tuned planner choice on short generated clips, then check the
/// file with ffprobe, the x265 command line Lumora logged, and Lumora's own metrics against a ProRes 4444 XQ export
/// of the same job.
@MainActor
final class X265TuningTests: XCTestCase {

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraX265Tuning-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    static func value(_ flag: String, _ a: [String]) -> String? {
        a.firstIndex(of: flag).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
    }

    // MARK: - Command-line rules

    func testHDR10OptOnlyAt10Bit420() {
        let args = ["--preset", "slow", "--hdr10", "--hdr10-opt", "--repeat-headers", "--crf", "18"]
        XCTAssertTrue(EncodeRecipes.x265Args(args, bits: 10, chroma: .c420, preset: "slow").contains("--hdr10-opt"))
        for (bits, chroma) in [(12, ChromaFormat.c420), (10, .c422), (10, .c444), (12, .c444)] {
            let out = EncodeRecipes.x265Args(args, bits: bits, chroma: chroma, preset: "slow")
            XCTAssertFalse(out.contains("--hdr10-opt"), "\(bits)-bit \(chroma)")
            XCTAssertEqual(out, args.filter { $0 != "--hdr10-opt" }, "nothing else changes")
        }
        // The HDR10 arguments in encoders.json still ask for it, so 10-bit 4:2:0 HDR10 keeps PQ-aware QP.
        let spec = EncoderCatalog.shared.spec(for: "x265")
        XCTAssertEqual(spec?.hdrArgs.contains("--hdr10-opt"), true)
    }

    func testPsyRDOQOnlyWhereRDOQRuns() {
        let extras = ["--psy-rd", "2.0", "--psy-rdoq", "1.5", "--aq-mode", "3"]
        for preset in ["ultrafast", "veryfast", "fast", "medium"] {
            XCTAssertEqual(EncodeRecipes.x265Args(extras, bits: 10, chroma: .c420, preset: preset), ["--psy-rd", "2.0", "--aq-mode", "3"], preset)
        }
        for preset in ["slow", "slower", "veryslow", "placebo"] {
            XCTAssertEqual(EncodeRecipes.x265Args(extras, bits: 10, chroma: .c420, preset: preset), extras, preset)
        }
        // An explicit --rdoq-level decides instead of the preset.
        XCTAssertEqual(EncodeRecipes.x265Args(extras + ["--rdoq-level", "1"], bits: 10, chroma: .c420, preset: "medium"),
                       extras + ["--rdoq-level", "1"])
        XCTAssertFalse(EncodeRecipes.x265Args(extras + ["--rdoq-level", "0"], bits: 10, chroma: .c420, preset: "slow").contains("--psy-rdoq"))
        // Every x265 rung on the ladder is either a preset with RDOQ or one in the list without it.
        let known = EncodeRecipes.x265PresetsWithoutRDOQ.union(["slow", "slower", "veryslow", "placebo"])
        for rung in EncodeRecipes.recipe(codec: .hevc12, kind: .realLife).rungs { XCTAssertTrue(known.contains(rung.presetValue), rung.id) }
    }

    func testNoPlanEncodesLikeThePlannerBaseSet() throws {
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "x265"))
        for kind in ContentKind.allCases {
            // x265's own tunes are not used: explicit options would override what they set.
            let tune = ContentTuning.preset(kind).encoderTune
            XCTAssertEqual(spec.tunes?[tune] ?? [], [], "\(kind): tune \(tune)")
            let base = EncodeRecipes.x265BaseOptions(kind)
            XCTAssertFalse(base.isEmpty, "\(kind)")
            let noPlan = EncodeRecipes.x265Args(["--preset", "slow"], bits: 10, chroma: .c420, preset: "slow", kind: kind, planned: false)
            XCTAssertEqual(noPlan, ["--preset", "slow"] + base.flatMap(\.args), "\(kind)")
            XCTAssertFalse(noPlan.contains("--tune"), "\(kind)")
            // The planner always enables the same set, whatever the mode.
            for mode in PlanMode.allCases {
                let p = EncodePlanner.plan(codec: .hevc12, kind: kind, frames: 2000, width: 1920, height: 1080, vmafMode: false,
                                           renderFps: 60, mode: mode, budget: 3600, overrides: [:])
                XCTAssertTrue(Set(base.map(\.id)).isSubset(of: p.enabled), "\(kind) \(mode): \(p.enabled)")
            }
            // An x265 flag appears at most once in the base set, so nothing in it overrides anything else in it.
            let flags = base.flatMap(\.args).filter { $0.hasPrefix("--") }
            XCTAssertEqual(flags.count, Set(flags).count, "\(kind): \(flags)")
        }
        // With a plan nothing is added: the planner's extras are already on the command line.
        XCTAssertEqual(EncodeRecipes.x265Args(["--crf", "18"], bits: 10, chroma: .c420, preset: "slow", kind: .anime, planned: true), ["--crf", "18"])
    }

    func testMeasuredDecisions() throws {
        func args(_ kind: ContentKind) -> [String] { EncodeRecipes.x265BaseOptions(kind).flatMap(\.args) }
        for kind in [ContentKind.realLife, .cgiAnimation, .fastMotion, .screenContent] {
            XCTAssertEqual(Self.value("--psy-rd", args(kind)), "1.0", "\(kind)")
            XCTAssertEqual(Self.value("--psy-rdoq", args(kind)), "1.0", "\(kind)")
        }
        for kind in [ContentKind.realLifeHeavyGrain, .lowLightNoisy, .oldAnime] {
            XCTAssertEqual(Self.value("--psy-rdoq", args(kind)), "4.0", "grain keeps psy-rdoq 4: \(kind)")
        }
        XCTAssertEqual(Self.value("--psy-rd", args(.anime)), "2.0")
        XCTAssertEqual(Self.value("--aq-strength", args(.anime)), "0.8")
        for kind in ContentKind.allCases where kind != .anime { XCTAssertNil(Self.value("--aq-strength", args(kind)), "\(kind)") }
        XCTAssertNil(Self.value("--aq-mode", args(.screenContent)), "screen content keeps x265's AQ mode 2")
        XCTAssertTrue(args(.screenContent).contains("--tskip"))
        for kind in ContentKind.allCases where kind != .screenContent { XCTAssertFalse(args(kind).contains("--tskip"), "\(kind)") }
        XCTAssertEqual(Set(EncodeRecipes.x265RD6Kinds), [.lowLightNoisy, .oldAnime])
        // B-frames 8/16, 6 references and the 60-frame look-ahead cost 10-54% time and saved nothing measurable
        // (look-ahead: about 2% on anime only), so they are not in any base set and the planner never picks them.
        for kind in ContentKind.allCases {
            for flag in ["--bframes", "--ref", "--rc-lookahead", "--rd"] { XCTAssertFalse(args(kind).contains(flag), "\(kind) \(flag)") }
            for mode in PlanMode.allCases {
                let p = EncodePlanner.plan(codec: .hevc12, kind: kind, frames: 2000, width: 1920, height: 1080, vmafMode: false,
                                           renderFps: 60, mode: mode, budget: 86_400, overrides: [:])
                XCTAssertTrue(p.enabled.isDisjoint(with: ["bframes", "ref"]), "\(kind) \(mode): \(p.enabled)")
                if kind != .anime { XCTAssertFalse(p.enabled.contains("rclook"), "\(kind) \(mode)") }
                if !EncodeRecipes.x265RD6Kinds.contains(kind) { XCTAssertFalse(p.enabled.contains("rd6"), "\(kind) \(mode)") }
            }
        }
        // The measured ladder: faster first, `fast` left out (slower than medium and larger), each rung slower and smaller.
        let rungs = EncodeRecipes.recipe(codec: .hevc12, kind: .realLife).rungs
        XCTAssertEqual(rungs.map(\.presetValue), ["faster", "medium", "slow", "slower", "veryslow", "placebo"])
        for (a, b) in zip(rungs, rungs.dropFirst()) {
            XCTAssertGreaterThan(a.seedSpeed, b.seedSpeed, b.id)
            XCTAssertLessThan(a.seedSaving, b.seedSaving, b.id)
        }
        // Given time, old anime gets rd 6: the slowest presets use it themselves, so the planner adds it only up to slow.
        let max = EncodePlanner.plan(codec: .hevc12, kind: .oldAnime, frames: 2000, width: 1920, height: 1080, vmafMode: false,
                                     renderFps: 60, mode: .maximum, budget: 86_400, overrides: [:])
        XCTAssertTrue(["slower", "veryslow", "placebo"].contains(max.choice.rungID), max.choice.rungID)
        XCTAssertFalse(max.enabled.contains("rd6"), "\(max.enabled)")
        let rd6 = EncodeRecipes.recipe(codec: .hevc12, kind: .oldAnime).options.first { $0.id == "rd6" }
        XCTAssertEqual(rd6?.offered(onRung: "slow"), true)
        XCTAssertEqual(rd6?.recommendedFor.contains(.oldAnime), true)
    }

    func testHelpParsingSeesFullHelpAndNoForms() {
        XCTAssertEqual(EncodeRecipes.helpArguments("x265"), ["--fullhelp", "--help"])
        XCTAssertEqual(EncodeRecipes.helpArguments("SvtAv1EncApp"), ["--help"])
        let text = """
           --[no-]sao                    Enable Sample Adaptive Offset. Default enabled
           --[no-]limit-sao              Limit Sample Adaptive Offset types. Default disabled
           --y4m                         Parse input stream as YUV4MPEG2 regardless of file extension
           --input-depth <integer>       Bit-depth of input file. Default 8
           --psy-rdoq <0..50.0>          Strength of psycho-visual optimization in RDO quantization, 0 to disable. Default 0.0
        -p/--preset <string>             Trade off performance for compression efficiency. Default medium
        -b/--bframes <0..16>             Maximum number of consecutive b-frames. Default 4
        """
        let flags = EncodeRecipes.parseFlags(text)
        for f in ["--sao", "--no-sao", "--limit-sao", "--no-limit-sao", "--y4m", "--input-depth", "--psy-rdoq", "--preset", "--bframes"] {
            XCTAssertTrue(flags.contains(f), f)
        }
        XCTAssertFalse(flags.contains("--"))
        XCTAssertFalse(flags.contains { $0.contains("[") || $0.contains("]") })
    }

    func testInstalledX265ListsTheFullHelp() throws {
        guard ToolLocator.isAvailable("x265") else { throw XCTSkip("x265 not installed") }
        let flags = try XCTUnwrap(EncodeRecipes.supportedFlags("x265"))
        // These appear only in --fullhelp on 4.3.
        for f in ["--y4m", "--qcomp", "--zones"] { XCTAssertTrue(flags.contains(f), "\(f) missing: --help was probed") }
        // Every flag Lumora's x265 recipe passes is known to the installed build.
        for kind in ContentKind.allCases {
            for o in EncodeRecipes.recipe(codec: .hevc12, kind: kind).options {
                for a in o.args where a.hasPrefix("--") { XCTAssertTrue(flags.contains(a), "\(o.id): \(a)") }
            }
        }
    }

    // MARK: - MP4 tag and Dolby Vision record

    static func ffprobeTag(_ url: URL) throws -> (tag: String, dvProfile: Int?) {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let out = try EndToEndTests.sh(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                 "stream=codec_tag_string:stream_side_data=dv_profile", "-of", "json", url.path])
        let root = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let stream = (root?["streams"] as? [[String: Any]])?.first ?? [:]
        let side = (stream["side_data_list"] as? [[String: Any]]) ?? []
        return (stream["codec_tag_string"] as? String ?? "", side.compactMap { $0["dv_profile"] as? Int }.first)
    }

    /// 1 s of 10-bit HEVC at 320x180: an Annex-B stream (x265), then the same in Matroska and in an `hev1` MP4.
    static func hevcSamples() throws -> (raw: URL, mkv: URL, hev1: URL) {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let raw = work.appendingPathComponent("s.hevc"), mkv = work.appendingPathComponent("s.mkv"), hev1 = work.appendingPathComponent("s-hev1.mp4")
        if !FileManager.default.fileExists(atPath: hev1.path) {
            try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=1", "-pix_fmt", "yuv420p10le",
                                          "-c:v", "libx265", "-x265-params", "log-level=error", "-f", "hevc", raw.path])
            // FFmpeg can't put a raw (untimed) stream into Matroska; mkvmerge rebuilds the timestamps, as Lumora does.
            guard ToolLocator.isAvailable("mkvmerge") else { throw XCTSkip("mkvmerge not installed") }
            try? FileManager.default.removeItem(at: mkv)
            try ToolLocator.run("mkvmerge", ["-q", "-o", mkv.path, "--default-duration", "0:24fps", raw.path])
            try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-i", mkv.path, "-c", "copy", hev1.path])
        }
        return (raw, mkv, hev1)
    }

    func testCopyArgsTagHEVCAsHvc1() throws {
        let s = try Self.hevcSamples()
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        XCTAssertEqual(try Self.ffprobeTag(s.hev1).tag, "hev1", "FFmpeg's own default, which Apple devices refuse")
        for input in [s.mkv, s.hev1, s.raw] {
            let args = Packager.quickTimeVideoArgs(video: input, outputExtension: "mp4")
            XCTAssertEqual(args, ["-tag:v", "hvc1", "-strict", "unofficial"], input.lastPathComponent)
            let out = Self.work.appendingPathComponent("copy-\(input.lastPathComponent).mp4")
            try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y"] + (input == s.raw ? ["-r", "24"] : []) + ["-i", input.path, "-c", "copy"] + args + [out.path])
            XCTAssertEqual(try Self.ffprobeTag(out).tag, "hvc1", input.lastPathComponent)
        }
        XCTAssertEqual(Packager.quickTimeVideoArgs(video: s.mkv, outputExtension: "mkv"), [], "Matroska has no sample-entry tag")
        // Not HEVC: nothing to add.
        let prores = Self.work.appendingPathComponent("p.mov")
        try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=160x90:r=24:d=0.2", "-c:v", "prores_ks", prores.path])
        XCTAssertEqual(Packager.quickTimeVideoArgs(video: prores, outputExtension: "mov"), [])
    }

    func packaged(_ exported: URL, name: String) async throws -> URL {
        var o = PackagingOptions()
        o.appendices = []
        o.outputName = name
        o.verifyAfterExport = false
        let facts = Packager.Facts(title: name, resolution: "180p", hdr: "SDR", codec: "HEVC", appVersion: "test",
                                   settings: [:], qualityLines: [], hdrReport: [], logLines: [], posterJPEG: nil)
        let dest = Self.work.appendingPathComponent("packaged-\(UUID().uuidString.prefix(6))")
        return try await Packager.package(exported: exported, source: exported, streams: SourceStreams.probe(exported), options: o,
                                          destination: dest, facts: facts, progress: ProgressReporter(task: nil)).video
    }

    func testPackagerWritesHvc1() async throws {
        let s = try Self.hevcSamples()
        let out = try await packaged(s.hev1, name: "tagged")
        XCTAssertEqual(out.pathExtension, "mp4")
        XCTAssertEqual(try Self.ffprobeTag(out).tag, "hvc1")
    }

    func testPackagerKeepsDolbyVisionRecord() async throws {
        let s = try Self.hevcSamples()
        guard ToolLocator.isAvailable("dovi_tool"), ToolLocator.isAvailable("MP4Box") else { throw XCTSkip("dovi_tool / MP4Box not installed") }
        let gen = Self.work.appendingPathComponent("gen.json"), rpu = Self.work.appendingPathComponent("rpu.bin")
        let dv = Self.work.appendingPathComponent("dv.hevc"), mp4 = Self.work.appendingPathComponent("dv.mp4")
        try #"{"cm_version":"V40","length":24,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}"#
            .write(to: gen, atomically: true, encoding: .utf8)
        try ToolLocator.run("dovi_tool", ["generate", "-j", gen.path, "-o", rpu.path])
        try ToolLocator.run("dovi_tool", ["inject-rpu", "-i", s.raw.path, "--rpu-in", rpu.path, "-o", dv.path])
        try? FileManager.default.removeItem(at: mp4)
        try ToolLocator.run("MP4Box", ["-quiet", "-add", "dv.hevc:dvp=8.1:fps=24", "-new", "dv.mp4"], in: Self.work)
        let before = try Self.ffprobeTag(mp4)
        XCTAssertEqual(before.dvProfile, 8, "MP4Box wrote the Dolby Vision record")
        let out = try await packaged(mp4, name: "dolby")
        let after = try Self.ffprobeTag(out)
        XCTAssertEqual(after.tag, "hvc1")
        XCTAssertEqual(after.dvProfile, 8, "the packaged file must keep dvcC, or it plays as plain HDR10")
    }

    // MARK: - Real exports through ExportEngine

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

    /// What the planner can pick at an x265 rung for this content type when time allows: the base set plus every
    /// recommended extra that saves bits.
    func choice(kind: ContentKind, rung: String) throws -> EncodeChoice {
        let recipe = EncodeRecipes.recipe(codec: .hevc12, kind: kind)
        let r = try XCTUnwrap(recipe.rungs.first { $0.id == rung })
        let options = recipe.options.filter {
            $0.recommendedFor.contains(kind) && EncodeRecipes.available($0, codec: .hevc12) && ($0.speedCost <= 1.05 || $0.vmafSaving > 0)
        }
        return EncodeChoice(codec: .hevc12, rungID: r.id, rungLabel: r.label, presetValue: r.presetValue,
                            optionIDs: options.map(\.id), extraArgs: options.flatMap(\.args))
    }

    /// Runs the export with verbose logging on (restored afterwards) and returns the x265 command lines it logged.
    func exportLoggingEncoder(_ job: ExportJob) async throws -> (URL, [String]) {
        let stored = UserDefaults.standard.object(forKey: "verboseLogging")
        LogStore.shared.verbose = true
        defer {
            LogStore.shared.verbose = (stored as? Bool) ?? false
            if stored == nil { UserDefaults.standard.removeObject(forKey: "verboseLogging") }
        }
        let before = LogStore.shared.entries.count
        let url = try await ExportEngine().run(job) { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)      // log entries reach the store on the main actor
        let lines = LogStore.shared.entries.dropFirst(before).map(\.message).filter { $0.hasPrefix(EncodeRecipes.x265Binary + " ") }
        return (url, lines)
    }

    /// VMAF, XPSNR and CAMBI of `test` against `reference`, both decoded by FFmpeg to 10-bit 4:2:0, as Lumora scores.
    func scores(reference: URL, test: URL, hdr: Bool, frames: Int) async throws -> MetricScores {
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
        let ctx = MetricSuite.Context(width: 640, height: 360, rate: (24, 1), hdr: hdr, frames: frames, threads: 4,
                                      fast: false, workDir: work)
        return try await MetricSuite.measure([.vmaf, .xpsnr, .cambi], reference: writeReference, distorted: test, ctx: ctx)
    }

    struct Tuned { var url: URL; var commands: [String]; var vmaf: Double; var xpsnr: Double; var cambi: Double }

    /// Exports the job with x265 (planner choice at `rung`, or no plan) into MP4 and a ProRes 4444 XQ reference of the
    /// same job, then checks the container and scores the encode.
    func runTuned(kind: ContentKind, delivery: DeliveryFormat, bits: Int, noisy: Bool, rung: String?) async throws -> Tuned {
        try TestHardware.requireGPU()
        guard Codec.hevc12.available else { throw XCTSkip("x265 not installed") }
        let src = try Self.makeSource(noisy ? "noisy.mp4" : "clean.mp4", noisy: noisy)
        let tag = "\(kind.rawValue)-\(delivery.rawValue)-\(bits)-\(rung ?? "noplan")"
        var reference = try await makeJob(src, delivery: delivery, codec: .prores4444XQ, out: "ref-\(kind.rawValue)-\(delivery.rawValue).mov", kind: kind)
        reference.bitDepth = 12
        reference.chroma = .c444
        let refURL = FileManager.default.fileExists(atPath: reference.outputURL.path) ? reference.outputURL
            : try await ExportEngine().run(reference) { _, _ in }
        var job = try await makeJob(src, delivery: delivery, codec: .hevc12, out: "x265-\(tag).mp4", kind: kind)
        job.bitDepth = bits
        job.chroma = .c420
        job.quality = 0.5
        if let rung { job.encodeChoice = try choice(kind: kind, rung: rung) }
        let (url, commands) = try await exportLoggingEncoder(job)

        let p = try EndToEndTests.probe(url)
        XCTAssertEqual(p.codec, "hevc")
        XCTAssertTrue(p.pixFmt.contains("\(bits)"), "expected \(bits)-bit, got \(p.pixFmt)")
        XCTAssertEqual(p.frames, 48)
        XCTAssertEqual(try Self.ffprobeTag(url).tag, "hvc1", "HEVC in MP4 must be tagged hvc1 for Apple devices")
        XCTAssertFalse(commands.isEmpty, "the x265 command line was logged")
        for c in commands { XCTAssertFalse(c.contains("--tune"), c) }
        let s = try await scores(reference: refURL, test: url, hdr: delivery == .hdr10, frames: 48)
        let vmaf = try XCTUnwrap(s.pooled[.vmaf]?.mean), xpsnr = try XCTUnwrap(s.pooled[.xpsnr]?.mean)
        let cambi = s.pooled[.cambi]?.mean ?? 0
        print(String(format: "x265 tuned export %@: VMAF %.2f XPSNR %.2f CAMBI %.3f; %@", tag, vmaf, xpsnr, cambi, commands.first ?? "none"))
        return Tuned(url: url, commands: commands, vmaf: vmaf, xpsnr: xpsnr, cambi: cambi)
    }

    func assertBaseSet(_ kind: ContentKind, in commands: [String], file: StaticString = #filePath, line: UInt = #line) {
        for o in EncodeRecipes.x265BaseOptions(kind) {
            let joined = o.args.joined(separator: " ")
            for c in commands { XCTAssertTrue(c.contains(joined), "\(o.id) (\(joined)) missing from \(c)", file: file, line: line) }
        }
    }

    func testTunedLiveActionExportSDR12Bit() async throws {
        let r = try await runTuned(kind: .realLife, delivery: .sdr, bits: 12, noisy: false, rung: "slow")
        assertBaseSet(.realLife, in: r.commands)
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--output-depth 12") && $0.contains("--profile main12") })
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--psy-rd 1.0 --psy-rdoq 1.0") && !$0.contains("--bframes") && !$0.contains("--rc-lookahead") },
                      "\(r.commands)")
        XCTAssertGreaterThan(r.vmaf, 85, "VMAF \(r.vmaf)")
        XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
        XCTAssertLessThan(r.cambi, 1, "CAMBI \(r.cambi)")
    }

    func testTunedHDR10ExportKeepsHDR10OptAt10Bit() async throws {
        let r = try await runTuned(kind: .realLife, delivery: .hdr10, bits: 10, noisy: false, rung: "slow")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--hdr10-opt") && $0.contains("--transfer smpte2084") }, "\(r.commands)")
        XCTAssertEqual(try EndToEndTests.probe(r.url).transfer, "smpte2084")
        XCTAssertGreaterThan(r.vmaf, 80, "VMAF \(r.vmaf)")
        XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
    }

    func testHDR10At12BitDropsHDR10Opt() async throws {
        let r = try await runTuned(kind: .realLife, delivery: .hdr10, bits: 12, noisy: false, rung: "slow")
        XCTAssertTrue(r.commands.allSatisfy { !$0.contains("--hdr10-opt") && $0.contains("--hdr10 ") }, "\(r.commands)")
        XCTAssertEqual(try EndToEndTests.probe(r.url).transfer, "smpte2084")
    }

    func testLowLightWithoutPlanMatchesPlannerAndMediumDropsPsyRDOQ() async throws {
        let noPlan = try await runTuned(kind: .lowLightNoisy, delivery: .sdr, bits: 10, noisy: true, rung: nil)
        assertBaseSet(.lowLightNoisy, in: noPlan.commands)
        let base = EncodeRecipes.x265BaseOptions(.lowLightNoisy).flatMap(\.args)
        if let v = Self.value("--psy-rdoq", base) {
            XCTAssertTrue(noPlan.commands.allSatisfy { $0.contains("--psy-rdoq \(v)") }, "slow (the default preset) keeps psy-rdoq")
        }
        XCTAssertGreaterThan(noPlan.vmaf, 60, "VMAF \(noPlan.vmaf)")
        let medium = try await runTuned(kind: .lowLightNoisy, delivery: .sdr, bits: 10, noisy: true, rung: "medium")
        XCTAssertTrue(medium.commands.allSatisfy { $0.contains("--preset medium") && !$0.contains("--psy-rdoq") }, "\(medium.commands)")
    }
}
