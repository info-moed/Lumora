import XCTest
@testable import Lumora

/// Decoder selection as a table: no files, no tools, just MediaInfo + capabilities in, a choice out.
final class PlayerSelectorTests: XCTestCase {
    /// This Mac as measured (M3 Max, FFmpeg 9 with dav1d and VideoToolbox, avmdec installed).
    static let mac = DecoderCapabilities(
        vtHardware: ["avc1", "hvc1", "av01", "apch", "ap4h"],
        ffmpegDecoders: ["h264", "hevc", "av1", "libdav1d", "vvc", "vp9", "libvpx-vp9", "prores", "rawvideo", "ffv1", "mpeg2video"],
        ffmpegHWAccels: ["videotoolbox"], hasFFmpeg: true, hasFFprobe: true, hasAVMDec: true, avmdecVersion: "15.0.0", hasMP4Box: true)

    func info(_ codec: PlayerCodec, bits: Int = 10, chroma: PlayerChroma = .c420, ext: String, avf: Bool? = nil,
              pix: String? = nil, fourCC: String? = nil) -> MediaInfo {
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/clip.\(ext)"), container: ext)
        i.isRawElementaryStream = MediaProbe.rawStreamExtensions.contains(ext)
        i.avfDecodable = avf ?? ["mp4", "mov", "m4v"].contains(ext)
        i.video.codec = codec
        i.video.bitDepth = bits
        i.video.chroma = chroma
        i.video.width = 1920; i.video.height = 1080
        i.video.fourCC = fourCC
        i.video.pixelFormat = pix ?? DecoderSelector.softwarePixelFormat(VideoInfo(bitDepth: bits, chroma: chroma))
        return i
    }

    func choose(_ i: MediaInfo, caps: DecoderCapabilities = mac, prefs: PlayerSettings = PlayerSettings()) throws -> DecoderChoice {
        try DecoderSelector.choose(i, caps: caps, prefs: prefs)
    }

    func testHardwareDecodableMP4GoesToAVFoundation() throws {
        for (codec, bits, chroma) in [(PlayerCodec.hevc, 10, PlayerChroma.c420), (.hevc, 10, .c422), (.hevc, 10, .c444), (.h264, 8, .c420), (.av1, 10, .c420)] {
            let c = try choose(info(codec, bits: bits, chroma: chroma, ext: "mp4"))
            XCTAssertEqual(c.backend, .avfoundation, "\(codec) \(bits)-bit \(chroma)")
            XCTAssertTrue(c.hardware)
        }
        let prores = try choose(info(.prores, bits: 12, chroma: .c444, ext: "mov", fourCC: "ap4h"))
        XCTAssertEqual(prores.backend, .avfoundation)
    }

    func testHEVC12BitGoesToFFmpegSoftware() throws {
        let c = try choose(info(.hevc, bits: 12, ext: "mp4", pix: "yuv420p12le"))
        XCTAssertEqual(c.backend, .ffmpeg)
        XCTAssertEqual(c.ffmpegDecoder, "hevc")
        XCTAssertFalse(c.hwaccel)
        XCTAssertFalse(c.hardware)
        XCTAssertEqual(c.pixelFormat, "yuv420p12le")
        XCTAssertTrue(c.reason.contains("12-bit"), c.reason)
    }

    func testMatroskaUsesFFmpegWithVideoToolbox() throws {
        let hevc = try choose(info(.hevc, ext: "mkv"))
        XCTAssertEqual(hevc.backend, .ffmpeg)
        XCTAssertTrue(hevc.hwaccel && hevc.hardware)
        XCTAssertEqual(hevc.pixelFormat, "p010le")
        XCTAssertEqual(hevc.softwareFallback, "hevc")
        XCTAssertEqual(try choose(info(.hevc, chroma: .c422, ext: "mkv")).pixelFormat, "p210le")
        XCTAssertEqual(try choose(info(.hevc, chroma: .c444, ext: "ts")).pixelFormat, "p410le")
        XCTAssertEqual(try choose(info(.h264, bits: 8, ext: "mkv")).pixelFormat, "nv12")
        let av1 = try choose(info(.av1, ext: "mkv"))
        XCTAssertEqual(av1.ffmpegDecoder, "av1")
        XCTAssertTrue(av1.hwaccel)
        XCTAssertEqual(av1.softwareFallback, "libdav1d", "FFmpeg's av1 decoder has no software path: fall back to dav1d")
    }

