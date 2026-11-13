import Foundation

/// Privacy passes for everything the recovery features write.
///
/// - `local`: for the per-export log that stays on this Mac. The home folder becomes "~" (the account name is part of
///   that path), the same rule `PrivacyScrub.paths` and `String.displayPath` follow.
/// - `share`: for the diagnostic report someone may paste into an issue. On top of the local pass it replaces the
///   account name, the full name, the computer name, drive names, the source and output file names, and anything that
///   looks like an email address or a serial number.
enum DiagnosticScrub {
    static func local(_ s: String) -> String {
        PrivacyScrub.paths(s)
    }

    /// Names that must not leave the Mac in a shared report (besides paths): set per export.
    struct Names {
        var source: [String] = []
        var output: [String] = []
    }

    static func share(_ s: String, names: Names = Names()) -> String {
        var t = local(s)
        // Drive names: "/Volumes/Holiday Footage/..." → "/Volumes/<drive>/...".
        t = t.replacingOccurrences(of: #"/Volumes/[^/\n]+"#, with: "/Volumes/<drive>", options: .regularExpression)
        // File names first (longest first, so "clip (repaired)" goes before "clip").
        for (list, tag) in [(names.output, "<output>"), (names.source, "<source>")] {
            for n in Set(list.filter { $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
                t = t.replacingOccurrences(of: n, with: tag)
            }
        }
        let account = NSUserName()
        let full = NSFullUserName()
        let host = ProcessInfo.processInfo.hostName
        let localHost = host.replacingOccurrences(of: ".local", with: "")
        for (value, tag) in [(full, "<name>"), (localHost, "<computer>"), (host, "<computer>"), (account, "<account>")]
        where value.count >= 3 {
            t = t.replacingOccurrences(of: value, with: tag, options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        // Serial-number-like tokens: 10-14 upper-case letters and digits with both present (Mac serials, drive serials).
        t = t.replacingOccurrences(of: #"\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{10,14}\b"#, with: "<serial>",
                                   options: .regularExpression)
        return t
    }

    /// The names an export's shared report hides: the base names (with and without extension) of source and output.
    static func names(source: URL, output: URL) -> Names {
        func both(_ u: URL) -> [String] { [u.lastPathComponent, u.deletingPathExtension().lastPathComponent] }
        return Names(source: both(source), output: both(output))
    }
}
