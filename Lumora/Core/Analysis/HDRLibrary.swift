import Foundation

/// One title in the UHD reference library. Facts are measured; opinions are short, in our own words,
/// and always carry a source link so anyone can check them.
struct HDRTitle: Codable, Identifiable, Hashable {
    var id: String { "\(title)-\(year)-\(edition ?? "")" }
    var title: String
    var year: Int
    var edition: String?              // e.g. "2017 UHD Blu-ray", "4K remaster 2023"
    var hdrFormats: [String]          // "HDR10", "Dolby Vision P7 FEL", "HDR10+"
    var masteringPeakNits: Int?
    var maxCLL: Int?
    var maxFALL: Int?
    var measuredP999Nits: Int?        // from Lumora's Report Card, when someone measured it
    var nativeResolution: String?     // "4K DI", "2K DI upscaled"
    var rating: Rating
    var reasons: [String]             // short, plain English: why it's good or bad
    var sources: [URL]
    var contributedBy: String?
    /// "My copy" entries from the HDR Report: the measured file on this Mac, so the Library can play it.
    var localFile: String? = nil

    enum Rating: String, Codable, CaseIterable {
        case reference = "Reference", great = "Great", average = "Average", dim = "Dim / conservative", poor = "Poor"
    }
}

/// Loads the bundled library, the user's own entries, and an optional community-maintained library
/// (any JSON array of HDRTitle at a URL the user chooses, e.g. a GitHub raw file). Lumora ships with
/// no ratings of its own: the library is only as good as the measurements people put into it.
@MainActor
final class HDRLibrary: ObservableObject {
    @Published private(set) var titles: [HDRTitle] = []
    @Published var communityURL: URL? {
        didSet { Prefs.store.set(communityURL?.absoluteString, forKey: "hdrLibraryURL") }
    }

    private var userFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumora", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hdr_library_user.json")
    }

    init() {
        communityURL = Prefs.store.string(forKey: "hdrLibraryURL").flatMap(URL.init(string:))
        reloadLocal()
    }

    func reloadLocal() {
        var all: [HDRTitle] = []
        if let url = Bundle.main.url(forResource: "hdr_library", withExtension: "json"),
           let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([HDRTitle].self, from: data) { all += t }
        if let data = try? Data(contentsOf: userFile), let t = try? JSONDecoder().decode([HDRTitle].self, from: data) { all += t }
        titles = merge(all)
    }

    func syncCommunity() async throws {
        guard let url = communityURL else { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        let remote = try JSONDecoder().decode([HDRTitle].self, from: data)
        titles = merge(titles + remote)
    }

    func add(_ title: HDRTitle) throws {
        var mine: [HDRTitle] = []
        if let data = try? Data(contentsOf: userFile), !data.isEmpty {
            // A file that can't be read (e.g. a typo from hand-editing) is never replaced by a one-entry list.
            do { mine = try JSONDecoder().decode([HDRTitle].self, from: data) } catch {
                throw LumoraError.unsupported("Your library file \(userFile.lastPathComponent) couldn't be read, so nothing was changed. Fix or remove it, then try again. (\(error.localizedDescription))")
            }
        }
        mine.removeAll { $0.id == title.id }
        mine.append(title)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(mine).write(to: userFile)
        reloadLocal()
    }

    var best: [HDRTitle] { titles.filter { $0.rating == .reference || $0.rating == .great } }
    var worst: [HDRTitle] { titles.filter { $0.rating == .dim || $0.rating == .poor } }

    /// Where a measured file sits against library titles that have a measured highlight level.
    func rank(_ card: HDRReportCard) -> String? {
        let measured = titles.compactMap { $0.measuredP999Nits }.sorted()
        guard measured.count >= 5 else { return nil }
        let below = measured.filter { Float($0) < card.p999Nits }.count
        let pct = Int(Double(below) / Double(measured.count) * 100)
        return "Brighter highlights than \(pct)% of the \(measured.count) measured titles in your library."
    }

    func match(_ name: String) -> HDRTitle? {
        let key = name.lowercased()
        return titles.first { key.contains($0.title.lowercased()) }
    }

    private func merge(_ list: [HDRTitle]) -> [HDRTitle] {
        var seen: [String: HDRTitle] = [:]
        for t in list { seen[t.id] = t }   // later sources (user, community) override earlier ones
        return seen.values.sorted { $0.title < $1.title }
    }
}
