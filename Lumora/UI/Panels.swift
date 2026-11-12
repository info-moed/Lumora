import SwiftUI
import Charts
import AppKit

/// Toolbar button: a progress ring while anything runs; opens the full activity list.
struct ActivityButton: View {
    @Environment(TaskCenter.self) private var center
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            if let t = center.active.first, let p = t.progress {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
            } else if !center.active.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checklist")
            }
        }
        .help("Activity")
        .popover(isPresented: $shown, arrowEdge: .bottom) { ActivityView().frame(width: 420, height: 380) }
    }
}

struct ActivityView: View {
    @Environment(TaskCenter.self) private var center

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(Theme.heading(14))
                Spacer()
                Button("Clear finished") { center.clearFinished() }.buttonStyle(.link)
            }
            .padding(14)
            Divider()
            if center.tasks.isEmpty {
                Text("Nothing running.").font(Theme.body).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(center.tasks) { t in TaskRow(task: t) }
                    }
                }
            }
        }
    }
}

struct TaskRow: View {
    let task: TrackedTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: task.symbol).foregroundStyle(.secondary).frame(width: 18)
                Text(task.title).font(Theme.body).lineLimit(1)
                Spacer()
                switch task.state {
                case .running:
                    if let cancel = task.onCancel { Button("Stop") { cancel() }.buttonStyle(.link) }
                case .finished: Image(systemName: "checkmark").foregroundStyle(Theme.pass)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.fail)
                case .canceled: Text("Stopped").font(Theme.note).foregroundStyle(.secondary)
                }
            }
            if task.state == .running {
                if let p = task.progress { ProgressView(value: p).controlSize(.small) } else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
            }
            HStack {
                Text(task.detail).font(Theme.note).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let r = task.rate { Text(r).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary) }
                if let e = task.eta { Text(e).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if case .failed(let m) = task.state { Text(m).font(Theme.note).foregroundStyle(Theme.fail).lineLimit(3) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct LogConsoleView: View {
    @Environment(LogStore.self) private var store
    @State private var minLevel: LogLevel = .info
    @State private var category: LogCategory?
    @State private var search = ""
    @State private var follow = true

    private var filtered: [LogEntry] {
        store.entries.filter { e in
            e.level >= minLevel && (category == nil || e.category == category)
                && (search.isEmpty || e.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Level", selection: $minLevel) { ForEach(LogLevel.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .frame(width: 150)
                Picker("Area", selection: $category) {
                    Text("Everything").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(LogCategory?.some($0)) }
                }
                .frame(width: 180)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Verbose", isOn: $store.verbose)
                Toggle("Follow", isOn: $follow)
                Spacer()
                Button("Open log folder") { NSWorkspace.shared.open(Log.logFolder) }
                Button("Export…") {
                    let p = NSSavePanel()
                    p.nameFieldStringValue = "Lumora log.txt"
                    if p.runModal() == .OK, let u = p.url { try? store.export(to: u) }
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(filtered) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.date, format: .dateTime.hour().minute().second()).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                        StatusDot(color: e.level >= .error ? Theme.fail : (e.level == .warning ? Theme.marginal : (e.level == .notice ? Theme.signal : .secondary.opacity(0.5))))
                        Text(e.category.rawValue).font(Theme.note).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                        Text(e.message).font(Theme.body).textSelection(.enabled)
                    }
                    .id(e.id)
                }
                .onChange(of: store.entries.count) {
                    if follow, let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 420)
    }
}

/// Live view of a target-VMAF encode: per-frame score against the target, and every chunk's state.
struct EncodeMonitorView: View {
    @Environment(EncodeMonitor.self) private var monitor

    struct Point: Identifiable { let id: Int; let score: Double }

    var body: some View {
        let target = monitor.target?.vmaf ?? 95
        let points = monitor.frameScores.sorted { $0.key < $1.key }.map { Point(id: $0.key, score: $0.value) }
        let done = monitor.chunks.filter { $0.state == .done }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 26) {
                Metric(value: String(format: "%.1f", target), caption: "target VMAF")
                Metric(value: points.isEmpty ? "–" : String(format: "%.2f", points.map(\.score).reduce(0, +) / Double(points.count)),
                       caption: "average so far")
                Metric(value: points.map(\.score).min().map { String(format: "%.1f", $0) } ?? "–", caption: "worst frame",
                       color: points.map(\.score).min().map { Theme.vmafColor($0, target: target) } ?? .primary)
                Metric(value: "\(done)/\(monitor.chunks.count)", caption: "chunks done")
                Metric(value: ByteCountFormatter.string(fromByteCount: monitor.encodedBytes, countStyle: .file), caption: "written")
                if let p = monitor.projectedBytes {
                    Metric(value: SizeForecast.gb(p), caption: monitor.forecast.map { "projected (forecast \(SizeForecast.gb($0.mid)))" } ?? "projected final size")
                }
                Spacer()
            }
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Frame", p.id), y: .value("VMAF", p.score)).interpolationMethod(.linear)
                        .foregroundStyle(Theme.signal)
                }
                RuleMark(y: .value("Target", target)).foregroundStyle(Theme.pass).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                if let m = monitor.target?.floorMargin {
                    RuleMark(y: .value("Floor", target - m)).foregroundStyle(Theme.marginal.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            .chartYScale(domain: max(60, (points.map(\.score).min() ?? 80) - 2)...100)
            .chartXAxisLabel("Output frame")
            .frame(height: 220)
            Text("Chunks").font(Theme.heading())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(monitor.chunks) { c in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                StatusDot(color: c.state == .done ? Theme.vmafColor(c.vmafLow ?? c.vmafMean ?? 0, target: target)
                                          : (c.state == .waiting ? .secondary.opacity(0.4) : Theme.signal))
                                Text("Frames \(c.range.lowerBound)–\(c.range.upperBound - 1)").font(Theme.note.monospacedDigit())
                            }
                            Text(c.state.rawValue + (c.trials > 0 ? ", \(c.trials) trial\(c.trials == 1 ? "" : "s")" : "")).font(Theme.note).foregroundStyle(.secondary)
                            if let v = c.vmafMean {
                                Text(String(format: "VMAF %.2f, low %.2f, %@", v, c.vmafLow ?? v, c.setting)).font(Theme.note.monospacedDigit())
                            }
                            ForEach(c.metrics.filter { $0.key != "vmaf" }.sorted { $0.key < $1.key }, id: \.key) { k, v in
                                Text("\(QualityMetric(rawValue: k)?.displayName ?? k) \(String(format: "%.2f", v))")
                                    .font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if !c.failures.isEmpty {
                                Text("Raised quality: " + c.failures.joined(separator: "; ")).font(Theme.note).foregroundStyle(Theme.marginal).lineLimit(2)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            let counts = QualityPredictor.shared.sampleCounts
            if !counts.isEmpty {
                Text("Learned from \(counts.values.reduce(0, +)) past chunks: " + counts.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
                    .font(Theme.note).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct ModelLabView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var lab = ModelLab.shared
    @State private var message: String?
    @State private var confirmConvert: RIFERelease?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model Lab").font(Theme.heading(20))
                Spacer()
                if lab.environmentReady {
                    Label("Converter ready", systemImage: "checkmark.circle").font(Theme.note).foregroundStyle(Theme.pass)
                } else {
                    Button("Set up converter (Python, PyTorch, coremltools)") { act { try await lab.prepareEnvironment() } }
                }
            }
            Text("Every RIFE release is converted twice: an image model, and an HDR flow model that keeps the full 10/12-bit precision of your footage. Benchmark them on real frames from your own video; the winner is remembered for each content type.")
                .font(Theme.body).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading)
            Table(lab.catalog) {
                TableColumn("Version") { r in Text("RIFE \(r.id)").font(Theme.body.weight(.medium)) }.width(110)
                TableColumn("Released") { r in Text(r.released).font(Theme.note) }.width(80)
                TableColumn("Notes") { r in Text(r.notes).font(Theme.note).lineLimit(3) }
                TableColumn("Status") { r in statusView(r) }.width(150)
                TableColumn("") { r in actions(r) }.width(190)
            }
            .frame(minHeight: 320)
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your best model per content type").font(Theme.heading())
                    ForEach(ContentKind.allCases) { k in
                        HStack {
                            Label(k.displayName, systemImage: k.symbol).font(Theme.body).frame(width: 230, alignment: .leading)
                            Text(lab.bestModel(for: k).flatMap { id in InterpolationModelSpec.all().first { $0.id == id }?.displayName } ?? "—")
                                .font(Theme.body).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Benchmark").font(Theme.heading())
                    Text("Removes real frames from the open video, rebuilds them with every installed model, and records the winner for \(app.contentKind.displayName.lowercased()).")
                        .font(Theme.note).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .leading)
                    Button("Benchmark on the open video") {
                        app.prepareCompare()
                        let kind = app.contentKind
                        app.compare.runBenchmark { _, sensitivity in
                            if let bm = app.compare.benchmark { lab.record(benchmark: bm, for: kind) }
                            app.interpolation.sensitivity = sensitivity
                            app.applyTuning()
                        }
                        openWindow(id: "compare")
                    }
                    .disabled(app.descriptor == nil)
                }
            }
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quality metrics").font(Theme.heading())
                    ForEach(QualityMetric.allCases) { m in
                        HStack {
                            StatusDot(color: m.isAvailable ? Theme.pass : Theme.fail)
                            Text(m.displayName).font(Theme.body).frame(width: 140, alignment: .leading)
                            Text(m.isAvailable ? "ready" : m.source).font(Theme.note).foregroundStyle(.secondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button("Install ColorVideoVDP and PU21 metrics") { act { try await lab.installMetrics() } }
                    Button("Get AVQT (Apple developer download)…") {
                        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/videos/play/wwdc2022/10149/")!)
                    }
                    Text("libvmaf (VMAF, VMAF NEG, CAMBI, MS-SSIM, PSNR-HVS, CIEDE2000): brew install libvmaf\nXPSNR: FFmpeg 7 or newer\nSSIMULACRA 2: cargo install ssimulacra2_rs")
                        .font(Theme.note).foregroundStyle(.secondary)
                }
            }
            if let message { Text(message).font(Theme.note).foregroundStyle(Theme.fail) }
        }
        .padding(18)
        .frame(minWidth: 940, minHeight: 760)
        .onAppear { lab.refresh() }
        .alert("Run code from this download?",
               isPresented: Binding(get: { confirmConvert != nil }, set: { if !$0 { confirmConvert = nil } }),
               presenting: confirmConvert) { r in
            Button("Convert anyway") { act { try await lab.convert(r) } }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("Converting RIFE \(r.id) runs the Python model code inside its archive on this Mac. This file doesn't match a published checksum (it was imported by hand, or the release has no pinned checksum), so only continue if you trust where it came from.\n\nSHA-256: \(lab.provenance(r)?.sha256 ?? "unknown")")
        }
    }

    @ViewBuilder private func statusView(_ r: RIFERelease) -> some View {
        switch lab.status[r.id] ?? .notDownloaded {
        case .notDownloaded: Text("Not downloaded").font(Theme.note).foregroundStyle(.secondary)
        case .downloaded: Label("Downloaded", systemImage: "arrow.down.circle").font(Theme.note)
        case .converted: Label("Ready (image + HDR)", systemImage: "checkmark.circle").font(Theme.note).foregroundStyle(Theme.pass)
        case .working(let s): HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(s).font(Theme.note) }
        }
    }

    @ViewBuilder private func actions(_ r: RIFERelease) -> some View {
        HStack(spacing: 6) {
            switch lab.status[r.id] ?? .notDownloaded {
            case .notDownloaded:
                if r.url != nil { Button("Download") { act { try await lab.download(r) } } }
                else { Button("Get…") { NSWorkspace.shared.open(r.sourcePage) } }
                Button("Import…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.zip]
                    if p.runModal() == .OK, let u = p.url { try? lab.importZip(u, for: r) }
                }
            case .downloaded:
                Button("Convert") { convert(r) }.disabled(!lab.environmentReady)
            case .converted:
                Button("Reconvert") { convert(r) }.disabled(!lab.environmentReady)
            case .working:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    /// Pinned, verified downloads convert straight away; anything else asks first (it runs code from the archive).
    private func convert(_ r: RIFERelease) {
        if lab.provenance(r)?.verified == true { act { try await lab.convert(r) } } else { confirmConvert = r }
    }

    private func act(_ f: @escaping () async throws -> Void) {
        message = nil
        Task { do { try await f() } catch { message = error.localizedDescription } }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            StorageSettings().tabItem { Label("Storage", systemImage: "externaldrive") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "hammer") }
            RunRulesSettings().tabItem { Label("Runs & Library", systemImage: "moon.stars") }
        }
        .frame(width: 660, height: 520)
    }
}

struct StorageSettings: View {
    @State private var scratch = ScratchManager.shared
    @State private var speed: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Scratch drive (all temporary and intermediate writes)") {
                LabeledContent("Folder", value: scratch.root.path.displayPath)
                if let v = scratch.volume {
                    LabeledContent("Drive", value: "\(v.name), \(v.kindDescription)")
                    LabeledContent("Free", value: ByteCountFormatter.string(fromByteCount: v.freeBytes, countStyle: .file))
                }
                if let speed { LabeledContent("Measured", value: speed) }
                HStack {
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { scratch.root = u.appendingPathComponent("Lumora Scratch") ; try? FileManager.default.createDirectory(at: scratch.root, withIntermediateDirectories: true) }
                    }
                    Button("Test speed") {
                        let root = scratch.root
                        Task.detached {
                            let w = StorageInspector.measureWrite(root)
                            await MainActor.run { speed = w.map { String(format: "%.0f MB/s write", $0) } ?? "Couldn't measure" }
                        }
                    }
                    Button("Empty scratch") { scratch.purgeAll() }
                }
                Text("Pick your fastest Thunderbolt 4/5 or internal SSD. Sources on slow drives are read once, in order; nothing is written back to them.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Section("Slow source drives") {
                Toggle("Copy files to the scratch SSD when the drive is too slow to stream them", isOn: $app.autoStage)
                Text("Otherwise Lumora streams with read-ahead and builds a small preview proxy on the SSD for smooth scrubbing.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    let tools = ["ffmpeg", "ffprobe", "vmaf", "SvtAv1EncApp", "aomenc", "x265", "vvencapp", "avmenc",
                 "dovi_tool", "hdr10plus_tool", "MP4Box", "mkvmerge"]
    var body: some View {
        Form {
            Section("Helper tools") {
                ForEach(tools, id: \.self) { t in
                    HStack {
                        StatusDot(color: ToolLocator.isAvailable(t) ? Theme.pass : Theme.fail)
                        Text(t).font(Theme.body)
                        Spacer()
                        Text(ToolLocator.url(for: t)?.path.displayPath ?? "not found").font(Theme.note).foregroundStyle(.secondary)
                    }
                }
            }
            Section("VMAF") {
                Text(VMAFRunner.available ? "VMAF scoring is available." : "Install with: brew install libvmaf").font(Theme.body)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Optimize for this Mac": live CPU/GPU/memory/thermal gauges while the tests push every part of the chip.
struct OptimizeView: View {
    @Environment(AppModel.self) private var app
    @State private var optimizer = MacOptimizer.shared
    @State private var monitor = SystemMonitor.shared
    @State private var level: MacOptimizer.Level = .thorough

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Optimize for this Mac").font(Theme.heading(20))
                Spacer()
                Text(ChipProfile.current.description).font(Theme.note).foregroundStyle(.secondary)
            }
            Text("Measures what this machine is actually best at: GPU threadgroup shapes, where each neural model runs fastest, how many hardware encodes run in parallel, how many software encoders keep every core busy, how much memory to use, and how fast it stays when hot. Nothing is assumed from the chip's name, so the same tests tune an M5, an M5 Ultra, or whatever comes next.")
                .font(Theme.body).foregroundStyle(.secondary).frame(maxWidth: 760, alignment: .leading)
            HStack(spacing: 28) {
                gauge("CPU", monitor.cpu)
                gauge("GPU", monitor.gpu ?? 0, note: monitor.gpu == nil ? "n/a" : nil)
                gauge("Memory", monitor.memory)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.thermalText).font(Theme.figure(18))
                        .foregroundStyle(monitor.thermal == .nominal ? Theme.pass : (monitor.thermal == .fair ? Theme.marginal : Theme.fail))
                    Text("thermal").font(Theme.note).foregroundStyle(.secondary)
                }
            }
            HStack {
                Picker("Depth", selection: $level) { ForEach(MacOptimizer.Level.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(width: 300)
                if optimizer.running {
                    Button("Stop") { optimizer.stop() }
                } else {
                    Button("Start") { optimizer.start(level, footage: app) }.buttonStyle(.borderedProminent)
                }
                if level == .burnIn {
                    Text(app.analysis == nil ? "Open a film first to also calibrate encoders and interpolation on it." : "Includes encoder calibration and interpolation benchmarks on the open film.")
                        .font(Theme.note).foregroundStyle(.secondary)
                }
                Spacer()
                if MacProfile.current != nil && !optimizer.running {
                    Button("Forget profile") { MacProfile.reset(); optimizer.summary = [] }.buttonStyle(.link)
                }
            }
            VStack(spacing: 0) {
                ForEach(optimizer.steps) { s in
                    HStack(alignment: .top) {
                        Image(systemName: s.state == "Done" ? "checkmark.circle.fill" : (s.state == "Running" ? "circle.dotted" : "circle"))
                            .foregroundStyle(s.state == "Done" ? Theme.pass : (s.state == "Running" ? Theme.signal : .secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(Theme.body.weight(.medium))
                            if !s.result.isEmpty { Text(s.result).font(Theme.note).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if s.state == "Running" { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }
            if !optimizer.summary.isEmpty && optimizer.steps.isEmpty {
                Text("Current profile").font(Theme.heading())
                ForEach(optimizer.summary, id: \.self) { Text($0).font(Theme.note).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 620)
        .onAppear { monitor.start() }
    }

    private func gauge(_ title: String, _ value: Double, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note ?? "\(Int(value * 100))%").font(Theme.figure(18))
            ProgressView(value: min(1, max(0, value))).frame(width: 120).tint(value > 0.85 ? Theme.signal : .secondary)
            Text(title).font(Theme.note).foregroundStyle(.secondary)
        }
    }
}

/// Shown until this Mac has a profile.
struct OptimizeBanner: View {
    @Environment(\.openWindow) private var openWindow
    @State private var dismissed = UserDefaults.standard.bool(forKey: "optimizeBannerDismissed")

    var body: some View {
        if MacProfile.current == nil && !dismissed {
            HStack(spacing: 10) {
                Image(systemName: "speedometer").foregroundStyle(Theme.signal)
                Text("Lumora hasn't been tuned for this Mac yet. A 30-minute optimization measures GPU, neural, media-engine and CPU performance and bakes the best settings in.")
                    .font(Theme.note)
                Spacer()
                Button("Optimize…") { openWindow(id: "optimize") }.controlSize(.small)
                Button { dismissed = true; UserDefaults.standard.set(true, forKey: "optimizeBannerDismissed") } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(Theme.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
