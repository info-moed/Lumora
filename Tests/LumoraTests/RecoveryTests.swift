import XCTest
import Metal
@testable import Lumora

/// Real exports that fail on purpose (faults injected through FaultInjection, nothing mounted or filled): each one
/// must end with the right plain-language explanation, keep the finished work, and recover cleanly.
final class RecoveryTests: RecoveryTestCase {

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T?
        var value: T? { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    var prepared: CampaignRobustnessTests.Prepared!

    /// 96 frames (two shots), four 24-frame segments.
    func svtJob(_ name: String, source: URL? = nil) async throws -> ExportJob {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let src = try source ?? Self.makeSource("recovery-src.mp4")
        prepared = try await Self.prepare(src)
        CheckpointPlanner.segmentFramesOverride = 24
        return job(prepared, codec: .av1, name: name)
    }

    func reference(_ name: String = "reference.mkv") async throws -> URL {
        let j = job(prepared, codec: .av1, name: name)
        return try await ExportEngine().run(j) { _, _ in }
    }

    /// Kills the encoder of `segment` (on the attempts `when` allows) after it took 10 frames.
    func killEncoder(segment: Int, signal: Int32, when: @escaping (Int) -> Bool) {
        let pid = Box<Int32>()
        FaultInjection.onEncoderStarted = { p, seg, _ in if seg == segment { pid.value = p.processIdentifier } }
        FaultInjection.handler = { point, attempt in
            guard case .afterFrameWritten(let seg, 10) = point, seg == segment, when(attempt), let p = pid.value else { return }
            kill(p, signal)
            // Wait until it is gone (Foundation reaps it), so the next frame write meets a dead encoder.
            for _ in 0..<200 where kill(p, 0) == 0 { usleep(5000) }
        }
    }

    // MARK: Encoders

    func testEncoderKilledOnceIsRetriedAndMatchesUninterrupted() async throws {
        let j = try await svtJob("retried.mkv")
        let ref = try await reference()
        killEncoder(segment: 1, signal: SIGKILL) { $0 == 1 }
        let e = ExportEngine()
        let url = try await e.run(j) { _, _ in }
        let log = Self.log(e)
        XCTAssertTrue(log.contains("RETRY  seg 1 attempt 1 failed (toolCrashed)"), "the crash is retried")
        XCTAssertEqual(try Self.frames(url), try Self.frames(ref), "the retried export equals an uninterrupted one")
        print("[recovery] encoder killed once: retried, frames identical")
    }

    func testEncoderCrashingEveryTimeIsExplainedAndResumable() async throws {
        let j = try await svtJob("crashing.mkv")
        killEncoder(segment: 1, signal: SIGSEGV) { _ in true }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .toolCrashed)
        XCTAssertEqual(r.failure.tool, "SvtAv1EncApp")
        XCTAssertEqual(r.failure.signal, SIGSEGV)
        XCTAssertTrue(r.simple.contains("crashed again"), r.simple)
        XCTAssertTrue(r.proLine.contains("SIGSEGV"), r.proLine)
        XCTAssertEqual(r.progressText, "25%")
        XCTAssertEqual(r.actions.first?.label(r), "Resume from 25%")
        let journal = try savedJournal()
        XCTAssertEqual(journal.state, .failed)
        FaultInjection.reset()
        CheckpointPlanner.segmentFramesOverride = 24
        let again = ExportEngine()
        _ = try await again.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        XCTAssertEqual(again.session?.encodedSegments.sorted(), [1, 2, 3])
    }

