import SwiftUI
import AppKit

/// The Encode monitor window: the live render panel above the existing target-quality monitor.
struct EncodeMonitorWindow: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LoadBanner(insets: EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))
                LiveRenderPanel()
                Divider()
                EncodeMonitorView()
            }
        }
        .environment(RenderMonitor.shared)
        .frame(minWidth: 980, minHeight: 640)
    }
}

/// Always-visible render status for the main window toolbar; opens the monitor.
struct RenderStatusPill: View {
    @Environment(\.openWindow) private var openWindow
    private var monitor: RenderMonitor { RenderMonitor.shared }

    var body: some View {
        if let s = monitor.current, !s.ended {
            Button { openWindow(id: "monitor") } label: {
                HStack(spacing: 6) {
                    Pill(status: s.status, heartbeat: s.heartbeat, compact: true)
                    Text("\(Int((s.fraction * 100).rounded(.down)))%").font(Theme.note.monospacedDigit())
                }
            }
            .help("\(s.status.text). \(s.verdict.sentence) Click for the live render monitor.")
        }
    }

    /// Status dot and words: Rendering live / Paused / Waiting on … / Stalled, with the heartbeat.
    struct Pill: View {
        let status: RunStatus
        var heartbeat: Double?
        var compact = false
        @State private var pulse = false

        var color: Color {
            switch status {
            case .rendering, .starting: return Theme.pass
            case .paused: return Theme.marginal
            case .waiting, .finishing, .preparing: return Theme.signal
            case .stalled: return Theme.fail
            case .done: return .secondary
            }
        }

        var body: some View {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(status == .rendering ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                    .onAppear { pulse = status == .rendering }
                    .onChange(of: status) { _, s in pulse = s == .rendering }
                Text(compact ? short : status.text).font(compact ? Theme.note : Theme.body.weight(.medium)).lineLimit(1)
                if !compact, let h = heartbeat, status != .done {
                    Text(h < 2 ? "last frame just now" : "last frame \(RenderSummary.duration(h)) ago")
                        .font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, compact ? 0 : 10).padding(.vertical, compact ? 0 : 5)
            .background(compact ? Color.clear : color.opacity(0.14), in: Capsule())
        }

        private var short: String {
            switch status {
            case .rendering: return "Rendering"
            case .starting: return "Starting"
            case .paused: return "Paused"
            case .waiting: return "Waiting"
            case .stalled: return "Stalled"
            case .finishing: return "Finishing"
            case .preparing: return "Preparing"
            case .done: return "Done"
            }
        }
    }
}

/// "Your Mac is overloaded": plain words, the busiest other apps (names only), and the person's choice.
struct LoadBanner: View {
    var insets = EdgeInsets()
    private var monitor: RenderMonitor { RenderMonitor.shared }

    var body: some View {
        let g = monitor.governor
        if let reason = g.diskPause {
            banner(icon: "externaldrive.badge.exclamationmark", color: Theme.fail, title: reason,
                   detail: "The render is paused safely and continues on its own once there is space. Clear Lumora's caches from the Export window, or free space on the drive.") { EmptyView() }
        } else if let reason = g.memoryPause {
            banner(icon: "memorychip", color: Theme.fail, title: reason,
                   detail: "Close apps that use a lot of memory; the render continues on its own when memory recovers.") { EmptyView() }
        } else if g.userChoice == .paused {
            banner(icon: "pause.circle", color: Theme.marginal, title: "Paused so other apps can run",
                   detail: "No work is lost.") {
                Button("Resume") { monitor.resumeNormal() }
            }
        } else if monitor.isRendering, let o = monitor.overload {   // only a running export can act on it
            banner(icon: "gauge.with.dots.needle.100percent", color: Theme.marginal, title: "Your Mac is overloaded",
                   detail: o.reasons.joined(separator: ". ") + ". " + appsLine(o)) {
                Button("Pause") { monitor.pauseForOthers() }
                Button("Lower priority") { monitor.lowerPriority() }
                    .help("Lumora's encoders run in the background band and Lumora rests between frames. On a busy Mac this can make the export much slower.")
                Button("Continue") { monitor.continueAnyway() }
            }
        } else if g.userChoice == .lowerPriority {
            banner(icon: "tortoise", color: Theme.signal, title: "Running at lower priority",
                   detail: "Other apps go first; the export takes longer.") {
                Button("Normal priority") { monitor.resumeNormal() }
            }
        } else if monitor.isRendering, g.pacing > 0, let why = g.pacingReason {
            banner(icon: g.thermalBackoff ? "thermometer.high" : "tortoise", color: Theme.signal,
                   title: "Lumora rests between frames \(why)",
                   detail: g.thermalBackoff ? "Its helpers run in the background band until the Mac cools; full speed returns on its own."
                                            : "Full speed returns on its own.") { EmptyView() }
        }
    }

    private func appsLine(_ o: LoadGovernor.Overload) -> String {
        var parts: [String] = []
        if !o.topByCPU.isEmpty {
            parts.append("Busiest: " + o.topByCPU.map { String(format: "%@ (%.1f cores)", $0.name, $0.cores) }.joined(separator: ", "))
        }
        if !o.topByMemory.isEmpty {
            parts.append("most memory: " + o.topByMemory.map { "\($0.name) (\(DiskBudget.gb(Int64($0.memoryMB * 1_048_576))))" }.joined(separator: ", "))
        }
        if o.systemCores > 0.5 { parts.append(String(format: "system processes %.1f cores", o.systemCores)) }
        return parts.isEmpty ? "Closing other apps would help." : parts.joined(separator: "; ") + ". Closing some of them would help."
    }

