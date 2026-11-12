import Foundation

/// Finds helper command-line tools: bundled copies first (Contents/Resources/bin), then Homebrew.
enum ToolLocator {
    static func url(for name: String) -> URL? {
        if let override = UserDefaults.standard.string(forKey: "toolPath.\(name)"),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("bin/\(name)")) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin",
                       NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isAvailable(_ name: String) -> Bool { url(for: name) != nil }

    /// Runs a tool and returns its stderr (FFmpeg prints filter statistics such as `idet` there).
    static func runCapturingStderr(_ name: String, _ args: [String]) throws -> String {
        guard let exe = url(for: name) else { throw LumoraError.missingTool(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = FFHarden.args(name, args)
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let exited = p.exitSignal()
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a tool to completion and returns stdout. Throws with stderr on failure.
    @discardableResult
    static func run(_ name: String, _ args: [String], in directory: URL? = nil) throws -> Data {
        guard let exe = url(for: name) else { throw LumoraError.missingTool(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = FFHarden.args(name, args)
        if let directory { p.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let exited = p.exitSignal()
        try p.run()
        // Drain stderr concurrently so a chatty tool can't fill that pipe and stall while we read stdout.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        exited.wait()
        guard p.terminationStatus == 0 else {
            throw LumoraError.toolFailed(name, String(decoding: errData.suffix(2000), as: UTF8.self))
        }
        return data
    }
}

extension Process {
    /// A semaphore signalled when the process exits. Unlike `waitUntilExit()`, waiting on it doesn't spin the
    /// current run loop, so a short tool call made on the main thread (e.g. while SwiftUI is computing a view)
    /// can't re-enter UI updates. Call before `run()`.
    func exitSignal() -> DispatchSemaphore {
        let s = DispatchSemaphore(value: 0)
        terminationHandler = { _ in s.signal() }
        return s
    }

    /// Call before `run()` so `exited()` can await the process. `waitUntilExit()` waits on the calling thread's
    /// run loop for a termination notice, and on a Swift-concurrency pool thread that notice can be missed, which
    /// left exports hanging forever after the encoder had already quit.
    func trackExit() {
        let waiter = ProcessExitWaiter()
        objc_setAssociatedObject(self, processExitKey, waiter, .OBJC_ASSOCIATION_RETAIN)
        terminationHandler = { _ in waiter.fire() }
    }

    /// Suspends until the process has exited (no thread is blocked). Needs `trackExit()` before `run()`.
    func exited() async {
        if let waiter = objc_getAssociatedObject(self, processExitKey) as? ProcessExitWaiter {
            await waiter.wait()
        } else {
            await Task.detached { self.waitUntilExit() }.value
        }
    }
}

private let processExitKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        done = true
        let w = waiting
        waiting = []
        lock.unlock()
        w.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done { lock.unlock(); c.resume() } else { waiting.append(c); lock.unlock() }
        }
    }
}

/// Tool capability checks run external processes. Do them once, off the main thread, at launch, so views
/// that show "installed / not installed" only ever read cached answers.
/// Inputs are only ever local files or pipes. Restricting FFmpeg's protocols stops a hostile playlist-style
/// file (HLS, concat, ffconcat…) from making it fetch other local or remote resources.
enum FFHarden {
    static let whitelist = ["-protocol_whitelist", "file,pipe,fd"]
    static func args(_ tool: String, _ args: [String]) -> [String] {
        switch tool {
        case "ffprobe": return whitelist + args
        case "ffmpeg":
            var out: [String] = []
            for a in args { if a == "-i" { out += whitelist }; out.append(a) }
            return out
        default: return args
        }
    }
}

/// Quoting for FFmpeg's concat demuxer list files (`file '…'` lines), so paths with apostrophes work.
enum FFConcat {
    static func line(_ url: URL) -> String { "file '" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

enum ToolProbe {
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = VMAFRunner.backend
            _ = MetricSuite.ffmpegHasXPSNR
        }
    }
}

enum LumoraError: LocalizedError {
    case noVideoTrack, decodeFailed(String), missingTool(String), toolFailed(String, String)
    case needsVendorSDK(String), unsupported(String), cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "This file has no video track."
        case .decodeFailed(let s): return "Couldn't decode the video: \(s)"
        case .missingTool(let t): return "The helper tool “\(t)” isn't installed. See README → Encoders."
        case .toolFailed(let t, let e): return "\(t) failed: \(e)"
        case .needsVendorSDK(let ext): return ".\(ext) files need the camera maker's RAW SDK plug-in. See README → RAW formats."
        case .unsupported(let s): return s
        case .cancelled: return "Cancelled."
        }
    }
}
