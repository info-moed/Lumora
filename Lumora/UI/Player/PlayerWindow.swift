import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Opens Player windows from places that have no SwiftUI environment (Finder's Open With, the app delegate).
@MainActor
final class PlayerLauncher {
    static let shared = PlayerLauncher()
    private var openWindow: OpenWindowAction?
    private var pending: [URL] = []

    func attach(_ action: OpenWindowAction) {
        openWindow = action
        let waiting = pending
        pending = []
        waiting.forEach { action(id: "player", value: $0) }
    }

    func open(_ url: URL) {
        if let openWindow { openWindow(id: "player", value: url) } else { pending.append(url) }
    }

    /// File → Open in Player…
    func presentOpenPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.message = "Choose a video to play"
        if p.runModal() == .OK { p.urls.forEach(open) }
    }
}

/// Finder's Open With and files dropped on the Dock icon open in the Player: opening a file from outside means
/// "watch it". The main window's Open and drag-and-drop keep the grading flow.
final class LumoraAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { PlayerLauncher.shared.open($0) } }
    }
}

struct PlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open in Player…") {
                PlayerLauncher.shared.attach(openWindow)
                PlayerLauncher.shared.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
        }
    }
}

/// A Player window: the picture, auto-hiding controls, the buffering banner and the info overlay.
struct PlayerWindow: View {
    @Binding var url: URL?
    @State private var engine: PlayerEngine
    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var dropTargeted = false
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool

    @MainActor
    init(url: Binding<URL?>, engine: PlayerEngine? = nil) {
        _url = url
        _engine = State(initialValue: engine ?? PlayerEngine())
    }

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(engine: engine)
            if engine.phase == .opening {
                ProgressView("Opening…").controlSize(.large).foregroundStyle(Theme.ink)
            }
            if let err = engine.errorMessage {
                FailureView(message: err)
            } else if url == nil && engine.info == nil {
                EmptyPlayerView()
            }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if engine.showInfo, engine.info != nil { InfoOverlay(engine: engine).transition(.opacity) }
                    Spacer()
                    if let m = engine.message {
                        Text(m).font(Theme.note).padding(8).background(.black.opacity(0.7), in: .rect(cornerRadius: 6))
                            .foregroundStyle(Theme.ink).frame(maxWidth: 420, alignment: .trailing)
                    }
                }
                .padding(12)
                Spacer()
                if engine.phase == .buffering || (engine.preDecoding && engine.bufferingReason != nil) {
                    BufferingBanner(engine: engine).padding(.bottom, 8)
                }
                if controlsVisible || !engine.isPlaying {
                    ControlBar(engine: engine).transition(.opacity)
                }
            }
            if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(Theme.signal, lineWidth: 3).padding(4) }
        }
        .background(Theme.surround)
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(engine.info?.url.lastPathComponent ?? url?.lastPathComponent ?? "Player")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onContinuousHover { _ in poke() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            url = u
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            PlayerLauncher.shared.attach(openWindow)
            focused = true
            if let url { engine.open(url) }
        }
        .onChange(of: url) { _, new in if let new { engine.open(new) } }
        .onDisappear { engine.stop() }
        .task {
            // Hide the controls after three idle seconds while playing.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if engine.isPlaying && Date().timeIntervalSince(lastActivity) > 3 {
                    withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
                }
            }
        }
    }

    private func poke() {
        lastActivity = Date()
        if !controlsVisible { withAnimation(.easeIn(duration: 0.15)) { controlsVisible = true } }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        poke()
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .space: engine.togglePlay()
        case .leftArrow: shift ? engine.stepSeconds(-1) : engine.step(-1)
        case .rightArrow: shift ? engine.stepSeconds(1) : engine.step(1)
        case .upArrow: engine.volume = min(1, engine.volume + 0.1)
        case .downArrow: engine.volume = max(0, engine.volume - 0.1)
        case .home: engine.seek(toFrame: 0)
        case .end: engine.seek(toFrame: engine.frameCount - 1)
        case .escape:
            if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) } else { return .ignored }
        default:
            let c = press.characters.lowercased()
            if press.modifiers.contains(.command) {
                if c == "l" { engine.loop.toggle(); return .handled }
                if c == "f" && press.modifiers.contains(.control) { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
                return .ignored
            }
            switch c {
            case "j", "k", "l": engine.jkl(Character(c))
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "i": withAnimation { engine.showInfo.toggle() }
            default: return .ignored
            }
        }
        return .handled
    }
}

