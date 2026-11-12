import SwiftUI

@main
struct LumoraApp: App {
    @State private var model = AppModel()

    init() {
        // An encoder that exits early must not take the app down with SIGPIPE; writes throw instead.
        signal(SIGPIPE, SIG_IGN)
        Log.notice(.app, "Lumora started on \(ChipProfile.current.description), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        try? FileManager.default.createDirectory(at: InterpolationModelSpec.modelsFolder, withIntermediateDirectories: true)
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
        }
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
