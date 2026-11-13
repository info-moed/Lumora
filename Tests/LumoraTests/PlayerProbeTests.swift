import XCTest
@testable import Lumora

/// What the probe reads from real files: codec, geometry, signal tags, HDR metadata, AV2's own stream data.
final class PlayerProbeTests: XCTestCase {
    func testHDR10HEVCInMP4AndMatroska() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        for container in ["mp4", "mkv"] {
            let i = try MediaProbe.probe(try PlayerFixtures.hdr10Clip(container))
            let v = i.video
            XCTAssertEqual(v.codec, .hevc, container)
            XCTAssertEqual(v.bitDepth, 10)
            XCTAssertEqual(v.chroma, .c420)
            XCTAssertEqual([v.color.primaries, v.color.transfer, v.color.matrix], [9, 16, 9], container)
            XCTAssertTrue(v.color.transferTagged)
            XCTAssertFalse(v.color.fullRange)
            XCTAssertEqual(v.hdr?.mdcvMaxNits ?? 0, 1000, accuracy: 0.5, container)
            XCTAssertEqual(v.hdr?.mdcvMinNits ?? 0, 0.005, accuracy: 0.0005, container)
            XCTAssertEqual(v.hdr?.maxCLL, 800, container)
            XCTAssertEqual(v.hdr?.maxFALL, 300, container)
            XCTAssertEqual(i.fps, 24, accuracy: 0.001)
            XCTAssertEqual(i.avfDecodable, container == "mp4")
            XCTAssertEqual(PlayerRenderer.sourcePeak(i, assumed: 1000).0, 800, "MaxCLL wins")
        }
    }

    func testCodecsAndContainers() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let cases: [(String, PlayerCodec, Int)] = [("h264.mp4", .h264, 8), ("vp9.webm", .vp9, 10), ("av1.mkv", .av1, 10),
                                                    ("hevc12.mp4", .hevc, 12), ("y4m", .rawvideo, 10)]
        for (kind, codec, bits) in cases {
            let i = try MediaProbe.probe(try PlayerFixtures.indexClip(kind))
            XCTAssertEqual(i.video.codec, codec, kind)
            XCTAssertEqual(i.video.bitDepth, bits, kind)
            XCTAssertEqual(i.video.width, 320, kind)
            XCTAssertEqual(i.video.height, 180, kind)
            XCTAssertEqual(i.estimatedFrameCount, 24, kind)
            XCTAssertEqual(i.fps, 24, accuracy: 0.01, kind)
            // Untagged: guessed as SD BT.601 (180 lines), limited range, left-sited chroma.
            XCTAssertEqual(i.video.color.matrix, 6, kind)
            XCTAssertEqual(i.video.color.chromaLocation, .left, kind)
        }
    }

    func testRawVVCStream() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe", "vvencapp")
        let i = try MediaProbe.probe(try PlayerFixtures.indexClip("vvc.266"))
        XCTAssertEqual(i.video.codec, .vvc)
        XCTAssertTrue(i.isRawElementaryStream)
        XCTAssertEqual(i.video.bitDepth, 10)
        XCTAssertEqual(i.video.width, 320)
        let table = try FrameTable.read(i.url, timeout: 30)
        XCTAssertEqual(table.count, 24, "every frame is a packet even without timestamps")
    }

    func testThirdPartyVVCHLGPlaysAsHLG() throws {
        // VVenC's --hdr hlg_2020 tags transfer 14 (BT.2020) plus the alternative-transfer SEI, which FFmpeg's VVC
        // decoder ignores: the probe reads the SEI itself, from the raw stream and from an MP4 copy.
        try PlayerFixtures.require("ffmpeg", "ffprobe", "vvencapp")
        let y4m = try PlayerFixtures.indexY4M("index.y4m", spec: .init())
        let hlg = try PlayerFixtures.cached("vvc-hlg.266") {
            try PlayerFixtures.run("vvencapp", ["-i", y4m.path, "--preset", "faster", "-q", "34", "--hdr", "hlg_2020", "-o", $0.path])
        }
        var files = [hlg]
        if PlayerFixtures.tool("MP4Box") != nil {
            files.append(try PlayerFixtures.cached("vvc-hlg.mp4") { try PlayerFixtures.run("MP4Box", ["-add", "\(hlg.path):fps=24", "-new", $0.path]) })
        }
        var macOS = PlayerSettings(); macOS.toneMapping = .macOS
        for url in files {
            let i = try MediaProbe.probe(url)
            let name = url.lastPathComponent
            XCTAssertEqual(i.video.color.primaries, 9, name)
            XCTAssertTrue([14, 18].contains(i.video.color.transfer), "\(name): transfer \(i.video.color.transfer)")
            if i.video.color.transfer == 14 {
                XCTAssertEqual(i.video.alternativeTransfer, 18, name)
                XCTAssertTrue(i.notes.contains { $0.contains("playing as HLG") }, "\(name): \(i.notes)")
                XCTAssertFalse(i.notes.contains { $0.contains("Interpret as HLG") }, name)
            }
            let out = PlayerRenderer.output(frameColor: i.video.color, storage: .planarBuffer, info: i, settings: macOS, interpret: .auto)
            XCTAssertEqual(out, .hlg, name)
        }
        // A plain BT.2020 SDR VVC stream has no such SEI.
        let sdr = try PlayerFixtures.indexClip("vvc.266")
        XCTAssertNil(VVCSEI.alternativeTransfer(firstAccessUnitOf: sdr))
    }

    func testAV2StreamColorRandomAccessPointsAndManifestRate() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        let y4m = try PlayerFixtures.indexY4M("index.y4m", spec: .init())
        let pq = try PlayerFixtures.cached("av2-pq.obu") {
            try PlayerFixtures.run("avmenc", ["--obu", "--passes=1", "--cpu-used=9", "--end-usage=q", "--qp=150", "--kf-max-dist=4", "--kf-min-dist=4",
                                              "--limit=12", "--fps=24/1", "--color-primaries=bt2020", "--transfer-characteristics=smpte2084",
                                              "--matrix-coefficients=bt2020ncl", "-o", $0.path, y4m.path])
        }
        let s = try AV2Stream.summary(of: pq)
        XCTAssertEqual(s.units.count, 12)
        XCTAssertEqual(s.randomAccessFrames, [0, 4, 8])
        var i = try MediaProbe.probe(pq)
        XCTAssertEqual(i.video.codec, .av2)
        XCTAssertEqual(i.video.width, 320); XCTAssertEqual(i.video.height, 180)
        XCTAssertEqual(i.video.bitDepth, 10)
        XCTAssertEqual(i.frameCount, 12)
        XCTAssertEqual(i.av2?.randomAccessPoints, [0, 4, 8])
        XCTAssertEqual(i.av2?.sampleBytes, 2)
        XCTAssertEqual([i.video.color.primaries, i.video.color.transfer, i.video.color.matrix], [9, 16, 9])
        XCTAssertFalse(i.frameRateKnown, "a raw AV2 stream carries no rate")
        XCTAssertTrue(i.notes.contains { $0.contains("no frame rate") })

        // Lumora's own export record supplies the rate and the peak.
        let m = ExportManifest(output: pq.path, source: "/tmp/src.mov", codec: .av2, rateNum: 30, rateDen: 1, frames: 12, delivery: .hdr10,
                               chunks: [], created: Date(), peakNits: 600)
        m.save()
        defer { ExportManifest.remove(for: pq) }
        i = try MediaProbe.probe(pq)
        XCTAssertEqual(i.fps, 30)
        XCTAssertTrue(i.frameRateKnown)
        XCTAssertEqual(i.manifestPeakNits, 600)
        XCTAssertEqual(PlayerRenderer.sourcePeak(i, assumed: 1000).0, 600)
    }

    func testAV2InIVFReadsItsTimebase() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        let ivf = try PlayerFixtures.indexClip("av2.ivf")
        let i = try MediaProbe.probe(ivf)
        XCTAssertEqual(i.video.codec, .av2)
        XCTAssertEqual(i.container, "IVF")
        XCTAssertEqual(i.fps, 24, accuracy: 0.001)
        XCTAssertTrue(i.frameRateKnown)
        XCTAssertEqual(i.frameCount, 24)
        XCTAssertEqual(i.av2?.randomAccessPoints, [0, 8, 16])
    }

    func testDolbyVision81PlaysItsBaseLayer() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe", "dovi_tool", "MP4Box")
        let dv = try PlayerFixtures.cached("dv81.mp4") { out in
            let work = PlayerFixtures.url("dv-work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try PlayerFixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=1", "-vf", "scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le",
                                       "-c:v", "libx265", "-x265-params", CampaignHDRMetadataTests.x265PQ, "-f", "hevc", work.appendingPathComponent("bl.hevc").path])
            let rpu = """
            {"cm_version":"V40","profile":"8.1","length":24,
             "level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":50,"max_content_light_level":1000,"max_frame_average_light_level":300},
             "shots":[{"start":0,"duration":24,"metadata_blocks":[{"Level1":{"min_pq":0,"max_pq":3001,"avg_pq":1501}}]}]}
            """
            try rpu.write(to: work.appendingPathComponent("rpu.json"), atomically: true, encoding: .utf8)
            try PlayerFixtures.run("dovi_tool", ["generate", "-j", "rpu.json", "-o", "rpu.bin"], cwd: work)
            try PlayerFixtures.run("dovi_tool", ["inject-rpu", "-i", "bl.hevc", "--rpu-in", "rpu.bin", "-o", "dv.hevc"], cwd: work)
            try PlayerFixtures.run("MP4Box", ["-add", "dv.hevc:dvp=8.1:fps=24", "-new", out.path], cwd: work)
        }
        let i = try MediaProbe.probe(dv)
        XCTAssertEqual(i.video.dolbyVision?.profile, 8)
        XCTAssertEqual(i.video.dolbyVision?.blCompatibilityID, 1)
        XCTAssertTrue(i.notes.contains("Dolby Vision 8.1: playing the HDR10 base layer"), "\(i.notes)")
        XCTAssertEqual(i.video.color.transfer, 16)
    }

    func testDolbyVisionRecordAndMasteringParsers() {
        // dvcC: version 1.0, profile 8, level 6, rpu + bl present, compatibility id 1.
        let rec = Data([1, 0, 8 << 1 | 0, 6 << 3 | 0b101, 1 << 4])
        XCTAssertEqual(MediaProbe.parseDOVIRecord(rec), DolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1, hasEnhancementLayer: false))
        let s = HDRMetadata.Static(peakNits: 1000, maxCLL: 800, maxFALL: 300)
        let m = HDRMetadata.parseMasteringDisplay(HDRMetadata.vtMasteringDisplay(s))
        XCTAssertEqual(m?.maxNits ?? 0, 1000, accuracy: 0.01)
        XCTAssertEqual(m?.primaries.count, 8)
        let c = HDRMetadata.parseContentLightLevel(HDRMetadata.vtContentLightLevel(s))
        XCTAssertEqual(c?.maxCLL, 800); XCTAssertEqual(c?.maxFALL, 300)
    }
}
