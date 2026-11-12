import Foundation

/// Optional online lookup (The Movie Database) with your own free API key. Lumora works fully offline without it;
/// this only fills in title, year, plot, genres and IDs for naming and the NFO.
enum LibraryLookup {
    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "tmdbKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "tmdbKey") }
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
