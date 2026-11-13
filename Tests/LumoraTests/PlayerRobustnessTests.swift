import XCTest
import AVFoundation
import simd
@testable import Lumora

/// Stopping decoders never blocks, audio starts that lose a race undo themselves, audio lines up with the video's
/// timeline, seeks past an estimated end recover, rotated files are shown upright, and the kernel's output encoding
/// always matches the layer it is drawn into.
@MainActor
final class PlayerRobustnessTests: XCTestCase {
    func spin(_ s: Double = 0.01) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    func waitFor(_ what: String, timeout: Double = 15, _ cond: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw XCTSkip("timed out") }
            spin()
        }
    }

    // MARK: Child processes

    /// FFmpeg ignores SIGTERM while blocked writing to a full pipe; the player's stop must not wait for it.
    func testTerminateAndInterruptNeverWaitOnAFullPipe() throws {
        try PlayerFixtures.require("ffmpeg")
        let args = ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=30", "-f", "rawvideo", "-"]
        for useInterrupt in [false, true] {
            let c = try ChildProcess(tool: "ffmpeg", args: args, qos: .utility)
            Thread.sleep(forTimeInterval: 0.5)             // nobody reads: the pipe is full and ffmpeg sits in write()
            XCTAssertTrue(c.isRunning)
            let t0 = Date()
            if useInterrupt { c.interrupt() } else { c.terminate() }
            XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05, "returns at once")
            XCTAssertNotNil(c.waitForExit(timeout: 2), "the child is gone within moments, not after a 1 s grace period")
        }
        XCTAssertTrue(PlayerFixtures.noChildrenLeft(timeout: 3))
    }

    func testAChildThatExitedByItselfIsNeverSignaled() throws {
        try PlayerFixtures.require("ffmpeg")
        let c = try ChildProcess(tool: "ffmpeg", args: ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "nullsrc=s=16x16:d=0.04", "-f", "null", "-"])
        XCTAssertEqual(c.waitForExit(timeout: 10), 0)
        XCTAssertTrue(c.hasBeenReaped, "reaped before waiters are released, so its PID is never signaled again")
        c.interrupt()
        c.terminate()
        XCTAssertTrue(PlayerFixtures.noChildrenLeft(timeout: 3))
    }

    /// A decoder parked in write() with frames queued ahead: a seek restarts it at once.
    func testSeekWithTheDecoderBlockedAheadIsFast() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        for kind in ["vp9.webm", "hevc.mkv"] {
            let (_, b) = try PlayerFixtures.backend(try PlayerFixtures.indexClip(kind))
            defer { b.stop() }
            try b.start(atFrame: 0)
            XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(try b.next())), 0)
            Thread.sleep(forTimeInterval: 0.4)            // the next frames fill the pipe; ffmpeg blocks
            for t in [16, 5] {
                let t0 = Date()
                b.interrupt()
                try b.start(atFrame: t)
                XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(try b.next())), t, kind)
                XCTAssertLessThan(Date().timeIntervalSince(t0), 0.8, "\(kind): seek to \(t) waited for the old decoder")
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }

    /// The pre-decode cache's segment workers for a raw stream read its indexed copy, not the raw stream.
    func testRawStreamSegmentWorkersUseTheIndexedCopy() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe", "vvencapp", "MP4Box")
        let saved = PreDecodeCache.rootOverride, savedFloor = PreDecodeCache.floorBytes
        PreDecodeCache.rootOverride = PlayerFixtures.url("cache-remux")
        PreDecodeCache.floorBytes = 1 << 20
        defer { PreDecodeCache.rootOverride = saved; PreDecodeCache.floorBytes = savedFloor }
        let url = try PlayerFixtures.indexClip("vvc.266")
        let (info, b) = try PlayerFixtures.backend(url)
        defer { b.stop() }
        let pipe = try XCTUnwrap(b as? FFmpegPipeBackend)
        let copy = try XCTUnwrap(PlayerEngine.remuxRawStream(info))
        pipe.useIndexedCopy(copy, rate: info.fps)
        pipe.setFrameTable(try FrameTable.read(copy, timeout: 30))
        for (start, n) in [(8, 5), (16, 8), (3, 4)] {
            let seg = try pipe.segmentWorker(limit: n)
            defer { seg.stop() }
            XCTAssertEqual(seg.choice.seekModel, .random)
            let got = try PlayerFixtures.decodeAll(seg, from: start)
            XCTAssertEqual(got.map(\.0), Array(start..<(start + n)), "segment from \(start)")
            XCTAssertEqual(got.map(\.1), Array(start..<(start + n)), "segment from \(start) shows the right pictures")
        }
    }

    // MARK: Audio

    /// Video at 0, audio from 0.5 s (as -itsoffset or a TS capture writes it): audio sample 0 is media time 0.
    static func lateAudioClip() throws -> URL {
        let video = try PlayerFixtures.indexClip("h264.mp4")
        return try PlayerFixtures.cached("late-audio.mkv") {
            try PlayerFixtures.ffmpeg(["-i", video.path, "-itsoffset", "0.5", "-f", "lavfi", "-i", "sine=f=440:d=1.5:sample_rate=48000",
                                       "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", "-f", "matroska", $0.path])
        }
    }

    func firstSound(_ src: PlayerAudioSource, frames: Int) -> Double? {
        var buf = [Float](repeating: 0, count: frames * 2)
        var got = 0
        while got < frames {
            let n = buf.withUnsafeMutableBufferPointer { src.read(into: $0.baseAddress! + got * 2, frames: frames - got) }
            if n == 0 { break }
            got += n
        }
        guard let k = (0..<got).first(where: { abs(buf[2 * $0]) > 0.05 }) else { return nil }
        return Double(k) / PlayerAudio.sampleRate
    }

    func testAudioThatStartsAfterTheVideoIsPaddedIntoPlace() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let info = try MediaProbe.probe(try Self.lateAudioClip())
        XCTAssertEqual(info.audioStartTimes[0] ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(info.startTime, 0, accuracy: 0.01)
        for (at, sound) in [(0.0, 0.5), (0.25, 0.25), (0.75, 0.0)] {
            let src = try PlayerAudio.makeSource(info: info, track: 0, at: at)
            defer { src.stop() }
            let t = try XCTUnwrap(firstSound(src, frames: 48_000), "no sound from \(at)")
            XCTAssertEqual(t, sound, accuracy: 0.012, "from \(at) s the tone starts \(sound) s in")
        }
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }

    func testAudioOffsetArguments() {
        // A TS file whose video starts 0.2 s after the audio: the seek target is the video's own time.
        let a = PlayerAudio.ffmpegArgs(path: "/x.ts", track: 1, at: 2, videoStart: 1.6, formatStart: 1.4)
        XCTAssertEqual(a[a.firstIndex(of: "-ss")! + 1], "2.200000")
        XCTAssertTrue(a.contains("aresample=48000:first_pts=0"))
        XCTAssertEqual(a[a.firstIndex(of: "-map")! + 1], "0:a:1")
        XCTAssertFalse(PlayerAudio.ffmpegArgs(path: "/x.mkv", track: 0, at: 0, videoStart: 0, formatStart: 0).contains("-ss"))
    }

    /// Pause (or K) right after play, while the audio decoder is still starting: the start undoes itself.
    func testPauseDuringAudioStartLeavesItSilent() throws {
        let url = try AVSyncTests.flashClip("mkv")
        let e = PlayerEngine()
        defer { e.stop() }
        e.manualAudio = true
        e.open(url)
        XCTAssertTrue(e.waitUntilOpened())
        try waitFor("first frame") { e.frameForDisplay(targetHost: 0) != nil }
        for keys in [["space", "space"], ["l", "k"], ["l", "l", "k"]] {
            for k in keys { if k == "space" { e.togglePlay() } else { e.jkl(Character(k)) } }
            XCTAssertFalse(e.isPlaying)
            let deadline = Date(timeIntervalSinceNow: 1.5)
            while Date() < deadline { spin(0.02) }
            let out = try XCTUnwrap(e.audioOutputForTests)
            XCTAssertFalse(out.node.isPlaying, "\(keys): audio keeps playing while the video is paused")
            XCTAssertFalse(e.audioActive, "\(keys)")
            let t0 = Date()
            e.togglePlay(); e.pause()
            XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1, "\(keys): play / pause never blocks the main thread")
        }
    }

    // MARK: Seeking past an estimated end

    /// 1 s of video with 2 s of audio: the container duration overestimates the frames until the frame table
    /// arrives. A seek there must land on the real last frame and leave the player usable.
    func testSeekPastTheEstimatedEndLandsOnTheLastFrame() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let video = try PlayerFixtures.indexClip("h264.mp4")
        let url = try PlayerFixtures.cached("long-audio.mkv") {
            try PlayerFixtures.ffmpeg(["-i", video.path, "-f", "lavfi", "-i", "sine=f=440:d=2:sample_rate=48000",
                                       "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "libopus", "-f", "matroska", $0.path])
        }
        let info = try MediaProbe.probe(url)
        XCTAssertGreaterThan(info.estimatedFrameCount, 40, "the estimate counts the audio's length")
        let choice = try DecoderSelector.choose(info, caps: .current, prefs: PlayerSettings())
        let e = PlayerEngine()
        defer { e.stop() }
        var caps = DecoderCapabilities.current
        caps.hasFFprobe = false                       // no background frame table: the estimate stays
        e.capabilities = caps
        e.manualAudio = true
        e.open(info: info, choice: choice)
        try waitFor("first frame") { e.frameForDisplay(targetHost: 0) != nil }
        e.seek(toFrame: info.estimatedFrameCount - 1)
        // The search shows frame 23 first; the count becomes exact when that run reaches its end of stream.
        try waitFor("landing on the real end (shown \(e.currentFrame?.index ?? -1), count \(e.frameCount))") {
            _ = e.frameForDisplay(targetHost: 0); return e.currentFrame?.index == 23 && e.frameCount == 24
        }
        XCTAssertEqual(e.frameCount, 24)
        XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(e.currentFrame)), 23)
        e.step(-1)
        try waitFor("step back") { _ = e.frameForDisplay(targetHost: 0); return e.currentFrame?.index == 22 }
    }

    // MARK: Rotation

    func testRotationIsReadAndFramesKeepTheirStoredSize() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        for kind in ["h264-rot.mkv", "h264-rot.mp4"] {
            let (info, b) = try PlayerFixtures.backend(try PlayerFixtures.indexClip(kind))
            defer { b.stop() }
            XCTAssertEqual(info.video.rotation, 270, kind)
            XCTAssertFalse(info.video.mirrored, kind)
            XCTAssertEqual(info.video.width, 320, kind)
            XCTAssertEqual(info.video.displayAspect, 180.0 / 320, accuracy: 1e-6, "shown portrait")
            let all = try PlayerFixtures.decodeAll(b)
            XCTAssertEqual(all.map(\.1), Array(0..<24), "\(kind) (\(b.choice.tool)): frames read with the stored geometry")
        }
        XCTAssertEqual(VideoInfo.quarterTurns(clockwise: -90), 270)
        XCTAssertEqual(VideoInfo.quarterTurns(clockwise: 450), 90)
        XCTAssertEqual(VideoInfo.quarterTurns(clockwise: -180.0001), 180)
    }

    func testTheKernelRotatesThePicture() throws {
        try TestHardware.requireGPU()
        // 4 × 2 source, luma code = 100 + 10 × y + x (full range 8-bit 4:4:4 BT.709, linear "SDR").
        let l = FrameLayout.planar(width: 4, height: 2, chroma: .c444, sampleBytes: 1, bits: 8)
        let pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: 1)
        let buf = pool.acquire()!
        for y in 0..<2 { for x in 0..<4 {
            buf.bytes.storeBytes(of: UInt8(100 + 10 * y + x), toByteOffset: l.offsets[0] + y * l.strides[0] + x, as: UInt8.self)
            buf.bytes.storeBytes(of: UInt8(128), toByteOffset: l.offsets[1] + y * l.strides[1] + x, as: UInt8.self)
            buf.bytes.storeBytes(of: UInt8(128), toByteOffset: l.offsets[2] + y * l.strides[2] + x, as: UInt8.self)
        } }
        let color = SignalColor(primaries: 1, transfer: 8, matrix: 1, fullRange: true, chromaLocation: .center,
                                primariesTagged: true, transferTagged: true, matrixTagged: true, rangeTagged: true)
        let f = PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(buf), color: color)
        var info = MediaInfo(url: URL(fileURLWithPath: "/tmp/r.mkv"), container: "mkv")
        info.video.width = 4; info.video.height = 2; info.video.color = color
        let renderer = PlayerRenderer()
        func code(_ v: Float) -> Int { Int((v * 255).rounded()) }
        // Expected shown picture (rows top to bottom) for each clockwise rotation.
        let cases: [(Int, Int, Int, [[Int]])] = [
            (0, 4, 2, [[100, 101, 102, 103], [110, 111, 112, 113]]),
            (90, 2, 4, [[110, 100], [111, 101], [112, 102], [113, 103]]),
            (180, 4, 2, [[113, 112, 111, 110], [103, 102, 101, 100]]),
            (270, 2, 4, [[103, 113], [102, 112], [101, 111], [100, 110]]),
        ]
        for (rot, w, h, want) in cases {
            info.video.rotation = rot
            let (u, _) = PlayerRenderer.uniforms(frame: f, info: info, display: DisplayState(headroom: 1), settings: PlayerSettings(),
                                                 interpret: .auto, viewport: SIMD4(0, 0, Float(w), Float(h)))
            let px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u, width: w, height: h))
            let got = (0..<h).map { y in (0..<w).map { x in code(px[y * w + x].y) } }
            XCTAssertEqual(got, want, "rotation \(rot)")
        }
    }

    // MARK: Output encoding and layer agree

    static func patch(code: Float, transfer: Int, primaries: Int = 9) -> (PlayerFrame, MediaInfo) {
        let l = FrameLayout.planar(width: 1, height: 1, chroma: .c444, sampleBytes: 2, bits: 16)
        let pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: 1)
        let b = pool.acquire()!
        b.bytes.storeBytes(of: UInt16((code * 65535).rounded()), toByteOffset: l.offsets[0], as: UInt16.self)
        b.bytes.storeBytes(of: UInt16(32768), toByteOffset: l.offsets[1], as: UInt16.self)
        b.bytes.storeBytes(of: UInt16(32768), toByteOffset: l.offsets[2], as: UInt16.self)
        let color = SignalColor(primaries: primaries, transfer: transfer, matrix: 9, fullRange: true, chromaLocation: .center,
                                primariesTagged: true, transferTagged: true, matrixTagged: true, rangeTagged: true)
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/p.mkv"), container: "mkv")
        i.video.width = 1; i.video.height = 1; i.video.color = color
        return (PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(b), color: color), i)
    }

    func testKernelOutputAlwaysMatchesTheLayer() {
        var macOS = PlayerSettings(); macOS.toneMapping = .macOS
        for transfer in [1, 14, 16, 18] {
            for alt in [nil, 18] as [Int?] {
                for interpret in InterpretMode.allCases {
                    for settings in [PlayerSettings(), macOS] {
                        for storage in [FrameLayout.Storage.planarBuffer, .rgbaTexture] {
                            var (f, i) = Self.patch(code: 0.5, transfer: transfer)
                            i.video.alternativeTransfer = alt
                            if storage == .rgbaTexture {
                                f = PlayerFrame(index: 0, pts: 0, layout: FrameLayout(storage: .rgbaTexture, width: 1, height: 1, chroma: .c444,
                                                                                      sampleBytes: 2, bits: 16, msbAligned: false),
                                                planes: f.planes, color: f.color)
                            }
                            let out = PlayerRenderer.output(frameColor: f.color, storage: storage, info: i, settings: settings, interpret: interpret)
                            let (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 4), settings: settings,
                                                                 interpret: interpret, viewport: SIMD4(0, 0, 1, 1), outputMode: out.kernelMode)
                            let what = "t\(transfer) alt \(alt ?? 0) \(interpret) \(settings.toneMapping) \(storage)"
                            switch out {
                            case .hlg:
                                XCTAssertEqual(u.transfer, Int32(PLAYER_TF_HLG), "the kernel's HLG output needs an HLG signal: \(what)")
                                XCTAssertNotEqual(storage, .rgbaTexture, what)
                            case .pq:
                                XCTAssertTrue(u.transfer == Int32(PLAYER_TF_PQ) || storage == .rgbaTexture, what)
                            case .extendedLinear(let edr):
                                XCTAssertEqual(edr, u.transfer == Int32(PLAYER_TF_PQ) || u.transfer == Int32(PLAYER_TF_HLG) || storage == .rgbaTexture, what)
                                if settings.toneMapping == .macOS { XCTAssertFalse(edr, "macOS passes HDR through: \(what)") }
                            }
                        }
                    }
                }
            }
        }
    }

    func testInterpretOverridesRenderTheirSignal() throws {
        try TestHardware.requireGPU()
        var macOS = PlayerSettings(); macOS.toneMapping = .macOS
        let renderer = PlayerRenderer()
        // HDR10 shown as SDR: BT.1886, not PQ code values in a linear layer.
        var (f, i) = Self.patch(code: 0.58, transfer: 16)
        var out = PlayerRenderer.output(frameColor: f.color, storage: f.layout.storage, info: i, settings: macOS, interpret: .sdr)
        XCTAssertEqual(out, .extendedLinear(edr: false))
        var (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 4), settings: macOS, interpret: .sdr,
                                             viewport: SIMD4(0, 0, 1, 1), outputMode: out.kernelMode)
        var px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))[0]
        XCTAssertEqual(Double(px.y), pow(0.58, 2.4), accuracy: 2e-3)
        // HLG read as PQ under macOS tone mapping: a PQ layer, and the kernel writes the PQ signal.
        (f, i) = Self.patch(code: 0.58, transfer: 18)
        out = PlayerRenderer.output(frameColor: f.color, storage: f.layout.storage, info: i, settings: macOS, interpret: .pq)
        XCTAssertEqual(out, .pq)
        (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 4), settings: macOS, interpret: .pq,
                                         viewport: SIMD4(0, 0, 1, 1), outputMode: out.kernelMode)
        px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))[0]
        XCTAssertEqual(Double(px.y), 0.58, accuracy: 2e-3, "PQ code value passed through")
        // VVenC HLG (tagged BT.2020 SDR, HLG in the SEI): an HLG layer and an HLG signal.
        (f, i) = Self.patch(code: 0.75, transfer: 14)
        i.video.alternativeTransfer = 18
        out = PlayerRenderer.output(frameColor: f.color, storage: f.layout.storage, info: i, settings: macOS, interpret: .auto)
        XCTAssertEqual(out, .hlg)
        (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 4), settings: macOS, interpret: .auto,
                                         viewport: SIMD4(0, 0, 1, 1), outputMode: out.kernelMode)
        px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))[0]
        XCTAssertEqual(Double(px.y), 0.75, accuracy: 2e-3, "HLG code value passed through, not linear light")
    }

    func testDolbyVision5NeedsNoGamutConversion() {
        // Profile 5 VUI is usually unspecified; the guess for 1080p is BT.709, but macOS hands over BT.2020.
        var c = SignalColor(); c.resolve(height: 1080, chroma: .c420)
        XCTAssertEqual(c.primaries, 1)
        let l = FrameLayout(storage: .rgbaTexture, width: 1920, height: 1080, chroma: .c444, sampleBytes: 2, bits: 16, msbAligned: false)
        let pool = BufferPool(device: MetalContext.shared.device, length: 16, capacity: 1)
        let f = PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(pool.acquire()!), color: c)
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/dv5.mp4"), container: "mp4")
        i.video.color = c
        i.video.dolbyVision = DolbyVisionInfo(profile: 5, level: 6, blCompatibilityID: 0, hasEnhancementLayer: false)
        let (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 4), settings: PlayerSettings(),
                                             interpret: .auto, viewport: SIMD4(0, 0, 1920, 1080))
        XCTAssertEqual(u.toBT2020, matrix_identity_float3x3)
        XCTAssertEqual(u.luma.x, 0.2627, accuracy: 1e-6)
        XCTAssertEqual(PlayerRenderer.output(frameColor: c, storage: .rgbaTexture, info: i, settings: PlayerSettings(), interpret: .auto),
                       .extendedLinear(edr: true))
    }

    // MARK: HLG across the headroom

    /// HLG 75% (reference white) as the headroom moves: no jump anywhere, and never darker for more headroom.
    func testHLGIsContinuousAcrossTheHeadroom() throws {
        try TestHardware.requireGPU()
        let renderer = PlayerRenderer()
        let (f, i) = Self.patch(code: 0.75, transfer: 18)
        var last: Double?
        var h = 1.0
        while h <= 6.0001 {
            let (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: h), settings: PlayerSettings(),
                                                 interpret: .auto, viewport: SIMD4(0, 0, 1, 1))
            let v = Double(PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))[0].y)
            if let last {
                XCTAssertGreaterThanOrEqual(v, last - 1e-4, "darker at headroom \(h)")
                XCTAssertLessThan(abs(v - last) / last, 0.02, "a step at headroom \(h): \(last) -> \(v)")
            }
            last = v
            h += 0.01
        }
        XCTAssertEqual(PlayerRenderer.hlgNominalPeak(displayPeak: 100), 400)
        XCTAssertEqual(PlayerRenderer.hlgNominalPeak(displayPeak: 1000), 1000)
        XCTAssertEqual(PlayerRenderer.hlgNominalPeak(displayPeak: 5000), 2000)
    }

    // MARK: VVC alternative transfer SEI

    func testVVCAlternativeTransferSEIParser() {
        // Prefix SEI (NAL type 23) with two messages: 137 holding an emulation-prevented 00 00 01, then 147 = 18.
        let sei: [UInt8] = [0, 0, 1, 0x00, 0xB9, 0x89, 0x03, 0x00, 0x00, 0x03, 0x01, 0x93, 0x01, 0x12, 0x80]
        let slice: [UInt8] = [0, 0, 0, 1, 0x00, 0x39, 0xAA, 0xBB]
        XCTAssertEqual(VVCSEI.alternativeTransfer(annexB: Data(sei + slice)), 18)
        XCTAssertNil(VVCSEI.alternativeTransfer(annexB: Data(slice + sei)), "only SEI before the first slice counts")
        XCTAssertNil(VVCSEI.alternativeTransfer(annexB: Data([0, 0, 1, 0x00, 0xB9, 0x89, 0x03, 0x00, 0x00, 0x03, 0x01, 0x80])))
        XCTAssertNil(VVCSEI.alternativeTransfer(annexB: Data([0, 0, 1, 0x00, 0xB9, 0x93, 0x40, 0x12])), "a size past the end")
        XCTAssertEqual(VVCSEI.rbsp([0, 0, 3, 1, 0, 0, 3, 0][...]), [0, 0, 1, 0, 0, 0])
    }
}
