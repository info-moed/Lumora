import Foundation
import OSLog
import Observation

/// Verbose, searchable logging: every decision Lumora makes (detection, chunk quality, model choice, storage
/// plan, tool command lines) is recorded to the unified log, an on-disk daily file, and the in-app console.
enum LogCategory: String, CaseIterable, Codable {
    case app, ingest, analysis, storage, interpolation, upscale, encode, quality, models, tools
}

enum LogLevel: Int, CaseIterable, Codable, Comparable {
    case debug, info, notice, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Debug", "Info", "Notice", "Warning", "Error"][rawValue] }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
}

@MainActor
@Observable
final class LogStore {
    static let shared = LogStore()
    private(set) var entries: [LogEntry] = []
    var verbose = UserDefaults.standard.bool(forKey: "verboseLogging") {
        didSet { UserDefaults.standard.set(verbose, forKey: "verboseLogging") }
    }
    let capacity = 20_000

    func append(_ e: LogEntry) {
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func export(to url: URL) throws {
        let f = ISO8601DateFormatter()
        try entries.map { "\(f.string(from: $0.date)) [\($0.level.label)] \($0.category.rawValue): \($0.message)" }
            .joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() { entries.removeAll() }
}

enum Log {
    private static let loggers = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: "io.github.info-moed.Lumora", category: $0.rawValue))
    })
    private static let fileQueue = DispatchQueue(label: "lumora.log.file")
    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Lumora")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("lumora-\(df.string(from: Date())).log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()
    static var logFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Lumora")
    }

    static func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let l = loggers[category]!
        switch level {
        case .debug: l.debug("\(message, privacy: .public)")
        case .info: l.info("\(message, privacy: .public)")
        case .notice: l.notice("\(message, privacy: .public)")
        case .warning: l.warning("\(message, privacy: .public)")
        case .error: l.error("\(message, privacy: .public)")
        }
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        if level > .debug { RenderLog.current?.line(level >= .error ? .error : (level == .warning ? .warn : .info), category.rawValue, message) }
        fileQueue.async {
            let line = "\(ISO8601DateFormatter().string(from: entry.date)) [\(level.label)] \(category.rawValue): \(message)\n"
            try? fileHandle?.write(contentsOf: Data(line.utf8))
        }
        Task { @MainActor in
            if level > .debug || LogStore.shared.verbose { LogStore.shared.append(entry) }
        }
    }

    static func debug(_ c: LogCategory, _ m: @autoclosure () -> String) { write(.debug, c, m()) }
    static func info(_ c: LogCategory, _ m: String) { write(.info, c, m) }
    static func notice(_ c: LogCategory, _ m: String) { write(.notice, c, m) }
    static func warning(_ c: LogCategory, _ m: String) { write(.warning, c, m) }
    static func error(_ c: LogCategory, _ m: String) { write(.error, c, m) }
}

// MARK: - Task center: every long operation gets a progress bar, rate and ETA.

@MainActor
@Observable
final class TrackedTask: Identifiable {
    enum State: Equatable { case running, finished, failed(String), canceled }
    let id = UUID()
    let title: String
    let symbol: String
    var detail = ""
    var progress: Double?            // nil = indeterminate
    var rate: String?                // e.g. "142 fps", "148 MB/s"
    var state: State = .running
    let started = Date()
    var onCancel: (() -> Void)?

    init(title: String, symbol: String) { self.title = title; self.symbol = symbol }

    var eta: String? {
        guard let p = progress, p > 0.01, p < 1, state == .running else { return nil }
        let remaining = Date().timeIntervalSince(started) * (1 - p) / p
        let f = DateComponentsFormatter()
        f.allowedUnits = remaining > 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: remaining).map { "\($0) left" }
    }
}

@MainActor
@Observable
final class TaskCenter {
    static let shared = TaskCenter()
    private(set) var tasks: [TrackedTask] = []
    var active: [TrackedTask] { tasks.filter { $0.state == .running } }

    @discardableResult
    func begin(_ title: String, symbol: String = "gearshape.2", cancel: (() -> Void)? = nil) -> TrackedTask {
        let t = TrackedTask(title: title, symbol: symbol)
        t.onCancel = cancel
        tasks.insert(t, at: 0)
        if tasks.count > 60 { tasks.removeLast(tasks.count - 60) }
        Log.info(.app, "Started: \(title)")
        return t
    }

    func finish(_ t: TrackedTask, error: Error? = nil) {
        if let error {
            t.state = (error is CancellationError) ? .canceled : .failed(error.localizedDescription)
            Log.error(.app, "\(t.title) failed: \(error.localizedDescription)")
        } else {
            t.state = .finished
            t.progress = 1
            Log.info(.app, "Finished: \(t.title) in \(Int(Date().timeIntervalSince(t.started)))s")
        }
    }

    func clearFinished() { tasks.removeAll { $0.state != .running } }
}

/// Thread-safe progress reporting from background work into a TrackedTask.
struct ProgressReporter: Sendable {
    let task: TrackedTask?
    nonisolated func update(_ progress: Double?, detail: String? = nil, rate: String? = nil) {
        guard let task else { return }
        Task { @MainActor in
            if let progress { task.progress = progress }
            if let detail { task.detail = detail }
            if let rate { task.rate = rate }
        }
    }
}
