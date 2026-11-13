import Foundation

/// Times how long the two ends of a pipeline channel wait. The sender waiting means the next stage is the limit
/// (backpressure); the receiver waiting means the previous stage is (starved). Waits in progress count too, so a
/// 90-second AV2 frame shows up as waiting while it happens, not only once it ends. No allocation per frame.
final class ChannelMeter: @unchecked Sendable {
    struct Reading: Sendable {
        var sendWait: Double = 0          // seconds, cumulative, including a wait in progress
        var receiveWait: Double = 0
        var received = 0
        var closed = false
        var openedAt: Double = 0
        var closedAt: Double?
        var lastReceiveAt: Double?
    }

    private let lock = NSLock()
    private var sendWait: Double = 0
    private var receiveWait: Double = 0
    private var sendStart: Double = 0
    private var receiveStart: Double = 0
    private var received = 0
    private var closedAt: Double?
    private var lastReceiveAt: Double?
    let openedAt: Double

    init() { openedAt = CACurrentMediaTimeCompat() }

    func sendWaiting(_ on: Bool) {
        let t = CACurrentMediaTimeCompat()
        lock.lock()
        if on { sendStart = t } else if sendStart > 0 { sendWait += t - sendStart; sendStart = 0 }
        lock.unlock()
    }

    func receiveWaiting(_ on: Bool) {
        let t = CACurrentMediaTimeCompat()
        lock.lock()
        if on { receiveStart = t } else if receiveStart > 0 { receiveWait += t - receiveStart; receiveStart = 0 }
        lock.unlock()
    }

    func took() {
        let t = CACurrentMediaTimeCompat()
        lock.lock(); received += 1; lastReceiveAt = t; lock.unlock()
    }

    func close() {
        let t = CACurrentMediaTimeCompat()
        lock.lock()
        if closedAt == nil { closedAt = t }
        if sendStart > 0 { sendWait += t - sendStart; sendStart = 0 }
        if receiveStart > 0 { receiveWait += t - receiveStart; receiveStart = 0 }
        lock.unlock()
    }

    func reading(at now: Double = CACurrentMediaTimeCompat()) -> Reading {
        lock.lock()
        defer { lock.unlock() }
        return Reading(sendWait: sendWait + (sendStart > 0 ? now - sendStart : 0),
                       receiveWait: receiveWait + (receiveStart > 0 ? now - receiveStart : 0),
                       received: received, closed: closedAt != nil, openedAt: openedAt, closedAt: closedAt,
                       lastReceiveAt: lastReceiveAt)
    }
}
