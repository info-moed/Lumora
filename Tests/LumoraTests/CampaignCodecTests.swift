import XCTest
import CoreMedia
@testable import Lumora

/// Every codec × every bit depth and chroma it claims × SDR / HDR10 / HLG, from SDR and from HDR10 (PQ) sources,
/// through the real engine (GPU grade, VideoToolbox or the real CLI encoders, join with audio). Each output is
/// checked with ffprobe (codec, profile, pixel format, color tags, range, frame count, container, audio) and by
/// decoding it (mean luma, spread), plus HDR10 static metadata, quality extremes, multi-segment joins and validation.
@MainActor
final class CampaignCodecTests: XCTestCase {

    // MARK: - Sources

    struct Source {
        var name: String
        var url: URL
        var descriptor: SourceDescriptor
        var preset: PresetCandidate
        var analysis: AnalysisResult
        var sourcePeak: Float
        var frames: Int
    }

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoraCodecCampaign-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var cache: [String: Source] = [:]

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    static func ffmpegPath() throws -> String {
        guard let f = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        return f
    }

    /// Two 0.5 s shots (24 fps, hard cut) with a sine tone, 384×216 (a multiple of 8 but not 16, like 1080p).
    func barsSource(hdr: Bool) async throws -> Source {
        let name = hdr ? "hdr10" : "sdr"
        if let s = Self.cache[name] { return s }
        let ffmpeg = try Self.ffmpegPath()
        let url = Self.work.appendingPathComponent("src-\(name).mp4")
        let shots = "testsrc2=s=384x216:r=24:d=0.5[a];smptehdbars=s=384x216:r=24:d=0.5[b];[a][b]concat=n=2:v=1"
        let graph = shots + (hdr ? ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le[v]" : ",format=yuv420p[v]")
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex", graph,
                    "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000:d=1", "-map", "[v]", "-map", "0:a"]
        if hdr {
            args += ["-c:v", "libx265", "-x265-params", "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                     "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        } else {
            args += ["-c:v", "libx264", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        args += ["-c:a", "aac", "-b:a", "96k", "-shortest", url.path]
        try EndToEndTests.sh(ffmpeg, args)
        let s = try await prepare(name: name, url: url)
        Self.cache[name] = s
        return s
    }

    /// A 16×16 white box moving 4 px per frame over gray, 22 s at 24 fps (528 frames, so the engine splits it
    /// into several segments). The box position encodes the frame index, so a dropped or duplicated frame at a
    /// segment join shows up as a position error.
    func movingBoxSource() async throws -> Source {
        if let s = Self.cache["box"] { return s }
        let ffmpeg = try Self.ffmpegPath()
        let url = Self.work.appendingPathComponent("src-box.mp4")
        let graph = "color=c=0x404040:s=256x144:r=24:d=22[bg];color=c=white:s=16x16:r=24:d=22[box];"
            + "[bg][box]overlay=x='mod(n*4,240)':y='mod(floor(n/60)*16,128)':eval=frame,format=yuv420p[v]"
        try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex", graph,
                                      "-f", "lavfi", "-i", "sine=f=300:sample_rate=48000:d=22",
                                      "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-g", "48", "-crf", "12",
                                      "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                                      "-c:a", "aac", "-b:a", "64k", "-shortest", url.path])
        let s = try await prepare(name: "box", url: url)
        Self.cache["box"] = s
        return s
    }

    /// Inspect → analyze → auto presets, as AppModel's batch path does.
    func prepare(name: String, url: URL) async throws -> Source {
        let (d, colors) = try await SourceInspector.inspect(url)
        let color = try XCTUnwrap(colors.first, "no color interpretation for \(name)")
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let report = (color.transfer == .pq || color.transfer == .hlg)
            ? HDRReportCard.make(title: name, descriptor: d, color: color, analysis: a) : nil
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: report)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first, "no presets")
        // The expected frame count comes from ffprobe, never from Lumora's own inspection of the file.
        let truth = try Self.fullProbe(url)
        XCTAssertEqual(d.frameCount, truth.frames, "\(name): inspector frame count")
        XCTAssertEqual(Double(d.fpsNum) / Double(d.fpsDen), 24, accuracy: 0.001, "\(name): inspector frame rate")
        return Source(name: name, url: url, descriptor: d, preset: preset, analysis: a,
                      sourcePeak: report?.p999Nits ?? 1000, frames: truth.frames)
    }

    func job(_ s: Source, codec: Codec, depth: Int, chroma: ChromaFormat, delivery: DeliveryFormat,
             out: String, quality: Float = 0.5) -> ExportJob {
        var j = ExportJob(descriptor: s.descriptor, preset: s.preset, analysis: s.analysis, delivery: delivery,
                          codec: codec, outputURL: Self.work.appendingPathComponent(out))
        j.bitDepth = depth
        j.chroma = chroma
        j.quality = quality
        j.sourcePeakNits = s.sourcePeak
        try? FileManager.default.removeItem(at: j.outputURL)
        return j
    }

    // MARK: - Probing

    struct FullProbe {
        var format: String
        var video: [String: Any]
        var audioStreams: Int
        var frames: Int
        func s(_ k: String) -> String { (video[k] as? String) ?? "" }
    }

    static func ffprobeJSON(_ args: [String]) throws -> [String: Any] {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let out = try EndToEndTests.sh(ffprobe, ["-v", "error", "-of", "json"] + args)
        return (try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
    }

    static func fullProbe(_ url: URL) throws -> FullProbe {
        let j = try ffprobeJSON(["-count_frames", "-show_format", "-show_streams", url.path])
        let streams = (j["streams"] as? [[String: Any]]) ?? []
        let video = streams.first { ($0["codec_type"] as? String) == "video" } ?? [:]
        let audio = streams.filter { ($0["codec_type"] as? String) == "audio" }.count
        let fmt = ((j["format"] as? [String: Any])?["format_name"] as? String) ?? ""
        let frames = Int((video["nb_read_frames"] as? String) ?? "") ?? -1
        return FullProbe(format: fmt, video: video, audioStreams: audio, frames: frames)
    }

    /// Every side-data dictionary in the stream headers and the first frames.
    static func sideData(_ url: URL) throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        let st = try ffprobeJSON(["-select_streams", "v:0", "-show_streams", url.path])
        for s in (st["streams"] as? [[String: Any]]) ?? [] { all += (s["side_data_list"] as? [[String: Any]]) ?? [] }
        let fr = try ffprobeJSON(["-select_streams", "v:0", "-read_intervals", "%+#3", "-show_frames", url.path])
        for f in (fr["frames"] as? [[String: Any]]) ?? [] { all += (f["side_data_list"] as? [[String: Any]]) ?? [] }
        return all
    }

    static func rational(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        let p = s.split(separator: "/")
        if p.count == 2, let a = Double(p[0]), let b = Double(p[1]), b != 0 { return a / b }
        return Double(s)
    }

    /// Mean, min and max of per-frame average luma (0...1 of the coded range) and the overall luma spread.
    struct LumaStats { var mean: Double; var minAvg: Double; var maxAvg: Double; var lowest: Double; var highest: Double }

    static func luma(_ url: URL) throws -> LumaStats {
        let ffmpeg = try ffmpegPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-i", url.path, "-vf", "format=gray16le,signalstats,metadata=print", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        func values(_ key: String) -> [Double] {
            text.split(separator: "\n").compactMap { l in
                guard let r = l.range(of: "lavfi.signalstats.\(key)=") else { return nil }
                return Double(l[r.upperBound...].trimmingCharacters(in: .whitespaces)).map { $0 / 65535 }
            }
        }
        let avg = values("YAVG"), lo = values("YMIN"), hi = values("YMAX")
        guard !avg.isEmpty else { return LumaStats(mean: -1, minAvg: -1, maxAvg: -1, lowest: -1, highest: -1) }
        return LumaStats(mean: avg.reduce(0, +) / Double(avg.count), minAvg: avg.min()!, maxAvg: avg.max()!,
                         lowest: lo.min() ?? -1, highest: hi.max() ?? -1)
    }

