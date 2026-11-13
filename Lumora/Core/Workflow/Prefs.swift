import Foundation

/// Lumora's preferences. The app uses the standard user defaults. A test run gets its own throwaway domain instead, so
/// tests never change the owner's settings, and two test runs at the same time never share one (for example the
/// scratch folder: one run's temporary folder became the other's and was deleted under it).
enum Prefs {
    static var isTestRun: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// The domain a test run uses: unique per process, emptied when it starts and when it exits.
    static let testDomain = "io.github.info-moed.Lumora.tests-\(getpid())"

    static let store: UserDefaults = {
        guard isTestRun, let d = UserDefaults(suiteName: testDomain) else { return .standard }
        d.removePersistentDomain(forName: testDomain)
        atexit { UserDefaults.standard.removePersistentDomain(forName: Prefs.testDomain) }
        return d
    }()
}
