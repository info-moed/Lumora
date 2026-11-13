import Foundation
import AppKit
import Observation

/// What the UI shows about renders in progress: status, heartbeat, speed, the verdict, lanes, history and load.
/// It pulls from the running exports once a second (preview text four times a second); nothing here is on the
/// render path.
@MainActor
@Observable
final class RenderMonitor {
    static let shared = RenderMonitor()

    private(set) var runs: [MonitoredRun] = []
    private(set) var current: MonitoredRun.Snapshot?
    private(set) var sample = SystemSample()
    private(set) var history: [MonitoredRun.HistoryPoint] = []
    private(set) var overload: LoadGovernor.Overload?
    private(set) var governor = LoadGovernor.State()
    private(set) var lastSummary: RenderSummary?
    private(set) var previewInfo: String = ""
    var selectedLane: LaneID?
    /// Seconds without a finished frame (and without any other sign of life) before a render is called stalled.
    var stallSetting: Double = UserDefaults.standard.object(forKey: "stallSeconds") as? Double ?? 60 {
        didSet { UserDefaults.standard.set(stallSetting, forKey: "stallSeconds"); Self.stallStore = stallSetting }
    }
    nonisolated(unsafe) static var stallStore: Double = UserDefaults.standard.object(forKey: "stallSeconds") as? Double ?? 60
    nonisolated static var stallSeconds: Double { stallStore }
    nonisolated(unsafe) static var panelOpen = false

    private var timer: Timer?
    private var fastTicks = 0
    private var idleSamplerHeld = false
    private let dock = DockProgress()

    var isRendering: Bool { current != nil && !(current?.ended ?? true) }
    /// When the oldest running job (render or any other tracked task) started; its scratch files must not be cleared.
    var activeSince: Date? {
        (runs.map(\.startDate) + TaskCenter.shared.active.map(\.started)).min()
    }
    var activeRun: MonitoredRun? { runs.last }
    /// The sources running exports read (a staged copy among them): never offered for clearing.
    var filesInUse: [URL] { runs.map(\.job.descriptor.url) }

    nonisolated static func register(_ run: MonitoredRun) {
        Task { @MainActor in shared.add(run) }
    }

    nonisolated static func unregister(_ run: MonitoredRun, summary: RenderSummary) {
        Task { @MainActor in shared.remove(run, summary: summary) }
    }

    private func add(_ run: MonitoredRun) {
        runs.append(run)
        ResponsivenessProbe.shared.setRendering(true)
        startTimer()
        refresh()
    }

    private func remove(_ run: MonitoredRun, summary: RenderSummary) {
        runs.removeAll { $0 === run }
        lastSummary = summary
        if runs.isEmpty {
            ResponsivenessProbe.shared.setRendering(false)
            // A short idle reading after each render: the baseline the next export's responsiveness is compared with.
            ResponsivenessProbe.shared.hold(seconds: 20)
            if var c = current { c.ended = true; c.status = .done; current = c }
            dock.clear()
            if !Self.panelOpen { stopTimer() }
        }
        refresh()
    }

    /// The monitor window keeps the sampler running (for the gauges) even when nothing renders.
    func panelAppeared() {
        Self.panelOpen = true
        if !idleSamplerHeld { SystemSampler.shared.retain(); ResponsivenessProbe.shared.retain(); idleSamplerHeld = true }
        SystemSampler.shared.wantAppScan(true)
        if lastSummary == nil { Task.detached { let s = RenderSummary.latest(); await MainActor.run { if self.lastSummary == nil { self.lastSummary = s } } } }
        startTimer()
    }

