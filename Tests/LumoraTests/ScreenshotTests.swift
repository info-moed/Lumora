import XCTest
import SwiftUI
import AppKit
@testable import Lumora

/// Generates the documentation screenshots: every screen of the app, offscreen, with original sample footage.
/// Skipped in normal test runs. Generate them with:
///
///     scripts/screenshots.sh
///
/// which runs this class with LUMORA_SCREENSHOTS=1 and copies the PNGs into docs/images/.
@MainActor
final class ScreenshotTests: XCTestCase {
    static var outDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraScreenshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["LUMORA_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Screenshots are generated on demand: scripts/screenshots.sh")
        }
        try TestHardware.requireGPU()
        EDRViewer.snapshotMode = true
        // The "not tuned for this Mac yet" banner isn't part of what the screenshots document; hide it, then put the
        // owner's own setting back afterwards.
        savedBanner = Prefs.store.object(forKey: "optimizeBannerDismissed")
        Prefs.store.set(true, forKey: "optimizeBannerDismissed")
    }

    private var savedBanner: Any?

    override func tearDown() async throws {
        EDRViewer.snapshotMode = false
        InspectorView.defaultTab = .source
        if let savedBanner { Prefs.store.set(savedBanner, forKey: "optimizeBannerDismissed") }
        else { Prefs.store.removeObject(forKey: "optimizeBannerDismissed") }
    }

    // MARK: Sample footage (original, generated)

    /// Three shots with hard cuts: a colorful fractal zoom, a slow sunset-like gradient sweep, and a fractal
    /// triangle pattern. Optionally encoded as HDR10 (PQ, BT.2020) so the HDR features have something to show.
    static func sampleFootage(hdr: Bool) throws -> URL {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let url = outDir.appendingPathComponent(hdr ? "Aurora HDR.mp4" : "Aurora.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let shots = [
            "mandelbrot=s=1920x1080:r=24:start_scale=2.5:end_scale=0.6:end_pts=96:inner=convergence,trim=duration=2,setpts=PTS-STARTPTS[a]",
            "gradients=s=1920x1080:r=24:c0=0x0b1d51:c1=0xff6b35:c2=0xffd166:c3=0x7b2cbf:n=4:speed=0.03:type=radial,trim=duration=2,setpts=PTS-STARTPTS[b]",
            "sierpinski=s=1920x1080:r=24:type=triangle,hue=h=200:s=1.4,trim=duration=2,setpts=PTS-STARTPTS[c]",
        ]
        var graph = shots.joined(separator: ";") + ";[a][b][c]concat=n=3:v=1"
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-filter_complex"]
        if hdr {
            graph += ",format=yuv420p10le,scale=out_color_matrix=bt2020:out_range=tv[v]"
            args += [graph, "-map", "[v]", "-c:v", "libx265", "-x265-params",
                     "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:max-cll=1000,400",
                     "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
        } else {
            graph += ",format=yuv420p[v]"
            args += [graph, "-map", "[v]", "-c:v", "libx264", "-crf", "16",
                     "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        }
        try EndToEndTests.sh(ffmpeg, args + [url.path])
        return url
    }

    // MARK: Rendering

    func shoot<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 1440, height: 900)) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.surround))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.outDir.appendingPathComponent("\(name).png"))
    }

    func loaded(hdr: Bool = false, simple: Bool) async throws -> AppModel {
        let model = AppModel()
        model.simpleMode = simple
        model.open(try Self.sampleFootage(hdr: hdr))
        let deadline = Date().addingTimeInterval(120)
        while (model.presets.isEmpty || model.previewFrame == nil), model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.errorMessage)
        if let natural = model.presets.first(where: { $0.look == .natural }) { model.selectedPresetID = natural.id }
        model.scrub(to: 0.9)
        try await Task.sleep(nanoseconds: 800_000_000)
        model.renderThumbnails()
        return model
    }

    func main(_ model: AppModel) -> some View {
        ContentView()
            .environment(model)
            .environment(EncodeMonitor.shared)
            .environment(TaskCenter.shared)
            .preferredColorScheme(.dark)
            .tint(Theme.signal)
    }

    func dark<V: View>(_ v: V, _ model: AppModel) -> some View {
        v.environment(model).environment(EncodeMonitor.shared).environment(TaskCenter.shared)
            .preferredColorScheme(.dark).tint(Theme.signal).background(Theme.surround)
    }

    // MARK: Screens

    /// The built-in Player with its info overlay on an HDR10 clip (1280×720, encoded at low priority).
    func testPlayer() async throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let clip = Self.outDir.appendingPathComponent("Aurora HDR.mkv")
        if !FileManager.default.fileExists(atPath: clip.path) {
            let graph = "mandelbrot=s=1280x720:r=24:start_scale=2.5:end_scale=0.6:end_pts=96:inner=convergence,trim=duration=1,setpts=PTS-STARTPTS[a];"
                + "gradients=s=1280x720:r=24:c0=0x0b1d51:c1=0xff6b35:c2=0xffd166:c3=0x7b2cbf:n=4:speed=0.03:type=radial,trim=duration=1,setpts=PTS-STARTPTS[b];"
                + "[a][b]concat=n=2:v=1,format=yuv420p10le,scale=out_color_matrix=bt2020:out_range=tv[v]"
            try PlayerFixtures.ffmpeg(["-filter_complex", graph, "-map", "[v]", "-c:v", "libx265", "-x265-params",
                                       "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:max-cll=1000,400:" +
                                       "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)",
                                       "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", clip.path])
        }
        PlayerMetalView.snapshotMode = true
        defer { PlayerMetalView.snapshotMode = false }
        let engine = PlayerEngine()
        var bound: URL? = clip
        let view = PlayerWindow(url: Binding(get: { bound }, set: { bound = $0 }), engine: engine)
        let host = NSHostingView(rootView: view.frame(width: 1440, height: 810))
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 810)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        defer { engine.stop(); window.close() }
        let deadline = Date().addingTimeInterval(60)
        while engine.currentFrame?.index != 20 && Date() < deadline {
            if engine.info != nil && engine.currentFrame != nil && engine.currentIndex != 20 { engine.seek(toFrame: 20) }
            _ = engine.frameForDisplay(targetHost: CACurrentMediaTime())
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.showInfo = true
        for _ in 0..<20 {
            _ = engine.frameForDisplay(targetHost: CACurrentMediaTime())
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: Self.outDir.appendingPathComponent("26-player.png"))
    }

    func testMainWindow() async throws {
        let empty = AppModel()
        empty.simpleMode = true
        try await shoot("01-simple-empty", main(empty))

        let simple = try await loaded(simple: true)
        for (n, goal) in [("02-simple-watch-on-tv", Goal.watchOnTV), ("03-simple-archive", .archive),
                          ("04-simple-smaller", .saveSpace), ("05-simple-smoother", .smoother)] {
            simple.goal = goal
            try await shoot(n, main(simple))
        }

        let pro = try await loaded(simple: false)
        for (n, tab) in [("06-pro-source", InspectorTab.source), ("07-pro-look", .look), ("08-pro-motion", .motion),
                         ("09-pro-enhance", .enhance), ("10-pro-deliver", .deliver)] {
            InspectorView.defaultTab = tab
            try await shoot(n, main(pro))
        }
        InspectorView.defaultTab = .look
        pro.showScopes = true
        try await Task.sleep(nanoseconds: 500_000_000)
        try await shoot("11-pro-scopes", main(pro))
        pro.showScopes = false
    }

    func testHDRSource() async throws {
        let model = try await loaded(hdr: true, simple: false)
        InspectorView.defaultTab = .source
        try await shoot("12-pro-hdr-source", main(model))
        if model.report != nil {
            try await shoot("13-hdr-report", dark(ReportCardSheet(), model), size: CGSize(width: 720, height: 640))
        }
    }

    func testSheetsAndWindows() async throws {
        let model = try await loaded(simple: false)
        try await shoot("14-export", dark(ExportSheet(), model), size: CGSize(width: 680, height: 720))
        try await shoot("15-advisor", dark(AdvisorSheet(), model), size: CGSize(width: 760, height: 640))
        model.prepareCompare()
        try await shoot("16-compare", dark(CompareView().environment(model.compare), model))
        try await shoot("17-model-lab", dark(ModelLabView(), model), size: CGSize(width: 1100, height: 820))
        try await shoot("18-encode-monitor", dark(EncodeMonitorView(), model), size: CGSize(width: 1000, height: 640))
        try await shoot("19-optimize", dark(OptimizeView(), model), size: CGSize(width: 1000, height: 720))
        try await shoot("20-library", LibraryView().environmentObject(model.library).preferredColorScheme(.dark),
                        size: CGSize(width: 1000, height: 640))
        try await shoot("21-log", dark(LogConsoleView().environment(LogStore.shared), model), size: CGSize(width: 1000, height: 640))
        try await shoot("22-settings-storage", dark(StorageSettings().padding(20), model), size: CGSize(width: 720, height: 560))
        try await shoot("23-settings-tools", dark(ToolsSettings().padding(20), model), size: CGSize(width: 720, height: 560))
        try await shoot("24-settings-runs", dark(RunRulesSettings().padding(20), model), size: CGSize(width: 720, height: 560))
    }

    /// The live render monitor, with a real graded frame of the sample footage as the preview and a synthetic
    /// render in progress (two SVT-AV1 segments using every core).
    func testRenderMonitor() async throws {
        let model = try await loaded(simple: false)
        let frame = try XCTUnwrap(model.previewFrame)
        let saved = model.previewTarget
        model.previewTarget = .sdr
        let w = 480, h = Int((480.0 * Double(frame.texture.height) / Double(frame.texture.width)).rounded())
        let tex = MetalContext.shared.makeTexture(width: w, height: h, format: .rgba16Float)
        let u = try XCTUnwrap(model.previewUniforms(viewport: SIMD4<Float>(0, 0, Float(w), Float(h))))
        let cb = try XCTUnwrap(MetalContext.shared.queue.makeCommandBuffer())
        GradeRenderer().encodeGrade(cb, source: frame.texture, destination: tex, uniforms: u)
        cb.commit()
        cb.waitUntilCompleted()
        model.previewTarget = saved
        let (snap, sample) = LiveRenderUITests.syntheticState(preview: tex)
        RenderMonitor.shared.showForTesting(snap, sample: sample)
        let savedDetail = Prefs.store.object(forKey: "renderMonitorDetail")
        Prefs.store.set(true, forKey: "renderMonitorDetail")
        defer {
            RenderMonitor.shared.showForTesting(nil, sample: SystemSample())
            RenderMonitor.testPreview = nil
            RenderMonitor.shared.panelDisappeared()
            if let savedDetail { Prefs.store.set(savedDetail, forKey: "renderMonitorDetail") }
            else { Prefs.store.removeObject(forKey: "renderMonitorDetail") }
        }
        try await shoot("25-render-monitor", dark(LiveRenderPanel().environment(RenderMonitor.shared), model), size: CGSize(width: 1100, height: 860))
    }

    /// The failure explanation (Simple mode) and the resume offer, for docs/render-failures.md. Synthetic reports, so
    /// no footage is needed and nothing personal can appear.
    func testRecoveryScreens() async throws {
        var f = RenderFailure(kind: .diskFull, stage: .encode, volume: "Scratch SSD", message: "No space left on device")
        f.segment = 41
        f.frames = "9840–10079"
        f.code = "NSCocoaErrorDomain 512 ← NSPOSIXErrorDomain 28"
        var x = FailureExplainer.Facts()
        x.progress = 0.63
        x.sourceName = "Aurora.mp4"
        x.neededBytes = 9 << 30
        x.freeBytes = 800 << 20
        var r = FailureExplainer.explain(f, facts: x)
        r.logPath = "~/Library/Logs/Lumora/Exports/2026-11-12 16-41-07 Aurora – Natural – HDR10.log"
        let card = FailureCard(report: r, simple: true, showDetails: .constant(false), onAction: { _ in }, onClose: {})
        try await shoot("30-failure-explained", card.preferredColorScheme(.dark).tint(Theme.signal).background(Theme.surround),
                        size: CGSize(width: 580, height: 300))

        var j = ExportJournal(exportID: "docs", recipeHash: "", renderVersion: CheckpointStore.renderVersion, source: nil,
                              sourceName: "Aurora.mp4", outputPath: "/Movies/Aurora – Natural – HDR10.mkv")
        j.plan = .init(frames: 1000, rateNum: 24, rateDen: 1, workers: 2, segments: [])
        j.segments = [.init(index: 0, file: "", frames: 630, bytes: 0, sha256: "", packets: 630, validatedAt: Date(), attempt: 1)]
        let crash = FailureExplainer.explain(RenderFailure(kind: .interruptedCrash, stage: .encode, message: ""), facts: x)
        let offer = ResumeOffer(journal: j, folder: URL(fileURLWithPath: "/tmp"), report: crash, bytes: 0)
        let banner = VStack { ResumeBannerContent(offer: offer, simple: false) }.padding(16)
        try await shoot("31-resume-offer", banner.preferredColorScheme(.dark).tint(Theme.signal).background(Theme.surround),
                        size: CGSize(width: 1000, height: 120))
    }
}
