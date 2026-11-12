import XCTest
@testable import Lumora

/// HDR10 static metadata, HDR10+ and Dolby Vision dynamic metadata, end to end: every export here is checked
/// with the tools that consume the metadata (hdr10plus_tool extract, dovi_tool extract-rpu / info / export,
/// ffprobe side data), not just for "no error thrown".
@MainActor
final class CampaignHDRMetadataTests: XCTestCase {

    // MARK: - Fixtures and instruments

    static let bin = "/opt/homebrew/bin"
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraHDRMeta-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    static func require(_ tools: String...) throws {
        for t in tools where !FileManager.default.isExecutableFile(atPath: "\(bin)/\(t)") {
            throw XCTSkip("\(t) is not installed in \(bin)")
        }
    }

    /// Runs a tool from /opt/homebrew/bin, stdout and stderr merged. Throws on a non-zero exit unless `allowFail`.
    @discardableResult
    static func tool(_ name: String, _ args: [String], cwd: URL? = nil, allowFail: Bool = false) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(bin)/\(name)")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        let out = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 && !allowFail {
            throw NSError(domain: name, code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(name) \(args.joined(separator: " ")) exited \(p.terminationStatus): \(out.suffix(1500))"])
        }
        return (p.terminationStatus, out)
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Full-range-normalised PQ signal for `nits` (SMPTE ST 2084).
    static func pq(_ nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(max(0, min(1, nits / 10000)), m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    /// The two-shot pattern (hard cut at frame 24) as a filter graph producing [v] in 10-bit PQ BT.2020 coding.
    static func twoShotGraph(w: Int, h: Int, letterbox: Int = 0) -> String {
        let ih = h - 2 * letterbox
        var g = "testsrc2=s=\(w)x\(ih):r=24:d=1[a];smptehdbars=s=\(w)x\(ih):r=24:d=1[b];[a][b]concat=n=2:v=1"
        if letterbox > 0 { g += ",pad=\(w):\(h):0:\(letterbox):black" }
        return g + ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le[v]"
    }

    static let x265PQ = "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:repeat-headers=1"

    /// PQ HDR10 MP4 (HEVC 10-bit + AAC stereo), two shots, 48 frames.
    static func pqSource(_ name: String, w: Int = 1280, h: Int = 720, audio: Bool = true) throws -> URL {
        try require("ffmpeg")
        let out = url(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex", twoShotGraph(w: w, h: h)]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000"] }
        args += ["-map", "[v]"]
        if audio { args += ["-map", "0:a", "-c:a", "aac", "-b:a", "96k"] }
        args += ["-c:v", "libx265", "-x265-params", x265PQ, "-tag:v", "hvc1",
                 "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", out.path]
        try tool("ffmpeg", args)
        return out
    }

    /// A colourist-style RPU: per-shot L1 and an L2 100-nit trim, plus an L5 active area for the letterbox.
    static func colouristRPUJSON(frames: Int, letterbox: Int) -> String {
        """
        {"cm_version":"V40","profile":"8.1","length":\(frames),
         "level5":{"active_area_left_offset":0,"active_area_right_offset":0,"active_area_top_offset":\(letterbox),"active_area_bottom_offset":\(letterbox)},
         "level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":50,"max_content_light_level":1000,"max_frame_average_light_level":300},
         "shots":[
          {"start":0,"duration":24,"metadata_blocks":[{"Level1":{"min_pq":0,"max_pq":3001,"avg_pq":1501}},
            {"Level2":{"target_max_pq":2081,"trim_slope":2148,"trim_offset":2048,"trim_power":2048,"trim_chroma_weight":2048,"trim_saturation_gain":2048,"ms_weight":2048}}]},
          {"start":24,"duration":\(frames - 24),"metadata_blocks":[{"Level1":{"min_pq":0,"max_pq":2701,"avg_pq":1201}},
            {"Level2":{"target_max_pq":2081,"trim_slope":1948,"trim_offset":2048,"trim_power":2048,"trim_chroma_weight":2048,"trim_saturation_gain":2048,"ms_weight":2048}}]}]}
        """
    }

    /// Dolby Vision profile 8.1 source (HEVC Main10 PQ + RPU, MP4 with a dvcC record), 1280×720 with 88-px bars.
    /// (720p, not smaller: sources of 576 lines or fewer go through FFmpeg's idet, which calls testsrc2 interlaced.)
    /// `rpuFrames` < 48 builds a mis-authored file whose last frames carry no RPU at all.
    static func dvSource(_ name: String, rpuFrames: Int = 48, letterbox: Int = 88) throws -> URL {
        try require("ffmpeg", "dovi_tool", "MP4Box")
        let out = url(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let work = url(name + ".work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        func encode(_ graphTail: String, _ file: String) throws {
            try tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y",
                                "-filter_complex", twoShotGraph(w: 1280, h: 720, letterbox: letterbox).replacingOccurrences(of: "[v]", with: graphTail),
                                "-map", "[v]", "-c:v", "libx265", "-x265-params", x265PQ, "-f", "hevc", work.appendingPathComponent(file).path])
        }
        try "\(colouristRPUJSON(frames: 48, letterbox: letterbox))".write(to: work.appendingPathComponent("rpu.json"), atomically: true, encoding: .utf8)
        try tool("dovi_tool", ["generate", "-j", "rpu.json", "-o", "rpu.bin"], cwd: work)
        try encode("[v]", "bl.hevc")
        if rpuFrames == 0 {
            // Mis-flagged file: the container says Dolby Vision 8.1, the stream has no RPUs at all.
            try FileManager.default.moveItem(at: work.appendingPathComponent("bl.hevc"), to: work.appendingPathComponent("dv.hevc"))
        } else {
            try tool("dovi_tool", ["inject-rpu", "-i", "bl.hevc", "--rpu-in", "rpu.bin", "-o", "dv.hevc"], cwd: work)
        }
        if rpuFrames > 0 && rpuFrames < 48 {
            // inject-rpu pads a short RPU to the video length, so instead drop the RPU NALs of the last access units.
            let dv = work.appendingPathComponent("dv.hevc")
            try stripRPUs(keepingAccessUnits: rpuFrames, in: Data(contentsOf: dv)).write(to: dv)
        }
        try tool("MP4Box", ["-add", "dv.hevc:dvp=8.1:fps=24", "-new", "src.mp4"], cwd: work)
        try FileManager.default.moveItem(at: work.appendingPathComponent("src.mp4"), to: out)
        return out
    }

