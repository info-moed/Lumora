import XCTest
@testable import Lumora

/// Hostile inputs: crafted names, metadata, frame rates, sizes, playlists and archives. Each test is an attack that
/// used to work (or crash) and must now be refused or neutralized.
@MainActor
final class SecurityTests: XCTestCase {

    // MARK: Path traversal through naming

    func testTitlesCannotEscapeTheOutputFolder() {
        var o = PackagingOptions()
        o.naming = .custom
        o.customTemplate = "{title}"
        for evil in ["../../../../Library/LaunchAgents/x", "..", ".", "/etc/passwd", "a/../../b", "....//....//x", ".hidden", "\u{0}x\u{7}y"] {
            o.bespoke.title = evil
            let rel = Naming.path(o, original: "src", facts: [:])
            let parts = rel.split(separator: "/")
            XCTAssertFalse(parts.contains { $0 == ".." || $0 == "." || $0.hasPrefix(".") }, "\(evil) → \(rel)")
            XCTAssertFalse(rel.hasPrefix("/"), "\(evil) → \(rel)")
            XCTAssertFalse(rel.unicodeScalars.contains { $0.properties.generalCategory == .control }, "\(evil) → \(rel)")
            XCTAssertFalse(rel.isEmpty)
        }
    }

    func testExplicitRenameCannotEscapeEither() {
        var o = PackagingOptions()
        o.outputName = "../../../tmp/owned"
        let rel = Naming.path(o, original: "src", facts: [:])
        XCTAssertEqual(rel, "tmp/owned")
        let dest = URL(fileURLWithPath: "/Users/someone/Movies")
        XCTAssertTrue(dest.appendingPathComponent(rel).standardizedFileURL.path.hasPrefix(dest.path + "/"))
    }

    // MARK: Never overwrite the source

    func testExportRefusesToOverwriteItsSource() throws {
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        let d = SourceDescriptor(url: src, kind: .avfoundation)
        let preset = PresetCandidate(name: "x", look: .original, color: .testSDR, params: GradeParams(), sceneExposures: [], reason: "")
        let job = ExportJob(descriptor: d, preset: preset, analysis: AnalysisResult.empty, delivery: .sdr, codec: .hevc, outputURL: src)
        XCTAssertNotNil(ExportEngine.validate(job))
        XCTAssertThrowsError(try ExportEngine.clearOutput(job))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the source must survive")
    }

    // MARK: Hostile frame rates, durations and sizes

    func testFrameRateAndFrameCountNeverTrap() {
        for fps in [Double.nan, .infinity, -.infinity, 0, -24, 0.001, 1e12, 1_073_741_823.5] {
            let (n, d) = rationalFrameRate(fps)
            XCTAssertGreaterThan(n, 0); XCTAssertGreaterThan(d, 0)
            XCTAssertLessThanOrEqual(Double(n) / Double(d), 1000)
            XCTAssertLessThan(n, Int(Int32.max), "must fit a CMTimeScale")
        }
        for (s, f) in [(Double.nan, 24.0), (.infinity, 24), (1e300, 1e300), (-5, 24), (0, 0)] {
            let c = safeFrameCount(seconds: s, fps: f)
            XCTAssertGreaterThanOrEqual(c, 1); XCTAssertLessThanOrEqual(c, 10_000_000)
            XCTAssertGreaterThanOrEqual(safeFrameIndex(seconds: s, fps: f), 0)
        }
        XCTAssertEqual(rationalFrameRate(23.976).0, 24000)
        XCTAssertEqual(rationalFrameRate(25).0, 25)
    }

    func testImpossibleSizesAreRejected() {
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/x.mkv"), kind: .ffmpeg)
        d.frameCount = 10
        for (w, h) in [(0, 0), (0, 1080), (8, 8), (16400, 16000), (20000, 100)] {
            d.width = w; d.height = h
            XCTAssertThrowsError(try SourceInspector.validateGeometry(d), "\(w)×\(h)")
        }
        d.width = 1920; d.height = 1080
        XCTAssertNoThrow(try SourceInspector.validateGeometry(d))
    }

