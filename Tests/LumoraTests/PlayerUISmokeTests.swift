import XCTest
import SwiftUI
import AppKit
@testable import Lumora

/// The Player window offscreen (never ordered front), in snapshot mode: open a clip, drive the transport, check
/// the state and the info overlay, render one snapshot.
@MainActor
final class PlayerUISmokeTests: XCTestCase {
    override func setUp() async throws {
        try TestHardware.requireGPU()
        PlayerMetalView.snapshotMode = true
    }

    override func tearDown() async throws { PlayerMetalView.snapshotMode = false }

    func spin(_ s: Double = 0.02) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    func waitFor(_ what: String, timeout: Double = 15, _ cond: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out: \(what)"); return }
            spin()
        }
    }

    func testPlayerWindowTransportAndOverlay() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let url = try PlayerFixtures.hdr10Clip("mkv")
        let engine = PlayerEngine()
        var bound: URL? = url
        let view = PlayerWindow(url: Binding(get: { bound }, set: { bound = $0 }), engine: engine)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }

        try waitFor("open") { engine.phase != .opening && engine.info != nil }
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(engine.info?.video.color.transfer, 16)
        XCTAssertTrue(engine.isHDR)
        try waitFor("first frame") { _ = engine.frameForDisplay(targetHost: CACurrentMediaTime()); return engine.currentFrame != nil }

        engine.play()
        XCTAssertTrue(engine.isPlaying)
        let t0 = CACurrentMediaTime()
        for k in 1...6 { _ = engine.frameForDisplay(targetHost: t0 + Double(k) / 24); spin(1.0 / 24) }
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        let here = engine.currentIndex
        engine.step(1)
        try waitFor("step") { _ = engine.frameForDisplay(targetHost: CACurrentMediaTime()); return engine.currentIndex == here + 1 }
        engine.seek(toFrame: 9)
        try waitFor("seek") { _ = engine.frameForDisplay(targetHost: CACurrentMediaTime()); return engine.currentFrame?.index == 9 }
        engine.step(-1)
        try waitFor("step back") { _ = engine.frameForDisplay(targetHost: CACurrentMediaTime()); return engine.currentFrame?.index == 8 }
        engine.loop = true
        engine.jkl("l")
        XCTAssertTrue(engine.isPlaying)
        engine.jkl("l")
        XCTAssertEqual(engine.rate, 2, "L again doubles the speed")
        engine.jkl("k")
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.rate, 1)
        engine.showInfo = true
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); spin(0.05) }

        // The overlay shows the decoder, the signal and the HDR metadata (the rows the overlay draws).
        let rows = InfoOverlay.rows(engine)
        let text = rows.map { "\($0.0) \($0.1)" }.joined(separator: "\n")
        for needle in ["Decoder", "PQ (SMPTE ST 2084)", "BT.2020", "MaxCLL 800", "MDCV 1000", "limited", "Tone mapping", "VideoToolbox"] {
            XCTAssertTrue(text.contains(needle), "overlay lacks \(needle):\n\(text)")
        }
        XCTAssertFalse(text.contains(NSHomeDirectory()), "no home paths in the UI")
        XCTAssertNotNil(engine.toneMap)

        // One offscreen snapshot with the picture in it (snapshot mode draws the frame for an SDR screen).
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var lit = 0
        for y in stride(from: 60, to: Int(rep.pixelsHigh) - 120, by: 20) {
            for x in stride(from: 600, to: Int(rep.pixelsWide) - 20, by: 20) {
                if let c = rep.colorAt(x: x, y: y), c.redComponent + c.greenComponent + c.blueComponent > 0.3 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 20, "the snapshot shows the picture")

        engine.stop()
        XCTAssertTrue(PlayerFixtures.noChildrenLeft())
    }
}
