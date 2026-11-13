import XCTest
@testable import Lumora

/// Frame-accurate landing on every backend: each test clip shows its own frame number as 12 black / white blocks,
/// so the decoded picture says which frame it really is.
final class PlayerSeekTests: XCTestCase {
    /// first, last, key frames (every 8), key ± 1, and a few others.
    static let targets = [0, 23, 8, 7, 9, 16, 15, 13, 5, 20, 1]

    func check(_ kind: String, expect backend: PlayerBackendKind, targets: [Int] = targets, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try PlayerFixtures.indexClip(kind)
        let (info, b) = try PlayerFixtures.backend(url)
        defer { b.stop() }
        XCTAssertEqual(b.choice.backend, backend, "\(kind): \(b.choice.tool)", file: file, line: line)
        let all = try PlayerFixtures.decodeAll(b)
        XCTAssertEqual(all.map(\.0), Array(0..<24), "\(kind): every frame, in order", file: file, line: line)
        XCTAssertEqual(all.map(\.1), Array(0..<24), "\(kind): each frame shows its own number", file: file, line: line)
        for t in targets {
            try b.start(atFrame: t)
            let f = try XCTUnwrap(try b.next(), "\(kind): no frame after seeking to \(t)", file: file, line: line)
            XCTAssertEqual(f.index, t, "\(kind): landed on the wrong index", file: file, line: line)
            XCTAssertEqual(PlayerFixtures.decodeIndex(f), t, "\(kind): seek to \(t) shows another frame", file: file, line: line)
            XCTAssertEqual(f.pts, Double(t) / info.fps, accuracy: 1e-3, file: file, line: line)
            if t + 1 < 24 {
                let g = try XCTUnwrap(try b.next(), file: file, line: line)
                XCTAssertEqual(PlayerFixtures.decodeIndex(g), t + 1, "\(kind): step forward after \(t)", file: file, line: line)
            }
        }
    }

    func testAVFoundationHEVC() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("hevc.mp4", expect: .avfoundation)
    }

    func testFFmpegVideoToolboxHEVCInMatroska() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("hevc.mkv", expect: .ffmpeg)
    }

    func testFFmpegSoftwareHEVC12Bit() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("hevc12.mp4", expect: .ffmpeg)
    }

    func testAV1InMatroska() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("av1.mkv", expect: .ffmpeg)
    }

    func testAV1Dav1dSoftware() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        var prefs = PlayerSettings()
        prefs.preferHardware = false
        let url = try PlayerFixtures.indexClip("av1.mkv")
        let (_, b) = try PlayerFixtures.backend(url, prefs: prefs)
        defer { b.stop() }
        XCTAssertEqual(b.choice.ffmpegDecoder, "libdav1d")
        for t in [0, 8, 9, 23] {
            try b.start(atFrame: t)
            XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(try b.next())), t)
        }
    }

    func testVP9() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("vp9.webm", expect: .ffmpeg)
    }

    func testH264AndY4M() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        try check("h264.mp4", expect: .avfoundation)
        try check("y4m", expect: .ffmpeg)
    }

    func testMPEGTSWithANonZeroStart() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let info = try MediaProbe.probe(try PlayerFixtures.indexClip("h264.ts"))
        XCTAssertGreaterThan(info.formatStartTime, 1, "TS clocks start at 1.4 s")
        try check("h264.ts", expect: .ffmpeg)
    }

    func testRawVVCDecodesForwardThenSeeksDirectlyAfterRemux() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe", "vvencapp", "MP4Box")
        let saved = PreDecodeCache.rootOverride, savedFloor = PreDecodeCache.floorBytes
        PreDecodeCache.rootOverride = PlayerFixtures.url("cache-remux")
        PreDecodeCache.floorBytes = 1 << 20
        defer { PreDecodeCache.rootOverride = saved; PreDecodeCache.floorBytes = savedFloor }
        try check("vvc.266", expect: .ffmpeg, targets: [0, 23, 8, 9])         // decode forward from the start
        let url = try PlayerFixtures.indexClip("vvc.266")
        let (info, b) = try PlayerFixtures.backend(url)
        defer { b.stop() }
        XCTAssertEqual(b.choice.seekModel, .fromStart)
        let copy = try XCTUnwrap(PlayerEngine.remuxRawStream(info), "MP4Box remux")
        let pipe = try XCTUnwrap(b as? FFmpegPipeBackend)
        pipe.useIndexedCopy(copy, rate: info.fps)
        XCTAssertEqual(pipe.choice.seekModel, .random)
        for t in Self.targets {
            try b.start(atFrame: t)
            XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(try b.next())), t, "remuxed VVC seek to \(t)")
        }
    }

    func testAV2FromRandomAccessPoints() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        let url = try PlayerFixtures.indexClip("av2.obu")
        let (info, b) = try PlayerFixtures.backend(url)
        defer { b.stop() }
        XCTAssertEqual(b.choice.backend, .avm)
        XCTAssertEqual(info.av2?.randomAccessPoints, [0, 8, 16])
        // avmdec's --random-access-point-index=k starts output exactly at the k-th random access point.
        let avm = try XCTUnwrap(b as? AVMBackend)
        for (k, rap) in [0, 8, 16].enumerated() {
            XCTAssertEqual(avm.startPoint(for: rap + 3).0, k)
            try b.start(atFrame: rap)
            XCTAssertEqual(PlayerFixtures.decodeIndex(try XCTUnwrap(try b.next())), rap, "RAP \(k)")
        }
        try check("av2.obu", expect: .avm, targets: [0, 23, 8, 7, 9, 16, 17, 12])
    }

    func testAV2InIVF() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        try check("av2.ivf", expect: .avm, targets: [0, 23, 8, 9, 16])
    }
}

