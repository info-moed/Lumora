import Foundation

/// A helper tool or encoder that failed, with what is needed to explain it: the exit status or the signal that
/// stopped it, its last stderr lines, and the command that ran. The message reads exactly like the older
/// `LumoraError.toolFailed` ("x265 failed: …"), so existing messages stay the same.
struct ToolFailure: LocalizedError {
    var tool: String
    var args: [String] = []
    var exitStatus: Int32 = 0
    var signal: Int32? = nil          // set when the process was killed by a signal it didn't handle
    var stderrTail: String
    var stage: String? = nil
    /// Lumora stopped the process itself (cancel, a write that failed): not a crash.
    var stoppedByLumora = false

    var errorDescription: String? { "\(tool) failed: \(stderrTail)" }

    /// The last few meaningful lines of stderr (no progress bars).
    var lastLines: [String] {
        RenderLog.splitLines(stderrTail).filter { l in
            !l.hasPrefix("Encoding frame") && !l.contains("frames/sec") && !(l.hasPrefix("[") && l.hasSuffix("%]"))
        }.suffix(8).map { $0 }
    }

    var lastErrorLine: String {
        let lines = lastLines
        return lines.last { l in
            let s = l.lowercased()
            return s.contains("error") || s.contains("invalid") || s.contains("fail") || s.contains("unrecognized")
                || s.contains("unknown option") || s.contains("cannot") || s.contains("could not") || s.contains("must be")
        } ?? lines.last ?? ""
    }

    static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGABRT: return "SIGABRT"
        case SIGTRAP: return "SIGTRAP"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        case SIGPIPE: return "SIGPIPE"
        default: return "signal \(s)"
        }
    }

    /// From a finished process and the file its stderr went to.
    static func from(_ tool: String, process: Process, log: URL?, args: [String] = [], stoppedByLumora: Bool = false) -> ToolFailure {
        let text = log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return from(tool, process: process, stderr: text, args: args, stoppedByLumora: stoppedByLumora)
    }

    static func from(_ tool: String, process: Process, stderr: String, args: [String] = [], stoppedByLumora: Bool = false) -> ToolFailure {
        let signaled = !process.isRunning && process.terminationReason == .uncaughtSignal
        return ToolFailure(tool: tool, args: args, exitStatus: signaled ? 0 : process.terminationStatus,
                           signal: signaled ? process.terminationStatus : nil, stderrTail: String(stderr.suffix(1500)),
                           stoppedByLumora: stoppedByLumora)
    }
}
