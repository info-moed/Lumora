import XCTest
@testable import Lumora

/// Hostile, broken and unsupported files fail cleanly: a PlayerError with a useful message within 5 s, no crash,
/// no decoder left running.
@MainActor
final class PlayerFailureTests: XCTestCase {
    func write(_ name: String, _ data: Data) throws -> URL {
        let u = PlayerFixtures.url("bad-" + name)
        try data.write(to: u)
        return u
    }

    /// Opens through the engine and returns its failure message.
    func failure(_ url: URL, caps: DecoderCapabilities? = nil, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let e = PlayerEngine()
        e.capabilities = caps
        let start = Date()
        e.open(url)
        XCTAssertTrue(e.waitUntilOpened(timeout: 5), "\(url.lastPathComponent): still opening after 5 s", file: file, line: line)
        // A file can open and then fail on its first frame: give the decoder a moment.
        let deadline = Date(timeIntervalSinceNow: 5 - Date().timeIntervalSince(start))
        while e.errorMessage == nil && Date() < deadline && e.currentFrame == nil {
            _ = e.frameForDisplay(targetHost: CACurrentMediaTime())
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let msg = e.errorMessage
        e.stop()
        return msg
    }

    func testMissingDecodersNameWhatToInstall() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        var noFFmpeg = DecoderCapabilities.current
        noFFmpeg.hasFFmpeg = false
        let mkv = try PlayerFixtures.indexClip("hevc.mkv")
        let m = try XCTUnwrap(failure(mkv, caps: noFFmpeg))
        XCTAssertTrue(m.contains("brew install ffmpeg"), m)
        if PlayerFixtures.tool("avmenc") != nil {
            var noAVM = DecoderCapabilities.current
            noAVM.hasAVMDec = false
            let a = try XCTUnwrap(failure(try PlayerFixtures.indexClip("av2.obu"), caps: noAVM))
            XCTAssertTrue(a.contains("avmdec") && a.contains("install-encoders.sh"), a)
        }
        // A tool that is gone by the time it's needed.
        XCTAssertThrowsError(try ChildProcess(tool: "lumora-no-such-decoder", args: [])) { e in
            guard case .missingTool = e as? PlayerError else { return XCTFail("\(e)") }
        }
    }

    func testEmptyFileDirectoryAndGarbage() throws {
        try PlayerFixtures.require("ffprobe")
        XCTAssertTrue(try XCTUnwrap(failure(try write("empty.mp4", Data()))).contains("empty"))
        let dir = PlayerFixtures.url("bad-folder.mkv")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNotNil(failure(dir))
        XCTAssertNotNil(failure(PlayerFixtures.url("does-not-exist.mp4")))
        var g = SystemRandomNumberGenerator()
        let noise = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &g) })
        for ext in ["mkv", "obu", "266", "ivf", "y4m", "mp4", "webm"] {
            XCTAssertNotNil(failure(try write("noise.\(ext)", noise)), "random bytes named .\(ext)")
        }
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }

    func testTruncatedFile() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let mp4 = try Data(contentsOf: try PlayerFixtures.indexClip("hevc.mp4"))
        XCTAssertNotNil(failure(try write("half.mp4", mp4.prefix(mp4.count / 2))))
        // Matroska cut short plays what is there and stops; it must not hang or crash. (A 4 s clip: in the tiny index
        // clip half the file is inside the first packet, which rightly fails to open.)
        let mkv = try Data(contentsOf: try AVSyncTests.flashClip("mkv"))
        let cut = try write("half.mkv", mkv.prefix(mkv.count / 2))
        let info = try MediaProbe.probe(cut)
        let choice = try DecoderSelector.choose(info, caps: .current)
        let b = try PlayerBackends.make(info: info, choice: choice, settings: PlayerSettings(), poolCapacity: 8)
        try b.start(atFrame: 0)
        var n = 0
        while try b.next() != nil { n += 1; if n > 100 { break } }
        XCTAssertGreaterThan(n, 0, "the intact part plays")
        XCTAssertLessThan(n, 96)
        b.stop()
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }

    func testImpossibleGeometryAndSizes() throws {
        try PlayerFixtures.require("ffprobe")
        var y4m = Data("YUV4MPEG2 W100000 H100000 F24:1 C420\nFRAME\n".utf8)
        y4m.append(Data(count: 1000))
        XCTAssertNotNil(failure(try write("huge.y4m", y4m)))
        // IVF header claiming AV1 at 65535×65535.
        var ivf = Data("DKIF".utf8) + Data([0, 0, 32, 0]) + Data("AV01".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF, 24, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        ivf.append(Data([16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + Data(count: 16))
        XCTAssertNotNil(failure(try write("huge.ivf", ivf)))
        // AV2 IVF with an oversized frame size and an OBU whose LEB128 size runs past the end.
        var av2 = Data("DKIF".utf8) + Data([0, 0, 32, 0]) + Data("AV02".utf8) + Data([64, 0, 64, 0, 24, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        av2.append(Data([0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0]) + Data(count: 8))
        XCTAssertNotNil(failure(try write("hostile-av2.ivf", av2)))
        let obu = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x04]) + Data(count: 64)
        XCTAssertThrowsError(try AV2Stream.summary(of: obu))
        XCTAssertNotNil(failure(try write("leb.obu", obu)))
        // A frame rate of one frame per million seconds must not become an absurd duration or frame count.
        var slow = Data("YUV4MPEG2 W64 H32 F1:1000000 C420jpeg\n".utf8)
        for _ in 0..<2 { slow.append(Data("FRAME\n".utf8)); slow.append(Data(repeating: 128, count: 64 * 32 * 3 / 2)) }
        let info = try MediaProbe.probe(try write("slow.y4m", slow))
        XCTAssertLessThanOrEqual(info.duration, 864_000)
        XCTAssertLessThanOrEqual(info.estimatedFrameCount, 10_000_000)
    }

    func testPlaylistsDisguisedAsVideoAreRefused() throws {
        try PlayerFixtures.require("ffprobe")
        for (name, body) in [("http.mp4", "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:9/segment.ts\n#EXT-X-ENDLIST\n"),
                             ("passwd.mp4", "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nfile:///etc/passwd\n#EXT-X-ENDLIST\n"),
                             ("concat.mkv", "ffconcat version 1.0\nfile 'http://127.0.0.1:9/a.mkv'\n")] {
            XCTAssertNotNil(failure(try write(name, Data(body.utf8))), name)
        }
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }

    func testProbeTimesOut() throws {
        // ToolLocator's timeout variant kills a tool that runs too long.
        let t0 = Date()
        XCTAssertThrowsError(try ToolLocator.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "anullsrc", "-f", "null", "-"], timeout: 1)) { e in
            XCTAssertTrue("\(e)".contains("timed out") || e.localizedDescription.contains("timed out"), "\(e)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }
}
