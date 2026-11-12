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

    /// The gaussian sequence is shifted right by 12 − bit depth (σ 32 / 128 / 512 code values at 8 / 10 / 12 bits), so
    /// the same grain in signal units gets the same scaling points at every depth. (12-bit used the 10-bit constant
    /// and came out four times too strong; measured with aomenc + dav1d: σ 16.7 codes for a table asking 16.5.)
    func testGrainScalingIsTheSameAtEveryBitDepth() {
        let stats = FilmTexture.film35.stats(strength: 1)
        func scaling(_ bits: Int, _ format: GrainTable.Format) -> [Int] {
            let line = GrainTable.text(stats, bitDepth: bits, format: format).split(separator: "\n").first { $0.contains("sY") }!
            let v = line.split(separator: " ").dropFirst(2).compactMap { Int($0) }
            return stride(from: 1, to: v.count, by: 2).map { v[$0] }
        }
        let ten = scaling(10, .av1)
        for (a, b) in zip(ten, scaling(12, .av1)) { XCTAssertEqual(a, b, accuracy: 1) }
        for (a, b) in zip(ten, scaling(8, .av1)) { XCTAssertEqual(a, b, accuracy: 2) }
        XCTAssertEqual(scaling(10, .av2), ten, "AV2 uses the same gaussian sequence and scaling as AV1")
        XCTAssert(GrainTable.text(stats, bitDepth: 10, format: .av2).hasPrefix("filmgrn2"))
    }

    func testFilmTexturePeaksInMidtones() {
        let s = FilmTexture.film35.stats(strength: 1).sigmaPerBin
        XCTAssertGreaterThan(s[s.count / 2], s[0])
        XCTAssertEqual(FilmTexture.off.stats(strength: 1).overall, 0)
    }
}
