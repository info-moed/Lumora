import Foundation

/// Decoded frames waiting to be shown, in display order. The decode thread blocks in `push` while it is full
/// (back-pressure); a seek flushes it and bumps the generation so frames still in flight from before are dropped.
final class FrameQueue: @unchecked Sendable {
    let capacity: Int
    private let cond = NSCondition()
    private var frames: [PlayerFrame] = []
    private var gen = 0
    private var closed = false

    init(capacity: Int) { self.capacity = max(2, capacity) }

    var generation: Int { cond.lock(); defer { cond.unlock() }; return gen }
    var count: Int { cond.lock(); defer { cond.unlock() }; return frames.count }
    var firstIndex: Int? { cond.lock(); defer { cond.unlock() }; return frames.first?.index }
    var lastIndex: Int? { cond.lock(); defer { cond.unlock() }; return frames.last?.index }

    /// Adds a frame; waits while the queue is full. false when the queue was flushed (or closed) meanwhile.
    @discardableResult
    func push(_ f: PlayerFrame, generation g: Int) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while frames.count >= capacity && gen == g && !closed { cond.wait() }
        guard gen == g, !closed else { return false }
        if let last = frames.last, f.index <= last.index {
            // Out of order (shouldn't happen with passthrough timing): keep the list sorted.
            let at = frames.firstIndex { $0.index >= f.index } ?? frames.count
            if at < frames.count, frames[at].index == f.index { return true }
            frames.insert(f, at: at)
        } else {
            frames.append(f)
        }
        cond.broadcast()
        return true
    }

    /// Drops everything and starts a new generation. Returns the new generation.
    @discardableResult
    func flush() -> Int {
        cond.lock()
        frames.removeAll()
        gen += 1
        let g = gen
        cond.broadcast()
        cond.unlock()
        return g
    }

    func close() {
        cond.lock(); closed = true; frames.removeAll(); cond.broadcast(); cond.unlock()
    }

    /// The newest frame due at media time `t` (pts ≤ t + tolerance), removed from the queue together with the
    /// older ones it replaces; `dropped` counts those, which were never shown.
    func take(dueAt t: Double, tolerance: Double) -> (frame: PlayerFrame?, dropped: Int) {
        cond.lock()
        defer { cond.unlock() }
        var pick = -1
        for (n, f) in frames.enumerated() {
            if f.pts <= t + tolerance { pick = n } else { break }
        }
        guard pick >= 0 else { return (nil, 0) }
        let f = frames[pick]
        frames.removeFirst(pick + 1)
        cond.broadcast()
        return (f, pick)
    }

    /// Removes and returns the first frame at or after `index`, dropping any older ones (seeks, frame steps).
    func take(atLeast index: Int) -> PlayerFrame? {
        cond.lock()
        defer { cond.unlock() }
        guard let n = frames.firstIndex(where: { $0.index >= index }) else {
            if !frames.isEmpty { frames.removeAll(); cond.broadcast() }
            return nil
        }
        let f = frames[n]
        frames.removeFirst(n + 1)
        cond.broadcast()
        return f
    }

    /// Waits up to `timeout` for the frame with this index (or a later one, which means it was skipped).
    func waitFor(index: Int, timeout: TimeInterval) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !(frames.last.map { $0.index >= index } ?? false) && !closed {
            if !cond.wait(until: deadline) { return false }
        }
        return !closed
    }
}
