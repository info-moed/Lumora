import XCTest
@testable import Lumora

/// Broken and corrupt sources: found on open (quick check) and by the full scan, explained in plain words, and repaired
/// into a NEW file. The fixtures are made here from a generated clip with the damage measured during the design:
/// truncation with and without the index, flipped bytes, a timestamp jump, a wrong extension, an empty file.
final class SourceIntegrityTests: RecoveryTestCase {

    // MARK: Fixtures

    static func good(_ ext: String = "mp4", faststart: Bool = false, bframes: Bool = false) throws -> URL {
        try makeSource("integrity-good.\(ext)", seconds: 4, gop: 24, faststart: faststart, bframes: bframes)
    }

    static func truncated(_ src: URL, as name: String, keep fraction: Double) throws -> URL {
        let u = try copy(src, as: name)
        let size = try XCTUnwrap(try u.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let h = try FileHandle(forUpdating: u)
        try h.truncate(atOffset: UInt64(Double(size) * fraction))
        try h.close()
        return u
    }

    /// Overwrites `count` bytes in the middle of the video data with a fixed pattern.
    static func flipped(_ src: URL, as name: String, at fraction: Double = 0.45, count: Int = 4000) throws -> URL {
        let u = try copy(src, as: name)
        let size = try XCTUnwrap(try u.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let h = try FileHandle(forUpdating: u)
        try h.seek(toOffset: UInt64(Double(size) * fraction))
        try h.write(contentsOf: Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        try h.close()
        return u
    }

    /// A 2-second jump in the timestamps from frame 48 on (B-frame H.264 in Matroska).
    static func brokenTimestamps() throws -> (good: URL, bad: URL) {
        let good = try self.good("mkv", bframes: true)
        let bad = work.appendingPathComponent("integrity-badts.mkv")
        if !FileManager.default.fileExists(atPath: bad.path) {
            try ff(["-i", good.path, "-map", "0", "-c", "copy",
                    "-bsf:v", "setts=pts=if(gte(N\\,48)\\,PTS+2/TB\\,PTS):dts=if(gte(N\\,48)\\,DTS+2/TB\\,DTS)", bad.path])
        }
        return (good, bad)
    }

    func kinds(_ h: SourceHealth) -> [SourceProblem.Kind] { h.problems.map(\.kind) }

    // MARK: Quick check

    func testQuickCheckIdentifiesEachProblemFast() async throws {
        try Self.requireTool("ffprobe")
        let good = try Self.good()
        let fast = try Self.good(faststart: true)
        let mkv = try Self.good("mkv")
        let cases: [(String, URL, SourceProblem.Kind?)] = [
            ("intact MP4", good, nil),
            ("intact MKV", mkv, nil),
            ("missing index (truncated, index at the end)", try Self.truncated(good, as: "noindex.mp4", keep: 0.7), .indexMissing),
            ("truncated faststart MP4", try Self.truncated(fast, as: "cut.mp4", keep: 0.6), .truncated),
            ("truncated MKV", try Self.truncated(mkv, as: "cut.mkv", keep: 0.6), .truncated),
            ("flipped bytes", try Self.flipped(good, as: "flipped.mp4"), .damaged),
            ("broken timestamps", try Self.brokenTimestamps().bad, .brokenTimestamps),
            ("wrong extension", try Self.copy(mkv, as: "really-mkv.mp4"), .mislabeled),
        ]
        for (label, url, want) in cases {
            let t0 = Date()
            let h = await SourceIntegrity.quickCheck(url)
            let took = Date().timeIntervalSince(t0)
            XCTAssertLessThan(took, 2, "\(label): quick check took \(took) s")
            if let want {
                XCTAssertTrue(kinds(h).contains(want), "\(label): expected \(want), got \(kinds(h)) — \(h.summary(url.lastPathComponent))")
            } else {
                XCTAssertTrue(h.ok, "\(label): expected OK, got \(kinds(h))")
            }
            print("[integrity] \(label): \(h.summary(url.lastPathComponent)) (\(String(format: "%.2f", took)) s)")
        }
        let empty = Self.work.appendingPathComponent("empty.mp4")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let e = await SourceIntegrity.quickCheck(empty)
        XCTAssertEqual(kinds(e), [.empty])

        // Times are right: the faststart file stops near 60% of 4 s, the jump is at 2 s.
        let cut = await SourceIntegrity.quickCheck(Self.work.appendingPathComponent("cut.mp4"))
        let t = try XCTUnwrap(cut.problems.first { $0.kind == .truncated })
        XCTAssertLessThan(try XCTUnwrap(t.seconds), 3.5)
        XCTAssertEqual(try XCTUnwrap(t.claimedSeconds), 4, accuracy: 0.1)
        XCTAssertTrue(t.summary("cut.mp4").hasPrefix("Cut short: stops at 0:0"), t.summary("cut.mp4"))
        let ts = await SourceIntegrity.quickCheck(try Self.brokenTimestamps().bad)
        XCTAssertEqual(try XCTUnwrap(ts.problems.first { $0.kind == .brokenTimestamps }?.seconds), 2, accuracy: 0.1)
        let mis = await SourceIntegrity.quickCheck(Self.work.appendingPathComponent("really-mkv.mp4"))
        XCTAssertTrue(mis.problems.first?.summary("really-mkv.mp4").contains("Lumora reads it anyway") ?? false)
    }

    // MARK: Full scan and decoding past damage

    func testFullScanMapsDamageToTimesAndAnalysisKeepsEveryFrame() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("ffmpeg")
        let bad = try Self.flipped(try Self.good(), as: "scan-flipped.mp4")
        let h = SourceIntegrity.fullScan(bad)
        let map = try XCTUnwrap(h.damage)
        XCTAssertGreaterThan(map.damagedFrames, 0, "damage found: \(map.decoderMessages.prefix(3))")
        let first = try XCTUnwrap(map.places.first)
        XCTAssertGreaterThan(map.seconds(first.start), 0.5)
        XCTAssertLessThan(map.seconds(first.start), 3.5)
        print("[integrity] full scan: \(map.summary)")
        // Analysis reads past the damage (AVFoundation stops at the first bad frame; the rest comes from FFmpeg,
        // with pictures it can't decode held so the timeline stays exact).
        let p = try await Self.prepare(bad)
        XCTAssertEqual(p.analysis.frameCount, 96, "every frame of the timeline is there")
    }

    func testExportOfDamagedSourceKeepsTheTimeline() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let bad = try Self.flipped(try Self.good(), as: "export-flipped.mp4")
        let p = try await Self.prepare(bad)
        CheckpointPlanner.segmentFramesOverride = 48
        let e = ExportEngine()
        let url = try await e.run(job(p, codec: .av1, name: "from-damaged.mkv")) { _, _ in }
        XCTAssertEqual(try Self.frames(url).hashes.count, 96, "no frame is skipped")
        XCTAssertTrue(Self.log(e).contains("decode"), "the damage is in the export log")
    }

    func testRenderOfTruncatedSourceFailsWithAClearExplanation() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("SvtAv1EncApp")
        let good = try Self.good(faststart: true)
        let p = try await Self.prepare(good)
        // The file is cut after it was opened and analyzed (an interrupted copy finishing while Lumora reads it).
        let cut = try Self.truncated(good, as: "late-cut.mp4", keep: 0.55)
        var d = p.d
        d.url = cut
        var q = p
        q.d = d
        let e = ExportEngine()
        _ = await failure(e, job(q, codec: .av1, name: "from-cut.mkv"))
        let r = try XCTUnwrap(e.lastFailure)
        XCTAssertTrue([.sourceTruncated, .sourceChanged, .sourceDamaged].contains(r.failure.kind), "\(r.failure.kind): \(r.simple)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.session!.job.outputURL.path), "no short video is delivered")
    }

    // MARK: Repairs (always into a new file)

    func assertSourceUntouched(_ url: URL, _ sha: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try SegmentValidator.sha256(url), sha, "the source is never modified", file: file, line: line)
    }

