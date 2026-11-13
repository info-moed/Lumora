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

    // MARK: No leaks

    func testChecksAndDecoderMessagesDoNotLeakFileDescriptors() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("ffmpeg")
        let mkv = try Self.good("mkv")
        func fds() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        _ = await SourceIntegrity.quickCheck(mkv)
        let before = fds()
        for _ in 0..<5 { _ = await SourceIntegrity.quickCheck(mkv) }
        let afterChecks = fds()
        let (d, _) = try await SourceInspector.inspect(mkv)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterInspect = fds()
        for _ in 0..<5 {
            var dd = d; dd.kind = .ffmpeg
            let src = try FFmpegFrameSource(descriptor: dd)
            try src.start(at: 0, count: 3)
            while try src.nextFrame() != nil {}
            try src.start(at: 10, count: 2)
            _ = try src.nextFrame()
            src.cancel()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterSources = fds()
        print("[integrity] fds: \(before) → \(afterChecks) after 5 quick checks → \(afterInspect) after inspect → \(afterSources) after 5 FFmpeg sources")
        XCTAssertLessThanOrEqual(afterChecks - before, 2, "quick checks leak file descriptors")
        XCTAssertLessThanOrEqual(afterSources - afterInspect, 2, "FFmpeg sources leak file descriptors")
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

    /// Frames the full check found missing are re-created from their good neighbors while exporting (the default) or,
    /// when the user picks it, the previous good frame is repeated; every other frame passes through untouched.
    /// Checked on a synthetic source (frame k is a flat gray of level k/40), because decoding a damaged file isn't
    /// repeatable around the damage (the decoder's concealment varies with threading).
    @MainActor func testDamagedFramesAreRecreatedFromNeighborsOrRepeated() async throws {
        try TestHardware.requireGPU(); try Self.requireTool("ffmpeg")
        let bad = try Self.flipped(try Self.good(), as: "recreate-flipped.mp4")
        var p = try await Self.prepare(bad)
        let map = try XCTUnwrap(SourceIntegrity.fullScan(bad).damage)
        print("[integrity] damage spans: \(map.spans.map { "\($0.kind.rawValue) \($0.start)+\($0.count)" })")
        // The real file: a short run of missing frames, rebuilt without losing a frame from the timeline.
        p.analysis.damage = map
        let j = job(p, codec: .av1, name: "unused.mkv")
        let real = RecoveryHooks.rebuildingDamagedFrames(ConcealingFrameSource.wrap(try await p.d.makeFrameSource(), descriptor: p.d), j)
        XCTAssertTrue(real is PatchedFrameSource, "a short run is re-created by default")
        try real.start(at: 0, count: nil)
        var n = 0
        while try real.nextFrame() != nil { n += 1 }
        XCTAssertEqual(n, p.analysis.frameCount, "every frame of the timeline")

        // Synthetic: frames 10–11 missing (re-created), 20–24 missing (too long: always the previous frame).
        let ctx = MetalContext.shared
        func flat(_ v: Float) -> MTLTexture {
            let t = ctx.makeTexture(width: 32, height: 32, format: .rgba16Float, storage: .shared)
            let px = [Float16](repeating: Float16(v), count: 32 * 32 * 4)
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32 * 8) }
            return t
        }
        var synth = j
        synth.analysis.damage = DamageMap(spans: [.init(start: 10, count: 2, kind: .missing), .init(start: 20, count: 5, kind: .missing)], fps: 24)
        synth.analysis.frameCount = 40
        func read(_ method: String?) throws -> [Float] {
            setDefault("damagedFrameMethod", method)
            // What the decoder hands over for a missing frame: a wrong picture (here, white).
            let base = SequenceFrameSource(width: 32, height: 32, loaders: (0..<40).map { k in
                { flat(synth.analysis.damage!.missingFrames.contains(k) ? 1 : Float(k) / 40) } })
            let s = RecoveryHooks.rebuildingDamagedFrames(base, synth)
            try s.start(at: 0, count: nil)
            var out: [Float] = []
            while let f = try s.nextFrame() { out.append(CampaignIngestTests.pixels(f.texture)[0].x) }
            return out
        }
        let repeated = try read("repeat")
        XCTAssertEqual(repeated.count, 40)
        for k in [10, 11] { XCTAssertEqual(repeated[k], 9 / 40, accuracy: 0.002, "repeat: frame \(k) shows frame 9") }
        for k in 20...24 { XCTAssertEqual(repeated[k], 19 / 40, accuracy: 0.002, "frame \(k) shows frame 19") }
        let rebuilt = try read(nil)
        XCTAssertEqual(rebuilt.count, 40)
        for k in [10, 11] {
            XCTAssertGreaterThan(rebuilt[k], 9.4 / 40, "re-created frame \(k) lies between its neighbors (\(rebuilt[k] * 40) of 9–12)")
            XCTAssertLessThan(rebuilt[k], 11.6 / 40, "re-created frame \(k) lies between its neighbors (\(rebuilt[k] * 40) of 9–12)")
        }
        XCTAssertLessThan(rebuilt[10], rebuilt[11], "re-created frames keep the motion order")
        for k in 20...24 { XCTAssertEqual(rebuilt[k], 19 / 40, accuracy: 0.002, "a long run keeps the previous frame (\(k))") }
        for k in (0..<40) where !(10...11).contains(k) && !(20...24).contains(k) {
            XCTAssertEqual(rebuilt[k], Float(k) / 40, accuracy: 0.002, "frame \(k) untouched")
            XCTAssertEqual(repeated[k], Float(k) / 40, accuracy: 0.002, "frame \(k) untouched")
        }
        print(String(format: "[integrity] re-created frames 10–11 at levels %.2f, %.2f (neighbors 9 and 12); repeat holds 9; frames 20–24 hold 19", rebuilt[10] * 40, rebuilt[11] * 40))
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
        try assertRepairedCopyIsRight(r, good: good, label: "flipped H.264")
        print("[repair] flipped bytes: \(rebuilt.count) frames re-encoded, \(untouchedSame) untouched and identical; \(r.summary)")
    }

    // MARK: Damaged GOPs in the sources people actually have (verifier cases)

    /// The good clip re-encoded with other encoders: 8-bit x265 (B-frames, closed GOPs) and, when this Mac has it,
    /// Apple's 10-bit hardware HEVC encoder. Same 24-frame GOPs, same audio.
    static func reencoded(_ good: URL, as name: String, _ video: [String]) throws -> URL {
        let u = work.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: u.path) {
            try ff(["-i", good.path, "-map", "0", "-c:a", "copy"] + video + [u.path])
        }
        return u
    }

    static var hasVideoToolboxHEVC: Bool {
        ((try? run(try ffmpeg, ["-hide_banner", "-encoders"])) ?? "").contains("hevc_videotoolbox")
    }

    /// Overwrites `count` bytes at the start of video packet `index` (decode order), just after its NAL header: the
    /// slice header is garbage, so the decoder reports it (damage in the middle of a slice often decodes silently).
    /// `within` places the damage further into the packet instead (x264 starts its first packet with a text SEI).
    static func damagedPacket(_ src: URL, as name: String, packet index: Int, count: Int = 400, within: Double? = nil) throws -> URL {
        let text = try run(try ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pos,size", "-of", "compact", src.path])
        let rows = text.split(separator: "\n").map { row in
            Dictionary(uniqueKeysWithValues: row.split(separator: "|").dropFirst().compactMap { kv -> (String, Int)? in
                let p = kv.split(separator: "=", maxSplits: 1)
                return p.count == 2 ? (String(p[0]), Int(p[1]) ?? 0) : nil
            })
        }
        let pos = try XCTUnwrap(rows[index]["pos"]), size = try XCTUnwrap(rows[index]["size"])
        let u = try copy(src, as: name)
        let h = try FileHandle(forUpdating: u)
        let skip = within.map { Int(Double(size) * $0) } ?? 6
        try h.seek(toOffset: UInt64(pos + skip))
        try h.write(contentsOf: Data((0..<min(count, size - skip)).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }))
        try h.close()
        return u
    }

    /// Per-frame luma PSNR of `a` against `b` (99 for identical frames).
    static func psnr(_ a: URL, _ b: URL) throws -> [Double] {
        let stats = work.appendingPathComponent("psnr-\(UUID().uuidString.prefix(6)).txt")
        defer { try? FileManager.default.removeItem(at: stats) }
        // Frame by frame, by position (the files' own timestamps can start at different offsets).
        try ff(["-i", a.path, "-i", b.path, "-lavfi", "[0:v]settb=1/24,setpts=N[x];[1:v]settb=1/24,setpts=N[y];[x][y]psnr=stats_file=\(stats.path)", "-f", "null", "-"])
        return try String(contentsOf: stats, encoding: .utf8).split(separator: "\n").map { line in
            let y = line.split(separator: " ").first { $0.hasPrefix("psnr_y:") }.map { String($0.dropFirst(7)) } ?? "0"
            return y == "inf" ? 99 : (Double(y) ?? 0)
        }
    }

    /// Luma PSNR of frames `range` of `a` against one frame of `b`.
    static func psnr(_ a: URL, frames range: Range<Int>, against b: URL, frame: Int) throws -> [Double] {
        let stats = work.appendingPathComponent("psnr-\(UUID().uuidString.prefix(6)).txt")
        defer { try? FileManager.default.removeItem(at: stats) }
        let g = "[0:v]trim=start_frame=\(range.lowerBound):end_frame=\(range.upperBound),settb=1/24,setpts=N[x];"
            + "[1:v]trim=start_frame=\(frame):end_frame=\(frame + 1),loop=loop=\(range.count - 1):size=1,settb=1/24,setpts=N[y];"
            + "[x][y]psnr=stats_file=\(stats.path)"
        try ff(["-i", a.path, "-i", b.path, "-lavfi", g, "-f", "null", "-"])
        return try String(contentsOf: stats, encoding: .utf8).split(separator: "\n").map { line in
            let y = line.split(separator: " ").first { $0.hasPrefix("psnr_y:") }.map { String($0.dropFirst(7)) } ?? "0"
            return y == "inf" ? 99 : (Double(y) ?? 0)
        }
    }

    /// A repaired copy is right only if: the exact frame count and timestamps, a clean decode, every frame outside the
    /// re-encoded parts bit-identical to the undamaged file, every re-encoded frame that isn't listed as rebuilt close
    /// to the undamaged one (no concealed garbage passed off as repaired), every listed rebuilt frame a repeat of
    /// the last good one, and the audio kept.
    func assertRepairedCopyIsRight(_ r: SourceRepair.Report, good: URL, frames total: Int = 96, label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.framesAfter, total, "\(label): frame count", file: file, line: line)
        XCTAssertEqual(r.decodeErrorsAfter, 0, "\(label): clean decode", file: file, line: line)
        XCTAssertFalse(r.reencoded.isEmpty, "\(label): a part was re-encoded", file: file, line: line)
        let a = try Self.frames(good).hashes, b = try Self.frames(r.output).hashes
        XCTAssertEqual(b.count, total, file: file, line: line)
        let reencoded = Set(r.reencoded.flatMap { Array($0) })
        let rebuilt = Set(r.rebuiltFrames.flatMap { Array($0) } + r.heldFromNext.flatMap { Array($0) })
        let changed = (0..<min(a.count, b.count)).filter { !reencoded.contains($0) && a[$0] != b[$0] }
        XCTAssertTrue(changed.isEmpty, "\(label): untouched frames bit-identical; differ: \(changed.prefix(10))", file: file, line: line)
        let pts = try Self.ptsSeconds(r.output)
        let late = pts.enumerated().filter { abs($0.element - pts[0] - Double($0.offset) / 24) > 0.002 }.map(\.offset)
        XCTAssertTrue(late.isEmpty, "\(label): every frame on time; off: \(late.prefix(10))", file: file, line: line)
        let q = try Self.psnr(r.output, good)
        let bad = reencoded.subtracting(rebuilt).sorted().filter { $0 < q.count && q[$0] < 35 }
        XCTAssertTrue(bad.isEmpty, "\(label): re-encoded frames not listed as rebuilt look like the original; below 35 dB: \(bad.prefix(10).map { "\($0): \(Int(q[$0])) dB" })", file: file, line: line)
        // Rebuilt frames are re-encoded copies of the good frame they repeat (close to it, not bit-identical).
        for range in r.rebuiltFrames where range.lowerBound > 0 {
            let held = try Self.psnr(r.output, frames: range, against: good, frame: range.lowerBound - 1)
            XCTAssertGreaterThanOrEqual(held.count, range.count, file: file, line: line)
            XCTAssertTrue(held.prefix(range.count).allSatisfy { $0 >= 38 }, "\(label): frames \(range) repeat frame \(range.lowerBound - 1): \(held.map { Int($0) })", file: file, line: line)
        }
        for range in r.heldFromNext {
            let held = try Self.psnr(r.output, frames: range, against: good, frame: range.upperBound)
            XCTAssertTrue(held.prefix(range.count).allSatisfy { $0 >= 38 }, "\(label): frames \(range) repeat frame \(range.upperBound): \(held.map { Int($0) })", file: file, line: line)
        }
        XCTAssertGreaterThan(try Self.audioDuration(r.output), 3.5, "\(label): audio kept", file: file, line: line)
    }

    func testRepairDamagedHEVCKeepsTheFramesAfterItIntact() async throws {
        try Self.requireTool("ffmpeg")
        let good = try Self.good()
        let x265 = try Self.reencoded(good, as: "hevc8.mp4", ["-c:v", "libx265", "-pix_fmt", "yuv420p", "-tag:v", "hvc1",
                                                              "-x265-params", "keyint=24:min-keyint=24:scenecut=0:open-gop=0:log-level=error"])
        var cases: [(String, URL, URL)] = [("8-bit x265", x265, try Self.flipped(x265, as: "flipped-hevc8.mp4"))]
        if Self.hasVideoToolboxHEVC {
            let vt = try Self.reencoded(good, as: "vt10.mp4", ["-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                                                               "-pix_fmt", "p010le", "-g", "24", "-tag:v", "hvc1", "-q:v", "70"])
            // The 45% overwrite lands in the middle of a slice of this file and decodes "fine" (nothing to find); a
            // damaged slice header at frame 30 is what a full check reports.
            cases.append(("10-bit VideoToolbox", vt, try Self.damagedPacket(vt, as: "damaged-vt10.mp4", packet: 30)))
        }
        for (label, clean, bad) in cases {
            let sha = try SegmentValidator.sha256(bad)
            let h = SourceIntegrity.fullScan(bad)
            XCTAssertTrue(h.repairable, "\(label): \(h.problems.map(\.kind)) \(h.summary(bad.lastPathComponent))")
            let r = try SourceRepair.repair(bad, health: h, to: out.appendingPathComponent("\(label) (repaired).mkv"))
            try assertSourceUntouched(bad, sha)
            try assertRepairedCopyIsRight(r, good: clean, label: label)
            print("[repair] \(label): \(r.summary)")
        }
    }

    func testRepairDamagedBFrameH264KeepsTimestamps() async throws {
        try Self.requireTool("ffmpeg")
        let good = try Self.good("mkv", bframes: true)
        let bad = try Self.flipped(good, as: "repair-flipped-b.mkv")
        let r = try SourceRepair.repair(bad, health: SourceIntegrity.fullScan(bad), to: out.appendingPathComponent("b (repaired).mkv"))
        try assertRepairedCopyIsRight(r, good: good, label: "B-frame H.264")
        let last = try XCTUnwrap(try Self.ptsSeconds(r.output).last)
        XCTAssertEqual(last - (try Self.ptsSeconds(r.output).first ?? 0), 95.0 / 24, accuracy: 0.002, "no longer than the original")
        print("[repair] B-frame H.264: \(r.summary)")
    }

    func testRepairOfADamagedFirstKeyframeRepeatsTheNextGoodFrame() async throws {
        try Self.requireTool("ffmpeg")
        let good = try Self.good()
        let bad = try Self.damagedPacket(good, as: "damaged-start.mp4", packet: 0, within: 0.3)
        let h = SourceIntegrity.fullScan(bad)
        XCTAssertTrue(h.repairable, "\(h.problems.map(\.kind))")
        let r = try SourceRepair.repair(bad, health: h, to: out.appendingPathComponent("start (repaired).mkv"))
        XCTAssertEqual(r.heldFromNext, [0..<24], "nothing before the damage: the next good frame is repeated")
        XCTAssertTrue(r.summary.contains("repeat the next good frame"), r.summary)
        try assertRepairedCopyIsRight(r, good: good, label: "first keyframe")
        print("[repair] first keyframe: \(r.summary)")
    }

    func testRepairNamesWhereALostFrameWas() async throws {
        try Self.requireTool("ffmpeg")
        let good = try Self.good("mkv")
        let dropped = Self.work.appendingPathComponent("repair-dropped.mkv")
        if !FileManager.default.fileExists(atPath: dropped.path) {
            try Self.ff(["-i", good.path, "-map", "0", "-c", "copy", "-bsf:v", "noise=drop=eq(n\\,30)", dropped.path])
        }
        let h = SourceIntegrity.fullScan(dropped)
        XCTAssertTrue(h.repairable, "\(h.problems.map(\.kind))")
        let r = try SourceRepair.repair(dropped, health: h, to: out.appendingPathComponent("dropped (repaired).mkv"))
        XCTAssertEqual(r.framesAfter, 96)
        // Frame 30 (0:01.2) is the lost one; the frames after it in its GOP referred to it, so they are rebuilt too.
        XCTAssertEqual(r.rebuiltFrames.first?.lowerBound, 30, "\(r.rebuiltFrames)")
        XCTAssertEqual(r.rebuiltFrames.first?.upperBound, 48, "\(r.rebuiltFrames)")
        XCTAssertTrue(r.summary.contains("0:01.2"), r.summary)
        try assertRepairedCopyIsRight(r, good: good, label: "lost frame")
        print("[repair] lost frame: \(r.summary)")
    }

    /// A joined copy that doesn't check out (here a part placed 0.25 s late) is never offered as repaired.
    func testRepairThatDoesNotCheckOutIsNotSaved() async throws {
        try Self.requireTool("ffmpeg")
        let bad = try Self.flipped(try Self.good(), as: "repair-shifted.mp4")
        FaultInjection.repairPartShift = 0.25
        let dest = out.appendingPathComponent("shifted (repaired).mkv")
        XCTAssertThrowsError(try SourceRepair.repair(bad, health: SourceIntegrity.fullScan(bad), to: dest)) { e in
            let m = e.localizedDescription
            XCTAssertTrue(m.contains("didn't come out right") && m.contains("instead of"), m)
            XCTAssertTrue(m.contains("Your original is unchanged"), m)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "no repaired copy is left behind")
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
