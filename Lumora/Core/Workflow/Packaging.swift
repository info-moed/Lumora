import Foundation

/// One audio or subtitle track in the source.
struct MediaTrack: Identifiable, Hashable, Codable {
    var index: Int              // stream index in the source
    var kind: String            // "audio" / "subtitle"
    var codec: String
    var language: String
    var title: String
    var channels: Int
    var isAtmos: Bool
    var isDefault: Bool
    var isForced: Bool
    var id: Int { index }

    var label: String {
        var parts = [language.isEmpty ? "und" : language.uppercased(), codec.uppercased()]
        if kind == "audio" { parts.append(channels == 8 ? "7.1" : (channels == 6 ? "5.1" : "\(channels) ch")) }
        if isAtmos { parts.append("Atmos") }
        if isForced { parts.append("forced") }
        if !title.isEmpty { parts.append("“\(title)”") }
        return parts.joined(separator: " · ")
    }
    /// Lossless home-theater formats that some players can't decode.
    var needsCompatibilityTrack: Bool { kind == "audio" && ["truehd", "dts", "mlp", "pcm_s24le", "pcm_s16le", "flac"].contains(codec) }
    /// Bitmap subtitles (Blu-ray PGS, DVD VobSub) only fit in MKV.
    var isBitmapSubtitle: Bool { kind == "subtitle" && ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"].contains(codec) }
}

struct SourceStreams: Codable {
    var audio: [MediaTrack] = []
    var subtitles: [MediaTrack] = []
    var chapters = 0
    var tags: [String: String] = [:]     // container-level metadata found in the file

    static func probe(_ url: URL) -> SourceStreams {
        guard let data = try? ToolLocator.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_chapters",
                                                          "-show_format", url.path]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return SourceStreams() }
        var s = SourceStreams()
        for st in root["streams"] as? [[String: Any]] ?? [] {
            let type = st["codec_type"] as? String ?? ""
            guard type == "audio" || type == "subtitle" else { continue }
            let tags = st["tags"] as? [String: Any] ?? [:]
            let disp = st["disposition"] as? [String: Any] ?? [:]
            let profile = (st["profile"] as? String ?? "") + " " + (tags["title"] as? String ?? "")
            let t = MediaTrack(index: st["index"] as? Int ?? 0, kind: type, codec: st["codec_name"] as? String ?? "?",
                               language: tags["language"] as? String ?? "", title: tags["title"] as? String ?? "",
                               channels: st["channels"] as? Int ?? 0, isAtmos: profile.localizedCaseInsensitiveContains("atmos"),
                               isDefault: (disp["default"] as? Int ?? 0) == 1, isForced: (disp["forced"] as? Int ?? 0) == 1)
            if type == "audio" { s.audio.append(t) } else { s.subtitles.append(t) }
        }
        s.chapters = (root["chapters"] as? [[String: Any]])?.count ?? 0
        if let fmt = root["format"] as? [String: Any], let tags = fmt["tags"] as? [String: Any] {
            s.tags = tags.compactMapValues { "\($0)" }
        }
        return s
    }
}

/// What to do with metadata already in the file.
enum MetadataPolicy: String, CaseIterable, Codable, Identifiable {
    case keep = "Keep it"
    case removePersonal = "Remove personal details"
    case removeAll = "Remove everything"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .keep: return "Copies the source's titles, tags and descriptions."
        case .removePersonal: return "Removes location (GPS), device make/model, creation dates, encoder/software names, comments and personal names. Keeps titles and languages."
        case .removeAll: return "Removes every tag (titles, languages excepted) so only what you write below is in the file."
        }
    }
    /// Container tags kept by "remove personal details". Everything else is dropped (an allowlist: phone and
    /// camera makers add new personal tags all the time, so a denylist would leak).
    static let safeKeys: Set<String> = ["title", "album", "genre", "description", "synopsis", "show", "season_number",
                                        "episode_sort", "episode_id", "network", "language", "track", "disc"]
    /// Container tags that count as personal (shown in the UI as what was found).
    static let personalKeys = ["location", "location-eng", "com.apple.quicktime.location.iso6709", "com.apple.quicktime.make",
                               "com.apple.quicktime.model", "com.apple.quicktime.software", "creation_time", "date", "encoder",
                               "encoded_by", "comment", "artist", "author", "copyright", "com.apple.quicktime.author",
                               "com.apple.quicktime.creationdate", "major_brand", "minor_version", "compatible_brands", "handler_name"]
}

