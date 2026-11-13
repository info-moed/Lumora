import XCTest
@testable import Lumora

/// Checkpointed exports: an export that stops part way (a crash, a quit, a power loss) resumes in a fresh engine,
/// encodes only the missing segments, and gives the same frames, timestamps, audio and HDR signaling as an export
/// that never stopped.
final class ResumeTests: RecoveryTestCase {

    struct Outcome { var reference: URL; var resumed: URL; var encodedOnResume: Int; var planned: Int; var log: String }

    /// Uninterrupted reference, then the same export "crashing" after `crashAfter` journaled segments, then a resume.
    @discardableResult
    func resumeMatches(_ codec: Codec, binary: String?, delivery: DeliveryFormat = .sdr, segmentFrames: Int = 24,
                       crashAfter: Int = 2, source: String = "resume-src.mp4", seconds: Double = 4,
                       width: Int = 320, height: Int = 180, exact: Bool = true,
                       configure: (inout ExportJob) -> Void = { _ in }) async throws -> Outcome {
        try TestHardware.requireGPU()
        if let binary { try Self.requireTool(binary) }
        let src = try Self.makeSource(source, width: width, height: height, seconds: seconds)
        let p = try await Self.prepare(src)
        CheckpointPlanner.segmentFramesOverride = segmentFrames
        let ext = codec.defaultContainer == "mkv" && codec == .hevc12 ? "mp4" : codec.defaultContainer

        var refJob = job(p, codec: codec, delivery: delivery, name: "reference.\(ext)")
        configure(&refJob)
        let started = Date()
        let reference = try await ExportEngine().run(refJob) { _, _ in }
        let refSeconds = Date().timeIntervalSince(started)
        XCTAssertTrue(Self.checkpointFolders().isEmpty, "no saved progress is left after a finished export")

        var j = job(p, codec: codec, delivery: delivery, name: "resumed.\(ext)")
        configure(&j)
        FaultInjection.crashAfterSegments = crashAfter
        let first = ExportEngine()
        do {
            _ = try await first.run(j) { _, _ in }
            XCTFail("the simulated crash should stop the export")
        } catch is FaultInjection.SimulatedCrash {}
        FaultInjection.crashAfterSegments = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.outputURL.path), "nothing is delivered by a crashed export")
        let journal = try savedJournal()
        let planned = try XCTUnwrap(journal.plan).segments.count
        XCTAssertEqual(journal.segments.count, crashAfter)
        XCTAssertEqual(journal.state, .running, "a crash leaves the journal as it was")

        // The next launch finds it.
        let offers = ResumeCoordinator.scan()
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.percent, Int(Double(journal.savedFrames) / Double(journal.plan!.frames) * 100))

        let resumedAt = Date()
        let second = ExportEngine()
        let resumed = try await second.run(j, options: RecoveryOptions(resume: try XCTUnwrap(offers.first).journal)) { _, _ in }
        let resumeSeconds = Date().timeIntervalSince(resumedAt)
        let s = try XCTUnwrap(second.session)
        XCTAssertEqual(s.encodedSegments.count, planned - crashAfter, "only the missing segments are encoded")
        XCTAssertEqual(Set(s.reusedSegments), Set(0..<crashAfter))
        let log = Self.log(second)
        if let binary {
            let afterResume = log.components(separatedBy: "=== Resumed").last ?? ""
            XCTAssertEqual(Self.encoderLaunches(afterResume, binary), planned - crashAfter, "encoder launches after resuming")
        }

        if ext == "obu" {
            // No FFmpeg decoder for AV2: the deterministic reference encoder must give the same stream, byte for byte.
            XCTAssertEqual(try AV2Stream.summary(of: resumed).temporalUnits, p.analysis.frameCount)
            XCTAssertEqual(try SegmentValidator.sha256(resumed), try SegmentValidator.sha256(reference), "identical AV2 stream")
            XCTAssertTrue(Self.checkpointFolders().isEmpty)
            return Outcome(reference: reference, resumed: resumed, encodedOnResume: planned - crashAfter, planned: planned, log: log)
        }
        let a = try Self.frames(reference), b = try Self.frames(resumed)
        XCTAssertEqual(a.hashes.count, p.analysis.frameCount, "the reference has every frame")
        XCTAssertEqual(b.hashes.count, a.hashes.count, "same frame count")
        XCTAssertEqual(b.pts, a.pts, "same timestamps")
        if exact { XCTAssertEqual(b.hashes, a.hashes, "identical decoded frames") }
        let pts = try Self.ptsSeconds(resumed)
        let fps = Double(p.d.fpsNum) / Double(p.d.fpsDen)
        for (n, t) in pts.enumerated() { XCTAssertEqual(t - pts[0], Double(n) / fps, accuracy: 0.0006, "pts of frame \(n)") }
        if p.d.hasAudio && ext != "obu" {
            XCTAssertEqual(try Self.audioDuration(resumed), try Self.audioDuration(reference), accuracy: 0.03, "audio intact")
        }
        if ext != "obu" {
            let tags = "stream=color_primaries,color_transfer,color_space,pix_fmt"
            XCTAssertEqual(try Self.streamInfo(resumed, tags), try Self.streamInfo(reference, tags), "same color signaling")
        }
        XCTAssertTrue(Self.checkpointFolders().isEmpty, "saved progress is removed after the resumed export finishes")
        print(String(format: "[resume] %@: reference %.1f s, resume %.1f s (%d of %d segments encoded), frames identical: %@",
                     codec.displayName, refSeconds, resumeSeconds, planned - crashAfter, planned, a.hashes == b.hashes ? "yes" : "no"))
        return Outcome(reference: reference, resumed: resumed, encodedOnResume: planned - crashAfter, planned: planned, log: log)
    }

    // MARK: Every path

    func testSVTAV1ResumeMatchesUninterrupted() async throws { try await resumeMatches(.av1, binary: "SvtAv1EncApp") }
    func testAomencResumeMatchesUninterrupted() async throws { try await resumeMatches(.av1Pro, binary: "aomenc", seconds: 3) }
    func testX265ResumeMatchesUninterrupted() async throws { try await resumeMatches(.hevc12, binary: "x265") }
    /// VVC segments are at least 64 frames (two VVenC GOPs; see CheckpointPlanner.minFrames), so 8 s gives 3 segments.
    func testVVenCResumeMatchesUninterrupted() async throws {
        try await resumeMatches(.vvc, binary: "vvencapp", segmentFrames: 64, crashAfter: 1, seconds: 8)
    }

    /// The planner never cuts VVC shorter than two VVenC GOPs, even when asked to.
    func testVVCSegmentsAreNeverShorterThanTwoGOPs() {
        CheckpointPlanner.segmentFramesOverride = 24
        defer { CheckpointPlanner.segmentFramesOverride = nil }
        let i = CheckpointPlanner.Input(frames: 200, fps: 24, pixels: 320 * 180, codec: .vvc, workers: 2, cutStarts: [],
                                        shotStart: { _ in 0 }, measuredFps1080: nil)
        let segs = CheckpointPlanner.plan(i)
        XCTAssertEqual(segs.reduce(0) { $0 + $1.count }, 200)
        XCTAssertTrue(segs.allSatisfy { $0.count >= 64 }, "\(segs.map(\.count))")
        var other = i; other.codec = .av1
        XCTAssertEqual(CheckpointPlanner.plan(other).count, 9, "other codecs keep the forced length")
    }

    func testHardwareHEVCResumeMatchesUninterrupted() async throws {
        try TestHardware.requireHardwareHEVC()
        try await resumeMatches(.hevc, binary: nil)
    }

    func testProResResumeMatchesUninterrupted() async throws {
        try TestHardware.requireProRes()
        try await resumeMatches(.prores422HQ, binary: nil)
    }

    func testAV2ResumeMatchesUninterrupted() async throws {
        try Self.requireTool("avmenc")
        try await resumeMatches(.av2, binary: "avmenc", segmentFrames: 8, crashAfter: 1, source: "resume-av2.mp4", seconds: 1,
                                width: 160, height: 90)
    }

    func testHDR10ResumeKeepsStaticMetadata() async throws {
        let o = try await resumeMatches(.hevc12, binary: "x265", delivery: .hdr10)
        let side = "stream_side_data=max_content,max_average,red_x,white_point_x,max_luminance"
        XCTAssertEqual(try Self.streamInfo(o.resumed, side), try Self.streamInfo(o.reference, side), "mastering display and CLL")
        XCTAssertTrue(try Self.streamInfo(o.resumed, "stream=color_transfer").contains("smpte2084"))
    }

    /// Dolby Vision RPUs and HDR10+ metadata are generated for the joined video, so a resumed export carries exactly
    /// the same per-frame metadata as an uninterrupted one.
    func dynamicMetadataMatches(_ delivery: DeliveryFormat, tool: String) async throws {
        try Self.requireTool(tool)
        let o = try await resumeMatches(.hevc12, binary: "x265", delivery: delivery, segmentFrames: 48, crashAfter: 1)
        func extract(_ url: URL) throws -> Data {
            let es = url.deletingPathExtension().appendingPathExtension("hevc")
            try Self.ff(["-i", url.path, "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", es.path])
            let meta = url.deletingPathExtension().appendingPathExtension(tool == "dovi_tool" ? "rpu" : "json")
            let exe = try XCTUnwrap(ToolLocator.url(for: tool)).path
            if tool == "dovi_tool" { try Self.run(exe, ["extract-rpu", "-i", es.path, "-o", meta.path]) }
            else { try Self.run(exe, ["extract", es.path, "-o", meta.path]) }
            return try Data(contentsOf: meta)
        }
        let a = try extract(o.reference), b = try extract(o.resumed)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "\(tool): per-frame metadata identical after resuming")
        if tool == "dovi_tool" {
            let info = try Self.run(try XCTUnwrap(ToolLocator.url(for: tool)).path,
                                    ["info", "-i", o.resumed.deletingPathExtension().appendingPathExtension("rpu").path, "--summary"],
                                    allowFailure: true)
            XCTAssertTrue(info.contains("96") || info.isEmpty, "one RPU per frame: \(info.prefix(300))")
        }
    }

    func testDolbyVisionRPUsMatchAfterResume() async throws { try await dynamicMetadataMatches(.dolbyVision81, tool: "dovi_tool") }
    func testHDR10PlusMetadataMatchesAfterResume() async throws { try await dynamicMetadataMatches(.hdr10Plus, tool: "hdr10plus_tool") }

    /// Target quality resumes per chunk: finished chunks keep their pieces and levels; only the missing chunks are
    /// searched again, and the manifest's chunk map equals an uninterrupted export's.
    func testTargetQualityResumesPerChunk() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        guard VMAFRunner.available else { throw XCTSkip("VMAF not available") }
        let p = try await Self.prepare(try Self.makeSource("resume-tq.mp4", seconds: 4))
        let target = await CampaignQualityTests.vmafOnly(90)
        // One chunk at a time (in memory only, restored after), so "crash after the first chunk" is exact.
        let savedProfile = MacProfile.current
        var profile = savedProfile ?? MacProfile(machine: MacProfile.machineModel, chip: "test", os: MacProfile.osVersion,
                                                 created: Date(), level: "test")
        profile.concurrentChunks = 1
        MacProfile.current = profile
        defer { MacProfile.current = savedProfile }
        func tqJob(_ name: String) -> ExportJob {
            var j = job(p, codec: .av1, name: name)
            j.qualityTarget = target
            j.qualityTarget?.maxTrials = 2
            return j
        }
        let refEngine = ExportEngine()
        let reference = try await refEngine.run(tqJob("tq-reference.mkv")) { _, _ in }
        let refChunks = refEngine.lastPieces.map { [$0.start, $0.count] }
        let refLevels = refEngine.lastPieces.map(\.level)
        XCTAssertGreaterThanOrEqual(refChunks.count, 2, "at least two chunks")

        let j = tqJob("tq-resumed.mkv")
        FaultInjection.crashAfterSegments = 1
        _ = await failure(ExportEngine(), j)
        FaultInjection.crashAfterSegments = nil
        let journal = try savedJournal()
        let chunks = try XCTUnwrap(journal.chunkPlan).count
        XCTAssertEqual(Set(journal.pieces.map(\.chunk)).count, 1, "one chunk was finished before the crash")
        let e = ExportEngine()
        let url = try await e.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        XCTAssertEqual(e.session?.reusedSegments.count, 1, "the finished chunk is reused")
        XCTAssertEqual(e.session?.encodedSegments.count, chunks - 1, "only the missing chunks are searched")
        XCTAssertEqual(e.lastPieces.map { [$0.start, $0.count] }, refChunks, "same chunk map as an uninterrupted export")
        XCTAssertEqual(e.lastPieces.map(\.level), refLevels, "same encoder levels")
        XCTAssertEqual(try Self.frames(url), try Self.frames(reference), "identical frames")
        print("[resume] target quality: \(chunks) chunks, 1 reused, \(chunks - 1) searched again; frames identical")
    }

    /// Measurement, run on demand (LUMORA_RECOVERY_BENCH=1): what checkpointing costs on a 1280×720, 6-second
    /// SVT-AV1 export, as one segment versus three 2-second segments (each flushed, validated and journaled, the
    /// later ones starting with up to 16 preroll frames).
    func testCheckpointOverheadMeasurement() async throws {
        guard ProcessInfo.processInfo.environment["LUMORA_RECOVERY_BENCH"] == "1" else { throw XCTSkip("measurement: LUMORA_RECOVERY_BENCH=1") }
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("bench.mp4", width: 1280, height: 720, seconds: 6))
        var results: [(segments: Int, seconds: Double, bytes: Int)] = []
        for (n, frames) in [(1, 144), (3, 48), (1, 144), (3, 48)].enumerated() {
            CheckpointPlanner.segmentFramesOverride = frames.1
            let j = job(p, codec: .av1, name: "bench-\(n).mkv")
            let t0 = Date()
            let e = ExportEngine()
            let url = try await e.run(j) { _, _ in }
            let dt = Date().timeIntervalSince(t0)
            let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            results.append((e.session?.plan?.segments.count ?? 0, dt, size))
            print(String(format: "[bench] %d segment(s): %.2f s, %d bytes", e.session?.plan?.segments.count ?? 0, dt, size))
        }
        let one = results.filter { $0.segments == 1 }, three = results.filter { $0.segments == 3 }
        let t1 = one.map(\.seconds).min() ?? 0, t3 = three.map(\.seconds).min() ?? 0
        print(String(format: "[bench] checkpoint overhead: %.2f s for 2 extra segments (%.1f%%), size %+.2f%%", t3 - t1,
                     (t3 - t1) / max(0.001, t1) * 100, (Double(three[0].bytes) - Double(one[0].bytes)) / Double(one[0].bytes) * 100))
    }

    // MARK: Durability

    func testCrashBetweenSegmentAndJournalRedoesThatSegment() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("resume-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .av1, name: "between.mkv")
        FaultInjection.crashBetweenSegmentAndJournal = 1
        _ = await failure(ExportEngine(), j)
        FaultInjection.crashBetweenSegmentAndJournal = nil
        let journal = try savedJournal()
        XCTAssertEqual(journal.segments.map(\.index), [0], "segment 1 was written but never journaled")
        let segDir = CheckpointStore.folder(journal.exportID).appendingPathComponent("segments")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: segDir.path).count, 2, "the stray file is on disk")
        let e = ExportEngine()
        _ = try await e.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        XCTAssertEqual(e.session?.encodedSegments.sorted(), Array(1..<(journal.plan?.segments.count ?? 0)))
        XCTAssertTrue(Self.log(e).contains("not in the journal"), "the stale file is removed")
        XCTAssertEqual(try Self.frames(j.outputURL).hashes.count, p.analysis.frameCount)
    }

    func testTornJournalWriteKeepsThePreviousJournal() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("resume-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .av1, name: "torn.mkv")
        FaultInjection.handler = { point, _ in
            if case .beforeSegment(2) = point {
                FaultInjection.tearJournalTmp = true      // the next journal write is cut off by a "power loss"
            }
            if case .beforeSegment(3) = point { throw FaultInjection.SimulatedCrash() }
        }
        _ = await failure(ExportEngine(), j)
        FaultInjection.handler = nil
        FaultInjection.tearJournalTmp = false
        let dir = try XCTUnwrap(Self.checkpointFolders().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal.json.tmp").path))
        let journal = try XCTUnwrap(CheckpointStore.load(dir), "the last complete journal is still readable")
        XCTAssertEqual(journal.segments.count, 2, "segment 2's journal entry was lost with the torn write")
        let e = ExportEngine()
        _ = try await e.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        XCTAssertEqual(e.session?.encodedSegments.sorted(), [2, 3])
    }

    /// Segments finishing at the same moment save the journal at the same moment: every save must land.
    func testConcurrentJournalSavesAllSucceed() async throws {
        let dir = try CheckpointStore.create("concurrent")
        let base = ExportJournal(exportID: "concurrent", recipeHash: "h", renderVersion: CheckpointStore.renderVersion,
                                 source: nil, sourceName: "s.mp4", outputPath: out.appendingPathComponent("o.mkv").path)
        let failures = await withTaskGroup(of: Int.self) { g in
            for n in 0..<64 {
                g.addTask {
                    var j = base
                    j.lastEvent = "save \(n)"
                    return (try? CheckpointStore.save(j, in: dir)) == nil ? 1 : 0
                }
            }
            return await g.reduce(0, +)
        }
        XCTAssertEqual(failures, 0, "no save may find another save's journal.json.tmp gone")
        XCTAssertNotNil(CheckpointStore.load(dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal.json.tmp").path))
        CheckpointStore.discard("concurrent")
    }

    func testSegmentDamagedOnDiskIsRejectedAndRedone() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("resume-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .av1, name: "damaged-seg.mkv")
        FaultInjection.crashAfterSegments = 3
        _ = await failure(ExportEngine(), j)
        FaultInjection.crashAfterSegments = nil
        let journal = try savedJournal()
        // A power loss tore the end off segment 1.
        let seg1 = CheckpointStore.folder(journal.exportID).appendingPathComponent(journal.segments[1].file)
        let h = try FileHandle(forUpdating: seg1)
        try h.truncate(atOffset: UInt64(journal.segments[1].bytes / 2))
        try h.close()
        let e = ExportEngine()
        _ = try await e.run(j, options: RecoveryOptions(resume: journal)) { _, _ in }
        XCTAssertEqual(e.session?.encodedSegments.sorted(), [1, 3])
        XCTAssertTrue(Self.log(e).contains("can't be reused"))
        XCTAssertEqual(try Self.frames(j.outputURL).hashes.count, p.analysis.frameCount)
    }

    func testResumeRefusedWhenSourceChanged() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let src = try Self.copy(try Self.makeSource("resume-src.mp4"), as: "refuse-src.mp4")
        let p = try await Self.prepare(src)
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .av1, name: "refused.mkv")
        FaultInjection.crashAfterSegments = 1
        _ = await failure(ExportEngine(), j)
        FaultInjection.crashAfterSegments = nil
        let journal = try savedJournal()
        let h = try FileHandle(forWritingTo: src)
        try h.seekToEnd(); try h.write(contentsOf: Data(repeating: 7, count: 4096)); try h.close()
        let e = ExportEngine()
        let err = await failure(e, j, options: RecoveryOptions(resume: journal))
        XCTAssertTrue(err is ResumeRefused, "\(String(describing: err))")
        XCTAssertEqual(e.lastFailure?.actions.first, .startOver)
        XCTAssertTrue(e.lastFailure?.simple.contains("changed") ?? false)
    }

    func testResumeRefusedWhenEncoderOrRenderVersionChanged() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let p = try await Self.prepare(try Self.makeSource("resume-src.mp4"))
        CheckpointPlanner.segmentFramesOverride = 24
        let j = job(p, codec: .av1, name: "refused2.mkv")
        FaultInjection.crashAfterSegments = 1
        _ = await failure(ExportEngine(), j)
        FaultInjection.crashAfterSegments = nil
        var journal = try savedJournal()
        journal.encode?.version = "SVT-AV1 v0.0.1"
        let e1 = ExportEngine()
        let err1 = await failure(e1, j, options: RecoveryOptions(resume: journal))
        XCTAssertTrue((err1 as? ResumeRefused)?.reason.contains("encoder changed") ?? false, "\(String(describing: err1))")
        journal = try savedJournal()
        journal.renderVersion = CheckpointStore.renderVersion - 1
        let err2 = await failure(ExportEngine(), j, options: RecoveryOptions(resume: journal))
        XCTAssertTrue((err2 as? ResumeRefused)?.reason.contains("updated") ?? false, "\(String(describing: err2))")
    }

    // MARK: Launch reasons

    func testLaunchReasonsFromSyntheticJournals() throws {
        let root = scratch.appendingPathComponent("Checkpoints")
        func make(_ id: String, _ edit: (inout ExportJournal) -> Void, heartbeat: ((inout CheckpointStore.Heartbeat) -> Void)? = nil) throws {
            let d = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: d.appendingPathComponent("segments"), withIntermediateDirectories: true)
            var j = ExportJournal(exportID: id, recipeHash: "h", renderVersion: CheckpointStore.renderVersion, source: nil,
                                  sourceName: "clip.mov", outputPath: "/tmp/out.mkv")
            j.pid = 999_999
            j.plan = .init(frames: 100, rateNum: 24, rateDen: 1, workers: 1, segments: [.init(index: 0, start: 0, count: 100, preroll: 0)])
            edit(&j)
            try CheckpointStore.save(j, in: d)
            try CheckpointStore.saveRecipe(ExportRecipe(Self.tinyJob()), in: d)
            var hb = CheckpointStore.Heartbeat(pid: j.pid, processStart: j.processStart, boot: j.bootSession, time: Date(),
                                               pressure: .normal, lastEvent: j.lastEvent)
            heartbeat?(&hb)
            try JSONEncoder.iso.encode(hb).write(to: d.appendingPathComponent("heartbeat"))
        }
        let reports = scratch.appendingPathComponent("DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        FaultInjection.diagnosticReportsFolder = reports
        CheckpointStore.isProcessAlive = { _ in false }

        try make("quit") { $0.willTerminate = true }
        try make("reboot") { $0.bootSession = "other-boot" } heartbeat: { $0.boot = "other-boot" }
        try make("asleep") { $0.bootSession = "other-boot"; $0.lastEvent = "sleep" } heartbeat: { $0.boot = "other-boot"; $0.lastEvent = "sleep" }
        try make("memory") { _ in } heartbeat: { $0.pressure = .critical; $0.time = Date().addingTimeInterval(-600) }
        try make("unknown") { _ in } heartbeat: { $0.time = Date().addingTimeInterval(-600) }
        func reason(_ id: String) -> RenderFailure.Kind? {
            let d = root.appendingPathComponent(id)
            return CheckpointStore.load(d).map { ResumeCoordinator.reason($0, dir: d) }
        }
        XCTAssertEqual(reason("quit"), .interruptedQuit)
        XCTAssertEqual(reason("reboot"), .interruptedRestart)
        XCTAssertEqual(reason("asleep"), .interruptedShutdownAsleep)
        XCTAssertEqual(reason("memory"), .outOfMemory)
        XCTAssertEqual(reason("unknown"), .interruptedUnknown)
        // A crash report newer than the last heartbeat.
        try Data("{\"type\":\"EXC_BAD_ACCESS\"}\nException Type: EXC_BAD_ACCESS (SIGSEGV)\n".utf8)
            .write(to: reports.appendingPathComponent("Lumora-2026-11-12-101010.ips"))
        XCTAssertEqual(reason("unknown"), .interruptedCrash)

        let offers = ResumeCoordinator.scan(root: root)
        XCTAssertEqual(offers.count, 5)
        let crash = try XCTUnwrap(offers.first { $0.id == "unknown" })
        XCTAssertEqual(crash.report.failure.kind, .interruptedCrash)
        XCTAssertTrue(crash.report.simple.contains("quit unexpectedly"))
        XCTAssertTrue(crash.report.actions.contains(.copyReport))
        XCTAssertTrue(offers.first { $0.id == "quit" }!.report.simple.contains("was quit"))
    }
}

extension RecoveryTestCase {
    /// A job that is never rendered (for journals, recipes and explanations).
    static func tinyJob(source: String = "/tmp/clip.mov", output: String = "/tmp/out.mkv") -> ExportJob {
        let d = SourceDescriptor(url: URL(fileURLWithPath: source), kind: .avfoundation)
        let preset = PresetCandidate(name: "x", look: .original, color: .testSDR, params: GradeParams(), sceneExposures: [], reason: "")
        return ExportJob(descriptor: d, preset: preset, analysis: AnalysisResult.empty, delivery: .sdr, codec: .hevc,
                         outputURL: URL(fileURLWithPath: output))
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
