import XCTest
@testable import Lumora

final class QualityTests: XCTestCase {
    func testVMAFLogParsing() throws {
        let json = """
        {"frames":[{"frameNum":0,"metrics":{"vmaf":96.0}},{"frameNum":1,"metrics":{"vmaf":94.0}},
                   {"frameNum":2,"metrics":{"vmaf":90.0}},{"frameNum":3,"metrics":{"vmaf":98.0}}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vmaf-test.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let r = try VMAFRunner.parse(url)
        XCTAssertEqual(r.frames.count, 4)
        XCTAssertEqual(r.mean, 94.5, accuracy: 1e-9)
        XCTAssertEqual(r.min, 90, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(r.harmonic, r.mean)
    }

    func testEveryContentKindHasATuning() {
        for k in ContentKind.allCases {
            let t = ContentTuning.preset(k)
            XCTAssertEqual(t.kind, k)
            XCTAssertFalse(t.interpolationModels.isEmpty)
            XCTAssert((85...99).contains(t.targetVMAF))
        }
    }

    func testLevelRangesAreOrdered() {
        for c in Codec.allCases {
            let r = TargetQualityEncoder.levelRange(c)
            XCTAssertLessThan(r.low, r.high)
            XCTAssert((r.low...r.high).contains(r.start))
        }
    }

    func testPlanarDownconversionHeader() {
        XCTAssertEqual(PlanarFrame.y4mHeader420p10(width: 3840, height: 2160, fps: (24000, 1001)),
                       "YUV4MPEG2 W3840 H2160 F24000:1001 Ip A1:1 C420p10 XYSCSS=420P10\n")
    }
}
