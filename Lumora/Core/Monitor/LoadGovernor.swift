import Foundation

/// Keeps heavy work from seizing up the Mac. It watches memory pressure (kernel events and level), swap growth,
/// thermal state, free disk space and how busy other apps keep the CPU, and reacts in the one place every long loop
/// already passes between frames (`PauseGate.wait`): it pauses before macOS starts swapping or the disk fills,
/// paces work while the Mac is hot or the person chose Lower priority, and tells parallel stages to run fewer
/// instances at once. Overload is only reported (with the busiest apps named); the person decides what to do.
final class LoadGovernor: @unchecked Sendable {
    static let shared = LoadGovernor()

    enum Choice: String, Sendable { case none, paused, lowerPriority, continued }

    struct Overload: Sendable, Equatable {
        var reasons: [String]
        var topByCPU: [SystemSample.App]
        var topByMemory: [SystemSample.App]
        var systemCores: Double
        var since: Double
    }

    struct State: Sendable, Equatable {
        var pressure = 1
        var thermal: ProcessInfo.ThermalState = .nominal
        var diskPause: String?
        var memoryPause: String?
        var userChoice: Choice = .none
        var overload: Overload?
        var snoozedUntil: Double = 0
        var gpuLatencyP90Ms: Double?
        var pacing: Double = 0          // 0...1 fraction of time to rest between frames
    }

    private let lock = NSLock()
    private var state = State()
    private var memorySource: DispatchSourceMemoryPressure?
    private var overloadSince: Double?
    private var snoozedReasons = 0
    private var lastSampleTime: Double = 0
    private var lastPressureHigh: Double = 0
    private var swapHistory: [(Double, Double)] = []
    private var lastReturn: [Int: Double] = [:]
    private var thermalObserver: NSObjectProtocol?
    /// Tests can turn the governor off so a busy shared Mac never pauses an unrelated test.
    nonisolated(unsafe) static var enabled = true
    /// Seconds at normal memory pressure before work goes back to full speed.
    nonisolated(unsafe) static var recoverySeconds: Double = 10

