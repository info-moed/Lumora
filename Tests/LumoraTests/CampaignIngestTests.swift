import XCTest
import Metal
import AVFoundation
import CoreImage
@testable import Lumora

/// Ingest, inspection and analysis on real generated media: every container / codec / rate / color / scan
/// combination the inspector claims to handle, crop detection, cut / fade / dissolve / duplicate detection,
/// the content test, camera log ranking, RAW (DNG and CinemaDNG folders), storage and scratch handling, and the
/// preview proxy written during analysis. Every check looks at the result (descriptor fields against ffprobe,
/// decoded frame counts, decoded pixel values, file contents), not just that nothing threw.
@MainActor
final class CampaignIngestTests: XCTestCase {

    // MARK: - Helpers

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraIngest-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// Runs a tool and returns stdout; throws with the tool's stderr on failure.
    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "tool", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                "\(exe) \(args.joined(separator: " ")) exited \(p.terminationStatus): \(String(decoding: errData.suffix(1500), as: UTF8.self))"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Generates a clip once (cached by name) with FFmpeg. `args` are everything between `-y` and the output path.
    static func clip(_ name: String, _ args: [String]) throws -> URL {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args + [url.path])
        return url
    }

    /// One lavfi graph → one file.
    static func lavfi(_ name: String, _ graph: String, _ codec: [String]) throws -> URL {
        try clip(name, ["-f", "lavfi", "-i", graph] + codec)
    }

    /// ffprobe stream fields of the first video stream (with an exact decoded frame count).
    static func streamInfo(_ url: URL) throws -> [String: String] {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let out = try run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries",
                                    "stream=codec_name,width,height,pix_fmt,avg_frame_rate,r_frame_rate,nb_read_frames,field_order,color_range,color_transfer,color_primaries,sample_aspect_ratio",
                                    "-of", "default=nw=1", url.path])
        var kv: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, kv[parts[0]] == nil { kv[parts[0]] = parts[1] }
        }
        return kv
    }

    static func ffprobeFrames(_ url: URL) throws -> Int { Int(try streamInfo(url)["nb_read_frames"] ?? "") ?? -1 }

    /// Reads a decoded frame texture back to RGBA floats (blitting private textures to shared memory first).
    static func pixels(_ tex: MTLTexture) -> [SIMD4<Float>] {
        let ctx = MetalContext.shared
        let w = tex.width, h = tex.height
        var src = tex
        if tex.storageMode == .private {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: w, height: h, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.shaderRead]
            let t = ctx.device.makeTexture(descriptor: desc)!
            let cb = ctx.queue.makeCommandBuffer()!
            let b = cb.makeBlitCommandEncoder()!
            b.copy(from: tex, to: t)
            b.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            src = t
        }
        let region = MTLRegionMake2D(0, 0, w, h)
        switch tex.pixelFormat {
        case .rgba16Float:
            var raw = [Float16](repeating: 0, count: w * h * 4)
            src.getBytes(&raw, bytesPerRow: w * 8, from: region, mipmapLevel: 0)
            return (0..<(w * h)).map { i in SIMD4<Float>(Float(raw[i*4]), Float(raw[i*4+1]), Float(raw[i*4+2]), Float(raw[i*4+3])) }
        case .rgba16Unorm:
            var raw = [UInt16](repeating: 0, count: w * h * 4)
            src.getBytes(&raw, bytesPerRow: w * 8, from: region, mipmapLevel: 0)
            return (0..<(w * h)).map { i in SIMD4<Float>(Float(raw[i*4]), Float(raw[i*4+1]), Float(raw[i*4+2]), Float(raw[i*4+3])) / 65535 }
        case .rgba32Float:
            var raw = [Float](repeating: 0, count: w * h * 4)
            src.getBytes(&raw, bytesPerRow: w * 16, from: region, mipmapLevel: 0)
            return (0..<(w * h)).map { i in SIMD4<Float>(raw[i*4], raw[i*4+1], raw[i*4+2], raw[i*4+3]) }
        default:
            XCTFail("unexpected decoded pixel format \(tex.pixelFormat.rawValue)")
            return []
        }
    }

    static func meanRGB(_ tex: MTLTexture) -> SIMD3<Float> {
        let p = pixels(tex)
        let s = p.reduce(SIMD4<Float>(repeating: 0), +) / Float(max(1, p.count))
        return SIMD3(s.x, s.y, s.z)
    }

    static func luma(_ p: [SIMD4<Float>]) -> [Float] { p.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z } }

    /// Combing: in an interlaced frame with motion, neighboring rows (opposite fields) differ far more than rows
    /// two apart (same field). Returns mean|L[y]-L[y+1]| / mean|L[y]-L[y+2]|; progressive pictures give ≲ 1.
    static func combRatio(_ tex: MTLTexture) -> Float {
        let l = luma(pixels(tex))
        let w = tex.width, h = tex.height
        var d1: Float = 0, d2: Float = 0
        for y in 0..<(h - 2) {
            for x in Swift.stride(from: 0, to: w, by: 2) {
                let a = l[y * w + x]
                d1 += abs(a - l[(y + 1) * w + x])
                d2 += abs(a - l[(y + 2) * w + x])
            }
        }
        return d1 / max(1e-6, d2)
    }

    /// Decodes every frame of a descriptor through the real frame source and returns how many came out.
    static func decodeCount(_ d: SourceDescriptor) async throws -> Int {
        let src = try await d.makeFrameSource()
        try src.start(at: 0, count: nil)
        var n = 0
        while let _ = try src.nextFrame() { n += 1 }
        src.cancel()
        return n
    }

    static func frame(_ d: SourceDescriptor, at index: Int) async throws -> DecodedFrame {
        let src = try await d.makeFrameSource()
        try src.start(at: index, count: 1)
        guard let f = try src.nextFrame() else { throw NSError(domain: "decode", code: 1, userInfo: [NSLocalizedDescriptionKey: "no frame at \(index) of \(d.url.lastPathComponent)"]) }
        src.cancel()
        return f
    }

    /// testsrc2 drawn natively at small sizes is aliased (1-px lines) and FFmpeg's own field detector calls it
    /// interlaced; drawn at 720p and scaled down it is a clean progressive picture.
    static func pattern(_ w: Int, _ h: Int, rate: String = "24", seconds: Double = 2) -> String {
        "testsrc2=s=1280x720:r=\(rate):d=\(seconds),scale=\(w):\(h)"
    }

    static let x264 = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p"]

    func requireTools() throws {
        try TestHardware.requireGPU()
        guard EndToEndTests.ffmpeg != nil, EndToEndTests.ffprobe != nil else { throw XCTSkip("FFmpeg / ffprobe not installed") }
    }

    // MARK: - Containers and codecs

    struct Case {
        var file: String
        var graph: String
        var codec: [String]
        var kind: SourceKind
        var codecNames: Set<String>
        var width: Int
        var height: Int
        var bitDepth: Int? = nil
    }

    func testContainersAndCodecs() async throws {
        try requireTools()
        let base = Self.pattern(320, 180)
        let cases: [Case] = [
            Case(file: "h264.mov", graph: base, codec: Self.x264, kind: .avfoundation, codecNames: ["avc1"], width: 320, height: 180),
            Case(file: "h264.mp4", graph: base, codec: Self.x264, kind: .avfoundation, codecNames: ["avc1"], width: 320, height: 180),
            Case(file: "hevc8.mp4", graph: base, codec: ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-x265-params", "log-level=error"],
                 kind: .avfoundation, codecNames: ["hvc1"], width: 320, height: 180),
            Case(file: "hevc10.mp4", graph: base, codec: ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-x265-params", "log-level=error"],
                 kind: .avfoundation, codecNames: ["hvc1"], width: 320, height: 180),
            Case(file: "prores422.mov", graph: base, codec: ["-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le"],
                 kind: .avfoundation, codecNames: ["apcn"], width: 320, height: 180),
            Case(file: "prores4444.mov", graph: base, codec: ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuv444p10le"],
                 kind: .avfoundation, codecNames: ["ap4h"], width: 320, height: 180),
            // AV1 in MP4: AVFoundation when this Mac decodes AV1, otherwise the inspector must fall back to FFmpeg.
            Case(file: "av1.mp4", graph: base, codec: ["-c:v", "libsvtav1", "-preset", "12", "-pix_fmt", "yuv420p10le", "-svtav1-params", "lp=2"],
                 kind: .avfoundation, codecNames: ["av01", "av1"], width: 320, height: 180, bitDepth: 10),
            Case(file: "vp9.webm", graph: base, codec: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "400k"],
                 kind: .ffmpeg, codecNames: ["vp9"], width: 320, height: 180, bitDepth: 8),
            Case(file: "h264.mkv", graph: base, codec: Self.x264, kind: .ffmpeg, codecNames: ["h264"], width: 320, height: 180, bitDepth: 8),
            Case(file: "hevc422.mkv", graph: base, codec: ["-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv422p10le", "-x265-params", "log-level=error"],
                 kind: .ffmpeg, codecNames: ["hevc"], width: 320, height: 180, bitDepth: 10),
            Case(file: "h264-444.mkv", graph: base, codec: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv444p"],
                 kind: .ffmpeg, codecNames: ["h264"], width: 320, height: 180, bitDepth: 8),
            Case(file: "mpeg4.avi", graph: base, codec: ["-c:v", "mpeg4", "-q:v", "3"], kind: .ffmpeg, codecNames: ["mpeg4"], width: 320, height: 180),
            Case(file: "raw.y4m", graph: base, codec: ["-pix_fmt", "yuv420p"], kind: .ffmpeg, codecNames: ["rawvideo"], width: 320, height: 180, bitDepth: 8),
            // Odd sizes: an odd FFV1 frame is rounded down to even, a 1918-wide H.264 frame is kept as is.
            Case(file: "odd-ffv1.mkv", graph: Self.pattern(321, 181), codec: ["-c:v", "ffv1", "-pix_fmt", "yuv444p"],
                 kind: .ffmpeg, codecNames: ["ffv1"], width: 320, height: 180, bitDepth: 8),
            Case(file: "w1918.mov", graph: "testsrc2=s=1918x1080:r=24:d=1", codec: Self.x264, kind: .avfoundation, codecNames: ["avc1"], width: 1918, height: 1080),
        ]
        for c in cases {
            let url = try Self.lavfi(c.file, c.graph, c.codec)
            let truth = try Self.ffprobeFrames(url)
            let (d, colors) = try await SourceInspector.inspect(url)
            let label = c.file
            if c.codecNames.contains("av01") {
                XCTAssertTrue(d.kind == .avfoundation ? d.codec == "av01" : d.codec == "av1", "\(label): kind \(d.kind) codec \(d.codec)")
            } else {
                XCTAssertEqual(d.kind, c.kind, label)
                XCTAssertTrue(c.codecNames.contains(d.codec), "\(label): codec \(d.codec)")
            }
            XCTAssertEqual(d.width, c.width, label); XCTAssertEqual(d.height, c.height, label)
            XCTAssertEqual(d.fpsNum, 24, label); XCTAssertEqual(d.fpsDen, 1, label)
            XCTAssertLessThanOrEqual(abs(d.frameCount - truth), 1, "\(label): descriptor \(d.frameCount) frames, ffprobe \(truth)")
            if let b = c.bitDepth, d.kind == .ffmpeg { XCTAssertEqual(d.bitDepth, b, label) }
            XCTAssertEqual(d.scanFix, .none, "\(label) is progressive")
            XCTAssertEqual(colors.first?.transfer, .bt1886, "\(label): untagged SDR must rank SDR first, got \(colors.map(\.name))")
            XCTAssertFalse(d.isHDRSource, label)
            // Decode every frame through the frame source the rest of the app uses.
            let decoded = try await Self.decodeCount(d)
            XCTAssertLessThanOrEqual(abs(decoded - truth), 1, "\(label): decoded \(decoded) frames, file has \(truth)")
            let mid = try await Self.frame(d, at: d.frameCount / 2)
            XCTAssertEqual(mid.texture.width & ~1, c.width, "\(label) decoded width")
            XCTAssertEqual(mid.texture.height & ~1, c.height, "\(label) decoded height")
            let m = Self.meanRGB(mid.texture)
            XCTAssertGreaterThan(m.sum() / 3, 0.15, "\(label): decoded picture too dark \(m)")
            XCTAssertLessThan(m.sum() / 3, 0.85, "\(label): decoded picture too bright \(m)")
        }
    }

    /// MPEG-2 in a transport stream (SD, 29.97) takes the legacy path: the field detector must run and find it progressive.
    func testMPEG2TransportStreamProgressive() async throws {
        try requireTools()
        let url = try Self.lavfi("mpeg2.ts", "mandelbrot=s=720x480:r=30000/1001,trim=duration=2",
                                 ["-c:v", "mpeg2video", "-q:v", "3"])
        let truth = try Self.ffprobeFrames(url)
        let (d, _) = try await SourceInspector.inspect(url)
        XCTAssertEqual(d.kind, .ffmpeg)
        XCTAssertEqual(d.codec, "mpeg2video")
        XCTAssertEqual(d.width, 720); XCTAssertEqual(d.height, 480)
        XCTAssertEqual(d.fpsNum, 30000); XCTAssertEqual(d.fpsDen, 1001)
        XCTAssertLessThanOrEqual(abs(d.frameCount - truth), 1)
        XCTAssertEqual(d.suggestedScanFix, .none)
        let decoded = try await Self.decodeCount(d)
        XCTAssertLessThanOrEqual(abs(decoded - truth), 1)
    }

    func testAnamorphicSARUsesDisplayWidthOnBothPaths() async throws {
        try requireTools()
        // 720x480 DV-style anamorphic widescreen (SAR 32:27 -> 853x480 square-pixel picture). AVFoundation's
        // naturalSize is the display size; the FFmpeg path must agree, and its pipe must deliver frames of that size.
        var widths: [Int] = []
        for name in ["sar.mov", "sar.mkv"] {
            let url = try Self.lavfi(name, "mandelbrot=s=720x480:r=30000/1001,trim=duration=1,setsar=32/27", Self.x264)
            XCTAssertEqual(try Self.streamInfo(url)["sample_aspect_ratio"], "32:27", "instrument: SAR not written")
            let (d, _) = try await SourceInspector.inspect(url)
            XCTAssertEqual(d.width, 852, "\(name) (\(d.kind)): display width")
            XCTAssertEqual(d.height, 480, name)
            widths.append(d.width)
            let f = try await Self.frame(d, at: 3)
            XCTAssertEqual(f.texture.height, 480, name)
            if d.kind == .ffmpeg { XCTAssertEqual(f.texture.width, 852, "\(name): the pipe de-squeezes to the descriptor size") }
            XCTAssertEqual(Double(d.outputWidth) / Double(d.outputHeight), 16.0 / 9, accuracy: 0.02, name)
        }
        XCTAssertEqual(widths[0], widths[1], "both decode paths describe the same picture")
    }

    // MARK: - Frame rates

    func testFrameRatesAreExactRationals() async throws {
        try requireTools()
        let rates: [(String, Int, Int)] = [("24000/1001", 24000, 1001), ("25", 25, 1), ("30000/1001", 30000, 1001),
                                           ("50", 50, 1), ("60000/1001", 60000, 1001), ("120", 120, 1)]
        for (r, num, den) in rates {
            for ext in ["mp4", "mkv"] {
                let name = "rate-\(num)-\(den).\(ext)"
                let url = try Self.lavfi(name, Self.pattern(320, 180, rate: r, seconds: 1), Self.x264)
                let truth = try Self.ffprobeFrames(url)
                let (d, _) = try await SourceInspector.inspect(url)
                XCTAssertEqual(d.fpsNum, num, name); XCTAssertEqual(d.fpsDen, den, name)
                XCTAssertLessThanOrEqual(abs(d.frameCount - truth), 1, "\(name): \(d.frameCount) vs \(truth)")
                XCTAssertEqual(d.kind, ext == "mp4" ? .avfoundation : .ffmpeg, name)
                let decoded = try await Self.decodeCount(d)
                XCTAssertLessThanOrEqual(abs(decoded - truth), 1, "\(name): decoded \(decoded) vs \(truth)")
            }
        }
    }

    func testVariableFrameRate() async throws {
        try requireTools()
        // 30 frames 1/30 s apart, then 30 frames 1/60 s apart: 60 frames in ~1.5 s, written with a fine timebase
        // straight into each container (remuxing B-frame VFR from Matroska to MP4 corrupts the timing).
        func vfr(_ ext: String) throws -> URL {
            try Self.clip("vfr.\(ext)", ["-f", "lavfi", "-i", Self.pattern(320, 180, rate: "30"),
                                          "-vf", "settb=1/600,setpts='if(lt(N,30),N*2,30+N)/(60*TB)'", "-fps_mode", "passthrough",
                                          "-enc_time_base", "1/600"] + Self.x264)
        }
        let mp4 = try vfr("mp4"), mkv = try vfr("mkv")
        XCTAssertEqual(try Self.ffprobeFrames(mp4), 60, "instrument")
        XCTAssertEqual(try Self.ffprobeFrames(mkv), 60, "instrument")
        let (d, _) = try await SourceInspector.inspect(mp4)
        XCTAssertEqual(d.kind, .avfoundation)
        XCTAssertEqual(d.durationSeconds, 1.5, accuracy: 0.05, "VFR MP4 keeps its real duration (\(d.frameCount) frames at \(d.fps) fps)")
        XCTAssertLessThanOrEqual(abs(d.frameCount - 60), 1, "VFR MP4: \(d.frameCount) frames at \(d.fps) fps")
        let decoded = try await Self.decodeCount(d)
        XCTAssertEqual(decoded, 60, "AVFoundation hands over every coded frame")
        XCTAssertLessThanOrEqual(abs(decoded - d.frameCount), 1)
        // Matroska carries no frame count; the inspector estimates from duration × rate, and the FFmpeg pipe
        // delivers constant-rate frames. Both must agree closely so planning and decode line up.
        let (dk, _) = try await SourceInspector.inspect(mkv)
        XCTAssertEqual(dk.kind, .ffmpeg)
        let decodedK = try await Self.decodeCount(dk)
        XCTAssertLessThanOrEqual(abs(decodedK - dk.frameCount), 2, "VFR MKV: descriptor \(dk.frameCount) vs piped \(decodedK)")
        XCTAssertEqual(dk.durationSeconds, 1.5, accuracy: 0.1)
    }

    // MARK: - Color signaling

    func testHDRAndHLGTagsRankFirstOnBothPaths() async throws {
        try requireTools()
        let graph = Self.pattern(320, 180, seconds: 1) + ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le"
        func x265(_ trc: String) -> [String] {
            ["-vf", "setparams=color_primaries=bt2020:color_trc=\(trc):colorspace=bt2020nc", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error:colorprim=bt2020:transfer=\(trc):colormatrix=bt2020nc",
             "-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc"]
        }
        let cases: [(String, String, Transfer, String)] = [
            ("pq.mp4", "smpte2084", .pq, "SMPTE_ST_2084_PQ"), ("pq.mkv", "smpte2084", .pq, "SMPTE_ST_2084_PQ"),
            ("hlg.mov", "arib-std-b67", .hlg, "ITU_R_2100_HLG"), ("hlg.mkv", "arib-std-b67", .hlg, "ITU_R_2100_HLG")]
        for (name, trc, transfer, tag) in cases {
            let url = try Self.lavfi(name, graph, x265(trc) + (name.hasSuffix("mkv") ? [] : ["-tag:v", "hvc1"]))
            let (d, colors) = try await SourceInspector.inspect(url)
            XCTAssertEqual(d.transferTag, tag, name)
            XCTAssertEqual(d.primariesTag, "ITU_R_2020", name)
            XCTAssertTrue(d.isHDRSource, name)
            XCTAssertEqual(colors.first?.transfer, transfer, "\(name): \(colors.map(\.name))")
            XCTAssertEqual(colors.first?.gamut, .rec2020, name)
            XCTAssertEqual(colors.last?.transfer, .bt1886, "\(name): SDR is always offered last")
            XCTAssertEqual(d.kind, name.hasSuffix("mkv") ? .ffmpeg : .avfoundation, name)
            if d.kind == .ffmpeg { XCTAssertEqual(d.bitDepth, 10, name) }
        }
    }

    /// The same gray (RGB 40/255) coded as limited range and as full range must decode to the same value.
    func testFullAndLimitedRangeDecodeToSameValue() async throws {
        try requireTools()
        let expected: Float = 40 / 255
        for ext in ["mp4", "mkv"] {
            for full in [false, true] {
                let name = "range-\(full ? "full" : "tv").\(ext)"
                let url = try Self.lavfi(name, "color=c=0x282828:s=320x180:r=24:d=1,scale=out_color_matrix=bt709:out_range=\(full ? "pc" : "tv"),format=yuv420p",
                                         ["-c:v", "libx264", "-preset", "veryfast", "-qp", "0", "-color_range", full ? "pc" : "tv",
                                          "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"])
                XCTAssertEqual(try Self.streamInfo(url)["color_range"], full ? "pc" : "tv", "instrument: \(name) range flag")
                let (d, _) = try await SourceInspector.inspect(url)
                let f = try await Self.frame(d, at: 5)
                let m = Self.meanRGB(f.texture)
                XCTAssertEqual(m.x, expected, accuracy: 0.015, "\(name) (\(d.kind)): decoded \(m), expected \(expected)")
                XCTAssertEqual(m.y, expected, accuracy: 0.015, name)
            }
        }
    }

    /// SD video is normally BT.601 (smpte170m). A tagged BT.601 file must not be decoded with the BT.709 matrix.
    func testBT601TaggedSDDecodesWithItsMatrix() async throws {
        try requireTools()
        for ext in ["mov", "mkv"] {
            let name = "bt601.\(ext)"
            let url = try Self.lavfi(name, "color=c=0xC02020:s=720x480:r=30000/1001:d=1,scale=out_color_matrix=bt601:out_range=tv,format=yuv420p",
                                     ["-c:v", "libx264", "-preset", "veryfast", "-qp", "0", "-colorspace", "smpte170m",
                                      "-color_primaries", "smpte170m", "-color_trc", "smpte170m"])
            let (d, _) = try await SourceInspector.inspect(url)
            let f = try await Self.frame(d, at: 5)
            let m = Self.meanRGB(f.texture)
            XCTAssertEqual(m.x, 192 / 255, accuracy: 0.02, "\(name) (\(d.kind)) red: \(m)")
            XCTAssertEqual(m.y, 32 / 255, accuracy: 0.02, "\(name) (\(d.kind)) green: \(m)")
            XCTAssertEqual(m.z, 32 / 255, accuracy: 0.02, "\(name) (\(d.kind)) blue: \(m)")
        }
    }

    // MARK: - Camera log ranking

    /// Re-wraps a clip with QuickTime camera make/model metadata written by AVFoundation itself, the way an
    /// iPhone recording carries it (FFmpeg's `use_metadata_tags` writes keys AVFoundation reads as iTunes items).
    static func withCameraMetadata(_ src: URL, _ name: String, make: String, model: String) async throws -> URL {
        let out = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "export", code: 1, userInfo: [NSLocalizedDescriptionKey: "no passthrough export session"])
        }
        func item(_ id: AVMetadataIdentifier, _ v: String) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = v as NSString
            i.dataType = kCMMetadataBaseDataType_UTF8 as String
            return i
        }
        session.metadata = [item(.quickTimeMetadataMake, make), item(.quickTimeMetadataModel, model)]
        try await session.export(to: out, as: .mov)
        return out
    }

    func testLogLookingIPhoneFileOffersAppleLogCandidates() async throws {
        try requireTools()
        // A flat, lifted, desaturated picture (what log footage looks like) tagged as an iPhone 17 Pro recording.
        let graph = Self.pattern(640, 360, seconds: 1) + ",lutyuv=y='val*0.42+70':u='128+(val-128)*0.15':v='128+(val-128)*0.15'"
        let plain = try Self.lavfi("unknown-log.mov", graph, Self.x264)
        let url = try await Self.withCameraMetadata(plain, "iphone-log.mov", make: "Apple", model: "iPhone 17 Pro")
        let (d, colors) = try await SourceInspector.inspect(url)
        let probe = try await SourceInspector.probeSignal(d)
        XCTAssertTrue(probe.looksLog, "instrument: picture should probe as log: \(probe)")
        XCTAssertEqual(d.kind, .avfoundation)
        XCTAssertEqual(d.make, "Apple")
        XCTAssertEqual(d.model, "iPhone 17 Pro")
        let names = colors.map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["Apple Log 2", "Apple Log"], "iPhone 17 Pro log: \(names)")
        XCTAssertEqual(colors.last?.name, "SDR Rec.709")
        XCTAssertEqual(colors.first?.transfer, .appleLog)
        XCTAssertEqual(colors.first?.gamut, .appleWideGamut)

        // An older phone that can't record Apple Log 2 puts plain Apple Log first.
        let old = try await Self.withCameraMetadata(plain, "iphone15-log.mov", make: "Apple", model: "iPhone 15 Pro")
        let (_, c15) = try await SourceInspector.inspect(old)
        XCTAssertEqual(c15.first?.name, "Apple Log", "\(c15.map(\.name))")

        // The same picture with no camera tags offers the generic camera logs, each marked unsure.
        let (_, c2) = try await SourceInspector.inspect(plain)
        XCTAssertEqual(Set(c2.prefix(3).map(\.transfer)), [.sLog3, .logC3, .vLog], "\(c2.map(\.name))")
        XCTAssertTrue(c2.prefix(3).allSatisfy { $0.note != nil && $0.confidence < 0.5 })
        XCTAssertEqual(c2.last?.transfer, .bt1886)

        // A Sony-tagged log picture names S-Log3 with confidence.
        let sony = try await Self.withCameraMetadata(plain, "sony-log.mov", make: "Sony", model: "ILME-FX3")
        let (_, cs) = try await SourceInspector.inspect(sony)
        XCTAssertEqual(cs.first?.transfer, .sLog3, "\(cs.map(\.name))")

        // A normal-contrast picture from the same phone stays SDR.
        let normalPlain = try Self.lavfi("iphone-sdr-src.mov", Self.pattern(640, 360, seconds: 1), Self.x264)
        let normal = try await Self.withCameraMetadata(normalPlain, "iphone-sdr.mov", make: "Apple", model: "iPhone 17 Pro")
        let (_, c3) = try await SourceInspector.inspect(normal)
        XCTAssertEqual(c3.first?.transfer, .bt1886, "\(c3.map(\.name))")
    }

    func testAppleLogTagRanking() {
        // Apple's log tag can't be written by FFmpeg, so the ranking is exercised with the tag set directly.
        let notLog = SourceInspector.SignalProbe(p01: 0.01, median: 0.4, p995: 0.99, chroma: 0.2)
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/x.mov"), kind: .avfoundation)
        d.logTag = "AppleLog"; d.make = "Apple"; d.model = "iPhone 15 Pro"; d.primariesTag = "ITU_R_2020"
        var c = SourceInspector.rankCandidates(d, probe: notLog)
        XCTAssertEqual(c.first?.name, "Apple Log", "iPhone 15 Pro can't record Apple Log 2: \(c.map(\.name))")
        XCTAssertEqual(c.map(\.name).sorted(), ["Apple Log", "Apple Log 2", "SDR Rec.709"])
        d.model = "iPhone 17 Pro"
        c = SourceInspector.rankCandidates(d, probe: notLog)
        XCTAssertEqual(c.first?.name, "Apple Log 2")
        d.model = "iPhone 15 Pro"; d.logTag = "AppleLog2"
        c = SourceInspector.rankCandidates(d, probe: notLog)
        XCTAssertEqual(c.first?.name, "Apple Log 2", "an explicit Log 2 tag wins")
        XCTAssertTrue(c.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 })
        // Sony / ARRI / Panasonic by maker.
        let log = SourceInspector.SignalProbe(p01: 0.08, median: 0.4, p995: 0.8, chroma: 0.03)
        for (make, model, t) in [("Sony", "FX3", Transfer.sLog3), ("ARRI", "ALEXA 35", .logC4), ("ARRI", "ALEXA Mini", .logC3), ("Panasonic", "S5", .vLog)] {
            var e = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/y.mov"), kind: .avfoundation)
            e.make = make; e.model = model
            XCTAssertEqual(SourceInspector.rankCandidates(e, probe: log).first?.transfer, t, "\(make) \(model)")
        }
    }

    // MARK: - Interlace and telecine

    func testInterlacedSourcesGetDeinterlaced() async throws {
        try requireTools()
        // 50p motion woven into 25i, three ways: flagged H.264 in MKV, flagged MPEG-2 in TS, and interlaced
        // pictures coded as progressive (no field flags; only the content detector can find these).
        // Horizontal scrolling gives motion between fields everywhere in the frame, so the weave combs visibly.
        let weave = "testsrc2=s=1280x720:r=50:d=2,scale=640:360,scroll=horizontal=0.01,interlace=scan=tff"
        let sources: [(String, [String])] = [
            ("il-flagged.mkv", ["-f", "lavfi", "-i", weave + ",setfield=tff", "-c:v", "libx264", "-preset", "veryfast", "-crf", "14",
                                "-pix_fmt", "yuv420p", "-flags", "+ildct+ilme", "-x264opts", "tff=1", "-field_order", "tt"]),
            ("il-mpeg2.ts", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=60000/1001:d=2,scale=720:480,scroll=horizontal=0.01,interlace=scan=tff,setfield=tff",
                             "-c:v", "mpeg2video", "-q:v", "2", "-flags", "+ildct+ilme", "-field_order", "tt"]),
            ("il-unflagged.mkv", ["-f", "lavfi", "-i", weave + ",setfield=prog", "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p"]),
        ]
        for (name, args) in sources {
            let url = try Self.clip(name, args)
            let truth = try Self.ffprobeFrames(url)
            let (d, _) = try await SourceInspector.inspect(url)
            XCTAssertEqual(d.suggestedScanFix, .deinterlace, "\(name): field order \(d.fieldOrder ?? "nil")")
            XCTAssertEqual(d.scanFix, .deinterlace, "\(name): the suggested fix is applied on open")
            XCTAssertEqual(d.kind, .ffmpeg, name)
            XCTAssertEqual(d.frameCount, d.originalFrameCount, name)
            XCTAssertLessThanOrEqual(abs(d.frameCount - truth), 1, name)
            // Raw (unfixed) frames comb; fixed frames don't.
            let raw = d.applying(.none)
            XCTAssertEqual(raw.scanFix, .none)
            let combedFrame = try await Self.frame(raw, at: 10)
            let fixedFrame = try await Self.frame(d, at: 10)
            let combed = Self.combRatio(combedFrame.texture), fixed = Self.combRatio(fixedFrame.texture)
            XCTAssertGreaterThan(combed, 1.3, "instrument: \(name) should comb before the fix (\(combed))")
            XCTAssertLessThan(fixed, 1.1, "\(name): still combed after deinterlacing (ratio \(fixed), raw \(combed))")
            let decoded = try await Self.decodeCount(d)
            XCTAssertLessThanOrEqual(abs(decoded - d.frameCount), 1, "\(name): \(decoded) vs \(d.frameCount)")
            // Double-rate deinterlacing doubles rate and count, and the decoder really produces twice the frames.
            let dbl = d.applying(.deinterlaceDouble)
            XCTAssertEqual(Double(dbl.fpsNum) / Double(dbl.fpsDen), d.fps * 2, accuracy: 0.001, name)
            XCTAssertEqual(dbl.frameCount, d.originalFrameCount * 2, name)
            let decodedDouble = try await Self.decodeCount(dbl)
            XCTAssertLessThanOrEqual(abs(decodedDouble - dbl.frameCount), 2, "\(name) double rate: \(decodedDouble) vs \(dbl.frameCount)")
        }
    }

    func testTelecineIsDetectedAndInverted() async throws {
        try requireTools()
        let sources: [(String, [String])] = [
            ("telecine.mkv", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24000/1001:d=2,scale=640:360,scroll=horizontal=0.01,telecine=pattern=23"] + Self.x264),
            ("telecine.ts", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24000/1001:d=2,scale=720:480,scroll=horizontal=0.01,telecine=pattern=23",
                             "-c:v", "mpeg2video", "-q:v", "2"]),
        ]
        for (name, args) in sources {
            let url = try Self.clip(name, args)
            let truth = try Self.ffprobeFrames(url)
            let (d, _) = try await SourceInspector.inspect(url)
            XCTAssertEqual(d.suggestedScanFix, .inverseTelecine, name)
            XCTAssertEqual(d.scanFix, .inverseTelecine, name)
            XCTAssertEqual(d.originalFpsNum, 30000, name); XCTAssertEqual(d.originalFpsDen, 1001, name)
            XCTAssertEqual(d.fpsNum, 24000, name); XCTAssertEqual(d.fpsDen, 1001, name)
            XCTAssertLessThanOrEqual(abs(d.originalFrameCount - truth), 1, name)
            XCTAssertEqual(d.frameCount, d.originalFrameCount * 4 / 5, name)
            let decoded = try await Self.decodeCount(d)
            XCTAssertLessThanOrEqual(abs(decoded - d.frameCount), 1, "\(name): IVTC produced \(decoded), expected \(d.frameCount)")
            let back = d.applying(.none)
            XCTAssertEqual(back.fpsNum, 30000); XCTAssertEqual(back.frameCount, d.originalFrameCount)
            XCTAssertEqual(back.kind, .ffmpeg)
            XCTAssertTrue(d.summary.contains("telecined"), d.summary)
        }
    }

    func testScanFixApplyingIsReversibleAndStartsFromOriginalTiming() {
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/z.mov"), kind: .avfoundation)
        (d.fpsNum, d.fpsDen, d.frameCount) = (30000, 1001, 300)
        let ivtc = d.applying(.inverseTelecine)
        XCTAssertEqual(ivtc.fpsNum, 24000); XCTAssertEqual(ivtc.fpsDen, 1001); XCTAssertEqual(ivtc.frameCount, 240)
        XCTAssertEqual(ivtc.kind, .ffmpeg)
        let dbl = ivtc.applying(.deinterlaceDouble)     // switching fixes always starts from the file's timing
        XCTAssertEqual(dbl.fpsNum, 60000); XCTAssertEqual(dbl.fpsDen, 1001); XCTAssertEqual(dbl.frameCount, 600)
        let none = dbl.applying(.none)
        XCTAssertEqual(none.kind, .avfoundation); XCTAssertEqual(none.fpsNum, 30000); XCTAssertEqual(none.frameCount, 300)
        XCTAssertEqual(none.scanFix, .none)
    }

    // MARK: - Crop

    func testLetterboxAndPillarboxCrop() async throws {
        try requireTools()
        let cases: [(String, String, SIMD4<Float>)] = [
            ("letterbox.mp4", "testsrc2=s=1280x544:r=24:d=1,pad=1280:720:0:88:black", SIMD4(0, 88 / 720, 1, 544 / 720)),
            ("letterbox.mkv", "testsrc2=s=1280x544:r=24:d=1,pad=1280:720:0:88:black", SIMD4(0, 88 / 720, 1, 544 / 720)),
            ("pillarbox.mov", "testsrc2=s=960x720:r=24:d=1,pad=1280:720:160:0:black", SIMD4(160 / 1280, 0, 960 / 1280, 1)),
            ("windowbox.mkv", "testsrc2=s=1000x560:r=24:d=1,pad=1280:720:140:80:black", SIMD4(140 / 1280, 80 / 720, 1000 / 1280, 560 / 720)),
            ("fullframe.mp4", "testsrc2=s=1280x720:r=24:d=1", SIMD4(0, 0, 1, 1)),
        ]
        for (name, graph, want) in cases {
            let url = try Self.lavfi(name, graph, Self.x264)
            let (d, _) = try await SourceInspector.inspect(url)
            let crop = try await CropDetector.detect(d)
            let px = SIMD4<Float>(Float(d.width), Float(d.height), Float(d.width), Float(d.height))
            let got = crop * px, pic = want * px
            // Edges in pixels: the crop may keep a few rows of codec ringing / chroma bleed from the bars, but must
            // never cut into the picture (2 px allowed for the even-size rounding).
            let (gx0, gy0, gx1, gy1) = (got.x, got.y, got.x + got.z, got.y + got.w)
            let (px0, py0, px1, py1) = (pic.x, pic.y, pic.x + pic.z, pic.y + pic.w)
            let msg = "\(name): crop \(got) px, picture \(pic) px"
            XCTAssertTrue(gx0 <= px0 + 2 && gy0 <= py0 + 2 && gx1 >= px1 - 2 && gy1 >= py1 - 2, "cuts into the picture: " + msg)
            XCTAssertTrue(px0 - gx0 <= 8 && py0 - gy0 <= 8 && gx1 - px1 <= 8 && gy1 - py1 <= 8, "leaves too much bar: " + msg)
            var cropped = d
            cropped.crop = crop
            XCTAssertLessThanOrEqual(abs(cropped.outputWidth - Int(want.z * Float(d.width))), 16, name)
            XCTAssertLessThanOrEqual(abs(cropped.outputHeight - Int(want.w * Float(d.height))), 16, name)
            XCTAssertEqual(cropped.outputWidth % 2, 0); XCTAssertEqual(cropped.outputHeight % 2, 0)
        }
    }

    // MARK: - Scene analysis

    func testHardCutsAreFoundAtTheRightFrames() async throws {
        try requireTools()
        let graph = "testsrc2=s=640x360:r=24:d=1.5[a];smptehdbars=s=640x360:r=24:d=1.5[b];mandelbrot=s=640x360:r=24,trim=duration=1.5,setpts=PTS-STARTPTS[c];[a][b][c]concat=n=3:v=1"
        let url = try Self.clip("cuts.mp4", ["-filter_complex", graph] + Self.x264)
        XCTAssertEqual(try Self.ffprobeFrames(url), 108, "instrument")
        let (d, colors) = try await SourceInspector.inspect(url)
        var progressSeen: [Double] = []
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { progressSeen.append($0) }
        XCTAssertEqual(a.frameCount, 108)
        XCTAssertEqual(a.cutFrames.sorted(), [0, 36, 72], "cuts found at \(a.cutFrames.sorted())")
        XCTAssertEqual(a.scenes.map(\.start), [0, 36, 72])
        XCTAssertEqual(a.scenes.last?.end, 108)
        XCTAssertEqual(a.sceneIndex(for: 50), 1); XCTAssertEqual(a.sceneIndex(for: 107), 2)
        XCTAssertEqual(a.motion.count, 108)
        XCTAssertEqual(a.motion[36], 0, "motion is zeroed at a cut"); XCTAssertEqual(a.motion[72], 0)
        XCTAssertEqual(progressSeen.last, 1)
        XCTAssertTrue(a.transitions.isEmpty, "no fades in this clip: \(a.transitions)")
        // The bars shot is a still picture, so its frames repeat; nothing in the moving shots does.
        XCTAssertTrue(a.duplicateFrames.allSatisfy { (37..<72).contains($0) }, "duplicates outside the still shot: \(a.duplicateFrames.sorted())")
        // Bars (scene 2) are static: much less motion than the moving test pattern (scene 1).
        XCTAssertLessThan(a.sceneMotion(1), a.sceneMotion(0))
        // Per-scene light levels are ordered and finite.
        for s in a.scenes { XCTAssertTrue(s.p005 <= s.p50 && s.p50 <= s.p995 && s.keyStops.isFinite, "\(s)") }
    }

    func testFadesAndDissolvesAreFound() async throws {
        try requireTools()
        let fades = try Self.clip("fades.mp4", ["-filter_complex",
            "testsrc2=s=640x360:r=24:d=2,fade=t=out:st=1:d=1[a];smptehdbars=s=640x360:r=24:d=2,fade=t=in:st=0:d=1[b];[a][b]concat=n=2:v=1"] + Self.x264)
        let (d, colors) = try await SourceInspector.inspect(fades)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        XCTAssertEqual(a.frameCount, 96)
        let out = a.transitions.first { $0.kind == .fadeOut }
        let inn = a.transitions.first { $0.kind == .fadeIn }
        XCTAssertNotNil(out, "fade out not found: \(a.transitions)")
        XCTAssertNotNil(inn, "fade in not found: \(a.transitions)")
        if let out { XCTAssertTrue(out.start >= 22 && out.end <= 50 && out.end - out.start >= 8, "fade out span \(out)") }
        if let inn { XCTAssertTrue(inn.start >= 46 && inn.end <= 74 && inn.end - inn.start >= 8, "fade in span \(inn)") }

        let dissolve = try Self.clip("dissolve.mp4", ["-filter_complex",
            "testsrc2=s=640x360:r=24:d=2[a];smptehdbars=s=640x360:r=24:d=2[b];[a][b]xfade=transition=fade:duration=1:offset=1"] + Self.x264)
        let (d2, c2) = try await SourceInspector.inspect(dissolve)
        let b = try await SceneAnalyzer.analyze(d2, color: c2[0]) { _ in }
        XCTAssertEqual(b.frameCount, 72)
        let dis = b.transitions.first { $0.kind == .dissolve && $0.end > 24 && $0.start < 48 }
        XCTAssertNotNil(dis, "dissolve over frames 24-48 not found: \(b.transitions)")
        if let dis { XCTAssertTrue(dis.start >= 20 && dis.end <= 52, "dissolve span \(dis)") }
        print("DISSOLVE transitions \(b.transitions) cuts \(b.cutFrames.sorted())")
        // Known limitation, kept visible: the per-frame chi-square histogram distance shrinks with the square of the
        // step, so a 24-frame dissolve between shots of similar brightness only registers over its last ~7 frames.
        XCTExpectFailure("SceneAnalyzer: long dissolves between similar-brightness shots are only caught at their tail") {
            XCTAssertNotNil(b.transition(containing: 30), "frame 30 is mid-dissolve: \(b.transitions)")
        }
        XCTAssertFalse(b.cutFrames.contains { $0 > 26 && $0 < 46 }, "a dissolve is not a hard cut: \(b.cutFrames.sorted())")
    }

    func testAnimationOnTwosMarksDuplicates() async throws {
        try requireTools()
        let twos = try Self.lavfi("twos.mp4", "testsrc2=s=640x360:r=12:d=2,fps=24", Self.x264)
        let (d, colors) = try await SourceInspector.inspect(twos)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        XCTAssertEqual(a.frameCount, 48)
        XCTAssertGreaterThanOrEqual(a.duplicateFrames.count, 22, "on twos: \(a.duplicateFrames.sorted())")
        XCTAssertTrue(a.duplicateFrames.allSatisfy { $0 % 2 == 1 }, "only the repeated (odd) frames: \(a.duplicateFrames.sorted())")
        let ones = try Self.lavfi("ones.mp4", "testsrc2=s=640x360:r=24:d=2", Self.x264)
        let (d1, c1) = try await SourceInspector.inspect(ones)
        let b = try await SceneAnalyzer.analyze(d1, color: c1[0]) { _ in }
        XCTAssertTrue(b.duplicateFrames.isEmpty, "every frame moves: \(b.duplicateFrames.sorted())")
    }

    // MARK: - Content test

    func testContentProfilerKinds() async throws {
        try requireTools()
        // Flat-colour cartoon, drawn on twos: shapes move every second frame over a flat background.
        let cartoon = "color=c=0x2a6fd6:s=1280x720:r=12:d=4[bg];color=c=0xffd000:s=240x240:r=12:d=4[a];color=c=0xe03030:s=200x300:r=12:d=4[b];" +
                      "[bg][a]overlay=x='100+t*150':y=200[c];[c][b]overlay=x=800:y='80+t*60',fps=24"
        // A stand-in for camera footage: a smooth "sky" half and a fine-texture half, with large-scale movement
        // across both (testsrc2 itself is flat-colour graphics, so it reads as animation, correctly).
        func scene(dark: Bool) -> String {
            let sky = dark ? "4+Y*0.05+6*sin(X*0.012+T*2)" : "60+Y*0.25+20*sin(X*0.012+T*2)"
            let texture = dark ? "30+25*sin(X*0.37+Y*0.11+T*3)*sin(Y*0.29-X*0.07+T)+15*sin(X*0.01-T*3)"
                               : "120+45*sin(X*0.37+Y*0.11+T*3)*sin(Y*0.29-X*0.07+T)+30*sin(X*0.01-T*3)"
            return "nullsrc=s=640x360:r=24:d=4,geq=lum='16+if(lt(X,W/2),\(sky),\(texture))':cb=128:cr=128,scale=1280:720"
        }
        let grainLight = scene(dark: false) + ",noise=alls=8:allf=t"
        let grainHeavy = scene(dark: false) + ",noise=alls=30:allf=t"
        let darkGrain = scene(dark: true) + ",noise=alls=8:allf=t"
        let screen = "color=c=white:s=1280x720:r=24:d=4,drawgrid=w=80:h=40:t=2:c=0x202020,drawbox=x=100:y=100:w=300:h=150:color=0x3070ff:t=fill," +
                     "drawbox=x=640:y=300:w=400:h=24:color=black:t=fill"
        let natural = scene(dark: false)
        let flatGrain = "testsrc2=s=1280x720:r=24:d=4,noise=alls=8:allf=t"
        // The same cartoon with black ink outlines (line art) around every shape.
        let ink = "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=3"
        let lineArt = "color=c=0x2a6fd6:s=1280x720:r=12:d=4,drawbox=x=200:y=500:w=300:h=120:color=0x40a040:t=fill,drawbox=x=200:y=500:w=300:h=120:color=black:t=3[bg];" +
                      "color=c=0xffd000:s=240x240:r=12:d=4,\(ink)[a];color=c=0xe03030:s=200x300:r=12:d=4,\(ink)[b];" +
                      "[bg][a]overlay=x='100+t*150':y=200[c];[c][b]overlay=x=800:y='80+t*60',fps=24"
        let cases: [(String, String, Set<ContentKind>)] = [
            ("cartoon.mp4", cartoon, [.anime]),
            ("lineart.mp4", lineArt, [.anime]),
            ("scene-grain.mp4", grainLight, [.realLifeHeavyGrain]),
            ("scene-dark-grain.mp4", darkGrain, [.lowLightNoisy]),
            ("screen.mp4", screen, [.screenContent]),
            ("scene-clean.mp4", natural, [.realLife, .cgiAnimation, .fastMotion]),
            ("flat-grain.mp4", flatGrain, [.oldAnime]),   // flat graphics + grain: what grainy cel animation looks like
        ]
        var failures: [String] = []
        for (name, graph, kinds) in cases {
            let url = try Self.clip(name, ["-filter_complex", graph] + Self.x264)
            let (d, colors) = try await SourceInspector.inspect(url)
            let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
            let p = try await ContentProfiler.profile(d, color: colors[0], analysis: a, progress: ProgressReporter(task: nil))
            let line = "\(name): \(p.kind) conf \(p.confidence) flat \(p.flatShare) grain \(p.grain) detail \(p.detail) motion \(p.motion) repeats \(p.repeatedFrameShare) key \(a.globalKey) — \(p.evidence)"
            print("PROFILE " + line)
            if !kinds.contains(p.kind) { failures.append(line) }
            XCTAssertFalse(p.evidence.isEmpty, name)
            XCTAssertTrue(p.confidence > 0 && p.confidence <= 1, name)
            XCTAssertEqual(ContentTuning.preset(p.kind).kind, p.kind)
        }
        XCTAssertTrue(failures.isEmpty, "misclassified:\n" + failures.joined(separator: "\n"))

        // Known limitation, kept visible: grain is only measured inside blocks whose variance is below 0.0004
        // (std 0.02). Noise stronger than that makes no block "flat", so the grain reading is 0 and very heavy
        // grain is reported as clean real life. Strict: this starts failing (and must be updated) once fixed.
        let url = try Self.clip("scene-heavygrain.mp4", ["-filter_complex", grainHeavy] + Self.x264)
        let (d, colors) = try await SourceInspector.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        let p = try await ContentProfiler.profile(d, color: colors[0], analysis: a, progress: ProgressReporter(task: nil))
        print("PROFILE scene-heavygrain.mp4: \(p.kind) flat \(p.flatShare) grain \(p.grain)")
        XCTExpectFailure("ContentProfiler: noise above std 0.02 leaves no flat block to measure grain in (grain reads 0)") {
            XCTAssertEqual(p.kind, .realLifeHeavyGrain, "heavy noise: flat \(p.flatShare) grain \(p.grain)")
        }
    }

    // MARK: - RAW (DNG / CinemaDNG)

    /// Writes a minimal uncompressed LinearRaw DNG (16-bit RGB, linear sRGB camera space, D65): bright top band,
    /// horizontal ramp below, everything scaled by `gain`.
    static func writeDNG(_ url: URL, width w: Int, height h: Int, gain: Float) throws {
        var pixels = Data(capacity: w * h * 6)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = y < h / 4 ? 0.8 : 0.05 + 0.25 * Float(x) / Float(w)
                let c = UInt16(max(0, min(65535, v * gain * 65535)))
                for _ in 0..<3 { pixels.append(UInt8(c & 0xFF)); pixels.append(UInt8(c >> 8)) }
            }
        }
        struct Entry { var tag: UInt16; var type: UInt16; var count: UInt32; var bytes: Data }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func short(_ t: UInt16, _ v: [UInt16]) -> Entry { Entry(tag: t, type: 3, count: UInt32(v.count), bytes: v.reduce(Data()) { $0 + le16($1) }) }
        func long(_ t: UInt16, _ v: [UInt32]) -> Entry { Entry(tag: t, type: 4, count: UInt32(v.count), bytes: v.reduce(Data()) { $0 + le32($1) }) }
        func ascii(_ t: UInt16, _ s: String) -> Entry { let d = Data(s.utf8) + Data([0]); return Entry(tag: t, type: 2, count: UInt32(d.count), bytes: d) }
        func bytes(_ t: UInt16, _ v: [UInt8]) -> Entry { Entry(tag: t, type: 1, count: UInt32(v.count), bytes: Data(v)) }
        func srational(_ t: UInt16, _ v: [Double]) -> Entry {
            Entry(tag: t, type: 10, count: UInt32(v.count), bytes: v.reduce(Data()) { $0 + le32(UInt32(bitPattern: Int32(($1 * 10000).rounded()))) + le32(10000) })
        }
        func rational(_ t: UInt16, _ v: [Double]) -> Entry {
            Entry(tag: t, type: 5, count: UInt32(v.count), bytes: v.reduce(Data()) { $0 + le32(UInt32(($1 * 10000).rounded())) + le32(10000) })
        }
        let xyzToSRGB: [Double] = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
        var entries = [
            long(254, [0]), long(256, [UInt32(w)]), long(257, [UInt32(h)]), short(258, [16, 16, 16]), short(259, [1]),
            short(262, [34892]), ascii(271, "Lumora"), ascii(272, "Test Camera"), long(273, [0]), short(274, [1]),
            short(277, [3]), long(278, [UInt32(h)]), long(279, [UInt32(pixels.count)]), short(284, [1]),
            bytes(50706, [1, 4, 0, 0]), bytes(50707, [1, 1, 0, 0]), ascii(50708, "Lumora Test Camera"),
            short(50717, [65535, 65535, 65535]), srational(50721, xyzToSRGB), rational(50728, [1, 1, 1]), short(50778, [21]),
        ]
        entries.sort { $0.tag < $1.tag }
        let ifdSize = 2 + entries.count * 12 + 4
        var extra = Data()
        let extraBase = 8 + ifdSize
        var offsets: [Int: UInt32] = [:]
        for (i, e) in entries.enumerated() where e.bytes.count > 4 {
            offsets[i] = UInt32(extraBase + extra.count)
            extra.append(e.bytes)
            if extra.count % 2 == 1 { extra.append(0) }
        }
        let imageOffset = UInt32(extraBase + extra.count)
        if let i = entries.firstIndex(where: { $0.tag == 273 }) { entries[i].bytes = le32(imageOffset) }
        var file = Data("II".utf8) + le16(42) + le32(8) + le16(UInt16(entries.count))
        for (i, e) in entries.enumerated() {
            file += le16(e.tag) + le16(e.type) + le32(e.count)
            if let off = offsets[i] { file += le32(off) } else { file += e.bytes + Data(count: 4 - e.bytes.count) }
        }
        file += le32(0) + extra + pixels
        try file.write(to: url)
    }

    func testDNGStillAndCinemaDNGFolder() async throws {
        try TestHardware.requireGPU()
        let folder = Self.work.appendingPathComponent("cdng", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Names chosen so plain string order (1, 10, 2) differs from natural frame order (1, 2, 10).
        let gains: [(String, Float)] = [("clip_1.dng", 0.5), ("clip_2.dng", 0.75), ("clip_10.dng", 1.0)]
        for (n, g) in gains { try Self.writeDNG(folder.appendingPathComponent(n), width: 256, height: 144, gain: g) }
        try Data("not a frame".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let still = folder.appendingPathComponent("clip_10.dng")
        guard CIRAWFilter(imageURL: still) != nil else {
            throw XCTSkip("Core Image's RAW engine rejects the hand-written LinearRaw DNG on this OS; no DNG writer is available to make a real one")
        }

        let (d, colors) = try await SourceInspector.inspect(still)
        XCTAssertEqual(d.kind, .rawSequence)
        XCTAssertEqual(d.width, 256); XCTAssertEqual(d.height, 144)
        XCTAssertEqual(d.frameCount, 1)
        XCTAssertEqual(d.codec, "DNG")
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(colors.first?.transfer, .linear); XCTAssertEqual(colors.first?.gamut, .rec2020)
        let f = try await Self.frame(d, at: 0)
        XCTAssertEqual(f.texture.width, 256); XCTAssertEqual(f.texture.height, 144)
        let p = Self.luma(Self.pixels(f.texture))
        let top = p[(144 / 8) * 256 + 128], bottomLeft = p[(144 * 7 / 8) * 256 + 10], bottomRight = p[(144 * 7 / 8) * 256 + 245]
        XCTAssertGreaterThan(top, bottomRight * 1.5, "bright band must be at the top (Metal top-left origin): top \(top) bottom \(bottomRight)")
        XCTAssertGreaterThan(bottomRight, bottomLeft * 1.5, "ramp must rise left to right: \(bottomLeft) → \(bottomRight)")
        XCTAssertTrue(p.allSatisfy { $0.isFinite && $0 >= -0.01 }, "scene-linear output is finite and non-negative")
        // Scene-linear: the ramp's left/right ratio (0.05 vs 0.30) should survive roughly linearly, not as a tone curve.
        XCTAssertEqual(bottomRight / max(1e-4, bottomLeft), 0.299 / 0.051, accuracy: 2.5, "linearity \(bottomLeft) \(bottomRight)")

        let (seq, _) = try await SourceInspector.inspect(folder)
        XCTAssertEqual(seq.kind, .rawSequence)
        XCTAssertEqual(seq.frameCount, 3)
        XCTAssertEqual(seq.codec, "DNG sequence")
        XCTAssertEqual(seq.files.map(\.lastPathComponent), ["clip_1.dng", "clip_2.dng", "clip_10.dng"])
        let src = try await seq.makeFrameSource()
        try src.start(at: 0, count: nil)
        var means: [Float] = []
        while let fr = try src.nextFrame() { means.append(Self.meanRGB(fr.texture).sum() / 3); XCTAssertEqual(fr.index, means.count - 1) }
        XCTAssertEqual(means.count, 3)
        XCTAssertTrue(means[0] < means[1] && means[1] < means[2], "frames decode in natural order: \(means)")
        try src.start(at: 2, count: 1)
        XCTAssertNotNil(try src.nextFrame()); XCTAssertNil(try src.nextFrame())
        // The whole analysis pass runs on the sequence too.
        let a = try await SceneAnalyzer.analyze(seq, color: colors[0]) { _ in }
        XCTAssertEqual(a.frameCount, 3)
    }

    // MARK: - Errors that must be clear

    func testVendorRAWAndMissingEncoderAreReportedClearly() async throws {
        let braw = Self.work.appendingPathComponent("clip.braw")
        try Data(count: 64).write(to: braw)
        do {
            _ = try await SourceInspector.inspect(braw)
            XCTFail("a .braw with no plug-in must not open")
        } catch let e as LumoraError {
            guard case .needsVendorSDK(let ext) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertEqual(ext, "braw")
            XCTAssertTrue(e.localizedDescription.contains("plug-in"), e.localizedDescription)
        }
        // Without AV2's reference encoder, absence must read as "not installed", not a crash (skipped where
        // avmenc is installed; AV2ExportTests covers it then).
        if !ToolLocator.isAvailable("avmenc") {
            XCTAssertNil(ToolLocator.url(for: "avmenc"))
            XCTAssertThrowsError(try ToolLocator.run("avmenc", ["--help"])) { e in
                guard case LumoraError.missingTool(let t)? = e as? LumoraError else { return XCTFail("wrong error \(e)") }
                XCTAssertEqual(t, "avmenc")
                XCTAssertTrue(e.localizedDescription.contains("isn't installed"))
            }
        }
        // A file that isn't video at all.
        let junk = Self.work.appendingPathComponent("junk.mp4")
        try Data("hello".utf8).write(to: junk)
        do { _ = try await SourceInspector.inspect(junk); XCTFail("junk must not open") } catch {}
    }

    // MARK: - Frame sources

    func testFrameSourcesSeekToTheRightFrame() async throws {
        try requireTools()
        // Each frame has a different overall brightness, so a seek to the wrong frame shows up in the mean.
        let graph = Self.pattern(320, 180) + ",geq=lum='lum(X,Y)*(0.3+0.7*N/48)':cb='cb(X,Y)':cr='cr(X,Y)'"
        for name in ["seek.mp4", "seek.mkv"] {
            let url = try Self.lavfi(name, graph, Self.x264)
            let (d, _) = try await SourceInspector.inspect(url)
            let src = try await d.makeFrameSource()
            try src.start(at: 0, count: nil)
            var sequential: [Float] = []
            while let f = try src.nextFrame() { sequential.append(Self.meanRGB(f.texture).sum()) }
            XCTAssertEqual(sequential.count, 48, name)
            for target in [1, 17, 30, 47] {
                try src.start(at: target, count: 1)
                let f = try XCTUnwrap(try src.nextFrame(), "\(name) frame \(target)")
                XCTAssertEqual(f.index, target, "\(name): reported index")
                XCTAssertEqual(Self.meanRGB(f.texture).sum(), sequential[target], accuracy: 0.004, "\(name): seek to \(target) returned another frame")
                XCTAssertNil(try src.nextFrame(), "\(name): count 1 must stop after one frame")
            }
            src.cancel()
        }
    }

    // MARK: - Storage, scratch and proxy

    func testStorageInspectorDescribesVolumes() throws {
        let boot = try XCTUnwrap(StorageInspector.describe(URL(fileURLWithPath: "/")))
        XCTAssertEqual(boot.mountPoint.path, "/")
        XCTAssertTrue(boot.isInternal, "the boot volume is internal")
        XCTAssertEqual(boot.isSolidState, true, "Apple silicon boot drives are SSDs")
        XCTAssertGreaterThan(boot.totalBytes, 10 << 30)
        XCTAssertGreaterThan(boot.freeBytes, 0)
        XCTAssertLessThanOrEqual(boot.freeBytes, boot.totalBytes)
        XCTAssertFalse(boot.bus.isEmpty)
        XCTAssertEqual(boot.kindDescription, "Internal SSD")
        let tmp = try XCTUnwrap(StorageInspector.describe(Self.work))
        XCTAssertTrue(tmp.isInternal)
        XCTAssertGreaterThan(tmp.freeBytes, 0)
        XCTAssertTrue(Self.work.resolvingSymlinksInPath().path.hasPrefix(tmp.mountPoint.path), "\(tmp.mountPoint.path)")
        XCTAssertNil(StorageInspector.describe(URL(fileURLWithPath: "/definitely/not/here-\(UUID())")))

        // Speed measurements on a 48 MB file and a 32 MB write, in the temp folder only.
        let big = Self.work.appendingPathComponent("speed.bin")
        try Data(count: 48 << 20).write(to: big)
        let read = try XCTUnwrap(StorageInspector.measureRead(big, bytes: 48 << 20))
        XCTAssertGreaterThan(read, 50, "internal SSD read MB/s")
        XCTAssertNil(StorageInspector.measureRead(Self.work.appendingPathComponent("missing.bin")))
        let write = try XCTUnwrap(StorageInspector.measureWrite(Self.work, bytes: 32 << 20))
        XCTAssertGreaterThan(write, 20)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: Self.work.path).filter { $0.hasPrefix(".lumora-speedtest") }
        XCTAssertTrue(leftovers.isEmpty, "speed test file removed")
        try? FileManager.default.removeItem(at: big)
    }

    /// Runs `body` with `scratchRoot` pointed at a temp folder, restoring the user's setting afterwards.
    func withTemporaryScratch(_ body: (URL) async throws -> Void) async throws {
        let key = "scratchRoot"
        let saved = Prefs.store.object(forKey: key)
        let root = Self.work.appendingPathComponent("scratch-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Prefs.store.set(root.path, forKey: key)
        defer {
            if let saved { Prefs.store.set(saved, forKey: key) } else { Prefs.store.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(root)
    }

    func testScratchJobDirectoryStagingAndPlan() async throws {
        let before = Prefs.store.object(forKey: "scratchRoot") as? String
        try await withTemporaryScratch { root in
            let job = try ScratchManager.jobDirectory("unit")
            XCTAssertEqual(job.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
            XCTAssertTrue(job.lastPathComponent.hasPrefix("unit-"))
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: job.path, isDirectory: &isDir) && isDir.boolValue)
            let job2 = try ScratchManager.jobDirectory("unit")
            XCTAssertNotEqual(job, job2, "every job gets its own folder")
            XCTAssertEqual(ScratchManager.proxiesFolder.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)

            // Staging copies byte for byte into a scratch job folder.
            let src = Self.work.appendingPathComponent("stage-src.bin")
            var bytes = Data(count: 3 << 20)
            bytes.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) } }
            try bytes.write(to: src)
            let staged = try await Stager.stage(src, progress: ProgressReporter(task: nil))
            XCTAssertTrue(staged.path.hasPrefix(root.path), staged.path)
            XCTAssertEqual(try Data(contentsOf: staged), bytes)
            XCTAssertEqual(staged.lastPathComponent, "stage-src.bin")

            // Read-ahead hints never fail on a real file, and refuse a missing one.
            let ra = try XCTUnwrap(ReadAheadAdvisor(url: src, window: 1 << 20))
            for f in [0.0, 0.3, 0.9, 1.0, 2.0, -1.0] { ra.advance(toFraction: f) }
            XCTAssertNil(ReadAheadAdvisor(url: Self.work.appendingPathComponent("nope.bin")))

            // A source on the internal SSD streams directly.
            if EndToEndTests.ffmpeg != nil {
                let clip = try Self.lavfi("plan.mp4", Self.pattern(320, 180, seconds: 1), Self.x264)
                let (d, _) = try await SourceInspector.inspect(clip)
                let plan = StoragePlan.make(for: d, measureSpeed: false)
                XCTAssertEqual(plan.strategy, .stream, plan.explanation)
                XCTAssertFalse(plan.buildProxy)
                XCTAssertEqual(plan.maxConcurrentReaders, 8)
                XCTAssertGreaterThan(plan.sourceBitrateMBps, 0)
                XCTAssertNotNil(plan.source); XCTAssertNotNil(plan.scratch)
            }
        }
        XCTAssertEqual(Prefs.store.object(forKey: "scratchRoot") as? String, before, "scratchRoot restored")
    }

    func testProxyIsWrittenDuringAnalysis() async throws {
        try TestHardware.requireHardwareHEVC()
        guard EndToEndTests.ffmpeg != nil else { throw XCTSkip("FFmpeg not installed") }
        try await withTemporaryScratch { root in
            for (name, w, h) in [("proxy-src-720.mp4", 1280, 720), ("proxy-src-small.mkv", 640, 360)] {
                let url = try Self.lavfi(name, Self.pattern(w, h), Self.x264)
                let (d, colors) = try await SourceInspector.inspect(url)
                let proxy = try ProxyWriter(for: d)
                XCTAssertTrue(proxy.url.path.hasPrefix(root.path), "proxy goes to the scratch drive: \(proxy.url.path)")
                let a = try await SceneAnalyzer.analyze(d, color: colors[0], proxy: proxy) { _ in }
                let finished = await proxy.finish()
                let out = try XCTUnwrap(finished, "\(name): proxy writer failed")
                let info = try Self.streamInfo(out)
                XCTAssertEqual(info["codec_name"], "hevc", name)
                XCTAssertTrue(info["pix_fmt"]?.contains("10") == true, "\(name): \(info["pix_fmt"] ?? "")")
                XCTAssertEqual(Int(info["nb_read_frames"] ?? ""), a.frameCount, "\(name): one proxy frame per analyzed frame")
                XCTAssertEqual(info["avg_frame_rate"], "24/1", name)
                let size = ProxyWriter.outputSize(for: d)
                XCTAssertEqual(Int(info["height"] ?? ""), size.height, name)
                XCTAssertEqual(Int(info["width"] ?? ""), size.width, name)
                XCTAssertEqual(size.height, min(720, h), name)
                XCTAssertEqual(size.width, w * min(720, h) / h, "\(name): proxy keeps the aspect ratio")
                // The proxy is the encoded signal: its picture matches the source's (both near the pattern's mean).
                let ySrc = try EndToEndTests.meanLuma(url), yProxy = try EndToEndTests.meanLuma(out)
                XCTAssertEqual(yProxy, ySrc, accuracy: 0.06, "\(name): proxy luma \(yProxy) vs source \(ySrc)")
                // And it opens as a normal source.
                let (pd, _) = try await SourceInspector.inspect(out)
                XCTAssertEqual(pd.kind, .avfoundation)
                XCTAssertEqual(pd.width, size.width); XCTAssertEqual(pd.height, size.height)
            }
        }
    }
}
