import Foundation
import CryptoKit

/// Helper tool versions, asked once per launch (the export log lists them).
extension ToolVersions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func version(_ tool: String) -> String {
        lock.lock()
        if let v = cache[tool] { lock.unlock(); return v }
        lock.unlock()
        let v = ask(tool)
        lock.lock(); cache[tool] = v; lock.unlock()
        return v
    }

    private static func ask(_ tool: String) -> String {
        guard let exe = ToolLocator.url(for: tool) else { return "not installed" }
        let args: [String]
        switch tool {
        case "aomenc", "avmenc": args = ["--help"]
        case "ffmpeg", "ffprobe": args = ["-hide_banner", "-version"]
        case "MP4Box": args = ["-version"]
        default: args = ["--version"]
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let done = p.exitSignal()
        guard (try? p.run()) != nil else { return "unknown" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close()
        done.wait()
        let text = String(decoding: data.prefix(64 << 10), as: UTF8.self)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if tool == "aomenc" || tool == "avmenc" {
            if let i = lines.firstIndex(where: { $0.hasPrefix("Included encoders") }), i + 1 < lines.count { return lines[i + 1] }
        }
        return lines.first { !$0.isEmpty }.map { String($0.prefix(160)) } ?? "unknown"
    }

    /// The tools an export may run, for the log header.
    static func relevant(_ job: ExportJob) -> [String] {
        var t = ["ffmpeg"]
        if let s = ExportEngine.encoder(for: job) { t.append(s.binary) }
        if ExportEngine.needsMetadataPass(job.delivery) { t += ["dovi_tool", "hdr10plus_tool", "MP4Box", "mkvmerge"] }
        if job.codec == .hevc12 || job.codec == .vvc { t.append("MP4Box") }
        if ExportEngine.needsContainerHDR10Metadata(job) { t.append("mkvmerge") }
        var seen = Set<String>()
        return t.filter { seen.insert($0).inserted }
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The text people can paste into an issue: plain text (easy to review), strictly scrubbed, never the raw journal,
/// file contents or frames.
enum DiagnosticReport {
    static func make(_ r: FailureReport, logURL: URL?, journal: ExportJournal? = nil, names: DiagnosticScrub.Names = .init()) -> String {
        var out: [String] = ["Lumora diagnostic report", String(repeating: "=", count: 24)]
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        out.append("Lumora \(v) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(ChipProfile.current.description)")
        out.append("")
        out.append("WHAT HAPPENED")
        out.append(r.title)
        out.append(r.simple)
        out.append(r.means)
        out.append("")
        out.append("TECHNICAL")
        out.append(r.proLine)
        out += r.technical
        if let j = journal, let p = j.plan {
            out.append("")
            out.append("SEGMENTS (\(p.segments.count) planned, \(j.segments.count) saved, \(p.workers) at a time)")
            let done = Set(j.segments.map(\.index))
            for s in p.segments.prefix(80) {
                out.append("  \(s.index): frames \(s.start)–\(s.start + s.count - 1)\(s.preroll > 0 ? " (preroll \(s.preroll))" : "") \(done.contains(s.index) ? "saved" : "missing")")
            }
            if let e = j.encode { out.append("Encoder: \(e.binary) \(e.version), \(e.threads) threads") }
        }
        if let crash = CrashReports.summary(newerThan: journal?.updated.addingTimeInterval(-60) ?? Date().addingTimeInterval(-3600)) {
            out.append("")
            out.append("CRASH REPORT")
            out.append(crash)
        }
        if let logURL {
            out.append("")
            out.append("LAST LOG LINES")
            let lines = RenderLog.tail(logURL, lines: 300)
            // The header (settings, tool versions) too, when the log is longer than the tail.
            let head = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").prefix(40).map(String.init) ?? []
            if !head.isEmpty, head.first != lines.first { out += head + ["…"] }
            out += lines
        }
        var n = names
        if let v = r.failure.volume { n.volumes.append(v) }
        if let logURL, n.source.isEmpty || n.output.isEmpty {
            let fromLog = DiagnosticScrub.names(fromLog: logURL)
            if n.source.isEmpty { n.source = fromLog.source }
            if n.output.isEmpty { n.output = fromLog.output }
        }
        if let p = r.failure.path { n.files += DiagnosticScrub.both(URL(fileURLWithPath: p)) }
        if let s = r.sourceName, !s.isEmpty, n.source.isEmpty { n.source = DiagnosticScrub.both(URL(fileURLWithPath: s)) }
        return DiagnosticScrub.share(out.joined(separator: "\n"), names: n)
    }
}

/// Crash reports macOS wrote for Lumora (exception type and crashed thread only).
enum CrashReports {
    static var folder: URL {
        FaultInjection.diagnosticReportsFolder
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DiagnosticReports")
    }

    static func newest(newerThan date: Date) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Lumora") && $0.pathExtension == "ips" }
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? u.resourceValues(forKeys: Set(keys)))?.contentModificationDate, d > date else { return nil }
                return (u, d)
            }
            .max { $0.1 < $1.1 }?.0
    }

    static func summary(newerThan date: Date) -> String? {
        guard let u = newest(newerThan: date), let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        var parts: [String] = []
        for key in ["\"type\"", "\"signal\"", "\"faultingThread\""] {
            if let r = text.range(of: key + #"\s*:\s*"?[^",}]+"#, options: .regularExpression) { parts.append(String(text[r])) }
        }
        if let r = text.range(of: #"Exception Type:[^\n]+"#, options: .regularExpression) { parts.append(String(text[r])) }
        if let r = text.range(of: #"Crashed Thread:[^\n]+"#, options: .regularExpression) { parts.append(String(text[r])) }
        return parts.isEmpty ? "A crash report exists (\(u.lastPathComponent))." : parts.joined(separator: "; ")
    }
}
