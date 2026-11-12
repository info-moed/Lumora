import XCTest
@testable import Lumora

final class PlannerTests: XCTestCase {
    private func plan(_ mode: PlanMode, budget: Double = 4 * 3600, codec: Codec = .av1, kind: ContentKind = .anime) -> EncodePlan {
        EncodePlanner.plan(codec: codec, kind: kind, frames: 34_000, width: 3840, height: 2160, vmafMode: true,
                           renderFps: 30, mode: mode, budget: budget, overrides: [:])
    }

    func testModesAreOrderedByTimeAndEfficiency() {
        let fast = plan(.fastest), best = plan(.bestForMac), max = plan(.maximum)
        XCTAssertLessThanOrEqual(fast.seconds, best.seconds)
        XCTAssertLessThanOrEqual(best.seconds, max.seconds)
        XCTAssertLessThanOrEqual(fast.saving, max.saving)
    }

    func testBudgetIsRespectedWhenPossible() {
        let p = plan(.budget, budget: 6 * 3600)
        let fastest = plan(.fastest)
        XCTAssert(p.seconds <= 6 * 3600 || p.seconds == fastest.seconds)
    }

    func testUpgradeIsSlowerAndBetter() {
        let p = plan(.fastest)
        if let u = p.upgrade {
            XCTAssertGreaterThan(u.extraSeconds, 0)
            XCTAssertGreaterThan(u.smallerFraction, 0)
        }
    }

    func testGrainSynthesisIsUsedForGrainyFilmsEvenInVMAFMode() {
        // Scoring strips synthetic grain and compares against a de-grained master, so it no longer conflicts.
        let p = plan(.bestForMac, kind: .realLifeHeavyGrain)
        if p.options.contains(where: { $0.id == "grain" }) { XCTAssert(p.enabled.contains("grain")) }
        let off = EncodePlanner.plan(codec: .av1, kind: .realLifeHeavyGrain, frames: 1000, width: 1920, height: 1080,
                                     vmafMode: true, renderFps: 60, mode: .fastest, budget: 3600, overrides: ["grain": false])
        XCTAssertFalse(off.enabled.contains("grain"))
    }

    func testX265AnimeRecipeHasAnimeFlags() {
        let r = EncodeRecipes.recipe(codec: .hevc12, kind: .anime)
        let args = r.options.flatMap(\.args)
        XCTAssert(args.contains("--aq-mode"))
        XCTAssert(args.contains("--limit-sao"))
        XCTAssertEqual(r.rungs.first?.presetValue, "faster")
    }
}
