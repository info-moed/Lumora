import XCTest
import SwiftUI
import AppKit
@testable import Lumora

/// Builds every window's real SwiftUI view tree offscreen (never ordered front, so nothing appears on screen)
/// with a video loaded through the normal open path, lays it out, and draws it into a bitmap.
/// Catches crashes in view bodies and missing environment objects; the PNGs are written next to the test
/// clips so a person can look at them.
@MainActor
final class UISmokeTests: XCTestCase {
    static var shotsDir: URL {
        let d = EndToEndTests.dir.appendingPathComponent("screens")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Hosts a view in an offscreen window, lets SwiftUI settle, and returns a snapshot.
    @discardableResult
    func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 1440, height: 900)) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<20 {                          // let tasks, onAppear and async state land
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: Self.shotsDir.appendingPathComponent("\(name).png"))
        }
        return rep
    }

    func loadedModel() async throws -> AppModel {
        let model = AppModel()
        model.open(try EndToEndTests.makeClip("sdr.mp4", hdr: false))
        let deadline = Date().addingTimeInterval(60)
        while model.presets.isEmpty, model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.presets.isEmpty, "opening a clip should produce presets (status: \(model.status))")
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

    func testEmptyMainWindow() async throws {
        try await render(main(AppModel()), name: "main-empty")
    }

    func testSimpleModeWithVideo() async throws {
        let model = try await loadedModel()
        model.simpleMode = true
        try await render(main(model), name: "main-simple")
    }

    func testProModeWithVideo() async throws {
        let model = try await loadedModel()
        model.simpleMode = false
        try await render(main(model), name: "main-pro")
    }

    func testLibraryWindow() async throws {
        let model = try await loadedModel()
        try await render(LibraryView().environmentObject(model.library), name: "library", size: CGSize(width: 900, height: 600))
    }
    func testCompareWindow() async throws {
        let model = try await loadedModel()
        try await render(CompareView().environment(model.compare).environment(model).preferredColorScheme(.dark), name: "compare")
    }
    func testEncodeMonitorWindow() async throws {
        try await render(EncodeMonitorView().environment(EncodeMonitor.shared).preferredColorScheme(.dark), name: "monitor", size: CGSize(width: 900, height: 600))
    }
    func testModelLabWindow() async throws {
        let model = try await loadedModel()
        try await render(ModelLabView().environment(model).preferredColorScheme(.dark), name: "modellab", size: CGSize(width: 1000, height: 760))
    }
    func testAirPlayWindow() async throws {
        let model = try await loadedModel()
        try await render(AirPlayPreviewView().environment(model).preferredColorScheme(.dark), name: "airplay", size: CGSize(width: 700, height: 500))
    }
    func testRegressionWindow() async throws {
        let model = try await loadedModel()
        try await render(RegressionView().environment(model).preferredColorScheme(.dark), name: "regression", size: CGSize(width: 900, height: 600))
    }
    func testOptimizeWindow() async throws {
        let model = try await loadedModel()
        try await render(OptimizeView().environment(model).preferredColorScheme(.dark), name: "optimize", size: CGSize(width: 900, height: 700))
    }
    func testLogWindow() async throws {
        try await render(LogConsoleView().environment(LogStore.shared).preferredColorScheme(.dark), name: "log", size: CGSize(width: 900, height: 600))
    }
    func testSettingsWindow() async throws {
        let model = try await loadedModel()
        try await render(SettingsView().environment(model), name: "settings", size: CGSize(width: 700, height: 600))
    }
}
