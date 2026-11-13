import SwiftUI
import Charts

/// The live render panel: what is being produced right now, how hard the Mac is working, and whether that is
/// making the most of it. Simple mode shows one sentence, the preview, three gauges and the verdict; the detail
/// view adds history charts, stage timings, encoder processes and the busiest other apps.
struct LiveRenderPanel: View {
    @Environment(RenderMonitor.self) private var monitor
    @AppStorage("renderMonitorDetail") private var detail = false
    @State private var filmstrip: [CGImage] = []

    var body: some View {
        let snap = monitor.current
        VStack(alignment: .leading, spacing: 12) {
            header(snap)
            if let snap {
                HStack(alignment: .top, spacing: 16) {
                    previewColumn(snap)
                    VerdictCard(verdict: snap.verdict, paused: snap.status.isPaused)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                GaugeRow(sample: monitor.sample, snap: snap, detail: detail)
                if detail {
                    HistoryCharts(points: monitor.history, cores: monitor.sample.cores)
                    LaneList(lanes: snap.lanes, selected: Bindable(monitor).selectedLane)
                    ProDetail(snap: snap, sample: monitor.sample)
                    Stepper("Call a render stalled after \(Int(monitor.stallSetting)) s with no frame and no activity",
                            value: Bindable(monitor).stallSetting, in: 30...1800, step: 30)
                        .font(Theme.note)
                } else if snap.lanes.filter({ $0.kind != "trial" }).count > 1 || snap.targetQuality {
                    LaneList(lanes: Array(snap.lanes.suffix(6)), selected: Bindable(monitor).selectedLane)
                }
            } else {
                IdleLoad(sample: monitor.sample, detail: detail)
                if let s = monitor.lastSummary { LastExportCard(summary: s) }
            }
        }
        .padding(16)
        .onAppear { monitor.panelAppeared() }
        .onDisappear { monitor.panelDisappeared() }
        .task(id: monitor.current?.framesDone ?? -1) {
            filmstrip = monitor.activeRun?.hub.filmstrip ?? filmstrip
        }
    }

    @ViewBuilder private func header(_ snap: MonitoredRun.Snapshot?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let snap {
                RenderStatusPill.Pill(status: snap.status, heartbeat: snap.heartbeat)
                Text("\(Int((snap.fraction * 100).rounded(.down)))%").font(Theme.figure(30))
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.name).font(Theme.body.weight(.medium)).lineLimit(1)
                    Text(progressLine(snap)).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing is rendering").font(Theme.heading(15))
                Text("The Mac's load is shown live below.").font(Theme.note).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Details", isOn: $detail).toggleStyle(.switch).controlSize(.small)
        }
    }

    private func progressLine(_ s: MonitoredRun.Snapshot) -> String {
        var parts = ["frame \(s.framesDone) of \(s.totalFrames)", s.timecode]
        if s.fps > 0 { parts.append(s.fps >= 10 ? String(format: "%.0f fps", s.fps) : String(format: "%.2f fps", s.fps)) }
        if s.realtime > 0 { parts.append(String(format: "%.2f× realtime", s.realtime)) }
        if let eta = s.eta, s.framesDone > 0 { parts.append("\(RenderSummary.duration(eta)) left") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func previewColumn(_ snap: MonitoredRun.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LiveFrameView(lane: monitor.selectedLane)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: 400)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomLeading) {
                    Text(monitor.previewInfo.isEmpty ? "Waiting for the first frame…" : monitor.previewInfo)
                        .font(Theme.note.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Text(snap.targetKind == .sdr ? "SDR" : (snap.targetKind == .hlg ? "HLG" : "HDR10 \(Int(snap.peakNits)) nits"))
                        .font(Theme.note).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule()).padding(6)
                }
            if !filmstrip.isEmpty && detail { FilmstripView(images: filmstrip) }
        }
    }
}

