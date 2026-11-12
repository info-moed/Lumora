import XCTest
import SwiftUI
import AppKit
import Vision
@testable import Lumora

/// Drives `AppModel` the way the UI does (headless), with real clips, the real GPU and the real encoders, and
/// checks what comes out: frame indices, pixel statistics, ffprobe fields, files on disk. Also renders the sheets,
/// dialogs and inspector tabs offscreen and reads them back with on-device OCR.
///
/// User state is left as found: notifications and the scratch folder are overridden in this process only
/// (argument domain), preferences the model writes are restored, and files under Application Support that a flow
/// touches are restored byte for byte.
@MainActor
final class CampaignAppFlowTests: XCTestCase {

    // MARK: - Sandbox

    nonisolated static let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CampaignFlow-\(ProcessInfo.processInfo.processIdentifier)")
    nonisolated static var scratch: URL { root.appendingPathComponent("scratch") }
    nonisolated static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
    }
    nonisolated static let touchedKeys = ["simpleMode", "playsAV1", "planMode", "budgetHours", "autoStage", "dismissedUpgrades",
                                          "optimizeBannerDismissed", "runRules", "scratchRoot"]
    nonisolated(unsafe) static var savedDefaults: [String: Any] = [:]
    nonisolated(unsafe) static var savedArgs: [String: Any] = [:]
    nonisolated(unsafe) static var persistentOverride = false
    nonisolated(unsafe) static var savedFiles: [URL: Data] = [:]
    nonisolated(unsafe) static var absentFiles: Set<URL> = []
    nonisolated(unsafe) static var savedListings: [URL: Set<String>] = [:]

    nonisolated static var supportFiles: [URL] {
        ["forecast-learning.json", "queue.json", "mac-profile.json", "quality-predictor.json",
         "Models/model-hashes.json", "Models/model-choices.json"].map { support.appendingPathComponent($0) }
    }
    nonisolated static var supportDirs: [URL] {
        ["MotionMaps", "Manifests", "Calibration", "Models/Downloads"].map { support.appendingPathComponent($0) }
    }

    nonisolated override class func setUp() {
        super.setUp()
        let fm = FileManager.default
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ud = UserDefaults.standard
        for k in touchedKeys { if let v = ud.object(forKey: k) { savedDefaults[k] = v } }
        for f in supportFiles {
            if let d = try? Data(contentsOf: f) { savedFiles[f] = d } else { absentFiles.insert(f) }
        }
        for d in supportDirs { savedListings[d] = Set((try? fm.contentsOfDirectory(atPath: d.path)) ?? []) }

        // Process-local overrides: no notifications or webhooks, and all scratch work inside our temp folder.
        var rules = RunRules()
        rules.notifyMac = false
        rules.webhookURL = ""
        rules.pauseOnBattery = false
        let rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        savedArgs = ud.volatileDomain(forName: UserDefaults.argumentDomain)
        var args = savedArgs
        args["runRules"] = rulesData
        args["scratchRoot"] = scratch.path
        args["optimizeBannerDismissed"] = true      // the "optimize this Mac" banner would shift the layouts compared
        ud.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        ud.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        if RunRules.current.notifyMac || ud.string(forKey: "scratchRoot") != scratch.path {
            // Fallback: persistent values, restored in tearDown.
            persistentOverride = true
            ud.set(rulesData, forKey: "runRules")
            ud.set(scratch.path, forKey: "scratchRoot")
        }
    }

    nonisolated override class func tearDown() {
        let fm = FileManager.default
        let ud = UserDefaults.standard
        ud.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        ud.setVolatileDomain(savedArgs, forName: UserDefaults.argumentDomain)
        for k in touchedKeys {
            if let v = savedDefaults[k] { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) }
        }
        for (f, data) in savedFiles where (try? Data(contentsOf: f)) != data { try? data.write(to: f, options: .atomic) }
        for f in absentFiles where fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
        for (d, before) in savedListings {
            let now = Set((try? fm.contentsOfDirectory(atPath: d.path)) ?? [])
            for name in now.subtracting(before) where name.contains("CampaignFlow") || name.hasPrefix("RIFE_v") {
                try? fm.removeItem(at: d.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Helpers

    struct Timeout: Error, CustomStringConvertible { var description: String }

    func waitUntil(_ what: String, timeout: TimeInterval, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline {
                XCTFail("timed out after \(Int(timeout)) s waiting for \(what)")
                throw Timeout(description: what)
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    static func ffmpeg(_ args: [String]) throws {
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        try EndToEndTests.sh(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    /// Two shots (testsrc2, then SMPTE HD bars) with a hard cut, 24 fps, with a sine audio track. 720p, because
    /// SD-sized sources (≤ 576 lines) get an interlace check that this synthetic pattern trips.
    static func clip(_ name: String, width: Int = 1280, height: Int = 720, shotSeconds: Int = 1, letterbox: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("CampaignFlow-\(name).mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let ih = letterbox ? (height * 3 / 4) / 8 * 8 : height
        var g = "testsrc2=s=\(width)x\(ih):r=24:d=\(shotSeconds)[a];smptehdbars=s=\(width)x\(ih):r=24:d=\(shotSeconds)[b];[a][b]concat=n=2:v=1"
        if letterbox { g += ",pad=\(width):\(height):0:\((height - ih) / 2):black" }
        g += ",format=yuv420p[v]"
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(2 * shotSeconds)",
                    "-filter_complex", g, "-map", "[v]", "-map", "0:a",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                    "-c:a", "aac", "-b:a", "96k", url.path])
        return url
    }

    /// The shared HDR10 test clip, copied under this class's file-name prefix (so anything keyed by the file name,
    /// such as motion maps, is recognised and removed in tearDown).
    static func hdrClip() throws -> URL {
        let url = root.appendingPathComponent("CampaignFlow-hdr10.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try EndToEndTests.makeClip("hdr10.mp4", hdr: true), to: url)
        }
        return url
    }

    func opened(_ url: URL, timeout: TimeInterval = 120) async throws -> AppModel {
        try TestHardware.requireGPU()
        let m = AppModel()
        m.open(url)
        try await waitUntil("presets for \(url.lastPathComponent) (status: \(m.status))", timeout: timeout) {
            (!m.presets.isEmpty && m.status.contains("presets ready")) || m.errorMessage != nil
        }
        XCTAssertNil(m.errorMessage, "opening \(url.lastPathComponent)")
        return m
    }

    /// Waits for a re-analysis started by the model (`setRemoveBlackBars`, `setScanFix`, `chooseColor`).
    func waitForReanalysis(_ m: AppModel, _ what: String, timeout: TimeInterval = 120) async throws {
        try await waitUntil("\(what) (status: \(m.status))", timeout: timeout) {
            m.status.contains("presets ready") || m.errorMessage != nil
        }
        XCTAssertNil(m.errorMessage, what)
    }

    struct Stats { var mean: Double; var std: Double; var width: Int; var height: Int }

    /// Luma statistics of an image (0...1), drawn into an sRGB 8-bit buffer.
    static func stats(_ img: CGImage, rect: CGRect? = nil) -> Stats {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let r = rect.map { CGRect(x: max(0, $0.minX), y: max(0, $0.minY), width: min(CGFloat(w) - $0.minX, $0.width),
                                  height: min(CGFloat(h) - $0.minY, $0.height)) } ?? CGRect(x: 0, y: 0, width: w, height: h)
        var sum = 0.0, sum2 = 0.0, n = 0.0
        // CGContext memory is top-row first.
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let i = (y * w + x) * 4
                let l = (0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])) / 255
                sum += l; sum2 += l * l; n += 1
            }
        }
        let mean = sum / max(1, n)
        return Stats(mean: mean, std: sqrt(max(0, sum2 / max(1, n) - mean * mean)), width: w, height: h)
    }

    static func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let pa = pixels(a), pb = pixels(b)
        var d = 0.0
        for i in 0..<pa.count { d += abs(Double(pa[i]) - Double(pb[i])) }
        return d / Double(pa.count) / 255
    }

    /// On-device text recognition, for checking that a rendered view shows what it should.
    static func ocr(_ img: CGImage) throws -> [(text: String, box: CGRect)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { ($0.string, o.boundingBox) }     // normalized, origin bottom-left
        }
    }

    static func ocrText(_ img: CGImage) throws -> String { try ocr(img).map(\.text).joined(separator: "\n") }

    func assertShows(_ img: CGImage, _ needles: [String], _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try Self.ocrText(img).lowercased()
        for n in needles {
            XCTAssertTrue(text.contains(n.lowercased()), "\(name) should show “\(n)”; OCR read:\n\(text)", file: file, line: line)
        }
    }

    func assertNotBlank(_ img: CGImage, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let s = Self.stats(img)
        XCTAssertGreaterThan(s.std, 0.03, "\(name) looks blank (luma mean \(s.mean), std \(s.std))", file: file, line: line)
    }

    static var shotsDir: URL {
        let d = root.appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Same as UISmokeTests.render: hosts the view in an offscreen window (never ordered front) and snapshots it.
    @discardableResult
    func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 1440, height: 900)) async throws -> CGImage {
        try TestHardware.requireGPU()
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: Self.shotsDir.appendingPathComponent("\(name).png"))
        }
        return try XCTUnwrap(rep.cgImage)
    }

    func dressed<V: View>(_ v: V, _ m: AppModel) -> some View {
        v.environment(m)
            .environment(EncodeMonitor.shared)
            .environment(TaskCenter.shared)
            .preferredColorScheme(.dark)
            .tint(Theme.signal)
            .background(Theme.surround)
    }

    func job(_ m: AppModel) throws -> ExportJob {
        var j = try XCTUnwrap(m.draftJob(), "draft job")
        j.delivery = m.delivery; j.codec = m.codec; j.bitDepth = m.bitDepth; j.chroma = m.chroma
        j.outputURL = Self.root.appendingPathComponent("out-check.\(m.codec.defaultContainer)")
        return j
    }

    static func videoFiles(in folder: URL) -> [URL] {
        let exts: Set<String> = ["mov", "mp4", "mkv", "obu", "ivf", "266", "hevc"]
        return (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
    }

    static func allFiles(in folder: URL) -> [URL] {
        (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    static func frameRate(_ url: URL) throws -> Double {
        guard let fp = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let s = try EndToEndTests.sh(fp, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate",
                                          "-of", "default=nw=1:nk=1", url.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : (parts.first ?? 0)
    }

    static func scratchLeftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter { $0 != "Proxies" && !$0.hasPrefix(".") }
    }

    // MARK: - Open, presets, params

    func testOpenBuildsDescriptorAnalysisPresetsAndThumbnails() async throws {
        XCTAssertFalse(RunRules.current.notifyMac, "notifications must be off for this process")
        XCTAssertEqual(ScratchManager.shared.root.path, Self.scratch.path)
        let m = try await opened(try Self.clip("sdr"))
        let d = try XCTUnwrap(m.descriptor)
        XCTAssertEqual(d.width, 1280); XCTAssertEqual(d.height, 720)
        XCTAssertEqual(d.frameCount, 48); XCTAssertEqual(d.fps, 24, accuracy: 0.001)
        XCTAssertEqual(d.kind, .avfoundation); XCTAssertEqual(d.scanFix, .none)
        XCTAssertEqual(d.crop, UniformBuilder.fullFrame, "no black bars in this clip")
        XCTAssertTrue(m.selectedColor?.transfer.isSDR ?? false, "read as \(m.selectedColor?.name ?? "nil")")
        let a = try XCTUnwrap(m.analysis)
        XCTAssertEqual(a.frameCount, 48)
        XCTAssertGreaterThanOrEqual(a.scenes.count, 2, "the hard cut at frame 24 should split the clip")
        XCTAssertTrue(a.cutFrames.contains(24) || a.cutFrames.contains(23) || a.cutFrames.contains(25), "cuts: \(a.cutFrames.sorted())")
        XCTAssertEqual(Set(m.presets.map(\.look)), [.original, .natural, .punchy, .superPunchy, .cinematic, .brightClean, .moody])
        let rec = m.presets.filter(\.recommended)
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(m.selectedPresetID, rec.first?.id)
        XCTAssertEqual(m.params, rec.first?.params)
        XCTAssertEqual(m.report?.verdict, .sdr)
        XCTAssertNotNil(m.contentProfile)
        XCTAssertGreaterThan(m.sourceSizes?.total ?? 0, 0)
        XCTAssertEqual(m.sourceStreams.audio.count, 1, "the sine audio track")
        XCTAssertEqual(m.previewFrame?.index, 24, "opens on the middle frame")
        XCTAssertEqual(m.previewTime, 1.0, accuracy: 0.001)

        // One 240 px thumbnail per preset, each a real picture, and the looks really differ.
        XCTAssertEqual(m.thumbnails.count, m.presets.count)
        var means: [Look: Double] = [:]
        for p in m.presets {
            let img = try XCTUnwrap(m.thumbnails[p.id], "thumbnail for \(p.name)")
            XCTAssertEqual(img.width, 240); XCTAssertEqual(img.height, 135)
            let s = Self.stats(img)
            XCTAssertGreaterThan(s.std, 0.1, "\(p.name) thumbnail is flat")
            means[p.look] = s.mean
        }
        XCTAssertLessThan(means[.moody]!, means[.brightClean]!, "Moody should be darker than Bright & Clean: \(means)")
        let nat = m.thumbnails[m.presets.first { $0.look == .natural }!.id]!
        let pun = m.thumbnails[m.presets.first { $0.look == .punchy }!.id]!
        XCTAssertGreaterThan(Self.meanAbsDiff(nat, pun), 0.005, "Natural and Punchy render identically")

        // The progress bar must clear once the work is done.
        try await waitUntil("progress to clear (\(String(describing: m.progress)))", timeout: 5) { m.progress == nil }
    }

    func testSelectEachPresetEditParamsCommitAndPreviewUniforms() async throws {
        let m = try await opened(try Self.clip("sdr"))
        let frame = try XCTUnwrap(m.previewFrame)
        let vp = SIMD4<Float>(0, 0, 1280, 720)
        var previews: [UUID: Double] = [:]
        for p in m.presets {
            m.selectedPresetID = p.id
            XCTAssertEqual(m.selectedPreset?.id, p.id)
            XCTAssertEqual(m.params, p.params, "selecting \(p.name) loads its parameters")
            let u = try XCTUnwrap(m.previewUniforms(viewport: vp))
            XCTAssertEqual(u.viewport, vp)
            XCTAssertEqual(u.sourceRect, UniformBuilder.fullFrame)
            // The preview pass itself, on the GPU, with the preview target (HDR10 1000 nits by default).
            let img = try XCTUnwrap(GradeRenderer().thumbnail(frame.texture, uniforms: u, width: 320))
            let s = Self.stats(img)
            XCTAssertGreaterThan(s.std, 0.05, "\(p.name) preview is flat")
            previews[p.id] = s.mean
        }
        XCTAssertGreaterThan(Set(previews.values.map { Int($0 * 1000) }).count, 3, "looks should preview differently: \(previews.values)")

        // Edit Natural: +1 stop, uncommitted, then committed.
        let natural = try XCTUnwrap(m.presets.first { $0.look == .natural })
        m.selectedPresetID = natural.id
        let u0 = try XCTUnwrap(m.previewUniforms(viewport: vp))
        let thumb0 = Self.stats(try XCTUnwrap(m.thumbnails[natural.id])).mean
        m.params.exposureStops += 1
        let u1 = try XCTUnwrap(m.previewUniforms(viewport: vp))
        XCTAssertEqual(u1.exposure / u0.exposure, 2, accuracy: 0.01, "+1 stop doubles the linear exposure")
        XCTAssertEqual(m.presets.first { $0.id == natural.id }?.params.exposureStops, natural.params.exposureStops, "not committed yet")
        let token = m.renderToken
        m.commitParams()
        XCTAssertEqual(m.renderToken, token + 1)
        XCTAssertEqual(m.presets.first { $0.id == natural.id }?.params.exposureStops ?? 0, natural.params.exposureStops + 1, accuracy: 1e-6)
        m.renderThumbnails()
        let thumb1 = Self.stats(try XCTUnwrap(m.thumbnails[natural.id])).mean
        XCTAssertGreaterThan(thumb1, thumb0 + 0.03, "committed exposure should brighten the thumbnail (\(thumb0) → \(thumb1))")
        // The committed edit survives switching away and back.
        m.selectedPresetID = m.presets.first { $0.look == .moody }?.id
        m.selectedPresetID = natural.id
        XCTAssertEqual(m.params.exposureStops, natural.params.exposureStops + 1, accuracy: 1e-6)

        // Viewing toggles reach the uniforms.
        m.splitCompare = true
        XCTAssertEqual(m.previewUniforms(viewport: vp)?.split, 0.5)
        m.splitCompare = false
        let t2 = m.renderToken
        m.falseColor = true
        XCTAssertEqual(m.renderToken, t2 + 1)
        XCTAssertNotEqual(m.previewUniforms(viewport: vp)?.falseColor ?? 0, 0)
        m.falseColor = false
        m.previewTarget = .sdr
        let sdr = try XCTUnwrap(m.previewUniforms(viewport: vp))
        XCTAssertNotEqual(sdr.outputTransfer, u1.outputTransfer, "preview target changes the output encoding")
    }

    func testScopesAndNitsProbeFollowThePicture() async throws {
        let src = try Self.clip("sdr")
        let m = try await opened(src)
        XCTAssertNil(m.scopes)
        m.showScopes = true
        let sc = try XCTUnwrap(m.scopes, "turning scopes on computes them")
        XCTAssertGreaterThan(sc.waveform.reduce(0) { $0 + UInt64($1) }, 0)
        XCTAssertGreaterThan(sc.cie.reduce(0) { $0 + UInt64($1) }, 0)
        XCTAssertGreaterThan(sc.waveform.filter { $0 > 0 }.count, 100, "waveform should spread over many cells")

        // Probe the colour bars of frame 24 and compare the ordering with the source pixels' luma.
        XCTAssertEqual(m.previewFrame?.index, 24)
        guard let ff = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let raw = Self.root.appendingPathComponent("frame24.rgb")
        try EndToEndTests.sh(ff, ["-hide_banner", "-loglevel", "error", "-y", "-i", src.path, "-vf", "select=eq(n\\,24)", "-frames:v", "1",
                                  "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path])
        let px = try Data(contentsOf: raw)
        XCTAssertEqual(px.count, 1280 * 720 * 3)
        var samples: [(src: Double, nits: Double)] = []
        for x in stride(from: 0.06, to: 0.95, by: 0.0625) {
            let uv = SIMD2<Float>(Float(x), 0.3)
            m.probe(at: uv)
            let readout = try XCTUnwrap(m.probeReadout)
            let nits = try XCTUnwrap(Double(readout.split(separator: " ").first ?? ""), "readout \(readout)")
            XCTAssertTrue(readout.contains("nits"), readout)
            let i = (Int(0.3 * 720) * 1280 + Int(x * 1280)) * 3
            // Relative luminance in linear light (BT.1886 display, gamma 2.4) — what a nits reading follows.
            func lin(_ v: UInt8) -> Double { pow(Double(v) / 255, 2.4) }
            let l = 0.2126 * lin(px[i]) + 0.7152 * lin(px[i + 1]) + 0.0722 * lin(px[i + 2])
            samples.append((l, nits))
        }
        XCTAssertGreaterThan(Set(samples.map { Int($0.nits) }).count, 3, "probe should read different bars: \(samples)")
        for a in samples { for b in samples where a.src > b.src * 1.5 + 0.01 {
            XCTAssertGreaterThan(a.nits, b.nits, "brighter source bar must probe brighter: \(a) vs \(b)")
        } }
    }

    // MARK: - Transport

    func show(_ m: AppModel, _ t: Double) async throws {
        let token = m.renderToken
        m.scrub(to: t)
        try await waitUntil("frame at \(t)", timeout: 10) { m.renderToken != token || m.errorMessage != nil }
        XCTAssertNil(m.errorMessage)
    }

    func testScrubAndStepFramesLikeTheTransportBar() async throws {
        let m = try await opened(try Self.clip("sdr"))
        let d = try XCTUnwrap(m.descriptor)
        try await show(m, 0)
        XCTAssertEqual(m.previewFrame?.index, 0)
        try await show(m, 0.5 + 0.4 / 24)
        XCTAssertEqual(m.previewFrame?.index, 12, "a time inside frame 12 shows frame 12")
        try await show(m, d.durationSeconds)
        XCTAssertEqual(m.previewFrame?.index, 47, "scrubbing to the end shows the last frame")

        // Right arrow from the first frame to the last: every press shows the next frame.
        try await show(m, 0)
        var forward: [Int] = []
        for _ in 1..<d.frameCount {
            try await show(m, min(d.durationSeconds, m.previewTime + 1 / d.fps))
            forward.append(m.previewFrame?.index ?? -1)
        }
        XCTAssertEqual(forward, Array(1..<d.frameCount), "stepping forward skipped or repeated frames")
        // Left arrow back to the start.
        var back: [Int] = []
        for _ in 1..<d.frameCount {
            try await show(m, max(0, m.previewTime - 1 / d.fps))
            back.append(m.previewFrame?.index ?? -1)
        }
        XCTAssertEqual(back, Array((0..<(d.frameCount - 1)).reversed()), "stepping back skipped or repeated frames")
    }

    func testTogglePlayStartsStopsRestartsAndEnds() async throws {
        let m = try await opened(try Self.clip("sdr"))
        try await show(m, 0)
        m.togglePlay()
        XCTAssertTrue(m.playing)
        try await Task.sleep(nanoseconds: 750_000_000)
        let i1 = m.previewFrame?.index ?? 0
        XCTAssertGreaterThan(i1, 6, "about 18 frames should have played in 0.75 s at 24 fps")
        XCTAssertLessThan(i1, 30, "playback should be paced to real time")
        XCTAssertEqual(m.previewTime, Double(i1) / 24, accuracy: 0.05)
        m.togglePlay()
        XCTAssertFalse(m.playing)
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopped = m.previewFrame?.index
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.previewFrame?.index, stopped, "frames keep coming after pause")

        // Pause and immediately play again: the new playback must keep running and show as playing.
        try await show(m, 0)
        m.togglePlay()
        try await Task.sleep(nanoseconds: 300_000_000)
        m.togglePlay()
        m.togglePlay()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(m.playing, "restarted playback shows as paused")
        let a = m.previewFrame?.index ?? 0
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(m.previewFrame?.index ?? 0, a, "restarted playback isn't advancing")
        m.togglePlay()
        XCTAssertFalse(m.playing)
        try await Task.sleep(nanoseconds: 300_000_000)
        let b = m.previewFrame?.index
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.previewFrame?.index, b, "a second playback loop is still running after pause")

        // Playing to the end stops by itself on the last frame.
        try await show(m, 1.5)
        m.togglePlay()
        try await waitUntil("playback to end", timeout: 5) { !m.playing }
        XCTAssertEqual(m.previewFrame?.index, 47)
    }

    // MARK: - Picture fixes and colour interpretation

    func testRemoveBlackBarsReanalysesAndThumbnailsKeepAspect() async throws {
        let m = try await opened(try Self.clip("letterbox", letterbox: true))
        XCTAssertTrue(m.removeBlackBars)
        XCTAssertNotEqual(m.detectedCrop, UniformBuilder.fullFrame, "letterbox should be detected")
        var d = try XCTUnwrap(m.descriptor)
        XCTAssertEqual(d.crop, m.detectedCrop)
        XCTAssertEqual(d.outputWidth, 1280)
        XCTAssertTrue((520...544).contains(d.outputHeight), "picture area height \(d.outputHeight), expected about 536")
        let picked = try XCTUnwrap(m.selectedPresetID)
        let cropped = try XCTUnwrap(m.thumbnails[picked])
        // Thumbnails show the picture area at its own shape, without the bars.
        XCTAssertEqual(Double(cropped.width) / Double(cropped.height), Double(d.outputWidth) / Double(d.outputHeight), accuracy: 0.05,
                       "cropped thumbnail is \(cropped.width)×\(cropped.height)")
        let topBand = Self.stats(cropped, rect: CGRect(x: 0, y: 0, width: cropped.width, height: max(2, cropped.height / 12)))
        XCTAssertGreaterThan(topBand.mean, 0.05, "black bar still visible at the top of the cropped thumbnail")
        let u = try XCTUnwrap(m.previewUniforms(viewport: .zero))
        XCTAssertEqual(u.sourceRect, m.detectedCrop)

        m.setRemoveBlackBars(false)
        d = try XCTUnwrap(m.descriptor)
        XCTAssertEqual(d.crop, UniformBuilder.fullFrame)
        XCTAssertEqual(d.outputHeight, 720)
        try await waitForReanalysis(m, "re-analysis without crop")
        XCTAssertEqual(m.analysis?.frameCount, 48)
        let full = try XCTUnwrap(m.thumbnails[try XCTUnwrap(m.selectedPresetID)])
        XCTAssertEqual(full.height, 135)
        let bar = Self.stats(full, rect: CGRect(x: 0, y: 0, width: full.width, height: 8))
        XCTAssertLessThan(bar.mean, 0.03, "full frame thumbnail should show the black bar")

        m.setRemoveBlackBars(true)
        XCTAssertEqual(m.descriptor?.crop, m.detectedCrop)
        try await waitForReanalysis(m, "re-analysis with crop")
    }

    func testScanFixChangesTimingAndReanalyses() async throws {
        let m = try await opened(try Self.clip("sdr"))
        m.setScanFix(.deinterlaceDouble)
        var d = try XCTUnwrap(m.descriptor)
        XCTAssertEqual(d.scanFix, .deinterlaceDouble)
        XCTAssertEqual(d.kind, .ffmpeg)
        XCTAssertEqual(d.fps, 48, accuracy: 0.001)
        XCTAssertEqual(d.frameCount, 96)
        try await waitForReanalysis(m, "deinterlace to double rate")
        XCTAssertEqual(m.analysis?.frameCount, 96)
        XCTAssertNotNil(m.previewFrame)
        try await show(m, 1.0)
        XCTAssertEqual(m.previewFrame?.index, 48)


        m.setScanFix(.none)
        d = try XCTUnwrap(m.descriptor)
        XCTAssertEqual(d.kind, .avfoundation)
        XCTAssertEqual(d.frameCount, 48)
        XCTAssertEqual(d.fps, 24, accuracy: 0.001)
        try await waitForReanalysis(m, "back to progressive")
        XCTAssertEqual(m.analysis?.frameCount, 48)
        // Same fix again is a no-op (no re-analysis started).
        let status = m.status
        m.setScanFix(.none)
        XCTAssertEqual(m.status, status)

        // Inverse telecine on footage that really is telecined (24p → 30i with 3:2 pulldown).
        let tc = Self.root.appendingPathComponent("CampaignFlow-telecined.mp4")
        if !FileManager.default.fileExists(atPath: tc.path) {
            try Self.ffmpeg(["-i", try Self.clip("sdr").path, "-vf", "telecine=pattern=23,format=yuv420p", "-flags", "+ilme+ildct",
                             "-c:v", "libx264", "-x264-params", "tff=1", "-an", tc.path])
        }
        let t = try await opened(tc)
        var td = try XCTUnwrap(t.descriptor)
        // Detected on open and applied straight away.
        XCTAssertEqual(td.suggestedScanFix, .inverseTelecine)
        XCTAssertEqual(td.scanFix, .inverseTelecine)
        XCTAssertEqual(td.fps, 24, accuracy: 0.01); XCTAssertEqual(td.frameCount, 48)
        XCTAssertEqual(Double(t.analysis?.frameCount ?? 0), 48, accuracy: 1, "restored film frames")
        t.setScanFix(.none)
        td = try XCTUnwrap(t.descriptor)
        XCTAssertEqual(td.fps, 30, accuracy: 0.01); XCTAssertEqual(td.frameCount, 60)
        try await waitForReanalysis(t, "telecined, as stored")
        XCTAssertEqual(t.analysis?.frameCount, 60)
        t.setScanFix(.inverseTelecine)
        td = try XCTUnwrap(t.descriptor)
        XCTAssertEqual(td.fps, 24, accuracy: 0.01); XCTAssertEqual(td.frameCount, 48)
        try await waitForReanalysis(t, "inverse telecine")
        XCTAssertEqual(Double(t.analysis?.frameCount ?? 0), 48, accuracy: 1, "restored film frames")
        XCTAssertGreaterThanOrEqual(t.analysis?.scenes.count ?? 0, 2)
        try await show(t, 1.0)
        XCTAssertEqual(t.previewFrame?.index, 24)
    }

    func testChooseColorReanalysesWithThatInterpretation() async throws {
        let m = try await opened(try Self.hdrClip())
        XCTAssertEqual(m.selectedColor?.transfer, .pq)
        let candidates = m.colorCandidates
        XCTAssertFalse(candidates.isEmpty)
        let target = candidates.count > 1 ? candidates[1] : candidates[0]
        let oldIDs = Set(m.presets.map(\.id))
        m.chooseColor(target)
        XCTAssertEqual(m.selectedColor, target)
        try await waitForReanalysis(m, "re-analysis as \(target.name)")
        XCTAssertTrue(Set(m.presets.map(\.id)).isDisjoint(with: oldIDs), "presets should be rebuilt")
        XCTAssertEqual(m.presets.first?.color, target, "presets for the chosen reading come first")
        XCTAssertEqual(m.selectedPreset?.color, target)
        XCTAssertEqual(m.previewUniforms(viewport: .zero) != nil, true)
    }

    // MARK: - Recommendations and advice

    func expectedRecommendation(goal: Goal, av1: Bool, hdr: Bool, dimHDR: Bool) -> (look: Look, delivery: DeliveryFormat, codec: Codec,
                                                                                    plan: PlanMode, profile: String, smooth: Bool) {
        let look: Look = hdr ? (dimHDR ? .ripRevive : .original) : (goal == .watchOnTV ? .natural : .original)
        let delivery: DeliveryFormat = goal == .share ? (hdr ? .dolbyVision84 : .sdr) : (hdr || goal == .watchOnTV ? .hdr10 : .sdr)
        let codec: Codec
        let plan: PlanMode
        switch goal {
        case .archive: codec = .av1; plan = .bestForMac
        case .saveSpace: codec = av1 ? .av1 : .hevc12; plan = .budget
        case .share: codec = .hevc; plan = .fastest
        case .watchOnTV, .smoother: codec = av1 ? .av1 : .hevc; plan = .bestForMac
        }
        return (look, delivery, codec, plan, goal == .share ? "Transparent streaming" : "Imperceptible", goal == .smoother)
    }

    func checkRecommendations(_ m: AppModel, hdr: Bool) async throws {
        let dim = m.report.map { $0.verdict == .conservative || $0.verdict == .fakeHDR } ?? false
        for av1 in [true, false] {
            for goal in Goal.allCases {
                m.goal = goal
                m.playsAV1 = av1
                let r = try XCTUnwrap(m.currentRecommendation())
                let e = expectedRecommendation(goal: goal, av1: av1, hdr: hdr, dimHDR: dim)
                let tag = "\(hdr ? "HDR" : "SDR") \(goal.rawValue), AV1 \(av1)"
                XCTAssertEqual(r.look, e.look, tag); XCTAssertEqual(r.delivery, e.delivery, tag); XCTAssertEqual(r.codec, e.codec, tag)
                XCTAssertEqual(r.planMode, e.plan, tag); XCTAssertEqual(r.profileName, e.profile, tag)
                XCTAssertEqual(r.budgetHours, goal == .saveSpace ? 10 : 8, tag)
                XCTAssertEqual(r.interpolation, e.smooth ? .targetFPS(num: 60, den: 1) : .off, tag)
                XCTAssertEqual(r.intelligence, e.smooth ? .perScene : .eachFrame, tag)
                XCTAssertEqual(r.removeBlackBars, false, tag)
                // Every area the panel explains is present, and the stated values match the settings.
                let areas = Set(r.items.map(\.area))
                XCTAssertTrue(areas.isSuperset(of: ["Look", "HDR", "Codec", "Quality", "Time", "Motion"]), "\(tag): \(areas)")
                XCTAssertEqual(r.items.first { $0.area == "Look" }?.value, r.look.displayName, "\(tag): the Look line must state the applied look")
                XCTAssertEqual(r.items.filter { $0.area == "Look" }.count, 1, tag)
                XCTAssertEqual(r.items.first { $0.area == "Quality" }?.value, e.profile, tag)
                XCTAssertEqual(r.items.first { $0.area == "Time" }?.value, e.plan.rawValue, tag)
                XCTAssertEqual(r.items.first { $0.area == "Motion" }?.value, e.smooth ? "Interpolate to 60 fps" : "Keep original frame rate", tag)
                if !hdr && goal == .watchOnTV { XCTAssertEqual(r.items.first { $0.area == "HDR" }?.value, "Convert to HDR10", tag) }
                XCTAssertTrue(r.headline.hasPrefix(goal.rawValue), tag)

                m.applyRecommendation()
                XCTAssertEqual(m.selectedPreset?.look, r.look, "\(tag): selected look")
                XCTAssertEqual(m.selectedPreset?.color, m.selectedColor, tag)
                XCTAssertEqual(m.params, m.selectedPreset?.params, tag)
                XCTAssertEqual(m.delivery, r.delivery, tag)
                XCTAssertEqual(m.codec, r.codec, tag)
                XCTAssertEqual(m.bitDepth, 10, tag)
                XCTAssertEqual(m.chroma, r.codec.chromaFormats[0], tag)
                XCTAssertEqual(m.qualityProfile.name, r.profileName, tag)
                XCTAssertEqual(m.useTargetQuality, ![.prores422HQ, .prores4444XQ, .av2].contains(r.codec), tag)
                XCTAssertEqual(m.planMode, r.planMode, tag)
                XCTAssertEqual(m.budgetHours, r.budgetHours, tag)
                XCTAssertEqual(m.interpolation.mode, r.interpolation, tag)
                XCTAssertEqual(m.interpolation.intelligence, r.intelligence, tag)
                XCTAssertEqual(m.interpolation.grainAware, r.grainAware, tag)
                XCTAssertEqual(m.filmTexture, r.filmTexture, tag)
                XCTAssertEqual(m.previewTarget.kind, r.delivery.target.0, tag)
                XCTAssertEqual(m.deliversHDR, r.delivery != .sdr, tag)
                XCTAssertNil(ExportEngine.validate(try job(m)), "\(tag): recommended settings can't be exported")
                if m.status == "Re-analysing" {
                    // Black-bar setting changed: the re-analysis must keep the recommended look selected.
                    try await waitForReanalysis(m, "\(tag): re-analysis")
                    XCTAssertEqual(m.selectedPreset?.look, r.look, "\(tag): re-analysis dropped the recommended look")
                    XCTAssertEqual(m.removeBlackBars, r.removeBlackBars, tag)
                }
                if !r.codec.isHardware {
                    let plan = try XCTUnwrap(m.currentPlan(), tag)
                    XCTAssertEqual(plan.choice.codec, r.codec, tag)
                }
                if goal == .smoother {
                    // The per-scene motion map is built in the background and routes every scene.
                    try await waitUntil("\(tag): motion map", timeout: 120) { m.motionMap != nil || m.errorMessage != nil }
                    XCTAssertNil(m.errorMessage, tag)
                    XCTAssertEqual(m.motionMap?.routes.count, m.analysis?.scenes.count, tag)
                }
            }
        }
    }

    func testApplyRecommendationForEveryGoalSDR() async throws {
        let m = try await opened(try Self.clip("sdr"))
        try await checkRecommendations(m, hdr: false)
    }

    func testApplyRecommendationForEveryGoalHDR() async throws {
        let m = try await opened(try Self.hdrClip())
        try await checkRecommendations(m, hdr: true)
    }

    /// A Dolby Vision 8.1 source kept as-is: the recommender switches to x265 HEVC with Dolby Vision 8.1;
    /// that combination must pass export validation and really produce a Dolby Vision file.
    func testDolbyVisionSourceRecommendationIsExportable() async throws {
        try TestHardware.requireGPU()
        guard ToolLocator.isAvailable("x265"), ToolLocator.isAvailable("dovi_tool"), ToolLocator.isAvailable("mkvmerge") else {
            throw XCTSkip("x265, dovi_tool and mkvmerge are needed")
        }
        let m = try await opened(try Self.hdrClip())
        m.descriptor?.isDolbyVision = true
        m.descriptor?.dvProfile = 8
        m.playsAV1 = false
        for goal in [Goal.watchOnTV, .saveSpace] {
            m.goal = goal
            let r = try XCTUnwrap(m.currentRecommendation())
            guard r.look == .original else { throw XCTSkip("source reads as dim HDR here; DV is regenerated, not kept") }
            XCTAssertEqual(r.delivery, .dolbyVision81, goal.rawValue)
            XCTAssertEqual(r.codec, .hevc12, goal.rawValue)
            XCTAssertTrue(r.items.contains { $0.area == "Dolby Vision" && $0.value == "Keep the original (retimed)" })
            m.applyRecommendation()
            XCTAssertEqual(m.delivery, .dolbyVision81)
            XCTAssertNil(ExportEngine.validate(try job(m)), "\(goal.rawValue): DV 8.1 in x265 HEVC rejected")
        }
        // HLG-based Dolby Vision 8.4 still needs the hardware encoder.
        XCTAssertFalse(DeliveryFormat.dolbyVision84.supported(by: .hevc12))
        XCTAssertTrue(DeliveryFormat.dolbyVision84.supported(by: .hevc))

        // Export it for real (the fake-DV source has no RPU to retime, so fresh metadata is generated).
        m.useTargetQuality = false
        m.planMode = .fastest
        m.interpolation.mode = .off
        let out = Self.root.appendingPathComponent("dv-out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        m.export(presetIDs: [try XCTUnwrap(m.selectedPresetID)], folder: out)
        try await waitUntil("DV export (status: \(m.status))", timeout: 240) {
            m.errorMessage != nil || (m.status.hasPrefix("Saved") && m.lastPackage != nil)
        }
        XCTAssertNil(m.errorMessage)
        let file = try XCTUnwrap(m.lastPackage?.video)
        XCTAssertEqual(file.pathExtension, "mkv")
        let p = try EndToEndTests.probe(file)
        XCTAssertEqual(p.codec, "hevc"); XCTAssertEqual(p.frames, 48); XCTAssertEqual(p.transfer, "smpte2084")
        let fp = try XCTUnwrap(EndToEndTests.ffprobe)
        let side = try EndToEndTests.sh(fp, ["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#2", "-show_frames",
                                             "-show_entries", "frame=side_data_list:stream_side_data_list", "-show_streams", file.path])
        XCTAssertTrue(side.contains("DOVI") || side.contains("Dolby Vision"), "no Dolby Vision metadata in the file")
    }

    /// "Make it much smaller" when the player can't do AV1 picks archival x265 HEVC; that export must work.
    func testSaveSpaceWithoutAV1ExportsWithX265() async throws {
        guard ToolLocator.isAvailable("x265") else { throw XCTSkip("x265 not installed") }
        let m = try await opened(try Self.clip("sdr"))
        m.goal = .saveSpace
        m.playsAV1 = false
        m.applyRecommendation()
        XCTAssertEqual(m.codec, .hevc12)
        XCTAssertEqual(m.delivery, .sdr)
        if m.status == "Re-analysing" { try await waitForReanalysis(m, "re-analysis") }
        m.useTargetQuality = false          // fixed quality and the fastest rung keep the test short
        m.planMode = .fastest
        let out = Self.root.appendingPathComponent("x265")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        m.export(presetIDs: [try XCTUnwrap(m.selectedPresetID)], folder: out)
        try await waitUntil("x265 export (status: \(m.status))", timeout: 240) {
            m.errorMessage != nil || (m.status.hasPrefix("Saved") && m.lastPackage != nil)
        }
        XCTAssertNil(m.errorMessage)
        let file = try XCTUnwrap(m.lastPackage?.video)
        let p = try EndToEndTests.probe(file)
        XCTAssertEqual(p.codec, "hevc"); XCTAssertEqual(p.frames, 48); XCTAssertTrue(p.pixFmt.contains("10"), p.pixFmt)
        XCTAssertEqual(try Self.frameRate(file), 24, accuracy: 0.01)
        let y = try EndToEndTests.meanLuma(file)
        XCTAssertTrue((0.1...0.9).contains(y), "mean luma \(y)")
        XCTAssertEqual(m.lastPackage?.verified, true, "post-export verification")
    }

    func checkAdvisor(_ m: AppModel) throws {
        let dim = m.report.map { $0.verdict == .conservative || $0.verdict == .fakeHDR } ?? false
        for dest in FormatAdvisor.Destination.allCases {
            let a = FormatAdvisor.advise(for: dest, source: m.descriptor, color: m.selectedColor, report: m.report)
            let before = m.selectedPresetID
            let token = m.renderToken
            m.apply(a)
            let tag = "\(m.selectedColor?.name ?? "") → \(dest.title)"
            XCTAssertEqual(m.delivery, a.delivery, tag); XCTAssertEqual(m.codec, a.codec, tag)
            XCTAssertEqual(m.bitDepth, a.bitDepth, tag); XCTAssertEqual(m.peakNits, a.peakNits, tag)
            XCTAssertEqual(m.chroma, a.codec.chromaFormats[0], tag)
            XCTAssertEqual(m.previewTarget, OutputTarget(kind: a.delivery.target.0, peakNits: a.peakNits), tag)
            XCTAssertEqual(m.renderToken, token + 1, tag)
            if let look = a.look {
                XCTAssertTrue(m.presets.contains { $0.look == look }, "\(tag): advises \(look.displayName), which this file has no preset for")
                XCTAssertEqual(m.selectedPreset?.look, look, tag)
            } else {
                XCTAssertEqual(m.selectedPresetID, before, "\(tag): look kept")
            }
            if a.look == .ripRevive { XCTAssertTrue(dim, "\(tag): Rip Revive advised for HDR that isn't dim") }
            XCTAssertNil(ExportEngine.validate(try job(m)), "\(tag): advice can't be exported")
            XCTAssertFalse(a.headline.isEmpty); XCTAssertFalse(a.why.isEmpty)
            if m.selectedColor?.transfer.isSDR == true {
                XCTAssertTrue(a.watchOut.contains { $0.contains("Your source is SDR") }, tag)
            }
        }
    }

    func testFormatAdvisorEveryDestinationAppliesCleanly() async throws {
        let sdr = try await opened(try Self.clip("sdr"))
        try checkAdvisor(sdr)
        let hdr = try await opened(try Self.hdrClip())
        try checkAdvisor(hdr)
    }

    // MARK: - Planner and forecast

    func testPlanUpgradeAndForecastFollowSettings() async throws {
        let m = try await opened(try Self.clip("sdr"))
        m.codec = .av1
        m.planMode = .bestForMac
        let plan = try XCTUnwrap(m.currentPlan())
        XCTAssertEqual(plan.choice.codec, .av1)
        XCTAssertGreaterThan(plan.seconds, 0)
        XCTAssertFalse(plan.choice.rungLabel.isEmpty)
        m.planMode = .fastest
        let fast = try XCTUnwrap(m.currentPlan())
        m.planMode = .maximum
        let max = try XCTUnwrap(m.currentPlan())
        XCTAssertLessThanOrEqual(fast.seconds, max.seconds)
        XCTAssertLessThanOrEqual(fast.saving, max.saving)

        m.planMode = .fastest
        let u = try XCTUnwrap(fast.upgrade, "the fastest AV1 plan should offer an upgrade")
        m.applyUpgrade(u)
        XCTAssertEqual(m.planMode, .budget)
        XCTAssertEqual(m.budgetHours, (fast.seconds + u.extraSeconds) / 3600 + 0.05, accuracy: 1e-6)
        let upgraded = try XCTUnwrap(m.currentPlan())
        XCTAssertGreaterThanOrEqual(upgraded.saving, fast.saving + 0.01, "the budget should now buy the upgrade")
        XCTAssertGreaterThanOrEqual(upgraded.seconds, fast.seconds + u.extraSeconds - 1)
        XCTAssertLessThanOrEqual(upgraded.seconds, m.budgetHours * 3600)

        // Forecast: an instant estimate keyed to the current settings, and it reacts to them.
        let f1 = try XCTUnwrap(m.currentForecast())
        XCTAssertEqual(f1.method, .quick)
        XCTAssertLessThanOrEqual(f1.low, f1.mid); XCTAssertLessThanOrEqual(f1.mid, f1.high)
        XCTAssertGreaterThan(f1.videoMid, 0)
        XCTAssertGreaterThan(f1.otherBytes, 0, "the audio track is carried over")
        XCTAssertEqual(f1.sourceBytes, m.sourceSizes?.total)
        XCTAssertTrue(f1.key.hasPrefix("av1|10|4:2:0|"), f1.key)
        m.codec = .prores4444XQ; m.bitDepth = 12; m.chroma = .c444
        let f2 = try XCTUnwrap(m.currentForecast())
        XCTAssertNotEqual(f2.key, f1.key)
        XCTAssertGreaterThan(f2.mid, f1.mid * 3, "a 12-bit ProRes master must forecast far larger than AV1")
        m.codec = .hevc; m.bitDepth = 10; m.chroma = .c420
        m.interpolation.mode = .multiply(2)
        let f3 = try XCTUnwrap(m.currentForecast())
        m.interpolation.mode = .off
        let f4 = try XCTUnwrap(m.currentForecast())
        XCTAssertGreaterThan(f3.videoMid, f4.videoMid, "twice the frames should forecast a bigger video stream")
    }

    // MARK: - Export

    func testExportTwoLooksAlsoAtOriginalFrameRate() async throws {
        try TestHardware.requireHardwareHEVC()
        let m = try await opened(try Self.clip("sdr"))
        let looks = try [Look.natural, .punchy].map { l in try XCTUnwrap(m.presets.first { $0.look == l }) }
        m.delivery = .sdr; m.codec = .hevc; m.bitDepth = 10; m.chroma = .c420
        m.useTargetQuality = false
        m.interpolation.mode = .multiply(2)
        m.alsoExportOriginalRate = true
        let out = Self.root.appendingPathComponent("two-looks")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        m.export(presetIDs: looks.map(\.id), folder: out)
        try await waitUntil("both exports (status: \(m.status))", timeout: 400) {
            m.errorMessage != nil || (Self.videoFiles(in: out).filter { $0.lastPathComponent.contains("original-fps") }.count == 2
                                       && m.status == "Saved interpolated and original-frame-rate versions")
        }
        XCTAssertNil(m.errorMessage)
        try await waitUntil("progress to clear", timeout: 10) { m.progress == nil }
        let videos = Self.videoFiles(in: out)
        let originals = videos.filter { $0.lastPathComponent.contains("original-fps") }
        let smooth = videos.filter { !$0.lastPathComponent.contains("original-fps") }
        XCTAssertEqual(originals.count, 2, "\(videos.map(\.lastPathComponent))")
        XCTAssertEqual(smooth.count, 2, "\(videos.map(\.lastPathComponent))")
        var lumas: [String: Double] = [:]
        for v in smooth {
            let p = try EndToEndTests.probe(v)
            XCTAssertEqual(p.codec, "hevc", v.lastPathComponent); XCTAssertTrue(p.pixFmt.contains("10"), p.pixFmt)
            // 2×: every original plus one new frame between each pair (none after the last): (48 − 1) × 2 + 1.
            XCTAssertEqual(p.frames, 95, "\(v.lastPathComponent): 2× interpolated")
            XCTAssertEqual(try Self.frameRate(v), 48, accuracy: 0.01)
            XCTAssertEqual(p.transfer, "bt709")
            lumas[v.lastPathComponent] = try EndToEndTests.meanLuma(v)
        }
        for v in originals {
            let p = try EndToEndTests.probe(v)
            XCTAssertEqual(p.codec, "hevc"); XCTAssertEqual(p.frames, 48, v.lastPathComponent)
            XCTAssertEqual(try Self.frameRate(v), 24, accuracy: 0.01)
        }
        // One file per look, named for its look, and the two grades really differ.
        XCTAssertTrue(smooth.contains { $0.lastPathComponent.contains("Natural") }, "\(smooth.map(\.lastPathComponent))")
        XCTAssertTrue(smooth.contains { $0.lastPathComponent.contains("Punchy") }, "\(smooth.map(\.lastPathComponent))")
        XCTAssertTrue(originals.contains { $0.lastPathComponent.contains("Natural") } && originals.contains { $0.lastPathComponent.contains("Punchy") })
        let l = Array(lumas.values)
        XCTAssertEqual(l.count, 2)
        XCTAssertGreaterThan(abs(l[0] - l[1]), 0.002, "Natural and Punchy exports look the same: \(lumas)")
        for y in l { XCTAssertTrue((0.1...0.9).contains(y), "exposure off: \(lumas)") }
        XCTAssertNotNil(m.lastOriginalRateURL)
        XCTAssertEqual(m.lastExportURL, m.lastPackage?.video)
        let packaged = try XCTUnwrap(m.lastPackage?.video).resolvingSymlinksInPath().path
        XCTAssertTrue(smooth.map { $0.resolvingSymlinksInPath().path }.contains(packaged), packaged)
        XCTAssertEqual(Self.scratchLeftovers(), [], "scratch should be empty after the exports")
    }

    func testCancelMidExportLeavesNoPartialOutputAndCleansScratch() async throws {
        try await cancelMidExport(targetQuality: false)
    }

    /// The default export path (quality target: chunk trials scored with VMAF) must cancel just as cleanly.
    func testCancelMidTargetQualityExport() async throws {
        guard VMAFRunner.available else { throw XCTSkip("VMAF isn't available, so there is no quality-target path") }
        try await cancelMidExport(targetQuality: true)
    }

    func cancelMidExport(targetQuality: Bool) async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SvtAv1EncApp not installed") }
        let m = try await opened(try Self.clip("long", width: 1280, height: 720, shotSeconds: 3))
        m.delivery = .sdr; m.codec = .av1; m.bitDepth = 10; m.chroma = .c420
        m.useTargetQuality = targetQuality
        m.planMode = .maximum      // slowest settings, so there's time to cancel mid-encode
        m.interpolation.mode = .off
        let before = Set(Self.scratchLeftovers())
        let out = Self.root.appendingPathComponent(targetQuality ? "cancelled-tq" : "cancelled-fixed")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        m.export(presetIDs: [try XCTUnwrap(m.selectedPresetID)], folder: out)
        try await waitUntil("encoding to start (status: \(m.status))", timeout: 60) {
            (m.progress ?? 0) > 0.01 || m.status.contains("Encoding") || m.errorMessage != nil || m.status.hasPrefix("Saved")
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(m.errorMessage)
        XCTAssertFalse(m.status.hasPrefix("Saved"), "export finished before it could be cancelled")
        XCTAssertFalse(Set(Self.scratchLeftovers()).subtracting(before).isEmpty, "export should be using scratch")
        m.cancel()
        try await waitUntil("cancellation (status: \(m.status))", timeout: 30) { m.status == "Cancelled" || m.errorMessage != nil }
        XCTAssertNil(m.errorMessage, "cancelling should not surface an error")
        try await waitUntil("progress to clear", timeout: 10) { m.progress == nil }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(Self.allFiles(in: out).map(\.lastPathComponent), [], "no partial output")
        XCTAssertEqual(Set(Self.scratchLeftovers()).subtracting(before), [], "scratch folders left behind")
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let list = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        XCTAssertFalse(list.split(separator: "\n").contains { $0.contains("SvtAv1EncApp") && $0.contains(Self.scratch.path) },
                       "encoder process still running after cancel")
        XCTAssertNil(m.lastExportURL)
    }

    func testBadFileReportsAnError() async throws {
        try TestHardware.requireGPU()
        let bad = Self.root.appendingPathComponent("CampaignFlow-garbage.mp4")
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }).write(to: bad)
        let m = AppModel()
        m.open(bad)
        try await waitUntil("error for a garbage file (status: \(m.status))", timeout: 30) { m.errorMessage != nil }
        XCTAssertFalse(m.errorMessage!.isEmpty)
        XCTAssertNil(m.descriptor); XCTAssertTrue(m.presets.isEmpty); XCTAssertNil(m.analysis)
        try await waitUntil("progress to clear", timeout: 5) { m.progress == nil }

        let missing = AppModel()
        missing.open(Self.root.appendingPathComponent("CampaignFlow-does-not-exist.mov"))
        try await waitUntil("error for a missing file", timeout: 30) { missing.errorMessage != nil }
        XCTAssertNil(missing.descriptor)
    }

    func testAV2AbsenceIsReportedCleanly() async throws {
        XCTAssertFalse(ToolLocator.isAvailable("avmenc"), "avmenc is installed here; this test expects it absent")
        XCTAssertFalse(Codec.av2.available)
        let m = try await opened(try Self.clip("sdr"))
        m.codec = .av2; m.bitDepth = 10; m.chroma = .c420; m.delivery = .hdr10
        let problem = try XCTUnwrap(ExportEngine.validate(try job(m)))
        XCTAssertTrue(problem.contains("avmenc") && problem.contains("isn't installed"), problem)
        let out = Self.root.appendingPathComponent("av2")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        m.export(presetIDs: [try XCTUnwrap(m.selectedPresetID)], folder: out)
        try await waitUntil("AV2 export error", timeout: 30) { m.errorMessage != nil }
        XCTAssertTrue(m.errorMessage!.contains("avmenc") && m.errorMessage!.contains("isn't installed"), m.errorMessage!)
        XCTAssertEqual(Self.allFiles(in: out), [])
        // The planner and forecast still answer without the encoder.
        XCTAssertNotNil(m.currentForecast())
    }

    // MARK: - Sheets, dialogs and inspector tabs (offscreen)

    func testRenderExportAdvisorAndReportSheets() async throws {
        let m = try await opened(try Self.clip("sdr"))
        let export = try await render(dressed(ExportSheet(), m), name: "export-sheet", size: CGSize(width: 560, height: 680))
        assertNotBlank(export, "ExportSheet")
        try assertShows(export, ["Export", "HDR format", "Codec", "Presets to export", "Cancel"], "ExportSheet")

        // A codec that isn't installed shows the reason instead of a broken export.
        m.codec = .av2
        let av2 = try await render(dressed(ExportSheet(), m), name: "export-sheet-av2", size: CGSize(width: 560, height: 680))
        try assertShows(av2, ["not installed"], "ExportSheet with AV2")
        m.codec = .hevc

        m.interpolation.mode = .multiply(2)
        let interp = try await render(dressed(ExportSheet(), m), name: "export-sheet-interp", size: CGSize(width: 560, height: 680))
        try assertShows(interp, ["original frame rate"], "ExportSheet with interpolation")
        m.interpolation.mode = .off

        let advisor = try await render(dressed(AdvisorSheet(), m), name: "advisor-sheet", size: CGSize(width: 560, height: 640))
        assertNotBlank(advisor, "AdvisorSheet")
        try assertShows(advisor, ["Where is this video going?", "YouTube", "Upload HDR10 HEVC at 1000 nits", "Use these settings"], "AdvisorSheet")

        let report = try await render(dressed(ReportCardSheet(), m), name: "report-sheet", size: CGSize(width: 560, height: 520))
        assertNotBlank(report, "ReportCardSheet")
        try assertShows(report, [try XCTUnwrap(m.report?.title), "SDR video", "Typical brightness", "Add to my library"], "ReportCardSheet")
    }

    func testRenderTrialViewFromARealSmoothingTest() async throws {
        let m = try await opened(try Self.clip("sdr"))
        let h = try XCTUnwrap(m.hotspots.first, "two one-second scenes should give hotspots")
        m.runTrial(h)
        XCTAssertTrue(m.trialBusy)
        try await waitUntil("smoothing test", timeout: 120) { !m.trialBusy }
        XCTAssertNil(m.errorMessage)
        let t = try XCTUnwrap(m.trial)
        XCTAssertEqual(t.outputFps, 48, accuracy: 0.01, "a test with interpolation off doubles the rate")
        XCTAssertEqual(t.original.count, t.interpolated.count)
        XCTAssertGreaterThanOrEqual(t.interpolated.count, 40)
        let generated = t.generatedMask.filter { $0 }.count
        XCTAssertEqual(Double(generated), Double(t.interpolated.count) / 2, accuracy: 2, "every other frame is new")
        XCTAssertEqual(t.interpolated.first?.width, 640, "trial frames are rendered at preview size")
        // A generated frame differs from the held original next to it.
        if let i = t.generatedMask.firstIndex(of: true) {
            XCTAssertGreaterThan(Self.meanAbsDiff(t.interpolated[i], t.original[i]), 0.001)
        }
        let img = try await render(dressed(TrialView(), m), name: "trial", size: CGSize(width: 1000, height: 560))
        assertNotBlank(img, "TrialView")
        try assertShows(img, ["Smoothing test", "Original", "Smoothed (48 fps)", "Done"], "TrialView")
    }

    func testModelLabConfirmationStateForUnpinnedImports() async throws {
        let m = try await opened(try Self.clip("sdr"))
        let lab = ModelLab.shared
        let unpinned = try XCTUnwrap(lab.catalog.first { $0.sha256 == nil && $0.url == nil }, "catalog needs an unpinned release")
        let pinned = try XCTUnwrap(lab.catalog.first { $0.sha256 != nil && lab.status[$0.id] == .notDownloaded }, "a pinned, not downloaded release")
        let hadZip = FileManager.default.fileExists(atPath: lab.zipURL(unpinned).path)
        guard !hadZip, lab.status[unpinned.id] == .notDownloaded else { throw XCTSkip("RIFE \(unpinned.id) is already on this Mac; not touching it") }
        let fake = Self.root.appendingPathComponent("not-rife.zip")
        try Data("PK\u{05}\u{06}".utf8 + [UInt8](repeating: 0, count: 18)).write(to: fake)

        // A pinned release refuses a file with the wrong checksum, and nothing is written.
        XCTAssertThrowsError(try lab.importZip(fake, for: pinned)) { e in
            XCTAssertTrue(e.localizedDescription.contains("checksum differs"), e.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lab.zipURL(pinned).path))
        XCTAssertEqual(lab.status[pinned.id], .notDownloaded)

        // An unpinned import is accepted but recorded as unverified, so Convert asks first.
        try lab.importZip(fake, for: unpinned)
        defer { try? FileManager.default.removeItem(at: lab.zipURL(unpinned)); lab.refresh() }
        XCTAssertEqual(lab.status[unpinned.id], .downloaded)
        let prov = try XCTUnwrap(lab.provenance(unpinned))
        XCTAssertFalse(prov.verified, "hand import of an unpinned release must not count as verified")
        XCTAssertEqual(prov.sha256, try ModelLab.sha256(of: fake))
        // Installed pinned downloads convert without asking.
        if let ok = lab.catalog.first(where: { lab.provenance($0)?.verified == true }) {
            XCTAssertEqual(ok.sha256?.lowercased(), lab.provenance(ok)?.sha256)
        }
        let img = try await render(dressed(ModelLabView(), m), name: "modellab-confirm", size: CGSize(width: 1000, height: 820))
        assertNotBlank(img, "ModelLabView")
        try assertShows(img, ["Model Lab", "RIFE \(unpinned.id)", "Downloaded"], "ModelLabView")
    }

    func testRenderEachInspectorTab() async throws {
        let m = try await opened(try Self.clip("sdr"))
        m.simpleMode = false
        let size = CGSize(width: 430, height: 900)
        let inspector = try await render(dressed(InspectorView(), m), name: "inspector", size: size)
        assertNotBlank(inspector, "InspectorView")
        try assertShows(inspector, ["Source", "Look", "Motion", "Enhance", "Deliver", "CampaignFlow-sdr.mp4"], "InspectorView")

        // Each tab's panel, hosted exactly as InspectorView hosts it.
        func tab(_ t: InspectorTab) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch t {
                    case .source: SourcePanel()
                    case .look: LookPanel()
                    case .motion: InterpolationSection()
                    case .enhance: UpscaleSection()
                    case .deliver: DeliverPanel()
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(width: 310)          // InspectorView is 372 wide, less its 62-point tab rail
        }
        let expected: [InspectorTab: [String]] = [
            .source: ["Picture", "Remove black bars", "Content"],
            .look: ["Exposure", "Contrast", "Saturation", "Save changes to this preset"],
            .motion: ["Frame interpolation", "Intelligence", "Scan for interpolation problems"],
            .enhance: ["Upscaling", "Output height"],
            .deliver: ["Quality", "Encode to a quality target"]
        ]
        var shots: [InspectorTab: CGImage] = [:]
        for t in InspectorTab.allCases {
            let img = try await render(dressed(tab(t), m), name: "inspector-\(t.rawValue)", size: CGSize(width: 310, height: 1500))
            assertNotBlank(img, "\(t.rawValue) tab")
            try assertShows(img, expected[t] ?? [], "\(t.rawValue) tab")
            for l in try Self.ocr(img) where l.box.minX * 310 < 2 || (1 - l.box.maxX) * 310 < 2 {
                XCTFail("\(t.rawValue) tab: “\(l.text)” is cut at the edge of the inspector")
            }
            shots[t] = img
        }
        XCTAssertGreaterThan(Self.meanAbsDiff(shots[.look]!, shots[.deliver]!), 0.01)
    }

    func testRenderSimpleModeForEveryGoal() async throws {
        let m = try await opened(try Self.clip("sdr"))
        m.simpleMode = true
        m.playsAV1 = true
        let needles: [Goal: [String]] = [
            .watchOnTV: ["Convert to HDR10", "Natural"],
            .archive: ["AV1 (SVT-AV1)"],
            .saveSpace: ["Time budget"],
            .share: ["HEVC (hardware)", "Transparent streaming"],
            .smoother: ["Interpolate to 60 fps"]
        ]
        var shots: [Goal: CGImage] = [:]
        for g in Goal.allCases {
            m.goal = g
            let img = try await render(dressed(SimpleModeView(), m), name: "simple-\(g.id.prefix(12))", size: CGSize(width: 1100, height: 1400))
            assertNotBlank(img, "Simple mode, \(g.rawValue)")
            try assertShows(img, ["What do you want to do?", "Lumora recommends", "Use these settings"] + (needles[g] ?? []), "Simple mode, \(g.rawValue)")
            shots[g] = img
        }
        XCTAssertGreaterThan(Self.meanAbsDiff(shots[.share]!, shots[.smoother]!), 0.001, "goals should change the panel")
    }

    /// At the window's minimum size (1280×800) nothing in Simple mode may run off the right edge: the right-hand
    /// panel must look exactly as it does in a wide window, and every line of text in it must end inside it.
    func testSimpleModeLayoutAtMinimumWindowSize() async throws {
        let m = try await opened(try Self.clip("sdr"))
        m.simpleMode = true
        m.goal = .watchOnTV
        func main() -> some View {
            ContentView().environment(m).environment(EncodeMonitor.shared).environment(TaskCenter.shared)
                .preferredColorScheme(.dark).tint(Theme.signal)
        }
        let narrow = try await render(main(), name: "simple-1280x800", size: CGSize(width: 1280, height: 800))
        let wide = try await render(main(), name: "simple-1800x800", size: CGSize(width: 1800, height: 800))
        let scale = Double(narrow.width) / 1280
        XCTAssertEqual(Double(wide.width) / 1800, scale, accuracy: 0.01)
        assertNotBlank(narrow, "Simple mode at 1280×800")
        let panelW = Int(400 * scale)
        func panel(_ img: CGImage) -> CGImage { img.cropping(to: CGRect(x: img.width - panelW, y: 0, width: panelW, height: img.height))! }
        let pn = panel(narrow), pw = panel(wide)
        let diff = Self.meanAbsDiff(pn, pw)
        XCTAssertLessThan(diff, 0.01, "the right-hand panel differs at the minimum window size (shifted or squeezed): \(diff)")
        // Every recognised text line in the panel sits inside it, clear of both edges (an over-wide control makes
        // the whole panel overflow and get cut on both sides).
        let lines = try Self.ocr(pn)
        XCTAssertGreaterThan(lines.count, 5, "OCR found too little in the panel")
        for l in lines {
            let rightPts = (1 - l.box.maxX) * 400, leftPts = l.box.minX * 400
            XCTAssertGreaterThan(rightPts, 3, "“\(l.text)” touches the right edge (\(rightPts) pt)")
            XCTAssertGreaterThan(leftPts, 3, "“\(l.text)” is cut at the panel's left edge (\(leftPts) pt)")
        }
        try assertShows(pn, ["What do you want to do?", "best quality)", "Share it or play it anywhere",
                             "Lumora recommends", "Use these settings"], "Simple panel at 1280×800")
        // The same words are readable in both.
        let wn = Set(lines.map(\.text)), ww = Set(try Self.ocr(pw).map(\.text))
        XCTAssertTrue(ww.subtracting(wn).count <= 1, "text missing at 1280×800: \(ww.subtracting(wn))")
        // The picture column's overlay is intact (the Metal picture itself isn't captured by an offscreen snapshot).
        let leftW = narrow.width - panelW
        try assertShows(narrow.cropping(to: CGRect(x: 0, y: 0, width: leftW, height: narrow.height))!, ["CampaignFlow-sdr", "presets ready"], "picture column")
    }

    // MARK: - Hardware

    func testSystemMonitorReadings() async throws {
        let mon = SystemMonitor.shared
        let before = mon.history.count
        mon.start()
        try await waitUntil("three samples", timeout: 8) { mon.history.count >= before + 3 }
        XCTAssertTrue((0...1).contains(mon.cpu), "cpu \(mon.cpu)")
        XCTAssertGreaterThan(mon.history.suffix(2).map(\.cpu).max() ?? 0, 0, "CPU load should be measured as non-zero on a busy machine")
        XCTAssertTrue((0.01...1).contains(mon.memory), "memory \(mon.memory)")
        if let g = mon.gpu { XCTAssertTrue((0...1).contains(g), "gpu \(g)") }
        XCTAssertEqual(mon.thermal, ProcessInfo.processInfo.thermalState)
        XCTAssertFalse(mon.thermalText.isEmpty)
        mon.stop()
        let n = mon.history.count
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(mon.history.count, n, "stop() should stop sampling")
    }

    func testMacOptimizerQuickMeasuresAndWritesProfile() async throws {
        // Deferred by the owner: "Optimize for this Mac" is not to run on this Mac for now (it benchmarks the
        // machine for minutes). Run it deliberately with TEST_RUNNER_LUMORA_RUN_OPTIMIZER=1.
        guard ProcessInfo.processInfo.environment["LUMORA_RUN_OPTIMIZER"] == "1" else {
            throw XCTSkip("Optimize for this Mac deferred by the owner; set LUMORA_RUN_OPTIMIZER=1 to run it")
        }
        try TestHardware.requireHardwareHEVC()
        let profileURL = Self.support.appendingPathComponent("mac-profile.json")
        let saved = try? Data(contentsOf: profileURL)
        let savedCurrent = MacProfile.current
        defer {
            if let saved { try? saved.write(to: profileURL, options: .atomic) } else { try? FileManager.default.removeItem(at: profileURL) }
            MacProfile.current = savedCurrent
            SystemMonitor.shared.stop()
        }
        let opt = MacOptimizer.shared
        XCTAssertFalse(opt.running)
        opt.start(.quick, footage: nil)
        XCTAssertTrue(opt.running)
        XCTAssertEqual(opt.steps.count, 7)
        try await waitUntil("Quick optimization (\(opt.steps.map { "\($0.name): \($0.state)" }))", timeout: 1200) { !opt.running }
        for s in opt.steps {
            XCTAssertEqual(s.state, "Done", s.name)
            XCTAssertFalse(s.result.isEmpty, s.name)
        }
        let data = try Data(contentsOf: profileURL)
        let p = try JSONDecoder().decode(MacProfile.self, from: data)
        XCTAssertEqual(p.machine, MacProfile.machineModel)
        XCTAssertEqual(p.os, MacProfile.osVersion)
        XCTAssertEqual(p.level, MacOptimizer.Level.quick.rawValue)
        XCTAssertEqual(Set(p.threadgroups.keys), ["gradeKernel", "bilateralKernel", "blendKernel", "regrainKernel"])
        for (k, v) in p.threadgroups { XCTAssertEqual(v.count, 2, k); XCTAssertGreaterThan(v[0] * v[1], 0, k) }
        XCTAssertGreaterThanOrEqual(p.vtSessions ?? 0, 1)
        if Codec.av1.available { XCTAssertGreaterThanOrEqual(p.cliInstances["av1"] ?? 0, 1); XCTAssertGreaterThan(p.cliFps["av1"] ?? 0, 0) }
        XCTAssertGreaterThan(p.scratchWriteMBps ?? 0, 0)
        XCTAssertTrue((0.3...1).contains(p.sustainedFactor), "\(p.sustainedFactor)")
        XCTAssertTrue((3...16).contains(p.pipelineDepth))
        XCTAssertEqual(p.findings.count, 7)
        XCTAssertEqual(opt.summary, p.findings)
        XCTAssertEqual(MacProfile.current?.machine, p.machine, "the new profile applies right away")
        if InterpolationModelSpec.all().contains(where: \.isInstalled) { XCTAssertFalse(p.coreMLUnits.isEmpty) }
        XCTAssertEqual(Self.scratchLeftovers(), [], "optimizer left files in scratch")
    }
}
