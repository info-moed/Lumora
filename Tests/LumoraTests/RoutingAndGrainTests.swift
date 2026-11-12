import XCTest
@testable import Lumora

final class RoutingAndGrainTests: XCTestCase {
    func testClearWinnerReachesHighConfidence() {
        let a = (0..<12).map { 0.95 + Double($0 % 3) * 0.001 }
        let b = (0..<12).map { 0.93 + Double($0 % 3) * 0.001 }
        let v = MotionRouter.decide(["rife": a, "film": b], target: 0.97)
        XCTAssertEqual(v.best, "rife")
        XCTAssertGreaterThanOrEqual(v.conf, 0.97)
        XCTAssertFalse(v.tied)
    }

    func testIdenticalModelsAreATie() {
        let a = Array(repeating: 0.95, count: 10)
        let v = MotionRouter.decide(["x": a, "y": a], target: 0.97)
        XCTAssertTrue(v.tied)
    }

    func testNoisyCloseRaceIsNotConfident() {
        let a = [0.95, 0.91, 0.96, 0.90, 0.94, 0.92]
        let b = [0.94, 0.93, 0.95, 0.91, 0.93, 0.93]
        XCTAssertLessThan(MotionRouter.decide(["a": a, "b": b], target: 0.97).conf, 0.97)
    }

    func testGrainTableFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grain-test.tbl")
        try GrainTable.write(FilmTexture.film35.stats(strength: 1), bitDepth: 10, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssert(text.hasPrefix("filmgrn1"))
        XCTAssert(text.contains("\tsY "))
        let points = text.split(separator: "\n").first { $0.contains("sY") }!.split(separator: " ").dropFirst(2).compactMap { Int($0) }
        XCTAssert(points.allSatisfy { (0...255).contains($0) })
    }

    func testFilmTexturePeaksInMidtones() {
        let s = FilmTexture.film35.stats(strength: 1).sigmaPerBin
        XCTAssertGreaterThan(s[s.count / 2], s[0])
        XCTAssertEqual(FilmTexture.off.stats(strength: 1).overall, 0)
    }
}