    func panelDisappeared() {
        Self.panelOpen = false
        SystemSampler.shared.wantAppScan(false)
        if idleSamplerHeld { SystemSampler.shared.release(); ResponsivenessProbe.shared.release(); idleSamplerHeld = false }
        if runs.isEmpty { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil, !Self.underTests || Self.timerInTests else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    static let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// Tests that drive the monitor turn its timer on explicitly.
    nonisolated(unsafe) static var timerInTests = false

    private func fastTick() {
        fastTicks += 1
        updatePreviewInfo()
        if fastTicks % 4 == 0 { refresh() }
    }

    private func updatePreviewInfo() {
        guard let f = Self.testPreview ?? activeRun?.hub.frame(for: selectedLane) else {
            if previewInfo != "" && activeRun == nil { previewInfo = "" }
            return
        }
        let pct = Int((Double(f.outputIndex + 1) / Double(max(1, f.totalFrames)) * 100).rounded())
        let text = "Frame \(f.outputIndex + 1) of \(f.totalFrames) · \(f.timecode) · \(pct)%"
        if text != previewInfo { previewInfo = text }
    }

    /// Pull everything once (the timer calls this every second; tests call it directly).
    func refresh() {
        Task { PauseGateMirror.reason = await PauseGate.shared.reason() }
        sample = SystemSampler.shared.latest
        governor = LoadGovernor.shared.current
        overload = governor.overload
        if let run = activeRun {
            var snap = run.snapshot
            if snap.targetQuality {
                // Encoded share from the chunk map: rendering alone is only half the job.
                let em = EncodeMonitor.shared
                let doneFrames = em.chunks.filter { $0.state == .done }.reduce(0) { $0 + $1.range.count }
                if em.totalFrames > 0 { snap.fraction = 0.25 * snap.fraction + 0.75 * Double(doneFrames) / Double(em.totalFrames) }
            }
            current = snap
            history = snap.history
            if !Self.underTests { dock.update(snap) }
        } else if !Self.panelOpen {
            history = []
        }
    }

    // MARK: - Actions

    func pauseForOthers() { LoadGovernor.shared.choose(.paused); refresh() }
    func lowerPriority() { LoadGovernor.shared.choose(.lowerPriority); refresh() }
    func continueAnyway() { LoadGovernor.shared.choose(.continued); refresh() }
    func resumeNormal() { LoadGovernor.shared.choose(.none); refresh() }

    // MARK: - Test support

    /// Puts a synthetic snapshot on screen (UI tests and documentation screenshots).
    func showForTesting(_ snap: MonitoredRun.Snapshot?, sample: SystemSample, overload: LoadGovernor.Overload? = nil, summary: RenderSummary? = nil) {
        current = snap
        history = snap?.history ?? []
        self.sample = sample
        self.overload = overload
        lastSummary = summary
        updatePreviewInfo()
    }

    nonisolated(unsafe) static var testPreview: PreviewFrame?
}

/// Rendering progress on the Dock icon: a bar and a badge ("Paused", "!" when stalled). At most once a second,
/// never under XCTest.
@MainActor
final class DockProgress {
    private var bar: NSProgressIndicator?
    private var lastBadge: String?
    private var lastValue = -1.0

    func update(_ s: MonitoredRun.Snapshot) {
        let tile = NSApp.dockTile
        if bar == nil {
            let view = NSImageView(image: NSApp.applicationIconImage)
            let p = NSProgressIndicator(frame: NSRect(x: 8, y: 4, width: tile.size.width - 16, height: 12))
            p.style = .bar
            p.isIndeterminate = false
            p.minValue = 0; p.maxValue = 1
            view.addSubview(p)
            tile.contentView = view
            bar = p
        }
        let v = (s.fraction * 100).rounded() / 100
        let badge: String? = s.status.isStalled ? "!" : (s.status.isPaused ? "Paused" : nil)
        guard v != lastValue || badge != lastBadge else { return }
        bar?.doubleValue = v
        lastValue = v
        tile.badgeLabel = badge
        lastBadge = badge
        tile.display()
    }

    func clear() {
        guard bar != nil || lastBadge != nil else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        bar = nil; lastBadge = nil; lastValue = -1
    }
}
