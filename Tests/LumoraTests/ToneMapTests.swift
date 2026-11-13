import XCTest
import simd
@testable import Lumora

/// BT.2390 EETF on the GPU against the double-precision reference, its shape, HLG system gamma, the SDR
/// fallback and headroom smoothing.
final class ToneMapTests: XCTestCase {
    /// A 1-row 16-bit full-range 4:4:4 frame of neutral PQ code values (a ramp).
    func pqRamp(_ codes: [Int], maxCLL: Double) -> (PlayerFrame, MediaInfo) {
        let l = FrameLayout.planar(width: codes.count, height: 1, chroma: .c444, sampleBytes: 2, bits: 16)
        let pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: 2)
        let b = pool.acquire()!
        for (x, c) in codes.enumerated() {
            b.bytes.storeBytes(of: UInt16(c), toByteOffset: l.offsets[0] + 2 * x, as: UInt16.self)
            b.bytes.storeBytes(of: UInt16(32768), toByteOffset: l.offsets[1] + 2 * x, as: UInt16.self)
            b.bytes.storeBytes(of: UInt16(32768), toByteOffset: l.offsets[2] + 2 * x, as: UInt16.self)
        }
        let color = SignalColor(primaries: 9, transfer: 16, matrix: 9, fullRange: true, chromaLocation: .center,
                                primariesTagged: true, transferTagged: true, matrixTagged: true, rangeTagged: true)
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/ramp.y4m"), container: "y4m")
        i.video.width = codes.count; i.video.height = 1; i.video.color = color
        i.video.hdr = HDRStatic(mdcvMaxNits: 10000, maxCLL: maxCLL)
        return (PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(b), color: color), i)
    }

    func testGPUMatchesTheReferenceOverAPQRamp() throws {
        try TestHardware.requireGPU()
        let renderer = PlayerRenderer()
        let codes = (0..<4096).map { Int((Double($0) / 4095 * 65535).rounded()) }
        for (srcPeak, headroom) in [(4000.0, 6.0), (1000.0, 2.0), (10000.0, 16.0), (1000.0, 1.0)] {
            let (f, i) = pqRamp(codes, maxCLL: srcPeak)
            let (u, summary) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: headroom), settings: PlayerSettings(),
                                                       interpret: .auto, viewport: SIMD4(0, 0, Float(codes.count), 1))
            XCTAssertEqual(u.toneMap, 1)
            XCTAssertTrue(summary.mapping.contains("BT.2390"))
            let px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))
            let e = PlayerRenderer.eetf(sourcePeak: srcPeak, displayPeak: headroom * 100)
            var worst = 0.0
            for (x, c) in codes.enumerated() {
                let nits = PlayerRenderer.pqInverse(Double(c) / 65535)
                let want = PlayerRenderer.applyEETF(nits, e)
                let got = Double(px[x].x) * 100
                worst = max(worst, abs(PlayerRenderer.pq(got) - PlayerRenderer.pq(want)))
                XCTAssertEqual(Double(px[x].x), Double(px[x].y), accuracy: 1e-6, "neutral stays neutral")
            }
            XCTAssertLessThan(worst, 1e-4, "max PQ error, \(Int(srcPeak)) nits to \(Int(headroom * 100))")
        }
    }

    func testCurveShape() {
        for (src, dst) in [(1000.0, 400.0), (4000.0, 1000.0), (10000.0, 600.0), (1000.0, 100.0)] {
            let e = PlayerRenderer.eetf(sourcePeak: src, displayPeak: dst)
            XCTAssertEqual(PlayerRenderer.applyEETF(0, e), 0, accuracy: 1e-9, "black stays black")
            XCTAssertEqual(PlayerRenderer.applyEETF(src, e), dst, accuracy: dst * 1e-6, "the content peak lands on the display peak")
            var last = -1.0
            for k in 0...2000 {
                let v = PlayerRenderer.applyEETF(src * Double(k) / 2000, e)
                XCTAssertGreaterThanOrEqual(v, last - 1e-9, "monotonic")
                XCTAssertLessThanOrEqual(v, dst * (1 + 1e-9))
                last = v
            }
            // Below the knee the curve is the identity.
            let knee = PlayerRenderer.pqInverse(e.ks * (e.lw - e.lb) + e.lb)
            XCTAssertEqual(PlayerRenderer.applyEETF(knee * 0.5, e), knee * 0.5, accuracy: knee * 1e-9)
        }
    }

    func testNoToneMappingWhenTheDisplayReachesTheContentPeak() {
        let (f, i) = pqRamp([0, 30000, 65535], maxCLL: 1000)
        let (u, s) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 16), settings: PlayerSettings(),
                                             interpret: .auto, viewport: SIMD4(0, 0, 3, 1))
        XCTAssertEqual(u.toneMap, 0)
        XCTAssertEqual(u.srcPeak, 1000, "clip at the content peak")
        XCTAssertTrue(s.mapping.hasPrefix("none"))
    }

    func testHLGSystemGamma() {
        XCTAssertEqual(PlayerRenderer.hlgGamma(1000), 1.2, accuracy: 1e-9)
        XCTAssertEqual(PlayerRenderer.hlgGamma(400), 1.033, accuracy: 1e-3)
        XCTAssertEqual(PlayerRenderer.hlgGamma(2000), 1.326, accuracy: 1e-3)
        // The OOTF follows the display peak, clamped to 400-2000 nits.
        var f = pqRamp([0], maxCLL: 1000).0
        var c = f.color; c.transfer = 18; c.fullRange = false
        f = PlayerFrame(index: 0, pts: 0, layout: f.layout, planes: f.planes, color: c)
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/h.mov"), container: "mov"); i.video.color = c
        for (headroom, lw) in [(16.0, 1600.0), (2.0, 400.0), (40.0, 2000.0)] {
            let (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: headroom), settings: PlayerSettings(),
                                                 interpret: .auto, viewport: SIMD4(0, 0, 1, 1))
            XCTAssertEqual(Double(u.hlgLw), lw, accuracy: 1e-3)
            XCTAssertEqual(Double(u.hlgGamma), PlayerRenderer.hlgGamma(lw), accuracy: 1e-6)
        }
    }

    func testSDRScreenFallback() throws {
        try TestHardware.requireGPU()
        let renderer = PlayerRenderer()
        // HDR on a screen with no headroom: nothing above SDR white.
        let codes = (0..<1024).map { $0 * 64 }
        let (f, i) = pqRamp(codes, maxCLL: 10000)
        let (u, _) = PlayerRenderer.uniforms(frame: f, info: i, display: DisplayState(headroom: 1), settings: PlayerSettings(),
                                             interpret: .auto, viewport: SIMD4(0, 0, Float(codes.count), 1))
        let px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))
        XCTAssertLessThanOrEqual(px.map { max($0.x, $0.y, $0.z) }.max() ?? 0, 1.0001)
        // SDR white (BT.1886 code 940) shows as exactly 1.0.
        let l = FrameLayout.planar(width: 2, height: 2, chroma: .c444, sampleBytes: 2, bits: 10)
        let pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: 1)
        let b = pool.acquire()!
        for p in 0..<3 { for k in 0..<4 { b.bytes.storeBytes(of: UInt16(p == 0 ? 940 : 512), toByteOffset: l.offsets[p] + 2 * k, as: UInt16.self) } }
        var sdr = SignalColor(); sdr.resolve(height: 1080, chroma: .c444)
        let sf = PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(b), color: sdr)
        var si = MediaInfo(url: URL(fileURLWithPath: "/tmp/s.mov"), container: "mov"); si.video.color = sdr
        for refWhite: Float in [100, 203] {
            var s = PlayerSettings(); s.referenceWhite = refWhite
            let (su, _) = PlayerRenderer.uniforms(frame: sf, info: si, display: DisplayState(headroom: 1), settings: s, interpret: .auto,
                                                  viewport: SIMD4(0, 0, 2, 2))
            let out = PlayerRenderer.readBack(try renderer.render(frame: sf, uniforms: su))
            XCTAssertEqual(out[0].x, 1, accuracy: 1e-4, "SDR white at \(refWhite)-nit reference")
        }
    }

    func testHeadroomSmoothingStepResponse() {
        var h = HeadroomFilter(initial: 1)
        var t = 0.0
        while t < 0.3 - 1e-9 { _ = h.update(4, dt: 0.005); t += 0.005 }
        XCTAssertEqual(h.value, 1 + 3 * (1 - exp(-1)), accuracy: 0.01, "one time constant")
        for _ in 0..<400 { _ = h.update(4, dt: 0.005) }
        XCTAssertEqual(h.value, 4, accuracy: 0.002, "settled after 2.3 s")
        XCTAssertEqual(h.update(0.5, dt: 10), 1, accuracy: 1e-6, "never below SDR")
    }
}
