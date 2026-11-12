import XCTest
@testable import Lumora

final class RecommenderTests: XCTestCase {
    private func film(fps: Int = 24, transfer: Transfer = .pq) -> (SourceDescriptor, SourceColor, AnalysisResult) {
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/film.mkv"), kind: .ffmpeg)
        d.width = 3840; d.height = 2160; d.fpsNum = fps; d.fpsDen = 1; d.frameCount = fps * 600
        let c = SourceColor(name: "HDR10", transfer: transfer, gamut: .rec2020, legalToFull: false, confidence: 1)
        let a = AnalysisResult(frameCount: d.frameCount,
                               scenes: [SceneStats(start: 0, end: d.frameCount, keyStops: -1, p005: -7, p50: -1, p995: 4, skinFraction: 0.1, avgChroma: 0.05)],
                               transitions: [], cutFrames: [0], duplicateFrames: [], globalKey: -1, globalP005: -7, globalP995: 4,
                               skinFraction: 0.1, avgChroma: 0.05, globalHistogram: [])
        return (d, c, a)
    }

    func testFilmsKeepTheirFrameRateUnlessAskedForSmoothness() {
        let (d, c, a) = film()
        let tv = Recommender.recommend(goal: .watchOnTV, playsAV1: true, descriptor: d, color: c, analysis: a,
                                       profile: nil, report: nil, sizes: nil, detectedCrop: false)
        XCTAssertEqual(tv.interpolation, .off)
        let smooth = Recommender.recommend(goal: .smoother, playsAV1: true, descriptor: d, color: c, analysis: a,
                                           profile: nil, report: nil, sizes: nil, detectedCrop: false)
        XCTAssertNotEqual(smooth.interpolation, .off)
        XCTAssertEqual(smooth.intelligence, .perScene)
    }

    func testArchiveUsesAV1AndImperceptible() {
        let (d, c, a) = film()
        let r = Recommender.recommend(goal: .archive, playsAV1: false, descriptor: d, color: c, analysis: a,
                                      profile: nil, report: nil, sizes: nil, detectedCrop: true)
        XCTAssertEqual(r.codec, .av1)
        XCTAssertEqual(r.profileName, "Imperceptible")
        XCTAssertTrue(r.removeBlackBars)
        XCTAssertEqual(r.look, .original)
    }

    func testAlignedFramesFor24To60() {
        let plan = ExternalRepairPlan(flagged: [], originalFps: 24, interpolatedFps: 60, offsetSeconds: 0)
        XCTAssertTrue(plan.isOriginal(0))
        XCTAssertTrue(plan.isOriginal(5))
        XCTAssertFalse(plan.isOriginal(1))
        XCTAssertFalse(plan.isOriginal(3))
    }

    func testAV1LadderReachesIntoLibaomOnlyAtTheSlowEnd() {
        let r = EncodeRecipes.recipe(codec: .av1, kind: .realLife)
        let aom = r.rungs.filter { $0.encoderKey == "aomenc" }
        XCTAssertFalse(aom.isEmpty)
        let fastestSVT = r.rungs.first { $0.encoderKey == nil }!
        XCTAssert(aom.allSatisfy { $0.seedSpeed < 0.03 && $0.seedSpeed < fastestSVT.seedSpeed })
    }
}