    func testEncoderKilledUnderMemoryPressureIsOutOfMemory() async throws {
        let j = try await svtJob("oom.mkv")
        MemoryPressureWatch.override = .critical
        RenderSession.pressureWait = 0.2
        killEncoder(segment: 1, signal: SIGKILL) { _ in true }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .outOfMemory)
        XCTAssertEqual(r.actions.first, .resumeLessMemory)
        XCTAssertTrue(Self.log(e).contains("RETRY"), "retried once after the pressure eased (or the wait ran out)")
        // "Resume using less memory": one segment at a time.
        MemoryPressureWatch.override = nil
        FaultInjection.handler = nil
        let journal = try savedJournal()
        let again = ExportEngine()
        _ = try await again.run(j, options: RecoveryOptions(resume: journal, lessMemory: true)) { _, _ in }
        XCTAssertEqual(again.session?.plan?.workers, 1)
    }

    func testRejectedSettingIsNamed() async throws {
        var j = try await svtJob("bogus.mkv")
        j.encodeChoice = EncodeChoice(codec: .av1, rungID: "test", rungLabel: "test", presetValue: "12", optionIDs: ["custom"],
                                      extraArgs: ["--bogus-opt", "3"])
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .encoderRejectedSetting)
        XCTAssertEqual(r.failure.setting, "--bogus-opt")
        XCTAssertTrue(r.simple.contains("“--bogus-opt”"), r.simple)
        XCTAssertFalse(Self.log(e).contains("RETRY"), "a setting is never retried")
    }

    // MARK: Drives

    func testScratchFullIsExplainedAndResumesToTheSameFrames() async throws {
        let j = try await svtJob("full.mkv")
        let ref = try await reference()
        FaultInjection.handler = { point, _ in if case .beforeSegment(2) = point { throw POSIXError(.ENOSPC) } }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .diskFull)
        XCTAssertNotNil(r.failure.volume, "names the drive")
        XCTAssertTrue(r.simple.contains("“\(r.failure.volume ?? "?")”"), r.simple)
        XCTAssertEqual(r.progressText, "50%")
        XCTAssertTrue(r.means.contains("50% of the export is saved"), r.means)
        FaultInjection.handler = nil
        let again = ExportEngine()
        let url = try await again.run(j, options: RecoveryOptions(resume: try savedJournal())) { _, _ in }
        XCTAssertEqual(again.session?.encodedSegments.sorted(), [2, 3])
        XCTAssertEqual(try Self.frames(url), try Self.frames(ref))
    }

    func testFullOutputDriveKeepsTheFinishedVideo() async throws {
        let j = try await svtJob("deliver.mkv")
        FaultInjection.handler = { point, _ in
            if case .deliver = point { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .diskFull)
        XCTAssertEqual(r.failure.stage, .deliver)
        XCTAssertTrue(r.finishedVideoKept)
        XCTAssertTrue(r.means.contains("Nothing has to be rendered again"), r.means)
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.outputURL.path))
        let journal = try savedJournal()
        XCTAssertNotNil(journal.finalFile)
        // "Save to another folder…": only the move is left, no encoder runs.
        FaultInjection.handler = nil
        var elsewhere = j
        let other = out.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        elsewhere.outputURL = other.appendingPathComponent("deliver.mkv")
        let again = ExportEngine()
        let url = try await again.run(elsewhere, options: RecoveryOptions(resume: journal)) { _, _ in }
        let resumed = Self.log(again).components(separatedBy: "=== Resumed").last ?? ""
        XCTAssertEqual(Self.encoderLaunches(resumed, "SvtAv1EncApp"), 0, "no encoder launched to save again")
        XCTAssertEqual(try Self.frames(url).hashes.count, prepared.analysis.frameCount)
        XCTAssertTrue(Self.checkpointFolders().isEmpty)
    }

    func testOutputFolderDeletedNearTheEnd() async throws {
        let j = try await svtJob("gone.mkv")
        let folder = out!
        FaultInjection.handler = { point, _ in
            if case .beforeSegment(3) = point { try? FileManager.default.removeItem(at: folder) }
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .outputDriveGone, "\(r.failure)")
        XCTAssertTrue(r.finishedVideoKept)
        XCTAssertEqual(r.actions.first, .saveAgain)
    }

    func testReadOnlyOutputFolderKeepsTheResult() async throws {
        let j = try await svtJob("readonly.mkv")
        let folder = out!
        FaultInjection.handler = { point, _ in
            if case .beforeSegment(3) = point { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .noPermission, "\(r.failure)")
        XCTAssertTrue(r.finishedVideoKept)
        XCTAssertTrue(r.simple.contains("read-only"), r.simple)
    }

    // MARK: GPU and hardware encoder

    func testGPUFaultIsRetriedOnceThenSucceeds() async throws {
        let j = try await svtJob("gpu-once.mkv")
        let ref = try await reference()
        FaultInjection.gpuError = { n in
            n == 40 ? NSError(domain: MTLCommandBufferErrorDomain, code: Int(MTLCommandBufferError.timeout.rawValue)) : nil
        }
        let e = ExportEngine()
        let url = try await e.run(j) { _, _ in }
        XCTAssertTrue(Self.log(e).contains("failed (gpuError)"))
        XCTAssertEqual(try Self.frames(url), try Self.frames(ref), "the retried segment is identical")
    }

    func testPersistentGPUFaultIsExplained() async throws {
        let j = try await svtJob("gpu-always.mkv")
        FaultInjection.gpuError = { n in
            n > 30 ? NSError(domain: MTLCommandBufferErrorDomain, code: Int(MTLCommandBufferError.pageFault.rawValue)) : nil
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .gpuError)
        XCTAssertTrue(r.simple.contains("GPU stopped while grading the frame at"), r.simple)
        XCTAssertTrue(r.proLine.contains("MTLCommandBufferErrorDomain 3"), r.proLine)
    }

    func testHardwareEncoderResetAfterSleepIsRetried() async throws {
        try TestHardware.requireHardwareHEVC()
        let p = try await Self.prepare(try Self.makeSource("recovery-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .hevc, name: "vt-reset.mov")
        let engine = ExportEngine()
        FaultInjection.handler = { [engine] point, attempt in
            guard case .writerAppend(1, 12) = point, attempt == 1 else { return }
            engine.session?.simulateSleepWake()
            throw NSError(domain: NSOSStatusErrorDomain, code: -12903)
        }
        let url = try await engine.run(j) { _, _ in }
        let log = Self.log(engine)
        XCTAssertTrue(log.contains("the Mac is going to sleep"))
        XCTAssertTrue(log.contains("the export continued"))
        XCTAssertTrue(log.contains("failed (hardwareEncoderReset)"))
        XCTAssertEqual(try Self.frames(url).hashes.count, p.analysis.frameCount)
    }

    // MARK: Metadata tools

    func metadataFailure(_ delivery: DeliveryFormat, tool: String) async throws {
        try TestHardware.requireGPU(); try Self.requireTool("x265"); try Self.requireTool(tool); try Self.requireTool("MP4Box")
        let p = try await Self.prepare(try Self.makeSource("recovery-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 48
        let j = job(p, codec: .hevc12, delivery: delivery, name: "meta-\(delivery.rawValue).mkv")
        FaultInjection.handler = { point, _ in
            if case .metadataStep(let t) = point, t == tool {
                throw ToolFailure(tool: tool, exitStatus: 1, stderrTail: "Error: Invalid input file type.")
            }
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .metadataToolFailed)
        XCTAssertEqual(r.failure.tool, tool)
        XCTAssertTrue(r.simple.contains("encoded fine"), r.simple)
        XCTAssertEqual(r.actions.first, .retryLastStep)
        XCTAssertTrue(r.actions.contains(.saveWithoutDynamicMetadata))
        XCTAssertEqual(r.progress, 1, "the encoded video is saved")
        FaultInjection.handler = nil
        let journal = try savedJournal()
        XCTAssertNotNil(journal.joinedFile)

        // "Try the last step again": no encoding.
        let again = ExportEngine()
        let url = try await again.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        let resumed = Self.log(again).components(separatedBy: "=== Resumed").last ?? ""
        XCTAssertEqual(Self.encoderLaunches(resumed, "x265"), 0, "the last step alone is repeated")
        XCTAssertTrue(resumed.contains(" CMD ") && resumed.contains(tool), "the metadata tool ran again")
        XCTAssertEqual(try Self.frames(url).hashes.count, p.analysis.frameCount)
    }

    func testDolbyVisionToolFailureRetriesOnlyTheLastStep() async throws { try await metadataFailure(.dolbyVision81, tool: "dovi_tool") }
    func testHDR10PlusToolFailureRetriesOnlyTheLastStep() async throws { try await metadataFailure(.hdr10Plus, tool: "hdr10plus_tool") }

    func testSaveWithoutDolbyVisionGivesAValidHDR10File() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("x265"); try Self.requireTool("dovi_tool")
        let p = try await Self.prepare(try Self.makeSource("recovery-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 48
        let j = job(p, codec: .hevc12, delivery: .dolbyVision81, name: "no-dv.mkv")
        FaultInjection.handler = { point, _ in
            if case .metadataStep("dovi_tool") = point { throw ToolFailure(tool: "dovi_tool", exitStatus: 1, stderrTail: "Error: boom") }
        }
        _ = await failure(ExportEngine(), j)
        FaultInjection.handler = nil
        let url = try await ExportEngine().run(j, options: RecoveryOptions(resume: try savedJournal(), skipDynamicMetadata: true)) { _, _ in }
        XCTAssertTrue(try Self.streamInfo(url, "stream=color_transfer").contains("smpte2084"))
        XCTAssertEqual(try Self.frames(url).hashes.count, p.analysis.frameCount)
    }

    // MARK: Source

    func testSourceModifiedMidExportIsCaughtAtTheNextSegment() async throws {
        let src = try Self.copy(try Self.makeSource("recovery-src.mp4"), as: "changing.mp4")
        let j = try await svtJob("changed.mkv", source: src)
        FaultInjection.handler = { point, _ in
            guard case .beforeSegment(2) = point else { return }
            let h = try FileHandle(forWritingTo: src)
            try h.seekToEnd(); try h.write(contentsOf: Data(repeating: 1, count: 1024)); try h.close()
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .sourceChanged)
        XCTAssertEqual(r.actions.first, .startOver)
    }

    func testSourceDeletedMidExportThenLocated() async throws {
        let original = try Self.makeSource("recovery-src.mp4")
        let src = try Self.copy(original, as: "moving.mp4")
        let j = try await svtJob("moved.mkv", source: src)
        FaultInjection.handler = { point, _ in
            if case .beforeSegment(2) = point { try FileManager.default.removeItem(at: src) }
        }
        let e = ExportEngine()
        _ = await failure(e, j)
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertEqual(r.failure.kind, .sourceMoved)
        XCTAssertEqual(r.actions.first, .locateSource)
        // "Locate the file…": the same file, found again; the fingerprint matches, so the export resumes.
        FaultInjection.handler = nil
        _ = try Self.copy(original, as: "moving.mp4")
        let again = ExportEngine()
        _ = try await again.run(j, options: RecoveryOptions(resume: try savedJournal())) { _, _ in }
        XCTAssertEqual(again.session?.encodedSegments.sorted(), [2, 3])
    }

    // MARK: Cancel

    func testCancelKeepsProgressOnlyWhenAsked() async throws {
        let j = try await svtJob("cancel.mkv")
        for keep in [false, true] {
            let task = Box<Task<URL, Error>>()
            FaultInjection.handler = { point, _ in if case .beforeSegment(2) = point { task.value?.cancel() } }
            let e = ExportEngine()
            let t = Task { try await e.run(j, options: RecoveryOptions(keepProgressOnCancel: keep)) { _, _ in } }
            task.value = t
            do { _ = try await t.value; XCTFail("canceled") } catch {}
            XCTAssertEqual(e.lastFailure?.failure.kind, .cancelled)
            if keep {
                let journal = try savedJournal()
                XCTAssertEqual(journal.state, .cancelledKept)
                XCTAssertTrue(e.lastFailure?.means.contains("kept the finished part (50%)") ?? false, e.lastFailure?.means ?? "")
                FaultInjection.handler = nil
                let again = ExportEngine()
                _ = try await again.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
                XCTAssertEqual(again.session?.encodedSegments.sorted(), [2, 3])
            } else {
                XCTAssertTrue(Self.checkpointFolders().isEmpty, "a plain stop leaves nothing behind")
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasPrefix("export-") && !$0.hasPrefix("grain-") }, "\(leftovers)")
    }
}