    /// Removes Dolby Vision RPU NAL units (type 62) once `keep` access units (in decode order) have been seen.
    static func stripRPUs(keepingAccessUnits keep: Int, in data: Data) -> Data {
        let b = [UInt8](data)
        var starts: [Int] = []          // offsets of the start code of each NAL
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append(i > 0 && b[i - 1] == 0 ? i - 1 : i); i += 3
            } else { i += 1 }
        }
        var out = Data(), units = 0
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : b.count
            let header = b[s + 2] == 1 ? s + 3 : s + 4
            guard header + 2 < end else { out.append(contentsOf: b[s..<end]); continue }
            let type = (b[header] >> 1) & 0x3F
            if type < 32, b[header + 2] & 0x80 != 0 { units += 1 }          // first slice of a picture
            if type == 62, units > keep { continue }
            out.append(contentsOf: b[s..<end])
        }
        return out
    }

    /// Video stream as raw Annex-B HEVC (for hdr10plus_tool / dovi_tool).
    static func annexB(_ video: URL) throws -> URL {
        let out = url(video.lastPathComponent + ".\(UUID().uuidString.prefix(6)).hevc")
        try tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-map", "0:v:0", "-c:v", "copy",
                            "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", out.path])
        return out
    }

    struct RPUReport {
        var summary: String
        var frames: Int
        var profile: Int
        var l1: [[Int]]   // per frame: min_pq, max_pq, avg_pq
        var l2: [[Int]]   // per frame: target_max_pq, trim_slope, …
        var l5: [[Int]]   // per frame: left, right, top, bottom
        var rpu: URL
    }

    static func rpu(_ binRPU: URL) throws -> RPUReport {
        let summary = try tool("dovi_tool", ["info", "-i", binRPU.path, "-s"]).out
        func value(_ key: String) -> Int {
            guard let line = summary.split(separator: "\n").first(where: { $0.contains(key) }) else { return -1 }
            return Int(line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) ?? -1
        }
        let base = binRPU.deletingPathExtension().path
        try tool("dovi_tool", ["export", "-i", binRPU.path, "-l", "level1=\(base)-l1.csv,level2=\(base)-l2.csv,level5=\(base)-l5.csv"])
        func csv(_ suffix: String) -> [[Int]] {
            guard let text = try? String(contentsOfFile: "\(base)-\(suffix).csv", encoding: .utf8) else { return [] }
            return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",").dropFirst().compactMap { Int($0) } }
        }
        return RPUReport(summary: summary, frames: value("Frames:"), profile: value("Profile:"),
                         l1: csv("l1"), l2: csv("l2"), l5: csv("l5"), rpu: binRPU)
    }

    /// Extracts the RPU from a delivered file (MKV/MP4/MOV) with dovi_tool and parses it.
    static func rpuOf(_ video: URL) throws -> RPUReport {
        let hevc = try annexB(video)
        let bin = hevc.deletingPathExtension().appendingPathExtension("rpu.bin")
        try tool("dovi_tool", ["extract-rpu", "-i", hevc.path, "-o", bin.path])
        return try rpu(bin)
    }

    /// hdr10plus_tool extract → the parsed JSON (SceneInfo has one entry per frame).
    static func hdr10Plus(_ video: URL) throws -> [String: Any] {
        let hevc = try annexB(video)
        let json = hevc.deletingPathExtension().appendingPathExtension("hdr10plus.json")
        try tool("hdr10plus_tool", ["extract", "-i", hevc.path, "-o", json.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
    }

    /// ffprobe side data: the video stream's (configuration records) plus the first frame's (SEI-derived).
    static func sideData(_ video: URL) throws -> (stream: [[String: Any]], frame: [[String: Any]], tag: String) {
        let s = try tool("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", video.path]).out
        let f = try tool("ffprobe", ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames",
                                     "-show_entries", "frame=side_data_list", "-of", "json", video.path]).out
        let sj = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
        let fj = try JSONSerialization.jsonObject(with: Data(f.utf8)) as? [String: Any]
        let stream = (sj?["streams"] as? [[String: Any]])?.first ?? [:]
        let frame = (fj?["frames"] as? [[String: Any]])?.first ?? [:]
        return (stream["side_data_list"] as? [[String: Any]] ?? [], frame["side_data_list"] as? [[String: Any]] ?? [],
                stream["codec_tag_string"] as? String ?? "")
    }

    static func entry(_ list: [[String: Any]], _ type: String) -> [String: Any]? {
        list.first { ($0["side_data_type"] as? String)?.contains(type) == true }
    }

    static func ratio(_ v: Any?) -> Double {
        guard let s = v as? String else { return (v as? NSNumber)?.doubleValue ?? -1 }
        let p = s.split(separator: "/").compactMap { Double($0) }
        return p.count == 2 && p[1] != 0 ? p[0] / p[1] : (p.first ?? -1)
    }

    static func audioStreams(_ video: URL) throws -> Int {
        try tool("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", video.path])
            .out.split(separator: "\n").count
    }

    /// Inspect → (optional crop detection) → analyze → presets → job, as the app does it.
    func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out: String, look: Look? = nil,
                 detectCrop: Bool = false) async throws -> ExportJob {
        var (d, colors) = try await SourceInspector.inspect(src)
        if detectCrop { d.crop = try await CropDetector.detect(d) }
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let report = (color.transfer == .pq || color.transfer == .hlg)
            ? HDRReportCard.make(title: src.lastPathComponent, descriptor: d, color: color, analysis: a) : nil
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: report)
        let preset: PresetCandidate
        if let look {
            preset = try XCTUnwrap(presets.first { $0.look == look }, "no \(look.displayName) preset")
        } else {
            preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        }
        var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: Self.url(out))
        job.sourcePeakNits = report?.p999Nits ?? 1000
        job.quality = 0.5
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    func frames(_ url: URL) throws -> Int { try EndToEndTests.probe(url).frames }

    // MARK: - Static metadata encoders

    func testStaticMetadataByteAndStringEncodings() {
        let s = HDRMetadata.Static(peakNits: 1000, maxCLL: 812.4, maxFALL: 245.6)
        let md = [UInt8](HDRMetadata.vtMasteringDisplay(s))
        XCTAssertEqual(md.count, 24)
        func u16(_ i: Int) -> Int { Int(md[i]) << 8 | Int(md[i + 1]) }
        func u32(_ i: Int) -> Int { Int(md[i]) << 24 | Int(md[i + 1]) << 16 | Int(md[i + 2]) << 8 | Int(md[i + 3]) }
        // G, B, R, white point in 0.00002 units (SMPTE ST 2086 / HEVC SEI order), then luminance in 0.0001 nits.
        XCTAssertEqual([u16(0), u16(2), u16(4), u16(6), u16(8), u16(10), u16(12), u16(14)],
                       [13250, 34500, 7500, 3000, 34000, 16000, 15635, 16450])
        XCTAssertEqual(u32(16), 10_000_000)
        XCTAssertEqual(u32(20), 50)
        XCTAssertEqual([UInt8](HDRMetadata.vtContentLightLevel(s)), [0x03, 0x2C, 0x00, 0xF6])   // 812, 246
        XCTAssertEqual([UInt8](HDRMetadata.vtContentLightLevel(.init(peakNits: 1000, maxCLL: 90000, maxFALL: 0))), [0xFF, 0xFF, 0, 0])
        XCTAssertEqual(HDRMetadata.x265Mastering(s), "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)")
        XCTAssertEqual(HDRMetadata.svtMastering(s), "G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(1000,0.005)")
        // 12-bit PQ codes used by the Dolby Vision L1 block (reference: BT.2100 PQ, 100 nits = 0.5081).
        XCTAssertEqual(HDRMetadata.pqCode12(0), 0)
        XCTAssertEqual(HDRMetadata.pqCode12(10000), 4095)
        XCTAssertEqual(HDRMetadata.pqCode12(100), Int((Self.pq(100) * 4095).rounded()))
        XCTAssertEqual(HDRMetadata.pqCode12(1000), Int((Self.pq(1000) * 4095).rounded()))
        XCTAssertEqual(Double(HDRMetadata.pqCode12(100)) / 4095, 0.5081, accuracy: 0.0005)
    }

    /// The x265 and SVT-AV1 mastering strings, fed to the real encoders, come back out as the right ST 2086 values.
    func testMasteringStringsAreAcceptedByX265AndSVTAV1() throws {
        try Self.require("ffmpeg", "ffprobe", "x265", "SvtAv1EncApp")
        let s = HDRMetadata.Static(peakNits: 1000, maxCLL: 800, maxFALL: 200)
        let y4m = Self.url("mastering-in.y4m")
        try Self.tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=0.5",
                                 "-pix_fmt", "yuv420p10le", "-strict", "-1", y4m.path])
        let hevc = Self.url("mastering.hevc"), ivf = Self.url("mastering.ivf")
        try Self.tool("x265", ["--input", y4m.path, "--output-depth", "10", "--log-level", "error", "--preset", "ultrafast",
                               "--colorprim", "bt2020", "--transfer", "smpte2084", "--colormatrix", "bt2020nc",
                               "--hdr10", "--master-display", HDRMetadata.x265Mastering(s), "--max-cll", "800,200", "-o", hevc.path])
        try Self.tool("SvtAv1EncApp", ["-i", y4m.path, "-b", ivf.path, "--preset", "12", "--input-depth", "10",
                                       "--color-primaries", "9", "--transfer-characteristics", "16", "--matrix-coefficients", "9",
                                       "--mastering-display", HDRMetadata.svtMastering(s), "--content-light", "800,200"])
        for file in [hevc, ivf] {
            let sd = try Self.sideData(file)
            let md = try XCTUnwrap(Self.entry(sd.frame, "Mastering display"), "\(file.lastPathComponent): no mastering display in \(sd.frame)")
            XCTAssertEqual(Self.ratio(md["red_x"]), 0.680, accuracy: 0.001, file.lastPathComponent)
            XCTAssertEqual(Self.ratio(md["green_y"]), 0.690, accuracy: 0.001, file.lastPathComponent)
            XCTAssertEqual(Self.ratio(md["white_point_x"]), 0.3127, accuracy: 0.0005, file.lastPathComponent)
            XCTAssertEqual(Self.ratio(md["max_luminance"]), 1000, accuracy: 0.5, file.lastPathComponent)
            XCTAssertEqual(Self.ratio(md["min_luminance"]), 0.005, accuracy: 0.0005, file.lastPathComponent)
            let cll = try XCTUnwrap(Self.entry(sd.frame, "Content light level"), file.lastPathComponent)
            XCTAssertEqual(cll["max_content"] as? Int, 800, file.lastPathComponent)
            XCTAssertEqual(cll["max_average"] as? Int, 200, file.lastPathComponent)
        }
    }

    // MARK: - Dynamic metadata generators, validated by the tools that consume them

    func testDolbyVisionGeneratorJSONIsAcceptedByDoviTool() throws {
        try Self.require("dovi_tool")
        let shots = [HDRMetadata.Shot(start: 0, duration: 30, maxNits: 900, avgNits: 120),
                     HDRMetadata.Shot(start: 30, duration: 18, maxNits: 250, avgNits: 40)]
        let s = HDRMetadata.Static(peakNits: 1000, maxCLL: 900, maxFALL: 120)
        let json = Self.url("gen-dv.json"), bin = Self.url("gen-dv.bin")
        try HDRMetadata.doviGeneratorJSON(frames: 48, shots: shots, s: s).write(to: json)
        try Self.tool("dovi_tool", ["generate", "-j", json.path, "-o", bin.path])
        let r = try Self.rpu(bin)
        XCTAssertEqual(r.frames, 48)
        XCTAssertEqual(r.profile, 8)
        XCTAssertTrue(r.summary.contains("Scene/shot count: 2"), r.summary)
        XCTAssertTrue(r.summary.contains("CM v4.0"), r.summary)
        XCTAssertTrue(r.summary.contains("Mastering display: 0.0050/1000 nits. MaxCLL: 900 nits, MaxFALL: 120 nits"), r.summary)
        XCTAssertEqual(r.l1.count, 48)
        XCTAssertEqual(r.l1[0], [0, HDRMetadata.pqCode12(900), HDRMetadata.pqCode12(120)])
        XCTAssertEqual(r.l1[29], r.l1[0])
        XCTAssertEqual(r.l1[30], [0, HDRMetadata.pqCode12(250), HDRMetadata.pqCode12(40)])
        XCTAssertEqual(r.l1[47], r.l1[30])
    }

    func testHDR10PlusJSONRoundTripsThroughHdr10plusTool() throws {
        try Self.require("ffmpeg", "hdr10plus_tool")
        let raw = Self.url("hdr10plus-in.hevc")
        try Self.tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=2",
                                 "-pix_fmt", "yuv420p10le", "-c:v", "libx265", "-x265-params", "log-level=error", "-f", "hevc", raw.path])
        let shots = [HDRMetadata.Shot(start: 0, duration: 20, maxNits: 950, avgNits: 110),
                     HDRMetadata.Shot(start: 20, duration: 28, maxNits: 300, avgNits: 35)]
        let json = Self.url("hdr10plus-gen.json"), injected = Self.url("hdr10plus-out.hevc"), back = Self.url("hdr10plus-back.json")
        try HDRMetadata.hdr10PlusJSON(frames: 48, shots: shots).write(to: json)
        try Self.tool("hdr10plus_tool", ["inject", "-i", raw.path, "-j", json.path, "-o", injected.path])
        let verify = try Self.tool("hdr10plus_tool", ["--verify", "extract", "-i", injected.path], allowFail: true).out
        XCTAssertTrue(verify.lowercased().contains("dynamic hdr10+ metadata detected"), verify)
        try Self.tool("hdr10plus_tool", ["extract", "-i", injected.path, "-o", back.path])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: back)) as? [String: Any])
        let info = try XCTUnwrap(root["SceneInfo"] as? [[String: Any]])
        XCTAssertEqual(info.count, 48, "one HDR10+ entry per frame")
        XCTAssertEqual(Set(info.compactMap { $0["SceneId"] as? Int }), [0, 1])
        let maxScl = info.map { (($0["LuminanceParameters"] as? [String: Any])?["MaxScl"] as? [Int])?.first ?? -1 }
        XCTAssertEqual(maxScl[0], 9500)
        XCTAssertEqual(maxScl[47], 3000)
        let avg = info.map { ($0["LuminanceParameters"] as? [String: Any])?["AverageRGB"] as? Int ?? -1 }
        XCTAssertEqual(avg[0], 1100); XCTAssertEqual(avg[47], 350)
        let dist = ((info[0]["LuminanceParameters"] as? [String: Any])?["LuminanceDistributions"] as? [String: Any])?["DistributionValues"] as? [Int] ?? []
        XCTAssertEqual(dist.count, 9)
        XCTAssertEqual(dist, dist.sorted(), "percentile distribution must be monotonic")
        let summary = root["SceneInfoSummary"] as? [String: Any]
        XCTAssertEqual(summary?["SceneFirstFrameIndex"] as? [Int], [0, 20])
        XCTAssertEqual(summary?["SceneFrameNumbers"] as? [Int], [20, 28])
    }

    // MARK: - HDR10+ exports

    private func assertHDR10Plus(_ url: URL, expectFrames: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try frames(url), expectFrames, "video frame count", file: file, line: line)
        let j = try Self.hdr10Plus(url)
        let info = j["SceneInfo"] as? [[String: Any]] ?? []
        XCTAssertEqual(info.count, expectFrames, "one HDR10+ entry per frame", file: file, line: line)
        let scenes = Set(info.compactMap { $0["SceneId"] as? Int })
        XCTAssertGreaterThanOrEqual(scenes.count, 2, "the cut at frame 24 should start a new HDR10+ scene", file: file, line: line)
        let maxScl = info.compactMap { (($0["LuminanceParameters"] as? [String: Any])?["MaxScl"] as? [Int])?.max() }
        XCTAssertTrue(maxScl.allSatisfy { $0 > 0 && $0 <= 100_000 }, "MaxScl in 0.1-nit units within 0…10000 nits", file: file, line: line)
        let p = try EndToEndTests.probe(url)
        XCTAssertEqual(p.transfer, "smpte2084", file: file, line: line)
        XCTAssertEqual(p.primaries, "bt2020", file: file, line: line)
    }

    func testHDR10PlusHardwareHEVCToMKV() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("hdr10plus_tool", "mkvmerge")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .hdr10Plus, codec: .hevc, out: "hdr10plus-vt.mkv")
        let url = try await ExportEngine().run(job) { _, _ in }
        try assertHDR10Plus(url, expectFrames: 48)
        XCTAssertEqual(try Self.audioStreams(url), 1, "source audio is carried")
        // Static HDR10 metadata must survive the Annex-B round trip and the remux.
        try assertStaticHDR10(url, peak: job.target.effectivePeak)
        let sd = try Self.sideData(url)
        XCTAssertNotNil(Self.entry(sd.frame, "HDR Dynamic Metadata") , "ffprobe sees HDR10+ on frame 0: \(sd.frame)")
    }

    func testHDR10PlusHardwareHEVCToMP4() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("hdr10plus_tool", "MP4Box")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .hdr10Plus, codec: .hevc, out: "hdr10plus-vt.mp4")
        let url = try await ExportEngine().run(job) { _, _ in }
        try assertHDR10Plus(url, expectFrames: 48)
        XCTAssertEqual(try Self.audioStreams(url), 1, "source audio is carried")
        try assertStaticHDR10(url, peak: job.target.effectivePeak)
    }

    /// Mastering display (P3-D65 at the target peak) and light levels, as players read them from the delivered file.
    private func assertStaticHDR10(_ url: URL, peak: Float, file: StaticString = #filePath, line: UInt = #line) throws {
        let sd = try Self.sideData(url)
        guard let md = Self.entry(sd.stream, "Mastering display") ?? Self.entry(sd.frame, "Mastering display") else {
            return XCTFail("mastering display lost: stream \(sd.stream) frame \(sd.frame)", file: file, line: line)
        }
        XCTAssertEqual(Self.ratio(md["red_x"]), 0.680, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(Self.ratio(md["blue_y"]), 0.060, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(Self.ratio(md["white_point_y"]), 0.3290, accuracy: 0.0005, file: file, line: line)
        XCTAssertEqual(Self.ratio(md["max_luminance"]), Double(peak), accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(Self.ratio(md["min_luminance"]), 0.005, accuracy: 0.0005, file: file, line: line)
        let cll = Self.entry(sd.stream, "Content light level") ?? Self.entry(sd.frame, "Content light level")
        let maxCLL = cll?["max_content"] as? Int ?? 0
        XCTAssertGreaterThan(maxCLL, 100, "MaxCLL measured from the grade: \(String(describing: cll))", file: file, line: line)
        XCTAssertLessThanOrEqual(maxCLL, Int(peak), file: file, line: line)
    }

    func testHDR10PlusX265ToMKV() async throws {
        try TestHardware.requireGPU()
        try Self.require("hdr10plus_tool", "mkvmerge", "x265")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .hdr10Plus, codec: .hevc12, out: "hdr10plus-x265.mkv")
        let url = try await ExportEngine().run(job) { _, _ in }
        try assertHDR10Plus(url, expectFrames: 48)
        let md = try XCTUnwrap(Self.entry(try Self.sideData(url).frame, "Mastering display"))
        XCTAssertEqual(Self.ratio(md["max_luminance"]), 1000, accuracy: 0.5)
    }

    /// AV1 can't carry HDR10+ with the installed tools (hdr10plus_tool only edits HEVC). The export must say so
    /// up front instead of failing after the encode with an FFmpeg bitstream-filter error.
    func testHDR10PlusAV1IsRejectedCleanly() async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .hdr10Plus, codec: .av1, out: "hdr10plus-av1.mkv")
        let problem = ExportEngine.validate(job)
        XCTAssertNotNil(problem, "HDR10+ in AV1 should be refused before encoding")
        XCTAssertTrue(problem?.contains("HEVC") == true, problem ?? "")
        do {
            _ = try await ExportEngine().run(job) { _, _ in }
            XCTFail("export should have been refused")
        } catch let LumoraError.unsupported(why) {
            XCTAssertEqual(why, problem)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.outputURL.path))
        XCTAssertFalse(DeliveryFormat.hdr10Plus.supported(by: .av1))
    }

    // MARK: - Dolby Vision 8.1 (new metadata)

    private func assertDV81(_ url: URL, expectFrames: Int, file: StaticString = #filePath, line: UInt = #line) throws -> RPUReport {
        let videoFrames = try frames(url)
        XCTAssertEqual(videoFrames, expectFrames, "video frame count", file: file, line: line)
        let r = try Self.rpuOf(url)
        XCTAssertEqual(r.profile, 8, r.summary, file: file, line: line)
        XCTAssertEqual(r.frames, videoFrames, "one RPU per video frame", file: file, line: line)
        let sd = try Self.sideData(url)
        let dovi = Self.entry(sd.stream, "DOVI configuration")
        XCTAssertNotNil(dovi, "container has no Dolby Vision configuration record: \(sd.stream)", file: file, line: line)
        XCTAssertEqual(dovi?["dv_profile"] as? Int, 8, file: file, line: line)
        XCTAssertEqual(dovi?["dv_bl_signal_compatibility_id"] as? Int, 1, "8.1 = HDR10-compatible base layer", file: file, line: line)
        XCTAssertEqual(dovi?["rpu_present_flag"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(try EndToEndTests.probe(url).transfer, "smpte2084", file: file, line: line)
        return r
    }

    func testDolbyVision81GeneratedHardwareHEVCToMKV() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "mkvmerge")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-vt.mkv")
        let url = try await ExportEngine().run(job) { _, _ in }
        let r = try assertDV81(url, expectFrames: 48)
        XCTAssertTrue(r.summary.contains("Scene/shot count: 2"), r.summary)
        XCTAssertNotEqual(r.l1.first, r.l1.last, "each shot gets its own measured L1")
        XCTAssertTrue(r.l1.allSatisfy { $0.count == 3 && $0[1] >= $0[2] && $0[1] <= 4095 })
        XCTAssertEqual(try Self.audioStreams(url), 1, "source audio is carried")
        try assertStaticHDR10(url, peak: job.target.effectivePeak)
    }

    func testDolbyVision81GeneratedHardwareHEVCToMP4() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "MP4Box")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-vt.mp4")
        let url = try await ExportEngine().run(job) { _, _ in }
        _ = try assertDV81(url, expectFrames: 48)
        XCTAssertEqual(try Self.audioStreams(url), 1, "source audio is carried")
        try assertStaticHDR10(url, peak: job.target.effectivePeak)
    }

    /// A silent source: the MP4 remux must not depend on there being an audio track.
    func testDolbyVision81SilentSourceToMP4() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "MP4Box")
        let src = try Self.pqSource("pq-silent.mp4", audio: false)
        let job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-silent.mp4")
        let url = try await ExportEngine().run(job) { _, _ in }
        _ = try assertDV81(url, expectFrames: 48)
        XCTAssertEqual(try Self.audioStreams(url), 0)
    }

    /// The recommender and "future-proof export" pair Dolby Vision 8.1 with x265 (hevc12); that must validate and work.
    func testDolbyVision81WithX265() async throws {
        try TestHardware.requireGPU()
        try Self.require("dovi_tool", "mkvmerge", "x265")
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc12, out: "dv81-x265.mkv")
        XCTAssertNil(ExportEngine.validate(job))
        let url = try await ExportEngine().run(job) { _, _ in }
        _ = try assertDV81(url, expectFrames: 48)
        try assertStaticHDR10(url, peak: job.target.effectivePeak)
        XCTAssertFalse(DeliveryFormat.dolbyVision84.supported(by: .hevc12), "8.4 is only made by VideoToolbox")
    }

    // MARK: - Dolby Vision source: detection and retiming the original

    func testDolbyVisionSourceIsDetectedWithProfile() async throws {
        try TestHardware.requireGPU()
        let src = try Self.dvSource("dv81-source.mp4")
        let (d, colors) = try await SourceInspector.inspect(src)
        XCTAssertTrue(d.isDolbyVision)
        XCTAssertEqual(d.dvProfile, 8)
        XCTAssertFalse(d.dvHasEnhancementLayer)
        XCTAssertEqual(colors.first?.transfer, .pq)
        XCTAssertEqual(d.frameCount, 48)
        let src0 = try Self.rpuOf(src)
        XCTAssertEqual(src0.frames, 48)
        XCTAssertEqual(src0.l5.first, [0, 0, 88, 88])
        XCTAssertEqual(DolbyVisionRetimer.decide(source: d, look: .original, passthrough: true, codec: .hevc, delivery: .dolbyVision81), .retimeOriginal)
        if case .generateNew = DolbyVisionRetimer.decide(source: d, look: .punchy, passthrough: false, codec: .hevc, delivery: .dolbyVision81) {} else { XCTFail() }
        // Profile 5 (IPTPQc2, no HDR10 base) must never be "kept".
        var p5 = d; p5.dvProfile = 5
        if case .generateNew = DolbyVisionRetimer.decide(source: p5, look: .original, passthrough: true, codec: .hevc, delivery: .dolbyVision81) {} else { XCTFail() }
    }

    func testRetimeOriginalThroughDoubleFrameRate() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "mkvmerge")
        let src = try Self.dvSource("dv81-source.mp4")
        var job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-retimed-2x.mkv", look: .original)
        job.interpolation.mode = .multiply(2)
        let plan = InterpolationPlanner.plan(sourceFrames: job.descriptor.frameCount, sourceRate: (job.descriptor.fpsNum, job.descriptor.fpsDen),
                                             settings: job.interpolation, analysis: job.analysis).frames
        let mapping = DolbyVisionRetimer.sourceFrames(for: plan)
        let url = try await ExportEngine().run(job) { _, _ in }
        let r = try assertDV81(url, expectFrames: plan.count)
        XCTAssertGreaterThanOrEqual(r.frames, 94)
        // The colorist's metadata came through, frame-accurately: L1/L2 of each output frame = its source frame's.
        XCTAssertTrue(r.summary.contains("L2 trims"), "trims were dropped: \(r.summary)")
        XCTAssertEqual(r.l1.count, mapping.count)
        for (k, s) in mapping.enumerated() where k < r.l1.count {
            XCTAssertEqual(r.l1[k][1], s < 24 ? 3001 : 2701, "output frame \(k) (source \(s)) L1 max_pq")
            XCTAssertEqual(r.l2[safe: k]?[safe: 1], s < 24 ? 2148 : 1948, "output frame \(k) L2 trim_slope")
        }
        XCTAssertEqual(r.l5.first, [0, 0, 88, 88], "no crop: active area kept")
        let log = LogStore.shared.entries.map(\.message)
        XCTAssertTrue(log.contains { $0.contains("Dolby Vision retimed: 48 source frames → \(plan.count) output frames") }, "\(log.suffix(10))")
    }

    func testRetimeOriginalWithBlackBarCrop() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "MP4Box")
        let src = try Self.dvSource("dv81-source.mp4")
        let job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-retimed-crop.mp4", look: .original, detectCrop: true)
        XCTAssertEqual(job.descriptor.crop.y, 88 / 720, accuracy: 0.01, "letterbox detected: \(job.descriptor.crop)")
        XCTAssertEqual(job.descriptor.crop.w, 544 / 720, accuracy: 0.01)
        let url = try await ExportEngine().run(job) { _, _ in }
        let r = try assertDV81(url, expectFrames: 48)
        let height = try Self.tool("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=height", "-of", "csv=p=0", url.path]).out
        // 544 picture rows; the detector may keep a row or two of encoder ringing at each bar edge.
        XCTAssertEqual(Double(height.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 0), 544, accuracy: 4, "bars removed from the picture")
        XCTAssertTrue(r.summary.contains("L2 trims"), r.summary)
        XCTAssertEqual(r.l5.count, 48)
        XCTAssertTrue(r.l5.allSatisfy { $0 == [0, 0, 0, 0] }, "L5 active area must be reset after cropping: \(r.l5.first ?? [])")
        XCTAssertEqual(r.l1.map { $0[1] }, Array(repeating: 3001, count: 24) + Array(repeating: 2701, count: 24))
    }

    /// Output that uses only part of the source (preview ranges, trimmed RPUs) must drop the unused tail too.
    func testRetimerHandlesSubrangeMapping() throws {
        try Self.require("dovi_tool", "ffmpeg")
        let src = try Self.dvSource("dv81-source.mp4")
        let work = Self.url("retime-subrange")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let mapping = Array(10..<30) + [29]
        let out = try DolbyVisionRetimer.retime(source: src, mapping: mapping, cropped: false, workDir: work)
        let r = try Self.rpu(out)
        XCTAssertEqual(r.frames, mapping.count)
        XCTAssertEqual(r.l1.map { $0[1] }, mapping.map { $0 < 24 ? 3001 : 2701 })
    }

    /// When the original RPU can't be lined up with the output (here: a mis-authored source whose last 8 frames
    /// carry no RPU) the retimer refuses with a reason instead of producing misaligned metadata.
    /// (Such a file can't go through the whole export here: AVFoundation's Dolby Vision decoder rejects frames
    /// that lack an RPU, so the end-to-end fallback below uses a file whose stream has no RPUs at all.)
    func testRetimerRefusesAnRPUShorterThanTheOutputNeeds() throws {
        try Self.require("dovi_tool", "ffmpeg")
        let src = try Self.dvSource("dv81-short-rpu.mp4", rpuFrames: 40)
        let short = try Self.rpuOf(src).frames
        XCTAssertTrue((38...42).contains(short), "source should carry ~40 RPUs for 48 frames, has \(short)")
        XCTAssertEqual(try frames(src), 48)
        let work = Self.url("retime-short")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DolbyVisionRetimer.retime(source: src, mapping: Array(0..<48), cropped: false, workDir: work)) { e in
            XCTAssertTrue(e.localizedDescription.contains("covers \(short) frames"), e.localizedDescription)
        }
        // The frames it does cover still retime.
        let ok = try DolbyVisionRetimer.retime(source: src, mapping: Array(0..<short), cropped: false, workDir: work)
        XCTAssertEqual(try DolbyVisionRetimer.frameCount(of: ok), short)
    }

    /// End to end: the container says Dolby Vision 8.1 but the stream carries no RPUs, so the original can't be kept.
    /// Lumora logs why and writes fresh metadata, one RPU per output frame.
    func testRetimeFallbackGeneratesNewMetadata() async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", "mkvmerge")
        let src = try Self.dvSource("dv81-no-rpu.mp4", rpuFrames: 0)
        XCTAssertEqual(try frames(src), 48)
        var job = try await makeJob(src, delivery: .dolbyVision81, codec: .hevc, out: "dv81-fallback.mkv", look: .original)
        XCTAssertTrue(job.descriptor.isDolbyVision)
        job.interpolation.mode = .multiply(2)
        XCTAssertEqual(DolbyVisionRetimer.decide(source: job.descriptor, look: job.preset.look, passthrough: job.preset.params.passthrough,
                                                 codec: job.codec, delivery: job.delivery), .retimeOriginal)
        let before = LogStore.shared.entries.count
        let url = try await ExportEngine().run(job) { _, _ in }
        await Task.yield()
        let r = try assertDV81(url, expectFrames: try frames(url))
        XCTAssertGreaterThanOrEqual(r.frames, 94)
        XCTAssertFalse(r.summary.contains("L2 trims"), "fallback metadata is generated, not the colorist's: \(r.summary)")
        let log = LogStore.shared.entries.dropFirst(before).map(\.message)
        XCTAssertTrue(log.contains { $0.contains("Couldn't retime the original Dolby Vision") }, "\(log.suffix(10))")
    }

    // MARK: - Dolby Vision 8.4 (HLG) via VideoToolbox

    func testDolbyVision84HLGViaVideoToolboxToMOV() async throws {
        try await dolbyVision84(out: "dv84-vt.mov", requiring: "MP4Box")
    }

    func testDolbyVision84HLGViaVideoToolboxToMKV() async throws {
        try await dolbyVision84(out: "dv84-vt.mkv", requiring: "mkvmerge")
    }

    func testDolbyVision84GeneratorJSONIsAcceptedByDoviTool() throws {
        try Self.require("dovi_tool")
        let json = Self.url("gen-dv84.json"), bin = Self.url("gen-dv84.bin")
        try HDRMetadata.doviGeneratorJSON(frames: 24, shots: [.init(start: 0, duration: 24, maxNits: 800, avgNits: 90)],
                                          s: .init(peakNits: 1000, maxCLL: 800, maxFALL: 90), profile: "8.4").write(to: json)
        let gen = try Self.tool("dovi_tool", ["generate", "-j", json.path, "-o", bin.path]).out
        XCTAssertTrue(gen.contains("8.4"), gen)
        XCTAssertEqual(try DolbyVisionRetimer.frameCount(of: bin), 24)
    }

    private func dolbyVision84(out: String, requiring muxer: String) async throws {
        try TestHardware.requireHardwareHEVC()
        try Self.require("dovi_tool", muxer)
        let src = try Self.pqSource("pq-audio.mp4")
        let job = try await makeJob(src, delivery: .dolbyVision84, codec: .hevc, out: out)
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try EndToEndTests.probe(url)
        XCTAssertEqual(p.codec, "hevc")
        XCTAssertEqual(p.transfer, "arib-std-b67")
        XCTAssertEqual(p.primaries, "bt2020")
        XCTAssertEqual(p.frames, 48)
        let sd = try Self.sideData(url)
        let hevc = try Self.annexB(url)
        let bin = Self.url("dv84.rpu.bin")
        let ex = try Self.tool("dovi_tool", ["extract-rpu", "-i", hevc.path, "-o", bin.path], allowFail: true)
        let summary = ex.status == 0 ? (try? Self.tool("dovi_tool", ["info", "-i", bin.path, "-s"]).out) ?? "" : ""
        print("DV84 inspection: tag=\(sd.tag) stream=\(sd.stream) frame=\(sd.frame) extract=\(ex.status) \(ex.out.suffix(300)) summary=\(summary)")
        let dovi = Self.entry(sd.stream, "DOVI configuration")
        XCTAssertNotNil(dovi, "no Dolby Vision configuration record in the container (tag \(sd.tag))")
        XCTAssertEqual(dovi?["dv_profile"] as? Int, 8)
        XCTAssertEqual(dovi?["dv_bl_signal_compatibility_id"] as? Int, 4, "8.4 = HLG-compatible base layer")
        XCTAssertTrue(summary.contains("Frames: 48"), "RPU per frame: \(summary)")
        XCTAssertEqual(try Self.audioStreams(url), 1, "source audio is carried")
        // Lumora itself (AVFoundation for .mov, FFmpeg for .mkv) reads the result back as Dolby Vision 8 over HLG.
        let (d, colors) = try await SourceInspector.inspect(url)
        XCTAssertTrue(d.isDolbyVision)
        XCTAssertEqual(d.dvProfile, 8)
        XCTAssertEqual(colors.first?.transfer, .hlg)
        // MKV has no frame count field; the FFmpeg path estimates it from the duration (audio included), ±1 frame.
        XCTAssertEqual(Double(d.frameCount), 48, accuracy: url.pathExtension == "mkv" ? 1 : 0)
    }

    // MARK: - HDR Report Card on PQ sources of different peak levels

    /// A PQ clip: background at `bgNits`, a 25%×25% patch (6.25% of pixels) at `patchNits`.
    static func pqPatchClip(_ name: String, bgNits: Double, patchNits: Double) throws -> URL {
        try require("ffmpeg")
        let out = url(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        func y(_ nits: Double) -> Int { Int((64 + pq(nits) * 876).rounded()) }
        let geq = "geq=lum='if(lt(X,W/4)*lt(Y,H/4),\(y(patchNits)),\(y(bgNits)))':cb=512:cr=512"
        try tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "nullsrc=s=1280x720:r=24:d=1",
                            "-vf", "format=yuv420p10le,\(geq),setparams=range=tv:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc", "-c:v", "libx265", "-x265-params", "log-level=error:crf=4", "-tag:v", "hvc1",
                            "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", out.path])
        return out
    }

    func testHDRReportCardVerdictsAcrossPeakLevels() async throws {
        try TestHardware.requireGPU()
        let cases: [(Double, HDRReportCard.Verdict)] = [(150, .fakeHDR), (350, .conservative), (650, .balanced), (2000, .vivid)]
        var summary: [String] = []
        for (peak, expected) in cases {
            let src = try Self.pqPatchClip("report-\(Int(peak)).mp4", bgNits: 40, patchNits: peak)
            let (d, colors) = try await SourceInspector.inspect(src)
            let color = try XCTUnwrap(colors.first)
            XCTAssertEqual(color.transfer, .pq)
            let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
            let card = HDRReportCard.make(title: src.lastPathComponent, descriptor: d, color: color, analysis: a)
            summary.append("\(Int(peak)) nits → \(card.verdict.rawValue), p999 \(card.p999Nits), median \(card.medianNits), above1000 \(card.shareAbove1000)")
            XCTAssertEqual(card.verdict, expected, "\(Int(peak))-nit highlights: \(card)")
            XCTAssertEqual(Double(card.p999Nits), peak, accuracy: peak * 0.15, "p999 should be the highlight level")
            XCTAssertEqual(Double(card.medianNits), 40, accuracy: 40 * 0.15, "median should be the background level")
            XCTAssertFalse(card.findings.isEmpty)
            XCTAssertFalse(card.suggestion.isEmpty)
            if peak >= 1000 { XCTAssertGreaterThan(card.shareAbove1000, 0.03) } else { XCTAssertEqual(card.shareAbove1000, 0, accuracy: 0.001) }
        }
        print("HDRReportCard:\n" + summary.joined(separator: "\n"))
    }

    // MARK: - Missing tools are reported cleanly

    func testMissingAV2EncoderIsReportedCleanly() throws {
        guard !ToolLocator.isAvailable("avmenc") else { throw XCTSkip("avmenc is installed on this Mac") }
        XCTAssertFalse(Codec.av2.available)
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/in.mp4"), kind: .avfoundation)
        d.width = 640; d.height = 360; d.frameCount = 48
        let p = PresetCandidate(name: "n", look: .natural, color: .testSDR, params: Look.natural.params, sceneExposures: [0], reason: "")
        let job = ExportJob(descriptor: d, preset: p, analysis: .empty, delivery: .hdr10, codec: .av2, outputURL: Self.url("x.obu"))
        XCTAssertEqual(ExportEngine.validate(job), "AV2 · AVM reference (experimental) needs the avmenc encoder, which isn't installed. See README → Encoders.")
    }
}
