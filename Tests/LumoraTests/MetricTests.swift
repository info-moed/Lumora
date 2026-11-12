import XCTest
@testable import Lumora

final class MetricTests: XCTestCase {
    func testDirectionOfThresholds() {
        XCTAssertTrue(MetricRule(metric: .cvvdp, role: .mustPass, threshold: 9.6).passes(9.7))
        XCTAssertFalse(MetricRule(metric: .cvvdp, role: .mustPass, threshold: 9.6).passes(9.5))
        XCTAssertTrue(MetricRule(metric: .cambi, role: .mustPass, threshold: 1.0).passes(0.4))   // lower is better
        XCTAssertFalse(MetricRule(metric: .ciede, role: .mustPass, threshold: 1.5).passes(2.1))
    }

    func testPoolingWorstFivePercent() {
        let values = (0..<100).map(Double.init)
        let hi = MetricScores.pool(values, higherIsBetter: true)
        XCTAssertEqual(hi.mean, 49.5, accuracy: 1e-9)
        XCTAssertEqual(hi.worst, 4)
        let lo = MetricScores.pool(values, higherIsBetter: false)
        XCTAssertEqual(lo.worst, 95)
    }

    func testProfilesHaveOneSearchMetric() {
        for hdr in [true, false] {
            for p in QualityProfile.presets(hdr: hdr) {
                XCTAssertEqual(p.rules.filter { $0.role == .target }.count, 1, p.name)
                XCTAssertFalse(p.primary!.metric.slow, "the search metric must be fast")
            }
        }
        XCTAssertFalse(QualityProfile.presets(hdr: true)[0].rules.contains { $0.metric == .ssimulacra2 && $0.role != .off },
                       "SSIMULACRA 2 is SDR-only")
    }

    func testPassesIgnoresUnmeasuredAndSlowWhenAsked() {
        let profile = QualityProfile.presets(hdr: true)[0]
        var s = MetricScores()
        s.pooled[.vmaf] = (94, 90)
        s.pooled[.cambi] = (0.2, 0.5)
        XCTAssertTrue(s.passes(profile, includeSlow: false).ok)
        s.pooled[.cvvdp] = (9.2, 9.1)
        XCTAssertFalse(s.passes(profile, includeSlow: true).ok)
    }
}