private struct EmptyPlayerView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle").font(.system(size: 44)).foregroundStyle(Theme.inkSecondary)
            Text("Drop a video here").font(Theme.heading(15)).foregroundStyle(Theme.ink)
            Text("or choose File → Open in Player… (⌥⌘O). AV2, H.266, AV1, HEVC, H.264, ProRes, VP9 and more, with HDR.")
                .font(Theme.note).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }
}

private struct FailureView: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(Theme.marginal)
            Text("Can't play this file").font(Theme.heading(15)).foregroundStyle(Theme.ink)
            Text(message).font(Theme.body).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: 520)
        }
        .padding(24)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 10))
    }
}

/// Pre-decode / buffering status: why, how far, and when playback starts.
struct BufferingBanner: View {
    let engine: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.bufferingReason ?? "Buffering…").font(Theme.body).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                ProgressView(value: engine.bufferingProgress).frame(width: 260)
                if let eta = engine.bufferingETA, eta.isFinite {
                    Text("playback starts in \(PlayerEngine.timecode(eta))").font(Theme.note.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 8))
    }
}

/// Transport controls.
struct ControlBar: View {
    @Bindable var engine: PlayerEngine
    @State private var frameText = ""
    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 6) {
            Scrubber(engine: engine, value: Binding(get: { scrubbing ? scrubValue : Double(engine.currentIndex) },
                                                    set: { scrubValue = $0 }),
                     scrubbing: $scrubbing)
            HStack(spacing: 12) {
                Button { engine.step(-1) } label: { Image(systemName: "backward.frame") }.help("Previous frame (←)")
                Button { engine.togglePlay() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help("Play / pause (space)")
                Button { engine.step(1) } label: { Image(systemName: "forward.frame") }.help("Next frame (→)")
                if engine.rate != 1 { Text("\(Int(engine.rate))×").font(Theme.note.monospacedDigit()).foregroundStyle(Theme.signal) }
                if engine.reversing { Text("◀︎ reverse").font(Theme.note).foregroundStyle(Theme.signal) }
                Text("\(PlayerEngine.timecode(engine.currentTime)) / \(PlayerEngine.timecode(engine.duration))")
                    .font(Theme.note.monospacedDigit()).foregroundStyle(Theme.ink)
                TextField("frame", text: $frameText)
                    .textFieldStyle(.roundedBorder).frame(width: 74).font(Theme.note.monospacedDigit())
                    .onSubmit { if let n = Int(frameText.trimmingCharacters(in: .whitespaces)) { engine.seek(toFrame: n) }; frameText = "" }
                    .help("Frame \(engine.currentIndex) of \(engine.frameCount): type a frame number to jump there")
                Text("#\(engine.currentIndex)").font(Theme.note.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Toggle(isOn: $engine.loop) { Image(systemName: "repeat") }.toggleStyle(.button).help("Loop (⌘L)")
                if let info = engine.info {
                    if info.audio.count > 1 {
                        Picker("Audio", selection: $engine.audioTrack) {
                            ForEach(info.audio) { Text($0.label).tag($0.index) }
                        }
                        .frame(width: 170).labelsHidden()
                    }
                    if !info.audio.isEmpty {
                        Image(systemName: engine.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(Theme.inkSecondary)
                        Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.volume = Float($0) }), in: 0...1).frame(width: 80)
                    }
                    Picker("Interpret as", selection: $engine.interpret) {
                        ForEach(InterpretMode.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 150)
                    .help("How to read the signal: Auto follows the file's tags")
                    if info.isRawElementaryStream || !info.frameRateKnown {
                        Menu("\(MediaProbe.formatRate(info.fps)) fps") {
                            ForEach([(24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1)], id: \.0) { r in
                                Button(MediaProbe.formatRate(Double(r.0) / Double(r.1))) { engine.setFrameRate(r.0, r.1) }
                            }
                        }
                        .frame(width: 90)
                        .help("This stream carries no frame rate; pick the right one")
                    }
                }
                Button { withAnimation { engine.showInfo.toggle() } } label: { Image(systemName: "info.circle") }.help("Info (I)")
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Full screen (F)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }
}

/// The timeline: playhead, cached ranges (pre-decode) and key-frame ticks.
struct Scrubber: View {
    let engine: PlayerEngine
    @Binding var value: Double
    @Binding var scrubbing: Bool

    var body: some View {
        GeometryReader { g in
            let n = Double(max(1, engine.frameCount - 1))
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                ForEach(Array(engine.cachedRanges.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Theme.signal.opacity(0.45))
                        .frame(width: max(1, CGFloat(Double(r.count) / n) * w), height: 4)
                        .offset(x: CGFloat(Double(r.lowerBound) / n) * w)
                }
                if engine.keyFrames.count > 1 && engine.keyFrames.count < 400 {
                    ForEach(engine.keyFrames, id: \.self) { k in
                        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 8)
                            .offset(x: CGFloat(Double(k) / n) * w)
                    }
                }
                Capsule().fill(Theme.signal).frame(width: max(0, CGFloat(value / n) * w), height: 4)
                Circle().fill(Theme.ink).frame(width: 12, height: 12).offset(x: CGFloat(value / n) * w - 6)
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    scrubbing = true
                    value = max(0, min(n, Double(d.location.x / max(1, w)) * n)).rounded()
                }
                .onEnded { _ in
                    engine.seek(toFrame: Int(value))
                    scrubbing = false
                })
        }
        .frame(height: 16)
    }
}

