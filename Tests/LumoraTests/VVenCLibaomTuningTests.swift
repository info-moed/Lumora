import XCTest
@testable import Lumora

/// VVenC and libaom preset tuning (docs/encoding/tuning-vvenc.md, docs/encoding/tuning-aomenc.md). The unit tests pin
/// the measured decisions; the export tests run the real ExportEngine on short generated clips with the tuned settings,
/// then check each file with ffprobe, the encoder command line Lumora logged, and Lumora's own metrics against a
/// ProRes 4444 XQ export of the same job (same grade, near-lossless).
@MainActor
final class VVenCLibaomTuningTests: XCTestCase {

    // MARK: - Measured decisions

    func testLibaomProfileIsNeverForcedTo2For12Bit422Or444() {
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 10, chroma: .c420), "0")
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 10, chroma: .c444), "1")
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 10, chroma: .c422), "2")
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 12, chroma: .c420), "2")
        // aomenc 3.15.3 refuses an explicit --profile=2 with 12-bit 4:2:2 / 4:4:4 input and raises 0 to 2 itself.
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 12, chroma: .c422), "0")
        XCTAssertEqual(EncodeRecipes.aomProfile(bitDepth: 12, chroma: .c444), "0")
        for chroma in ChromaFormat.allCases { XCTAssertTrue(Codec.av1Pro.supports(bitDepth: 12, chroma: chroma), chroma.label) }
    }

    func testLibaomCommandLineHasOnePassFlag() throws {
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "aomenc"))
        let args = spec.render(["in": "-", "out": "o.ivf", "preset": "4", "quality": "30", "bits": "10", "threads": "4",
                                "aom_profile": "0", "cp_name": "bt709", "tc_name": "bt709", "mc_name": "bt709"], hdr: false)
        XCTAssertEqual(args.filter { $0.hasPrefix("--passes") }, ["--passes=1"], "stdin input needs exactly one pass")
    }

    func testLibaomGrainIsRecognizedForFairScoring() throws {
        XCTAssertTrue(EncodeRecipes.synthesizesGrain(["--denoise-noise-level=8"]))
        XCTAssertFalse(EncodeRecipes.synthesizesGrain(["--denoise-noise-level=0"]))
        XCTAssertTrue(EncodeRecipes.synthesizesGrain(["--film-grain", "12", "--film-grain-denoise", "1"]))
        XCTAssertFalse(EncodeRecipes.synthesizesGrain(["--film-grain", "0"]))
        XCTAssertFalse(EncodeRecipes.synthesizesGrain(["--enable-qm=1", "--tune-content=screen"]))
        // SVT-AV1's grain tune (placeholder not yet rendered) and every libaom grain option count.
        let svt = try XCTUnwrap(EncoderCatalog.shared.spec(for: "svtav1"))
        XCTAssertTrue(EncodeRecipes.synthesizesGrain(svt.tunes?["grain"] ?? []))
        var options = 0
        for codec in [Codec.av1, .av1Pro] {
            for o in EncodeRecipes.recipe(codec: codec, kind: .realLifeHeavyGrain).options where o.id.hasPrefix("aomgrain") {
                XCTAssertTrue(EncodeRecipes.synthesizesGrain(o.args), o.id)
                options += 1
            }
        }
        XCTAssertEqual(options, 2)
    }

    func testLibaomGrainSynthesisNoLongerRecommended() throws {
        // libaom's grain synthesis was larger than coding the grain on every grainy clip (tuning-aomenc.md).
        let aom = try XCTUnwrap(EncoderCatalog.shared.spec(for: "aomenc"))
        XCTAssertFalse(EncodeRecipes.synthesizesGrain(aom.tunes?["grain"] ?? []), "the libaom grain tune no longer synthesizes")
        for codec in [Codec.av1, .av1Pro] {
            for kind in ContentKind.allCases {
                for o in EncodeRecipes.recipe(codec: codec, kind: kind).options where o.id.hasPrefix("aomgrain") {
                    XCTAssertTrue(o.recommendedFor.isEmpty, "\(codec) \(kind)")
                    XCTAssertEqual(o.vmafSaving, 0)
                    XCTAssertEqual(o.args, ["--denoise-noise-level=\(EncodeRecipes.aomGrainLevel)"])
                }
            }
        }
        // The planner's fastest and fullest libaom plans for a grainy film carry no libaom grain.
        for mode in [PlanMode.fastest, .maximum] {
            let plan = EncodePlanner.plan(codec: .av1Pro, kind: .realLifeHeavyGrain, frames: 2400, width: 1920, height: 1080,
                                          vmafMode: false, renderFps: 200, mode: mode, budget: 360_000, overrides: [:])
            XCTAssertFalse(EncodeRecipes.synthesizesGrain(plan.choice.extraArgs), "\(mode): \(plan.choice.extraArgs)")
        }
    }

    func testLibaomQuantizationMatricesNoLongerRecommended() {
        for codec in [Codec.av1, .av1Pro] {
            for kind in ContentKind.allCases {
                let qm = EncodeRecipes.recipe(codec: codec, kind: kind).options.filter { $0.args.contains("--enable-qm=1") }
                XCTAssertFalse(qm.isEmpty)
                XCTAssertTrue(qm.allSatisfy { $0.recommendedFor.isEmpty && $0.vmafSaving == 0 }, "\(codec) \(kind)")
            }
        }
    }

    func testLibaomLadderFromMeasurements() {
        let pro = EncodeRecipes.recipe(codec: .av1Pro, kind: .realLife).rungs
        XCTAssertEqual(pro.map(\.presetValue), ["6", "5", "4", "3", "2"])
        for (a, b) in zip(pro, pro.dropFirst()) {
            XCTAssertLessThan(b.seedSpeed, a.seedSpeed); XCTAssertGreaterThan(b.seedSaving, a.seedSaving)
        }
        XCTAssertGreaterThan(pro[1].seedSpeed, 0.7, "cpu-used 5 is nearly as fast as 6")
        XCTAssertGreaterThan(pro[2].seedSaving, 0.1, "cpu-used 4 is the big step")
        // On the archival AV1 ladder libaom cpu-used 4 sits next to SVT-AV1 preset 1.
        let av1 = EncodeRecipes.recipe(codec: .av1, kind: .realLife).rungs
        let p1 = av1.first { $0.id == "p1" }!, aom4 = av1.first { $0.id == "aom4" }!
        XCTAssertEqual(aom4.seedSaving, p1.seedSaving, accuracy: 0.005)
        XCTAssertGreaterThan(aom4.seedSpeed, p1.seedSpeed)
    }

    func testVVenCColorModesPerTransfer() throws {
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "vvenc"))
        XCTAssertEqual(spec.colorNames["sdr"]?["vvenc_sdr"], "sdr_709")
        XCTAssertEqual(spec.colorNames["sdr"]?["vvenc_hdr"], "off")
        XCTAssertEqual(spec.colorNames["pq"]?["vvenc_hdr"], "pq_2020", "pq alone signals BT.709 primaries")
        XCTAssertEqual(spec.colorNames["hlg"]?["vvenc_hdr"], "hlg_2020")
        XCTAssertEqual(spec.colorNames["hlg"]?["vvenc_additional"], "TransferCharacteristics=18",
                       "without it the VUI says BT.2020 10-bit and only an SEI says HLG")
        XCTAssertTrue(spec.args.contains("--sdr") && spec.args.contains("--hdr") && spec.args.contains("--additional"))
    }

    func testVVenCQPAOffOnlyForPQAndLowLight() {
        for kind in ContentKind.allCases {
            XCTAssertFalse(EncodeRecipes.vvencQPA(kind: kind, pq: true), "\(kind) PQ")
            XCTAssertEqual(EncodeRecipes.vvencQPA(kind: kind, pq: false), kind != .lowLightNoisy, "\(kind) SDR/HLG")
        }
    }

    func testVVenCCommandLine() throws {
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "vvenc"))
        XCTAssertEqual(spec.preset, "medium")
        let args = spec.render(["in": "-", "out": "o.266", "preset": "medium", "quality": "30", "threads": "4", "vvenc_qpa": "0",
                                "vvenc_sdr": "off", "vvenc_hdr": "pq_2020", "vvenc_additional": ""], hdr: true)
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--refreshsec"), "5", "a 5 s intra period was 21% smaller than VVenC's 1 s default")
        XCTAssertEqual(value("--qpa"), "0")
        XCTAssertTrue(args.contains("--y4m"), "piped Y4M needs --y4m or vvencapp encodes nothing")
        XCTAssertFalse(args.contains { $0.contains("{") }, "\(args)")
    }

    func testVVenCLadderFromMeasurements() {
        let rungs = EncodeRecipes.recipe(codec: .vvc, kind: .realLife).rungs
        XCTAssertEqual(rungs.map(\.id), ["faster", "fast", "medium", "slow", "slower"])
        for (a, b) in zip(rungs, rungs.dropFirst()) {
            XCTAssertLessThan(b.seedSpeed, a.seedSpeed, "\(b.id) is slower than \(a.id)")
            XCTAssertGreaterThan(b.seedSaving, a.seedSaving, "\(b.id) is smaller than \(a.id)")
        }
        let medium = rungs.first { $0.id == "medium" }!, slow = rungs.first { $0.id == "slow" }!
        XCTAssertEqual(medium.seedSpeed / slow.seedSpeed, 3.2, accuracy: 0.2)
    }

    func testBenchmarkValuesFillEveryPlaceholder() {
        for key in ["svtav1", "aomenc", "x265", "vvenc", "avm"] {
            guard let spec = EncoderCatalog.shared.spec(for: key) else { continue }
            let values = MacOptimizer.benchmarkValues(spec: spec, inArg: "-", out: "o", preset: spec.preset, threads: 4)
            let args = spec.render(values, hdr: false)
            XCTAssertFalse(args.contains { $0.contains("{") }, "\(key): \(args.filter { $0.contains("{") })")
        }
    }

    // MARK: - Real exports

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraVVenCAomTuning-\(ProcessInfo.processInfo.processIdentifier)")
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

    /// What the planner picks at a rung for this content kind when time allows every recommended extra.
    func choice(codec: Codec, kind: ContentKind, rung: String) throws -> EncodeChoice {
        let recipe = EncodeRecipes.recipe(codec: codec, kind: kind)
        let r = try XCTUnwrap(recipe.rungs.first { $0.id == rung })
        let options = recipe.options.filter { o in
            o.encoderKey == r.encoderKey && o.offered(onRung: r.id) && o.recommendedFor.contains(kind)
                && !o.id.contains("table") && EncodeRecipes.available(o, codec: codec)
        }
        return EncodeChoice(codec: codec, encoderKey: r.encoderKey, rungID: r.id, rungLabel: r.label, presetValue: r.presetValue,
                            optionIDs: options.map(\.id), extraArgs: options.flatMap(\.args))
    }

    /// Runs the export with verbose logging on (restored afterwards) and returns the encoder command lines it logged.
    func exportLoggingEncoder(_ job: ExportJob, binary: String) async throws -> (URL, [String]) {
        let stored = UserDefaults.standard.object(forKey: "verboseLogging")
        LogStore.shared.verbose = true
        defer {
            LogStore.shared.verbose = (stored as? Bool) ?? false
            if stored == nil { UserDefaults.standard.removeObject(forKey: "verboseLogging") }
        }
        let before = LogStore.shared.entries.count
        let url = try await ExportEngine().run(job) { _, _ in }
        try await Task.sleep(nanoseconds: 300_000_000)      // log entries reach the store on the main actor
        let lines = LogStore.shared.entries.dropFirst(before).map(\.message).filter { $0.hasPrefix(binary + " ") }
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

    struct Stream { var profile = "", pixFmt = "", primaries = "", transfer = "", matrix = "", range = "", frames = -1; var side = "" }

    func stream(_ url: URL) throws -> Stream {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let out = try EndToEndTests.sh(ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                                                 "stream=profile,pix_fmt,color_primaries,color_transfer,color_space,color_range,nb_read_frames",
                                                 "-of", "default=nw=1", url.path])
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        let side = try EndToEndTests.sh(ffprobe, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames",
                                                  "-show_entries", "frame=side_data_list", "-of", "default=nw=1", url.path])
        return Stream(profile: kv["profile"] ?? "", pixFmt: kv["pix_fmt"] ?? "", primaries: kv["color_primaries"] ?? "",
                      transfer: kv["color_transfer"] ?? "", matrix: kv["color_space"] ?? "", range: kv["color_range"] ?? "",
                      frames: Int(kv["nb_read_frames"] ?? "") ?? -1, side: side)
    }

    struct Run { var url: URL; var commands: [String]; var stream: Stream; var vmaf: Double; var xpsnr: Double; var cambi: Double }

    func runTuned(codec: Codec, kind: ContentKind, delivery: DeliveryFormat, noisy: Bool = false, rung: String,
                  bitDepth: Int = 10, chroma: ChromaFormat = .c420) async throws -> Run {
        try TestHardware.requireGPU()
        guard codec.available else { throw XCTSkip("\(codec.displayName) encoder not installed") }
        let src = try Self.makeSource(noisy ? "noisy.mp4" : "clean.mp4", noisy: noisy)
        let tag = "\(codec.rawValue)-\(kind.rawValue)-\(delivery.rawValue)-\(bitDepth)-\(chroma.y4mTag)"
        var reference = try await makeJob(src, delivery: delivery, codec: .prores4444XQ, out: "ref-\(tag).mov", kind: kind)
        reference.bitDepth = 12
        reference.chroma = .c444
        let refURL = try await ExportEngine().run(reference) { _, _ in }
        var job = try await makeJob(src, delivery: delivery, codec: codec, out: "enc-\(tag).\(codec.defaultContainer)", kind: kind)
        job.quality = 0.5
        job.bitDepth = bitDepth
        job.chroma = chroma
        job.encodeChoice = try choice(codec: codec, kind: kind, rung: rung)
        let binary = codec == .vvc ? "vvencapp" : "aomenc"
        let (url, commands) = try await exportLoggingEncoder(job, binary: binary)
        let st = try stream(url)
        XCTAssertEqual(st.frames, 48)
        XCTAssertFalse(commands.isEmpty, "the \(binary) command line was logged")
        let s = try await scores(reference: refURL, test: url, hdr: delivery == .hdr10, frames: 48)
        let vmaf = try XCTUnwrap(s.pooled[.vmaf]?.mean), xpsnr = try XCTUnwrap(s.pooled[.xpsnr]?.mean)
        let cambi = s.pooled[.cambi]?.mean ?? 0
        print(String(format: "%@ tuned export %@ %@ %@ %d-bit %@: VMAF %.2f XPSNR %.2f CAMBI %.3f; %@", binary, kind.rawValue,
                     delivery.rawValue, rung, bitDepth, chroma.label, vmaf, xpsnr, cambi, commands.first ?? "no command logged"))
        return Run(url: url, commands: commands, stream: st, vmaf: vmaf, xpsnr: xpsnr, cambi: cambi)
    }

    // VVenC: the campaign's signaling fix, through the real export path.

    func testVVenCSDRExportIsTaggedBT709() async throws {
        let r = try await runTuned(codec: .vvc, kind: .realLife, delivery: .sdr, rung: "medium")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--sdr sdr_709") && $0.contains("--hdr off") }, "\(r.commands)")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--qpa 1") && $0.contains("--refreshsec 5") }, "\(r.commands)")
        XCTAssertEqual(r.stream.primaries, "bt709"); XCTAssertEqual(r.stream.transfer, "bt709"); XCTAssertEqual(r.stream.matrix, "bt709")
        XCTAssertEqual(r.stream.range, "tv")
        XCTAssertTrue(r.stream.pixFmt.contains("10"))
        XCTAssertGreaterThan(r.vmaf, 85, "VMAF \(r.vmaf)"); XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
        XCTAssertLessThan(r.cambi, 1, "CAMBI \(r.cambi)")
    }

    func testVVenCHDR10ExportCarriesPQAndStaticMetadata() async throws {
        let r = try await runTuned(codec: .vvc, kind: .realLife, delivery: .hdr10, rung: "medium")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--hdr pq_2020") && $0.contains("MasteringDisplayColourVolume=") }, "\(r.commands)")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--qpa 0") }, "PQ turns QPA off: \(r.commands)")
        XCTAssertEqual(r.stream.primaries, "bt2020"); XCTAssertEqual(r.stream.transfer, "smpte2084"); XCTAssertEqual(r.stream.matrix, "bt2020nc")
        XCTAssertTrue(r.stream.side.contains("Mastering display metadata"), r.stream.side)
        XCTAssertTrue(r.stream.side.contains("Content light level metadata"), r.stream.side)
        XCTAssertGreaterThan(r.vmaf, 80, "VMAF \(r.vmaf)"); XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
    }

    func testVVenCHLGExportSignalsHLGInTheVUI() async throws {
        let r = try await runTuned(codec: .vvc, kind: .realLife, delivery: .hlg, rung: "medium")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--hdr hlg_2020") && $0.contains("TransferCharacteristics=18") }, "\(r.commands)")
        XCTAssertEqual(r.stream.primaries, "bt2020"); XCTAssertEqual(r.stream.transfer, "arib-std-b67")
        XCTAssertGreaterThan(r.vmaf, 80, "VMAF \(r.vmaf)")
    }

    // libaom: 12-bit 4:2:2 / 4:4:4 now export.

    func testLibaom12Bit444ExportIsProfessionalProfile() async throws {
        let r = try await runTuned(codec: .av1Pro, kind: .realLife, delivery: .hdr10, rung: "c6", bitDepth: 12, chroma: .c444)
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--profile=0") && $0.contains("--bit-depth=12") }, "\(r.commands)")
        XCTAssertEqual(r.stream.profile, "Professional")
        XCTAssertEqual(r.stream.pixFmt, "yuv444p12le")
        XCTAssertEqual(r.stream.transfer, "smpte2084")
        XCTAssertGreaterThan(r.vmaf, 80, "VMAF \(r.vmaf)"); XCTAssertGreaterThan(r.xpsnr, 32, "XPSNR \(r.xpsnr)")
    }

    func testLibaomTunedGrainyExportCodesTheGrain() async throws {
        let r = try await runTuned(codec: .av1Pro, kind: .realLifeHeavyGrain, delivery: .sdr, noisy: true, rung: "c4")
        XCTAssertTrue(r.commands.allSatisfy { $0.contains("--cpu-used=4") }, "\(r.commands)")
        XCTAssertTrue(r.commands.allSatisfy { !$0.contains("--denoise-noise-level") && !$0.contains("--enable-qm") },
                      "neither libaom grain synthesis nor QM is recommended any more: \(r.commands)")
        XCTAssertEqual(r.stream.profile, "Main")
        XCTAssertGreaterThan(r.vmaf, 70, "VMAF \(r.vmaf)")
    }

    func testLibaom12Bit422Export() async throws {
        let r = try await runTuned(codec: .av1Pro, kind: .realLife, delivery: .sdr, rung: "c6", bitDepth: 12, chroma: .c422)
        XCTAssertEqual(r.stream.profile, "Professional")
        XCTAssertEqual(r.stream.pixFmt, "yuv422p12le")
        XCTAssertGreaterThan(r.vmaf, 85, "VMAF \(r.vmaf)")
    }
}