    /// A raw Y4M stream declaring an absurd frame rate used to overflow a CMTimeScale and crash.
    func testHostileY4MFrameRatesOpenSafely() async throws {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        for (name, rate) in [("huge-fps.y4m", "F2147483647:2"), ("tiny-fps.y4m", "F1:1000")] {
            let url = EndToEndTests.dir.appendingPathComponent(name)
            try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=64x64:r=24:d=0.25",
                                          "-pix_fmt", "yuv420p", "-f", "yuv4mpegpipe", url.path])
            // Rewrite the frame-rate field in the header.
            var data = try Data(contentsOf: url)
            let header = String(decoding: data.prefix(80), as: UTF8.self)
            guard let r = header.range(of: #"F\d+:\d+"#, options: .regularExpression) else { return XCTFail("no rate in header") }
            let old = String(header[r])
            data.replaceSubrange(header.utf8.distance(from: header.startIndex, to: r.lowerBound)..<header.utf8.distance(from: header.startIndex, to: r.upperBound),
                                 with: Data(rate.utf8))
            try data.write(to: url)
            XCTAssertNotEqual(old, rate)
            do {
                let (d, _) = try await SourceInspector.inspect(url)
                XCTAssertGreaterThanOrEqual(d.fps, 1); XCTAssertLessThanOrEqual(d.fps, 1000)
                XCTAssertGreaterThanOrEqual(d.frameCount, 1); XCTAssertLessThanOrEqual(d.frameCount, 10_000_000)
                // Planning interpolation on it must not trap either.
                var s = InterpolationSettings(); s.mode = .targetFPS(num: 60, den: 1)
                let (plan, _) = InterpolationPlanner.plan(sourceFrames: min(d.frameCount, 100), sourceRate: (d.fpsNum, d.fpsDen),
                                                          settings: s, analysis: .empty)
                XCTAssertFalse(plan.isEmpty)
            } catch {
                // Refusing the file is fine too; crashing is not.
            }
        }
    }

    // MARK: FFmpeg can't be steered to other resources

    func testFFmpegInputsAreRestrictedToFilesAndPipes() {
        let a = FFHarden.args("ffmpeg", ["-y", "-i", "/a.mkv", "-i", "pipe:0", "-map", "0"])
        XCTAssertEqual(a.filter { $0 == "-protocol_whitelist" }.count, 2)
        XCTAssertEqual(a[a.firstIndex(of: "-protocol_whitelist")! + 1], "file,pipe,fd")
        XCTAssertEqual(FFHarden.args("ffprobe", ["/a.mkv"]).prefix(2), ["-protocol_whitelist", "file,pipe,fd"])
        XCTAssertEqual(FFHarden.args("x265", ["--input", "-"]), ["--input", "-"])
    }

    /// A "video" that is really a playlist pointing at the network must not make FFmpeg fetch anything.
    func testPlaylistDisguisedAsVideoIsRefused() async throws {
        guard EndToEndTests.ffmpeg != nil else { throw XCTSkip("FFmpeg not installed") }
        let url = EndToEndTests.dir.appendingPathComponent("evil.mkv")
        try "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttp://127.0.0.1:9/segment.ts\n#EXT-X-ENDLIST\n".write(to: url, atomically: true, encoding: .utf8)
        let started = Date()
        do {
            _ = try await SourceInspector.inspect(url)
            XCTFail("a playlist must not open as a video")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testConcatListQuotesApostrophes() {
        let line = FFConcat.line(URL(fileURLWithPath: "/Volumes/Pat's SSD/seg 1.mov"))
        XCTAssertEqual(line, #"file '/Volumes/Pat'\''s SSD/seg 1.mov'"#)
    }

    // MARK: Personal metadata

    func testRemovePersonalDetailsUsesAnAllowlist() async throws {
        guard let ffmpeg = EndToEndTests.ffmpeg, let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("FFmpeg not installed") }
        let src = EndToEndTests.dir.appendingPathComponent("tagged.mp4")
        try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=128x72:r=24:d=0.5", "-c:v", "libx264",
                                      "-pix_fmt", "yuv420p",
                                      "-metadata", "title=Holiday", "-metadata", "genre=Family",
                                      "-metadata", "location=+51.5074-000.1278/", "-metadata", "com.apple.quicktime.make=Apple",
                                      "-metadata", "com.apple.quicktime.model=iPhone 99 Pro", "-metadata", "artist=Jane Doe",
                                      "-metadata", "com.android.version=15", "-metadata", "vendor.serial=ABC123",
                                      "-movflags", "+use_metadata_tags", src.path])
        let outDir = EndToEndTests.dir.appendingPathComponent("packaged-\(UUID().uuidString.prefix(6))")
        var o = PackagingOptions()
        o.metadataPolicy = .removePersonal
        o.appendices = [.settings, .log]
        o.outputName = "Holiday"
        o.verifyAfterExport = false
        let facts = Packager.Facts(title: "Holiday", resolution: "720p", hdr: "SDR", codec: "HEVC", appVersion: "test",
                                   settings: ["source": src.lastPathComponent], qualityLines: [], hdrReport: [],
                                   logLines: [PrivacyScrub.paths("Opened \(NSHomeDirectory())/Movies/Holiday.mov")], posterJPEG: nil)
        let r = try await Packager.package(exported: src, source: src, streams: SourceStreams.probe(src), options: o,
                                           destination: outDir, facts: facts, progress: ProgressReporter(task: nil))
        let tags = try EndToEndTests.sh(ffprobe, ["-v", "error", "-show_entries", "format_tags", "-of", "default=nw=1", r.video.path]).lowercased()
        XCTAssertTrue(tags.contains("holiday"), "title is kept: \(tags)")
        for leak in ["51.5074", "iphone", "jane", "com.android", "abc123", "quicktime.make"] {
            XCTAssertFalse(tags.contains(leak), "leaked \(leak): \(tags)")
        }
        let log = try String(contentsOf: r.appendices.first { $0.path.hasSuffix(".log") }!, encoding: .utf8)
        XCTAssertFalse(log.contains(NSHomeDirectory()), "home path leaked into the log sidecar")
    }

    func testPackagingRefusesToReplaceTheSource() async throws {
        let src = try EndToEndTests.makeClip("sdr.mp4", hdr: false)
        let copy = EndToEndTests.dir.appendingPathComponent("victim.mp4")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        var o = PackagingOptions()
        o.outputName = "victim"
        o.appendices = []
        o.verifyAfterExport = false
        let facts = Packager.Facts(title: "v", resolution: "720p", hdr: "SDR", codec: "HEVC", appVersion: "test", settings: [:],
                                   qualityLines: [], hdrReport: [], logLines: [], posterJPEG: nil)
        do {
            _ = try await Packager.package(exported: src, source: copy, streams: SourceStreams(), options: o,
                                           destination: copy.deletingLastPathComponent(), facts: facts, progress: ProgressReporter(task: nil))
            XCTFail("packaging over the source must be refused")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: src), "source untouched")
    }

    // MARK: Model downloads

    func testImportRefusesAModelThatDoesNotMatchItsPinnedChecksum() throws {
        let fake = EndToEndTests.dir.appendingPathComponent("RIFE_fake.zip")
        try Data("not really a model".utf8).write(to: fake)
        let r = RIFERelease(id: "test-pinned", released: "2026-01-01", variant: "standard", pad: 32, url: nil,
                            sourcePage: URL(string: "https://example.org")!, notes: "", sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ModelLab.shared.importZip(fake, for: r))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelLab.shared.zipURL(r).path))
    }

    func testCatalogDownloadsArePinned() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "rife_catalog", withExtension: "json"))
        let releases = try JSONDecoder().decode([RIFERelease].self, from: Data(contentsOf: url))
        for r in releases where r.url != nil {
            XCTAssertEqual(r.sha256?.count, 64, "RIFE \(r.id) downloads without a pinned checksum")
        }
    }

    func testFileHashingMatchesShasum() throws {
        let f = EndToEndTests.dir.appendingPathComponent("hash.txt")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try ModelLab.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Secrets

    func testKeychainRoundTrip() {
        let account = "lumora-test-\(UUID().uuidString.prefix(6))"
        Keychain.set("secret-1", account: account)
        XCTAssertEqual(Keychain.get(account: account), "secret-1")
        Keychain.set("secret-2", account: account)
        XCTAssertEqual(Keychain.get(account: account), "secret-2")
        Keychain.delete(account: account)
        XCTAssertNil(Keychain.get(account: account))
    }

    func testPrivacyScrubRemovesAccountNames() {
        XCTAssertEqual(PrivacyScrub.paths("read /Users/alice/Movies/a.mov"), "read /Users/…/Movies/a.mov")
        XCTAssertFalse(PrivacyScrub.paths("at \(NSHomeDirectory())/x").contains(NSHomeDirectory()))
    }

    // MARK: Entitlements

    /// Reads the entitlements actually signed into the running app (not the source file), so the check covers what
    /// ships and never touches the source tree at run time.
    func testSignedEntitlementsKeepLibraryValidation() throws {
        let out = try EndToEndTests.sh("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", Bundle.main.bundlePath])
        XCTAssertFalse(out.contains("disable-library-validation"), out)
        XCTAssertFalse(out.contains("allow-unsigned-executable-memory"), out)
    }
}