    func testAV1BeyondMainGoesToDav1d() throws {
        for (bits, chroma) in [(10, PlayerChroma.c444), (10, .c422), (12, .c420)] {
            let c = try choose(info(.av1, bits: bits, chroma: chroma, ext: "mkv"))
            XCTAssertEqual(c.ffmpegDecoder, "libdav1d", "AV1 \(bits)-bit \(chroma)")
            XCTAssertFalse(c.hwaccel)
        }
        var noVT = Self.mac
        noVT.vtHardware.remove("av01")
        XCTAssertEqual(try choose(info(.av1, ext: "mp4"), caps: noVT).ffmpegDecoder, "libdav1d", "no AV1 hardware (M1/M2)")
        var noDav1d = noVT
        noDav1d.ffmpegDecoders.remove("libdav1d")
        XCTAssertThrowsError(try choose(info(.av1, ext: "mkv"), caps: noDav1d)) { e in
            XCTAssertTrue((e as? PlayerError)?.errorDescription?.contains("dav1d") == true)
        }
    }

    func testVP9AndVVCUseFFmpegsNativeDecoders() throws {
        XCTAssertEqual(try choose(info(.vp9, ext: "webm")).ffmpegDecoder, "vp9")
        let raw = try choose(info(.vvc, ext: "266"))
        XCTAssertEqual(raw.ffmpegDecoder, "vvc")
        XCTAssertEqual(raw.seekModel, .fromStart, "a raw .266 has no index until it is remuxed")
        let mp4 = try choose(info(.vvc, ext: "mp4", avf: false))
        XCTAssertEqual(mp4.ffmpegDecoder, "vvc")
        XCTAssertEqual(mp4.seekModel, .random)
        var old = Self.mac
        old.ffmpegDecoders.remove("vvc")
        XCTAssertThrowsError(try choose(info(.vvc, ext: "266"), caps: old)) { e in
            guard case .missingTool(let t, let how) = e as? PlayerError else { return XCTFail("\(e)") }
            XCTAssertTrue(t.contains("7.1")); XCTAssertTrue(how.contains("brew install ffmpeg"))
        }
    }

    func testAV2() throws {
        let c = try choose(info(.av2, ext: "obu", avf: false))
        XCTAssertEqual(c.backend, .avm)
        XCTAssertEqual(c.tool, "avmdec 15.0.0")
        XCTAssertEqual(c.seekModel, .fromRandomAccessPoint)
        var future = Self.mac
        future.ffmpegDecoders.insert("libavm")
        let f = try choose(info(.av2, ext: "obu", avf: false), caps: future)
        XCTAssertEqual(f.backend, .ffmpeg)
        XCTAssertEqual(f.ffmpegDecoder, "libavm", "an FFmpeg AV2 decoder wins over avmdec")
        var none = Self.mac
        none.hasAVMDec = false
        XCTAssertThrowsError(try choose(info(.av2, ext: "obu", avf: false), caps: none)) { e in
            XCTAssertEqual(e as? PlayerError, .missingTool("avmdec", PlayerError.avmHint))
            XCTAssertTrue((e as? PlayerError)?.errorDescription?.contains("install-encoders.sh") == true)
        }
    }

    func testH264HighBitDepthAndProResInMatroskaUseSoftware() throws {
        let h10 = try choose(info(.h264, bits: 10, ext: "mp4", pix: "yuv420p10le"))
        XCTAssertEqual(h10.backend, .ffmpeg)
        XCTAssertEqual(h10.ffmpegDecoder, "h264")
        XCTAssertFalse(h10.hwaccel)
        XCTAssertEqual(try choose(info(.prores, bits: 10, chroma: .c422, ext: "mkv", pix: "yuv422p10le")).ffmpegDecoder, "prores")
    }

    func testPreferHardwareOffAndMissingTools() throws {
        var prefs = PlayerSettings()
        prefs.preferHardware = false
        let c = try choose(info(.hevc, ext: "mp4"), prefs: prefs)
        XCTAssertEqual(c.backend, .ffmpeg)
        XCTAssertFalse(c.hwaccel)
        var noFF = Self.mac
        noFF.hasFFmpeg = false
        XCTAssertThrowsError(try choose(info(.hevc, ext: "mkv"), caps: noFF)) { e in
            XCTAssertEqual(e as? PlayerError, .missingTool("ffmpeg", PlayerError.ffmpegHint))
        }
        XCTAssertEqual(try choose(info(.hevc, ext: "mp4"), caps: noFF).backend, .avfoundation, "MP4 still plays without FFmpeg")
        XCTAssertThrowsError(try choose(info(.other("cinepak"), bits: 8, ext: "avi"))) { e in
            XCTAssertEqual(e as? PlayerError, .unsupportedCodec("cinepak"))
        }
    }

