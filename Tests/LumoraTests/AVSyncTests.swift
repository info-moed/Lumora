import XCTest
import AVFoundation
@testable import Lumora

/// Audio and video stay together on the audio clock. Audio runs through AVAudioEngine's offline manual-rendering
/// mode (nothing reaches the speakers); the test pulls audio and asks for the frame due at that audio time, the way
/// the display link does.
@MainActor
final class AVSyncTests: XCTestCase {
    /// 4 s at 24 fps: white flash frames at 1 s (frame 24) and 3 s (frame 72), 1 kHz clicks at the same times.
    static func flashClip(_ container: String) throws -> URL {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let audio = container == "mp4" ? ["-c:a", "aac", "-b:a", "128k"] : ["-c:a", "libopus", "-b:a", "96k"]
        return try PlayerFixtures.cached("flash.\(container)") {
            try PlayerFixtures.ffmpeg(["-f", "lavfi", "-i", "color=black:s=320x180:r=24:d=4,drawbox=enable='eq(n\\,24)+eq(n\\,72)':c=white:t=fill",
                                       "-f", "lavfi", "-i", "aevalsrc='if(between(t\\,1\\,1.02)+between(t\\,3\\,3.02)\\,0.9*sin(2*PI*1000*t)\\,0)':s=48000:d=4",
                                       "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-g", "12", "-pix_fmt", "yuv420p"] + audio
                                      + ["-f", container == "mp4" ? "mp4" : "matroska", $0.path])
        }
    }

    func spin(_ seconds: Double = 0.02) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    func waitFor(_ what: String, timeout: Double = 15, _ cond: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw XCTSkip("timed out") }
            spin()
        }
    }

    /// Plays from `startFrame` and returns (audio time of the click onset, pts of the frame shown at that moment).
    func clickVersusFrame(_ e: PlayerEngine, from startFrame: Int, clickNear: Double) throws -> (Double, Double) {
        e.seek(toFrame: startFrame)
        try waitFor("seek to \(startFrame) (\(e.phase), shown \(e.currentFrame?.index ?? -1), queue \(e.queueDepthForTests ?? -1))") {
            _ = e.frameForDisplay(targetHost: 0); return e.currentFrame?.index == startFrame
        }
        e.play()
        try waitFor("audio") { e.audioActive }
        let out = try XCTUnwrap(e.audioOutputForTests)
        let base = Double(startFrame) / e.fps
        var rendered = 0
        var clickAt: Double?
        var shownAtClick: Double?
        while rendered < 48_000 * 3 {
            let buf = try out.renderOffline(frames: 480)
            let n = Int(buf.frameLength)
            if clickAt == nil {
                let l = buf.floatChannelData![0]
                if let k = (0..<n).first(where: { abs(l[$0]) > 0.3 }) {
                    clickAt = base + Double(rendered + k) / 48_000
                }
            }
            rendered += n
            // What the display link would show now.
            let f = e.frameForDisplay(targetHost: 0)
            if clickAt != nil && shownAtClick == nil, let f { shownAtClick = f.pts }
            if clickAt != nil && shownAtClick != nil { break }
            spin(0.001)
            if n == 0 { break }
        }
        e.pause()
        let c = try XCTUnwrap(clickAt, "no click heard")
        XCTAssertEqual(c, clickNear, accuracy: 0.02, "the audio lands on the right sample after seeking")
        return (c, try XCTUnwrap(shownAtClick))
    }

    func testFlashAndClickStayWithinAFrame() throws {
        for container in ["mp4", "mkv"] {
            let url = try Self.flashClip(container)
            let e = PlayerEngine()
            defer { e.stop() }
            e.manualAudio = true
            e.open(url)
            XCTAssertTrue(e.waitUntilOpened())
            XCTAssertNil(e.errorMessage, container)
            XCTAssertEqual(e.info?.audio.count, 1)
            for (start, click) in [(12, 1.0), (50, 3.0)] {
                let (heard, shown) = try clickVersusFrame(e, from: start, clickNear: click)
                XCTAssertEqual(shown, heard, accuracy: 1.0 / 24 + 0.02, "\(container): frame on screen when the click is heard (from \(start))")
            }
            e.stop()
            XCTAssertTrue(PlayerFixtures.noChildrenLeft(), "no decoder left running")
        }
    }

    /// A raw stream has no audio: the host clock paces it, one media second per host second, nothing dropped.
    func testSilentStreamUsesTheHostClock() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let url = try PlayerFixtures.indexClip("y4m")
        let e = PlayerEngine()
        defer { e.stop() }
        e.open(url)
        XCTAssertTrue(e.waitUntilOpened())
        try waitFor("first frame") { e.frameForDisplay(targetHost: CACurrentMediaTime()) != nil }
        e.play()
        XCTAssertFalse(e.audioActive)
        let h = CACurrentMediaTime()
        XCTAssertEqual(e.clockTime(atHost: h + 1) - e.clockTime(atHost: h), 1, accuracy: 1e-9)
        // Present a frame per 1/24 s of simulated display time.
        var seen: [Int] = []
        let t0 = CACurrentMediaTime()
        for k in 1...20 {
            try waitFor("frame \(k)") { (e.queueDepthForTests ?? 0) > 0 }
            if let f = e.frameForDisplay(targetHost: t0 + Double(k) / 24 + 0.002), seen.last != f.index { seen.append(f.index) }
        }
        e.stop()
        XCTAssertEqual(seen.count, 20, "a new frame at every 1/24 s: \(seen)")
        XCTAssertEqual(seen, Array((seen.first ?? 0)..<((seen.first ?? 0) + seen.count)), "consecutive, none dropped")
    }
}
