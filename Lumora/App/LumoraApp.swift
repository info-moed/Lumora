import SwiftUI
import AppKit

/// Entry point. Under XCTest the app is only a test host: it runs headless (no windows, no Dock icon,
/// no focus change) so `xcodebuild test` never disturbs whoever is using the Mac.
@main
enum LumoraMain {
    static func main() {
        // An encoder that exits early must not take the app down with SIGPIPE; writes throw instead.
        signal(SIGPIPE, SIG_IGN)
        ToolProbe.warmUp()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            LumoraApp.main()
        }
    }
}

struct LumoraApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(LumoraAppDelegate.self) private var appDelegate

    init() {
        Log.notice(.app, "Lumora started on \(ChipProfile.current.description), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        try? FileManager.default.createDirectory(at: InterpolationModelSpec.modelsFolder, withIntermediateDirectories: true)
        // Player pre-decode caches untouched for a week, or whose source changed, go at launch.
        DispatchQueue.global(qos: .utility).async { PreDecodeCache.cleanup() }
    }

    var body: some Scene {
        WindowGroup("Lumora") {
            ContentView()
                .environment(model)
                .environment(EncodeMonitor.shared)
                .environment(TaskCenter.shared)
                .frame(minWidth: 1280, minHeight: 800)
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
            }
            PlayerCommands()
        }
        WindowGroup("Player", id: "player", for: URL.self) { $url in
            PlayerWindow(url: $url)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        Window("UHD HDR Library", id: "library") {
            LibraryView().environmentObject(model.library)
        }
        Window("Compare: original vs interpolated", id: "compare") {
            CompareView()
                .environment(model.compare)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        Window("Encode monitor", id: "monitor") {
            EncodeMonitorView().environment(EncodeMonitor.shared).preferredColorScheme(.dark)
        }
        Window("Model Lab", id: "models") {
            ModelLabView().environment(model).preferredColorScheme(.dark)
        }
        Window("Preview on your TV", id: "airplay") {
            AirPlayPreviewView().environment(model).preferredColorScheme(.dark)
        }
        Window("Picture regression set", id: "regression") {
            RegressionView().environment(model).preferredColorScheme(.dark)
        }
        Window("Optimize for this Mac", id: "optimize") {
            OptimizeView().environment(model).preferredColorScheme(.dark)
        }
        Window("Log", id: "logs") {
            LogConsoleView().environment(LogStore.shared).preferredColorScheme(.dark)
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}
