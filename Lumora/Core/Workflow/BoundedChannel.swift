import Foundation
import Metal

/// A small async queue with back-pressure. Pipeline stages run as separate tasks connected by these
/// channels, so model inference (Neural Engine / GPU Neural Accelerators), grading (GPU), encoding
/// (media engine or CPU) and decoding all work at the same time instead of waiting on one another.
actor BoundedChannel<Element> {
    private var buffer: [Element] = []
    private let capacity: Int
    private var finished = false
    private var failure: Error?
    private var receivers: [CheckedContinuation<Element?, Error>] = []
    private var senders: [CheckedContinuation<Void, Never>] = []
    private let meter: ChannelMeter?      // times both ends' waits for the render monitor

    init(capacity: Int, meter: ChannelMeter? = nil) { self.capacity = max(1, capacity); self.meter = meter }

    func send(_ value: Element) async {
        let waits = buffer.count >= capacity && !finished
        if waits { meter?.sendWaiting(true) }
        while buffer.count >= capacity && !finished {
            await withCheckedContinuation { senders.append($0) }
        }
        if waits { meter?.sendWaiting(false) }
        guard !finished else { return }
        if !receivers.isEmpty {
            receivers.removeFirst().resume(returning: value)
        } else {
            buffer.append(value)
        }
    }

    func receive() async throws -> Element? {
        if !buffer.isEmpty {
            let v = buffer.removeFirst()
            if !senders.isEmpty { senders.removeFirst().resume() }
            meter?.took()
            return v
        }
        if let failure { throw failure }
        if finished { return nil }
        meter?.receiveWaiting(true)
        defer { meter?.receiveWaiting(false) }
        let v = try await withCheckedThrowingContinuation { receivers.append($0) }
        if v != nil { meter?.took() }
        return v
    }

    func finish() {
        meter?.close()
        finished = true
        receivers.forEach { $0.resume(returning: nil) }
        receivers.removeAll()
        senders.forEach { $0.resume() }
        senders.removeAll()
    }

    func fail(_ error: Error) {
        meter?.close()
        failure = error
        finished = true
        receivers.forEach { $0.resume(throwing: error) }
        receivers.removeAll()
        senders.forEach { $0.resume() }
        senders.removeAll()
    }
}

extension MTLCommandBuffer {
    /// Commits and suspends (without blocking a thread) until the GPU has finished this buffer.
    func commitAndWait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            addCompletedHandler { cb in
                if let e = cb.error { GPUFaults.record(e) }
                cont.resume()
            }
            commit()
        }
    }
}
