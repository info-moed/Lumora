import Foundation
import Metal

/// Measures whether the Mac stays responsive while Lumora works: how late the main thread (the app's UI) answers a
/// ping, how late a user-interactive timer wakes, and how long a tiny GPU command (a 64 KB fill, which really runs
/// on the GPU) waits before the GPU has done it, on its own queue: that wait is what the display's frames compete
/// with. It is timed to the GPU's own end timestamp, so a slow wake of the completion thread on a busy CPU does
/// not read as GPU contention. Readings are kept separately for idle and rendering, so a summary can say
/// "UI main-thread p95 4 ms (baseline 3 ms)".
final class ResponsivenessProbe: @unchecked Sendable {
    static let shared = ResponsivenessProbe()

    struct Stats: Sendable, Equatable {
        var count = 0
        var p50: Double = 0
        var p95: Double = 0
        var max: Double = 0
        var text: String { count == 0 ? "–" : String(format: "p95 %.0f ms", p95) }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lumora.monitor.responsiveness", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var users = 0
    private var expectedWake: Double = 0
    private var mainIdle: [Double] = [], mainBusy: [Double] = []
    private var wakeIdle: [Double] = [], wakeBusy: [Double] = []
    private var gpuIdle: [Double] = [], gpuBusy: [Double] = []
    private var pendingPing = false
    private var tickCount = 0
    private var gpuQueue: MTLCommandQueue?
    private var gpuScratch: MTLBuffer?
    private var mainBusyTotal = 0              // readings ever added to mainBusy (the array keeps the last 1200)
    /// Idle readings needed before they count as a baseline.
    static let baselineMinimum = 20
    /// The GPU wait that paces Lumora is the p90 of this many recent readings (about half a minute).
    static let gpuWindow = 30
    private var gpuPending = false
    private var rendering = false
    /// Set by the render monitor while any render runs.
    func setRendering(_ on: Bool) { lock.lock(); rendering = on; lock.unlock() }
    private let period = 0.1

    func retain() {
        // Checked and created under one lock, so two first users at once can't start two timers.
        lock.lock(); defer { lock.unlock() }
        users += 1
        guard timer == nil else { return }
        if gpuQueue == nil {
            let device = MetalContext.shared.device
            gpuQueue = device.makeCommandQueue()
            gpuScratch = device.makeBuffer(length: 65536, options: .storageModePrivate)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(1))
        queue.async { [weak self] in self?.expectedWake = CACurrentMediaTimeCompat() + (self?.period ?? 0.1) }
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Keeps measuring for a while after a render (the readings then count as idle: the baseline for the next one).
    func hold(seconds: Double) {
        retain()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in self?.release() }
    }

    func release() {
        lock.lock(); users = max(0, users - 1); let stop = users == 0 ? timer : nil; if users == 0 { timer = nil }; lock.unlock()
        stop?.cancel()
    }

    private func tick() {
        let now = CACurrentMediaTimeCompat()
        let late = max(0, now - expectedWake) * 1000
        expectedWake = now + period
        lock.lock()
        let busy = rendering
        if busy { append(&wakeBusy, late) } else { append(&wakeIdle, late) }
        let ping = !pendingPing
        if ping { pendingPing = true }
        tickCount += 1
        let gpuNow = tickCount % 10 == 0 && !gpuPending
        if gpuNow { gpuPending = true }
        lock.unlock()
        if ping {
            let sent = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ms = (CACurrentMediaTimeCompat() - sent) * 1000
                self.lock.lock()
                self.recordLocked(mainMs: ms, rendering: self.rendering)
                self.pendingPing = false
                self.lock.unlock()
            }
        }
        if gpuNow {
            if !measureGPU({ [weak self] ms in
                guard let self else { return }
                self.lock.lock()
                if let ms { if self.rendering { self.append(&self.gpuBusy, ms) } else { self.append(&self.gpuIdle, ms) } }
                self.gpuPending = false
                let p90 = Self.stats((self.rendering ? self.gpuBusy : self.gpuIdle).suffix(Self.gpuWindow), pct: 0.9)
                self.lock.unlock()
                LoadGovernor.shared.setGPULatency(p90Ms: p90)
            }) {
                lock.lock(); gpuPending = false; lock.unlock()
            }
        }
    }