/// Everything about what is playing and how: codec, decoder, signal, HDR metadata, tone mapping, live stats.
struct InfoOverlay: View {
    let engine: PlayerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(Self.rows(engine).enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 8) {
                    Text(r.0).foregroundStyle(Theme.inkSecondary).frame(width: 96, alignment: .leading)
                    Text(r.1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.ink)
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 8))
        .textSelection(.enabled)
    }

    /// The overlay's rows (label, value), also what the UI tests check.
    @MainActor
    static func rows(_ engine: PlayerEngine) -> [(String, String)] {
        guard let info = engine.info else { return [] }
        let v = info.video
        let c = v.color
        func tag(_ tagged: Bool) -> String { tagged ? "" : " (guessed)" }
        var r: [(String, String)] = []
        r.append(("File", info.url.lastPathComponent))
        r.append(("Codec", v.codec.description + (v.profile.map { " (\($0))" } ?? "") + " · \(info.container)"))
        if let ch = engine.choice {
            r.append(("Decoder", "\(ch.tool) · \(ch.hardware ? "hardware" : "software")"))
            r.append(("", ch.reason))
        }
        if let note = engine.decoderNote { r.append(("", note)) }
        r.append(("Picture", "\(v.width)×\(v.height)" + (v.sarNum != v.sarDen ? " (SAR \(v.sarNum):\(v.sarDen))" : "")
            + " · \(MediaProbe.formatRate(info.fps)) fps\(info.frameRateKnown ? "" : " (assumed)") · \(v.bitDepth)-bit \(v.chroma)"))
        r.append(("Chroma siting", c.chromaLocation.description + tag(c.chromaLocationTagged)))
        r.append(("Transfer", (engine.interpret == .auto ? c.transferName : "\(engine.interpret.label) (override)") + tag(c.transferTagged)))
        r.append(("Primaries", c.primariesName + tag(c.primariesTagged)))
        r.append(("Matrix", c.matrixName + tag(c.matrixTagged)))
        r.append(("Range", (c.fullRange ? "full" : "limited") + tag(c.rangeTagged)))
        r.append(("HDR metadata", hdrText(engine, info)))
        if let t = engine.toneMap {
            r.append(("Tone mapping", t.mapping))
            r.append(("", "content \(Int(t.sourcePeak)) nits (\(t.peakSource)) · display \(Int(t.displayPeak)) nits = headroom × \(Int(t.referenceWhite))"))
        }
        for n in info.notes { r.append(("Note", n)) }
        let s = engine.stats
        r.append(("Frames", "shown \(s.shown) · dropped \(s.dropped) · late \(s.late)"))
        r.append(("Decode", s.decodeFPS > 0 ? String(format: "%.1f fps (%.2f× real time)", s.decodeFPS, s.realTimeFactor) : "measuring…"))
        r.append(("Queue", "\(s.queueDepth) / \(s.queueCapacity) frames" + (s.cacheBytes > 0 ? " · cache \(ByteCountFormatter.string(fromByteCount: s.cacheBytes, countStyle: .file))" : "")))
        r.append(("Audio", info.audio.isEmpty ? "none (silent)" : (engine.audioActive ? "clock source · " : "") + info.audio[min(engine.audioTrack, info.audio.count - 1)].label))
        return r
    }

    @MainActor
    private static func hdrText(_ engine: PlayerEngine, _ info: MediaInfo) -> String {
        let h = info.video.hdr
        var parts: [String] = []
        if let m = h?.mdcvMaxNits { parts.append("MDCV \(Int(m))" + (h?.mdcvMinNits.map { String(format: "/%.4f", $0) } ?? "") + " nits") }
        if let c = h?.maxCLL { parts.append("MaxCLL \(Int(c))") }
        if let f = h?.maxFALL { parts.append("MaxFALL \(Int(f))") }
        if parts.isEmpty {
            if !info.video.color.isHDR && engine.interpret != .pq { return "none (SDR)" }
            if let p = info.manifestPeakNits { return "none in the stream; Lumora's export record says \(Int(p)) nits" }
            return "none, assuming \(Int(engine.settings.assumedPeak)) nits"
        }
        return parts.joined(separator: " · ")
    }
}