    var current: State { lock.lock(); defer { lock.unlock() }; return state }

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let e = src.data
            let level = e.contains(.critical) ? 4 : (e.contains(.warning) ? 2 : 1)
            self.setPressure(level, source: "event")
        }
        src.resume()
        memorySource = src
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: nil) { [weak self] _ in
            self?.lock.lock(); self?.state.thermal = ProcessInfo.processInfo.thermalState; self?.lock.unlock()
            self?.recomputePacing()
        }
    }

    // MARK: - Inputs

    func setPressure(_ level: Int, source: String = "sample") {
        let now = CACurrentMediaTimeCompat()
        lock.lock()
        let before = state.pressure
        if level >= 2 { lastPressureHigh = now }
        // Recover only after 10 s at normal, so a flapping level doesn't start and stop work every second.
        if level >= before || now - lastPressureHigh >= Self.recoverySeconds { state.pressure = level }
        if state.pressure >= 4 {
            state.memoryPause = "Paused: memory is almost full (before macOS starts swapping)"
        } else if state.memoryPause != nil, state.pressure <= 1 {
            state.memoryPause = nil
        }
        let changed = before != state.pressure
        lock.unlock()
        if changed { Log.notice(.app, "Memory pressure \(Self.pressureName(level)) (\(source))") }
    }

    /// Fed once a second by the render monitor while something renders.
    func observe(_ s: SystemSample, rendering: Bool) {
        setPressure(s.pressureLevel)
        let now = s.time
        lock.lock()
        lastSampleTime = now
        state.thermal = s.thermal
        swapHistory.append((now, s.swapUsedMB))
        swapHistory.removeAll { now - $0.0 > 90 }
        var reasons: [String] = []
        let n = Double(max(1, s.cores))
        if s.busyCores >= 0.95 * n && s.othersCores >= 0.40 * n {
            reasons.append(String(format: "Other apps are using %.0f of %d cores", s.othersCores, s.cores))
        }
        if state.pressure >= 2 { reasons.append("macOS reports memory pressure \(Self.pressureName(state.pressure))") }
        let growth = swapGrowthLocked()
        if growth > 100 { reasons.append(String(format: "Swap is growing by %.0f MB a minute", growth)) }
        if s.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { reasons.append("The Mac is hot and slowing itself down") }
        if rendering && !reasons.isEmpty {
            overloadSince = overloadSince ?? now
            if now - (overloadSince ?? now) >= 15 {
                let snoozed = state.snoozedUntil > now
                let worse = snoozed && reasons.count > snoozedReasons
                if !snoozed || worse {
                    state.overload = Overload(reasons: reasons, topByCPU: Array(s.topAppsByCPU.prefix(3)),
                                              topByMemory: Array(s.topAppsByMemory.prefix(3)),
                                              systemCores: s.systemProcessesCores, since: overloadSince ?? now)
                    if worse { state.snoozedUntil = 0 }
                }
            }
        } else {
            overloadSince = nil
            state.overload = nil
        }
        lock.unlock()
        recomputePacing()
    }

    var overloadSuspected: Bool { lock.lock(); defer { lock.unlock() }; return overloadSince != nil || state.overload != nil }

    var swapGrowthMBPerMin: Double { lock.lock(); defer { lock.unlock() }; return swapGrowthLocked() }

    private func swapGrowthLocked() -> Double {
        guard let first = swapHistory.first, let last = swapHistory.last, last.0 - first.0 >= 20 else { return 0 }
        return max(0, (last.1 - first.1) / (last.0 - first.0) * 60)
    }

    func setGPULatency(p90Ms: Double?) {
        lock.lock(); state.gpuLatencyP90Ms = p90Ms; lock.unlock()
        recomputePacing()
    }

    func setDiskPause(_ reason: String?) {
        lock.lock(); let changed = state.diskPause != reason; state.diskPause = reason; lock.unlock()
        if changed, let reason {
            Log.warning(.storage, reason)
            RenderHooks.pausedForDisk?(reason)
        } else if changed {
            Log.notice(.storage, "Disk space is back; resuming")
        }
    }

    // MARK: - The person's choice

    func choose(_ c: Choice) {
        lock.lock()
        state.userChoice = c
        if c == .continued {
            // Snooze for 10 minutes, unless it gets worse (more reasons than now).
            snoozedReasons = state.overload?.reasons.count ?? 0
            state.snoozedUntil = (lastSampleTime > 0 ? lastSampleTime : CACurrentMediaTimeCompat()) + 600
            state.overload = nil
        }
        lock.unlock()
        ChildPolicy.shared.setLowerPriority(c == .lowerPriority)
        recomputePacing()
        Log.notice(.app, "Heavy load: \(c == .paused ? "paused" : (c == .lowerPriority ? "running at lower priority" : (c == .continued ? "continuing" : "normal")))")
    }

    private func recomputePacing() {
        lock.lock()
        var p = 0.0
        if state.userChoice == .lowerPriority { p = max(p, 0.5) }
        if state.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { p = max(p, 0.2) }
        if let g = state.gpuLatencyP90Ms, g > 8 { p = max(p, 0.15) }   // the display's frames are waiting on the GPU
        state.pacing = p
        lock.unlock()
    }

    // MARK: - Outputs

    /// Why work should not continue right now, if anything.
    var pauseReason: String? {
        guard Self.enabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        if state.userChoice == .paused { return "Paused: you paused for other apps" }
        return state.diskPause ?? state.memoryPause
    }

    /// How many parallel instances to run when `wanted` would be the normal number.
    func limit(_ wanted: Int) -> Int {
        guard Self.enabled else { return wanted }
        lock.lock(); defer { lock.unlock() }
        var n = wanted
        if state.pressure >= 2 || swapGrowthLocked() > 100 { n = max(1, n / 2) }
        if state.pressure >= 4 { n = 1 }
        if state.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { n = max(1, n - 1) }
        return n
    }

    var memoryTight: Bool { lock.lock(); defer { lock.unlock() }; return state.pressure >= 2 }

    /// The first thing `PauseGate.wait()` does: wait out a governor pause, then rest briefly when pacing.
    func holdIfNeeded() async {
        guard Self.enabled else { return }
        var logged: String?
        while let why = pauseReason {
            if why != logged { Log.notice(.app, why); logged = why }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
        if logged != nil { Log.notice(.app, "Resumed") }
        let key = withUnsafeCurrentTask { $0?.hashValue } ?? 0
        let rest = restBeforeNextFrame(task: key)
        if rest > 0.001 { try? await Task.sleep(nanoseconds: UInt64(rest * 1e9)) }
        markReturned(task: key)
    }

    /// Rest so that rest ÷ (work + rest) = pacing, where work is the time since this task last passed through.
    private func restBeforeNextFrame(task key: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        let pacing = state.pacing
        guard pacing > 0 else { return 0 }
        let now = CACurrentMediaTimeCompat()
        let worked = lastReturn[key].map { min(2, max(0, now - $0)) } ?? 0
        if lastReturn.count > 256 { lastReturn.removeAll() }
        return worked * pacing / max(0.05, 1 - pacing)
    }

    private func markReturned(task key: Int) {
        lock.lock(); lastReturn[key] = CACurrentMediaTimeCompat(); lock.unlock()
    }

    static func pressureName(_ level: Int) -> String { level >= 4 ? "critical" : (level >= 2 ? "warning" : "normal") }

    /// Test support: back to a clean state.
    func reset() {
        lock.lock()
        state = State()
        overloadSince = nil
        snoozedReasons = 0
        lastSampleTime = 0
        swapHistory = []
        lastReturn = [:]
        lastPressureHigh = 0
        lock.unlock()
        ChildPolicy.shared.setLowerPriority(false)
    }
}

/// Hooks for other parts of the app that need to know about monitor decisions.
enum RenderHooks {
    /// Called when the governor pauses a render because the disk is about to fill (a resume-after-failure feature
    /// can write its checkpoint here). The render itself just waits at its next frame; resuming is automatic once
    /// space returns.
    nonisolated(unsafe) static var pausedForDisk: ((String) -> Void)?
}
