import Foundation
import Security

/// Optional online lookup (The Movie Database) with your own free API key. Lumora works fully offline without it;
/// this only fills in title, year, plot, genres and IDs for naming and the NFO.
enum LibraryLookup {
    /// Kept in the login Keychain, not in preferences. A key left in preferences by older versions is moved
    /// across the first time it's read.
    static var apiKey: String {
        get {
            if let legacy = UserDefaults.standard.string(forKey: "tmdbKey") {
                if !legacy.isEmpty { Keychain.set(legacy, account: "tmdb") }
                UserDefaults.standard.removeObject(forKey: "tmdbKey")
            }
            return Keychain.get(account: "tmdb") ?? ""
        }
        set { newValue.isEmpty ? Keychain.delete(account: "tmdb") : Keychain.set(newValue, account: "tmdb") }
    }

    struct Match: Identifiable, Hashable { var id: Int; var title: String; var year: String; var overview: String; var tv: Bool }

    static func search(_ query: String, year: String?, tv: Bool) async throws -> [Match] {
        guard !apiKey.isEmpty else { throw LumoraError.unsupported("Add a TMDB API key in Settings → Library to look titles up online.") }
        var c = URLComponents(string: "https://api.themoviedb.org/3/search/\(tv ? "tv" : "movie")")!
        c.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "query", value: query)]
            + (year.map { [URLQueryItem(name: tv ? "first_air_date_year" : "year", value: $0)] } ?? [])
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["results"] as? [[String: Any]] ?? []).prefix(8).map { r in
            Match(id: r["id"] as? Int ?? 0, title: (r["title"] ?? r["name"]) as? String ?? "",
                  year: String(((r["release_date"] ?? r["first_air_date"]) as? String ?? "").prefix(4)),
                  overview: r["overview"] as? String ?? "", tv: tv)
        }
    }

    /// Fills bespoke metadata from a match (genres and IMDb ID need one more call).
    static func details(_ m: Match, into b: inout BespokeMetadata) async {
        b.title = m.tv ? b.title : m.title
        if m.tv { b.show = m.title }
        b.year = m.year
        b.description = m.overview
        b.tmdbID = "\(m.id)"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(m.tv ? "tv" : "movie")/\(m.id)?api_key=\(apiKey)&append_to_response=external_ids"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        b.genre = (root["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        b.imdbID = (root["imdb_id"] as? String) ?? ((root["external_ids"] as? [String: Any])?["imdb_id"] as? String) ?? ""
    }
}

/// Minimal generic-password storage in the login Keychain.
enum Keychain {
    static let service = "io.github.info-moed.Lumora"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(q as CFDictionary, nil)
        }
    }
    static func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}
