import XCTest
@testable import Lumora

final class DolbyVisionTests: XCTestCase {
    private func dvSource(profile: Int = 8) -> SourceDescriptor {
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/dv.mkv"), kind: .ffmpeg)
        d.isDolbyVision = true; d.dvProfile = profile
        return d
    }

    func testKeepsOriginalOnlyWhenNothingIsRegraded() {
        XCTAssertEqual(DolbyVisionRetimer.decide(source: dvSource(), look: .original, passthrough: true, codec: .hevc12, delivery: .dolbyVision81), .retimeOriginal)
        if case .generateNew = DolbyVisionRetimer.decide(source: dvSource(), look: .punchy, passthrough: false, codec: .hevc12, delivery: .dolbyVision81) {} else { XCTFail() }
        if case .generateNew = DolbyVisionRetimer.decide(source: dvSource(), look: .original, passthrough: true, codec: .av1, delivery: .dolbyVision81) {} else { XCTFail() }
        if case .generateNew = DolbyVisionRetimer.decide(source: dvSource(profile: 5), look: .original, passthrough: true, codec: .hevc, delivery: .dolbyVision81) {} else { XCTFail() }
    }

    func testMappingUsesNearestOriginal() {
        let plan = [PlannedFrame(a: 0, b: 0, t: 0, kind: .original), PlannedFrame(a: 0, b: 1, t: 0.4, kind: .generated),
                    PlannedFrame(a: 0, b: 1, t: 0.8, kind: .generated), PlannedFrame(a: 1, b: 1, t: 0, kind: .original)]
        XCTAssertEqual(DolbyVisionRetimer.sourceFrames(for: plan), [0, 0, 1, 1])
    }

    func testBrightnessLimiterGuardOnlyLowersBrightScenes() {
        let scenes = [SceneStats(start: 0, end: 10, keyStops: 2.5, p005: -2, p50: 2, p995: 5, skinFraction: 0, avgChroma: 0),
                      SceneStats(start: 10, end: 20, keyStops: -3, p005: -9, p50: -3, p995: 2, skinFraction: 0, avgChroma: 0)]
        let a = AnalysisResult(frameCount: 20, scenes: scenes, transitions: [], cutFrames: [0, 10], duplicateFrames: [],
                               globalKey: 0, globalP005: -9, globalP995: 5, skinFraction: 0, avgChroma: 0, globalHistogram: [])
        let p = PresetCandidate(name: "n", look: .natural, color: SourceColor(name: "c", transfer: .pq, gamut: .rec2020, legalToFull: false, confidence: 1),
                                params: Look.natural.params, sceneExposures: [0, 0], reason: "")
        let oled = DisplayProfile.devices.first { $0.name == "OLED TV" }!
        let adapted = AutoPresetEngine.adapt(p, for: oled, analysis: a, pop: false)
        XCTAssertLessThan(adapted.sceneExposures[0], 0)
        XCTAssertEqual(adapted.sceneExposures[1], 0)
    }
}