    // MARK: - Expectations

    static func expectedPixFmt(_ codec: Codec, depth: Int, chroma: ChromaFormat) -> String {
        switch codec {
        case .prores422HQ: return "yuv422p10le"
        case .prores4444XQ: return "yuv444p12le"     // ProRes 4444 is always coded at 12 bits
        default: return "yuv\(chroma.y4mTag)p\(depth)le"
        }
    }

    static func expectedProfile(_ codec: Codec, depth: Int, chroma: ChromaFormat) -> [String] {
        switch codec {
        case .hevc: return ["Main 10"]
        case .prores422HQ: return ["HQ"]
        case .prores4444XQ: return ["XQ", "4444XQ"]   // FFmpeg names this profile "XQ"
        case .av1: return ["Main"]
        case .av1Pro:
            if depth == 12 || chroma == .c422 { return ["Professional"] }
            return chroma == .c444 ? ["High"] : ["Main"]
        case .vvc: return ["Main 10", "Main10", "unknown"]   // FFmpeg 9 has no names for VVC profiles yet
        case .av2: return []
        case .hevc12: return depth == 10 && chroma == .c420 ? ["Main 10"] : ["Rext", "Format Range Extensions"]
        }
    }

    static func expectedCodecName(_ codec: Codec) -> String {
        switch codec {
        case .hevc, .hevc12: return "hevc"
        case .prores422HQ, .prores4444XQ: return "prores"
        case .av1, .av1Pro: return "av1"
        case .vvc: return "vvc"
        case .av2: return "av2"
        }
    }