    private func banner<B: View>(icon: String, color: Color, title: String, detail: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body.weight(.semibold))
                Text(detail).font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack { buttons() }.controlSize(.small)
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(insets)
    }
}

/// In the export window: what is rendering right now, if anything.
struct RenderStatusBanner: View {
    @Environment(\.openWindow) private var openWindow
    private var monitor: RenderMonitor { RenderMonitor.shared }
    var body: some View {
        if let s = monitor.current, !s.ended {
            HStack(spacing: 10) {
                RenderStatusPill.Pill(status: s.status, heartbeat: s.heartbeat)
                Text("\(s.name) · \(Int((s.fraction * 100).rounded(.down)))% · \(s.verdict.headline)").font(Theme.note).lineLimit(1)
                Spacer()
                Button("Monitor") { openWindow(id: "monitor") }.controlSize(.small)
            }
        }
    }
}

/// Before an export: the space it needs on every drive involved against what is free, with exact amounts.
struct DiskPreflightRow: View {
    @Environment(AppModel.self) private var model
    @State private var estimate: DiskBudget.Estimate?
    @State private var showClear = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let e = estimate {
                Image(systemName: e.fits ? "internaldrive" : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(e.fits ? Color.secondary : Theme.fail)
                Text(e.message).font(Theme.note).foregroundStyle(e.fits ? Color.secondary : Theme.fail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(e.items.map { "\($0.0): \(DiskBudget.gb($0.1))" }.joined(separator: "\n"))
            } else {
                Text("Estimating disk space…").font(Theme.note).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Lumora caches…") { showClear = true }.controlSize(.small)
        }
        .task(id: "\(model.codec.rawValue)\(model.delivery.rawValue)\(model.quality)\(model.useTargetQuality)") { await refresh(debounce: true) }
        .sheet(isPresented: $showClear) { CacheClearSheet(inUse: [model.descriptor?.url].compactMap { $0 }) { Task { await refresh(debounce: false) } } }
    }

    /// Asking macOS for free space takes up to a tenth of a second per drive, so it never runs on the main thread,
    /// and a dragged slider only measures once it settles.
    private func refresh(debounce: Bool) async {
        if debounce { try? await Task.sleep(nanoseconds: 300_000_000) }
        guard !Task.isCancelled, let r = request() else { return }
        let e = await Task.detached(priority: .utility) { DiskBudget.estimate(r) }.value
        if !Task.isCancelled { estimate = e }
    }

    private func request() -> DiskBudget.Request? {
        guard let d = model.descriptor else { return nil }
        let forecast = model.currentForecast()
        let out = forecast?.high ?? Int64(Double(d.width * d.height) * 0.15 * Double(max(1, d.frameCount)))
        var r = DiskBudget.Request(outputBytes: out, codec: model.codec, delivery: model.delivery,
                                   scratch: DiskBudget.Roots.app.scratch, output: model.lastExportURL ?? d.url, source: d.url)
        if model.useTargetQuality, ![.prores422HQ, .prores4444XQ, .av2].contains(model.codec) {
            let chunkBytes = out / Int64(max(1, d.frameCount / 240))
            r.targetQuality = (concurrent: MacProfile.current?.concurrentChunks ?? 2, chunkBytes: chunkBytes, trials: model.qualityTarget.maxTrials)
        }
        return r
    }
}

/// Lumora's own caches with their sizes; only checked items are removed, and nothing outside Lumora's folders.
struct CacheClearSheet: View {
    /// Files open in Lumora (the source, a staged copy of it): their folders are never offered.
    var inUse: [URL] = []
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DiskBudget.CacheItem]?
    @State private var chosen: Set<String> = []
    @State private var freed: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear Lumora caches").font(.title3.bold())
            Text("Only files Lumora made and can make again. Your videos, exports and settings are never touched.")
                .font(Theme.note).foregroundStyle(.secondary)
            if let items {
                if items.isEmpty { Text("Nothing to clear.").font(Theme.body) }
                List(items) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.id) },
                                         set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                        HStack { Text(item.label).lineLimit(1); Spacer(); Text(DiskBudget.gb(item.bytes)).monospacedDigit() }
                    }
                }
                .frame(minHeight: 200)
                let total = items.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.bytes }
                if let freed { Text("Freed \(DiskBudget.gb(freed)).").font(Theme.body).foregroundStyle(Theme.pass) }
                HStack {
                    Spacer()
                    Button("Close") { onDone(); dismiss() }
                    Button("Clear \(DiskBudget.gb(total))") {
                        let pick = items.filter { chosen.contains($0.id) }
                        let since = RenderMonitor.shared.activeSince
                        let busy = inUse + RenderMonitor.shared.filesInUse
                        Task.detached {
                            let f = DiskBudget.clear(pick, inUse: busy)
                            let fresh = DiskBudget.inventory(activeSince: since, inUse: busy)
                            await MainActor.run { freed = f; self.items = fresh; chosen = Set(fresh.filter(\.recommended).map(\.id)) }
                        }
                    }
                    .disabled(total == 0)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView("Measuring…")
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .task {
            let since = RenderMonitor.shared.activeSince
            let busy = inUse + RenderMonitor.shared.filesInUse
            let list = await Task.detached { DiskBudget.inventory(activeSince: since, inUse: busy) }.value
            items = list
            chosen = Set(list.filter(\.recommended).map(\.id))
        }
    }
}