    /// One GPU reading: commits a 64 KB fill and reports, in ms, how long after the commit the GPU had finished it
    /// (by the GPU's own end timestamp), or nil if the GPU gave no timestamps. Returns false if nothing was sent.
    @discardableResult
    func measureGPU(_ done: @escaping @Sendable (Double?) -> Void) -> Bool {
        guard let q = gpuQueue, let buffer = gpuScratch, let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return false }
        blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        blit.endEncoding()
        let sent = CACurrentMediaTimeCompat()
        cb.addCompletedHandler { buffer in
            let end = buffer.gpuEndTime
            done(end > sent && buffer.gpuStartTime > 0 ? (end - sent) * 1000 : nil)
        }
        cb.commit()
        return true
    }

    /// Test support: the GPU's own time for the probe's command, in ms (it must be more than zero: the command
    /// really runs on the GPU).
    func probeGPUSpan() -> (wait: Double?, span: Double) {
        lock.lock()
        if gpuQueue == nil {
            let device = MetalContext.shared.device
            gpuQueue = device.makeCommandQueue()
            gpuScratch = device.makeBuffer(length: 65536, options: .storageModePrivate)
        }
        let q = gpuQueue, buffer = gpuScratch
        lock.unlock()
        guard let q, let buffer, let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return (nil, 0) }
        blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
        blit.endEncoding()
        let sent = CACurrentMediaTimeCompat()
        cb.commit()
        cb.waitUntilCompleted()
        let span = max(0, cb.gpuEndTime - cb.gpuStartTime) * 1000
        return (cb.gpuEndTime > sent ? (cb.gpuEndTime - sent) * 1000 : nil, span)
    }

    private func recordLocked(mainMs ms: Double, rendering: Bool) {
        if rendering { append(&mainBusy, ms); mainBusyTotal += 1 } else { append(&mainIdle, ms) }
    }

    /// One main-thread reading (the ping does this; tests feed readings directly).
    func record(mainMs ms: Double, rendering: Bool) { lock.lock(); recordLocked(mainMs: ms, rendering: rendering); lock.unlock() }

    private func append(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 1200 { a.removeFirst(a.count - 1200) }
    }

    private static func stats<C: Collection>(_ a: C, pct: Double) -> Double? where C.Element == Double {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * pct))]
    }

    private static func summarize(_ a: [Double]) -> Stats {
        guard !a.isEmpty else { return Stats() }
        let s = a.sorted()
        return Stats(count: s.count, p50: s[s.count / 2], p95: s[min(s.count - 1, Int(Double(s.count - 1) * 0.95))], max: s.last!)
    }

    struct Report: Sendable, Equatable {
        var mainIdle = Stats(), mainBusy = Stats()
        var wakeIdle = Stats(), wakeBusy = Stats()
        var gpuIdle = Stats(), gpuBusy = Stats()
    }

    var report: Report {
        lock.lock(); defer { lock.unlock() }
        return Report(mainIdle: Self.summarize(mainIdle), mainBusy: Self.summarize(mainBusy),
                      wakeIdle: Self.summarize(wakeIdle), wakeBusy: Self.summarize(wakeBusy),
                      gpuIdle: Self.summarize(gpuIdle), gpuBusy: Self.summarize(gpuBusy))
    }

    /// Readings taken while rendering since `mark()`, so each export's summary covers only itself. The mark counts
    /// every reading ever taken, so it stays right after the kept readings reach their cap.
    func mark() -> Int { lock.lock(); defer { lock.unlock() }; return mainBusyTotal }
    func busyMain(since mark: Int) -> Stats {
        lock.lock(); defer { lock.unlock() }
        let new = min(mainBusy.count, max(0, mainBusyTotal - mark))
        return Self.summarize(Array(mainBusy.suffix(new)))
    }

    /// The idle readings, once there are enough of them to be a baseline (otherwise none: a handful of pings taken
    /// as an export starts is not "idle").
    var idleBaseline: Stats? {
        lock.lock(); defer { lock.unlock() }
        return mainIdle.count >= Self.baselineMinimum ? Self.summarize(mainIdle) : nil
    }

    func resetReadings() {
        lock.lock()
        mainIdle = []; mainBusy = []; wakeIdle = []; wakeBusy = []; gpuIdle = []; gpuBusy = []; mainBusyTotal = 0
        lock.unlock()
    }
}
