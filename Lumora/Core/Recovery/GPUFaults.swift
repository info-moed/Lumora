import Foundation
import Metal

/// GPU errors from command buffers. `commitAndWait()` records them here; the grading loops call `check()` after each
/// frame, so a GPU timeout or page fault stops the export with a clear message instead of encoding garbage.
/// A GPU error concerns the whole device, so the next grading loop that checks reports it (and its segment is retried).
enum GPUFaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [NSError] = []
    nonisolated(unsafe) private static var generation = 0

    static func record(_ e: Error) {
        lock.lock(); pending.append(e as NSError); generation += 1; lock.unlock()
        RenderLog.broadcast(.error, "GPU error: \((e as NSError).domain) \((e as NSError).code) \(e.localizedDescription)")
    }

    /// Throws the oldest recorded GPU error (once), plus an injected one in tests.
    static func check() throws {
        try FaultInjection.gpu()
        lock.lock()
        let e = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        if let e { throw GPUFault(underlying: e) }
    }

    static func reset() { lock.lock(); pending.removeAll(); lock.unlock() }
}
