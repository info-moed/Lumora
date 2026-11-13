import Foundation
import Darwin

/// How Lumora's helper processes (encoders, metric tools, Python) are scheduled, so a heavy export never makes the
/// Mac seize up. Every child is niced a little at launch (+5 for a single export, +10 in a batch): that costs
/// nothing on an otherwise idle Mac, and gives the apps someone is using the first claim on the CPU. An
/// unprivileged process can only raise niceness, never lower it again, so the default is deliberately mild.
/// "Lower priority" additionally moves the children into the background band (revocable).
final class ChildPolicy: @unchecked Sendable {
    static let shared = ChildPolicy()

    /// Set by the batch queue: children started inside it get the larger nice value.
    @TaskLocal static var inBatch = false

    static let singleNice: Int32 = 5
    static let batchNice: Int32 = 10

    private let lock = NSLock()
    private var names: [Int32: String] = [:]
    private var niced: Set<Int32> = []
    private var background = false
    private(set) var started = 0

    /// Called right after a helper process starts.
    static func started(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let name = process.executableURL?.lastPathComponent ?? SystemSampler.processName(pid)
        shared.apply(pid: pid, name: name, nice: inBatch ? batchNice : singleNice)
    }

    func name(for pid: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return names[pid] }

    var lowerPriority: Bool { lock.lock(); defer { lock.unlock() }; return background }

    /// Applies the policy to a child the sampler found that wasn't started through `started(_:)` (frame decoders,
    /// short tool calls). Only ever raises niceness.
    func sweep(pid: Int32, name: String) {
        lock.lock(); let known = niced.contains(pid); lock.unlock()
        guard !known else { return }
        apply(pid: pid, name: name, nice: Self.singleNice)
    }

    private func apply(pid: Int32, name: String, nice: Int32) {
        errno = 0
        let current = getpriority(PRIO_PROCESS, id_t(pid))
        if errno == 0, current < nice { _ = setpriority(PRIO_PROCESS, id_t(pid), nice) }
        lock.lock()
        names[pid] = name
        niced.insert(pid)
        started += 1
        if names.count > 512 { names.removeAll(); niced.removeAll() }
        let bg = background
        lock.unlock()
        if bg { _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) }
    }

    /// "Lower priority": every current and future child runs in the background band (on a busy Mac this can make
    /// the export much slower: background threads were measured waking 0.5 to 3.4 s late). Turning it off undoes it.
    func setLowerPriority(_ on: Bool) {
        lock.lock(); background = on; lock.unlock()
        for pid in Self.allChildren() {
            _ = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0)
        }
    }

    static func allChildren() -> [Int32] {
        var out: [Int32] = []
        var stack = SystemSampler.childPIDs(getpid())
        while let p = stack.popLast(), out.count < 128 {
            out.append(p)
            stack += SystemSampler.childPIDs(p)
        }
        return out
    }

    static func niceness(of pid: Int32) -> Int32? {
        errno = 0
        let v = getpriority(PRIO_PROCESS, id_t(pid))
        return errno == 0 ? v : nil
    }
}
