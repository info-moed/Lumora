import Foundation

/// One verbose log file per export, always on: settings, tool versions, every command line (paths as ~/…), each stage
/// with its duration, frame counters, encoder stderr, warnings, system events, and on failure the plain-language
/// explanation plus the full technical chain.
///
/// The log of the export running in the current task is `RenderLog.current` (a task-local value), so two exports at
/// once never write into each other's file, and code deep in the pipeline (ToolLocator, Log) adds to it without
/// being handed anything.
final class RenderLog: @unchecked Sendable {
    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR", cmd = "CMD", stage = "STAGE", frames = "FRAMES",
                         stderr = "STDERR", system = "SYSTEM", retry = "RETRY", result = "RESULT" }

    @TaskLocal static var current: RenderLog?

    static let maxBytes: Int64 = 16 << 20
    static let keepDays = 30.0
    static let keepCount = 200
    static let keepTotalBytes: Int64 = 256 << 20

    let url: URL
    let exportID: String
    let started = Date()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var truncatedNoted = false
    private let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    /// Every open log, so system-wide events (sleep, memory pressure) reach each running export.
    nonisolated(unsafe) private static var open: [ObjectIdentifier: RenderLog] = [:]
    private static let openLock = NSLock()

    static var folder: URL {
        if let o = UserDefaults.standard.string(forKey: "renderLogFolder") { return URL(fileURLWithPath: o, isDirectory: true) }
        return Log.logFolder.appendingPathComponent("Exports", isDirectory: true)
    }

    init(exportID: String, outputName: String, folder: URL = RenderLog.folder) throws {
        self.exportID = exportID
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let base = Naming.truncated(URL(fileURLWithPath: outputName).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"), maxBytes: 60)
        var u = folder.appendingPathComponent("\(df.string(from: started)) \(base).log")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = folder.appendingPathComponent("\(df.string(from: started)) \(base) \(n).log"); n += 1
        }
        url = u
        FileManager.default.createFile(atPath: u.path, contents: nil)
        handle = try FileHandle(forWritingTo: u)
        Self.openLock.lock(); Self.open[ObjectIdentifier(self)] = self; Self.openLock.unlock()
    }

    /// A log that writes nothing: when neither the log folder nor the temporary folder can take a new file (a
    /// completely full startup disk), the export still runs and its failure is still explained on screen.
    init(unwritableFor exportID: String, outputName: String, folder: URL = RenderLog.folder) {
        self.exportID = exportID
        url = folder.appendingPathComponent("\(URL(fileURLWithPath: outputName).deletingPathExtension().lastPathComponent).log")
        handle = nil
    }

    /// Whether lines reach a file.
    var isWritable: Bool { lock.lock(); defer { lock.unlock() }; return handle != nil }

    /// Reopens an existing log (a resumed export keeps writing the same file).
    init(appendingTo url: URL, exportID: String) throws {
        self.url = url
        self.exportID = exportID
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try FileHandle(forWritingTo: url)
        written = Int64((try? handle?.seekToEnd()) ?? 0)
        Self.openLock.lock(); Self.open[ObjectIdentifier(self)] = self; Self.openLock.unlock()
    }

    deinit { close() }

    func close() {
        lock.lock(); try? handle?.close(); handle = nil; lock.unlock()
        Self.openLock.lock(); Self.open[ObjectIdentifier(self)] = nil; Self.openLock.unlock()
    }

    // MARK: Writing

    func raw(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let data = Data((DiagnosticScrub.local(text) + (text.hasSuffix("\n") ? "" : "\n")).utf8)
        try? handle.write(contentsOf: data)
        written += Int64(data.count)
    }

    func line(_ level: Level, _ tag: String = "", _ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        if written >= Self.maxBytes {
            guard [.warn, .error, .stage, .result, .retry].contains(level) else {
                if !truncatedNoted {
                    truncatedNoted = true
                    try? handle.write(contentsOf: Data("--- log truncated at 16 MB: only warnings, errors and stages from here ---\n".utf8))
                }
                return
            }
        }
        let now = Date()
        let elapsed = String(format: "+%.3f", now.timeIntervalSince(started))
        let lvl = level.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        let t = tag.isEmpty ? "-" : tag
        var text = DiagnosticScrub.local(message)
        if text.count > 8000 { text = String(text.prefix(8000)) + " …" }
        let data = Data("\(timeFormat.string(from: now)) \(elapsed) \(lvl) \(t) \(text)\n".utf8)
        try? handle.write(contentsOf: data)
        written += Int64(data.count)
    }

    func info(_ m: String, tag: String = "") { line(.info, tag, m) }
    func warn(_ m: String, tag: String = "") { line(.warn, tag, m) }
    func error(_ m: String, tag: String = "") { line(.error, tag, m) }

    /// A command line, in full (paths scrubbed when written). Arguments with spaces are quoted.
    func command(_ tool: String, _ args: [String], tag: String = "") {
        let quoted = args.map { a in a.contains(" ") || a.isEmpty ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a }
        line(.cmd, tag, ([tool] + quoted).joined(separator: " "))
    }

    /// Encoder or tool stderr, split on carriage returns too (progress lines), at most `lines` lines and 64 KB.
    func stderrTail(_ text: String, lines: Int, tag: String) {
        let all = Self.splitLines(text)
        var tail = Array(all.suffix(lines))
        while tail.joined(separator: "\n").utf8.count > 64 << 10, !tail.isEmpty { tail.removeFirst() }
        for l in tail { line(.stderr, tag, l) }
    }

    static func splitLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Stages

    private var stageStarts: [String: Date] = [:]
    func stageStart(_ name: String, tag: String = "") {
        lock.lock(); stageStarts[name + tag] = Date(); lock.unlock()
        line(.stage, tag, "\(name) started")
    }
    func stageEnd(_ name: String, tag: String = "", note: String = "") {
        lock.lock(); let s = stageStarts.removeValue(forKey: name + tag); lock.unlock()
        let d = s.map { String(format: " in %.2f s", Date().timeIntervalSince($0)) } ?? ""
        line(.stage, tag, "\(name) finished\(d)\(note.isEmpty ? "" : " (\(note))")")
    }

    // MARK: Everyone

    /// A system event for every running export (sleep, wake, memory pressure, thermal change).
    static func broadcast(_ level: Level, _ message: String) {
        openLock.lock(); let logs = Array(open.values); openLock.unlock()
        for l in logs { l.line(level, "system", message) }
    }

    /// The last `n` lines of a log file.
    static func tail(_ url: URL, lines n: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = min(size, 512 << 10)
        try? h.seek(toOffset: size - chunk)
        let data = (try? h.readToEnd()) ?? Data()
        return Array(String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init).suffix(n))
    }

    // MARK: Pruning

    /// Keeps 30 days or 200 logs, at most 256 MB together; never deletes the log of an export that can still resume.
    static func prune(folder: URL = RenderLog.folder, keep: Set<String> = [], now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
            .filter({ $0.pathExtension == "log" }) else { return }
        let dated = files.map { u -> (URL, Date, Int64) in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total: Int64 = 0
        for (i, (u, date, size)) in dated.enumerated() {
            if keep.contains(u.lastPathComponent) || keep.contains(u.path) { total += size; continue }
            let tooOld = now.timeIntervalSince(date) > keepDays * 86_400
            if tooOld || i >= keepCount || total + size > keepTotalBytes {
                try? fm.removeItem(at: u)
            } else {
                total += size
            }
        }
    }

    /// Every export log, newest first, for the Export logs window.
    struct Entry: Identifiable, Hashable {
        var id: URL { url }
        var url: URL
        var date: Date
        var size: Int64
        var result: String        // "finished", "failed: …", "stopped", "running"
        var output: String
    }

    static func entries(folder: URL = RenderLog.folder) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "log" }
        return files.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let tail = tail(u, lines: 60)
            var result = "unfinished"
            if let r = tail.last(where: { $0.contains(" RESULT ") }) {
                result = r.contains("finished") ? "finished" : (r.contains("canceled") || r.contains("stopped") ? "stopped" : "failed")
            }
            let head = (try? String(contentsOf: u, encoding: .utf8).prefix(4000)).map(String.init) ?? ""
            let output = head.split(separator: "\n").first { $0.hasPrefix("Output: ") }.map { String($0.dropFirst(8)) } ?? u.lastPathComponent
            return Entry(url: u, date: v?.contentModificationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0), result: result, output: output)
        }.sorted { $0.date > $1.date }
    }
}