struct VerdictCard: View {
    let verdict: Verdict
    var paused = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ScoreRing(score: verdict.score, good: verdict.isGood)
                .frame(width: 64, height: 64)
                .help(verdict.scoreFormula)
            VStack(alignment: .leading, spacing: 6) {
                Text(verdict.headline).font(Theme.heading(15)).fixedSize(horizontal: false, vertical: true)
                Text(verdict.reason).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let s = verdict.suggestion {
                    Label(s, systemImage: "lightbulb").font(Theme.body).fixedSize(horizontal: false, vertical: true)
                }
                if verdict.kind != .measuring && !paused {
                    Text("Confidence: \(verdict.confidence.rawValue). Based on measured stage times, not guesses.")
                        .font(Theme.note).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ScoreRing: View {
    let score: Double?
    var good = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
            if let score {
                Circle().trim(from: 0, to: score).stroke(color(score), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((score * 100).rounded()))%").font(Theme.heading(13).monospacedDigit())
            } else {
                Text("–").font(Theme.heading(13))
            }
        }
    }
    private func color(_ s: Double) -> Color { good || s >= 0.85 ? Theme.pass : (s >= 0.6 ? Theme.marginal : Theme.signal) }
}

/// CPU (performance and efficiency clusters, split into Lumora, its encoders, other apps and idle), GPU, memory,
/// thermal and the media engine.
struct GaugeRow: View {
    let sample: SystemSample
    let snap: MonitoredRun.Snapshot?
    var detail: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CPUGauge(sample: sample)
            GPUGauge(device: sample.gpuDevice, lumora: snap?.gpuLumora)
            MemoryGauge(sample: sample)
            if detail || sample.thermal.rawValue >= 1 { ThermalGauge(state: sample.thermal) }
            if detail, let snap, snap.hardware { EngineGauge(busy: snap.engineNotReady) }
        }
    }
}

struct CPUGauge: View {
    let sample: SystemSample
    var body: some View {
        let n = Double(max(1, sample.cores))
        let parts: [(String, Double, Color)] = [
            ("Lumora", sample.selfCores, Theme.signal), ("Encoders", sample.childCores, Theme.pass),
            ("Other apps", sample.othersCores, Theme.marginal),
        ]
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU \(Int((sample.totalBusyFraction * 100).rounded()))%").font(Theme.heading(12))
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { p in p.2.frame(width: max(0, g.size.width * min(1, p.1 / n))) }
                    Spacer(minLength: 0)
                }
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 10)
            HStack(spacing: 8) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 3) { StatusDot(color: p.2); Text(String(format: "%@ %.1f", p.0, p.1)).font(Theme.note.monospacedDigit()) }
                }
            }
            Text("Performance cores \(Int((sample.performanceBusy * 100).rounded()))% · efficiency \(Int((sample.efficiencyBusy * 100).rounded()))%\(sample.clusterMapApproximate ? " (approximate)" : "")")
                .font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(minWidth: 260, alignment: .leading)
        .help("Cores busy. Other apps = everything busy minus Lumora and the encoders it started; it includes system processes.")
    }
}

struct GPUGauge: View {
    let device: Double?
    let lumora: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GPU \(device.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a")").font(Theme.heading(12))
            ProgressView(value: min(1, device ?? 0)).tint(Theme.signal)
            Text(lumora.map { "Lumora's grading \(Int(($0 * 100).rounded()))%" } ?? "Device utilization").font(Theme.note).foregroundStyle(.secondary)
        }
        .frame(width: 150, alignment: .leading)
    }
}

struct MemoryGauge: View {
    let sample: SystemSample
    var body: some View {
        let level = sample.pressureLevel
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory").font(Theme.heading(12))
            HStack(spacing: 4) {
                StatusDot(color: level >= 4 ? Theme.fail : (level >= 2 ? Theme.marginal : Theme.pass))
                Text(level >= 4 ? "Critical" : (level >= 2 ? "Tight" : "Fine")).font(Theme.body)
            }
            Text(String(format: "Lumora %.1f GB · swap %.1f GB", (sample.selfFootprintMB + sample.childFootprintMB) / 1024, sample.swapUsedMB / 1024))
                .font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 170, alignment: .leading)
    }
}

struct ThermalGauge: View {
    let state: ProcessInfo.ThermalState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thermal").font(Theme.heading(12))
            HStack(spacing: 4) {
                StatusDot(color: state.rawValue >= 2 ? Theme.fail : (state.rawValue == 1 ? Theme.marginal : Theme.pass))
                Text(["Cool", "Warm", "Hot (slowing down)", "Critical"][min(3, state.rawValue)]).font(Theme.body)
            }
        }
        .frame(width: 130, alignment: .leading)
    }
}

struct EngineGauge: View {
    let busy: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Media engine").font(Theme.heading(12))
            Text(busy.map { "busy ≈ \(Int(($0 * 100).rounded()))% (inferred)" } ?? "not measurable").font(Theme.body)
        }
        .frame(width: 160, alignment: .leading)
        .help("Media engine use isn't measurable on macOS without admin tools; Lumora infers it from how long the hardware encoder makes frames wait.")
    }
}

struct HistoryCharts: View {
    let points: [MonitoredRun.HistoryPoint]
    let cores: Int

    struct Stack: Identifiable { let id: String; let t: Double; let series: String; let value: Double }

