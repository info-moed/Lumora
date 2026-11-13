import XCTest
@testable import Lumora

/// Tests must never touch the owner's real preferences, and two test runs at once must not share settings.
final class PrefsTests: XCTestCase {
    func testTestRunsUseTheirOwnPreferences() {
        XCTAssertTrue(Prefs.isTestRun)
        XCTAssertFalse(Prefs.store === UserDefaults.standard, "a test run must not write the app's real preferences")
        XCTAssertTrue(Prefs.testDomain.hasSuffix("-\(getpid())"), "the domain is unique to this process")

        let key = "prefsTestsProbe-\(UUID().uuidString)"
        Prefs.store.set("probe", forKey: key)
        defer { Prefs.store.removeObject(forKey: key) }
        XCTAssertEqual(Prefs.store.string(forKey: key), "probe")
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key],
                     "the write must not reach the app's own domain")
    }
}