/// Settings → Player.
struct PlayerSettingsView: View {
    @State private var s = PlayerSettings.current
    @State private var cacheBytes: Int64 = PreDecodeCache.totalBytes

    var body: some View {
        Form {
            Section("HDR") {
                Picker("Tone mapping", selection: $s.toneMapping) { ForEach(PlayerSettings.ToneMapping.allCases) { Text($0.label).tag($0) } }
                Text("Lumora maps HDR to the display's current headroom with the BT.2390 curve. macOS passes the PQ or HLG signal through and lets the system tone map, for comparison.")
                    .font(Theme.note).foregroundStyle(.secondary)
                Picker("SDR reference white", selection: $s.referenceWhite) {
                    Text("100 nits (Apple EDR convention)").tag(Float(100))
                    Text("203 nits (BT.2408)").tag(Float(203))
                }
                Picker("Assume untagged HDR peaks at", selection: $s.assumedPeak) {
                    ForEach([Float(1000), 2000, 4000, 10_000], id: \.self) { Text("\(Int($0)) nits").tag($0) }
                }
                Text("Used for AV2 (which can't carry mastering metadata) and for HDR files without MaxCLL or mastering display data. Lumora's own exports record their peak.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Section("Decoding") {
                Toggle("Prefer hardware decoding", isOn: $s.preferHardware)
                Stepper("RAM for decoded frames: \(s.bufferBudgetMB) MB", value: $s.bufferBudgetMB, in: 128...8192, step: 128)
                Stepper("Parallel pre-decoders: \(s.parallelDecoders)", value: $s.parallelDecoders, in: 1...8)
                Toggle("AV2: skip film grain synthesis", isOn: $s.skipFilmGrain)
            }
            Section("Pre-decode cache (slow decoders such as AV2)") {
                Stepper("At most \(Int(s.cacheCapGB)) GB per file", value: $s.cacheCapGB, in: 2...200, step: 2)
                LabeledContent("Location", value: PreDecodeCache.root.path.displayPath)
                LabeledContent("In use", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                Text("Never more than a quarter of the free space or 40 GB in all, and never below 10 GB free. It follows the scratch drive (Settings → Storage).")
                    .font(Theme.note).foregroundStyle(.secondary)
                Button("Clear player cache") { PreDecodeCache.clearAll(); cacheBytes = PreDecodeCache.totalBytes }
            }
        }
        .formStyle(.grouped)
        .onChange(of: s) { _, new in new.save() }
    }
}
