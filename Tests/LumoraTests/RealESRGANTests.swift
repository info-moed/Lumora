import XCTest
import Metal
import CoreML
@testable import Lumora

/// Real-ESRGAN upscaling through Core ML, checked with the converted official models (skipped when none are
/// installed): the catalog matches the installed models and the converter, the Enhance tab lists them, the
/// upscaler runs inside real SDR and HDR10 exports with the exact output size, tile edges don't show, and HDR keeps
/// its precision. Footage comes from the local bench folder (Tears of Steel, its PQ version, Big Buck Bunny); tests
/// that need it skip without it.
///
/// `test9_Benchmark` (only with LUMORA_UPSCALE_BENCH=1) measures quality against the original frames (PSNR, SSIM,
/// VMAF) for bicubic, Lanczos, MetalFX and every installed model at 2x and 4x, and speed at 1080p -> 4K.
@MainActor
final class RealESRGANTests: XCTestCase {
    typealias G = CampaignGradeTests

    static let env = ProcessInfo.processInfo.environment
    static let benchRoot = URL(fileURLWithPath: env["LUMORA_BENCH_ROOT"] ?? (NSHomeDirectory() + "/Library/Caches/Lumora-Bench"),
                               isDirectory: true)
    static let tos = benchRoot.appendingPathComponent("tos/tears_of_steel_1080p.mov")
    static let tosPQ = benchRoot.appendingPathComponent("preset-clips/hdr_sky_full.y4m")
    static let bbb = benchRoot.appendingPathComponent("bbb/bbb_sunflower_2160p_60fps_normal.mp4")

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraESRGAN-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    static func installed(_ id: String) throws -> UpscaleModelSpec {
        guard let s = UpscaleModelSpec.all().first(where: { $0.id == id }), s.isInstalled else {
            throw XCTSkip("\(id) isn't installed (convert it with scripts/convert_realesrgan_coreml.py)")
        }
        return s
    }

    static func requireFile(_ u: URL) throws {
        guard FileManager.default.fileExists(atPath: u.path) else { throw XCTSkip("bench media missing: \(u.lastPathComponent)") }
    }

