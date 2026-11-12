import XCTest
@testable import Lumora

final class PipelineTests: XCTestCase {
    func testChannelKeepsOrderAndFinishes() async throws {
        let ch = BoundedChannel<Int>(capacity: 2)
        let producer = Task { for i in 0..<50 { await ch.send(i) }; await ch.finish() }
        var got: [Int] = []
        while let v = try await ch.receive() { got.append(v) }
        _ = await producer.value
        XCTAssertEqual(got, Array(0..<50))
    }

    func testChannelPropagatesFailure() async {
        let ch = BoundedChannel<Int>(capacity: 2)
        await ch.fail(LumoraError.canceled)
        do { _ = try await ch.receive(); XCTFail("expected error") } catch {}
    }

    func testToneMatchIdentity() {
        let h = (0..<256).map { _ in Double.random(in: 1...100) }
        let curve = InterpolationEvaluator.cdfMatch(h, h)
        for (i, v) in curve.enumerated() { XCTAssertEqual(v, Float(i) / 255, accuracy: 2.0 / 255) }
    }

    func testDuplicateAwarePlan() {
        let a = AnalysisResult(frameCount: 20, scenes: [SceneStats(start: 0, end: 20, keyStops: 0, p005: 0, p50: 0, p995: 0,
                                                                   skinFraction: 0, avgChroma: 0)],
                               transitions: [], cutFrames: [0], duplicateFrames: Set(stride(from: 1, to: 20, by: 2)),
                               globalKey: 0, globalP005: 0, globalP995: 0, skinFraction: 0, avgChroma: 0, globalHistogram: [])
        var s = InterpolationSettings()
        s.mode = .multiply(2)
        let (plan, _) = InterpolationPlanner.plan(sourceFrames: 20, sourceRate: (24, 1), settings: s, analysis: a)
        // Generated frames interpolate between real drawings (even frames), never onto a repeated one.
        XCTAssertTrue(plan.filter { $0.kind == .generated }.allSatisfy { $0.a % 2 == 0 && $0.b % 2 == 0 })
    }
}
