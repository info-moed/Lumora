import XCTest
@testable import Lumora

/// Runs real clips through the real pipeline: inspect → analyze → auto presets → GPU grade → encode → file.
/// The clips are generated with FFmpeg (skipped when it isn't installed), and every output is checked with
/// ffprobe: codec, bit depth, HDR signalling, frame count, and that the picture is neither black nor blown out.
@MainActor
final class EndToEndTests: XCTestCase {
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraE2E-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @discardableResult
    static func sh(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "sh", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(exe) \(args.joined(separator: " ")) exited \(p.terminationStatus)"]) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Two 1-second shots at 24 fps with a hard cut between them, so scene detection has something to find.
    static func makeClip(_ name: String, hdr: Bool) throws -> URL {
        guard let ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let shots = "testsrc2=s=1280x720:r=24:d=1[a];smptehdbars=s=1280x720:r=24:d=1[b];[a][b]concat=n=2:v=1"
        // HDR: the pattern's code values are used directly as a PQ signal (full white ≈ 10,000 nits, mid patches
        // in the hundreds), coded as studio-range 10-bit BT.2020 the way a UHD rip is.
        let graph = shots + (hdr ? ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le[v]" : "[v]")
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex", graph, "-map", "[v]"]
        if hdr {
            args += ["-c:v", "libx265", "-x265-params", "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                     "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        } else {
            args += ["-pix_fmt", "yuv420p", "-c:v", "libx264", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        try sh(ffmpeg, args + [url.path])
        return url
    }

    struct Probe { var codec: String; var pixFmt: String; var transfer: String; var primaries: String; var frames: Int }

    static func probe(_ url: URL) throws -> Probe {
        guard let ffprobe else { throw XCTSkip("ffprobe not installed") }
        let out = try sh(ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames",
                                   "-show_entries", "stream=codec_name,pix_fmt,color_transfer,color_primaries,nb_read_frames",
                                   "-of", "default=nw=1", url.path])
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { kv[parts[0]] = parts[1] }
        }
        return Probe(codec: kv["codec_name"] ?? "", pixFmt: kv["pix_fmt"] ?? "", transfer: kv["color_transfer"] ?? "",
                     primaries: kv["color_primaries"] ?? "", frames: Int(kv["nb_read_frames"] ?? "") ?? -1)
    }

    /// Mean luma of the whole output (0...1 of the coded range), so a black or clipped grade fails.
    static func meanLuma(_ url: URL) throws -> Double {
        guard let ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-i", url.path, "-vf", "format=gray16le,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let values = text.split(separator: "\n").compactMap { l -> Double? in
            guard let r = l.range(of: "YAVG=") else { return nil }
            return Double(l[r.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        guard !values.isEmpty else { return -1 }
        return values.reduce(0, +) / Double(values.count) / 65535.0
    }

    /// Inspect → analyze → presets → job, exactly as the batch path in AppModel does it.
    func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out: String) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first, "no colour interpretation for \(src.lastPathComponent)")
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let report = (color.transfer == .pq || color.transfer == .hlg)
            ? HDRReportCard.make(title: src.lastPathComponent, descriptor: d, color: color, analysis: a) : nil
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: report)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first, "no presets generated")
        var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: Self.dir.appendingPathComponent(out))
        job.sourcePeakNits = report?.p999Nits ?? 1000
        try? FileManager.default.removeItem(at: job.outputURL)
        return job
    }

    func testInspectAndAnalyzeFindTheCut() async throws {
        try TestHardware.requireGPU()
        let src = try Self.makeClip("sdr.mp4", hdr: false)
        let (d, colors) = try await SourceInspector.inspect(src)
        XCTAssertEqual(d.width, 1280); XCTAssertEqual(d.height, 720)
        XCTAssertEqual(d.frameCount, 48)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        XCTAssertGreaterThanOrEqual(a.scenes.count, 2, "the hard cut at frame 24 should split the clip")
    }

    func testHDR10SourceIsDetectedAsPQ() async throws {
        let src = try Self.makeClip("hdr10.mp4", hdr: true)
        let (_, colors) = try await SourceInspector.inspect(src)
        XCTAssertEqual(colors.first?.transfer, .pq)
    }

    func testSDRToHDR10HardwareHEVC() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.makeClip("sdr.mp4", hdr: false)
        let job = try await makeJob(src, delivery: .hdr10, codec: .hevc, out: "sdr-to-hdr10.mov")
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try Self.probe(url)
        XCTAssertEqual(p.codec, "hevc")
        XCTAssertTrue(p.pixFmt.contains("10"), "expected 10-bit, got \(p.pixFmt)")
        XCTAssertEqual(p.transfer, "smpte2084")
        XCTAssertEqual(p.primaries, "bt2020")
        XCTAssertEqual(p.frames, 48)
        let y = try Self.meanLuma(url)
        XCTAssertGreaterThan(y, 0.15, "picture is too dark (mean code value \(y))")
        XCTAssertLessThan(y, 0.85, "picture is blown out (mean code value \(y))")
    }

    func testHDR10ToSDRHardwareHEVC() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.makeClip("hdr10.mp4", hdr: true)
        let job = try await makeJob(src, delivery: .sdr, codec: .hevc, out: "hdr10-to-sdr.mov")
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try Self.probe(url)
        XCTAssertEqual(p.codec, "hevc")
        XCTAssertEqual(p.transfer, "bt709")
        XCTAssertEqual(p.frames, 48)
        let y = try Self.meanLuma(url)
        XCTAssertGreaterThan(y, 0.15, "picture is too dark (mean code value \(y))")
        XCTAssertLessThan(y, 0.85, "picture is blown out (mean code value \(y))")
    }

    func testHDR10ToProRes4444XQ12Bit() async throws {
        try TestHardware.requireProRes()
        let src = try Self.makeClip("hdr10.mp4", hdr: true)
        var job = try await makeJob(src, delivery: .hdr10, codec: .prores4444XQ, out: "hdr10-prores.mov")
        job.bitDepth = 12; job.chroma = .c444
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try Self.probe(url)
        XCTAssertEqual(p.codec, "prores")
        XCTAssertEqual(p.transfer, "smpte2084")
        XCTAssertEqual(p.frames, 48)
    }

    func testDoubleFrameRateWithoutModelsFallsBackToBlending() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .sdr, codec: .hevc, out: "sdr-48fps.mov")
        job.interpolation.mode = .multiply(2)
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try Self.probe(url)
        // 48 originals + one generated frame between each pair; never across the cut.
        XCTAssertGreaterThanOrEqual(p.frames, 94)
        XCTAssertLessThanOrEqual(p.frames, 96)
    }

    func testSDRToHDR10SoftwareAV1() async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try Self.makeClip("sdr.mp4", hdr: false)
        var job = try await makeJob(src, delivery: .hdr10, codec: .av1, out: "sdr-to-hdr10-av1.mkv")
        job.quality = 0.5
        let url = try await ExportEngine().run(job) { _, _ in }
        let p = try Self.probe(url)
        XCTAssertEqual(p.codec, "av1")
        XCTAssertTrue(p.pixFmt.contains("10"), "expected 10-bit, got \(p.pixFmt)")
        XCTAssertEqual(p.transfer, "smpte2084")
        XCTAssertEqual(p.frames, 48)
    }
}
