import XCTest
@testable import Lumora

/// The verbose per-export log: one file per export, everything needed to understand a failure, nothing personal.
final class RenderLogTests: RecoveryTestCase {

    func testEveryExportWritesAFullLog() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("log-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 48
        let e = ExportEngine()
        let j = job(p, codec: .av1, name: "logged.mkv")
        _ = try await e.run(j) { _, _ in }
        let url = try XCTUnwrap(e.session?.logURL)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, logs.standardizedFileURL, "the log is in the export log folder")
        XCTAssertTrue(url.lastPathComponent.hasSuffix(" logged.log"), url.lastPathComponent)
        let text = try String(contentsOf: url, encoding: .utf8)
        for needle in ["Lumora export log", "Export ID: ", "Source: ", "Output: ", "Settings: AV1", "Tools: ", "SvtAv1EncApp SVT-AV1",
                       "STAGE  grain", "STAGE  seg 0 segment started", "STAGE  seg 1 segment finished", "CMD    seg0.a1 SvtAv1EncApp ",
                       "FRAMES seg 0 48/48 frames", "STDERR seg 0", "STAGE  join", "Joined video: 96 frames (planned 96)",
                       "STAGE  deliver", "RESULT done finished in"] {
            XCTAssertTrue(text.contains(needle), "the log has “\(needle)”")
        }
        XCTAssertTrue(text.contains("SYSTEM start free space") || text.contains("SYSTEM start"), "system state at the start")
        // Every command line is written in full.
        let cmd = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(" CMD ") && $0.contains("SvtAv1EncApp") })
        XCTAssertTrue(cmd.contains("--crf") || cmd.contains("--qp") || cmd.contains("-q "), String(cmd))
        XCTAssertFalse(text.contains(NSHomeDirectory() + "/"), "paths are written as ~/…")
        XCTAssertEqual(RenderLog.entries(folder: logs).first?.result, "finished")
    }

    func testFailedExportLogExplainsWhatHappened() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("log-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 48
        FaultInjection.handler = { point, _ in
            if case .beforeSegment(1) = point { throw POSIXError(.ENOSPC) }
        }
        let e = ExportEngine()
        _ = await failure(e, job(p, codec: .av1, name: "failed.mkv"))
        let text = try String(contentsOf: try XCTUnwrap(e.session?.logURL), encoding: .utf8)
        for needle in ["RESULT failed failed at encode: diskFull", "WHAT HAPPENED", "The drive ran out of space", "TECHNICAL",
                       "Kind: diskFull", "Segment: 1", "SYSTEM AT FAILURE", "PROGRESS: 1 of 2 segments saved (48 of 96 frames)",
                       "Progress kept in the scratch folder"] {
            XCTAssertTrue(text.contains(needle), "the failure footer has “\(needle)”")
        }
        XCTAssertEqual(RenderLog.entries(folder: logs).first?.result, "failed")
    }

    func testSizeCapKeepsOnlyImportantLines() throws {
        let l = try RenderLog(exportID: "cap", outputName: "cap.mkv", folder: logs)
        let filler = String(repeating: "x", count: 7000)
        for _ in 0..<2500 { l.info(filler) }            // ~17.5 MB of chatter
        l.warn("still here")
        l.info("dropped")
        l.close()
        let text = try String(contentsOf: l.url, encoding: .utf8)
        XCTAssertLessThan(Int64(text.utf8.count), RenderLog.maxBytes + (1 << 20))
        XCTAssertTrue(text.contains("log truncated at 16 MB"))
        XCTAssertTrue(text.contains("still here"))
        XCTAssertFalse(text.hasSuffix("dropped\n"))
    }

    func testPruningKeepsResumableExportsLogs() throws {
        let fm = FileManager.default
        func make(_ name: String, daysOld: Double, bytes: Int = 10) throws -> URL {
            let u = logs.appendingPathComponent(name)
            try Data(repeating: 65, count: bytes).write(to: u)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: u.path)
            return u
        }
        let old = try make("old.log", daysOld: 40)
        let resumable = try make("resumable.log", daysOld: 45)
        let fresh = try make("fresh.log", daysOld: 1)
        let notALog = try make("notes.txt", daysOld: 90)
        for i in 0..<205 { _ = try make(String(format: "many-%03d.log", i), daysOld: 2 + Double(i) / 1000) }
        RenderLog.prune(folder: logs, keep: ["resumable.log"])
        XCTAssertFalse(fm.fileExists(atPath: old.path), "older than 30 days")
        XCTAssertTrue(fm.fileExists(atPath: resumable.path), "an export that can still resume keeps its log")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: notALog.path), "only logs are pruned")
        let count = try fm.contentsOfDirectory(atPath: logs.path).filter { $0.hasSuffix(".log") }.count
        XCTAssertLessThanOrEqual(count, RenderLog.keepCount + 1)
    }

    func testCommandsAndStderrAreScrubbedAndSplitOnCarriageReturns() throws {
        let l = try RenderLog(exportID: "scrub", outputName: "s.mkv", folder: logs)
        l.command("x265", ["--input", NSHomeDirectory() + "/Movies/My Clip.y4m", "-o", "/tmp/a b.hevc"])
        l.stderrTail("frame 1\rframe 2\rframe 3\nx265 [error]: bad\n", lines: 2, tag: "seg 0")
        l.close()
        let text = try String(contentsOf: l.url, encoding: .utf8)
        XCTAssertTrue(text.contains("x265 --input '~/Movies/My Clip.y4m' -o '/tmp/a b.hevc'"), text)
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertTrue(text.contains("STDERR seg 0 frame 3"))
        XCTAssertTrue(text.contains("STDERR seg 0 x265 [error]: bad"))
        XCTAssertFalse(text.contains("frame 2"), "only the last lines")
    }

    func testTwoExportsAtOnceKeepSeparateLogs() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("log-src.mp4", seconds: 2))
        let a = ExportEngine(), b = ExportEngine()
        let ja = job(p, codec: .av1, name: "first.mkv"), jb = job(p, codec: .av1, name: "second.mkv")
        async let ra = a.run(ja) { _, _ in }
        async let rb = b.run(jb) { _, _ in }
        _ = try await (ra, rb)
        let la = Self.log(a), lb = Self.log(b)
        XCTAssertNotEqual(a.session?.logURL, b.session?.logURL)
        XCTAssertTrue(la.contains("first.mkv") && !la.contains("second.mkv"), "the first log only has the first export")
        XCTAssertTrue(lb.contains("second.mkv") && !lb.contains("first.mkv"), "the second log only has the second export")
    }

    /// A completely full startup disk: no log file can be made anywhere, and the export still starts (no crash).
    func testExportStartsWhenNoLogCanBeWritten() {
        setDefault("renderLogFolder", "/dev/null/logs")
        RenderSession.fallbackLogFolder = URL(fileURLWithPath: "/dev/null/tmp-logs")
        let s = RenderSession(job: Self.tinyJob())
        XCTAssertFalse(s.log.isWritable)
        XCTAssertNil(s.journal.logFile, "the journal doesn't point at a log that doesn't exist")
        s.log.info("written nowhere")
        s.log.close()
    }

    func testDiagnosticReportFromARealLog() async throws {
        let l = try RenderLog(exportID: "rep", outputName: "Holiday Natural.mkv", folder: logs)
        l.raw("Lumora export log\nSource: \(NSHomeDirectory())/Movies/Holiday.mov\nOutput: /Volumes/Family Drive/Holiday Natural.mkv")
        for i in 0..<400 { l.info("line \(i)") }
        l.close()
        let r = FailureExplainer.explain(RenderFailure(kind: .diskFull, stage: .encode, volume: "Family Drive", message: "No space"))
        let names = DiagnosticScrub.names(source: URL(fileURLWithPath: "/x/Holiday.mov"), output: URL(fileURLWithPath: "/y/Holiday Natural.mkv"))
        let report = DiagnosticReport.make(r, logURL: l.url, names: names)
        XCTAssertTrue(report.contains("line 399"))
        XCTAssertFalse(report.contains("line 50\n"), "only the last 300 lines (plus the header)")
        XCTAssertTrue(report.contains("Lumora export log"), "the header is included")
        XCTAssertFalse(report.contains("Holiday"))
        XCTAssertFalse(report.contains("Family Drive"))
        XCTAssertFalse(report.contains(NSUserName()))
    }
}