    static func expectedColor(_ d: DeliveryFormat) -> (prim: String, trc: String, space: String) {
        switch d.target.0 {
        case .sdr: return ("bt709", "bt709", "bt709")
        case .hdr10: return ("bt2020", "smpte2084", "bt2020nc")
        case .hlg: return ("bt2020", "arib-std-b67", "bt2020nc")
        }
    }

    static func expectedFormat(_ ext: String) -> String {
        switch ext {
        case "mov", "mp4": return "mov"
        case "mkv": return "matroska"
        default: return ext
        }
    }

    // MARK: - The matrix

    /// Exports one combination and checks everything ffprobe and a decode can tell us. Returns problems found.
    func exportAndCheck(_ s: Source, codec: Codec, depth: Int, chroma: ChromaFormat, delivery: DeliveryFormat) async -> [String] {
        let ext = codec.defaultContainer
        let label = "\(codec.rawValue) \(depth)-bit \(chroma.label) \(delivery.rawValue) from \(s.name)"
        let name = "\(codec.rawValue)-\(depth)-\(chroma.y4mTag)-\(delivery.rawValue)-\(s.name).\(ext)"
        var problems: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { problems.append("\(label): \(what())") } }
        do {
            let j = job(s, codec: codec, depth: depth, chroma: chroma, delivery: delivery, out: name)
            XCTAssertNil(ExportEngine.validate(j), "\(label) should validate")
            let url = try await ExportEngine().run(j) { _, _ in }
            check(url == j.outputURL, "returned \(url.lastPathComponent), expected \(name)")
            check(url.pathExtension == ext, "extension \(url.pathExtension) != \(ext)")
            let p = try Self.fullProbe(url)
            check(p.format.contains(Self.expectedFormat(ext)), "container \(p.format), expected \(Self.expectedFormat(ext))")
            check(p.s("codec_name") == Self.expectedCodecName(codec), "codec \(p.s("codec_name"))")
            let profiles = Self.expectedProfile(codec, depth: depth, chroma: chroma)
            check(profiles.contains(p.s("profile")), "profile \(p.s("profile")), expected \(profiles)")
            let pix = Self.expectedPixFmt(codec, depth: depth, chroma: chroma)
            check(p.s("pix_fmt") == pix || p.s("pix_fmt") == pix.replacingOccurrences(of: "yuv", with: "yuva"),
                  "pix_fmt \(p.s("pix_fmt")), expected \(pix)")
            let c = Self.expectedColor(delivery)
            check(p.s("color_primaries") == c.prim, "primaries \(p.s("color_primaries")), expected \(c.prim)")
            check(p.s("color_transfer") == c.trc, "transfer \(p.s("color_transfer")), expected \(c.trc)")
            check(p.s("color_space") == c.space, "matrix \(p.s("color_space")), expected \(c.space)")
            check(p.s("color_range") == "tv", "range \(p.s("color_range")), expected tv")
            check(p.frames == s.frames, "\(p.frames) frames, expected \(s.frames)")
            check(p.s("r_frame_rate") == "24/1", "frame rate \(p.s("r_frame_rate")), expected 24/1")
            check(p.audioStreams == 1, "\(p.audioStreams) audio streams, expected the source's 1")
            let y = try Self.luma(url)
            check(y.mean > 0.12 && y.mean < 0.85, String(format: "mean luma %.3f (black or blown out)", y.mean))
            check(y.minAvg > 0.05, String(format: "darkest frame average %.3f (black frame)", y.minAvg))
            check(y.highest - y.lowest > 0.3, String(format: "luma spread %.3f..%.3f (flat picture)", y.lowest, y.highest))
            if delivery == .hdr10 {
                let sd = try Self.sideData(url)
                let mdcv = sd.first { ($0["side_data_type"] as? String) == "Mastering display metadata" }
                let cll = sd.first { ($0["side_data_type"] as? String) == "Content light level metadata" }
                check(mdcv != nil, "no mastering display metadata")
                check(cll != nil, "no content light level metadata")
                if let mdcv {
                    let peak = Self.rational(mdcv["max_luminance"]) ?? 0
                    check(abs(peak - Double(j.target.effectivePeak)) < 1, "mastering peak \(peak), expected \(j.target.effectivePeak)")
                    check((Self.rational(mdcv["red_x"]) ?? 0) > 0.6, "mastering primaries missing: \(mdcv)")
                }
                if let cll {
                    let maxCLL = (cll["max_content"] as? Int) ?? -1, maxFALL = (cll["max_average"] as? Int) ?? -1
                    check(maxCLL > 0 && maxCLL <= 10000, "MaxCLL \(maxCLL)")
                    check(maxFALL > 0 && maxFALL <= maxCLL, "MaxFALL \(maxFALL) (MaxCLL \(maxCLL))")
                }
            }
            print("CAMPAIGN \(label): ok=\(problems.isEmpty) \(p.s("profile")) \(p.s("pix_fmt")) \(p.frames)f "
                  + String(format: "Y=%.3f [%.3f..%.3f]", y.mean, y.lowest, y.highest))
            try? FileManager.default.removeItem(at: url)
        } catch let e as XCTSkip {
            problems.append("\(label): skipped \(e)")
        } catch {
            problems.append("\(label): export failed: \(error.localizedDescription)")
        }
        return problems
    }

    func runMatrix(_ codec: Codec) async throws {
        try TestHardware.requireGPU()
        if codec.isHardware, codec == .hevc { try TestHardware.requireHardwareHEVC() }
        guard codec.available else { throw XCTSkip("\(codec.displayName): encoder not installed") }
        let sources = [try await barsSource(hdr: false), try await barsSource(hdr: true)]
        var problems: [String] = []
        var combos = 0
        for s in sources {
            for depth in codec.bitDepths {
                for chroma in codec.chromaFormats {
                    guard codec.supports(bitDepth: depth, chroma: chroma) else {
                        // A claimed-but-unencodable pair must be refused up front, with a reason.
                        let j = job(s, codec: codec, depth: depth, chroma: chroma, delivery: .sdr, out: "x.\(codec.defaultContainer)")
                        XCTAssertTrue(ExportEngine.validate(j)?.contains("can't encode \(depth)-bit \(chroma.label)") == true,
                                      "\(codec) \(depth)-bit \(chroma.label): \(ExportEngine.validate(j) ?? "accepted")")
                        continue
                    }
                    for delivery in [DeliveryFormat.sdr, .hdr10, .hlg] where delivery.supported(by: codec) {
                        combos += 1
                        problems += await exportAndCheck(s, codec: codec, depth: depth, chroma: chroma, delivery: delivery)
                    }
                }
            }
        }
        let pairs = codec.bitDepths.flatMap { d in codec.chromaFormats.filter { codec.supports(bitDepth: d, chroma: $0) } }.count
        XCTAssertEqual(combos, 2 * pairs * 3)
        for p in problems { XCTFail(p) }
    }

    func testMatrixHEVC() async throws { try await runMatrix(.hevc) }
    func testMatrixProRes422HQ() async throws { try await runMatrix(.prores422HQ) }
    func testMatrixProRes4444XQ() async throws { try await runMatrix(.prores4444XQ) }
    func testMatrixAV1() async throws { try await runMatrix(.av1) }
    func testMatrixAV1Pro() async throws { try await runMatrix(.av1Pro) }
    func testMatrixVVC() async throws { try await runMatrix(.vvc) }
    func testMatrixHEVC12() async throws { try await runMatrix(.hevc12) }

    // MARK: - AV2 (encoder not installed here)

    func testAV2MissingEncoderIsReportedCleanly() async throws {
        let s = try await barsSource(hdr: false)
        guard !Codec.av2.available else { throw XCTSkip("avmenc is installed on this Mac; this test covers its absence") }
        XCTAssertEqual(Codec.av2.cliKey, "avm")
        XCTAssertEqual(Codec.av2.defaultContainer, "obu")
        for depth in Codec.av2.bitDepths {
            for delivery in [DeliveryFormat.sdr, .hdr10, .hlg] {
                let j = job(s, codec: .av2, depth: depth, chroma: .c420, delivery: delivery, out: "av2-\(depth)-\(delivery.rawValue).obu")
                let msg = try XCTUnwrap(ExportEngine.validate(j), "AV2 without avmenc must not validate")
                XCTAssertTrue(msg.contains("avmenc"), "message should name the missing program: \(msg)")
                XCTAssertTrue(msg.contains("isn't installed"), msg)
                do {
                    _ = try await ExportEngine().run(j) { _, _ in }
                    XCTFail("AV2 export ran without its encoder")
                } catch {
                    XCTAssertEqual(error.localizedDescription, msg)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: j.outputURL.path), "no output file may be left behind")
            }
        }
    }

    // MARK: - Validation

    func testValidateAcceptsExactlyTheClaimedCombinations() async throws {
        let s = try await barsSource(hdr: false)
        for codec in Codec.allCases {
            for depth in [8, 10, 12, 16] {
                for chroma in ChromaFormat.allCases {
                    for delivery in DeliveryFormat.allCases {
                        let j = job(s, codec: codec, depth: depth, chroma: chroma, delivery: delivery, out: "v.\(codec.defaultContainer)")
                        let msg = ExportEngine.validate(j)
                        let label = "\(codec.rawValue) \(depth)-bit \(chroma.label) \(delivery.rawValue)"
                        if !codec.bitDepths.contains(depth) {
                            XCTAssertTrue(msg?.contains("can't do \(depth)-bit") == true, "\(label): \(msg ?? "accepted")")
                        } else if !codec.chromaFormats.contains(chroma) {
                            XCTAssertTrue(msg?.contains("supports") == true && msg?.contains(chroma.label) == false,
                                          "\(label): \(msg ?? "accepted")")
                        } else if !codec.supports(bitDepth: depth, chroma: chroma) {
                            XCTAssertTrue(msg?.contains("can't encode \(depth)-bit \(chroma.label)") == true, "\(label): \(msg ?? "accepted")")
                        } else if !delivery.supported(by: codec) {
                            XCTAssertTrue(msg?.contains(delivery.displayName) == true, "\(label): \(msg ?? "accepted")")
                        } else if !codec.available {
                            XCTAssertTrue(msg?.contains("isn't installed") == true, "\(label): \(msg ?? "accepted")")
                        } else {
                            XCTAssertNil(msg, "\(label) is claimed but rejected")
                        }
                    }
                }
            }
        }
    }

    func testValidateNamedUnsupportedCombinations() async throws {
        let s = try await barsSource(hdr: false)
        func msg(_ c: Codec, _ d: Int, _ ch: ChromaFormat, _ del: DeliveryFormat) -> String {
            ExportEngine.validate(job(s, codec: c, depth: d, chroma: ch, delivery: del, out: "v.\(c.defaultContainer)")) ?? "<accepted>"
        }
        XCTAssertTrue(msg(.prores422HQ, 12, .c420, .hdr10).contains("can't do 12-bit"))
        XCTAssertTrue(msg(.prores422HQ, 10, .c420, .hdr10).contains("4:2:2"))
        XCTAssertTrue(msg(.prores4444XQ, 12, .c420, .hdr10).contains("4:4:4"))
        XCTAssertTrue(msg(.vvc, 12, .c420, .hdr10).contains("can't do 12-bit"))
        XCTAssertTrue(msg(.vvc, 10, .c444, .sdr).contains("4:2:0"))
        XCTAssertTrue(msg(.hevc, 12, .c420, .sdr).contains("Choose 10-bit"))
        XCTAssertTrue(msg(.hevc, 10, .c422, .sdr).contains("4:2:0"))
        XCTAssertTrue(msg(.av1, 12, .c420, .sdr).contains("can't do 12-bit"))
        XCTAssertTrue(msg(.av1Pro, 8, .c420, .sdr).contains("can't do 8-bit"))
        // aomenc refuses 12-bit 4:2:2 / 4:4:4; 12-bit 4:2:0 and 10-bit 4:4:4 stay available.
        XCTAssertTrue(msg(.av1Pro, 12, .c444, .hdr10).contains("can't encode 12-bit 4:4:4"))
        XCTAssertTrue(msg(.av1Pro, 12, .c422, .sdr).contains("can't encode 12-bit 4:2:2"))
        XCTAssertFalse(Codec.av1Pro.supports(bitDepth: 12, chroma: .c444))
        XCTAssertTrue(Codec.av1Pro.supports(bitDepth: 12, chroma: .c420))
        XCTAssertTrue(Codec.av1Pro.supports(bitDepth: 10, chroma: .c444))
        XCTAssertTrue(Codec.hevc12.supports(bitDepth: 12, chroma: .c444))
        XCTAssertFalse(Codec.av1.supportsHDR10Plus, "HDR10+ can't be injected into AV1")
        for c in Codec.allCases { XCTAssertTrue(msg(c, 8, c.chromaFormats[0], .sdr).contains("can't do 8-bit"), "\(c): 8-bit output must be rejected") }
        XCTAssertTrue(msg(.av1, 10, .c420, .dolbyVision81).contains("Dolby Vision"))
        XCTAssertTrue(msg(.av1Pro, 10, .c420, .dolbyVision84).contains("Dolby Vision"))
        XCTAssertTrue(msg(.vvc, 10, .c420, .dolbyVision81).contains("Dolby Vision"))
        XCTAssertTrue(msg(.prores422HQ, 10, .c422, .hdr10Plus).contains("HDR10+"))
        // x265 carries Dolby Vision 8.1 (dovi_tool injects the RPU after encoding; the output is verified with
        // dovi_tool in CampaignHDRMetadataTests). 8.4 is HLG-based and comes only from Apple's hardware encoder.
        XCTAssertEqual(msg(.hevc12, 10, .c420, .dolbyVision81), "<accepted>")
        let x265DV84 = msg(.hevc12, 10, .c420, .dolbyVision84)
        XCTAssertTrue(x265DV84.contains("Dolby Vision"), x265DV84)
        XCTAssertTrue(x265DV84.contains("hardware"), "should point to the hardware HEVC encoder: \(x265DV84)")
        // Slow motion + AV2, and overwriting the source.
        var slow = job(s, codec: .av2, depth: 10, chroma: .c420, delivery: .sdr, out: "v.obu")
        slow.interpolation.mode = .slowMotion(factor: 2)
        XCTAssertNotNil(ExportEngine.validate(slow))
        var over = job(s, codec: .hevc, depth: 10, chroma: .c420, delivery: .sdr, out: "v.mov")
        over.outputURL = s.url
        XCTAssertTrue(ExportEngine.validate(over)?.contains("overwrite the source") == true)
    }

    /// HDR10+ is offered for AV1; either it exports with dynamic metadata or validation must refuse it.
    func testHDR10PlusOnAV1IsEitherDeliveredOrRejected() async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let s = try await barsSource(hdr: true)
        let j = job(s, codec: .av1, depth: 10, chroma: .c420, delivery: .hdr10Plus, out: "av1-hdr10plus.mkv")
        if let msg = ExportEngine.validate(j) {
            XCTAssertTrue(msg.contains("HDR10+"), msg)
            return
        }
        do {
            let url = try await ExportEngine().run(j) { _, _ in }
            let sd = try Self.sideData(url)
            XCTAssertTrue(sd.contains { (($0["side_data_type"] as? String) ?? "").contains("2094-40") },
                          "HDR10+ AV1 export has no ST 2094-40 metadata")
        } catch {
            XCTFail("HDR10+ on AV1 passes validation but the export fails: \(error.localizedDescription)")
        }
    }

    /// Every codec that validation lets through with HDR10+ must actually carry ST 2094-40 metadata.
    func testHDR10PlusOnEveryCodecThatClaimsIt() async throws {
        try TestHardware.requireGPU()
        guard ToolLocator.isAvailable("hdr10plus_tool") else { throw XCTSkip("hdr10plus_tool not installed") }
        let s = try await barsSource(hdr: true)
        for codec in Codec.allCases where codec.supportsHDR10Plus && codec.available {
            if codec == .hevc && !TestHardware.hardwareEncoder(kCMVideoCodecType_HEVC) { continue }
            let j = job(s, codec: codec, depth: 10, chroma: .c420, delivery: .hdr10Plus, out: "hdr10plus-\(codec.rawValue).mkv")
            XCTAssertNil(ExportEngine.validate(j))
            do {
                let url = try await ExportEngine().run(j) { _, _ in }
                let p = try Self.fullProbe(url)
                XCTAssertEqual(p.s("codec_name"), "hevc", "\(codec)")
                XCTAssertEqual(p.s("color_transfer"), "smpte2084", "\(codec)")
                XCTAssertEqual(p.frames, s.frames, "\(codec)")
                let sd = try Self.sideData(url)
                XCTAssertTrue(sd.contains { (($0["side_data_type"] as? String) ?? "").contains("2094-40") },
                              "\(codec): HDR10+ export has no ST 2094-40 metadata (\(sd.compactMap { $0["side_data_type"] as? String }))")
                try? FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("\(codec): HDR10+ passes validation but the export fails: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Quality slider

    func testQualityExtremesChangeSizeInTheRightDirection() async throws {
        try TestHardware.requireGPU()
        let s = try await barsSource(hdr: false)
        for codec in [Codec.hevc, .av1, .av1Pro, .vvc, .hevc12] {
            if codec == .hevc && !TestHardware.hardwareEncoder(kCMVideoCodecType_HEVC) { continue }
            guard codec.available else { continue }
            var sizes: [Float: Int] = [:]
            for q: Float in [0, 1] {
                let j = job(s, codec: codec, depth: 10, chroma: .c420, delivery: .sdr,
                            out: "q\(Int(q))-\(codec.rawValue).\(codec.defaultContainer)", quality: q)
                let url = try await ExportEngine().run(j) { _, _ in }
                // Video payload only (the audio is the same in both).
                let p = try Self.ffprobeJSON(["-select_streams", "v:0", "-show_entries", "packet=size", url.path])
                sizes[q] = ((p["packets"] as? [[String: Any]]) ?? []).compactMap { Int(($0["size"] as? String) ?? "") }.reduce(0, +)
                XCTAssertEqual(try Self.fullProbe(url).frames, s.frames, "\(codec) q=\(q)")
                try? FileManager.default.removeItem(at: url)
            }
            let lo = sizes[0] ?? 0, hi = sizes[1] ?? 0
            print("CAMPAIGN quality \(codec.rawValue): q0=\(lo) q1=\(hi)")
            XCTAssertGreaterThan(lo, 0, "\(codec)")
            XCTAssertGreaterThan(Double(hi), Double(lo) * 1.3, "\(codec): quality 1 (\(hi) B) should be clearly bigger than quality 0 (\(lo) B)")
        }
    }

    /// The software encoders map quality 1 to their best CRF/QP and 0 to their worst.
    func testQualityMappingOfEverySoftwareEncoder() {
        for codec in Codec.allCases {
            guard let key = codec.cliKey else { continue }
            let spec = try? XCTUnwrap(EncoderCatalog.shared.spec(for: key), "\(key) missing from encoders.json")
            guard let spec else { continue }
            XCTAssertEqual(spec.qualityValue(1), String(Int(spec.qualityBest)), key)
            XCTAssertEqual(spec.qualityValue(0), String(Int(spec.qualityWorst)), key)
            XCTAssertLessThan(spec.qualityBest, spec.qualityWorst, "\(key): lower CRF/QP is better")
            XCTAssertEqual(spec.ext == "obu", codec == .av2)
        }
    }

    // MARK: - Multi-segment exports

    /// Decodes every frame and returns the center of the bright box in each (nil when there is none).
    static func boxPositions(_ url: URL, width: Int = 256, height: Int = 144) throws -> [SIMD2<Double>?] {
        let ffmpeg = try ffmpegPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-i", url.path, "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "gray", "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let size = width * height
        var result: [SIMD2<Double>?] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            for k in 0..<(data.count / size) {
                let base = k * size
                var lo = 255, hi = 0
                for i in 0..<size { let v = Int(b[base + i]); lo = min(lo, v); hi = max(hi, v) }
                let thr = (lo + hi) / 2
                var sx = 0.0, sy = 0.0, c = 0.0
                for y in 0..<height { for x in 0..<width where Int(b[base + y * width + x]) > thr { sx += Double(x); sy += Double(y); c += 1 } }
                result.append(hi - lo > 40 && c > 0 ? SIMD2(sx / c, sy / c) : nil)
            }
        }
        return result
    }

    func multiSegment(_ codec: Codec, forcedSegments: Int) async throws {
        try TestHardware.requireGPU()
        if codec == .hevc { try TestHardware.requireHardwareHEVC() }
        guard codec.available else { throw XCTSkip("\(codec.displayName) not installed") }
        let s = try await movingBoxSource()
        XCTAssertEqual(s.frames, 528)
        // Pin the segment count in memory only (never saved to disk), so the join is exercised on any Mac.
        let saved = MacProfile.current
        defer { MacProfile.current = saved }
        var profile = saved ?? MacProfile(machine: MacProfile.machineModel, chip: "test", os: MacProfile.osVersion,
                                          created: Date(), level: "test")
        if codec.isHardware { profile.vtSessions = forcedSegments } else { profile.cliInstances[codec.rawValue] = forcedSegments }
        MacProfile.current = profile
        XCTAssertEqual(ChipProfile.current.segments(for: codec, frameCount: s.frames), forcedSegments)

        let j = job(s, codec: codec, depth: 10, chroma: codec.chromaFormats[0], delivery: .sdr,
                    out: "multiseg-\(codec.rawValue).\(codec.defaultContainer)", quality: 0.9)
        var labels = Set<String>()
        let url = try await ExportEngine().run(j) { label, _ in labels.insert(label) }
        XCTAssertTrue(labels.contains { $0.contains("\(forcedSegments) parallel segments") }, "segments used: \(labels)")
        let p = try Self.fullProbe(url)
        XCTAssertEqual(p.frames, 528, "\(codec): frame count after joining \(forcedSegments) segments")
        XCTAssertEqual(p.audioStreams, 1, "\(codec): audio carried")
        // Frame k of the output must show the box exactly where frame k of the source does (moves 4 px a frame,
        // so a dropped or repeated frame at a segment join is a 4 px error from there on).
        let want = try Self.boxPositions(s.url), got = try Self.boxPositions(url)
        XCTAssertEqual(want.count, 528)
        XCTAssertEqual(got.count, 528)
        // Instrument check: every source frame differs from its neighbor by ≥ 3 px, so a slip can't hide.
        XCTAssertTrue(zip(want, want.dropFirst()).allSatisfy { a, b in
            guard let a, let b else { return false }
            return max(abs(a.x - b.x), abs(a.y - b.y)) >= 3
        }, "source box positions don't identify every frame")
        var bad: [Int] = []
        for k in 0..<min(want.count, got.count) {
            guard let w = want[k], let g = got[k], abs(w.x - g.x) <= 1.5, abs(w.y - g.y) <= 1.5 else { bad.append(k); continue }
        }
        XCTAssertTrue(bad.isEmpty, "\(codec): \(bad.count) frames out of place (dropped/duplicated at a join?), first: \(bad.prefix(10))")
        // Timestamps strictly increasing at constant rate.
        let pk = try Self.ffprobeJSON(["-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", url.path])
        let ts = ((pk["frames"] as? [[String: Any]]) ?? []).compactMap { Double(($0["best_effort_timestamp_time"] as? String) ?? "") }
        XCTAssertEqual(ts.count, 528)
        let steps = zip(ts, ts.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(steps.allSatisfy { abs($0 - 1.0 / 24) < 0.002 }, "\(codec): irregular frame timing, steps \(Set(steps.map { String(format: "%.4f", $0) }))")
        try? FileManager.default.removeItem(at: url)
    }

    func testMultiSegmentHardwareHEVC() async throws { try await multiSegment(.hevc, forcedSegments: 2) }
    func testMultiSegmentHardwareProRes() async throws { try await multiSegment(.prores422HQ, forcedSegments: 2) }
    func testMultiSegmentVVC() async throws { try await multiSegment(.vvc, forcedSegments: 3) }
    func testMultiSegmentSVTAV1() async throws { try await multiSegment(.av1, forcedSegments: 2) }
    func testMultiSegmentX265() async throws { try await multiSegment(.hevc12, forcedSegments: 2) }
    func testMultiSegmentLibaom() async throws { try await multiSegment(.av1Pro, forcedSegments: 3) }

    /// Without a measured profile the chip table must split long clips for parallel encoders and keep short ones whole.
    func testSegmentCountsFromChipTable() {
        let saved = MacProfile.current
        defer { MacProfile.current = saved }
        MacProfile.current = nil
        let chip = ChipProfile.current
        for codec in Codec.allCases {
            XCTAssertEqual(chip.segments(for: codec, frameCount: 480), 1, "\(codec): short clips stay in one segment")
            XCTAssertGreaterThanOrEqual(chip.segments(for: codec, frameCount: 481), 1)
        }
        XCTAssertEqual(chip.segments(for: .hevc, frameCount: 10_000), chip.videoEncodeEngines)
    }

    // MARK: - Audio

    func testAudioIsCarriedIntact() async throws {
        try TestHardware.requireGPU()
        let s = try await barsSource(hdr: false)
        for codec in [Codec.hevc, .prores422HQ, .av1, .hevc12] where codec.available {
            if codec == .hevc && !TestHardware.hardwareEncoder(kCMVideoCodecType_HEVC) { continue }
            let j = job(s, codec: codec, depth: 10, chroma: codec.chromaFormats[0], delivery: .sdr,
                        out: "audio-\(codec.rawValue).\(codec.defaultContainer)")
            let url = try await ExportEngine().run(j) { _, _ in }
            let pj = try Self.ffprobeJSON(["-select_streams", "a", "-show_streams", url.path])
            let a = try XCTUnwrap(((pj["streams"] as? [[String: Any]]) ?? []).first, "\(codec): no audio stream")
            XCTAssertEqual(a["codec_name"] as? String, "aac", "\(codec): audio should be copied, not re-encoded")
            XCTAssertEqual(a["sample_rate"] as? String, "48000")
            let fmt = try Self.ffprobeJSON(["-show_format", url.path])["format"] as? [String: Any]
            let dur = Self.rational(a["duration"]) ?? Self.rational(fmt?["duration"]) ?? 0
            XCTAssertEqual(dur, 1.0, accuracy: 0.1, "\(codec): audio duration")
            // The tone must still be there (not silence).
            let ffmpeg = try Self.ffmpegPath()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-i", url.path, "-map", "0:a:0", "-af", "volumedetect", "-f", "null", "-"]
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let mean = text.split(separator: "\n").compactMap { l -> Double? in
                guard let r = l.range(of: "mean_volume: ") else { return nil }
                return Double(l[r.upperBound...].replacingOccurrences(of: " dB", with: ""))
            }.first ?? -99
            XCTAssertGreaterThan(mean, -40, "\(codec): audio is silent (\(mean) dB)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
