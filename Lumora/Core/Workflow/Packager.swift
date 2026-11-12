import Foundation
import CryptoKit

/// Turns an encoded video into a finished, library-ready file: chosen audio/subtitles/chapters from the source,
/// a compatibility audio track, metadata policy + your own metadata, the final name and folder, and appendices.
enum Packager {
    struct Facts {
        var title: String
        var resolution: String
        var hdr: String
        var codec: String
        var appVersion: String
        var settings: [String: Any]          // everything needed to reproduce the encode
        var qualityLines: [String]
        var hdrReport: [String]
        var logLines: [String]
        var posterJPEG: Data?
    }

    struct Result { var video: URL; var appendices: [URL]; var verified: Bool?; var sha256: String? }

    static func package(exported: URL, source: URL, streams: SourceStreams, options o: PackagingOptions, destination: URL,
                        facts: Facts, progress: ProgressReporter) async throws -> Result {
        // Name and folder.
        let guess = Naming.guess(from: source.deletingPathExtension().lastPathComponent)
        var factMap = guess
        factMap["resolution"] = facts.resolution; factMap["hdr"] = facts.hdr; factMap["codec"] = facts.codec
        let keptSubs = streams.subtitles.filter { o.keepSubtitles.isEmpty || o.keepSubtitles.contains($0.index) }
        let audio = streams.audio.filter { o.keepAudio.isEmpty || o.keepAudio.contains($0.index) }
        var ext = exported.pathExtension.lowercased()
        if keptSubs.contains(where: \.isBitmapSubtitle) && ext != "mkv" { ext = "mkv" }   // Blu-ray subtitles only fit in MKV
        if ext == "mov" && videoCodec(exported) != "prores" { ext = "mp4" }                 // ProRes has no MP4 binding
        // Audio FFmpeg can't put in an MP4 / QuickTime file (TrueHD, and FLAC/Opus in QuickTime) goes to MKV instead.
        if let unfit = ext == "mp4" ? Self.notInMP4 : (ext == "mov" ? Self.notInMOV : nil),
           audio.contains(where: { unfit.contains($0.codec) }) { ext = "mkv" }
        let rel = Naming.path(o, original: source.deletingPathExtension().lastPathComponent, facts: factMap)
        let out = destination.appendingPathComponent(rel).appendingPathExtension(ext)
        // Belt and braces: the finished file must land inside the folder the user chose.
        let root = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard out.standardizedFileURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw LumoraError.unsupported("The file name “\(rel)” would place the file outside the chosen folder.")
        }
        guard out.standardizedFileURL.path != source.standardizedFileURL.path else {
            throw LumoraError.unsupported("The finished file would replace the source file. Choose another folder or name.")
        }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Remux with FFmpeg: video from the export, the rest from the source.
        var args = ["-y", "-v", "error", "-i", exported.path, "-i", source.path, "-map", "0:v:0"]
        var codecArgs: [String] = ["-c", "copy"]
        var outAudio = 0
        for t in audio {
            args += ["-map", "1:\(t.index)"]
            outAudio += 1
        }
        if o.addCompatibilityTrack, let lossless = (audio.first { $0.isDefault && $0.needsCompatibilityTrack } ?? audio.first { $0.needsCompatibilityTrack }) {
            args += ["-map", "1:\(lossless.index)"]
            let n = outAudio
            codecArgs += ["-c:a:\(n)", "eac3", "-b:a:\(n)", "640k", "-ac:a:\(n)", "\(min(6, max(2, lossless.channels)))",
                          "-metadata:s:a:\(n)", "title=Compatibility (Dolby Digital Plus)",
                          "-metadata:s:a:\(n)", "language=\(lossless.language.isEmpty ? "und" : lossless.language)"]
            outAudio += 1
        }
        let quickTime = ext == "mp4" || ext == "mov"
        let subs = keptSubs.filter { !(ext != "mkv" && $0.isBitmapSubtitle) }
        for t in subs { args += ["-map", "1:\(t.index)"] }
        if quickTime && !subs.isEmpty { codecArgs += ["-c:s", "mov_text"] }
        if ext == "mkv" {      // MP4 text subtitles (tx3g) have no Matroska mapping; SubRip carries the same text
            for (i, t) in subs.enumerated() where t.codec == "mov_text" { codecArgs += ["-c:s:\(i)", "srt"] }
        }
        args += ["-map_chapters", o.keepChapters ? "1" : "-1"]