    func testDolbyVisionProfile5InMatroskaIsRefused() throws {
        var i = info(.hevc, ext: "mkv")
        i.video.dolbyVision = DolbyVisionInfo(profile: 5, level: 6, blCompatibilityID: 0, hasEnhancementLayer: false)
        XCTAssertThrowsError(try choose(i)) { XCTAssertEqual($0 as? PlayerError, .dvProfile5InMKV) }
        var mp4 = info(.hevc, ext: "mp4")
        mp4.video.dolbyVision = i.video.dolbyVision
        XCTAssertEqual(try choose(mp4).backend, .avfoundation)
        var p81 = info(.hevc, ext: "mkv")
        p81.video.dolbyVision = DolbyVisionInfo(profile: 8, level: 6, blCompatibilityID: 1, hasEnhancementLayer: false)
        XCTAssertEqual(try choose(p81).backend, .ffmpeg, "8.1 plays its HDR10 base layer anywhere")
        XCTAssertEqual(p81.video.dolbyVision?.summary, "Dolby Vision 8.1: playing the HDR10 base layer")
        XCTAssertEqual(DolbyVisionInfo(profile: 7, level: 6, blCompatibilityID: 6, hasEnhancementLayer: true).summary,
                       "Dolby Vision 7.6: playing the HDR10 base layer, enhancement layer ignored")
    }

    func testGuessingRules() {
        // GBR on 4:2:0 is impossible (a muxer bug seen with x265 through FFmpeg): guess the matrix instead.
        var c = SignalColor(primaries: 9, transfer: 16, matrix: 0, primariesTagged: true, transferTagged: true, matrixTagged: true)
        c.resolve(height: 2160, chroma: .c420)
        XCTAssertEqual(c.matrix, 9)
        XCTAssertFalse(c.matrixTagged)
        var rgb = SignalColor(primaries: 1, transfer: 13, matrix: 0, primariesTagged: true, transferTagged: true, matrixTagged: true)
        rgb.resolve(height: 1080, chroma: .c444)
        XCTAssertEqual(rgb.matrix, 0, "GBR stays on 4:4:4")
        var hd = SignalColor()
        hd.resolve(height: 1080, chroma: .c420)
        XCTAssertEqual([hd.primaries, hd.transfer, hd.matrix], [1, 1, 1])
        XCTAssertFalse(hd.fullRange)
        XCTAssertEqual(hd.chromaLocation, .left)
        var sd = SignalColor()
        sd.resolve(height: 480, chroma: .c420)
        XCTAssertEqual(sd.matrix, 6)
        var hlg = SignalColor(transfer: 18, transferTagged: true)
        hlg.resolve(height: 1080, chroma: .c420)
        XCTAssertEqual([hlg.primaries, hlg.matrix], [9, 9], "untagged HLG is BT.2020")
    }

    func testFFmpegDecoderListAndPixelFormats() {
        let text = """
        Decoders:
         V..... = Video
         ------
         V....D hevc                 HEVC (High Efficiency Video Coding)
         V..... libdav1d             dav1d AV1 decoder by VideoLAN (codec av1)
         A....D aac                  AAC (Advanced Audio Coding)
        """
        XCTAssertEqual(DecoderCapabilities.parseDecoders(text), ["hevc", "libdav1d", "aac"])
        func pix(_ p: String, _ bits: Int = 8) -> String { DecoderSelector.softwarePixelFormat(VideoInfo(bitDepth: bits, pixelFormat: p)) }
        XCTAssertEqual(pix("yuv420p10le", 10), "yuv420p10le")
        XCTAssertEqual(pix("yuva420p"), "yuv420p")
        XCTAssertEqual(pix("rgb24"), "gbrp")
        XCTAssertEqual(pix("gbrp10le", 10), "gbrp10le")
        XCTAssertEqual(pix("yuvj420p"), "yuvj420p")
        XCTAssertTrue(FrameLayout.ffmpeg("yuvj420p", width: 16, height: 16)!.forcesFullRange)
        XCTAssertEqual(FrameLayout.ffmpeg("p010le", width: 1920, height: 1080)!.frameBytes, 1920 * 1080 * 3)
        XCTAssertEqual(FrameLayout.ffmpeg("yuv420p10le", width: 3840, height: 2160)!.frameBytes, 24_883_200)
        XCTAssertEqual(FrameLayout.planar(width: 1920, height: 1080, chroma: .c420, sampleBytes: 2, bits: 10).frameBytes, 6_220_800,
                       "avmdec's 16-bit 1080p frame")
        XCTAssertEqual(PlayerBackends.queueCapacity(frameBytes: 24_883_200, budgetMB: 1414), 59)
    }
}