    /// Runs ffmpeg with at most two threads at low priority (the Mac is shared).
    @discardableResult
    static func ffmpeg(_ args: [String]) throws -> G.Run {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let r = try G.run("/usr/bin/nice", ["-n", "15", ff, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-threads", "2"] + args)
        if r.status != 0 { throw LumoraError.unsupported("ffmpeg \(args.joined(separator: " ")): \(r.err)") }
        return r
    }

    /// A short clip cut from bench footage, scaled with `filter`, as `codec` (ProRes 4444 by default, near lossless).
    static func clip(_ name: String, from src: URL, at seconds: Double, frames: Int, filter: String?, hdr: Bool = false,
                     encode: [String]? = nil) throws -> URL {
        let url = work.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try requireFile(src)
        var vf = [String]()
        if let filter { vf.append(filter) }
        let tags = hdr ? ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
                       : ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        var input = ["-ss", String(format: "%.3f", seconds), "-i", src.path]
        if src.pathExtension == "y4m" {   // y4m can't seek: skip frames with a select instead
            input = ["-i", src.path]
            vf.insert("select=gte(n\\,\(Int(seconds * 24))),setpts=PTS-STARTPTS", at: 0)
        }
        let codec = encode ?? ["-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuv444p10le"]
        try ffmpeg(input + (vf.isEmpty ? [] : ["-vf", vf.joined(separator: ",")]) + ["-r", "24", "-frames:v", "\(frames)", "-an"]
                   + codec + tags + [url.path])
        return url
    }

    /// Every frame of a file as decoded by Lumora (the encoded signal every stage sees), as shared float textures.
    static func frames(_ url: URL, count: Int, highPrecision: Bool = false) async throws -> [MTLTexture] {
        let (d, _) = try await SourceInspector.inspect(url)
        let src = try await d.makeFrameSource(highPrecision: highPrecision)
        try src.start(at: 0, count: count)
        var out: [MTLTexture] = []
        while out.count < count, let f = try src.nextFrame() { out.append(G.resample(f.texture, f.texture.width, f.texture.height)) }
        src.cancel()
        return out
    }

    // MARK: - Catalog and converter

    /// Every installed model really has the tile and scale the catalog states. (That the converter's recipes match
    /// the catalog is checked by `scripts/convert_realesrgan_coreml.py --check-catalog`; the test host doesn't read
    /// the source tree, which may sit in a protected folder.)
    func testCatalogMatchesInstalledModels() throws {
        let specs = UpscaleModelSpec.all()
        XCTAssertGreaterThanOrEqual(specs.count, 5, "x4plus, x2plus, x4plus anime, AnimeVideo v3 and general v3")
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count, "unique ids")
        var loaded = 0
        for s in specs {
            XCTAssertTrue(s.license.contains("BSD-3-Clause"), s.id)
            XCTAssertGreaterThan(s.secondsPerMegapixel ?? 0, 0, "\(s.id): measured speed for time estimates")
            XCTAssertTrue(s.notes.contains("--model"), "\(s.id): the notes say how to convert it")
            guard s.isInstalled else { continue }
            let up = try CoreMLUpscaler(spec: s)
            XCTAssertEqual(up.tile, s.tile, "\(s.id): installed model's tile")
            XCTAssertEqual(up.scale, s.scale, "\(s.id): installed model's scale")
            loaded += 1
        }
        print("ESRGAN catalog: \(specs.count) models, \(loaded) installed")
        if loaded == 0 { throw XCTSkip("no Real-ESRGAN model installed") }
    }

    /// The Enhance tab offers every catalog model, marks exactly the installed ones as available, and shows the
    /// export's current setting after the view is rebuilt.
    func testEnhanceTabListsInstalledModels() throws {
        let specs = UpscaleModelSpec.all()
        let choices = UpscaleSection.choices(specs)
        XCTAssertEqual(choices.map(\.id), ["off", "metalfx"] + specs.map(\.id))
        for s in specs {
            let c = try XCTUnwrap(choices.first { $0.id == s.id })
            XCTAssertEqual(c.available, s.isInstalled, s.id)
            XCTAssertEqual(c.label.hasSuffix("(not installed)"), !s.isInstalled, c.label)
            XCTAssertTrue(c.label.hasPrefix(s.displayName), c.label)
        }
        print("ENHANCE menu: " + choices.map { $0.label + ($0.available ? "" : " [disabled]") }.joined(separator: " | "))
        for mode in [UpscaleMode.off, .metalFX(targetHeight: 1440)] + specs.map({ UpscaleMode.model(id: $0.id, targetHeight: 2160) }) {
            let engine = UpscaleSection.engine(of: mode)
            XCTAssertTrue(choices.contains { $0.id == engine }, "\(mode) is in the menu")
            XCTAssertEqual(UpscaleSection.mode(engine: engine, height: mode.targetHeight ?? 2160), mode, "round trip")
        }
        // A compiled model on its own counts as installed (and loads).
        if let s = specs.first(where: \.isInstalled) {
            let compiledOnly = Self.work.appendingPathComponent("compiled-only", isDirectory: true)
            try FileManager.default.createDirectory(at: compiledOnly, withIntermediateDirectories: true)
            let compiled = try CoreMLUpscaler.compiledURL(s)
            var copy = s
            let up = String(repeating: "../", count: InterpolationModelSpec.modelsFolder.pathComponents.count - 1)
            copy.file = up + String(compiledOnly.path.dropFirst()) + "/" + s.file
            let dest = compiledOnly.appendingPathComponent(compiled.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: compiled, to: dest)
            XCTAssertTrue(copy.isInstalled, "a compiled model without its package is installed")
            XCTAssertNoThrow(try CoreMLUpscaler(spec: copy))
        }
    }

    // MARK: - Inside the real export

    /// Tears of Steel shrunk to 960x400 and compressed like a web or DVD-class source (H.264 CRF 30), then upscaled
    /// back to 1920x800 by the general model inside a real export: exact size, brightness kept, and closer to the
    /// original than bicubic by VMAF NEG (the benchmark measured about +5 on this kind of source).
    func testRealESRGANInSDRExport() async throws {
        try TestHardware.requireHardwareHEVC()
        let spec = try Self.installed("realesr-general-x4v3")
        let truth = try Self.clip("sdr-truth.mov", from: Self.tos, at: 62, frames: 6, filter: nil)
        let low = try Self.clip("sdr-low.mp4", from: truth, at: 0, frames: 6, filter: "scale=960:400:flags=bicubic",
                                encode: ["-c:v", "libx264", "-crf", "30", "-pix_fmt", "yuv420p"])
        let m = try await Self.media(low)
        let url = try await export(m, look: .original, delivery: .sdr, codec: .prores422HQ, name: "esrgan-sdr.mov") {
            $0.upscale = .model(id: spec.id, targetHeight: 800)
            $0.chroma = .c422; $0.bitDepth = 10
        }
        let info = try G.streamInfo(url)
        XCTAssertEqual(info.width, 1920); XCTAssertEqual(info.height, 800); XCTAssertEqual(info.frames, 6)
        XCTAssertEqual(info.transfer, "bt709")
        let stats = try G.frameStats(url)
        XCTAssertEqual(stats.count, 6)
        XCTAssertFalse(stats.contains { $0.avg < 0.02 }, "no black frames")
        let bicubic = try Self.clip("sdr-bicubic.mov", from: low, at: 0, frames: 6, filter: "scale=1920:800:flags=bicubic")
        let pModel = try G.yPSNR(truth, url), pBicubic = try G.yPSNR(truth, bicubic)
        let vModel = try Self.vmafNEG(truth, url), vBicubic = try Self.vmafNEG(truth, bicubic)
        print(String(format: "ESRGAN SDR export %@: VMAF NEG model %.2f, bicubic %.2f; Y-PSNR model %.2f dB, bicubic %.2f dB",
                     spec.id, vModel, vBicubic, pModel, pBicubic))
        XCTAssertGreaterThan(vModel, vBicubic + 1, "the model undoes compression damage bicubic can't")
        XCTAssertGreaterThan(pModel, pBicubic - 1.5, "…without drifting away from the original")
        let truthStats = try G.frameStats(truth)
        let avgModel: Double = stats.map(\.avg).reduce(0, +) / Double(stats.count)
        let avgTruth: Double = truthStats.map(\.avg).reduce(0, +) / Double(max(1, truthStats.count))
        XCTAssertEqual(avgModel, avgTruth, accuracy: 0.02, "brightness kept")
    }

    /// The PQ version of Tears of Steel (10-bit HDR10) shrunk 4x, upscaled back inside a 10-bit HDR10 export: exact
    /// size, HDR10 signaling, brightness and highlights kept, and 10-bit precision through the model.
    func testRealESRGANInHDR10Export() async throws {
        try TestHardware.requireHardwareHEVC()
        let spec = try Self.installed("realesr-general-x4v3")
        let truth = try Self.clip("hdr-truth.mov", from: Self.tosPQ, at: 1, frames: 6, filter: nil, hdr: true)
        let low = try Self.clip("hdr-low.mov", from: truth, at: 0, frames: 6, filter: "scale=480:200:flags=bicubic", hdr: true,
                                encode: ["-c:v", "libx265", "-x265-params",
                                         "log-level=error:crf=6:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                                         "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"])
        let m = try await Self.media(low)
        XCTAssertEqual(m.color.transfer, .pq)
        let url = try await export(m, look: .original, delivery: .hdr10, codec: .hevc, name: "esrgan-hdr10.mov") {
            $0.upscale = .model(id: spec.id, targetHeight: 800)
            $0.peakNits = 1000
        }
        let info = try G.streamInfo(url)
        XCTAssertEqual(info.width, 1920); XCTAssertEqual(info.height, 800); XCTAssertEqual(info.frames, 6)
        XCTAssertEqual(info.transfer, "smpte2084"); XCTAssertEqual(info.primaries, "bt2020")
        XCTAssertTrue(info.pixFmt.contains("10"), "10-bit output: \(info.pixFmt)")
        let out = try G.frameStats(url), src = try G.frameStats(truth)
        let avgOut = out.map(\.avg).reduce(0, +) / Double(out.count), avgSrc = src.map(\.avg).reduce(0, +) / Double(src.count)
        let maxOut = out.map(\.max).max() ?? 0, maxSrc = src.map(\.max).max() ?? 0
        let p = try G.yPSNR(truth, url)
        print(String(format: "ESRGAN HDR10 export %@: PQ mean %.4f vs %.4f, PQ max %.4f vs %.4f, Y-PSNR %.2f dB",
                     spec.id, avgOut, avgSrc, maxOut, maxSrc, p))
        XCTAssertEqual(avgOut, avgSrc, accuracy: 0.02, "PQ brightness kept")
        XCTAssertEqual(maxOut, maxSrc, accuracy: 0.06, "highlights kept (no clipping, no 8-bit SDR detour)")
        XCTAssertGreaterThan(p, 24)
    }

    /// The model's output keeps more than 8 bits: on a smooth 10-bit PQ gradient, the upscaled values fall between
    /// 8-bit steps as often as the 10-bit input does (an 8-bit round trip would put nearly all of them on the grid).
    func testHDRPrecisionSurvivesTheModel() async throws {
        try TestHardware.requireGPU()
        let spec = try Self.installed("realesr-general-x4v3")
        let url = Self.work.appendingPathComponent("pq-ramp.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.ffmpeg(["-f", "lavfi", "-i", "nullsrc=s=384x96:r=24:d=0.1,format=rgb48le,geq=r='0.2*65535+X*0.45*65535/(W-1)':g='0.2*65535+X*0.45*65535/(W-1)':b='0.2*65535+X*0.45*65535/(W-1)'",
                             "-frames:v", "1", "-vf", "scale=out_color_matrix=bt2020:out_range=tv", "-c:v", "prores_ks", "-profile:v", "4",
                             "-pix_fmt", "yuv444p10le", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", url.path])
        }
        let src = try await Self.frames(url, count: 1)[0]
        let stage = try PreGradeStage(sourceWidth: src.width, sourceHeight: src.height, crop: UniformBuilder.fullFrame,
                                      mode: .model(id: spec.id, targetHeight: 96 * 4))
        let (out, _) = try stage.process(src)
        XCTAssertEqual(out.pixelFormat, .rgba16Float, "half float through the model, never 8-bit")
        func offGrid(_ px: [Float], w: Int, h: Int) -> Double {
            var off = 0, n = 0
            for y in (h / 4)..<(3 * h / 4) { for x in (w / 8)..<(7 * w / 8) {
                let v = px[(y * w + x) * 4 + 1] * 255
                n += 1
                if abs(v - v.rounded()) > 0.1 { off += 1 }
            } }
            return Double(off) / Double(max(1, n))
        }
        let inOff = offGrid(G.pixels(src), w: src.width, h: src.height)
        let outOff = offGrid(G.pixels(out), w: out.width, h: out.height)
        print(String(format: "ESRGAN precision: off the 8-bit grid: input %.1f%%, model output %.1f%%", inOff * 100, outOff * 100))
        XCTAssertGreaterThan(inOff, 0.5, "the 10-bit input itself falls between 8-bit steps")
        XCTAssertGreaterThan(outOff, 0.5, "the model's output keeps the finer steps")
    }

    // MARK: - Tiles

    /// Tiles are cut with a fixed context margin. Around each tile edge, the tiled result must match a run that sees
    /// that area in the middle of a single tile (full context), for every installed model.
    func testNoVisibleTileSeams() async throws {
        try TestHardware.requireGPU()
        let specs = UpscaleModelSpec.all().filter(\.isInstalled)
        if specs.isEmpty { throw XCTSkip("no Real-ESRGAN model installed") }
        let frameURL = try Self.clip("seam-src.mov", from: Self.tos, at: 95, frames: 1, filter: "scale=1440:600:flags=bicubic")
        let src = try await Self.frames(frameURL, count: 1)[0]
        var report: [String] = []
        let overlaps = (Self.env["LUMORA_SEAM_OVERLAPS"] ?? "").split(separator: ",").compactMap { Int($0) }
        for spec in specs { for o in (overlaps.isEmpty ? [nil] : overlaps.map(Optional.some)) {
            let up = try CoreMLUpscaler(spec: spec)
            if let o { up.overlap = o }
            let s = up.scale, C = up.tile - 2 * up.overlap
            let full = G.sharedTexture(src.width * s, src.height * s)
            try up.upscale(src, into: full)
            let tiled = G.pixels(full)
            // A window centered on the first vertical tile edge, small enough to sit inside one tile's inner area.
            let half = C / 2
            let x0 = C - half, y0 = max(0, min(src.height - C, 40))
            let crop = Self.crop(src, x: x0, y: y0, w: C, h: C)
            let one = G.sharedTexture(C * s, C * s)
            try up.upscale(crop, into: one)
            let ref = G.pixels(one)
            // Compare the middle half of the window (well away from the crop's own borders): near the edge vs. not.
            func psnr(_ cols: Range<Int>) -> Double {
                var se = 0.0, n = 0
                for yy in (C / 4 * s)..<(3 * C / 4 * s) { for xx in cols {
                    let gi = ((y0 * s + yy) * full.width + x0 * s + xx) * 4, li = (yy * C * s + xx) * 4
                    for c in 0..<3 { let d = Double(tiled[gi + c] - ref[li + c]); se += d * d; n += 1 }
                } }
                return se / Double(max(1, n)) <= 1e-12 ? 99 : 10 * log10(Double(n) / se)
            }
            let edge = half * s
            let near = psnr((edge - 4 * s)..<(edge + 4 * s))
            let away = psnr((C / 4 * s)..<(C / 4 * s + 8 * s))
            report.append(String(format: "%@ (overlap %d) near edge %.1f dB, away %.1f dB", spec.id, up.overlap, near, away))
            XCTAssertGreaterThan(near, 45, "\(spec.id): the tile edge differs from a full-context run (\(near) dB)")
        } }
        print("ESRGAN seams: " + report.joined(separator: "; "))
    }

    // MARK: - Benchmark (LUMORA_UPSCALE_BENCH=1)

    /// VMAF rewards sharpening (its "enhancement gain"); VMAF NEG is the same model with that gain removed.
    struct Score: Codable { var method: String; var psnr: Double; var ssim: Double; var vmaf: Double; var vmafNEG: Double }

    /// Quality against the original frames and 1080p -> 4K speed. Results go to <bench>/upscale/results.json.
    func test9_Benchmark() async throws {
        guard Self.env["LUMORA_UPSCALE_BENCH"] == "1" else { throw XCTSkip("set LUMORA_UPSCALE_BENCH=1 to run the upscaling benchmark") }
        try TestHardware.requireGPU()
        let out = Self.benchRoot.appendingPathComponent("upscale", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let n = Int(Self.env["LUMORA_UPSCALE_FRAMES"] ?? "") ?? 4
        switch Self.env["LUMORA_UPSCALE_UNITS"] {     // which processors Core ML may use (default: all)
        case "gpu": CoreMLUpscaler.computeUnits = .cpuAndGPU
        case "ane": CoreMLUpscaler.computeUnits = .cpuAndNeuralEngine
        default: CoreMLUpscaler.computeUnits = .all
        }
        defer { CoreMLUpscaler.computeUnits = .all }
        let only = Self.env["LUMORA_UPSCALE_MODELS"].map { Set($0.split(separator: ",").map(String.init)) }
        let specs = UpscaleModelSpec.all().filter { $0.isInstalled && (only?.contains($0.id) ?? true) }
        // (name, source, start seconds, original size). Shots picked for detail: faces/robots, foliage/fur.
        var sets: [(String, URL, Double, Int, Int)] = [("tos-live-action", Self.tos, 316, 1920, 800),
                                                       ("bbb-animation", Self.bbb, 128, 3840, 2160)]
        if let s = Self.env["LUMORA_UPSCALE_SETS"] { sets = sets.filter { s.split(separator: ",").contains(Substring($0.0)) } }
        var results: [String: [Score]] = [:]
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("results.json").path),
           let d = try? Data(contentsOf: out.appendingPathComponent("results.json")),
           let old = try? JSONDecoder().decode([String: [Score]].self, from: d) { results = old }
        for (name, src, t, w, h) in sets {
            // One frame every 3 seconds, so the frames come from different shots.
            let every = name.hasPrefix("bbb") ? 180 : 72
            let truth = try Self.clip("\(name)-truth.mov", from: src, at: t, frames: n,
                                      filter: "select=not(mod(n\\,\(every))),setpts=N/24/TB" + (w == 3840 ? "" : ",scale=\(w):\(h)"))
            let truthFrames = try await Self.frames(truth, count: n)
            let truthRaw = out.appendingPathComponent("\(name)-truth.rgb48")
            try Self.writeRaw(truthFrames, to: truthRaw)
            // Clean 2x and 4x downscales, and a 2x downscale with visible H.264 compression (a web or DVD-class
            // source: the degradations Real-ESRGAN is trained to undo).
            for (f, compressed) in [(2, false), (4, false), (2, true)] {
                let key = "\(name)-\(f)x" + (compressed ? "-h264" : "")
                let low = try Self.clip("\(key)-low.mov", from: truth, at: 0, frames: n, filter: "scale=\(w / f):\(h / f):flags=bicubic",
                                        encode: compressed ? ["-c:v", "libx264", "-crf", "30", "-preset", "medium", "-pix_fmt", "yuv420p"] : nil)
                let lowFrames = try await Self.frames(low, count: n)
                var scores = results[key] ?? []
                func record(_ method: String, _ frames: [MTLTexture]) throws {
                    let raw = out.appendingPathComponent("\(key)-\(method).rgb48")
                    try Self.writeRaw(frames, to: raw)
                    let s = try Self.score(raw, truthRaw, w: w, h: h, method: method)
                    try? FileManager.default.removeItem(at: raw)
                    scores.removeAll { $0.method == method }
                    scores.append(s)
                    print(String(format: "UPBENCH %@ %@: PSNR %.2f SSIM %.4f VMAF %.2f VMAF-NEG %.2f", key, method, s.psnr, s.ssim, s.vmaf, s.vmafNEG))
                    fflush(stdout)
                }
                for filter in ["bicubic", "lanczos"] where only == nil || only!.contains(filter) {
                    let u = try Self.clip("\(key)-\(filter).mov", from: low, at: 0, frames: n, filter: "scale=\(w):\(h):flags=\(filter)")
                    try record(filter, try await Self.frames(u, count: n))
                }
                if only == nil || only!.contains("metalfx") {
                    let stage = try PreGradeStage(sourceWidth: w / f, sourceHeight: h / f, crop: UniformBuilder.fullFrame,
                                                  mode: .metalFX(targetHeight: h))
                    try record("metalfx", try lowFrames.map { G.resample(try stage.process($0).0, w, h) })
                }
                let raw = Self.env["LUMORA_UPSCALE_RAW"] == "1"     // also score without the anti-ringing clamp
                defer { CoreMLUpscaler.antiRinging = true }
                for spec in specs { for clamp in (raw ? [true, false] : [true]) {
                    CoreMLUpscaler.antiRinging = clamp
                    let stage = try PreGradeStage(sourceWidth: w / f, sourceHeight: h / f, crop: UniformBuilder.fullFrame,
                                                  mode: .model(id: spec.id, targetHeight: h))
                    try record(spec.id + (clamp ? "" : "-raw"), try lowFrames.map { G.resample(try stage.process($0).0, w, h) })
                } }
                results[key] = scores
                try Self.json.encode(results).write(to: out.appendingPathComponent("results.json"))
            }
            try? FileManager.default.removeItem(at: truthRaw)
        }
        // Speed: 1080p -> 2160p on Big Buck Bunny frames, after one warm-up frame.
        if Self.env["LUMORA_UPSCALE_SPEED"] != "0" {
            let hd = try Self.clip("speed-1080.mov", from: Self.bbb, at: 128, frames: 3, filter: "scale=1920:1080:flags=bicubic")
            let frames = try await Self.frames(hd, count: 3)
            var speed: [String: Double] = [:]
            func time(_ label: String, _ mode: UpscaleMode) throws {
                let stage = try PreGradeStage(sourceWidth: 1920, sourceHeight: 1080, crop: UniformBuilder.fullFrame, mode: mode)
                _ = try stage.process(frames[0])
                let t0 = Date()
                for f in frames.dropFirst() { _ = try stage.process(f) }
                let per = Date().timeIntervalSince(t0) / Double(frames.count - 1)
                speed[label] = per
                print(String(format: "UPSPEED %@ 1080p->2160p: %.3f s/frame (%.2f fps)", label, per, 1 / per))
                fflush(stdout)
            }
            try time("metalfx", .metalFX(targetHeight: 2160))
            for spec in specs { try time(spec.id, .model(id: spec.id, targetHeight: 2160)) }
            try Self.json.encode(speed).write(to: out.appendingPathComponent("speed.json"))
        }
    }

    // MARK: - Helpers

    static let json: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    static func media(_ url: URL) async throws -> G.Media {
        let (d, colors) = try await SourceInspector.inspect(url)
        let a = try await SceneAnalyzer.analyze(d, color: colors[0]) { _ in }
        return G.Media(url: url, d: d, colors: colors, analysis: a, report: nil, presets: [])
    }

    func export(_ m: G.Media, look: Look, delivery: DeliveryFormat, codec: Codec, name: String,
                configure: (inout ExportJob) -> Void) async throws -> URL {
        var job = ExportJob(descriptor: m.d, preset: m.preset(look), analysis: m.analysis, delivery: delivery, codec: codec,
                            outputURL: Self.work.appendingPathComponent(name))
        configure(&job)
        try? FileManager.default.removeItem(at: job.outputURL)
        return try await ExportEngine().run(job) { _, _ in }
    }

    /// VMAF NEG (VMAF without its reward for sharpening) of `url` against `ref`, both as 10-bit 4:2:0.
    static func vmafNEG(_ ref: URL, _ url: URL) throws -> Double {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let log = work.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: log) }
        let r = try G.run("/usr/bin/nice", ["-n", "15", ff, "-hide_banner", "-nostdin", "-threads", "2", "-i", url.path, "-i", ref.path,
                                            "-lavfi", "[0:v]format=yuv420p10le[d];[1:v]format=yuv420p10le[r];[d][r]libvmaf=n_threads=2:"
                                                + "model=version=vmaf_v0.6.1neg:log_fmt=json:log_path=\(log.path)", "-f", "null", "-"])
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any]
        guard let v = ((j?["pooled_metrics"] as? [String: Any])?["vmaf"] as? [String: Any])?["mean"] as? Double else {
            throw LumoraError.unsupported("no VMAF score: \(r.err.suffix(400))")
        }
        return v
    }

