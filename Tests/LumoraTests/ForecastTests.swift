import XCTest
@testable import Lumora

final class ForecastTests: XCTestCase {
    private let source = StreamSizes(total: 60_000_000_000, video: 55_000_000_000, other: 5_000_000_000)

    private func quick(_ codec: Codec, _ kind: ContentKind, grain: Bool = false) -> SizeForecast {
        SizeForecaster.quick(width: 3840, height: 2160, outputFrames: 172_800, outputFps: 24, codec: codec, kind: kind,
                             grainSynthesis: grain, target: QualityTarget(), quality: 0.8, bitDepth: 10, chroma: .c420,
                             source: source, carryOther: true, key: "t")
    }

    func testRangeIsOrderedAndIncludesAudio() {
        let f = quick(.av1, .realLife)
        XCTAssertLessThan(f.low, f.mid)
        XCTAssertLessThan(f.mid, f.high)
        XCTAssertEqual(f.otherBytes, 5_000_000_000)
        XCTAssertGreaterThan(f.mid, f.otherBytes)
    }

    func testTypicalTwoHourRipLandsInTheExpectedBallpark() {
        let gb = Double(quick(.av1, .realLife).mid) / 1e9
        XCTAssert((10...25).contains(gb), "2 h 4K film in AV1 should forecast ~10–25 GB incl. audio, got \(gb)")
    }

    func testCodecAndContentOrdering() {
        XCTAssertLessThan(quick(.av1, .realLife).videoMid, quick(.hevc12, .realLife).videoMid)
        XCTAssertLessThan(quick(.hevc12, .realLife).videoMid, quick(.hevc, .realLife).videoMid)
        XCTAssertLessThan(quick(.av1, .anime).videoMid, quick(.av1, .realLife).videoMid)
        XCTAssertLessThan(quick(.av1, .realLifeHeavyGrain, grain: true).videoMid, quick(.av1, .realLifeHeavyGrain).videoMid)
    }

    func testSampledExtrapolationScalesWithFrames() {
        let scenes = [SceneStats(start: 0, end: 100, keyStops: -1, p005: -6, p50: -1, p995: 3, skinFraction: 0.1, avgChroma: 0.05),
                      SceneStats(start: 100, end: 200, keyStops: -3, p005: -8, p50: -3, p995: 1, skinFraction: 0, avgChroma: 0.02)]
        let a = AnalysisResult(frameCount: 200, scenes: scenes, transitions: [], cutFrames: [0, 100], duplicateFrames: [],
                               globalKey: -2, globalP005: -7, globalP995: 3, skinFraction: 0.05, avgChroma: 0.03, globalHistogram: [])
        let samples = [SizeForecaster.Sample(scene: 0, bytesPerFrame: 100_000), SizeForecaster.Sample(scene: 1, bytesPerFrame: 50_000)]
        let f = SizeForecaster.fromSamples(samples, analysis: a, sceneOutputFrames: [0: 100, 1: 100], chunkFrames: 48, sampleFrames: 48,
                                           codec: .av1, kind: .realLife, source: source, carryOther: false, key: "s")
        XCTAssertEqual(Double(f.videoMid), 15_000_000, accuracy: 3_000_000)
        XCTAssertEqual(f.method, .sampled)
    }
}
