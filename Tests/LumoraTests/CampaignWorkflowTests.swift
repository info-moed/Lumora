import XCTest
import AVFoundation
import ImageIO
import CryptoKit
@testable import Lumora

/// Packaging, batch, reliability and library, end to end: real clips made with FFmpeg, the real GPU and hardware
/// encoder, the real Packager remux, and every result checked with ffprobe, shasum, an XML parser or ImageIO.
/// User state touched by these features (queue.json, hdr_library_user.json, the run-rules / library / scratch
/// preferences) is saved before every test and put back afterwards; all media goes to a temporary folder.
@MainActor
final class CampaignWorkflowTests: XCTestCase {

    // MARK: - State protection

    static let root: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraCampaign-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
    }
    static let protectedFiles = ["queue.json", "hdr_library_user.json"]
    static let protectedDefaults = ["runRules", "hdrLibraryURL", "scratchRoot", "tmdbKey"]

    private var savedFiles: [String: Data?] = [:]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() async throws {
        for f in Self.protectedFiles {
            savedFiles.updateValue(try? Data(contentsOf: Self.appSupport.appendingPathComponent(f)), forKey: f)
        }
        for k in Self.protectedDefaults { savedDefaults.updateValue(UserDefaults.standard.object(forKey: k), forKey: k) }
        // Quiet, unattended rules: no Mac notifications, never pause for power, heat or hours.
        var r = RunRules()
        r.notifyMac = false; r.pauseOnBattery = false; r.pauseWhenHot = false; r.onlyBetween = false; r.webhookURL = ""
        RunRules.current = r
        let scratch = Self.root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        UserDefaults.standard.set(scratch.path, forKey: "scratchRoot")
        await PauseGate.shared.setPaused(false)
    }

    override func tearDown() async throws {
        await PauseGate.shared.setPaused(false)
        for (f, data) in savedFiles {
            let u = Self.appSupport.appendingPathComponent(f)
            if let data { try? data.write(to: u) } else { try? FileManager.default.removeItem(at: u) }
        }
        for (k, v) in savedDefaults {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    // MARK: - Process helpers

    struct Output { var status: Int32; var out: String; var err: String }

    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        var errData = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    }

    static func ff(_ args: [String]) throws {
        guard let f = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let r = try run(f, ["-hide_banner", "-loglevel", "error", "-y"] + args)
        guard r.status == 0 else { throw NSError(domain: "ffmpeg", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.err]) }
    }

    func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    func freshDir(_ label: String) throws -> URL {
        let d = Self.root.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Test media

    enum Lossless { case flac, truehd }

    /// A minimal Blu-ray PGS (.sup) stream: one 64×16 caption shown at 0.2 s and cleared at 1.5 s.
    static func pgsSup() -> Data {
        var d = Data()
        func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func seg(_ type: UInt8, pts: Int, _ payload: [UInt8]) {
            d.append(contentsOf: [0x50, 0x47] + be32(pts) + be32(0) + [type] + be16(payload.count) + payload)
        }
        let (w, h, x, y) = (64, 16, 128, 128)
        let window = [UInt8(1), 0] + be16(x) + be16(y) + be16(w) + be16(h)
        var rle: [UInt8] = []
        for _ in 0..<h { rle += [0x00, 0xC0 | UInt8(w >> 8), UInt8(w & 0xFF), 0x01, 0x00, 0x00] }
        let t1 = 18_000, t2 = 135_000          // 90 kHz clock
        seg(0x16, pts: t1, be16(1280) + be16(720) + [0x10] + be16(1) + [0x80, 0x00, 0x00, 0x01] + be16(0) + [0x00, 0x00] + be16(x) + be16(y))
        seg(0x17, pts: t1, window)
        seg(0x14, pts: t1, [0x00, 0x00, 0x01, 0xEB, 0x80, 0x80, 0xFF])
        let len = rle.count + 4
        seg(0x15, pts: t1, be16(0) + [0x00, 0xC0, UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)] + be16(w) + be16(h) + rle)
        seg(0x80, pts: t1, [])
        seg(0x16, pts: t2, be16(1280) + be16(720) + [0x10] + be16(2) + [0x00, 0x00, 0x00, 0x00])
        seg(0x17, pts: t2, window)
        seg(0x80, pts: t2, [])
        return d
    }

    static let chapterMeta = """
    ;FFMETADATA1
    title=Source Title
    artist=Jane Doe
    location=+37.3300-122.0300/
    genre=Drama
    comment=shot on my phone
    date=2019-05-01
    [CHAPTER]
    TIMEBASE=1/1000
    START=0
    END=1000
    title=Opening
    [CHAPTER]
    TIMEBASE=1/1000
    START=1000
    END=2000
    title=Middle & End

    """

    /// Writes the subtitle and metadata side files the sources are built from.
    static func sideFiles() throws -> (spa: URL, eng: URL, meta: URL, sup: URL) {
        let spa = root.appendingPathComponent("spa.srt"), eng = root.appendingPathComponent("eng.srt")
        let meta = root.appendingPathComponent("meta.txt"), sup = root.appendingPathComponent("caption.sup")
        try "1\n00:00:00,000 --> 00:00:01,000\nHola\n\n2\n00:00:01,000 --> 00:00:02,000\nMundo\n".write(to: spa, atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:01,000\nHello\n\n2\n00:00:01,000 --> 00:00:02,000\nWorld\n".write(to: eng, atomically: true, encoding: .utf8)
        try chapterMeta.write(to: meta, atomically: true, encoding: .utf8)
        try pgsSup().write(to: sup)
        return (spa, eng, meta, sup)
    }

    /// 2 s, 1280×720 at 24 fps (HD, so no SD scan-fix detection kicks in): H.264 video; lossless 5.1 (eng, default,
    /// titled, plus a private tag); AAC (fra, "Commentary"); SRT (spa, "Spanish SDH") and SRT (eng); optionally a PGS
    /// track; two titled chapters; and container tags including personal ones (artist, location, comment, date).
    static func richSource(_ name: String, lossless: Lossless = .flac, pgs: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let f = try sideFiles()
        var args = ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=2",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                    "-f", "lavfi", "-i", "sine=frequency=660:duration=2:sample_rate=48000",
                    "-i", f.spa.path, "-i", f.eng.path, "-i", f.meta.path]
        if pgs { args += ["-i", f.sup.path] }
        args += ["-filter_complex", "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a6]",
                 "-map", "0:v", "-map", "[a6]", "-map", "2:a", "-map", "3:s", "-map", "4:s"]
        if pgs { args += ["-map", "6:s"] }
        args += ["-map_metadata", "5", "-map_chapters", "5",
                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a:0", lossless == .flac ? "flac" : "truehd", "-strict", "-2",
                 "-c:a:1", "aac", "-c:s:0", "srt", "-c:s:1", "srt"]
        if pgs { args += ["-c:s:2", "copy", "-metadata:s:s:2", "language=eng", "-metadata:s:s:2", "title=Blu-ray PGS", "-disposition:s:2", "0"] }
        args += ["-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Lossless 5.1", "-metadata:s:a:0", "secret=yes",
                 "-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=Commentary",
                 "-metadata:s:s:0", "language=spa", "-metadata:s:s:0", "title=Spanish SDH",
                 "-metadata:s:s:1", "language=eng",
                 "-disposition:a:0", "default", "-disposition:a:1", "0", "-disposition:s:0", "0", "-disposition:s:1", "0",
                 url.path]
        try ff(args)
        return url
    }

    /// The same program as an MP4 (what AVFoundation opens directly): AAC 5.1 (eng, "Surround 5.1"), AAC stereo
    /// (fra, "Commentary"), two tx3g subtitle tracks (spa "Spanish SDH", eng), chapters and container tags.
    static func richMP4(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let f = try sideFiles()
        try ff(["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=2",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                "-f", "lavfi", "-i", "sine=frequency=660:duration=2:sample_rate=48000",
                "-i", f.spa.path, "-i", f.eng.path, "-i", f.meta.path,
                "-filter_complex", "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a6]",
                "-map", "0:v", "-map", "[a6]", "-map", "2:a", "-map", "3:s", "-map", "4:s", "-map_metadata", "5", "-map_chapters", "5",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-c:a", "aac", "-c:s", "mov_text",
                "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Surround 5.1",
                "-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "title=Commentary",
                "-metadata:s:s:0", "language=spa", "-metadata:s:s:0", "title=Spanish SDH", "-metadata:s:s:1", "language=eng",
                url.path])
        return url
    }

    /// HD SDR clip with stereo AAC and one subtitle track (tx3g in MP4, SubRip in MKV), as a phone or web file would have.
    static func simpleSource(_ name: String, seconds: Int = 2) throws -> URL {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let eng = root.appendingPathComponent("simple.srt")
        try "1\n00:00:00,000 --> 00:00:01,000\nHello\n".write(to: eng, atomically: true, encoding: .utf8)
        var args = ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=\(seconds)",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=48000", "-i", eng.path,
                    "-map", "0:v", "-map", "1:a", "-map", "2:s", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-c:a", "aac", "-ac", "2"]
        args += url.pathExtension == "mkv" ? ["-c:s", "srt"] : ["-c:s", "mov_text"]
        args += ["-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "language=eng", "-metadata", "artist=Jane Doe", url.path]
        try ff(args)
        return url
    }

    /// Inspect → analyze → presets → job, the way AppModel's batch path does it. The container follows the app's
    /// own rule: QuickTime for hardware codecs when AVFoundation reads the source, otherwise Matroska.
    func makeJob(_ src: URL, delivery: DeliveryFormat, codec: Codec, out base: URL) async throws -> ExportJob {
        let (d, colors) = try await SourceInspector.inspect(src)
        let color = try XCTUnwrap(colors.first)
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        let presets = AutoPresetEngine.generate(colors: colors, analysis: a, report: nil)
        let preset = try XCTUnwrap(presets.first(where: \.recommended) ?? presets.first)
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = codec.defaultContainer == "mov" && d.kind != .avfoundation ? "mkv" : codec.defaultContainer
        var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                            outputURL: base.appendingPathExtension(ext))
        job.chroma = codec.chromaFormats.first ?? .c420
        job.bitDepth = codec.bitDepths.first ?? 10
        return job
    }

    static var exportCache: [String: URL] = [:]

    /// A real export (GPU grade + hardware encode) of `src`, made once per test run. `name` has no extension.
    func export(_ src: URL, codec: Codec = .hevc, name: String) async throws -> URL {
        if codec == .hevc { try TestHardware.requireHardwareHEVC() } else { try TestHardware.requireProRes() }
        if let u = Self.exportCache[name], FileManager.default.fileExists(atPath: u.path) { return u }
        let job = try await makeJob(src, delivery: .sdr, codec: codec, out: Self.root.appendingPathComponent("exports/\(name)"))
        let url = try await ExportEngine().run(job) { _, _ in }
        Self.exportCache[name] = url
        return url
    }

    // MARK: - Probing

    struct Media {
        var streams: [[String: Any]]
        var format: [String: Any]
        var chapters: [[String: Any]]
        func of(_ type: String) -> [[String: Any]] { streams.filter { $0["codec_type"] as? String == type } }
        var globalTags: [String: String] { CampaignWorkflowTests.userTags(format["tags"]) }
    }

    static func media(_ url: URL) throws -> Media {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let r = try run(ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", "-show_chapters", url.path])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any], "ffprobe: \(r.err)")
        return Media(streams: root["streams"] as? [[String: Any]] ?? [], format: root["format"] as? [String: Any] ?? [:],
                     chapters: root["chapters"] as? [[String: Any]] ?? [])
    }

    /// Tags as written by the source or the user: lower-cased keys, with the bookkeeping a muxer adds on its own
    /// (brands, handler names, durations, the "Lavf…" encoder stamp) taken out. MP4 reads track titles back as "name".
    nonisolated static func userTags(_ any: Any?) -> [String: String] {
        var t: [String: String] = [:]
        for (k, v) in (any as? [String: Any]) ?? [:] { t[k.lowercased()] = "\(v)" }
        for k in ["major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id", "duration"] { t[k] = nil }
        if let e = t["encoder"], e.hasPrefix("Lav") { t["encoder"] = nil }
        if let n = t.removeValue(forKey: "name"), t["title"] == nil { t["title"] = n }
        return t
    }

    nonisolated static func tags(_ stream: [String: Any]) -> [String: String] { userTags(stream["tags"]) }

    static func facts(poster: Data?) -> Packager.Facts {
        Packager.Facts(title: "Alpha Film", resolution: "180p", hdr: "SDR", codec: "HEVC", appVersion: "0.11.1-test",
                       settings: ["look": "natural", "frames": 48, "fps": "24/1"],
                       qualityLines: ["VMAF mean 96.20", "Chunk 1: passed"],
                       hdrReport: ["Peak about 100 nits", "Verdict: SDR video"],
                       logLines: ["12:00 started", "12:01 finished"], posterJPEG: poster)
    }

    func package(_ exported: URL, source: URL, _ o: PackagingOptions, into dest: URL, poster: Data? = nil) async throws -> Packager.Result {
        try await Packager.package(exported: exported, source: source, streams: SourceStreams.probe(source), options: o,
                                   destination: dest, facts: Self.facts(poster: poster), progress: ProgressReporter(task: nil))
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Packager: Plex movie, remove personal details, track subset, DD+ track, chapters, every appendix

    func testPlexMovieWithEditionRemovesPersonalTagsKeepsChosenTracksAndWritesEveryAppendix() async throws {
        let src = try Self.richSource("Alpha.Film.2001.1080p.BluRay.mkv")
        let exported = try await export(src, name: "alpha")
        XCTAssertEqual(exported.pathExtension, "mkv", "an FFmpeg-read source exports to Matroska")
        let dest = try freshDir("movie")
        let posterURL = Self.root.appendingPathComponent("poster-src.jpg")
        try Self.ff(["-i", src.path, "-frames:v", "1", "-q:v", "3", posterURL.path])
        let poster = try Data(contentsOf: posterURL)

        var o = PackagingOptions()
        o.naming = .plexMovie
        o.metadataPolicy = .removePersonal
        o.bespoke.edition = "Director's Cut"
        o.bespoke.description = "Tom & Jerry <uncut> \"quoted\""
        o.bespoke.custom = [BespokeMetadata.KeyValue(key: "purpose", value: "archive")]
        o.keepAudio = [1]                 // the lossless 5.1 only (drop the French commentary)
        o.keepSubtitles = [3]             // Spanish only
        o.addCompatibilityTrack = true
        o.keepChapters = true
        o.appendices = Set(Appendix.allCases)
        o.verifyAfterExport = true
        let r = try await package(exported, source: src, o, into: dest, poster: poster)

        // Name and folder.
        let rel = "Alpha Film (2001)/Alpha Film (2001) {edition-Director's Cut} - 180p SDR HEVC.mkv"
        XCTAssertEqual(r.video.path, dest.appendingPathComponent(rel).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.video.path))

        // Tracks.
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("video").map { $0["codec_name"] as? String }, ["hevc"])
        XCTAssertEqual(try EndToEndTests.probe(r.video).frames, 48)
        let audio = m.of("audio")
        XCTAssertEqual(audio.map { $0["codec_name"] as? String }, ["flac", "eac3"])
        XCTAssertEqual(audio.map { $0["channels"] as? Int }, [6, 6])
        XCTAssertEqual(audio.map { Self.tags($0) }, [["language": "eng", "title": "Lossless 5.1"],
                                                    ["language": "eng", "title": "Compatibility (Dolby Digital Plus)"]],
                       "only languages and titles survive on audio tracks; the private tag must go")
        let subs = m.of("subtitle")
        XCTAssertEqual(subs.map { $0["codec_name"] as? String }, ["subrip"])
        XCTAssertEqual(subs.map { Self.tags($0) }, [["language": "spa", "title": "Spanish SDH"]],
                       "subtitle language and title are what players need")
        for v in m.of("video") {
            var t = Self.tags(v); if t["language"] == "und" { t["language"] = nil }
            XCTAssertEqual(t, [:], "no tags on the video track")
        }

        // Global tags: allowlisted source tags, the existing title, and what the user typed. Nothing personal.
        XCTAssertEqual(m.globalTags, ["title": "Source Title", "genre": "Drama", "description": "Tom & Jerry <uncut> \"quoted\"",
                                      "purpose": "archive"])

        // Chapters kept with their titles.
        XCTAssertEqual(m.chapters.map { ($0["tags"] as? [String: Any])?["title"] as? String }, ["Opening", "Middle & End"])

        // Verification and checksum.
        XCTAssertEqual(r.verified, true)
        XCTAssertEqual(r.sha256, try sha256(r.video))

        // Every appendix.
        let base = r.video.deletingPathExtension().path
        func appendix(_ a: Appendix) -> URL { URL(fileURLWithPath: base + a.fileSuffix) }
        XCTAssertEqual(Set(r.appendices.map(\.path)), Set(Appendix.allCases.map { appendix($0).path }))

        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: appendix(.settings))) as? [String: Any])
        XCTAssertEqual(settings["output"] as? String, r.video.lastPathComponent)
        XCTAssertEqual(settings["sha256"] as? String, r.sha256)
        XCTAssertEqual(settings["verified"] as? String, "passed")
        XCTAssertEqual(settings["app"] as? String, "0.11.1-test")
        XCTAssertEqual(settings["look"] as? String, "natural")
        XCTAssertEqual(settings["frames"] as? Int, 48)
        XCTAssertTrue(((settings["tools"] as? [String: String])?["ffmpeg"] ?? "").hasPrefix("ffmpeg version"), "\(settings["tools"] ?? "")")

        let quality = try String(contentsOf: appendix(.qualityReport), encoding: .utf8)
        XCTAssertEqual(quality, "Quality report for \(r.video.lastPathComponent)\n\nVMAF mean 96.20\nChunk 1: passed")

        let sums = try String(contentsOf: appendix(.checksums), encoding: .utf8)
        XCTAssertEqual(sums, "\(r.sha256 ?? "")  \(r.video.lastPathComponent)\n")
        let check = try Self.run("/usr/bin/shasum", ["-a", "256", "-c", appendix(.checksums).lastPathComponent], cwd: r.video.deletingLastPathComponent())
        XCTAssertEqual(check.status, 0, check.out + check.err)
        XCTAssertEqual(check.out.trimmingCharacters(in: .whitespacesAndNewlines), "\(r.video.lastPathComponent): OK")

        let nfoText = try String(contentsOf: appendix(.nfo), encoding: .utf8)
        XCTAssertTrue(nfoText.contains("&amp;") && nfoText.contains("&lt;uncut&gt;"), nfoText)
        let lint = try Self.run("/usr/bin/xmllint", ["--noout", appendix(.nfo).path])
        XCTAssertEqual(lint.status, 0, lint.err)
        let nfo = try XMLDocument(contentsOf: appendix(.nfo), options: [])
        XCTAssertEqual(nfo.rootElement()?.name, "movie")
        func el(_ name: String) -> String? { nfo.rootElement()?.elements(forName: name).first?.stringValue }
        XCTAssertEqual(el("title"), "Alpha Film")
        XCTAssertEqual(el("year"), "2001")
        XCTAssertEqual(el("edition"), "Director's Cut")
        XCTAssertEqual(el("plot"), "Tom & Jerry <uncut> \"quoted\"")

        let posterOut = try Data(contentsOf: appendix(.poster))
        XCTAssertEqual(Array(posterOut.prefix(3)), [0xFF, 0xD8, 0xFF], "poster must be a JPEG")
        let img = try XCTUnwrap(CGImageSourceCreateWithData(posterOut as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(img.width, 1280); XCTAssertEqual(img.height, 720)

        XCTAssertEqual(try String(contentsOf: appendix(.chapters), encoding: .utf8), "00:00:00  Opening\n00:00:01  Middle & End")
        XCTAssertEqual(try String(contentsOf: appendix(.hdrReport), encoding: .utf8), "Peak about 100 nits\nVerdict: SDR video")
        XCTAssertEqual(try String(contentsOf: appendix(.log), encoding: .utf8), "12:00 started\n12:01 finished")
    }

    // MARK: - Packager: Plex TV, keep metadata, all tracks, chapters dropped

    func testPlexTVKeepsAllMetadataAndTracksAndDropsChapters() async throws {
        let src = try Self.richSource("The.Show.S02E05.mkv")
        let exported = try await export(src, name: "show")
        let dest = try freshDir("tv")
        var o = PackagingOptions()
        o.naming = .plexTV
        o.metadataPolicy = .keep
        o.bespoke.episodeTitle = "Pilot & Co"
        o.keepAudio = []; o.keepSubtitles = []
        o.addCompatibilityTrack = false
        o.keepChapters = false
        o.appendices = [.nfo, .chapters, .checksums]
        o.verifyAfterExport = true
        let r = try await package(exported, source: src, o, into: dest)

        XCTAssertEqual(r.video.path, dest.appendingPathComponent("The Show/Season 02/The Show - S02E05 - Pilot & Co - 180p SDR.mkv").path)
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("audio").map { $0["codec_name"] as? String }, ["flac", "aac"])
        XCTAssertEqual(m.of("audio").map { Self.tags($0)["language"] }, ["eng", "fra"])
        XCTAssertEqual(m.of("audio").map { Self.tags($0)["title"] }, ["Lossless 5.1", "Commentary"])
        XCTAssertEqual(m.of("audio").first.map { Self.tags($0)["secret"] }, "yes", "keep means keep, track tags included")
        XCTAssertEqual(m.of("subtitle").map { $0["codec_name"] as? String }, ["subrip", "subrip"])
        XCTAssertEqual(m.of("subtitle").map { Self.tags($0)["language"] }, ["spa", "eng"])
        XCTAssertEqual(m.of("subtitle").first.map { Self.tags($0)["title"] }, "Spanish SDH")
        XCTAssertEqual(m.chapters.count, 0, "chapters were switched off")
        let g = m.globalTags
        XCTAssertEqual(g["title"], "Source Title")
        XCTAssertEqual(g["artist"], "Jane Doe")
        XCTAssertEqual(g["genre"], "Drama")
        XCTAssertEqual(g["comment"], "shot on my phone")
        XCTAssertEqual(g["location"], "+37.3300-122.0300/")
        XCTAssertEqual(g["date"], "2019-05-01")
        XCTAssertEqual(r.verified, true)

        let nfo = try XMLDocument(contentsOf: URL(fileURLWithPath: r.video.deletingPathExtension().path + ".nfo"), options: [])
        XCTAssertEqual(nfo.rootElement()?.name, "episodedetails")
        func el(_ n: String) -> String? { nfo.rootElement()?.elements(forName: n).first?.stringValue }
        XCTAssertEqual(el("title"), "Pilot & Co")
        XCTAssertEqual(el("showtitle"), "The Show")
        XCTAssertEqual(el("season"), "02")
        XCTAssertEqual(el("episode"), "05")
        // The file has no chapters, so there is no chapter list to write.
        XCTAssertFalse(r.appendices.contains { $0.lastPathComponent.hasSuffix(".chapters.txt") }, "\(r.appendices)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.video.deletingPathExtension().path + ".chapters.txt"))
    }

    // MARK: - Packager: keep original name, custom pattern (+ remove everything), rename (sanitized, contained)

    func testKeepOriginalCustomPatternAndRenameNamingIntoMP4() async throws {
        let src = try Self.richMP4("Alpha.Film.2001.1080p.WEB.mp4")
        let streams = SourceStreams.probe(src)
        XCTAssertEqual(streams.audio.map(\.title), ["Surround 5.1", "Commentary"], "MP4 track titles are read")
        XCTAssertEqual(streams.subtitles.map(\.title), ["Spanish SDH", ""])
        XCTAssertEqual(streams.chapters, 2)
        let exported = try await export(src, name: "alpha-mp4")
        XCTAssertEqual(exported.pathExtension, "mov", "AVFoundation source → QuickTime export")

        var o = PackagingOptions()
        o.appendices = []; o.verifyAfterExport = false; o.addCompatibilityTrack = false

        o.naming = .keep
        let d1 = try freshDir("keep")
        let r1 = try await package(exported, source: src, o, into: d1)
        XCTAssertEqual(r1.video.path, d1.appendingPathComponent("Alpha.Film.2001.1080p.WEB.mp4").path)
        XCTAssertNil(r1.verified); XCTAssertNil(r1.sha256); XCTAssertEqual(r1.appendices, [])
        XCTAssertEqual(try Self.media(r1.video).of("subtitle").map { $0["codec_name"] as? String }, ["mov_text", "mov_text"])

        o.naming = .custom
        o.customTemplate = "{title} [{resolution}] {codec} {imdb}"
        o.bespoke.imdbID = "tt0123456"
        o.metadataPolicy = .removeAll
        let d2 = try freshDir("custom")
        let r2 = try await package(exported, source: src, o, into: d2)
        XCTAssertEqual(r2.video.path, d2.appendingPathComponent("Alpha Film [180p] HEVC tt0123456.mp4").path)
        let m = try Self.media(r2.video)
        // "Remove everything": the source's own title, genre and personal tags are gone; only what Lumora writes on
        // the user's behalf (the title from the file name, the IMDb ID typed in) plus track languages and titles stay.
        XCTAssertEqual(m.globalTags, ["title": "Alpha Film", "imdb": "tt0123456"])
        XCTAssertEqual(m.of("audio").map { Self.tags($0) }, [["language": "eng", "title": "Surround 5.1"], ["language": "fra", "title": "Commentary"]])
        XCTAssertEqual(m.of("subtitle").map { Self.tags($0) }, [["language": "spa", "title": "Spanish SDH"], ["language": "eng"]])
        XCTAssertEqual(m.chapters.map { ($0["tags"] as? [String: Any])?["title"] as? String }, ["Opening", "Middle & End"],
                       "chapter titles are not personal data")
        XCTAssertTrue(Verifier.decodesCleanly(r2.video), "an MP4 with chapters and subtitles must verify")

        o.outputName = "Finished/My: Cut?"
        let d3 = try freshDir("rename")
        let r3 = try await package(exported, source: src, o, into: d3)
        XCTAssertEqual(r3.video.path, d3.appendingPathComponent("Finished/My- Cut-.mp4").path)

        o.outputName = "../../../escape/evil"
        let d4 = try freshDir("contained")
        let r4 = try await package(exported, source: src, o, into: d4)
        XCTAssertTrue(r4.video.standardizedFileURL.path.hasPrefix(d4.standardizedFileURL.path + "/"), r4.video.path)
        XCTAssertEqual(r4.video.lastPathComponent, "evil.mp4")
    }

    // MARK: - Packager: MP4 text subtitles into MKV (export join and packaging)

    func testMP4TextSubtitlesSurviveAMatroskaExportAndPackage() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.richMP4("Theta.Film.2009.mp4")
        // An MP4 source exported to Matroska (what the app does for any source it decodes with FFmpeg, e.g. an SD
        // file that needs deinterlacing): the tx3g subtitles must be carried as SubRip, not fail the whole export.
        var job = try await makeJob(src, delivery: .sdr, codec: .hevc, out: try freshDir("mkvjoin").appendingPathComponent("theta"))
        job.outputURL = job.outputURL.deletingPathExtension().appendingPathExtension("mkv")
        let exported = try await ExportEngine().run(job) { _, _ in }
        let e = try Self.media(exported)
        XCTAssertEqual(e.of("subtitle").map { $0["codec_name"] as? String }, ["subrip", "subrip"])
        XCTAssertEqual(try EndToEndTests.probe(exported).frames, 48)

        var o = PackagingOptions()
        o.appendices = []; o.verifyAfterExport = true
        let r = try await package(exported, source: src, o, into: try freshDir("mkvpack"))
        XCTAssertEqual(r.video.pathExtension, "mkv")
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("subtitle").map { $0["codec_name"] as? String }, ["subrip", "subrip"])
        XCTAssertEqual(m.of("subtitle").map { Self.tags($0)["language"] }, ["spa", "eng"])
        XCTAssertEqual(r.verified, true)
    }

    // MARK: - Packager: bitmap subtitles force MKV

    func testBitmapSubtitlesForceMKVAndTextOnlyStaysMP4() async throws {
        let src = try Self.richSource("Pgs.Film.2003.mkv", pgs: true)
        let streams = SourceStreams.probe(src)
        XCTAssertEqual(streams.subtitles.map(\.codec), ["subrip", "subrip", "hdmv_pgs_subtitle"])
        XCTAssertEqual(streams.subtitles.map(\.isBitmapSubtitle), [false, false, true])
        // The container rule is about the export's container, so feed the Packager a QuickTime export of the same
        // length (real hardware HEVC) with this source's tracks.
        let exported = try await export(try Self.simpleSource("Iota.Film.2010.mp4"), name: "iota")
        XCTAssertEqual(exported.pathExtension, "mov")

        var o = PackagingOptions()
        o.appendices = []; o.addCompatibilityTrack = false; o.verifyAfterExport = true
        let r = try await package(exported, source: src, o, into: try freshDir("pgs"))
        XCTAssertEqual(r.video.pathExtension, "mkv", "PGS only fits in MKV")
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("subtitle").map { $0["codec_name"] as? String }, ["subrip", "subrip", "hdmv_pgs_subtitle"])
        XCTAssertEqual(m.of("subtitle").last.map { Self.tags($0)["title"] }, "Blu-ray PGS")
        XCTAssertEqual(m.of("video").map { $0["codec_name"] as? String }, ["hevc"])
        XCTAssertEqual(r.verified, true)

        o.keepSubtitles = [3]
        let r2 = try await package(exported, source: src, o, into: try freshDir("pgs-text"))
        XCTAssertEqual(r2.video.pathExtension, "mp4", "text subtitles only: MP4 with tx3g")
        XCTAssertEqual(try Self.media(r2.video).of("subtitle").map { $0["codec_name"] as? String }, ["mov_text"])
        XCTAssertEqual(r2.verified, true)
    }

    // MARK: - Packager: TrueHD source gets a Dolby Digital Plus compatibility track

    func testTrueHDSourceGetsAudibleDDPlusCompatibilityTrack() async throws {
        let src = try Self.richSource("Gamma.Film.2004.mkv", lossless: .truehd)
        let streams = SourceStreams.probe(src)
        XCTAssertEqual(streams.audio.first?.codec, "truehd")
        XCTAssertEqual(streams.audio.first?.channels, 6)
        XCTAssertEqual(streams.audio.first?.needsCompatibilityTrack, true)
        XCTAssertEqual(streams.audio.first?.isDefault, true)
        let exported = try await export(src, name: "gamma")

        var o = PackagingOptions()
        o.appendices = []; o.addCompatibilityTrack = true; o.verifyAfterExport = true
        o.keepAudio = [1]
        let r = try await package(exported, source: src, o, into: try freshDir("truehd"))
        XCTAssertEqual(r.video.pathExtension, "mkv")
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("audio").map { $0["codec_name"] as? String }, ["truehd", "eac3"])
        XCTAssertEqual(m.of("audio").map { $0["channels"] as? Int }, [6, 6])
        XCTAssertEqual(m.of("audio").last.map { Self.tags($0)["title"] }, "Compatibility (Dolby Digital Plus)")
        XCTAssertEqual(m.of("audio").last.map { Self.tags($0)["language"] }, "eng")
        XCTAssertEqual(r.verified, true)
        // The DD+ track must carry the actual sound, not silence.
        let f = try XCTUnwrap(EndToEndTests.ffmpeg)
        let vol = try Self.run(f, ["-hide_banner", "-i", r.video.path, "-map", "0:a:1", "-af", "volumedetect", "-f", "null", "-"])
        let mean = vol.err.components(separatedBy: "mean_volume:").last?.split(separator: "d").first
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertNotNil(mean, vol.err)
        XCTAssertGreaterThan(mean ?? -999, -40, "compatibility track is silent")

        // A QuickTime export with a TrueHD source can't become an MP4 (FFmpeg refuses TrueHD there): MKV instead.
        let mov = try await export(try Self.simpleSource("Iota.Film.2010.mp4"), name: "iota")
        let r2 = try await package(mov, source: src, o, into: try freshDir("truehd-mov"))
        XCTAssertEqual(r2.video.pathExtension, "mkv")
        XCTAssertEqual(try Self.media(r2.video).of("audio").map { $0["codec_name"] as? String }, ["truehd", "eac3"])
        XCTAssertEqual(r2.verified, true)
    }

    // MARK: - Packager: ProRes export

    func testProResExportPackagesIntoACompatibleContainer() async throws {
        let src = try Self.simpleSource("Delta.Film.2005.mp4")
        let exported = try await export(src, codec: .prores422HQ, name: "delta")
        XCTAssertEqual(exported.pathExtension, "mov")
        XCTAssertEqual(try EndToEndTests.probe(exported).codec, "prores")
        var o = PackagingOptions()
        o.appendices = [.checksums]; o.verifyAfterExport = true
        let r = try await package(exported, source: src, o, into: try freshDir("prores"))
        XCTAssertEqual(r.video.pathExtension, "mov", "ProRes can't go in MP4; it stays a QuickTime movie")
        let p = try EndToEndTests.probe(r.video)
        XCTAssertEqual(p.codec, "prores"); XCTAssertEqual(p.frames, 48)
        let m = try Self.media(r.video)
        XCTAssertEqual(m.of("audio").map { $0["codec_name"] as? String }, ["aac"])
        XCTAssertEqual(m.of("subtitle").map { $0["codec_name"] as? String }, ["mov_text"])
        XCTAssertNil(m.globalTags["artist"], "personal tag removed by default")
        XCTAssertEqual(r.verified, true)
    }

    // MARK: - Verification and archive checks

    func testVerifyAfterExportDetectsCorruptedFile() async throws {
        let src = try Self.simpleSource("Epsilon.Film.2006.mp4")
        let exported = try await export(src, name: "epsilon")
        XCTAssertTrue(Verifier.decodesCleanly(exported), "a clean export must verify")

        // Damage the middle of the picture data the way a bad sector would.
        let bad = Self.root.appendingPathComponent("exports/epsilon-damaged.\(exported.pathExtension)")
        try? FileManager.default.removeItem(at: bad)
        try FileManager.default.copyItem(at: exported, to: bad)
        let h = try FileHandle(forUpdating: bad)
        let size = try h.seekToEnd()
        var rng: UInt64 = 0x9E3779B97F4A7C15
        for fraction in [0.25, 0.4, 0.55, 0.7] {
            try h.seek(toOffset: UInt64(Double(size) * fraction))
            var junk = Data(count: 2048)
            for i in 0..<junk.count { rng = rng &* 6364136223846793005 &+ 1442695040888963407; junk[i] = UInt8(truncatingIfNeeded: rng >> 33) }
            try h.write(contentsOf: junk)
        }
        try h.close()
        XCTAssertFalse(Verifier.decodesCleanly(bad), "decoding a damaged file must fail verification")

        var o = PackagingOptions()
        o.appendices = []; o.verifyAfterExport = true
        let r = try await package(bad, source: src, o, into: try freshDir("damaged"))
        XCTAssertEqual(r.verified, false, "packaging a damaged export must report verification FAILED")
        let ok = try await package(exported, source: src, o, into: try freshDir("undamaged"))
        XCTAssertEqual(ok.verified, true)
    }

    func testArchiveVerifyFlagsModifiedFile() async throws {
        let src = try Self.simpleSource("Zeta.Film.2007.mp4")
        let exported = try await export(src, name: "zeta")
        let archive = try freshDir("archive")
        var o = PackagingOptions()
        o.appendices = [.checksums]; o.verifyAfterExport = false
        let a = try await package(exported, source: src, o, into: archive)
        o.naming = .keep
        let b = try await package(exported, source: src, o, into: archive)
        XCTAssertNotEqual(a.video, b.video)

        let clean = await Verifier.verifyFolder(archive, progress: ProgressReporter(task: nil))
        XCTAssertEqual(clean.checked, 2); XCTAssertEqual(clean.bad, [])

        // Flip one byte in one of them.
        let h = try FileHandle(forUpdating: b.video)
        let size = try h.seekToEnd()
        try h.seek(toOffset: size / 2)
        let byte = try XCTUnwrap(try h.read(upToCount: 1)).first ?? 0
        try h.seek(toOffset: size / 2)
        try h.write(contentsOf: Data([byte ^ 0xFF]))
        try h.close()

        let dirty = await Verifier.verifyFolder(archive, progress: ProgressReporter(task: nil))
        XCTAssertEqual(dirty.checked, 2)
        XCTAssertEqual(dirty.bad, [b.video.lastPathComponent])
        let shasum = try Self.run("/usr/bin/shasum", ["-a", "256", "-c", b.video.deletingPathExtension().lastPathComponent + ".sha256"],
                                  cwd: b.video.deletingLastPathComponent())
        XCTAssertNotEqual(shasum.status, 0, "shasum agrees the file changed")
    }

    // MARK: - AppModel: export + packageExport (GPU poster, settings, privacy scrub)

    func testAppModelPackagesAnExportWithPosterSettingsAndScrubbedLog() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try Self.richSource("Alpha.Film.2001.1080p.BluRay.mkv")
        let model = AppModel()
        model.open(src)
        let opened = try await waitUntil(60) { !model.presets.isEmpty || model.errorMessage != nil }
        XCTAssertTrue(opened); XCTAssertNil(model.errorMessage)
        _ = try await waitUntil(20) { model.progress == nil }
        XCTAssertEqual(model.sourceStreams.audio.count, 2)
        XCTAssertEqual(model.sourceStreams.subtitles.count, 2)
        XCTAssertEqual(model.sourceStreams.chapters, 2)
        XCTAssertEqual(model.packaging.bespoke.title, "Alpha Film")
        XCTAssertEqual(model.packaging.bespoke.year, "2001")

        model.delivery = .sdr; model.codec = .hevc
        model.packaging.appendices = Set(Appendix.allCases)
        model.packaging.metadataPolicy = .removePersonal
        var job = try XCTUnwrap(model.draftJob())
        let folder = try freshDir("appmodel")
        job.outputURL = folder.appendingPathComponent("intermediate.mkv")   // what export() picks for an FFmpeg-read source
        let started = Date()
        let url = try await ExportEngine().run(job) { _, _ in }
        await model.packageExport(url, folder: folder, job: job, startedAt: started)
        XCTAssertNil(model.errorMessage)
        let r = try XCTUnwrap(model.lastPackage)
        XCTAssertEqual(r.video.path, folder.appendingPathComponent("Alpha Film (2001)/Alpha Film (2001) - 720p SDR HEVC.mkv").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the intermediate export is removed once packaged")
        XCTAssertEqual(r.verified, true)

        let base = r.video.deletingPathExtension().path
        let poster = try Data(contentsOf: URL(fileURLWithPath: base + Appendix.poster.fileSuffix))
        let img = try XCTUnwrap(CGImageSourceCreateWithData(poster as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(img.width, 1000, "graded poster frame rendered on the GPU")
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: base + ".lumora.json"))) as? [String: Any])
        XCTAssertEqual(settings["source"] as? String, src.lastPathComponent, "no full source path when personal details are removed")
        XCTAssertEqual(settings["codec"] as? String, Codec.hevc.rawValue)
        XCTAssertEqual(settings["frames"] as? Int, model.descriptor?.frameCount)
        XCTAssertNotNil(settings["gradeParameters"] as? [String: Any])
        let log = try String(contentsOf: URL(fileURLWithPath: base + ".log"), encoding: .utf8)
        XCTAssertFalse(log.contains(NSHomeDirectory()), "home folder (account name) scrubbed from the log")
        let hdr = try String(contentsOf: URL(fileURLWithPath: base + ".hdr-report.txt"), encoding: .utf8)
        XCTAssertFalse(hdr.isEmpty)
    }

    // MARK: - Batch: queue persistence, cancel mid-way, resume skipping finished files

    func testBatchQueuePersistsAndResumesAfterCancelSkippingFinishedFiles() async throws {
        try TestHardware.requireHardwareHEVC()
        let input = try freshDir("batch-in"), output = try freshDir("batch-out")
        var files: [URL] = []
        for name in ["Alpha.Film.2001.mp4", "Beta.Film.2002.mp4", "The.Show.S01E02.mkv"] {
            let s = try Self.simpleSource("batch-" + name, seconds: 2)
            let f = input.appendingPathComponent(name)
            try FileManager.default.copyItem(at: s, to: f)
            files.append(f)
        }
        try? FileManager.default.removeItem(at: Self.appSupport.appendingPathComponent("queue.json"))

        let model = AppModel()
        model.delivery = .sdr; model.codec = .hevc; model.useTargetQuality = false
        model.packaging.appendices = [.settings, .checksums, .nfo]
        model.packaging.verifyAfterExport = true

        // What batchProcess() does once the two folder panels return.
        QueueStore.enqueue(files, folder: output)
        XCTAssertEqual(QueueStore.load().map(\.source), files.map(\.path))
        XCTAssertEqual(QueueStore.load().map(\.done), [false, false, false])
        XCTAssertEqual(QueueStore.pendingFolder?.path, output.path)
        XCTAssertEqual(QueueStore.pending.map(\.path), files.map(\.path))

        model.resumePendingBatch()
        XCTAssertEqual(model.status, "Batch: 3 files")
        let firstDone = try await waitUntil(120) { QueueStore.load().first?.done == true || model.errorMessage != nil }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(firstDone, "first file never finished (status: \(model.status))")
        model.cancel()
        let stopped = try await waitUntil(60) { model.progress == nil }
        XCTAssertTrue(stopped)
        XCTAssertEqual(model.status, "Canceled")
        XCTAssertNil(model.errorMessage, "a user cancel is not an error")

        let afterCancel = QueueStore.load()
        XCTAssertEqual(afterCancel.count, 3)
        XCTAssertTrue(afterCancel[0].done)
        XCTAssertFalse(afterCancel[2].done, "cancel must stop the batch before the last file")
        let first = try XCTUnwrap(afterCancel[0].output.map(URL.init(fileURLWithPath:)))
        XCTAssertEqual(first.path, output.appendingPathComponent("Alpha Film (2001)/Alpha Film (2001) - 720p SDR HEVC.mp4").path)
        let firstDate = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date)
        let pendingNow = QueueStore.pending
        XCTAssertFalse(pendingNow.contains(files[0]), "finished files are not pending")
        // A partly written intermediate for the interrupted file would otherwise go to the Trash on resume.
        for f in (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
        where ["mov", "mkv", "mp4"].contains(f.pathExtension) {
            print("CampaignWorkflowTests: leftover after cancel: \(f.lastPathComponent)")
            try? FileManager.default.removeItem(at: f)
        }

        // Relaunch-style resume.
        let resumed = AppModel()
        resumed.delivery = .sdr; resumed.codec = .hevc; resumed.useTargetQuality = false
        resumed.packaging = model.packaging
        resumed.resumePendingBatch()
        XCTAssertEqual(resumed.status, "Batch: \(pendingNow.count) files")
        let finished = try await waitUntil(180) { resumed.progress == nil }
        XCTAssertTrue(finished)
        XCTAssertNil(resumed.errorMessage)
        XCTAssertEqual(resumed.status, "Batch finished: \(pendingNow.count) files")
        XCTAssertEqual(QueueStore.load().map(\.done), [true, true, true])
        XCTAssertNil(QueueStore.pendingFolder)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date, firstDate,
                       "the finished file was not redone")

        let expected = ["Alpha Film (2001)/Alpha Film (2001) - 720p SDR HEVC.mp4",
                        "Beta Film (2002)/Beta Film (2002) - 720p SDR HEVC.mp4",
                        "The Show/Season 01/The Show - S01E02 - 720p SDR.mkv"]
        XCTAssertEqual(QueueStore.load().compactMap(\.output), expected.map { output.appendingPathComponent($0).path })
        for rel in expected {
            let u = output.appendingPathComponent(rel)
            let p = try EndToEndTests.probe(u)
            XCTAssertEqual(p.codec, "hevc", rel); XCTAssertEqual(p.frames, 48, rel)
            XCTAssertEqual(try Self.media(u).of("audio").count, 1, rel)
            let s = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: u.deletingPathExtension().path + ".lumora.json"))) as? [String: Any])
            XCTAssertEqual(s["verified"] as? String, "passed", rel)
            XCTAssertEqual(s["sha256"] as? String, try sha256(u), rel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: u.deletingPathExtension().path + ".nfo"), rel)
        }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath }
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [], "intermediate encodes are cleaned up")
        let tv = try XMLDocument(contentsOf: output.appendingPathComponent("The Show/Season 01/The Show - S01E02 - 720p SDR.nfo"), options: [])
        XCTAssertEqual(tv.rootElement()?.name, "episodedetails")
    }

    // MARK: - Run rules and the pause gate

    func testRunRulesPersistAndScheduleWindows() {
        var r = RunRules()
        r.onlyBetween = true; r.startHour = 9; r.endHour = 17; r.pauseOnBattery = false; r.pauseWhenHot = true
        r.notifyMac = false; r.webhookURL = "http://127.0.0.1:9/x"
        RunRules.current = r
        XCTAssertEqual(RunRules.current, r)
        let at = { (h: Int) in Calendar.current.date(bySettingHour: h, minute: 30, second: 0, of: Date())! }
        XCTAssertEqual([8, 9, 12, 16, 17, 23].map { PauseGate.inWindow(r, now: at($0)) }, [false, true, true, true, false, false])
        r.startHour = 22; r.endHour = 6
        XCTAssertEqual([21, 22, 23, 0, 5, 6, 12].map { PauseGate.inWindow(r, now: at($0)) }, [false, true, true, true, true, false, false])
        UserDefaults.standard.set(Data("not json".utf8), forKey: "runRules")
        XCTAssertEqual(RunRules.current, RunRules(), "unreadable rules fall back to the defaults")
    }

    func testPauseGatePausesAndResumes() async throws {
        let gate = PauseGate.shared
        let reason0 = await gate.reason()
        XCTAssertNil(reason0)

        // Outside the allowed hours.
        let h = Calendar.current.component(.hour, from: Date())
        var r = RunRules.current
        r.onlyBetween = true; r.startHour = (h + 1) % 24; r.endHour = (h + 2) % 24
        RunRules.current = r
        let waiting = await gate.reason()
        XCTAssertEqual(waiting, "Waiting for \((h + 1) % 24):00")
        r.startHour = h; r.endHour = (h + 1) % 24
        RunRules.current = r
        let inside = await gate.reason()
        XCTAssertNil(inside)
        r.onlyBetween = false; RunRules.current = r

        // User pause through the app model, then resume.
        let model = AppModel()
        model.paused = true
        var why: String?
        for _ in 0..<20 { why = await gate.reason(); if why != nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(why, "Paused")
        let passed = Flag()
        let waiter = Task { await gate.wait(); await passed.set() }
        try await Task.sleep(nanoseconds: 600_000_000)
        let early = await passed.value
        XCTAssertFalse(early, "work must hold while paused")
        model.paused = false
        let t0 = Date()
        while !(await passed.value), Date().timeIntervalSince(t0) < 5 { try await Task.sleep(nanoseconds: 100_000_000) }
        let resumed = await passed.value
        XCTAssertTrue(resumed, "work resumes after un-pausing")
        _ = await waiter.value

        // Canceling a paused wait returns instead of hanging.
        await gate.setPaused(true)
        let canceled = Task { await gate.wait() }
        try await Task.sleep(nanoseconds: 200_000_000)
        canceled.cancel()
        let t1 = Date()
        _ = await canceled.value
        XCTAssertLessThan(Date().timeIntervalSince(t1), 3)
        await gate.setPaused(false)
    }

    actor Flag { var value = false; func set() { value = true } }

    // MARK: - Notifier webhook

    func testNotifierWebhookPostsTitleHeaderWithoutMacNotification() async throws {
        // A loopback listener using the system's own nc (built-in signed software, no firewall prompt).
        let port = Int.random(in: 41000...59000)
        let capture = Self.root.appendingPathComponent("webhook-\(port).txt")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-l", "127.0.0.1", "\(port)"]
        nc.standardOutput = try FileHandle(forWritingTo: capture)
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { if nc.isRunning { nc.terminate() } }
        try await Task.sleep(nanoseconds: 300_000_000)

        var r = RunRules.current
        r.notifyMac = false
        r.webhookURL = "http://127.0.0.1:\(port)/lumora"
        RunRules.current = r
        Notifier.send("Lumora batch finished", "3 files processed")

        let got = try await waitUntil(10) { ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").contains("3 files processed") }
        let text = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
        XCTAssertTrue(got, "no request arrived: \(text)")
        XCTAssertTrue(text.hasPrefix("POST /lumora HTTP/1.1"), text)
        XCTAssertTrue(text.contains("Title: Lumora batch finished"), text)
        XCTAssertTrue(text.hasSuffix("3 files processed"), text)
    }

    // MARK: - HDR library

    static func title(_ name: String, year: Int, p999: Int?, rating: HDRTitle.Rating = .great) -> HDRTitle {
        HDRTitle(title: name, year: year, edition: "UHD", hdrFormats: ["HDR10"], masteringPeakNits: 1000, maxCLL: 900, maxFALL: 300,
                 measuredP999Nits: p999, nativeResolution: "4K DI", rating: rating, reasons: ["Measured"],
                 sources: [URL(string: "https://example.org/\(year)")!], contributedBy: nil)
    }

    func testHDRLibraryBundledUserEntriesAndCommunitySync() async throws {
        let userFile = Self.appSupport.appendingPathComponent("hdr_library_user.json")
        try? FileManager.default.removeItem(at: userFile)
        UserDefaults.standard.removeObject(forKey: "hdrLibraryURL")

        // Bundled library (ships empty: Lumora has no ratings of its own).
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "hdr_library", withExtension: "json"))
        let shipped = try JSONDecoder().decode([HDRTitle].self, from: Data(contentsOf: bundled))
        let lib = HDRLibrary()
        XCTAssertEqual(lib.titles.count, shipped.count)

        // A user entry is saved, survives a reload, and replaces itself by id.
        try lib.add(Self.title("My Disc", year: 2017, p999: 700, rating: .reference))
        XCTAssertTrue(lib.titles.contains { $0.title == "My Disc" })
        var edited = Self.title("My Disc", year: 2017, p999: 750, rating: .reference); edited.reasons = ["Re-measured"]
        try lib.add(edited)
        XCTAssertEqual(lib.titles.filter { $0.title == "My Disc" }.count, 1)
        let reopened = HDRLibrary()
        XCTAssertEqual(reopened.titles.first { $0.title == "My Disc" }?.measuredP999Nits, 750)
        XCTAssertEqual(reopened.best.map(\.title), ["My Disc"])
        let saved = try JSONDecoder().decode([HDRTitle].self, from: Data(contentsOf: userFile))
        XCTAssertEqual(saved.map(\.reasons), [["Re-measured"]])

        // Community sync from a file URL, remembered in preferences.
        let community = Self.root.appendingPathComponent("community.json")
        let remote = (1...5).map { Self.title("Community \($0)", year: 2000 + $0, p999: 200 * $0, rating: $0 < 3 ? .dim : .great) }
        try JSONEncoder().encode(remote).write(to: community)
        reopened.communityURL = community
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hdrLibraryURL"), community.absoluteString)
        try await reopened.syncCommunity()
        XCTAssertEqual(reopened.titles.count, shipped.count + 6)
        XCTAssertEqual(reopened.worst.map(\.title).sorted(), ["Community 1", "Community 2"])
        XCTAssertEqual(reopened.match("community 3 (2003) remux.mkv")?.year, 2003)
        let card = HDRReportCard(title: "x", format: "HDR10", medianNits: 50, p99Nits: 400, p999Nits: 650, estimatedPeakNits: 1000,
                                 shareAbove203: 0.1, shareAbove1000: 0, blackFloorNits: 0.01, verdict: .balanced, findings: [], suggestion: "")
        XCTAssertEqual(reopened.rank(card), "Brighter highlights than 50% of the 6 measured titles in your library.")
        XCTAssertEqual(HDRLibrary().communityURL, community, "the community URL is remembered")

        // Malformed community JSON: a clear error, and the library is unchanged.
        let broken = Self.root.appendingPathComponent("community-broken.json")
        try Data("[{\"title\": \"Half".utf8).write(to: broken)
        reopened.communityURL = broken
        let before = reopened.titles
        do { try await reopened.syncCommunity(); XCTFail("malformed JSON must throw") } catch { XCTAssertTrue(error is DecodingError, "\(error)") }
        XCTAssertEqual(reopened.titles, before)
    }

    func testHDRLibraryMalformedUserFileIsNotOverwritten() throws {
        let userFile = Self.appSupport.appendingPathComponent("hdr_library_user.json")
        try FileManager.default.createDirectory(at: Self.appSupport, withIntermediateDirectories: true)
        let damaged = Data("[{\"title\": \"Hand edited\", \"year\": 1999, oops}]".utf8)
        try damaged.write(to: userFile)
        let lib = HDRLibrary()             // must not crash
        XCTAssertFalse(lib.titles.contains { $0.title == "Hand edited" })
        XCTAssertThrowsError(try lib.add(Self.title("New", year: 2020, p999: nil)), "adding must not silently wipe a file it couldn't read")
        XCTAssertEqual(try Data(contentsOf: userFile), damaged, "the user's file is left as it was")
    }

    // MARK: - Online lookup without a key

    func testLibraryLookupWithoutKeyGivesFriendlyErrorAndNoNetwork() async throws {
        guard LibraryLookup.apiKey.isEmpty else {
            throw XCTSkip("A TMDB key is stored in this Mac's Keychain; not touching it (the no-key path can't be exercised)")
        }
        do {
            _ = try await LibraryLookup.search("Alpha Film", year: "2001", tv: false)
            XCTFail("search without a key must fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Add a TMDB API key in Settings → Library to look titles up online.")
        }
        let model = AppModel()
        model.packaging.bespoke.title = "Alpha Film"
        model.lookUpTitle()
        let shown = try await waitUntil(5) { model.errorMessage != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(model.errorMessage, "Add a TMDB API key in Settings → Library to look titles up online.")
        XCTAssertEqual(model.lookupMatches.count, 0)
    }

    // MARK: - AirPlay preview

    func testAirPlayPreviewRendersFifteenSecondHEVCPreview() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = Self.root.appendingPathComponent("airplay-source.mp4")
        if !FileManager.default.fileExists(atPath: src.path) {
            try Self.ff(["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=24:d=17", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                         "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", src.path])
        }
        let model = AppModel()
        model.open(src)
        let opened = try await waitUntil(90) { (!model.presets.isEmpty && model.progress == nil) || model.errorMessage != nil }
        XCTAssertTrue(opened); XCTAssertNil(model.errorMessage)
        // Settings AirPlay can't carry are swapped for hardware HEVC HDR10.
        model.codec = .av1; model.delivery = .hdr10Plus; model.bitDepth = 10
        model.previewTime = 1.0
        let air = AirPlayPreview.shared
        air.player = nil
        air.prepare(model)
        XCTAssertTrue(air.busy)
        let done = try await waitUntil(120) { !air.busy }
        XCTAssertTrue(done)
        XCTAssertNil(model.errorMessage)
        let player = try XCTUnwrap(air.player)
        XCTAssertTrue(player.allowsExternalPlayback)
        XCTAssertEqual(player.rate, 0, "nothing plays until the window shows it")
        let url = try XCTUnwrap((player.currentItem?.asset as? AVURLAsset)?.url)
        XCTAssertEqual(url.lastPathComponent, "preview.mov")
        XCTAssertTrue(url.path.hasPrefix(Self.root.path), "rendered into the scratch folder")
        let p = try EndToEndTests.probe(url)
        XCTAssertEqual(p.codec, "hevc")
        XCTAssertTrue(p.pixFmt.contains("10"), p.pixFmt)
        XCTAssertEqual(p.transfer, "smpte2084")
        XCTAssertEqual(p.frames, 360, "15 s at 24 fps")
        air.player = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - AV2 without its encoder

    func testAV2WithoutEncoderIsReportedCleanly() async throws {
        guard !Codec.av2.available else { throw XCTSkip("avmenc is installed here; the missing-encoder path can't be exercised") }
        XCTAssertNil(ToolLocator.url(for: "avmenc"))
        let src = try Self.simpleSource("Eta.Film.2008.mp4")
        var job = ExportJob(descriptor: try await SourceInspector.inspect(src).0, preset: PresetCandidate(
            name: "Natural", look: .natural, color: .testSDR, params: GradeParams(), sceneExposures: [], reason: ""),
                            analysis: .empty, delivery: .sdr, codec: .av2, outputURL: try freshDir("av2").appendingPathComponent("x.obu"))
        job.bitDepth = 10
        XCTAssertEqual(ExportEngine.validate(job), "AV2 · AVM reference (experimental) needs the avmenc encoder, which isn't installed. See README → Encoders.")
        do { _ = try await ExportEngine().run(job) { _, _ in }; XCTFail("must not run without the encoder") } catch {
            XCTAssertEqual(error.localizedDescription, "AV2 · AVM reference (experimental) needs the avmenc encoder, which isn't installed. See README → Encoders.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.outputURL.path))
    }
}