    static func crop(_ t: MTLTexture, x: Int, y: Int, w: Int, h: Int) -> MTLTexture {
        let px = G.pixels(t)
        var out = [Float](repeating: 0, count: w * h * 4)
        for r in 0..<h { for c in 0..<w { for k in 0..<4 { out[(r * w + c) * 4 + k] = px[((y + r) * t.width + x + c) * 4 + k] } } }
        return G.texture(out, w, h)
    }

    /// Frames as 16-bit RGB (the encoded signal, clamped to 0...1), one after another.
    static func writeRaw(_ frames: [MTLTexture], to url: URL) throws {
        var data = Data()
        for t in frames {
            let px = G.pixels(t)
            var u = [UInt16](repeating: 0, count: t.width * t.height * 3)
            for i in 0..<(t.width * t.height) {
                for c in 0..<3 { u[i * 3 + c] = UInt16((min(1, max(0, px[i * 4 + c])) * 65535).rounded()) }
            }
            u.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    /// PSNR (Y), SSIM (Y) and VMAF (v0.6.1) of `raw` against `ref`, both converted to 10-bit 4:2:0 BT.709 the same way.
    static func score(_ raw: URL, _ ref: URL, w: Int, h: Int, method: String) throws -> Score {
        let input = { (u: URL) in ["-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "\(w)x\(h)", "-r", "24", "-i", u.path] }
        let conv = "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le"
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let log = raw.deletingPathExtension().appendingPathExtension("vmaf.json")
        defer { try? FileManager.default.removeItem(at: log) }
        let graph = "[0:v]\(conv),split=3[d0][d1][d2];[1:v]\(conv),split=3[r0][r1][r2];"
            + "[d0][r0]psnr;[d1][r1]ssim;[d2][r2]libvmaf=n_threads=2:log_fmt=json:log_path=\(log.path)"
            + ":model='version=vmaf_v0.6.1\\:name=vmaf|version=vmaf_v0.6.1neg\\:name=vmaf_neg'"
        let r = try G.run("/usr/bin/nice", ["-n", "15", ff, "-hide_banner", "-nostdin", "-threads", "2"] + input(raw) + input(ref)
                          + ["-lavfi", graph, "-f", "null", "-"])
        func value(after key: String) -> Double {
            guard let range = r.err.range(of: key, options: .backwards) else { return .nan }
            let tail = r.err[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? ""
            return tail == "inf" ? 99 : Double(tail) ?? .nan
        }
        // psnr: "PSNR y:.. u:.. v:.. average:..", ssim: "SSIM Y:0.98 (..)"; VMAF from the JSON log (pooled means)
        let pooled = (try? JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])?["pooled_metrics"] as? [String: Any]
        func vmaf(_ k: String) -> Double { ((pooled?[k] as? [String: Any])?["mean"] as? Double) ?? .nan }
        return Score(method: method, psnr: value(after: "PSNR y:"), ssim: value(after: "SSIM Y:"), vmaf: vmaf("vmaf"), vmafNEG: vmaf("vmaf_neg"))
    }
}
