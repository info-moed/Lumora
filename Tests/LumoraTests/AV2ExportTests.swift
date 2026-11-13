import XCTest
@testable import Lumora

/// AV2 through the AVM reference encoder (avmenc) and decoder (avmdec), which scripts/install-encoders.sh builds
/// from the official repository. FFmpeg can't read AV2, so every export is decoded with avmdec and checked by
/// frame index: frame count, size, chroma format and bit depth from the decoded Y4M, color signaling from the
/// stream's content interpretation OBU (AV2Stream), and luma PSNR against the same job rendered as ProRes 4444 XQ.
/// Skipped when AVM isn't installed. Exports use speed 6 on small clips: AVM is a reference encoder and far too
/// slow for full-size test clips (see docs/features.md → AV2 for measured speeds).
@MainActor
final class AV2ExportTests: XCTestCase {
    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraAV2-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var sources: [String: Source] = [:]

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    struct Source { var descriptor: SourceDescriptor; var preset: PresetCandidate; var analysis: AnalysisResult; var peak: Float }

    func requireAVM() throws -> String {
        guard Codec.av2.available, let dec = ToolLocator.url(for: "avmdec")?.path else {
            throw XCTSkip("avmenc / avmdec not installed (scripts/install-encoders.sh builds them)")
        }
        return dec
    }

    // MARK: - Y4M

    struct Y4M {
        var width = 0, height = 0, bits = 8
        var chroma = "420"
        var luma: [[UInt16]] = []
        var frames: Int { luma.count }
    }