/// Decoders agree with each other and with the source, in code values.
@MainActor
final class PlayerCodecRoundTripTests: XCTestCase {
    /// Every luma and chroma sample of a frame at its own bit depth (MSB-aligned formats shifted down).
    func samples(_ f: PlayerFrame) -> [[Int]] {
        let l = f.layout
        var planes: [[Int]] = []
        func read(_ base: UnsafeRawPointer, stride: Int, w: Int, h: Int, step: Int, offset: Int) -> [Int] {
            var out: [Int] = []
            out.reserveCapacity(w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * stride + (x * step + offset) * l.sampleBytes
                    let raw = l.sampleBytes == 1 ? Int(p.load(as: UInt8.self)) : Int(p.loadUnaligned(as: UInt16.self))
                    out.append(l.msbAligned ? raw >> (16 - l.bits) : raw)
                }
            }
            return out
        }
        switch f.planes {
        case .buffer(let b):
            planes.append(read(b.bytes + l.offsets[0], stride: l.strides[0], w: l.width, h: l.height, step: 1, offset: 0))
            if l.storage == .semiPlanarBuffer {
                for k in 0..<2 { planes.append(read(b.bytes + l.offsets[1], stride: l.strides[1], w: l.chromaWidth, h: l.chromaHeight, step: 2, offset: k)) }
            } else {
                for k in 1...2 { planes.append(read(b.bytes + l.offsets[k], stride: l.strides[k], w: l.chromaWidth, h: l.chromaHeight, step: 1, offset: 0)) }
            }
        case .pixelBuffer(let pb):
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            planes.append(read(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 0), w: l.width, h: l.height, step: 1, offset: 0))
            for k in 0..<2 {
                planes.append(read(CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, stride: CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                                   w: l.chromaWidth, h: l.chromaHeight, step: 2, offset: k))
            }
        }
        return planes
    }

    func frames(_ url: URL, prefs: PlayerSettings = PlayerSettings(), count: Int = 24) throws -> (DecoderChoice, [[[Int]]]) {
        let (_, b) = try PlayerFixtures.backend(url, prefs: prefs)
        defer { b.stop() }
        try b.start(atFrame: 0)
        var out: [[[Int]]] = []
        while out.count < count, let f = try b.next() { out.append(samples(f)) }
        return (b.choice, out)
    }

    func assertIdentical(_ a: [[[Int]]], _ b: [[[Int]]], _ what: String) {
        XCTAssertEqual(a.count, b.count, what)
        var worst = 0
        for (fa, fb) in zip(a, b) { for (pa, pb) in zip(fa, fb) { for (x, y) in zip(pa, pb) { worst = max(worst, abs(x - y)) } } }
        XCTAssertEqual(worst, 0, "\(what): max code-value difference")
    }

    /// The same AV1 through VideoToolbox (p010) and dav1d (planar), and the same HEVC through AVFoundation (x420) and
    /// FFmpeg's software decoder: bit-identical, which proves both unpack paths.
    func testCrossDecoderBitExactness() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        var sw = PlayerSettings(); sw.preferHardware = false
        let av1 = try PlayerFixtures.indexClip("av1.mkv")
        let (hwChoice, hw) = try frames(av1)
        let (swChoice, soft) = try frames(av1, prefs: sw)
        XCTAssertTrue(hwChoice.hwaccel, hwChoice.tool)
        XCTAssertEqual(swChoice.ffmpegDecoder, "libdav1d")
        assertIdentical(hw, soft, "AV1 VideoToolbox vs dav1d")

        let hevc = try PlayerFixtures.indexClip("hevc.mp4")
        let (avfChoice, avf) = try frames(hevc)
        let (ffChoice, ff) = try frames(hevc, prefs: sw)
        XCTAssertEqual(avfChoice.backend, .avfoundation)
        XCTAssertEqual(ffChoice.ffmpegDecoder, "hevc")
        assertIdentical(avf, ff, "HEVC AVFoundation vs FFmpeg software")
    }

    /// The player's AV2 frames are exactly what avmdec writes to a Y4M file.
    func testAV2MatchesTheReferenceDecoder() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        let obu = try PlayerFixtures.indexClip("av2.obu")
        let (_, player) = try frames(obu)
        let ref = try AV2ExportTests.decode(obu, avmdec: try XCTUnwrap(PlayerFixtures.tool("avmdec")))
        XCTAssertEqual(player.count, ref.frames)
        for (n, f) in player.enumerated() where n < ref.frames {
            XCTAssertEqual(f[0].map { UInt16($0) }, ref.luma[n], "frame \(n) luma")
        }
    }

    /// Lossy codecs at moderate quality stay close to the source in 10-bit code values.
    func testLumaErrorAgainstTheSource() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let (_, src) = try frames(try PlayerFixtures.indexClip("y4m"))
        for kind in ["hevc.mp4", "av1.mkv", "vp9.webm"] {
            let (_, dec) = try frames(try PlayerFixtures.indexClip(kind))
            var sum = 0, n = 0
            for (a, b) in zip(src, dec) { for (x, y) in zip(a[0], b[0]) { sum += abs(x - y); n += 1 } }
            XCTAssertLessThanOrEqual(Double(sum) / Double(max(1, n)), 2, "\(kind): mean luma error in codes")
        }
    }

    /// Flat PQ patches through HEVC and back to nits: within 1 %.
    func testFlatPQPatchesThroughHEVC() throws {
        try TestHardware.requireGPU()
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let levels: [Double] = [1, 10, 100, 203, 1000, 4000]
        let spec = PlayerFixtures.Spec(width: 128, height: 64, bits: 10, chroma: .c420, frames: levels.count)
        let y4m = try PlayerFixtures.cached("pq-patches.y4m") {
            try PlayerFixtures.writeY4M($0, spec) { f, p, _, _ in p == 0 ? Int((64 + 876 * PlayerRenderer.pq(levels[f])).rounded()) : 512 }
        }
        let mp4 = try PlayerFixtures.cached("pq-patches.mp4") {
            try PlayerFixtures.ffmpeg(["-i", y4m.path, "-c:v", "libx265", "-x265-params",
                                       "log-level=error:crf=16:keyint=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:max-cll=4000,1000",
                                       "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084",
                                       "-colorspace", "bt2020nc", "-f", "mp4", $0.path])
        }
        let (info, b) = try PlayerFixtures.backend(mp4)
        defer { b.stop() }
        try b.start(atFrame: 0)
        let renderer = PlayerRenderer()
        for nits in levels {
            let f = try XCTUnwrap(try b.next())
            let (u, _) = PlayerRenderer.uniforms(frame: f, info: info, display: DisplayState(headroom: 100), settings: PlayerSettings(),
                                                 interpret: .auto, viewport: SIMD4(0, 0, 128, 64))
            let px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))
            let got = Double(px[32 * 128 + 64].y) * 100
            XCTAssertEqual(got, nits, accuracy: nits * 0.01 + 0.02, "\(nits) nits through HEVC")
        }
    }
}