    var body: some View {
        let stacked = points.flatMap { p in
            [Stack(id: "\(p.id)l", t: p.t, series: "Lumora", value: p.lumora), Stack(id: "\(p.id)e", t: p.t, series: "Encoders", value: p.encoders),
             Stack(id: "\(p.id)o", t: p.t, series: "Other apps", value: p.others)]
        }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU cores, last 2 minutes").font(Theme.note).foregroundStyle(.secondary)
                Chart(stacked) { s in
                    AreaMark(x: .value("Time", s.t), y: .value("Cores", s.value)).foregroundStyle(by: .value("Who", s.series))
                }
                .chartForegroundStyleScale(["Lumora": Theme.signal, "Encoders": Theme.pass, "Other apps": Theme.marginal])
                .chartYScale(domain: 0...Double(max(1, cores)))
                .chartXAxis(.hidden)
                .frame(height: 110)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    HStack(spacing: 3) { StatusDot(color: Theme.signal); Text("GPU %") }
                    HStack(spacing: 3) { StatusDot(color: Theme.pass); Text("frames per second") }
                }
                .font(Theme.note).foregroundStyle(.secondary)
                Chart {
                    ForEach(points) { p in
                        if let g = p.gpuDevice { LineMark(x: .value("Time", p.t), y: .value("GPU", g * 100), series: .value("s", "GPU")).foregroundStyle(Theme.signal) }
                    }
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.t), y: .value("fps", p.fps), series: .value("s", "fps")).foregroundStyle(Theme.pass)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 110)
            }
        }
    }
}

struct LaneList: View {
    let lanes: [MonitoredRun.LaneSnapshot]
    @Binding var selected: LaneID?

    var body: some View {
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lanes").font(Theme.heading(12))
                ForEach(lanes) { l in
                    HStack(spacing: 8) {
                        StatusDot(color: l.closed ? Theme.pass : Theme.signal)
                        Text(l.label).font(Theme.note).lineLimit(1)
                        if let p = l.progress { ProgressView(value: min(1, p)).frame(width: 90) }
                        Text(l.detail).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }
}

struct ProDetail: View {
    let snap: MonitoredRun.Snapshot
    let sample: SystemSample

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Time per frame").font(Theme.heading(12))
                ForEach(snap.stages, id: \.name) { s in
                    Text(String(format: "%@ %.1f ms", s.name, s.msPerFrame)).font(Theme.note.monospacedDigit())
                }
                if let st = snap.encoderStarved, let bp = snap.pipeBlocked {
                    Text("Encoder waiting for frames \(Int((st * 100).rounded()))% · pipe blocked on the encoder \(Int((bp * 100).rounded()))%")
                        .font(Theme.note.monospacedDigit())
                }
                Text(String(format: "Monitor cost %.0f ms so far", snap.probeCostMs)).font(Theme.note).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Encoder processes").font(Theme.heading(12))
                if sample.children.isEmpty { Text("none running").font(Theme.note).foregroundStyle(.secondary) }
                ForEach(sample.children.prefix(8), id: \.pid) { c in
                    Text(String(format: "%@ %.1f cores · %.0f MB", c.name, c.cores, c.footprintMB)).font(Theme.note.monospacedDigit())
                }
            }
            TopApps(sample: sample)
        }
    }
}

struct TopApps: View {
    let sample: SystemSample
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Other apps").font(Theme.heading(12))
            if sample.topAppsByCPU.isEmpty { Text("measuring…").font(Theme.note).foregroundStyle(.secondary) }
            ForEach(sample.topAppsByCPU.prefix(4)) { a in
                Text(String(format: "%@ %.1f cores", a.name, a.cores)).font(Theme.note.monospacedDigit())
            }
            if sample.systemProcessesCores > 0.2 {
                Text(String(format: "System processes %.1f cores", sample.systemProcessesCores)).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct IdleLoad: View {
    let sample: SystemSample
    var detail: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CPUGauge(sample: sample)
            GPUGauge(device: sample.gpuDevice, lumora: nil)
            MemoryGauge(sample: sample)
            if detail { TopApps(sample: sample) }
        }
    }
}

struct LastExportCard: View {
    let summary: RenderSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last export: \(summary.name)").font(Theme.heading(12)).lineLimit(1)
            Text("\(summary.frames) frames in \(RenderSummary.duration(summary.seconds)) (\(String(format: "%.1f", summary.fps)) fps) · \(summary.verdictHeadline)\(summary.score.map { " · \(Int(($0 * 100).rounded()))% of the Mac" } ?? "")")
                .font(Theme.note).foregroundStyle(.secondary)
            Text("Bottleneck: \(summary.bottleneck). " + String(format: "CPU: Lumora %.1f, encoders %.1f, other apps %.1f cores.", summary.lumoraCores, summary.encoderCores, summary.otherCores))
                .font(Theme.note).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