        // Metadata policy. Dropping file and track tags uses the :g / :s forms, not a bare "-map_metadata -1":
        // that would also strip the chapter titles (and leave MP4s with a dangling chapter-track reference).
        var meta: [String] = []
        let dropTags = ["-map_metadata:g", "-1", "-map_metadata:s", "-1", "-fflags", "+bitexact"]
        switch o.metadataPolicy {
        case .keep:
            meta += ["-map_metadata", "1"]
        case .removePersonal:
            // Start from nothing and copy back only known-safe tags.
            meta += dropTags
            for (key, value) in streams.tags.sorted(by: { $0.key < $1.key }) where MetadataPolicy.safeKeys.contains(key.lowercased()) {
                meta += ["-metadata", "\(key)=\(value)"]
            }
            fallthrough
        case .removeAll:
            if o.metadataPolicy == .removeAll { meta += dropTags }
            // Keep what players need: track languages and the titles of kept tracks.
            for (i, t) in audio.enumerated() {
                meta += ["-metadata:s:a:\(i)", "language=\(t.language.isEmpty ? "und" : t.language)"]
                if !t.title.isEmpty { meta += ["-metadata:s:a:\(i)", "title=\(t.title)"] }
            }
            for (i, t) in subs.enumerated() {
                meta += ["-metadata:s:s:\(i)", "language=\(t.language.isEmpty ? "und" : t.language)"]
                if !t.title.isEmpty { meta += ["-metadata:s:s:\(i)", "title=\(t.title)"] }
            }
        }
        // Your metadata.
        let b = o.bespoke
        // A title already in the file beats a guess from its file name; what you type beats both.
        let existingTitle = o.metadataPolicy == .removeAll ? nil : streams.tags.first { $0.key.lowercased() == "title" }?.value
        let pairs: [(String, String)] = [("title", b.title.isEmpty ? (existingTitle ?? guess["title"] ?? "") : b.title), ("date", b.year), ("description", b.description),
                                         ("comment", b.comment), ("genre", b.genre), ("show", b.show), ("season_number", b.season),
                                         ("episode_sort", b.episode), ("episode_id", b.episodeTitle), ("IMDB", b.imdbID), ("TMDB", b.tmdbID)]
            + b.custom.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }
        for (k, v) in pairs where !v.isEmpty { meta += ["-metadata", "\(k)=\(v)"] }
        if quickTime { meta += ["-movflags", "+use_metadata_tags+faststart"] }

        progress.update(0.1, detail: "Packaging \(out.lastPathComponent)")
        try ToolLocator.run("ffmpeg", args + codecArgs + meta + [out.path])
        Log.notice(.encode, "Packaged \(out.path) — \(audio.count) audio\(o.addCompatibilityTrack ? " + compatibility" : ""), \(subs.count) subtitle tracks, metadata: \(o.metadataPolicy.rawValue)")

        // Archive safety.
        var verified: Bool?
        if o.verifyAfterExport {
            progress.update(0.4, detail: "Verifying: decoding every frame and track")
            verified = Verifier.decodesCleanly(out)
            Log.write(verified == true ? .notice : .error, .encode, "Verification \(verified == true ? "passed" : "FAILED") for \(out.lastPathComponent)")
        }
        var sha: String?
        if o.appendices.contains(.checksums) || o.appendices.contains(.settings) {
            progress.update(0.75, detail: "Checksum")
            sha = try await Checksum.sha256(out) { p in progress.update(0.75 + p * 0.2, detail: nil) }
        }

        // Appendices.
        var written: [URL] = []
        let base = out.deletingPathExtension()
        func write(_ a: Appendix, _ text: String) throws {
            let u = URL(fileURLWithPath: base.path + a.fileSuffix)
            try text.write(to: u, atomically: true, encoding: .utf8)
            written.append(u)
        }
        for a in o.appendices.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch a {
            case .settings:
                var s = facts.settings
                s["output"] = out.lastPathComponent; s["sha256"] = sha ?? ""; s["app"] = facts.appVersion
                s["verified"] = verified.map { $0 ? "passed" : "failed" } ?? "not run"
                s["tools"] = ToolVersions.current()
                let data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys])
                try write(.settings, String(decoding: data, as: UTF8.self))
            case .qualityReport:
                try write(.qualityReport, (["Quality report for \(out.lastPathComponent)", ""] + facts.qualityLines).joined(separator: "\n"))
            case .checksums:
                if let sha { try write(.checksums, "\(sha)  \(out.lastPathComponent)\n") }
            case .nfo:
                try write(.nfo, NFO.make(b, guess: guess, tv: o.naming == .plexTV))
            case .poster:
                if let jpg = facts.posterJPEG {
                    let u = URL(fileURLWithPath: base.path + a.fileSuffix)
                    try jpg.write(to: u); written.append(u)
                }
            case .chapters:
                if streams.chapters > 0, let data = try? ToolLocator.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_chapters", out.path]),
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let lines = (root["chapters"] as? [[String: Any]] ?? []).enumerated().map { i, c -> String in
                        let t = Double(c["start_time"] as? String ?? "0") ?? 0
                        let title = (c["tags"] as? [String: Any])?["title"] as? String ?? "Chapter \(i + 1)"
                        return String(format: "%02d:%02d:%02d  %@", Int(t) / 3600, (Int(t) / 60) % 60, Int(t) % 60, title)
                    }
                    if !lines.isEmpty { try write(.chapters, lines.joined(separator: "\n")) }   // chapters dropped: no list
                }
            case .hdrReport:
                if !facts.hdrReport.isEmpty { try write(.hdrReport, facts.hdrReport.joined(separator: "\n")) }
            case .log:
                try write(.log, facts.logLines.joined(separator: "\n"))
            }
        }
        return Result(video: out, appendices: written, verified: verified, sha256: sha)
    }

    /// Audio codecs FFmpeg won't write into MP4 / QuickTime (without experimental flags).
    static let notInMP4: Set<String> = ["truehd", "mlp"]
    static let notInMOV: Set<String> = ["truehd", "mlp", "flac", "opus"]

    static func videoCodec(_ url: URL) -> String? {
        guard let data = try? ToolLocator.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name",
                                                          "-of", "default=nw=1:nk=1", url.path]) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NFO {
    static func make(_ b: BespokeMetadata, guess: [String: String], tv: Bool) -> String {
        func x(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let title = b.title.isEmpty ? (guess["title"] ?? "") : b.title
        let year = b.year.isEmpty ? (guess["year"] ?? "") : b.year
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", tv ? "<episodedetails>" : "<movie>",
                     "  <title>\(x(tv && !b.episodeTitle.isEmpty ? b.episodeTitle : title))</title>"]
        if tv {
            lines += ["  <showtitle>\(x(b.show.isEmpty ? (guess["show"] ?? title) : b.show))</showtitle>",
                      "  <season>\(x(b.season.isEmpty ? (guess["season"] ?? "1") : b.season))</season>",
                      "  <episode>\(x(b.episode.isEmpty ? (guess["episode"] ?? "1") : b.episode))</episode>"]
        }
        if !year.isEmpty { lines.append("  <year>\(x(year))</year>") }
        if !b.edition.isEmpty { lines.append("  <edition>\(x(b.edition))</edition>") }
        if !b.description.isEmpty { lines.append("  <plot>\(x(b.description))</plot>") }
        for g in b.genre.split(separator: ",") { lines.append("  <genre>\(x(g.trimmingCharacters(in: .whitespaces)))</genre>") }
        if !b.imdbID.isEmpty { lines.append("  <uniqueid type=\"imdb\" default=\"true\">\(x(b.imdbID))</uniqueid>") }
        if !b.tmdbID.isEmpty { lines.append("  <uniqueid type=\"tmdb\">\(x(b.tmdbID))</uniqueid>") }
        lines.append(tv ? "</episodedetails>" : "</movie>")
        return lines.joined(separator: "\n") + "\n"
    }
}

