import XCTest
import Metal
import ImageIO
import CoreGraphics
@testable import Lumora

/// Grading, looks, upscaling, LUTs, stills, presets, reference match, grain, regression set, scopes and probe,
/// exercised end to end with real files, the real GPU and the real encoders. Every check looks at the output
/// itself (ffprobe fields, frame counts, decoded pixel values), not merely at the absence of an error.
@MainActor
final class CampaignGradeTests: XCTestCase {

    // MARK: - Media and tools

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraGrade-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    struct Run { var status: Int32; var out: Data; var err: String }

    @discardableResult
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if stdin != nil { p.standardInput = Pipe() } else { p.standardInput = FileHandle.nullDevice }
        try p.run()
        if let stdin, let pipe = p.standardInput as? Pipe {
            DispatchQueue.global().async { pipe.fileHandleForWriting.write(stdin); try? pipe.fileHandleForWriting.close() }
        }
        var errData = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        p.waitUntilExit()
        return Run(status: p.terminationStatus, out: o, err: String(decoding: errData, as: UTF8.self))
    }

    static func ffmpeg(_ args: [String]) throws -> Run {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let r = try run(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
        if r.status != 0 { throw NSError(domain: "ffmpeg", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: "ffmpeg \(args.joined(separator: " ")): \(r.err)"]) }
        return r
    }

    /// 640x360: testsrc2 on top (288 rows) and a full-range gray ramp below (72 rows), 12 frames at 24 fps.
    /// HDR: the same RGB scaled so white is PQ 0.75 (≈1000 nits), coded like a UHD rip (10-bit, BT.2020, PQ tags).
    static func makeSource(_ name: String, hdr: Bool, frames: Int = 12, size: (Int, Int) = (640, 360), whitePQ: Double = 0.75,
                           pattern: String = "testsrc2") throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let (w, h) = size
        let rampH = h / 5, topH = h - rampH
        let d = String(format: "%.4f", Double(frames) / 24.0)
        let head = pattern.contains("=") ? pattern : "\(pattern)=s=\(w)x\(topH):r=24"
        var g = "\(head),trim=end_frame=\(frames),setpts=PTS-STARTPTS,format=rgb48le[a];"
            + "nullsrc=s=\(w)x\(rampH):r=24:d=\(d),format=rgb48le,geq=r='X*65535/(W-1)':g='X*65535/(W-1)':b='X*65535/(W-1)'[b];"
            + "[a][b]vstack=inputs=2"
        var args: [String]
        if hdr {
            g += ",colorlevels=romax=\(whitePQ):gomax=\(whitePQ):bomax=\(whitePQ),scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le[v]"
            args = ["-c:v", "libx265", "-x265-params", "log-level=error:crf=8:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                    "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        } else {
            g += ",scale=out_color_matrix=bt709:out_range=tv,format=yuv420p[v]"
            args = ["-c:v", "libx264", "-crf", "6", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        try ffmpeg(["-filter_complex", g, "-map", "[v]", "-frames:v", "\(frames)"] + args + [url.path])
        return url
    }

    struct Media {
        var url: URL
        var d: SourceDescriptor
        var colors: [SourceColor]
        var analysis: AnalysisResult
        var report: HDRReportCard?
        var presets: [PresetCandidate]
        var color: SourceColor { colors[0] }

        /// Every look, including ones the engine doesn't offer for this source (Rip Revive on SDR), with its
        /// real adapted parameters whenever the engine does offer it.
        func preset(_ look: Look) -> PresetCandidate {
            presets.first { $0.look == look && $0.color == color }
                ?? PresetCandidate(name: look.displayName, look: look, color: color, params: look.params,
                                   sceneExposures: analysis.scenes.map { _ in 0 }, reason: "test")
        }
    }

    static var mediaCache: [String: Media] = [:]

    static func media(_ name: String, hdr: Bool) async throws -> Media {
        if let m = mediaCache[name] { return m }
        try TestHardware.requireGPU()
        let url = try makeSource(name, hdr: hdr)
        let (d, colors) = try await SourceInspector.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        let report = (colors[0].transfer == .pq || colors[0].transfer == .hlg)
            ? HDRReportCard.make(title: name, descriptor: d, color: colors[0], analysis: a) : nil
        let m = Media(url: url, d: d, colors: colors, analysis: a, report: report,
                      presets: AutoPresetEngine.generate(colors: colors, analysis: a, report: report))
        mediaCache[name] = m
        return m
    }

    // MARK: - GPU helpers

    static var ctx: MetalContext { MetalContext.shared }

    static func sharedTexture(_ w: Int, _ h: Int) -> MTLTexture {
        ctx.makeTexture(width: w, height: h, format: .rgba32Float, usage: [.shaderRead, .shaderWrite], storage: .shared)
    }

    static func texture(_ px: [Float], _ w: Int, _ h: Int) -> MTLTexture {
        let t = sharedTexture(w, h)
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        return t
    }

    /// Copies (or bilinearly resamples) any texture into a CPU-readable RGBA float texture.
    static func resample(_ src: MTLTexture, _ w: Int, _ h: Int) -> MTLTexture {
        let dst = sharedTexture(w, h)
        var rect = SIMD4<Float>(0, 0, 1, 1)
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&rect, length: 16, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("cropCopyKernel"), width: w, height: h)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    static func pixels(_ t: MTLTexture) -> [Float] {
        let s = (t.storageMode == .shared && t.pixelFormat == .rgba32Float) ? t : resample(t, t.width, t.height)
        var buf = [Float](repeating: 0, count: s.width * s.height * 4)
        s.getBytes(&buf, bytesPerRow: s.width * 16, from: MTLRegionMake2D(0, 0, s.width, s.height), mipmapLevel: 0)
        return buf
    }

    /// First decoded frame of a file as a shared RGBA float texture (the encoded signal, like every stage sees it).
    static func frame(_ m: Media, index: Int = 0) async throws -> MTLTexture {
        let src = try await m.d.makeFrameSource()
        try src.start(at: index, count: 1)
        let f = try XCTUnwrap(try src.nextFrame(), "no frame decoded from \(m.url.lastPathComponent)")
        let t = resample(f.texture, f.texture.width, f.texture.height)
        src.cancel()
        return t
    }

    static func uniforms(_ color: SourceColor, _ params: GradeParams, _ target: OutputTarget, w: Int, h: Int,
                         exposure: Float = 0, sourcePeak: Float = 1000) -> GradeUniforms {
        UniformBuilder.make(source: color, params: params, target: target, sceneExposureStops: exposure,
                            viewport: SIMD4<Float>(0, 0, Float(w), Float(h)), sourcePeakNits: sourcePeak)
    }

    /// Lumora's own grade of a frame: encoded output RGB (PQ / HLG / BT.1886), no dither.
    static func grade(_ src: MTLTexture, _ u: GradeUniforms) -> [Float] {
        let dst = sharedTexture(src.width, src.height)
        let cb = ctx.queue.makeCommandBuffer()!
        GradeRenderer().encodeGrade(cb, source: src, destination: dst, uniforms: u)
        cb.commit()
        cb.waitUntilCompleted()
        return pixels(dst)
    }

    static func luma(_ px: [Float], kr: Float = 0.2627, kb: Float = 0.0593) -> [Float] {
        let kg = 1 - kr - kb
        return stride(from: 0, to: px.count, by: 4).map { kr * px[$0] + kg * px[$0 + 1] + kb * px[$0 + 2] }
    }

    static func mean(_ v: [Float]) -> Double { v.isEmpty ? 0 : v.reduce(0.0) { $0 + Double($1) } / Double(v.count) }
    static func std(_ v: [Float]) -> Double {
        let m = mean(v)
        return sqrt(v.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(max(1, v.count)))
    }
    static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let ma = mean(a), mb = mean(b)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices {
            let x = Double(a[i]) - ma, y = Double(b[i]) - mb
            sab += x * y; saa += x * x; sbb += y * y
        }
        return sab / max(1e-12, sqrt(saa * sbb))
    }
    static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        var se = 0.0
        for i in a.indices { let d = Double(a[i]) - Double(b[i]); se += d * d }
        let mse = se / Double(max(1, a.count))
        return mse <= 1e-14 ? 140 : 10 * log10(1 / mse)
    }
    /// Mean absolute horizontal + vertical gradient of luma (higher = sharper).
    static func sharpness(_ px: [Float], _ w: Int, _ h: Int) -> Double {
        let y = luma(px)
        var s = 0.0, n = 0
        for r in 1..<(h - 1) { for c in 1..<(w - 1) {
            let i = r * w + c
            s += Double(abs(y[i + 1] - y[i])) + Double(abs(y[i + w] - y[i])); n += 1
        } }
        return s / Double(max(1, n))
    }

    // MARK: - File inspection

    struct StreamInfo {
        var codec = "", pixFmt = "", transfer = "", primaries = "", width = 0, height = 0, frames = -1
        var masteringMax: Double?, maxCLL: Double?
    }

    static func streamInfo(_ url: URL) throws -> StreamInfo {
        guard let fp = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let r = try run(fp, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_streams", "-of", "default=nw=1", url.path])
        var kv: [String: String] = [:]
        for line in String(decoding: r.out, as: UTF8.self).split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2, kv[p[0]] == nil { kv[p[0]] = p[1] }
        }
        func ratio(_ s: String?) -> Double? {
            guard let s else { return nil }
            let p = s.split(separator: "/").compactMap { Double($0) }
            return p.count == 2 ? p[0] / max(1, p[1]) : Double(s)
        }
        return StreamInfo(codec: kv["codec_name"] ?? "", pixFmt: kv["pix_fmt"] ?? "", transfer: kv["color_transfer"] ?? "",
                          primaries: kv["color_primaries"] ?? "", width: Int(kv["width"] ?? "") ?? 0, height: Int(kv["height"] ?? "") ?? 0,
                          frames: Int(kv["nb_read_frames"] ?? "") ?? -1,
                          masteringMax: ratio(kv["max_luminance"]), maxCLL: kv["max_content"].flatMap(Double.init))
    }

    struct FrameStats { var avg: Double; var min: Double; var max: Double }

    /// Per-frame luma statistics, in normalized signal units ((code - 64) / 876 at 10-bit, studio range).
    static func frameStats(_ url: URL) throws -> [FrameStats] {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let r = try run(ff, ["-hide_banner", "-i", url.path, "-vf", "format=yuv420p10le,signalstats,metadata=print", "-f", "null", "-"])
        var out: [FrameStats] = [], cur: [String: Double] = [:]
        for line in r.err.split(separator: "\n") {
            for key in ["YAVG", "YMIN", "YMAX"] {
                if let range = line.range(of: "lavfi.signalstats.\(key)=") {
                    cur[key] = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
                }
            }
            if let a = cur["YAVG"], let lo = cur["YMIN"], let hi = cur["YMAX"] {
                out.append(FrameStats(avg: (a - 64) / 876, min: (lo - 64) / 876, max: (hi - 64) / 876)); cur = [:]
            }
        }
        return out
    }

    /// Mean of the ramp band per column bin (normalized signal, studio range 10-bit), from frame `index`.
    static func rampProfile(_ url: URL, width: Int = 640, height: Int = 360, bins: Int = 32) throws -> [Double] {
        let rampH = height / 5, y0 = height - rampH + 8, rows = rampH - 16
        let r = try ffmpeg(["-i", url.path, "-vf", "select=eq(n\\,6),crop=\(width):\(rows):0:\(y0)", "-frames:v", "1",
                            "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"])
        let count = width * rows
        let ys: [UInt16] = r.out.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self).prefix(count)) }
        guard ys.count == count else { return [] }
        let perBin = width / bins
        return (0..<bins).map { b in
            var s = 0.0
            for row in 0..<rows { for c in (b * perBin)..<((b + 1) * perBin) { s += Double(ys[row * width + c]) } }
            return (s / Double(rows * perBin) - 64) / 876
        }
    }

    /// One frame as RGB 0...1 (studio-range Y'CbCr decoded with the stated matrix), for nits comparisons.
    static func rgbFrame(_ url: URL, wide: Bool, index: Int = 6, matrix: String? = nil) throws -> [Float] {
        let r = try ffmpeg(["-i", url.path, "-vf", "select=eq(n\\,\(index)),scale=in_color_matrix=\(matrix ?? (wide ? "bt2020" : "bt709")):in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48le",
                            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-"])
        return r.out.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Float($0) / 65535 } }
    }

    static func hlgToNits(_ rgb: SIMD3<Float>) -> Float {
        let s = SIMD3(TransferMath.hlgInverse(rgb.x), TransferMath.hlgInverse(rgb.y), TransferMath.hlgInverse(rgb.z))
        let ys = max(1e-6, simd_dot(s, ColorScience.luma2020))
        return 1000 * powf(ys, 1.2)
    }

    static func ramp(of rgb: [Float], width: Int = 640, height: Int = 360, bins: Int = 32, toNits: (SIMD3<Float>) -> Float) -> [Double] {
        let rampH = height / 5, y0 = height - rampH + 8, rows = rampH - 16, perBin = width / bins
        return (0..<bins).map { b in
            var s = 0.0
            for r in y0..<(y0 + rows) { for c in (b * perBin)..<((b + 1) * perBin) {
                let i = (r * width + c) * 3
                s += Double(toNits(SIMD3(rgb[i], rgb[i + 1], rgb[i + 2])))
            } }
            return s / Double(rows * perBin)
        }
    }

    /// Y PSNR of b against a, both at 10-bit (the psnr summary is printed at info level, so no -loglevel error here).
    static func yPSNR(_ a: URL, _ b: URL) throws -> Double {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let p = try run(ff, ["-hide_banner", "-i", a.path, "-i", b.path, "-lavfi", "[0:v]format=yuv420p10le[x];[1:v]format=yuv420p10le[y];[x][y]psnr", "-f", "null", "-"])
        guard let range = p.err.range(of: " y:") else { return 0 }
        let tail = p.err[range.upperBound...].split(separator: " ").first ?? ""
        return tail == "inf" ? 140 : Double(tail) ?? 0
    }

    func export(_ m: Media, preset: PresetCandidate, target: OutputTarget, codec: Codec = .hevc, name: String,
                configure: (inout ExportJob) -> Void = { _ in }) async throws -> URL {
        let delivery: DeliveryFormat = target.kind == .sdr ? .sdr : (target.kind == .hlg ? .hlg : .hdr10)
        var job = ExportJob(descriptor: m.d, preset: preset, analysis: m.analysis, delivery: delivery, codec: codec,
                            outputURL: Self.work.appendingPathComponent(name))
        job.peakNits = target.peakNits
        job.sourcePeakNits = m.report?.p999Nits ?? 1000
        configure(&job)
        try? FileManager.default.removeItem(at: job.outputURL)
        return try await ExportEngine().run(job) { _, _ in }
    }

    static let targets: [(String, OutputTarget)] = [("sdr", .sdr), ("hdr1000", .hdr10_1000), ("hdr2000", .hdr10_2000),
                                                     ("hdr4000", .hdr10_4000), ("hlg", .hlg)]

    // MARK: - Every look × every target, from SDR and from HDR10

    func testEveryLookFromSDRToEveryTarget() async throws {
        try TestHardware.requireHardwareHEVC()
        try await lookMatrix(try await Self.media("grade-sdr.mp4", hdr: false))
    }

    func testEveryLookFromHDR10ToEveryTarget() async throws {
        try TestHardware.requireHardwareHEVC()
        try await lookMatrix(try await Self.media("grade-hdr10.mp4", hdr: true))
    }

    private func lookMatrix(_ m: Media) async throws {
        var problems: [String] = []
        var table: [String] = []
        let srcTag = m.color.transfer == .pq ? "hdr" : "sdr"
        for look in Look.allCases {
            let preset = m.preset(look)
            for (tname, target) in Self.targets {
                let url = try await export(m, preset: preset, target: target, name: "look-\(srcTag)-\(look.rawValue)-\(tname).mov")
                let info = try Self.streamInfo(url)
                let stats = try Self.frameStats(url)
                let ramp = try Self.rampProfile(url)
                let tag = "\(srcTag)→\(tname) \(look.rawValue)"
                func fail(_ s: String) { problems.append("\(tag): \(s)") }

                if info.codec != "hevc" { fail("codec \(info.codec)") }
                if !info.pixFmt.contains("10") { fail("pix_fmt \(info.pixFmt)") }
                if info.width != 640 || info.height != 360 { fail("size \(info.width)x\(info.height)") }
                if info.frames != 12 || stats.count != 12 { fail("frames \(info.frames)/\(stats.count)") }
                let (trc, prim) = target.kind == .sdr ? ("bt709", "bt709") : (target.kind == .hlg ? ("arib-std-b67", "bt2020") : ("smpte2084", "bt2020"))
                if info.transfer != trc || info.primaries != prim { fail("tags \(info.transfer)/\(info.primaries)") }

                // Peak signal the target allows (PQ code of the target peak for HDR10, 1.0 for SDR/HLG), plus dither.
                let ceiling = target.kind == .hdr10 ? Double(TransferMath.nitsToPQ(target.peakNits)) : 1.0
                let peak = stats.map(\.max).max() ?? 0
                let meanY = stats.map(\.avg).reduce(0, +) / Double(max(1, stats.count))
                if stats.contains(where: { $0.avg < 0.06 }) { fail("black frame (min YAVG \(stats.map(\.avg).min() ?? 0))") }
                if stats.contains(where: { $0.max - $0.min < 0.2 }) { fail("flat frame") }
                if meanY < 0.12 || meanY > 0.8 { fail(String(format: "mean Y' %.3f out of range", meanY)) }
                if peak > ceiling + 0.012 { fail(String(format: "peak Y' %.3f above target ceiling %.3f", peak, ceiling)) }
                // Highlights must still look like highlights: SDR white near the top, HDR above graphics white (203 nits).
                let minPeak = target.kind == .sdr ? 0.75 : (target.kind == .hlg ? 0.7 : Double(TransferMath.nitsToPQ(200)))
                if peak < minPeak { fail(String(format: "peak Y' %.3f too dim (want ≥ %.3f)", peak, minPeak)) }
                if target.kind == .hdr10 {
                    if let mm = info.masteringMax, abs(mm - Double(target.peakNits)) > 1 { fail("mastering max \(mm)") }
                    if info.masteringMax == nil { fail("no mastering display metadata") }
                    if let cll = info.maxCLL, cll > Double(target.peakNits) + 1 || cll < 100 { fail("MaxCLL \(cll)") }
                }
                // The gray ramp must stay monotonic and keep gradation at its bright end (no clipped plateau).
                if ramp.count != 32 { fail("ramp unreadable") } else {
                    for i in 1..<ramp.count where ramp[i] < ramp[i - 1] - 0.004 { fail(String(format: "ramp inverts at bin %d (%.4f < %.4f)", i, ramp[i], ramp[i - 1])); break }
                    let plateau = ramp.filter { $0 >= ramp[31] - 1.0 / 876 }.count
                    if plateau > 4 { fail("clipped: top \(plateau) of 32 ramp bins within one code value of the maximum") }
                    if ramp[31] - ramp[24] < 0.01 { fail(String(format: "bright end of ramp flattened (%.4f → %.4f)", ramp[24], ramp[31])) }
                }
                table.append(String(format: "%@ mean %.3f peak %.3f (ceiling %.3f) ramp %.3f/%.3f/%.3f cll %@", tag, meanY, peak, ceiling,
                                    ramp.first ?? -1, ramp.count > 24 ? ramp[24] : -1, ramp.last ?? -1, info.maxCLL.map { "\(Int($0))" } ?? "-"))
                try? FileManager.default.removeItem(at: url)
            }
        }
        print("LOOK MATRIX\n" + table.joined(separator: "\n"))
        XCTAssertTrue(problems.isEmpty, "\(problems.count) problems:\n" + problems.joined(separator: "\n"))
    }

    // MARK: - "Keep original look" round trips

    func testOriginalLookRoundTripsSDRAndHDR10() async throws {
        try TestHardware.requireHardwareHEVC()
        let sdr = try await Self.media("grade-sdr.mp4", hdr: false)
        let hdr = try await Self.media("grade-hdr10.mp4", hdr: true)

        // Same transfer in and out: compare code values directly.
        let s2s = try await export(sdr, preset: sdr.preset(.original), target: .sdr, name: "orig-sdr-sdr.mov")
        let psnrSDR = try Self.yPSNR(sdr.url, s2s)
        XCTAssertGreaterThan(psnrSDR, 40, "SDR → SDR with Keep original look should be near-lossless (Y PSNR \(psnrSDR) dB)")
        for (name, t) in [("2000", OutputTarget.hdr10_2000), ("4000", .hdr10_4000)] {
            let url = try await export(hdr, preset: hdr.preset(.original), target: t, name: "orig-hdr-\(name).mov")
            let p = try Self.yPSNR(hdr.url, url)
            XCTAssertGreaterThan(p, 40, "HDR10 (1000-nit master) → HDR10 \(name) original look should be near-lossless (Y PSNR \(p) dB)")
        }
        // 1000-nit master to a 1000-nit target: everything below the soft knee (750 nits) passes unchanged.
        let h1000 = try await export(hdr, preset: hdr.preset(.original), target: .hdr10_1000, name: "orig-hdr-1000.mov")
        let srcRGB = try Self.rgbFrame(hdr.url, wide: true), outRGB = try Self.rgbFrame(h1000, wide: true)
        let pq: (SIMD3<Float>) -> Float = { TransferMath.pqToNits(simd_dot($0, ColorScience.luma2020)) }
        let srcRamp = Self.ramp(of: srcRGB, toNits: pq), outRamp = Self.ramp(of: outRGB, toNits: pq)
        for i in srcRamp.indices where srcRamp[i] > 1 && srcRamp[i] < 700 {
            XCTAssertEqual(outRamp[i], srcRamp[i], accuracy: srcRamp[i] * 0.04 + 0.2, "HDR10→HDR10 1000 original, ramp bin \(i)")
        }

        // Different transfer: compare displayed light after decoding each file with its own transfer.
        let toHLG = try await export(hdr, preset: hdr.preset(.original), target: .hlg, name: "orig-hdr-hlg.mov")
        let hlgRamp = Self.ramp(of: try Self.rgbFrame(toHLG, wide: true)) { Self.hlgToNits($0) }
        for i in srcRamp.indices where srcRamp[i] > 1 && srcRamp[i] < 700 {
            XCTAssertEqual(hlgRamp[i], srcRamp[i], accuracy: srcRamp[i] * 0.06 + 0.3, "HDR10→HLG original, ramp bin \(i) in nits")
        }
        let toPQ = try await export(sdr, preset: sdr.preset(.original), target: .hdr10_1000, name: "orig-sdr-hdr.mov")
        let sdrRamp = Self.ramp(of: try Self.rgbFrame(sdr.url, wide: false)) { 203 * powf(max(0, simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722))), 2.4) }
        let sdrInPQ = Self.ramp(of: try Self.rgbFrame(toPQ, wide: true), toNits: pq)
        for i in sdrRamp.indices where sdrRamp[i] > 1 {
            XCTAssertEqual(sdrInPQ[i], sdrRamp[i], accuracy: sdrRamp[i] * 0.05 + 0.3, "SDR→HDR10 original places SDR at BT.2408 (white = 203 nits), bin \(i)")
        }
        XCTAssertEqual(sdrInPQ.last ?? 0, 203, accuracy: 10, "SDR white in HDR10 should sit at ~203 nits")
        for u in [s2s, h1000, toHLG, toPQ] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: - GradeParams extremes

    func testEveryGradeSliderAtItsExtremesStaysSane() async throws {
        let sdr = try await Self.media("grade-sdr.mp4", hdr: false)
        let hdr = try await Self.media("grade-hdr10.mp4", hdr: true)
        typealias Field = (String, WritableKeyPath<GradeParams, Float>, ClosedRange<Float>)
        // The ranges of the sliders in the Look panel (InspectorView).
        let fields: [Field] = [
            ("exposure", \.exposureStops, -3...3), ("brightness", \.midGreyStops, -1...1), ("contrast", \.contrast, 0.7...1.5),
            ("punch", \.localContrast, 0...0.8), ("halo", \.edgeProtection, 0...1), ("toe", \.toe, 0...1),
            ("shoulder", \.shoulder, 1...4), ("hlSoften", \.highlightDesat, 0...1), ("saturation", \.saturation, 0.6...1.4),
            ("vibrance", \.vibrance, 0...1), ("skin", \.skinProtect, 0...1), ("warmth", \.temperature, -1...1),
            ("tint", \.tint, -1...1), ("deband", \.deband, 0...1), ("rebuild", \.highlightExpansion, 0...8)]
        var problems: [String] = []
        var renders = 0
        for m in [sdr, hdr] {
            let src = try await Self.frame(m, index: 3)
            let w = src.width, h = src.height
            for target in [OutputTarget.sdr, .hdr10_1000, .hdr10_4000, .hlg] {
                var baseParams = Look.natural.params
                baseParams.expandHDRSources = true
                let base = Self.luma(Self.grade(src, Self.uniforms(m.color, baseParams, target, w: w, h: h)))
                var cases: [(String, GradeParams)] = []
                for (name, kp, range) in fields {
                    for (label, v) in [("min", range.lowerBound), ("max", range.upperBound)] {
                        var p = baseParams; p[keyPath: kp] = v
                        cases.append(("\(name)=\(label)", p))
                    }
                }
                var allMin = baseParams, allMax = baseParams
                for (_, kp, range) in fields { allMin[keyPath: kp] = range.lowerBound; allMax[keyPath: kp] = range.upperBound }
                cases += [("ALL=min", allMin), ("ALL=max", allMax)]
                for (label, p) in cases {
                    let px = Self.grade(src, Self.uniforms(m.color, p, target, w: w, h: h))
                    renders += 1
                    let tag = "\(m.color.transfer.rawValue)→\(target.displayName) \(label)"
                    if px.contains(where: { !$0.isFinite }) { problems.append("\(tag): NaN/Inf"); continue }
                    let rgb = px.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
                    if let lo = rgb.min(), let hi = rgb.max(), lo < -1e-4 || hi > (target.kind == .hlg ? 1.12 : 1.0001) {
                        problems.append("\(tag): values outside the signal range [\(lo), \(hi)]")
                    }
                    let y = Self.luma(px)
                    let mu = Self.mean(y), sd = Self.std(y), r = Self.correlation(y, base)
                    if mu < 0.03 { problems.append(String(format: "%@: black (mean %.4f)", tag, mu)) }
                    if sd < 0.02 { problems.append(String(format: "%@: flat (std %.4f)", tag, sd)) }
                    if r < 0.6 { problems.append(String(format: "%@: garbage (correlation with the default grade %.3f)", tag, r)) }
                }
            }
        }
        XCTAssertGreaterThan(renders, 200)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: - UniformBuilder

    func testUniformBuilderFillsEveryTargetCorrectly() {
        let sdr = SourceColor(name: "SDR", transfer: .bt1886, gamut: .rec709, legalToFull: false, confidence: 1)
        let pq = SourceColor(name: "PQ", transfer: .pq, gamut: .rec2020, legalToFull: false, confidence: 1)
        let vp = SIMD4<Float>(0, 0, 640, 360)
        for t in OutputTarget.all {
            let u = UniformBuilder.make(source: sdr, params: Look.natural.params, target: t, sceneExposureStops: 0, viewport: vp)
            XCTAssertEqual(u.peakNits, t.kind == .hdr10 ? t.peakNits : (t.kind == .hlg ? 1000 : 100), "\(t.displayName)")
            XCTAssertEqual(u.outputTransfer, t.kind == .hdr10 ? OUT_PQ : (t.kind == .hlg ? OUT_HLG : OUT_SDR))
            XCTAssertEqual(u.midGreyNits, t.isHDR ? 26 : 18, accuracy: 1e-4)
            XCTAssertEqual(u.blackNits, t.isHDR ? 0.005 : 0.05, accuracy: 1e-6)
            XCTAssertEqual(u.inputTransfer, TF_BT1886)
            XCTAssertEqual(u.viewport, vp)
            XCTAssertEqual(u.sourceRect, UniformBuilder.fullFrame)
            let luma = t.kind == .sdr ? SIMD3<Float>(0.2126, 0.7152, 0.0722) : SIMD3<Float>(0.2627, 0.6780, 0.0593)
            XCTAssertEqual(Double(simd_distance(SIMD3(u.outputLuma.x, u.outputLuma.y, u.outputLuma.z), luma)), 0, accuracy: 2e-4)
            if t.kind == .sdr {
                XCTAssertEqual(u.workingToOutput.columns.0.x, 1.6605, accuracy: 2e-3, "BT.2020 → BT.709 matrix")
                XCTAssertEqual(u.inputToWorking.columns.0.x, 0.6274, accuracy: 2e-3, "BT.709 → BT.2020 matrix")
                XCTAssertEqual(u.highlightExpansion, 0, "SDR → SDR never expands highlights")
            } else {
                XCTAssertEqual(u.workingToOutput, matrix_identity_float3x3)
                XCTAssertEqual(u.highlightExpansion, Look.natural.params.highlightExpansion, "SDR → HDR rebuilds highlights")
                XCTAssertEqual(u.expansionKnee, 0.72, accuracy: 1e-6)
            }
            // The 3x3 matrices are exact inverses where they should be.
            let roundTrip = u.xyzToWorking * u.workingToXYZ
            XCTAssertEqual(Double(simd_distance(roundTrip.columns.0, SIMD3(1, 0, 0))), 0, accuracy: 1e-4)
        }
        // Rip Revive expands an HDR master above ~100 nits up to its measured peak, only for HDR targets.
        let rr = UniformBuilder.make(source: pq, params: Look.ripRevive.params, target: .hdr10_4000, sceneExposureStops: 0,
                                     viewport: vp, sourcePeakNits: 450)
        XCTAssertEqual(rr.highlightExpansion, 3)
        XCTAssertEqual(rr.expansionKnee, 100 / 144, accuracy: 1e-6)
        XCTAssertEqual(rr.expansionCeiling, 450 / 144, accuracy: 1e-5)
        let rrLow = UniformBuilder.make(source: pq, params: Look.ripRevive.params, target: .hdr10_1000, sceneExposureStops: 0,
                                        viewport: vp, sourcePeakNits: 20)
        XCTAssertEqual(rrLow.expansionCeiling, 150 / 144, accuracy: 1e-5, "ceiling never collapses onto the knee")
        XCTAssertEqual(UniformBuilder.make(source: pq, params: Look.ripRevive.params, target: .sdr, sceneExposureStops: 0, viewport: vp).highlightExpansion, 0)
        XCTAssertEqual(UniformBuilder.make(source: pq, params: Look.natural.params, target: .hdr10_1000, sceneExposureStops: 0, viewport: vp).highlightExpansion, 0,
                       "HDR sources are only expanded by looks that ask for it")

        // Every control lands in its uniform.
        var p = GradeParams()
        p.exposureStops = 1; p.midGreyStops = -1; p.contrast = 1.3; p.toe = 0.7; p.shoulder = 3.5; p.localContrast = 0.6
        p.saturation = 1.2; p.vibrance = 0.4; p.skinProtect = 0.3; p.highlightDesat = 0.8; p.deband = 0.5; p.edgeProtection = 1
        p.temperature = 0.6; p.tint = -0.4; p.passthrough = true; p.matchCurve = (0..<80).map { Float($0) / 100 }
        let crop = SIMD4<Float>(0, 0.125, 1, 0.75)
        let u = UniformBuilder.make(source: pq, params: p, target: .hdr10_2000, sceneExposureStops: 0.5, viewport: vp, split: 0.5,
                                    crop: crop, ditherBits: 10, frameSeed: 70_000, falseColor: true)
        XCTAssertEqual(u.exposure, powf(2, 1.5), accuracy: 1e-5)
        XCTAssertEqual(u.midGreyNits, 13, accuracy: 1e-4)
        XCTAssertEqual(u.contrast, 1.3); XCTAssertEqual(u.toe, 0.7); XCTAssertEqual(u.shoulder, 3.5)
        XCTAssertEqual(u.localContrast, 0.6); XCTAssertEqual(u.saturation, 1.2); XCTAssertEqual(u.vibrance, 0.4)
        XCTAssertEqual(u.skinProtect, 0.3); XCTAssertEqual(u.highlightDesat, 0.8)
        XCTAssertEqual(u.debandThreshold, 0.003, accuracy: 1e-6); XCTAssertEqual(u.debandRadius, 16, accuracy: 1e-6)
        XCTAssertEqual(u.guidedEpsilon, 0.01, accuracy: 1e-6)
        XCTAssertEqual(u.ditherAmplitude, 1 / 1023, accuracy: 1e-7)
        XCTAssertEqual(u.frameSeed, Int32(70_000 & 0xFFFF))
        XCTAssertEqual(u.passthrough, 1); XCTAssertEqual(u.falseColor, 1); XCTAssertEqual(u.split, 0.5)
        XCTAssertEqual(u.sourceRect, crop)
        XCTAssertEqual(u.matchCurveSize, 64, "the curve is capped at the uniform's 64 slots")
        withUnsafeBytes(of: u.matchCurve) { raw in
            let f = raw.bindMemory(to: Float.self)
            XCTAssertEqual(f[0], 0); XCTAssertEqual(f[63], 0.63, accuracy: 1e-6)
        }
        let gain = SIMD3(u.wbGain.x, u.wbGain.y, u.wbGain.z)
        XCTAssertEqual(simd_dot(gain, ColorScience.luma2020), 1, accuracy: 1e-5, "white balance keeps luminance")
        XCTAssertGreaterThan(gain.x, gain.z, "warmer = more red than blue")
        var raw = SIMD3<Float>(powf(2, 0.6 * 0.5), powf(2, 0.4 * 0.3), powf(2, -0.6 * 0.5))
        raw /= simd_dot(raw, ColorScience.luma2020)
        XCTAssertEqual(Double(simd_distance(gain, raw)), 0, accuracy: 1e-5, "warmth/tint gains (negative tint = greener)")
        p.matchCurve = [0.5]
        XCTAssertEqual(UniformBuilder.make(source: pq, params: p, target: .sdr, sceneExposureStops: 0, viewport: vp).matchCurveSize, 0,
                       "a one-point curve is ignored")
        let none = UniformBuilder.make(source: pq, params: p, target: .sdr, sceneExposureStops: 0, viewport: vp)
        XCTAssertEqual(none.ditherAmplitude, 0, "no dither unless an output depth is given")
        let a = UniformBuilder.analysis(source: pq, gridW: 320, gridH: 180)
        XCTAssertEqual(a.viewport, SIMD4(0, 0, 320, 180)); XCTAssertEqual(a.outputTransfer, OUT_SDR); XCTAssertEqual(a.localContrast, 0)
    }

    // MARK: - Upscaling

    private func upscaleCheck(from small: (Int, Int), to big: (Int, Int)) async throws {
        try TestHardware.requireGPU()
        // Ground truth at the large size, and the same picture downscaled (area) as the input.
        let truthURL = Self.work.appendingPathComponent("up-truth-\(big.1).mov")
        let smallURL = Self.work.appendingPathComponent("up-small-\(small.1).mov")
        if !FileManager.default.fileExists(atPath: smallURL.path) {
            try Self.ffmpeg(["-f", "lavfi", "-i", "mandelbrot=s=\(big.0)x\(big.1):r=24,trim=end_frame=1", "-c:v", "prores_ks", "-profile:v", "3",
                             "-pix_fmt", "yuv422p10le", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", truthURL.path])
            try Self.ffmpeg(["-i", truthURL.path, "-vf", "scale=\(small.0):\(small.1):flags=area", "-c:v", "prores_ks", "-profile:v", "3",
                             "-pix_fmt", "yuv422p10le", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", smallURL.path])
        }
        let (d, colors) = try await SourceInspector.inspect(smallURL)
        let m = Media(url: smallURL, d: d, colors: colors, analysis: .empty, report: nil, presets: [])
        let src = try await Self.frame(m)
        XCTAssertEqual(src.width, small.0); XCTAssertEqual(src.height, small.1)
        let stage: PreGradeStage
        do { stage = try PreGradeStage(sourceWidth: small.0, sourceHeight: small.1, crop: UniformBuilder.fullFrame, mode: .metalFX(targetHeight: big.1)) }
        catch { throw XCTSkip("MetalFX not available: \(error.localizedDescription)") }
        XCTAssertEqual(stage.outputWidth, big.0); XCTAssertEqual(stage.outputHeight, big.1)
        let out: MTLTexture, rect: SIMD4<Float>
        do { (out, rect) = try stage.process(src) } catch { throw XCTSkip("MetalFX spatial scaler unavailable: \(error.localizedDescription)") }
        XCTAssertEqual(out.width, big.0, "MetalFX output width"); XCTAssertEqual(out.height, big.1, "MetalFX output height")
        XCTAssertEqual(rect, UniformBuilder.fullFrame, "after the stage the grade uses the whole (already cropped) frame")
        let fx = Self.pixels(out)
        XCTAssertFalse(fx.contains { !$0.isFinite }, "MetalFX output has NaN")
        let bilinear = Self.pixels(Self.resample(src, big.0, big.1))
        let (tm, tc) = try await SourceInspector.inspect(truthURL)
        let truth = Self.pixels(try await Self.frame(Media(url: truthURL, d: tm, colors: tc, analysis: .empty, report: nil, presets: [])))
        let sFX = Self.sharpness(fx, big.0, big.1), sBL = Self.sharpness(bilinear, big.0, big.1), sT = Self.sharpness(truth, big.0, big.1)
        let pFX = Self.psnr(Self.luma(fx), Self.luma(truth)), pBL = Self.psnr(Self.luma(bilinear), Self.luma(truth))
        print(String(format: "UPSCALE %dx%d→%dx%d sharpness FX %.5f bilinear %.5f truth %.5f; PSNR FX %.2f bilinear %.2f",
                     small.0, small.1, big.0, big.1, sFX, sBL, sT, pFX, pBL))
        XCTAssertGreaterThan(sFX, sBL * 1.05, "MetalFX should be visibly sharper than bilinear")
        XCTAssertGreaterThan(pFX, pBL - 1.0, "…without drifting away from the true picture")
        XCTAssertEqual(Self.mean(Self.luma(fx)), Self.mean(Self.luma(bilinear)), accuracy: 0.01, "upscaling keeps brightness")
    }

    func testMetalFXUpscales360pTo720p() async throws { try await upscaleCheck(from: (640, 360), to: (1280, 720)) }
    func testMetalFXUpscales720pTo2160p() async throws { try await upscaleCheck(from: (1280, 720), to: (3840, 2160)) }

    func testUpscaledExportHasExactOutputSize() async throws {
        try TestHardware.requireHardwareHEVC()
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        let url = try await export(m, preset: m.preset(.natural), target: .hdr10_1000, name: "upscaled.mov") { $0.upscale = .metalFX(targetHeight: 720) }
        let info = try Self.streamInfo(url)
        XCTAssertEqual(info.width, 1280); XCTAssertEqual(info.height, 720); XCTAssertEqual(info.frames, 12)
        let stats = try Self.frameStats(url)
        XCTAssertFalse(stats.contains { $0.avg < 0.06 }, "no black frames after upscaling")
        try? FileManager.default.removeItem(at: url)
    }

    func testMissingRealESRGANModelIsReportedCleanly() async throws {
        for spec in UpscaleModelSpec.all() {
            if spec.isInstalled { continue }
            XCTAssertThrowsError(try PreGradeStage(sourceWidth: 640, sourceHeight: 360, crop: UniformBuilder.fullFrame,
                                                   mode: .model(id: spec.id, targetHeight: 1440))) { e in
                XCTAssertTrue(e.localizedDescription.contains("isn't installed"), "\(spec.id): \(e.localizedDescription)")
            }
        }
        XCTAssertFalse(UpscaleModelSpec.all().isEmpty, "the bundled model catalog should list Real-ESRGAN models")
        XCTAssertThrowsError(try PreGradeStage(sourceWidth: 640, sourceHeight: 360, crop: UniformBuilder.fullFrame,
                                               mode: .model(id: "no-such-model", targetHeight: 720)))
        // Through the export engine: a clean error, no crash, no file.
        try TestHardware.requireHardwareHEVC()
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        guard let missing = UpscaleModelSpec.all().first(where: { !$0.isInstalled }) else { throw XCTSkip("every Real-ESRGAN model is installed") }
        do {
            _ = try await export(m, preset: m.preset(.natural), target: .sdr, name: "esrgan.mov") { $0.upscale = .model(id: missing.id, targetHeight: 720) }
            XCTFail("export with a missing upscaling model should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't installed"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.work.appendingPathComponent("esrgan.mov").path))
    }

    func testMissingAV2EncoderIsReportedCleanly() async throws {
        guard !ToolLocator.isAvailable("avmenc") else { throw XCTSkip("avmenc is installed here") }
        XCTAssertFalse(Codec.av2.available)
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        var job = ExportJob(descriptor: m.d, preset: m.preset(.natural), analysis: m.analysis, delivery: .hdr10, codec: .av2,
                            outputURL: Self.work.appendingPathComponent("av2.obu"))
        let problem = try XCTUnwrap(ExportEngine.validate(job))
        XCTAssertTrue(problem.contains("avm") && problem.contains("isn't installed"), problem)
        job.bitDepth = 10
        do { _ = try await ExportEngine().run(job) { _, _ in }; XCTFail("AV2 export without avmenc should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("isn't installed"), error.localizedDescription) }
    }

    // MARK: - LUT export

    struct Cube { var size: Int; var title: String; var values: [SIMD3<Float>]; var domainMin: [Float]; var domainMax: [Float] }

    static func parseCube(_ url: URL) throws -> Cube {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0, title = "", values: [SIMD3<Float>] = [], dmin: [Float] = [], dmax: [Float] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("TITLE") { title = String(line.dropFirst(6)); continue }
            if line.hasPrefix("LUT_3D_SIZE") { size = Int(line.split(separator: " ")[1]) ?? 0; continue }
            if line.hasPrefix("DOMAIN_MIN") { dmin = line.split(separator: " ").dropFirst().compactMap { Float($0) }; continue }
            if line.hasPrefix("DOMAIN_MAX") { dmax = line.split(separator: " ").dropFirst().compactMap { Float($0) }; continue }
            let f = line.split(separator: " ").compactMap { Float($0) }
            if f.count == 3 { values.append(SIMD3(f[0], f[1], f[2])) } else { throw NSError(domain: "cube", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad line: \(line)"]) }
        }
        return Cube(size: size, title: title, values: values, domainMin: dmin, domainMax: dmax)
    }

    /// Exports a LUT, validates it, applies it with FFmpeg's lut3d to the exact frame Lumora graded, and compares.
    private func lutCheck(_ m: Media, look: Look, target: OutputTarget, size: Int, minPSNR: Double) async throws {
        var preset = m.preset(look)
        let url = Self.work.appendingPathComponent("lut-\(look.rawValue)-\(target.kind.rawValue)-\(size).cube")
        try LUTExporter.export(preset: preset, target: target, size: size, to: url)
        let cube = try Self.parseCube(url)
        XCTAssertEqual(cube.size, size)
        XCTAssertEqual(cube.values.count, size * size * size, "one entry per lattice point")
        XCTAssertEqual(cube.domainMin, [0, 0, 0]); XCTAssertEqual(cube.domainMax, [1, 1, 1])
        XCTAssertTrue(cube.title.contains(look.displayName) && cube.title.contains(target.displayName), cube.title)
        XCTAssertFalse(cube.values.contains { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) })
        XCTAssertFalse(cube.values.contains { simd_reduce_min($0) < 0 || simd_reduce_max($0) > 1.0001 }, "LUT values outside 0…1")
        // Neutral axis is neutral and monotonic.
        var last: Float = -1
        for i in 0..<size {
            let v = cube.values[i + i * size + i * size * size]
            XCTAssertEqual(v.x, v.y, accuracy: 0.01); XCTAssertEqual(v.y, v.z, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(v.y, last - 1e-4, "gray axis must be monotonic"); last = v.y
        }

        // The same frame through Lumora and through FFmpeg + the LUT. The LUT holds the global grade only
        // (no local-contrast punch, no deband), so Lumora renders with those off.
        let src = try await Self.frame(m, index: 6)
        let w = src.width, h = src.height
        let raw = Self.pixels(src)
        var q16 = [UInt16](repeating: 0, count: w * h * 3), quantized = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<3 {
            let v = UInt16((max(0, min(1, raw[i * 4 + c])) * 65535).rounded())
            q16[i * 3 + c] = v; quantized[i * 4 + c] = Float(v) / 65535
        } }
        preset.params.localContrast = 0; preset.params.deband = 0
        let sorted = preset.sceneExposures.sorted()
        let u = Self.uniforms(m.color, preset.params, target, w: w, h: h, exposure: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
        let lumora = Self.grade(Self.texture(quantized, w, h), u)
        let inRaw = Self.work.appendingPathComponent("lut-in-\(size).rgb48")
        try q16.withUnsafeBytes { try Data($0).write(to: inRaw) }
        let r = try Self.ffmpeg(["-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "\(w)x\(h)", "-i", inRaw.path,
                                 "-vf", "lut3d=file='\(url.path)':interp=tetrahedral", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-"])
        let viaLUT: [Float] = r.out.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { Float($0) / 65535 } }
        XCTAssertEqual(viaLUT.count, w * h * 3, "FFmpeg lut3d output size")
        guard viaLUT.count == w * h * 3 else { return }
        var a: [Float] = [], b: [Float] = []
        a.reserveCapacity(w * h * 3); b.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { a.append(lumora[i * 4 + c]); b.append(viaLUT[i * 3 + c]) } }
        let p = Self.psnr(a, b)
        let mad = zip(a, b).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(a.count)
        print(String(format: "LUT %@ %@ %d: PSNR %.2f dB, mean |Δ| %.5f", look.rawValue, target.displayName, size, p, mad))
        XCTAssertGreaterThan(p, minPSNR, "FFmpeg + \(size)-point LUT vs Lumora's render (\(look.rawValue) → \(target.displayName))")
        XCTAssertLessThan(mad, 0.006)
        try? FileManager.default.removeItem(at: inRaw)
    }

    func testLUTExportMatchesLumoraRenderSDRToHDR() async throws {
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        try await lutCheck(m, look: .natural, target: .hdr10_1000, size: 33, minPSNR: 38)
        try await lutCheck(m, look: .natural, target: .hdr10_1000, size: 65, minPSNR: 42)
    }

    func testLUTExportMatchesLumoraRenderHDRToSDR() async throws {
        let m = try await Self.media("grade-hdr10.mp4", hdr: true)
        try await lutCheck(m, look: .cinematic, target: .sdr, size: 33, minPSNR: 36)
        try await lutCheck(m, look: .cinematic, target: .sdr, size: 65, minPSNR: 40)
    }

    func testOriginalLookSDRLUTIsIdentity() async throws {
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        let url = Self.work.appendingPathComponent("identity.cube")
        try LUTExporter.export(preset: m.preset(.original), target: .sdr, size: 33, to: url)
        let cube = try Self.parseCube(url)
        var worst: Float = 0
        for b in 0..<33 { for g in 0..<33 { for r in 0..<33 {
            let v = cube.values[r + g * 33 + b * 33 * 33], e = SIMD3<Float>(Float(r), Float(g), Float(b)) / 32
            worst = max(worst, simd_reduce_max(abs(v - e)))
        } } }
        XCTAssertLessThan(worst, 0.002, "Keep original look, SDR → SDR, must bake an identity LUT (worst error \(worst))")
    }

    // MARK: - HDR stills

    func testHDRStillsExportValidHEICAVIFAndJPEG() async throws {
        let m = try await Self.media("grade-hdr10.mp4", hdr: true)
        let frame = try await Self.frame(m, index: 6)
        for target in [OutputTarget.hdr10_1000, .hlg] {
            let base = Self.work.appendingPathComponent("still-\(target.kind.rawValue)")
            let files = try StillExporter.export(frame: frame, preset: m.preset(.natural), params: m.preset(.natural).params,
                                                 sceneExposure: 0, crop: UniformBuilder.fullFrame, target: target, to: base)
            XCTAssertNotNil(StillExporter.avifEncoder, "this FFmpeg has an AV1 encoder, so an AVIF must be written")
            XCTAssertEqual(Set(files.map(\.pathExtension)), ["heic", "avif", "jpg"])
            // HEIC: 10-bit, HDR color space, right size, real picture.
            let heic = try XCTUnwrap(files.first { $0.pathExtension == "heic" })
            let isrc = try XCTUnwrap(CGImageSourceCreateWithURL(heic as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [CFString: Any])
            XCTAssertEqual(props[kCGImagePropertyDepth] as? Int, 10, "HEIC should be 10-bit")
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 640)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 360)
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(isrc, 0, nil))
            let cs = try XCTUnwrap(img.colorSpace, "HEIC has no color space")
            XCTAssertTrue(target.kind == .hlg ? CGColorSpaceIsHLGBased(cs) : CGColorSpaceIsPQBased(cs),
                          "HEIC color space should be \(target.kind == .hlg ? "HLG" : "PQ"): \(cs)")
            XCTAssertTrue(CGColorSpaceUsesITUR_2100TF(cs))
            // AVIF: AV1 still, 10-bit 4:4:4, BT.2020 primaries, PQ / HLG transfer.
            let avif = try XCTUnwrap(files.first { $0.pathExtension == "avif" })
            let info = try Self.streamInfo(avif)
            XCTAssertEqual(info.codec, "av1")
            XCTAssertEqual(info.pixFmt, StillExporter.avifEncoder == "libaom-av1" ? "yuv444p10le" : "yuv420p10le", "10-bit AVIF")
            XCTAssertEqual(info.primaries, "bt2020")
            XCTAssertEqual(info.transfer, target.kind == .hlg ? "arib-std-b67" : "smpte2084")
            XCTAssertEqual(info.width, 640); XCTAssertEqual(info.height, 360)
            // The AVIF carries the same picture as the HEIC: decode both to the HDR signal and compare.
            let fromAVIF = try Self.rgbFrame(avif, wide: true, index: 0)
            let direct = Self.grade(frame, Self.uniforms(m.color, m.preset(.natural).params, target, w: 640, h: 360))
            var se = 0.0, n = 0, worstPatch = 0.0
            for i in stride(from: 0, to: 640 * 360, by: 7) { for c in 0..<3 {
                let d = Double(fromAVIF[i * 3 + c] - direct[i * 4 + c]); se += d * d; n += 1
            } }
            // Color accuracy per 16x16 block (catches a wrong RGB→Y'CbCr matrix; immune to 4:2:0 edge blur).
            for by in 0..<(288 / 16) { for bx in 0..<(640 / 16) {
                var d = SIMD3<Double>(repeating: 0)
                for y in (by * 16)..<(by * 16 + 16) { for x in (bx * 16)..<(bx * 16 + 16) {
                    let i = y * 640 + x
                    for c in 0..<3 { d[c] += Double(fromAVIF[i * 3 + c] - direct[i * 4 + c]) / 256 }
                } }
                worstPatch = max(worstPatch, abs(d).max())
            } }
            let p = 10 * log10(1 / max(1e-12, se / Double(n)))
            XCTAssertGreaterThan(p, 30, "AVIF signal vs Lumora's render (PSNR \(p))")
            XCTAssertLessThan(worstPatch, 0.04, "AVIF colors drift from the render (worst 16x16 block error \(worstPatch))")
            // The Y'CbCr really is BT.2020 (as tagged): decoding with another matrix fits the render clearly worse.
            func err(_ px: [Float]) -> Double {
                var e = 0.0
                for i in stride(from: 0, to: 640 * 288, by: 3) { for c in 0..<3 { e += Double(abs(px[i * 3 + c] - direct[i * 4 + c])) } }
                return e
            }
            let e2020 = err(fromAVIF), e709 = err(try Self.rgbFrame(avif, wide: true, index: 0, matrix: "bt709")),
                e601 = err(try Self.rgbFrame(avif, wide: true, index: 0, matrix: "bt601"))
            XCTAssertLessThan(e2020, min(e709, e601) * 0.7, "AVIF matrix: error with bt2020 \(e2020), bt709 \(e709), bt601 \(e601)")
            // SDR JPEG for everything else.
            let jpg = try XCTUnwrap(files.first { $0.pathExtension == "jpg" })
            let jsrc = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
            let jimg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jsrc, 0, nil))
            XCTAssertEqual(jimg.width, 640); XCTAssertEqual(jimg.bitsPerComponent, 8)
            let jprops = CGImageSourceCopyPropertiesAtIndex(jsrc, 0, nil) as? [CFString: Any]
            XCTAssertNotNil(jprops?[kCGImagePropertyProfileName], "JPEG should carry a color profile")
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - Presets

    func testPresetSaveAndImportRoundTrip() throws {
        let color = SourceColor(name: "HDR10 (PQ)", transfer: .pq, gamut: .rec2020, legalToFull: false, confidence: 1)
        var params = Look.moody.params
        params.exposureStops = 0.4; params.temperature = -0.3; params.deband = 0.25; params.matchCurve = [0.1, 0.2, 0.3]
        let preset = PresetCandidate(name: "My Moody", look: .moody, color: color, params: params, sceneExposures: [0.5, -0.2], reason: "x")
        let url = Self.work.appendingPathComponent("my.lumorapreset")
        try PresetFile.save(preset, params: params, to: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "lumora-preset"); XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["look"] as? String, "moody"); XCTAssertEqual(json["madeFor"] as? String, "HDR10 (PQ)")
        let back = try PresetFile.load(url)
        XCTAssertEqual(back.name, "My Moody"); XCTAssertEqual(back.look, .moody); XCTAssertEqual(back.madeFor, "HDR10 (PQ)")
        var expected = params; expected.matchCurve = nil
        XCTAssertEqual(back.params, expected, "every control survives the round trip; the film-specific match curve doesn't")
        XCTAssertEqual(PresetFile.type.preferredFilenameExtension, "lumorapreset")
        // Not a preset: refused with a clear message, not silently loaded.
        let other = Self.work.appendingPathComponent("other.lumorapreset")
        var foreign = back; foreign.format = "something-else"
        try JSONEncoder().encode(foreign).write(to: other)
        XCTAssertThrowsError(try PresetFile.load(other)) { XCTAssertEqual($0.localizedDescription, "Not a Lumora preset.") }
        try Data("not json".utf8).write(to: other)
        XCTAssertThrowsError(try PresetFile.load(other))
    }

    // MARK: - Reference match

    func testReferenceMatchFollowsABrighterReleaseAndClears() async throws {
        try TestHardware.requireGPU()
        // Our source and an "official" release of the same picture mastered brighter (white at PQ 0.82 vs 0.70).
        // Mandelbrot zoom: every frame differs, so the time alignment has something real to lock onto.
        // The pattern scrolls 1.5% of the width per frame, so every frame differs and alignment has something to lock onto.
        let moving = "testsrc2=s=320x144:r=24,scroll=horizontal=0.015,null"
        let srcURL = try Self.makeSource("match-src.mp4", hdr: true, frames: 48, size: (320, 180), whitePQ: 0.70, pattern: moving)
        let refURL = try Self.makeSource("match-ref.mp4", hdr: true, frames: 48, size: (320, 180), whitePQ: 0.82, pattern: moving)
        let (d, colors) = try await SourceInspector.inspect(srcURL)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)
        let preset = try XCTUnwrap(presets.first { $0.look == .natural })
        let (curve, report) = try await ReferenceMatcher.match(source: d, color: colors[0], preset: preset, analysis: a,
                                                               target: .hdr10_1000, reference: refURL) { _ in }
        XCTAssertEqual(curve.count, ReferenceMatcher.gridCount)
        XCTAssertFalse(curve.contains { !$0.isFinite })
        XCTAssertEqual(report.offsetSeconds, 0, accuracy: 0.05, "same timing → no offset")
        let lo = Float(MATCH_LOG_MIN), hi = Float(MATCH_LOG_MAX)
        var lastY = -Float.infinity
        for (i, c) in curve.enumerated() {
            let x = lo + (hi - lo) * Float(i) / Float(curve.count - 1)
            XCTAssertGreaterThanOrEqual(x + c, lastY - 1e-4, "correction must keep the mapping monotonic (point \(i))"); lastY = x + c
            XCTAssertLessThanOrEqual(abs(c), 3)
        }
        let mids = try XCTUnwrap(report.bands.first { $0.name.hasPrefix("Mid") })
        let brights = try XCTUnwrap(report.bands.first { $0.name.hasPrefix("Bright") })
        print("MATCH \(report.summary) bands: \(report.bands.map { "\($0.name) \($0.beforeStops)→\($0.afterStops)" })")
        XCTAssertLessThan(abs(mids.afterStops), max(0.15, abs(mids.beforeStops) * 0.5), "mid-tones should be matched")
        XCTAssertLessThan(abs(brights.afterStops), max(0.15, abs(brights.beforeStops) * 0.5), "bright tones should be matched")
        XCTAssertGreaterThan(report.referenceHighlightNits, report.oursHighlightNits * 0.5)

        // The curve really moves the render toward the reference, measured the way the matcher measures:
        // our graded light vs the reference decoded straight to nits (log2-nits histograms).
        let r = GradeRenderer()
        let ours = try await Self.frame(Media(url: srcURL, d: d, colors: colors, analysis: a, report: nil, presets: []), index: 24)
        let (rd, rc) = try await SourceInspector.inspect(refURL)
        let theirs = try await Self.frame(Media(url: refURL, d: rd, colors: rc, analysis: a, report: nil, presets: []), index: 24)
        func logMean(_ h: [UInt32]) -> Double {
            let n = h.reduce(0.0) { $0 + Double($1) }
            return h.enumerated().reduce(0.0) { $0 + Double($1.element) * (Double(lo) + Double(hi - lo) * Double($1.offset) / Double(h.count - 1)) } / max(1, n)
        }
        var matched = preset.params; matched.matchCurve = curve
        let refLog = logMean(r.nitsHistogram(theirs, uniforms: Self.uniforms(rc[0], .neutral, .hdr10_1000, w: 0, h: 0), graded: false))
        let beforeLog = logMean(r.nitsHistogram(ours, uniforms: Self.uniforms(colors[0], preset.params, .hdr10_1000, w: 0, h: 0), graded: true))
        let afterLog = logMean(r.nitsHistogram(ours, uniforms: Self.uniforms(colors[0], matched, .hdr10_1000, w: 0, h: 0), graded: true))
        print(String(format: "MATCH log2-nits mean: reference %.3f, ours %.3f → matched %.3f", refLog, beforeLog, afterLog))
        XCTAssertLessThan(abs(afterLog - refLog), max(0.15, abs(beforeLog - refLog) * 0.5),
                          "matched render should land on the reference's brightness")

        // Clearing through the app model removes the curve from the live params and the selected preset.
        let model = AppModel()
        var p = preset; p.params = matched
        model.presets = [p]
        model.selectedPresetID = p.id
        model.matchReport = report
        XCTAssertNotNil(model.params.matchCurve)
        model.clearMatch()
        XCTAssertNil(model.params.matchCurve); XCTAssertNil(model.matchReport)
        XCTAssertNil(model.presets[0].params.matchCurve)

        // A release that starts 6 frames (0.25 s) later in the action is found at the right offset.
        let late = try Self.makeSource("match-late.mp4", hdr: true, frames: 48, size: (320, 180), whitePQ: 0.82,
                                       pattern: "testsrc2=s=320x144:r=24,scroll=horizontal=0.015,trim=start_frame=6")
        let (_, lateReport) = try await ReferenceMatcher.match(source: d, color: colors[0], preset: preset, analysis: a,
                                                                target: .hdr10_1000, reference: late) { _ in }
        XCTAssertEqual(lateReport.offsetSeconds, -0.25, accuracy: 0.05, "reference 6 frames ahead → offset -0.25 s")

        // An SDR "reference" is refused with a plain explanation.
        let sdr = try Self.makeSource("match-sdr.mp4", hdr: false, frames: 24, size: (320, 180))
        do {
            _ = try await ReferenceMatcher.match(source: d, color: colors[0], preset: preset, analysis: a, target: .hdr10_1000, reference: sdr) { _ in }
            XCTFail("an SDR reference should be refused")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HDR10"), error.localizedDescription) }
    }

    // MARK: - Grain

    static func noise(_ n: Int, sigma: Float, seed: UInt64) -> [Float] {
        var s = seed
        func uniform() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float((s >> 33) & 0xFFFFFF) / Float(0x1000000) + 1e-7 }
        return (0..<n).map { _ in sigma * sqrtf(-2 * logf(uniform())) * cosf(2 * .pi * uniform()) }
    }

    /// Mid-grey picture with soft structure, plus per-pixel (monochrome) gaussian grain.
    static func grainFrame(_ w: Int, _ h: Int, sigma: Float, seed: UInt64 = 1) -> (clean: [Float], grainy: [Float]) {
        let g = noise(w * h, sigma: sigma, seed: seed)
        var clean = [Float](repeating: 1, count: w * h * 4), grainy = clean
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let v = 0.45 + 0.05 * sinf(Float(x) / 37) * cosf(Float(y) / 23)
            for c in 0..<3 { clean[i * 4 + c] = v; grainy[i * 4 + c] = v + g[i] }
        } }
        return (clean, grainy)
    }

    func testGrainDenoiseMeasureAndRegrain() throws {
        try TestHardware.requireGPU()
        let w = 512, h = 288, sigma: Float = 0.01
        let (cleanPx, grainyPx) = Self.grainFrame(w, h, sigma: sigma)
        let grainy = Self.texture(grainyPx, w, h)
        let gp = GrainProcessor()
        let denoised = Self.sharedTexture(w, h)
        var cb = Self.ctx.queue.makeCommandBuffer()!
        gp.denoise(cb, grainy, into: denoised, sigma: sigma)
        cb.commit(); cb.waitUntilCompleted()
        let clean = Self.luma(cleanPx), noisy = Self.luma(grainyPx), den = Self.luma(Self.pixels(denoised))
        let errBefore = Self.std(zip(noisy, clean).map { $0 - $1 }), errAfter = Self.std(zip(den, clean).map { $0 - $1 })
        print(String(format: "GRAIN denoise residual %.5f → %.5f", errBefore, errAfter))
        XCTAssertLessThan(errAfter, errBefore * 0.6, "denoise should remove most of the grain")
        XCTAssertEqual(Self.mean(den), Self.mean(clean), accuracy: 0.002, "denoise keeps brightness")

        let stats = gp.measure(grainy)
        print("GRAIN measured overall \(stats.overall) bins \(stats.sigmaPerBin.map { String(format: "%.4f", $0) })")
        XCTAssertEqual(stats.sigmaPerBin.count, Int(GRAIN_BINS))
        XCTAssertEqual(stats.overall, sigma, accuracy: sigma * 0.5, "measured grain σ vs the σ we added")
        XCTAssertEqual(stats.sigmaPerBin[14], sigma, accuracy: sigma * 0.5, "the mid-grey band holds the measured grain")
        XCTAssertFalse(stats.sigmaPerBin.contains { $0 <= 0 }, "empty bands are filled from neighbors")
        let flat = gp.measure(Self.texture(cleanPx, w, h))
        XCTAssertLessThan(flat.overall, sigma * 0.2, "a grain-free picture measures (almost) no grain")

        // Re-grain a clean in-between frame with the grain of its neighbor.
        let out = Self.sharedTexture(w, h)
        cb = Self.ctx.queue.makeCommandBuffer()!
        gp.regrain(cb, cleanMid: Self.texture(cleanPx, w, h), origNear: grainy, cleanNear: denoised, into: out, seed: 3)
        cb.commit(); cb.waitUntilCompleted()
        let re = Self.luma(Self.pixels(out))
        let added = Self.std(zip(re, clean).map { $0 - $1 })
        print(String(format: "GRAIN regrain added σ %.5f", added))
        XCTAssertGreaterThan(added, Double(sigma) * 0.5, "re-grained frame should carry real grain")
        XCTAssertLessThan(added, Double(sigma) * 1.5)
        XCTAssertEqual(Self.mean(re), Self.mean(clean), accuracy: 0.002)
        XCTAssertLessThan(abs(Self.correlation(zip(re, clean).map { $0 - $1 }, zip(noisy, clean).map { $0 - $1 })), 0.2,
                          "grain is taken from a shifted position, not copied in place")
    }

    static func parseGrainTable(_ url: URL) throws -> (seed: Int, scalingShift: Int, points: [(Int, Int)]) {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.first, "filmgrn1")
        let e = lines.first { $0.hasPrefix("E ") }?.split(separator: " ").compactMap { Int($0) } ?? []
        XCTAssertEqual(e.count, 5, "E <start> <end> <apply> <seed> <update>")
        let p = lines.first { $0.hasPrefix("p ") }?.split(separator: " ").compactMap { Int($0) } ?? []
        XCTAssertEqual(p.count, 12, "p line has 12 parameters")
        XCTAssertEqual(p.first, 0, "ar_coeff_lag 0"); XCTAssertTrue((6...9).contains(p[1])); XCTAssertTrue((8...11).contains(p[3]))
        let s = lines.first { $0.hasPrefix("sY ") }?.split(separator: " ").dropFirst().compactMap { Int($0) } ?? []
        let n = s.first ?? -1
        XCTAssertEqual(s.count, 1 + 2 * n, "sY count matches its points")
        XCTAssertLessThanOrEqual(n, 14, "AV1 allows at most 14 luma points")
        let pts = stride(from: 1, to: s.count - 1, by: 2).map { (s[$0], s[$0 + 1]) }
        for (i, pt) in pts.enumerated() {
            XCTAssertTrue((0...255).contains(pt.0) && (0...255).contains(pt.1))
            if i > 0 { XCTAssertGreaterThan(pt.0, pts[i - 1].0, "x must increase") }
        }
        for key in ["sCb 0", "sCr 0", "cY", "cCb 0", "cCr 0"] { XCTAssertTrue(lines.contains(key), "missing \(key)") }
        return (e.count > 3 ? e[3] : 0, p.count > 3 ? p[3] : 0, pts)
    }

    func testMeasuredGrainTableIsAcceptedBySVTAV1AndGrainMatches() throws {
        try TestHardware.requireGPU()
        guard let svt = ToolLocator.url(for: "SvtAv1EncApp")?.path, let fp = EndToEndTests.ffprobe, let ff = EndToEndTests.ffmpeg else {
            throw XCTSkip("SvtAv1EncApp / FFmpeg not installed")
        }
        // Measure grain on a grainy GPU frame, then write the table exactly as the export engine does.
        let sigma: Float = 0.006
        let (_, grainyPx) = Self.grainFrame(512, 288, sigma: sigma, seed: 9)
        let stats = GrainProcessor().measure(Self.texture(grainyPx, 512, 288))
        let tbl = Self.work.appendingPathComponent("grain.tbl")
        try GrainTable.write(stats, bitDepth: 10, to: tbl)
        let parsed = try Self.parseGrainTable(tbl)
        XCTAssertEqual(parsed.seed, 7391)

        // Flat mid-grey 10-bit clip: any texture in the decoded picture is synthetic grain.
        let y4m = Self.work.appendingPathComponent("flat.y4m"), ivf = Self.work.appendingPathComponent("grain.ivf")
        try Self.ffmpeg(["-f", "lavfi", "-i", "color=c=0x737373:s=320x192:r=24:d=0.25", "-pix_fmt", "yuv420p10le", "-strict", "-1", y4m.path])
        let enc = try Self.run(svt, ["-i", y4m.path, "--preset", "12", "--crf", "20", "--fgs-table", tbl.path, "-b", ivf.path])
        XCTAssertEqual(enc.status, 0, "SvtAv1EncApp rejected the grain table: \(enc.err.suffix(600))")
        let side = try Self.run(fp, ["-v", "error", "-export_side_data", "film_grain", "-show_frames", "-read_intervals", "%+#1", ivf.path])
        let text = String(decoding: side.out, as: UTF8.self)
        XCTAssertTrue(text.contains("Film grain parameters"), "the encoded stream should carry film grain parameters")
        let tablePoints = parsed.points.map { "\($0.0)" }.joined(separator: " "), tableScaling = parsed.points.map { "\($0.1)" }.joined(separator: " ")
        XCTAssertTrue(text.contains("y_points_value=\(tablePoints)"), "stream luma points should be the table's: \(text.components(separatedBy: "\n").filter { $0.hasPrefix("y_points") })")
        XCTAssertTrue(text.contains("y_points_scaling=\(tableScaling)"), "stream luma scaling should be the table's")
        XCTAssertTrue(text.contains("seed=7391"))

        // Decode with grain synthesis and measure the grain the player actually adds (VERIFY constant in GrainTable).
        let dec = try Self.run(ff, ["-hide_banner", "-loglevel", "error", "-c:v", "libdav1d", "-i", ivf.path, "-frames:v", "1",
                                    "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"])
        let ys: [UInt16] = dec.out.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self).prefix(320 * 192)) }
        XCTAssertEqual(ys.count, 320 * 192)
        let codes = ys.map { Float($0) }
        let measuredCodes = Self.std(codes)
        // The grain table describes σ in full-range signal units; the coded luma is studio range (876 codes span).
        let mid = stats.sigmaPerBin[Int(Float(0x73 - 16) / 219 * Float(GRAIN_BINS))]
        let wanted = Double(mid) * 1023
        print(String(format: "GRAIN table: wanted σ %.2f codes, player adds %.2f codes", wanted, measuredCodes))
        XCTAssertGreaterThan(measuredCodes, wanted * 0.5, "player grain much weaker than measured grain")
        XCTAssertLessThan(measuredCodes, wanted * 1.6, "player grain much stronger than measured grain")
        for u in [y4m, ivf, tbl] { try? FileManager.default.removeItem(at: u) }
    }

    func testFilmTextureExportCarriesGrainTable() async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available, let fp = EndToEndTests.ffprobe else { throw XCTSkip("SVT-AV1 not installed") }
        let m = try await Self.media("grade-sdr.mp4", hdr: false)
        let url = try await export(m, preset: m.preset(.natural), target: .hdr10_1000, codec: .av1, name: "texture.mkv") {
            $0.filmTexture = .film35; $0.quality = 0.5
        }
        let info = try Self.streamInfo(url)
        XCTAssertEqual(info.codec, "av1"); XCTAssertEqual(info.frames, 12); XCTAssertEqual(info.transfer, "smpte2084")
        let side = try Self.run(fp, ["-v", "error", "-export_side_data", "film_grain", "-show_frames", "-read_intervals", "%+#1", url.path])
        let text = String(decoding: side.out, as: UTF8.self)
        XCTAssertTrue(text.contains("Film grain parameters"), "film texture should travel as AV1 grain parameters")
        // The table is the 35mm texture's (peaks in the mid-tones), not the encoder's own estimate.
        let want = FilmTexture.film35.stats(strength: 1)
        let tbl = Self.work.appendingPathComponent("film35.tbl")
        try GrainTable.write(want, bitDepth: 10, to: tbl)
        let scaling = try Self.parseGrainTable(tbl).points.map { "\($0.1)" }.joined(separator: " ")
        XCTAssertTrue(text.contains("y_points_scaling=\(scaling)"), "exported grain should be the film-texture table")
        XCTAssertFalse(try Self.frameStats(url).contains { $0.avg < 0.06 })
        // Without film texture there's no grain in the stream.
        let plain = try await export(m, preset: m.preset(.natural), target: .hdr10_1000, codec: .av1, name: "plain.mkv") { $0.quality = 0.5 }
        let side2 = try Self.run(fp, ["-v", "error", "-export_side_data", "film_grain", "-show_frames", "-read_intervals", "%+#1", plain.path])
        XCTAssertFalse(String(decoding: side2.out, as: UTF8.self).contains("Film grain parameters"))
        for u in [url, plain, tbl] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: - Regression set

    func testRegressionSetAddCheckAndFlagADeliberateChange() async throws {
        try TestHardware.requireGPU()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/Regression")
        let existed = FileManager.default.fileExists(atPath: folder.path)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        var mine: [String] = []
        defer {
            for f in mine { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
            if !existed, ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let m = try await Self.media("grade-hdr10.mp4", hdr: true)
        let model = AppModel()
        model.descriptor = m.d
        model.colorCandidates = m.colors
        model.selectedColor = m.color
        model.analysis = m.analysis
        model.presets = m.presets
        model.selectedPresetID = m.preset(.natural).id
        model.previewTime = 0.25
        model.previewTarget = .hdr10_1000
        try await RegressionSet.add(from: model, note: "campaign test")
        let added = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
        mine = Array(added)
        let json = try XCTUnwrap(added.first { $0.hasSuffix(".json") }, "a reference JSON should be written")
        XCTAssertTrue(added.contains(json.replacingOccurrences(of: ".json", with: ".bin")), "…with its pixels")
        let id = try XCTUnwrap(UUID(uuidString: String(json.dropLast(5))))
        let golden = try XCTUnwrap(RegressionSet.all().first { $0.id == id })
        XCTAssertEqual(golden.frame, 6); XCTAssertEqual(golden.look, .natural); XCTAssertEqual(golden.note, "campaign test")
        XCTAssertEqual(golden.target, .hdr10_1000)
        // The stored reference is a real picture, not black.
        let bin = try Data(contentsOf: folder.appendingPathComponent("\(id).bin"))
        let ref: [Float] = bin.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(ref.count, golden.width * golden.height * 4)
        let refLuma = stride(from: 0, to: ref.count, by: 4).map { ref[$0 + 1] }
        XCTAssertGreaterThan(Self.mean(refLuma), 0.1, "reference frame is black: the regression set would never see a change")
        XCTAssertGreaterThan(Self.std(refLuma), 0.05)

        // Nothing changed: passes.
        let firstAll = await RegressionSet.check(progress: ProgressReporter(task: nil))
        let first = try XCTUnwrap(firstAll.first { $0.id == id })
        XCTAssertTrue(first.ok, "unchanged render should pass (PSNR \(first.psnr))"); XCTAssertFalse(first.missing)
        XCTAssertGreaterThanOrEqual(first.psnr, 45)

        // A deliberate change to how this frame renders (+0.5 stop) must be flagged.
        var changed = golden
        changed.params.exposureStops += 0.5
        try JSONEncoder().encode(changed).write(to: folder.appendingPathComponent(json))
        let secondAll = await RegressionSet.check(progress: ProgressReporter(task: nil))
        let second = try XCTUnwrap(secondAll.first { $0.id == id })
        XCTAssertFalse(second.ok, "a visible change must be flagged (PSNR \(second.psnr))"); XCTAssertFalse(second.missing)
        XCTAssertLessThan(second.psnr, 45)

        // Source gone: reported as missing, not as a pass.
        var gone = golden
        gone.source = Self.work.appendingPathComponent("no-such-file.mp4").path
        try JSONEncoder().encode(gone).write(to: folder.appendingPathComponent(json))
        let thirdAll = await RegressionSet.check(progress: ProgressReporter(task: nil))
        let third = try XCTUnwrap(thirdAll.first { $0.id == id })
        XCTAssertTrue(third.missing); XCTAssertFalse(third.ok)
    }

    // MARK: - Scopes and the nits picker

    func testProbeReadsKnownPatchLevels() async throws {
        try TestHardware.requireGPU()
        // SDR: left half 100% white, right half 18% gray (studio-range H.264, BT.709 tags).
        let url = Self.work.appendingPathComponent("patch-sdr.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.ffmpeg(["-f", "lavfi", "-i", "color=c=white:s=320x180:r=24:d=0.5,drawbox=x=160:y=0:w=160:h=180:color=0x767676:t=fill",
                             "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p", "-c:v", "libx264", "-crf", "1",
                             "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", url.path])
        }
        let (d, colors) = try await SourceInspector.inspect(url)
        XCTAssertEqual(colors.first?.transfer, .bt1886)
        let m = Media(url: url, d: d, colors: colors, analysis: .empty, report: nil, presets: [])
        let frame = try await Self.frame(m, index: 3)
        let r = GradeRenderer()
        let original = Look.original.params
        let white = r.probe(frame, uniforms: Self.uniforms(colors[0], original, .sdr, w: 0, h: 0), at: SIMD2(0.25, 0.5))
        XCTAssertEqual(white.w, 100, accuracy: 3, "100% SDR white should read ~100 nits in SDR (read \(white))")
        XCTAssertEqual(white.x, white.z, accuracy: 1, "white is neutral")
        let gray = r.probe(frame, uniforms: Self.uniforms(colors[0], original, .sdr, w: 0, h: 0), at: SIMD2(0.75, 0.5))
        let greyNits = powf(Float(0x76) / 255, 2.4) * 100
        XCTAssertEqual(gray.w, greyNits, accuracy: greyNits * 0.06, "gray patch nits")
        let whiteHDR = r.probe(frame, uniforms: Self.uniforms(colors[0], original, .hdr10_1000, w: 0, h: 0), at: SIMD2(0.25, 0.5))
        XCTAssertEqual(whiteHDR.w, 203, accuracy: 6, "SDR white sits at BT.2408 graphics white in HDR")

        // HDR10: a patch at PQ ≈ 0.58 (≈ 203 nits) reads its own level in HDR10 with Keep original look.
        let hurl = Self.work.appendingPathComponent("patch-hdr.mp4")
        if !FileManager.default.fileExists(atPath: hurl.path) {
            try Self.ffmpeg(["-f", "lavfi", "-i", "color=c=0x949494:s=320x180:r=24:d=0.5",
                             "-vf", "scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le",
                             "-c:v", "libx265", "-x265-params", "log-level=error:crf=4:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                             "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", hurl.path])
        }
        let (hd, hc) = try await SourceInspector.inspect(hurl)
        XCTAssertEqual(hc.first?.transfer, .pq)
        let hf = try await Self.frame(Media(url: hurl, d: hd, colors: hc, analysis: .empty, report: nil, presets: []), index: 3)
        let yCode = try Self.frameStats(hurl).first.map { $0.avg } ?? -1   // the file's own code value, (Y - 64) / 876
        let expected = TransferMath.pqToNits(Float(yCode))
        let hp = r.probe(hf, uniforms: Self.uniforms(hc[0], original, .hdr10_1000, w: 0, h: 0), at: SIMD2(0.5, 0.5))
        XCTAssertEqual(hp.w, expected, accuracy: expected * 0.04, "PQ patch reads its mastered nits (\(expected))")

        // Through the app model's nits picker: the readout text carries the same number.
        let model = AppModel()
        let preset = PresetCandidate(name: "Keep", look: .original, color: colors[0], params: original, sceneExposures: [0], reason: "")
        model.descriptor = d
        model.presets = [preset]; model.selectedPresetID = preset.id
        model.previewTarget = .sdr
        model.previewFrame = DecodedFrame(texture: frame, index: 3, backing: [])
        model.probe(at: SIMD2(0.25, 0.5))
        let readout = try XCTUnwrap(model.probeReadout)
        let nits = Int(readout.split(separator: " ").first ?? "") ?? -1
        XCTAssertEqual(Double(nits), 100, accuracy: 3, "nits picker readout: \(readout)")
    }

    func testScopesOnKnownPattern() async throws {
        try TestHardware.requireGPU()
        let w = 320, h = 180
        // Left half white, right half black (encoded BT.1886 signal).
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in (w / 2)..<w { for c in 0..<3 { px[(y * w + x) * 4 + c] = 0 } } }
        let tex = Self.texture(px, w, h)
        let color = SourceColor(name: "SDR", transfer: .bt1886, gamut: .rec709, legalToFull: false, confidence: 1)
        let scopes = GradeRenderer().scopes(tex, uniforms: Self.uniforms(color, Look.original.params, .sdr, w: 0, h: 0))
        let gw = 768, gh = 768 * h / w
        XCTAssertEqual(scopes.waveform.count, Int(SCOPE_W * SCOPE_H))
        XCTAssertEqual(scopes.waveform.reduce(0) { $0 + Int($1) }, gw * gh, "every sampled pixel lands in the waveform")
        let whiteRow = Int(TransferMath.nitsToPQ(100) * Float(SCOPE_H - 1))
        var leftRows: [Int: Int] = [:], rightRows: [Int: Int] = [:]
        for row in 0..<Int(SCOPE_H) { for col in 0..<Int(SCOPE_W) {
            let n = Int(scopes.waveform[row * Int(SCOPE_W) + col]); guard n > 0 else { continue }
            if col < Int(SCOPE_W) / 2 { leftRows[row, default: 0] += n } else { rightRows[row, default: 0] += n }
        } }
        XCTAssertEqual(leftRows.max { $0.value < $1.value }?.key ?? -1, whiteRow, accuracy: 1, "white half sits at the 100-nit row (\(leftRows))")
        XCTAssertLessThanOrEqual(rightRows.max { $0.value < $1.value }?.key ?? 99, 2, "black half sits at the bottom (\(rightRows))")
        // CIE: only the white half is plotted (black has no chromaticity), at D65.
        XCTAssertEqual(scopes.cie.reduce(0) { $0 + Int($1) }, gw * gh / 2, accuracy: gw)
        let peak = scopes.cie.indices.max { scopes.cie[$0] < scopes.cie[$1] }!
        let cx = Float(peak % Int(CIE_N)) / Float(CIE_N - 1) * 0.8, cy = Float(peak / Int(CIE_N)) / Float(CIE_N - 1) * 0.9
        XCTAssertEqual(cx, 0.3127, accuracy: 0.006); XCTAssertEqual(cy, 0.3290, accuracy: 0.006)

        // Through the app model.
        let model = AppModel()
        let preset = PresetCandidate(name: "Keep", look: .original, color: color, params: Look.original.params, sceneExposures: [0], reason: "")
        model.presets = [preset]; model.selectedPresetID = preset.id
        model.previewTarget = .sdr
        model.previewFrame = DecodedFrame(texture: tex, index: 0, backing: [])
        model.showScopes = true
        let s = try XCTUnwrap(model.scopes, "showing scopes computes them")
        XCTAssertEqual(s.waveform, scopes.waveform)
    }
}
