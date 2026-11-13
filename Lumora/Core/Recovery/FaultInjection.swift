import Foundation

/// Test hooks for the recovery features: inert unless a test turns them on, and compiled out of release builds.
/// They inject the failures the tests need (a full disk, a crashed encoder, a GPU fault, a crash between two writes)
/// without touching the real system: nothing is mounted, filled or unplugged.
enum FaultInjection {
    enum Point: Equatable {
        case beforeSegment(Int)
        case afterFrameWritten(segment: Int, frame: Int)
        case writerAppend(segment: Int, frame: Int)
        case deliver
        case metadataStep(String)
        case join
    }

    /// Thrown by `simulateCrash`: the session skips every cleanup and journal update, like a real crash would.
    struct SimulatedCrash: Error {}

#if DEBUG
    nonisolated(unsafe) static var handler: ((Point, Int) throws -> Void)?     // (point, attempt)
    nonisolated(unsafe) static var onEncoderStarted: ((Process, Int, Int) -> Void)?   // (process, segment, attempt)
    nonisolated(unsafe) static var gpuError: ((Int) -> NSError?)?               // (call count) → error
    nonisolated(unsafe) static var tearJournalTmp = false
    nonisolated(unsafe) static var crashBetweenSegmentAndJournal: Int?           // segment index
    nonisolated(unsafe) static var crashAfterSegments: Int?                     // journaled segments before a crash
    nonisolated(unsafe) static var diagnosticReportsFolder: URL?
    nonisolated(unsafe) private static var gpuCalls = 0
    private static let lock = NSLock()

    static func reset() {
        handler = nil; onEncoderStarted = nil; gpuError = nil; tearJournalTmp = false
        crashBetweenSegmentAndJournal = nil; crashAfterSegments = nil; diagnosticReportsFolder = nil; gpuCalls = 0
        SystemSnapshot.provider = nil; SystemSnapshot.bootSessionOverride = nil; MemoryPressureWatch.override = nil
        CheckpointPlanner.segmentFramesOverride = nil
        CheckpointStore.isProcessAlive = { pid in kill(pid, 0) == 0 || errno == EPERM }
    }

    static func point(_ p: Point, attempt: Int = 1) throws {
        guard let h = handler else { return }
        try h(p, attempt)
    }

    static func encoderStarted(_ p: Process, segment: Int, attempt: Int) { onEncoderStarted?(p, segment, attempt) }

    static func gpu() throws {
        guard let g = gpuError else { return }
        lock.lock(); gpuCalls += 1; let n = gpuCalls; lock.unlock()
        if let e = g(n) { throw GPUFault(underlying: e) }
    }
#else
    static let tearJournalTmp = false
    static let crashBetweenSegmentAndJournal: Int? = nil
    static let crashAfterSegments: Int? = nil
    static let diagnosticReportsFolder: URL? = nil
    @inline(__always) static func point(_ p: Point, attempt: Int = 1) throws {}
    @inline(__always) static func encoderStarted(_ p: Process, segment: Int, attempt: Int) {}
    @inline(__always) static func gpu() throws {}
#endif
}