    func testRepairTruncatedFileByRemux() async throws {
        try Self.requireTool("ffmpeg")
        let src = try Self.truncated(try Self.good(faststart: true), as: "repair-cut.mp4", keep: 0.6)
        let sha = try SegmentValidator.sha256(src)
        let h = await SourceIntegrity.quickCheck(src)
        XCTAssertTrue(h.repairable)
        let r = try SourceRepair.repair(src, health: h)
        try assertSourceUntouched(src, sha)
        XCTAssertEqual(r.output.lastPathComponent, "repair-cut (repaired).mkv")
        XCTAssertEqual(r.output.deletingLastPathComponent().standardizedFileURL, src.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(r.methods, [.remux])
        XCTAssertGreaterThan(r.framesAfter, 24, "every frame that is there is kept")
        XCTAssertEqual(r.decodeErrorsAfter, 0, "the repaired copy decodes cleanly")
        print("[repair] truncated faststart MP4: \(r.framesAfter) frames kept, \(r.decodeErrorsAfter) decode errors — \(r.summary)")
        let mkv = try Self.truncated(try Self.good("mkv"), as: "repair-cut.mkv", keep: 0.6)
        let rm = try SourceRepair.repair(mkv, health: await SourceIntegrity.quickCheck(mkv))
        XCTAssertEqual(rm.decodeErrorsAfter, 0)
        print("[repair] truncated MKV: \(rm.framesAfter) frames kept, \(rm.decodeErrorsAfter) decode errors")
    }

    func testRepairBrokenTimestampsGivesIdenticalFrames() async throws {
        try Self.requireTool("ffmpeg"); try Self.requireTool("MP4Box")
        let (good, bad) = try Self.brokenTimestamps()
        let sha = try SegmentValidator.sha256(bad)
        let h = await SourceIntegrity.quickCheck(bad)
        let r = try SourceRepair.repair(bad, health: h, to: out.appendingPathComponent("ts (repaired).mkv"))
        try assertSourceUntouched(bad, sha)
        XCTAssertEqual(r.methods, [.timestamps])
        XCTAssertEqual(r.framesAfter, 96)
        let pts = try Self.ptsSeconds(r.output)
        XCTAssertEqual(pts.last.map { $0 - pts[0] } ?? 0, 95.0 / 24, accuracy: 0.002, "4 s again")
        XCTAssertEqual(try Self.frames(r.output).hashes, try Self.frames(good).hashes, "frames bit-identical to the good file")
        XCTAssertGreaterThan(try Self.audioDuration(r.output), 3.9, "audio kept")
        print("[repair] broken timestamps: \(r.framesAfter) frames, identical to the undamaged file")
    }

    func testRepairDamagedGOPsReencodesOnlyThose() async throws {
        try Self.requireTool("ffmpeg")
        let good = try Self.good()
        let bad = try Self.flipped(good, as: "repair-flipped.mp4")
        let sha = try SegmentValidator.sha256(bad)
        let h = SourceIntegrity.fullScan(bad)
        XCTAssertTrue(h.repairable)
        let r = try SourceRepair.repair(bad, health: h, to: out.appendingPathComponent("flipped (repaired).mkv"))
        try assertSourceUntouched(bad, sha)
        XCTAssertEqual(r.methods, [.reencodeDamaged])
        XCTAssertEqual(r.framesAfter, 96, "frame count exact")
        XCTAssertEqual(r.decodeErrorsAfter, 0, "clean decode")
        XCTAssertFalse(r.reencoded.isEmpty)
        let a = try Self.frames(good).hashes, b = try Self.frames(r.output).hashes
        XCTAssertEqual(b.count, 96)
        let rebuilt = Set(r.reencoded.flatMap { Array($0) })
        var untouchedSame = 0, untouchedDiff: [Int] = []
        for i in 0..<min(a.count, b.count) where !rebuilt.contains(i) {
            if a[i] == b[i] { untouchedSame += 1 } else { untouchedDiff.append(i) }
        }
        XCTAssertTrue(untouchedDiff.isEmpty, "frames outside the re-encoded parts are bit-identical; differ: \(untouchedDiff.prefix(10))")
        let pts = try Self.ptsSeconds(r.output)
        for (n, t) in pts.enumerated() { XCTAssertEqual(t - pts[0], Double(n) / 24, accuracy: 0.002) }
        XCTAssertGreaterThan(try Self.audioDuration(r.output), 3.5, "audio present")
        print("[repair] flipped bytes: \(rebuilt.count) frames re-encoded, \(untouchedSame) untouched and identical; \(r.summary)")
    }

    func testMissingIndexIsRefusedHonestly() async throws {
        let src = try Self.truncated(try Self.good(), as: "repair-noindex.mp4", keep: 0.7)
        let h = await SourceIntegrity.quickCheck(src)
        XCTAssertEqual(kinds(h), [.indexMissing])
        let dest = out.appendingPathComponent("noindex (repaired).mkv")
        XCTAssertThrowsError(try SourceRepair.repair(src, health: h, to: dest)) { e in
            let msg = e.localizedDescription
            XCTAssertTrue(msg.contains("can't be rebuilt from this file alone"), msg)
            XCTAssertTrue(msg.contains("camera card"), msg)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "no file is written")
    }
}