/// Extra files written next to the video.
enum Appendix: String, CaseIterable, Codable, Identifiable {
    case settings = "Settings file (reproduce this encode exactly)"
    case qualityReport = "Quality report"
    case checksums = "Checksums (SHA-256)"
    case nfo = "NFO for Plex/Kodi/Infuse"
    case poster = "Poster frame (JPEG)"
    case chapters = "Chapter list"
    case hdrReport = "HDR report card"
    case log = "Encode log"
    var id: String { rawValue }
    var fileSuffix: String {
        switch self {
        case .settings: return ".lumora.json"; case .qualityReport: return ".quality.txt"; case .checksums: return ".sha256"
        case .nfo: return ".nfo"; case .poster: return "-poster.jpg"; case .chapters: return ".chapters.txt"
        case .hdrReport: return ".hdr-report.txt"; case .log: return ".log"
        }
    }
    static let recommended: Set<Appendix> = [.settings, .qualityReport, .checksums, .nfo, .poster]
}

/// Library naming patterns.
enum NamingScheme: String, CaseIterable, Codable, Identifiable {
    case plexMovie = "Plex / Infuse movie", plexTV = "Plex / Infuse TV episode", keep = "Keep the original name", custom = "Custom pattern"
    var id: String { rawValue }
    var template: String {
        switch self {
        case .plexMovie: return "{title} ({year})/{title} ({year}){edition} - {resolution} {hdr} {codec}"
        case .plexTV: return "{show} ({year})/Season {season2}/{show} ({year}) - S{season2}E{episode2}{episodeTitle} - {resolution} {hdr}"
        case .keep: return "{original}"
        case .custom: return "{title} ({year})"
        }
    }
}

/// Your own metadata, written into the file.
struct BespokeMetadata: Codable, Hashable {
    var title = ""
    var year = ""
    var show = ""
    var season = ""
    var episode = ""
    var episodeTitle = ""
    var edition = ""            // e.g. "Director's Cut", "Remastered"
    var description = ""
    var genre = ""
    var comment = ""
    var custom: [KeyValue] = []
    var imdbID = ""
    var tmdbID = ""

    struct KeyValue: Codable, Hashable, Identifiable { var id = UUID(); var key = ""; var value = "" }
}

struct PackagingOptions: Codable, Hashable {
    var naming: NamingScheme = .plexMovie
    var customTemplate = "{title} ({year})"
    var outputName = ""                  // explicit rename (overrides the pattern)
    var metadataPolicy: MetadataPolicy = .removePersonal
    var bespoke = BespokeMetadata()
    var keepAudio: Set<Int> = []         // empty = all
    var keepSubtitles: Set<Int> = []     // empty = all
    var addCompatibilityTrack = true     // Dolby Digital Plus 5.1 alongside lossless audio
    var keepChapters = true
    var appendices: Set<Appendix> = Appendix.recommended
    var verifyAfterExport = true
}

