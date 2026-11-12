import XCTest
import simd
@testable import Lumora

/// Pins every curve and matrix to published reference values.
final class ColorMathTests: XCTestCase {
    func testPQReferencePoints() {
        XCTAssertEqual(TransferMath.nitsToPQ(100), 0.5081, accuracy: 0.0005)     // SDR reference white
        XCTAssertEqual(TransferMath.nitsToPQ(1000), 0.7518, accuracy: 0.0005)
        XCTAssertEqual(TransferMath.nitsToPQ(10000), 1.0, accuracy: 1e-5)
        for n: Float in [0.01, 1, 18, 203, 600, 4000] {
            XCTAssertEqual(TransferMath.pqToNits(TransferMath.nitsToPQ(n)), n, accuracy: n * 0.002)
        }
    }

    func testHLG() {
        XCTAssertEqual(TransferMath.hlgOETF(1.0 / 12), 0.5, accuracy: 1e-5)
        XCTAssertEqual(TransferMath.hlgOETF(1.0), 1.0, accuracy: 1e-4)
        for e: Float in [0.01, 0.05, 0.3, 0.9] {
            XCTAssertEqual(TransferMath.hlgInverse(TransferMath.hlgOETF(e)), e, accuracy: 1e-4)
        }
    }

    /// 18% gray code values from each manufacturer's published curve.
    func testCameraLogGrey() {
        XCTAssertEqual(TransferMath.sLog3Encode(0.18), 420.0 / 1023, accuracy: 1e-4)
        XCTAssertEqual(TransferMath.logC3Encode(0.18), 0.3910, accuracy: 2e-4)
        XCTAssertEqual(TransferMath.logC4Encode(0.18), 0.2784, accuracy: 3e-4)
        XCTAssertEqual(TransferMath.vLogEncode(0.18), 0.4233, accuracy: 2e-4)
        XCTAssertEqual(TransferMath.appleLogEncode(0.18), 0.4883, accuracy: 3e-4)
    }

    func testCameraLogRoundTrips() {
        for x: Float in [0.001, 0.02, 0.18, 0.9, 4, 16] {
            XCTAssertEqual(TransferMath.sLog3Decode(TransferMath.sLog3Encode(x)), x, accuracy: x * 1e-3 + 1e-5)
            XCTAssertEqual(TransferMath.logC3Decode(TransferMath.logC3Encode(x)), x, accuracy: x * 1e-3 + 1e-5)
            XCTAssertEqual(TransferMath.logC4Decode(TransferMath.logC4Encode(x)), x, accuracy: x * 1e-3 + 1e-5)
            XCTAssertEqual(TransferMath.vLogDecode(TransferMath.vLogEncode(x)), x, accuracy: x * 1e-3 + 1e-5)
            XCTAssertEqual(TransferMath.appleLogDecode(TransferMath.appleLogEncode(x)), x, accuracy: x * 1e-3 + 1e-5)
        }
    }

    func testRec2020Luma() {
        let l = ColorScience.luma(.rec2020)
        XCTAssertEqual(l.x, 0.2627, accuracy: 2e-4)
        XCTAssertEqual(l.y, 0.6780, accuracy: 2e-4)
        XCTAssertEqual(l.z, 0.0593, accuracy: 2e-4)
    }

    /// ITU-R BT.2087 Rec.709 -> Rec.2020 conversion matrix.
    func testRec709To2020() {
        let m = ColorScience.matrix(from: .rec709, to: .rec2020)
        let row0 = SIMD3<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x)
        let row1 = SIMD3<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y)
        XCTAssertEqual(row0.x, 0.6274, accuracy: 3e-4); XCTAssertEqual(row0.y, 0.3293, accuracy: 3e-4)
        XCTAssertEqual(row0.z, 0.0433, accuracy: 3e-4)
        XCTAssertEqual(row1.x, 0.0691, accuracy: 3e-4); XCTAssertEqual(row1.y, 0.9195, accuracy: 3e-4)
        // White stays white.
        let w = m * SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(w.x, 1, accuracy: 1e-4); XCTAssertEqual(w.y, 1, accuracy: 1e-4); XCTAssertEqual(w.z, 1, accuracy: 1e-4)
    }

    func testInterpolationPlanNeverCrossesCuts() {
        var a = AnalysisResult(frameCount: 100, scenes: [], transitions: [], cutFrames: [0, 50], duplicateFrames: [],
                               globalKey: 0, globalP005: 0, globalP995: 0, skinFraction: 0, avgChroma: 0,
                               globalHistogram: [])
        a.scenes = [SceneStats(start: 0, end: 50, keyStops: 0, p005: 0, p50: 0, p995: 0, skinFraction: 0, avgChroma: 0),
                    SceneStats(start: 50, end: 100, keyStops: 0, p005: 0, p50: 0, p995: 0, skinFraction: 0, avgChroma: 0)]
        var s = InterpolationSettings()
        s.mode = .multiply(2)
        let (plan, rate) = InterpolationPlanner.plan(sourceFrames: 100, sourceRate: (24, 1), settings: s, analysis: a)
        XCTAssertEqual(rate.num, 48)
        XCTAssertFalse(plan.contains { $0.kind == .generated && $0.a < 50 && $0.b >= 50 })
    }

    func testHDR10MetadataEncoding() {
        let s = HDRMetadata.Static(peakNits: 1000, maxCLL: 950, maxFALL: 400)
        XCTAssertEqual(HDRMetadata.vtMasteringDisplay(s).count, 24)
        XCTAssertEqual(Array(HDRMetadata.vtContentLightLevel(s)), [0x03, 0xB6, 0x01, 0x90])
    }
}
