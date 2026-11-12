import XCTest
@testable import Lumora

final class PackagingTests: XCTestCase {
    func testGuessesMovieAndEpisodeNames() {
        let m = Naming.guess(from: "Planes.Trains.and.Automobiles.1987.2160p.UHD.BluRay.REMUX")
        XCTAssertEqual(m["title"], "Planes Trains and Automobiles")
        XCTAssertEqual(m["year"], "1987")
        let e = Naming.guess(from: "The.Show.S02E05.1080p.WEB")
        XCTAssertEqual(e["season"], "02")
        XCTAssertEqual(e["episode"], "05")
        XCTAssertEqual(e["show"], "The Show")
    }

    func testPlexMoviePath() {
        var o = PackagingOptions()
        o.bespoke.title = "Planes, Trains and Automobiles"; o.bespoke.year = "1987"; o.bespoke.edition = "Remastered"
        let p = Naming.path(o, original: "x", facts: ["resolution": "2160p", "hdr": "HDR10", "codec": "AV1"])
        XCTAssertEqual(p, "Planes, Trains and Automobiles (1987)/Planes, Trains and Automobiles (1987) {edition-Remastered} - 2160p HDR10 AV1")
    }

    func testRenameOverridesAndSanitizes() {
        var o = PackagingOptions()
        o.outputName = "My: Cut?"
        XCTAssertEqual(Naming.path(o, original: "x", facts: [:]), "My- Cut-")
    }

    func testNFOEscapesAndIncludesIDs() {
        var b = BespokeMetadata()
        b.title = "Tom & Jerry"; b.year = "1940"; b.imdbID = "tt0000001"
        let x = NFO.make(b, guess: [:], tv: false)
        XCTAssert(x.contains("<title>Tom &amp; Jerry</title>"))
        XCTAssert(x.contains("uniqueid type=\"imdb\""))
    }

    func testScheduleWindowWrapsMidnight() {
        var r = RunRules(); r.onlyBetween = true; r.startHour = 23; r.endHour = 7
        let cal = Calendar.current
        let at = { (h: Int) in cal.date(bySettingHour: h, minute: 0, second: 0, of: Date())! }
        XCTAssertTrue(PauseGate.inWindow(r, now: at(2)))
        XCTAssertTrue(PauseGate.inWindow(r, now: at(23)))
        XCTAssertFalse(PauseGate.inWindow(r, now: at(12)))
    }

    func testChecksumOfKnownData() async throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: u)
        let h = try await Checksum.sha256(u)
        XCTAssertEqual(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