enum Naming {
    /// Builds the relative path (folders + file name, no extension) from a pattern and the facts about the export.
    static func path(_ o: PackagingOptions, original: String, facts: [String: String]) -> String {
        if !o.outputName.isEmpty { return safeRelativePath(o.outputName) }
        let t = o.naming == .custom ? o.customTemplate : o.naming.template
        var v = facts
        let b = o.bespoke
        v["original"] = original
        v["title"] = b.title.isEmpty ? (facts["title"] ?? original) : b.title
        v["year"] = b.year.isEmpty ? (facts["year"] ?? "") : b.year
        v["show"] = b.show.isEmpty ? (facts["show"] ?? v["title"]!) : b.show
        v["season2"] = String(format: "%02d", Int(b.season.isEmpty ? (facts["season"] ?? "1") : b.season) ?? 1)
        v["episode2"] = String(format: "%02d", Int(b.episode.isEmpty ? (facts["episode"] ?? "1") : b.episode) ?? 1)
        v["episodeTitle"] = b.episodeTitle.isEmpty ? "" : " - " + b.episodeTitle
        v["edition"] = b.edition.isEmpty ? "" : " {edition-\(b.edition)}"
        v["imdb"] = b.imdbID
        var out = t
        for (k, val) in v { out = out.replacingOccurrences(of: "{\(k)}", with: val) }
        out = out.replacingOccurrences(of: " ()", with: "").replacingOccurrences(of: "  ", with: " ")
        return safeRelativePath(out)
    }

    /// A relative path that can never leave the destination folder: every component is sanitized, and empty,
    /// "." and ".." components are dropped (titles can come from file names, typing or online lookups).
    static func safeRelativePath(_ s: String) -> String {
        let parts = s.split(separator: "/").map { sanitize(String($0)) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Untitled" : parts.joined(separator: "/")
    }

    /// One path component: no reserved or control characters, no leading dots (hidden files, "..").
    static func sanitize(_ s: String) -> String {
        var c = String(s.unicodeScalars.map { u -> Character in
            if u.properties.generalCategory == .control || ":\\?*\"<>|/".unicodeScalars.contains(u) { return "-" }
            return Character(u)
        }).trimmingCharacters(in: .whitespaces)
        while c.hasPrefix(".") { c.removeFirst() }
        return truncated(c, maxBytes: 200).trimmingCharacters(in: .whitespaces)
    }

    /// Cuts a name at a character boundary so its UTF-8 form fits `maxBytes`. File systems allow 255 bytes (or
    /// UTF-16 units) per name, and emoji or combining accents take 2–4 of those per character, so a limit in
    /// characters isn't enough; the remaining room is for extensions and sidecar suffixes like ".hdr-report.txt".
    static func truncated(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = "", bytes = 0
        for ch in s {
            bytes += ch.utf8.count
            if bytes > maxBytes { break }
            out.append(ch)
        }
        return out
    }

    /// Guesses title / year / season / episode from a file name like "The.Movie.2019.2160p.UHD.mkv" or "Show.S02E05.mkv".
    static func guess(from name: String) -> [String: String] {
        var n = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        var facts: [String: String] = [:]
        if let r = n.range(of: #"[Ss](\d{1,2})[Ee](\d{1,3})"#, options: .regularExpression) {
            let m = String(n[r]).lowercased().dropFirst()
            let parts = m.split(separator: "e")
            facts["season"] = String(parts.first ?? "1"); facts["episode"] = String(parts.last ?? "1")
            facts["show"] = String(n[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            n = String(n[..<r.lowerBound])
        }
        if let r = n.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            facts["year"] = String(n[r])
            n = String(n[..<r.lowerBound])
        }
        if let r = n.range(of: #"\b(2160p|1080p|720p|UHD|BluRay|REMUX|WEB|HDR)\b"#, options: [.regularExpression, .caseInsensitive]) {
            n = String(n[..<r.lowerBound])
        }
        facts["title"] = n.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
        return facts
    }
}

/// Removes the home-folder part of paths (which contains the account name) from text written next to a file
/// when the user asked for personal details to be removed.
enum PrivacyScrub {
    static func paths(_ s: String) -> String {
        s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
         .replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/…", options: .regularExpression)
    }
}
