import Foundation
import SystemConfiguration

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
        var volumes: [String] = []
    }

    static func share(_ s: String, names: Names = Names()) -> String {
        var t = local(s)
        // Drive names: "/Volumes/Holiday Footage/..." → "/Volumes/<drive>/...", and the same names wherever else they
        // appear (an explanation says “Holiday Footage” is full).
        var drives = Set(names.volumes)
        if let re = try? NSRegularExpression(pattern: #"/Volumes/([^/\n]+)"#) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                if let r = Range(m.range(at: 1), in: t) { drives.insert(String(t[r])) }
            }
        }
        // Drives mounted right now are hidden where a message quotes them; they aren't searched for as bare words
        // (a drive called "Movies" would otherwise eat every "Movies" in the report).
        let mounted = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).filter { $0 != "Macintosh HD" && $0.count >= 3 }
        t = t.replacingOccurrences(of: #"/Volumes/[^/\n]+"#, with: "/Volumes/<drive>", options: .regularExpression)
        for d in (drives.union(mounted)).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            t = t.replacingOccurrences(of: "“\(d)”", with: "“<drive>”")
        }
        // Bare drive names, except words the report itself needs (a drive named after the app or a tool).
        for d in drives.filter({ $0.count >= 3 && !protectedWords.contains($0.lowercased()) }).sorted(by: { $0.count > $1.count }) {
            t = t.replacingOccurrences(of: d, with: "<drive>")
        }
        // File names first (longest first, so "clip (repaired)" goes before "clip").
        for (list, tag) in [(names.output, "<output>"), (names.source, "<source>")] {
            for n in Set(list.filter { $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
                t = t.replacingOccurrences(of: n, with: tag)
            }
        }
        let account = NSUserName()
        let full = NSFullUserName()
        let (host, computer) = machineNames
        let localHost = host.replacingOccurrences(of: ".local", with: "")
        for (value, tag) in [(full, "<name>"), (computer, "<computer>"), (localHost, "<computer>"), (host, "<computer>"), (account, "<account>")]
        where value.count >= 3 {
            t = t.replacingOccurrences(of: value, with: tag, options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        // Serial-number-like tokens: 10-14 upper-case letters and digits with both present (Mac serials, drive serials).
        t = t.replacingOccurrences(of: #"\b(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*[0-9])[A-Z0-9]{10,14}\b"#, with: "<serial>",
                                   options: .regularExpression)
        return t
    }

    /// Words a drive name can't take away from the report: the app and the tools it names.
    static let protectedWords: Set<String> = ["lumora", "ffmpeg", "ffprobe", "mp4box", "mkvmerge", "x265", "aomenc", "avmenc",
                                              "vvencapp", "svtav1encapp", "dovi_tool", "hdr10plus_tool", "macos", "export", "exports"]

    /// The host name and the computer name (Sharing settings). Read directly: `ProcessInfo.hostName` can block for
    /// seconds on a network lookup.
    static let machineNames: (host: String, computer: String) = {
        var buf = [CChar](repeating: 0, count: 256)
        let host = gethostname(&buf, buf.count) == 0 ? String(cString: buf) : ""
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        return (host, computer)
    }()

    /// The names an export's shared report hides: the base names (with and without extension) of source and output.
    static func names(source: URL, output: URL) -> Names {
        func both(_ u: URL) -> [String] { [u.lastPathComponent, u.deletingPathExtension().lastPathComponent] }
        return Names(source: both(source), output: both(output))
    }
}
