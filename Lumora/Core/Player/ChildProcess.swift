import Foundation

/// A decoder child process whose stdout the player reads with read(2), straight into frame buffers.
/// stderr is drained into a small ring so error messages can be shown; every child is tracked until it has been
/// killed and reaped, so stopping a player (or closing its window) never leaves a decoder running.
final class ChildProcess: @unchecked Sendable {
    let name: String
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var errRing = Data()
    private var stopped = false
    private(set) var pid: Int32 = 0
    private var errDone = DispatchSemaphore(value: 0)

    /// Children that have been started and not yet reaped. Tests check it is empty after a player stops.
    private static let registryLock = NSLock()
    private static var live: Set<Int32> = []
    static var livePIDs: Set<Int32> { registryLock.lock(); defer { registryLock.unlock() }; return live }

    init(tool name: String, args: [String], qos: QualityOfService = .userInitiated) throws {
        guard let exe = ToolLocator.url(for: name) else {
            throw PlayerError.missingTool(name, name == "avmdec" ? PlayerError.avmHint : PlayerError.ffmpegHint)
        }
        self.name = name
        process.executableURL = exe
        process.arguments = FFHarden.args(name, args)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.qualityOfService = qos
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            throw PlayerError.decoderFailed(name, error.localizedDescription)
        }
        pid = process.processIdentifier
        Self.registryLock.lock(); Self.live.insert(pid); Self.registryLock.unlock()
        let fd = errPipe.fileHandleForReading.fileDescriptor
        let done = errDone
        Thread.detachNewThread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                self?.appendErr(buf[0..<n])
            }
            done.signal()
        }
    }

    deinit { terminate() }

    private func appendErr(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        errRing.append(contentsOf: bytes)
        if errRing.count > 4096 { errRing = errRing.suffix(4096) }
        lock.unlock()
    }

    /// The last 4 KB the tool wrote to stderr.
    var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errRing, as: UTF8.self)
    }

    /// Reads exactly `count` bytes unless the stream ends first; returns how many were read.
    func read(into p: UnsafeMutableRawPointer, count: Int) -> Int {
        let fd = outPipe.fileHandleForReading.fileDescriptor
        var got = 0
        while got < count {
            let n = Darwin.read(fd, p + got, count - got)
            if n > 0 { got += n } else if n == 0 { break } else if errno == EINTR { continue } else { break }
        }
        return got
    }

    /// Reads everything until EOF (for small outputs such as one probe frame), up to `limit` bytes.
    func readAll(limit: Int) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let fd = outPipe.fileHandleForReading.fileDescriptor
        while out.count < limit {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    var isRunning: Bool { process.isRunning }

    /// Waits for the process to exit by itself; nil on timeout.
    func waitForExit(timeout: TimeInterval) -> Int32? {
        if exited.wait(timeout: .now() + timeout) == .timedOut { return nil }
        exited.signal()          // keep it signaled for later waiters
        _ = errDone.wait(timeout: .now() + 1)
        errDone.signal()
        return process.terminationStatus
    }

    /// SIGTERM, then SIGKILL if it hasn't gone within a second; waits until the child has been reaped.
    func terminate() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(pid, SIGKILL)
            _ = exited.wait(timeout: .now() + 3)
        }
        exited.signal()
        Self.registryLock.lock(); Self.live.remove(pid); Self.registryLock.unlock()
    }
}