    static func readY4M(_ url: URL) throws -> Y4M {
        let data = try Data(contentsOf: url)
        guard let nl = data.firstIndex(of: 0x0A) else { throw LumoraError.decodeFailed("not a Y4M file") }
        var y = Y4M()
        for t in String(decoding: data[..<nl], as: UTF8.self).split(separator: " ") {
            switch t.first {
            case "W": y.width = Int(t.dropFirst()) ?? 0
            case "H": y.height = Int(t.dropFirst()) ?? 0
            case "C":
                let c = t.dropFirst()
                y.chroma = String(c.prefix(3))
                y.bits = c.contains("p10") ? 10 : (c.contains("p12") ? 12 : 8)
            default: break
            }
        }
        let bps = y.bits > 8 ? 2 : 1
        let (sx, sy) = y.chroma == "444" ? (1, 1) : (y.chroma == "422" ? (2, 1) : (2, 2))
        let lumaBytes = y.width * y.height * bps
        let frameBytes = lumaBytes + 2 * (y.width / sx) * (y.height / sy) * bps
        var pos = nl + 1
        while pos < data.endIndex, let eol = data[pos...].firstIndex(of: 0x0A) {
            pos = eol + 1
            guard pos + frameBytes <= data.endIndex else { break }
            let plane = data[pos..<(pos + lumaBytes)]
            y.luma.append(bps == 2 ? plane.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) } : plane.map { UInt16($0) })
            pos += frameBytes
        }
        return y
    }

    /// Decodes an AV2 stream to Y4M with avmdec (film grain applied unless skipped).
    static func decode(_ obu: URL, avmdec: String, skipGrain: Bool = false) throws -> Y4M {
        // The class tearDown removes `work`, and PlayerCodecRoundTripTests calls this after this class has finished.
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let out = work.appendingPathComponent(obu.deletingPathExtension().lastPathComponent + (skipGrain ? "-nograin" : "") + ".y4m")
        try EndToEndTests.sh(avmdec, (skipGrain ? ["--skip-film-grain"] : []) + [obu.path, "-o", out.path])
        defer { try? FileManager.default.removeItem(at: out) }
        return try readY4M(out)
    }

    static func psnr(_ a: [UInt16], _ b: [UInt16], bits: Int) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var se = 0.0
        for i in 0..<n { let d = Double(a[i]) - Double(b[i]); se += d * d }
        let peak = Double((1 << bits) - 1)
        return se == 0 ? 99 : 10 * log10(peak * peak / (se / Double(n)))
    }

    static func std(_ v: [UInt16]) -> Double {
        let m = v.reduce(0.0) { $0 + Double($1) } / Double(max(1, v.count))
        return (v.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(max(1, v.count))).squareRoot()
    }

    // MARK: - Sources and jobs

    /// Two shots (bars, then a moving test pattern) at 24 fps, 256×144, 12 frames.
    func source(hdr: Bool) async throws -> Source {
        let key = hdr ? "hdr" : "sdr"
        if let s = Self.sources[key] { return s }
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = Self.work.appendingPathComponent("src-\(key).mp4")
        let shots = "smptehdbars=s=256x144:r=24:d=0.25[a];testsrc2=s=256x144:r=24:d=0.25[b];[a][b]concat=n=2:v=1"
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex",
                    shots + (hdr ? ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le[v]" : ",format=yuv420p[v]"), "-map", "[v]"]
        if hdr {
            args += ["-c:v", "libx265", "-x265-params", "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                     "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        } else {
            args += ["-c:v", "libx264", "-crf", "8", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        try EndToEndTests.sh(ffmpeg, args + [url.path])
        let (d, colors) = try await SourceInspector.inspect(url)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let report = hdr ? HDRReportCard.make(title: key, descriptor: d, color: color, analysis: a) : nil
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: report)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        let s = Source(descriptor: d, preset: preset, analysis: a, peak: report?.p999Nits ?? 1000)
        Self.sources[key] = s
        return s
    }

    /// An AV2 job at AVM speed 6 (the fastest setting with its own speed features).
    func job(_ s: Source, delivery: DeliveryFormat, chroma: ChromaFormat = .c420, codec: Codec = .av2, name: String) -> ExportJob {
        var j = ExportJob(descriptor: s.descriptor, preset: s.preset, analysis: s.analysis, delivery: delivery, codec: codec,
                          outputURL: Self.work.appendingPathComponent(name))
        j.bitDepth = codec == .prores4444XQ ? 12 : 10
        j.chroma = codec == .prores4444XQ ? .c444 : chroma
        j.quality = 0.5
        j.sourcePeakNits = s.peak
        if codec == .av2 {
            j.encodeChoice = EncodeChoice(codec: .av2, rungID: "s6", rungLabel: "Speed 6", presetValue: "6", optionIDs: [], extraArgs: [])
        }
        try? FileManager.default.removeItem(at: j.outputURL)
        return j
    }

    /// The same render as near-lossless ProRes 4444 XQ, decoded to 10-bit luma by FFmpeg: the quality reference.
    func referenceLuma(_ s: Source, delivery: DeliveryFormat, name: String) async throws -> [[UInt16]] {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = try await ExportEngine().run(job(s, delivery: delivery, codec: .prores4444XQ, name: name + "-ref.mov")) { _, _ in }
        let y4m = Self.work.appendingPathComponent(name + "-ref.y4m")
        try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-pix_fmt", "yuv420p10le",
                                      "-strict", "-1", y4m.path])
        defer { for u in [url, y4m] { try? FileManager.default.removeItem(at: u) } }
        return try Self.readY4M(y4m).luma
    }

    // MARK: - Real exports

    /// Exports one delivery, decodes it, and checks everything the stream and its decode can tell.
    func exportAndCheck(hdrSource: Bool, delivery: DeliveryFormat, chroma: ChromaFormat = .c420,
                        cicp: (Int, Int, Int)) async throws {
        try TestHardware.requireGPU()
        let avmdec = try requireAVM()
        let s = try await source(hdr: hdrSource)
        let name = "av2-\(delivery.rawValue)-\(chroma.y4mTag)"
        let j = job(s, delivery: delivery, chroma: chroma, name: name + ".obu")
        XCTAssertNil(ExportEngine.validate(j))
        let start = Date()
        let url = try await ExportEngine().run(j) { _, _ in }
        let seconds = Date().timeIntervalSince(start)

        let stream = try AV2Stream.summary(of: url)
        let c = try XCTUnwrap(stream.color, "\(name): no color description in the stream")
        XCTAssertEqual(c.primaries, cicp.0, "\(name) primaries"); XCTAssertEqual(c.transfer, cicp.1, "\(name) transfer")
        XCTAssertEqual(c.matrix, cicp.2, "\(name) matrix"); XCTAssertFalse(c.fullRange, "\(name) must be limited range")
        if chroma != .c444 { XCTAssertEqual(stream.chromaSamplePosition, 1, "\(name): chroma siting should be signaled as center") }
        XCTAssertEqual(stream.sequenceHeaders, 1)

        let decoded = try Self.decode(url, avmdec: avmdec)
        XCTAssertEqual(decoded.frames, s.descriptor.frameCount, "\(name): every frame decodes")
        XCTAssertEqual(decoded.width, 256); XCTAssertEqual(decoded.height, 144)
        XCTAssertEqual(decoded.bits, 10, "\(name): 10-bit")
        XCTAssertEqual(decoded.chroma, chroma.y4mTag, "\(name): chroma format")

        let reference = try await referenceLuma(s, delivery: delivery, name: name)
        XCTAssertEqual(reference.count, decoded.frames)
        let scores = zip(decoded.luma, reference).map { Self.psnr($0, $1, bits: 10) }
        let mean = scores.reduce(0, +) / Double(max(1, scores.count))
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "AV2 %@: %d frames in %.1f s (%.2f fps at 256x144), %d bytes, luma PSNR vs ProRes mean %.2f dB, worst %.2f dB",
                     name, decoded.frames, seconds, Double(decoded.frames) / seconds, bytes, mean, scores.min() ?? 0))
        XCTAssertGreaterThan(mean, 36, "\(name): AV2 at the middle quality should be close to Lumora's own render")
        XCTAssertGreaterThan(scores.min() ?? 0, 30, "\(name): no broken frame")
        try? FileManager.default.removeItem(at: url)
    }

    func testSDRExport() async throws {
        try await exportAndCheck(hdrSource: false, delivery: .sdr, cicp: (1, 1, 1))
    }

    func testHDR10Export() async throws {
        try await exportAndCheck(hdrSource: true, delivery: .hdr10, cicp: (9, 16, 9))
    }

    func testHLGExport() async throws {
        try await exportAndCheck(hdrSource: true, delivery: .hlg, cicp: (9, 18, 9))
    }

    func test422And444Exports() async throws {
        try await exportAndCheck(hdrSource: false, delivery: .sdr, chroma: .c422, cicp: (1, 1, 1))
        try await exportAndCheck(hdrSource: true, delivery: .hdr10, chroma: .c444, cicp: (9, 16, 9))
    }

    // MARK: - Validation

    func testAV2OffersTenBitOnlyInEveryChroma() async throws {
        XCTAssertEqual(Codec.av2.bitDepths, [10], "AV2 v1.0 has no 12-bit profile; AVM's is test-only")
        XCTAssertEqual(Codec.av2.chromaFormats, [.c420, .c422, .c444])
        guard Codec.av2.available else { throw XCTSkip("avmenc not installed") }
        try TestHardware.requireGPU()
        let s = try await source(hdr: false)
        var twelve = job(s, delivery: .sdr, name: "twelve.obu")
        twelve.bitDepth = 12
        let msg = try XCTUnwrap(ExportEngine.validate(twelve))
        XCTAssertTrue(msg.contains("10-bit"), msg)
        for chroma in ChromaFormat.allCases {
            XCTAssertNil(ExportEngine.validate(job(s, delivery: .hdr10, chroma: chroma, name: "ok.obu")), chroma.label)
        }
    }

    func testEncoderFlagsAreAcceptedByAvmenc() throws {
        _ = try requireAVM()
        let spec = try XCTUnwrap(EncoderCatalog.shared.spec(for: "avm"))
        let help = try XCTUnwrap(EncodeRecipes.supportedFlags("avmenc"), "avmenc --help should list its flags")
        let all = spec.args + spec.hdrArgs + (spec.tunes ?? [:]).values.flatMap { $0 }
        for a in all where a.hasPrefix("--") {
            XCTAssertTrue(help.contains(String(a.split(separator: "=")[0])), "avmenc doesn't list \(a)")
        }
        XCTAssertTrue(spec.args.contains("--passes=1"), "AVM has one pass only; say so instead of relying on its default")
        XCTAssertEqual(spec.colorNames["hlg"]?["tc"], "hlg", "avmenc spells HLG 'hlg' (arib-std-b67 is rejected)")
        // The planner's AV2 recipe: every rung is a real speed and every extra is offered exactly when avmenc lists it.
        for kind in ContentKind.allCases {
            let recipe = EncodeRecipes.recipe(codec: .av2, kind: kind)
            XCTAssertEqual(recipe.rungs.map(\.presetValue), ["6", "5", "4"])
            for o in recipe.options {
                let flag = try XCTUnwrap(o.probeFlag)
                XCTAssertTrue(help.contains(flag), "avmenc doesn't list \(flag)")
                XCTAssertTrue(EncodeRecipes.available(o, codec: .av2), o.id)
            }
        }
        XCTAssertLessThan(EncodeRecipes.recipe(codec: .av2, kind: .realLife).baseFps1080, 0.1, "AVM runs far below 1 fps at 1080p")
    }

    // MARK: - Film grain

    /// AVM reads only its own "filmgrn2" table: a table in AV1's "filmgrn1" format is accepted without an error
    /// but no grain is coded. Lumora's AV2 table must produce grain of the strength it describes.
    func testFilmgrn2TableIsReadByAVMAndGrainMatches() throws {
        let avmdec = try requireAVM()
        guard let ffmpeg = EndToEndTests.ffmpeg, let avmenc = ToolLocator.url(for: "avmenc")?.path else { throw XCTSkip("FFmpeg not installed") }
        let flat = Self.work.appendingPathComponent("flat.y4m")
        try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x737373:s=128x96:r=24:d=0.125",
                                      "-pix_fmt", "yuv420p10le", "-strict", "-1", flat.path])
        let sigma: Float = 0.004
        let stats = GrainStats(sigmaPerBin: Array(repeating: sigma, count: Int(GRAIN_BINS)), overall: sigma)
        let av2Text = GrainTable.text(stats, bitDepth: 10, format: .av2)
        let lines = av2Text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.first, "filmgrn2")
        let p = lines.first { $0.hasPrefix("p ") }?.split(separator: " ").dropFirst().compactMap { Int($0) } ?? []
        XCTAssertEqual(p.count, 13, "filmgrn2 parameter line has 13 values (block_size last)")
        XCTAssertEqual(p.last, 0, "block_size 0 = 16x16, avmenc's default")
        // Scaling y = σ·1023·2^11 / 128 → the player adds y·128 / 2^11 code values.
        let y = Double(Int((Double(sigma) * 1023 * 2048 / 128).rounded()))
        let wanted = y * 128 / 2048

        var measured: [String: (grain: Double, none: Double)] = [:]
        for format in [GrainTable.Format.av2, .av1] {
            let tag = format == .av2 ? "g2" : "g1"
            let tbl = Self.work.appendingPathComponent("\(tag).tbl"), obu = Self.work.appendingPathComponent("\(tag).obu")
            try GrainTable.write(stats, bitDepth: 10, format: format, to: tbl)
            try EndToEndTests.sh(avmenc, [flat.path, "--obu", "-o", obu.path, "--passes=1", "--cpu-used=6", "--end-usage=q", "--qp=100",
                                          "--bit-depth=10", "--threads=2", "--quiet", "--film-grain-table=\(tbl.path)"])
            let grain = try Self.decode(obu, avmdec: avmdec), none = try Self.decode(obu, avmdec: avmdec, skipGrain: true)
            XCTAssertEqual(grain.frames, 3)
            measured[tag] = (grain.luma.map(Self.std).reduce(0, +) / 3, none.luma.map(Self.std).reduce(0, +) / 3)
            for u in [tbl, obu] { try? FileManager.default.removeItem(at: u) }
        }
        let g2 = try XCTUnwrap(measured["g2"]), g1 = try XCTUnwrap(measured["g1"])
        print(String(format: "AV2 GRAIN: table wants σ %.2f codes; filmgrn2 decodes to σ %.2f (%.2f without grain); filmgrn1 to σ %.2f",
                     wanted, g2.grain, g2.none, g1.grain))
        XCTAssertEqual(g2.grain, wanted, accuracy: wanted * 0.15, "filmgrn2 grain strength should match the table")
        XCTAssertLessThan(g2.none, 0.5, "the flat picture itself has no texture")
        XCTAssertLessThan(g1.grain, 0.5, "an AV1 filmgrn1 table is ignored by AVM (this is why AV2 gets filmgrn2)")
    }

    /// Film texture on an AV2 export travels as grain parameters: decoding with grain adds texture, decoding with
    /// --skip-film-grain gives the clean picture back.
    func testFilmTextureAV2Export() async throws {
        try TestHardware.requireGPU()
        let avmdec = try requireAVM()
        let s = try await source(hdr: false)
        var j = job(s, delivery: .sdr, name: "av2-texture.obu")
        j.filmTexture = .heavy
        let url = try await ExportEngine().run(j) { _, _ in }
        let grain = try Self.decode(url, avmdec: avmdec), clean = try Self.decode(url, avmdec: avmdec, skipGrain: true)
        XCTAssertEqual(grain.frames, s.descriptor.frameCount)
        let diffs = zip(grain.luma, clean.luma).map { g, c in Self.std(zip(g, c).map { UInt16(clamping: Int($0) - Int($1) + 512) }) }
        let added = diffs.reduce(0, +) / Double(max(1, diffs.count))
        print(String(format: "AV2 film texture: decoded grain adds σ %.2f codes (10-bit)", added))
        XCTAssertGreaterThan(added, 1.0, "film texture should reach the player as AV2 grain")

        let plain = try await ExportEngine().run(job(s, delivery: .sdr, name: "av2-plain.obu")) { _, _ in }
        let pg = try Self.decode(plain, avmdec: avmdec), pc = try Self.decode(plain, avmdec: avmdec, skipGrain: true)
        XCTAssertEqual(pg.luma, pc.luma, "without film texture there is no grain to apply")
        for u in [url, plain] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: - Joins and the stream reader

    /// Long exports are encoded in segments and joined by concatenating their OBU streams; avmdec must play the
    /// joined stream through, with one sequence header per segment.
    func testConcatenatedSegmentsDecodeThrough() throws {
        let avmdec = try requireAVM()
        guard let ffmpeg = EndToEndTests.ffmpeg, let avmenc = ToolLocator.url(for: "avmenc")?.path else { throw XCTSkip("FFmpeg not installed") }
        var parts: [URL] = []
        for (i, src) in ["testsrc2", "smptehdbars"].enumerated() {
            let y4m = Self.work.appendingPathComponent("part\(i).y4m"), obu = Self.work.appendingPathComponent("part\(i).obu")
            try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "\(src)=s=128x96:r=24:d=0.25",
                                          "-pix_fmt", "yuv420p10le", "-strict", "-1", y4m.path])
            try EndToEndTests.sh(avmenc, [y4m.path, "--obu", "-o", obu.path, "--passes=1", "--cpu-used=6", "--end-usage=q", "--qp=120",
                                          "--bit-depth=10", "--threads=2", "--quiet", "--color-primaries=bt709",
                                          "--transfer-characteristics=bt709", "--matrix-coefficients=bt709"])
            parts.append(obu)
        }
        let joined = Self.work.appendingPathComponent("joined.obu")
        try Data(try parts.map { try Data(contentsOf: $0) }.joined()).write(to: joined)
        let s = try AV2Stream.summary(of: joined)
        XCTAssertEqual(s.sequenceHeaders, 2)
        XCTAssertEqual(s.color?.descriptionIDC, 1, "BT.709 SDR uses the short color description")
        XCTAssertEqual(try Self.decode(joined, avmdec: avmdec).frames, 12)
    }

    /// A hand-built stream: temporal delimiter, sequence header, and a content interpretation OBU saying BT.2100 PQ
    /// (color_description_idc 2) with center chroma siting.
    func testStreamReaderParsesContentInterpretation() throws {
        let bytes: [UInt8] = [0x01, 0x08,                // TD
                              0x02, 0x04, 0x00,          // sequence header (payload not parsed)
                              0x04, 0x60, 0x30, 0x44, 0x80]   // CI: color + chroma position present; idc 2; limited; csp 1, 1
        let s = try AV2Stream.summary(of: Data(bytes))
        XCTAssertEqual(s.temporalUnits, 1)
        XCTAssertEqual(s.color, AV2Stream.ColorInfo(descriptionIDC: 2, primaries: 9, transfer: 16, matrix: 9, fullRange: false))
        XCTAssertEqual(s.chromaSamplePosition, 1)
        XCTAssertThrowsError(try AV2Stream.summary(of: Data([0x7F, 0x04])), "a size running past the end is not a stream")
        XCTAssertThrowsError(try AV2Stream.summary(of: Data("YUV4MPEG2 W2 H2".utf8)))
    }

    // MARK: - Speed (opt-in: minutes per run)

    /// AVM speed at 720p through the real engine. Run with TEST_RUNNER_LUMORA_AV2_SPEED=1.
    func testSpeedAt720p() async throws {
        guard ProcessInfo.processInfo.environment["LUMORA_AV2_SPEED"] == "1" else { throw XCTSkip("set TEST_RUNNER_LUMORA_AV2_SPEED=1") }
        try TestHardware.requireGPU()
        let avmdec = try requireAVM()
        let url = try EndToEndTests.makeClip("av2-speed-sdr.mp4", hdr: false)
        let (d, colors) = try await SourceInspector.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        let preset = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)[0]
        let frames = Int(ProcessInfo.processInfo.environment["LUMORA_AV2_FRAMES"] ?? "") ?? 12
        for speed in (ProcessInfo.processInfo.environment["LUMORA_AV2_PRESETS"] ?? "6,5").split(separator: ",").map(String.init) {
            var j = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: .sdr, codec: .av2,
                              outputURL: Self.work.appendingPathComponent("speed-\(speed).obu"))
            j.quality = 0.5
            j.frameRange = 0..<frames
            j.encodeChoice = EncodeChoice(codec: .av2, rungID: "s\(speed)", rungLabel: "Speed \(speed)", presetValue: speed, optionIDs: [], extraArgs: [])
            let start = Date()
            let out = try await ExportEngine().run(j) { _, _ in }
            let t = Date().timeIntervalSince(start)
            let decoded = try Self.decode(out, avmdec: avmdec)
            XCTAssertEqual(decoded.frames, frames)
            XCTAssertEqual(decoded.width, 1280)
            let bytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print(String(format: "AV2 SPEED 1280x720 speed %@: %d frames in %.1f s = %.3f fps, %d bytes", speed, frames, t, Double(frames) / t, bytes))
            try? FileManager.default.removeItem(at: out)
        }
    }
}