enum Checksum {
    /// Streaming SHA-256 (hardware-accelerated on Apple silicon), 16 MB at a time.
    static func sha256(_ url: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> String {
        try await Task.detached {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let size = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
            var hasher = SHA256()
            var done = 0.0
            while let chunk = try h.read(upToCount: 16 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                done += Double(chunk.count)
                progress(done / size)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

enum Verifier {
    /// Decodes every frame of every stream; any error means the file is damaged or non-conformant.
    static func decodesCleanly(_ url: URL) -> Bool {
        guard let log = try? ToolLocator.runCapturingStderr("ffmpeg", ["-v", "error", "-hwaccel", "videotoolbox", "-i", url.path,
                                                                        // Subtitles are read and passed through: the null
                                                                        // muxer has no subtitle encoder, so decoding them
                                                                        // would fail every file that has any.
                                                                        "-map", "0:v", "-map", "0:a?", "-map", "0:s?", "-c:s", "copy",
                                                                        "-f", "null", "-"]) else { return false }
        return log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-hashes every video in a folder that has a .sha256 sidecar (e.g. on the archive drive) and reports mismatches.
    static func verifyFolder(_ folder: URL, progress: ProgressReporter) async -> (checked: Int, bad: [String]) {
        let sidecars = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "sha256" }
        var bad: [String] = []
        for (i, s) in sidecars.enumerated() {
            guard let text = try? String(contentsOf: s, encoding: .utf8),
                  let line = text.split(separator: "\n").first else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let file = s.deletingLastPathComponent().appendingPathComponent(parts[1].trimmingCharacters(in: .whitespaces))
            let actual = try? await Checksum.sha256(file)
            if actual != String(parts[0]) { bad.append(file.lastPathComponent) }
            progress.update(Double(i + 1) / Double(max(1, sidecars.count)), detail: file.lastPathComponent)
        }
        Log.notice(.storage, "Archive verification: \(sidecars.count) files checked, \(bad.count) mismatched\(bad.isEmpty ? "" : ": " + bad.joined(separator: ", "))")
        return (sidecars.count, bad)
    }
}

enum ToolVersions {
    static func current() -> [String: String] {
        var out: [String: String] = [:]
        for (tool, arg) in [("ffmpeg", "-version"), ("SvtAv1EncApp", "--version"), ("aomenc", "--help"), ("x265", "--version"),
                            ("vvencapp", "--version"), ("dovi_tool", "--version"), ("vmaf", "--version")] where ToolLocator.isAvailable(tool) {
            let text = (try? ToolLocator.runCapturingStderr(tool, [arg])) ?? ""
            let stdout = (try? String(decoding: ToolLocator.run(tool, [arg]), as: UTF8.self)) ?? ""
            out[tool] = (stdout + text).split(separator: "\n").first.map(String.init) ?? "installed"
        }
        return out
    }
}
