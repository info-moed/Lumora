import Foundation
import Metal

/// Measures whether the Mac stays responsive while Lumora works: how late the main thread (the app's UI) answers a
/// ping, how late a user-interactive timer wakes, and how long a trivial GPU command takes on its own queue (which
/// is what the display's frames compete with). Readings are kept separately for idle and rendering, so a summary can
/// say "UI main-thread p95 4 ms (baseline 3 ms)".
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
    private var gpuPending = false
    private var rendering = false
    /// Set by the render monitor while any render runs.
    func setRendering(_ on: Bool) { lock.lock(); rendering = on; lock.unlock() }
    private let period = 0.1

    func retain() {
        lock.lock(); users += 1; let start = timer == nil; lock.unlock()
        guard start else { return }
        if gpuQueue == nil { gpuQueue = MetalContext.shared.device.makeCommandQueue() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(1))
        expectedWake = CACurrentMediaTimeCompat() + period
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
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
                if self.rendering { self.append(&self.mainBusy, ms) } else { self.append(&self.mainIdle, ms) }
                self.pendingPing = false
                self.lock.unlock()
            }
        }
        if gpuNow, let q = gpuQueue, let cb = q.makeCommandBuffer() {
            let sent = CACurrentMediaTimeCompat()
            cb.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                let ms = (CACurrentMediaTimeCompat() - sent) * 1000
                self.lock.lock()
                if self.rendering { self.append(&self.gpuBusy, ms) } else { self.append(&self.gpuIdle, ms) }
                self.gpuPending = false
                let p90 = Self.stats(self.rendering ? self.gpuBusy : self.gpuIdle, pct: 0.9)
                self.lock.unlock()
                LoadGovernor.shared.setGPULatency(p90Ms: p90)
            }
            cb.commit()
        }
    }

    private func append(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > 1200 { a.removeFirst(a.count - 1200) }
    }

    private static func stats(_ a: [Double], pct: Double) -> Double? {
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

    /// Readings taken while rendering since `mark()`, so each export's summary covers only itself.
    func mark() -> Int { lock.lock(); defer { lock.unlock() }; return mainBusy.count }
    func busyMain(since mark: Int) -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Self.summarize(Array(mainBusy.suffix(max(0, mainBusy.count - min(mark, mainBusy.count)))))
    }

    func resetReadings() {
        lock.lock()
        mainIdle = []; mainBusy = []; wakeIdle = []; wakeBusy = []; gpuIdle = []; gpuBusy = []
        lock.unlock()
    }
}
