import XCTest
import Darwin
@testable import Lumora

/// Hostile and broken files, hostile names, and hostile run-time conditions. Every case must end with either a
/// checked, correct output or a clear error message, never a crash and never a hang longer than 30 seconds.
/// Outputs are verified with ffprobe (codec, size, frame count, audio) and by decoding them.
@MainActor
final class CampaignRobustnessTests: XCTestCase {

    // MARK: - Fixtures

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoraRobust-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    override class func tearDown() {
        // Restore permissions on anything a test made read-only, then remove every fixture and output.
        if let e = FileManager.default.enumerator(atPath: work.path) {
            for case let rel as String in e {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// The container AppModel.export picks: the codec's own, except MKV for FFmpeg-decoded sources (their audio
    /// and subtitle formats often don't fit a .mov).
    nonisolated static func container(_ codec: Codec, _ d: SourceDescriptor) -> String {
        codec.defaultContainer == "mov" && d.kind != .avfoundation ? "mkv" : codec.defaultContainer
    }

    /// A fresh, empty folder under the work folder.
    func freshDir(_ name: String) throws -> URL {
        let d = Self.work.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func ff(_ args: [String]) throws {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }

    /// Two shots (hard cut in the middle) with a 440 Hz tone, H.264 + AAC (MP4/MOV) or Opus (MKV).
    @discardableResult
    func makeSource(_ url: URL, width: Int = 320, height: Int = 180, seconds: Double = 2, fps: Int = 24,
                    audio: Bool = true, faststart: Bool = false) throws -> URL {
        let half = seconds / 2
        var args = ["-f", "lavfi", "-i", "testsrc2=s=\(width)x\(height):r=\(fps):d=\(half)",
                    "-f", "lavfi", "-i", "smptehdbars=s=\(width)x\(height):r=\(fps):d=\(half)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)"] }
        args += ["-filter_complex", "[0:v][1:v]concat=n=2:v=1[v]", "-map", "[v]"]
        if audio { args += ["-map", "2:a", "-c:a", url.pathExtension == "mkv" ? "libopus" : "aac"] }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "24",
                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        if faststart { args += ["-movflags", "+faststart"] }
        try ff(args + [url.path])
        return url
    }

    struct Stream { var type: String; var codec: String; var width: Int; var height: Int }

    func streams(_ url: URL) throws -> [Stream] {
        guard let ffprobe = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }
        let json = try EndToEndTests.sh(ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", url.path])
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (root?["streams"] as? [[String: Any]] ?? []).map {
            Stream(type: $0["codec_type"] as? String ?? "", codec: $0["codec_name"] as? String ?? "",
                   width: $0["width"] as? Int ?? 0, height: $0["height"] as? Int ?? 0)
        }
    }

    /// Decodes every stream of a file; true when FFmpeg reports nothing at all.
    func decodesCleanly(_ url: URL) throws -> Bool {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-nostdin", "-i", url.path, "-map", "0", "-f", "null", "-"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Timeouts

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T?
        func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return v }
    }

    final class Labels: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    /// Runs `op` off the main actor; nil (and a test failure) when it hasn't finished within `seconds`.
    func outcome<T>(_ label: String, seconds: Double = 30,
                    _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        let box = Box<Result<T, Error>>()
        let task = Task.detached {
            do { box.set(.success(try await op())) } catch { box.set(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while box.value == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard let r = box.value else {
            task.cancel()
            XCTFail("\(label): still running after \(Int(seconds)) s (hang)")
            return nil
        }
        return r
    }

    /// The error must be a real, human-readable message (not a bare type name or "error 0").
    @discardableResult
    func assertClear(_ error: Error, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let msg = error.localizedDescription
        print("[robustness] \(label): \(msg)")
        XCTAssertFalse(msg.isEmpty, "\(label): empty error message", file: file, line: line)
        XCTAssertFalse(msg.contains("error 0.") || msg.contains("LumoraError"), "\(label): unhelpful message \(msg)", file: file, line: line)
        return msg
    }

    // MARK: - Pipeline helpers

    struct Prepared { var d: SourceDescriptor; var color: SourceColor; var analysis: AnalysisResult; var preset: PresetCandidate }

    nonisolated static func prepare(_ url: URL) async throws -> Prepared {
        let (d, colors) = try await SourceInspector.inspect(url)
        guard let color = colors.first else { throw LumoraError.unsupported("no color interpretation") }
        let a = try await SceneAnalyzer.analyze(d, color: color) { _ in }
        return Prepared(d: d, color: color, analysis: a, preset: preset(color: color, analysis: a))
    }

    nonisolated static func preset(color: SourceColor, analysis a: AnalysisResult) -> PresetCandidate {
        let presets = AutoPresetEngine.generate(colors: [color], analysis: a, report: nil)
        return presets.first(where: \.recommended) ?? presets[0]
    }

    /// An analysis for a source that couldn't be analyzed, so export can still be attempted on it.
    nonisolated static func syntheticAnalysis(frames n: Int) -> AnalysisResult {
        var a = AnalysisResult.empty
        a.frameCount = n
        a.scenes[0].end = n
        return a
    }

    nonisolated static func job(_ p: Prepared, codec: Codec = .hevc, delivery: DeliveryFormat = .sdr, out: URL) -> ExportJob {
        var j = ExportJob(descriptor: p.d, preset: p.preset, analysis: p.analysis, delivery: delivery, codec: codec, outputURL: out)
        j.quality = 0.5
        if codec == .prores4444XQ { j.bitDepth = 12; j.chroma = .c444 }
        if codec == .prores422HQ { j.chroma = .c422 }
        if codec == .av1 {
            j.encodeChoice = EncodeChoice(codec: .av1, rungID: "test", rungLabel: "test", presetValue: "12", optionIDs: [], extraArgs: [])
        }
        return j
    }

    /// Exactly the file name AppModel.export gives an export.
    func exportName(_ src: URL, _ p: PresetCandidate, _ delivery: DeliveryFormat, ext: String) -> String {
        AppModel.exportFileName(source: src, look: p.look, delivery: delivery, ext: ext)
    }

    // MARK: - User-state guards

    /// Points the scratch drive at `folder` for the duration of `body`; always restores the user's setting.
    func withScratchRoot<T>(_ folder: URL, _ body: () async throws -> T) async rethrows -> T {
        let key = "scratchRoot"
        let saved = Prefs.store.object(forKey: key)
        Prefs.store.set(folder.path, forKey: key)
        defer {
            if let saved { Prefs.store.set(saved, forKey: key) } else { Prefs.store.removeObject(forKey: key) }
        }
        return try await body()
    }

    /// Overrides the in-memory measured Mac profile (never written to disk), restored afterwards.
    func withMacProfile<T>(cliAV1: Int, vtSessions: Int, _ body: () async throws -> T) async rethrows -> T {
        let saved = MacProfile.current
        var p = saved ?? MacProfile(machine: MacProfile.machineModel, chip: "test", os: MacProfile.osVersion, created: Date(), level: "test")
        p.cliInstances["av1"] = cliAV1
        p.vtSessions = vtSessions
        MacProfile.current = p
        defer { MacProfile.current = saved }
        return try await body()
    }

    nonisolated func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Names of this process's child processes (encoders and decoders that may have been left behind).
    func childProcesses() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "ppid=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        return text.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, Int32(parts[0]) == me else { return nil }
            return String(parts[1])
        }.filter { !$0.hasSuffix("/ps") && $0 != "ps" }
    }

    func leftoverJobFolders(_ scratch: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            .filter { $0.hasPrefix("export-") || $0.hasPrefix("grain-") }
    }

    func openViaApp(_ url: URL, seconds: Double = 60) async throws -> AppModel {
        let model = AppModel()
        model.open(url)
        let deadline = Date().addingTimeInterval(seconds)
        try await Task.sleep(nanoseconds: 50_000_000)
        while model.progress != nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(model.progress, "opening \(url.lastPathComponent) didn't finish within \(Int(seconds)) s (status: \(model.status))")
        return model
    }

    // MARK: - Files that must be refused at inspection

    func assertRefused(_ url: URL, _ label: String, viaApp: Bool = true) async throws {
        let r = await outcome("inspect \(label)") { try await SourceInspector.inspect(url) }
        switch r {
        case .success(let (d, _))?: XCTFail("\(label) opened as a \(d.width)×\(d.height) video with \(d.frameCount) frames")
        case .failure(let e)?: assertClear(e, "inspect \(label)")
        case nil: break
        }
        if viaApp {
            let model = try await openViaApp(url, seconds: 30)
            XCTAssertNotNil(model.errorMessage, "\(label): opening in the app must show an error")
            XCTAssertNil(model.analysis)
            if let m = model.errorMessage { print("[robustness] app open \(label): \(m)") }
        }
    }

    func testZeroByteFileIsRefused() async throws {
        try TestHardware.requireGPU()
        let url = try freshDir("zero").appendingPathComponent("empty.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try await assertRefused(url, "zero-byte .mp4")
        let mkv = url.deletingPathExtension().appendingPathExtension("mkv")
        FileManager.default.createFile(atPath: mkv.path, contents: Data())
        try await assertRefused(mkv, "zero-byte .mkv", viaApp: false)
    }

    func testRandomBytesNamedMP4AreRefused() async throws {
        try TestHardware.requireGPU()
        var g = SystemRandomNumberGenerator()
        let bytes = Data((0..<(256 << 10)).map { _ in UInt8.random(in: 0...255, using: &g) })
        let url = try freshDir("random").appendingPathComponent("noise.mp4")
        try bytes.write(to: url)
        try await assertRefused(url, "random bytes .mp4")
    }

    func testTruncatedMP4WithoutMoovIsRefused() async throws {
        try TestHardware.requireGPU()
        let dir = try freshDir("trunc-mp4")
        let full = try makeSource(dir.appendingPathComponent("full.mp4"))   // moov at the end
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("half.mp4")
        try data.prefix(data.count / 2).write(to: cut)
        try await assertRefused(cut, "truncated .mp4 (moov lost)")
    }

    func testAudioOnlyFileIsRefused() async throws {
        try TestHardware.requireGPU()
        let dir = try freshDir("audio")
        let url = dir.appendingPathComponent("tone.mp4")
        try ff(["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac", url.path])
        try await assertRefused(url, "audio-only .mp4")
        let r = await outcome("inspect audio-only") { try await SourceInspector.inspect(url) }
        if case .failure(let e)? = r { XCTAssertTrue(e.localizedDescription.contains("no video track"), e.localizedDescription) }
    }

    func testDirectoryWithoutDNGsIsRefused() async throws {
        try TestHardware.requireGPU()
        let dir = try freshDir("Card 'A' #1")
        try "not a raw file".write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("photo.jpg"))
        try await assertRefused(dir, "folder without DNGs")
        let empty = try freshDir("empty folder")
        try await assertRefused(empty, "empty folder", viaApp: false)
    }

    func testOnePixelVideoIsRefused() async throws {
        try TestHardware.requireGPU()
        let dir = try freshDir("1x1")
        let mp4 = dir.appendingPathComponent("dot.mp4")
        try ff(["-f", "lavfi", "-i", "color=c=gray:s=1x1:r=24:d=1", "-c:v", "libx264", "-pix_fmt", "yuv444p", mp4.path])
        XCTAssertEqual(try streams(mp4).first?.width, 1, "instrument: the fixture really is 1×1")
        try await assertRefused(mp4, "1×1 .mp4")
        let mkv = dir.appendingPathComponent("dot.mkv")
        try ff(["-f", "lavfi", "-i", "color=c=gray:s=1x1:r=24:d=1", "-c:v", "ffv1", mkv.path])
        try await assertRefused(mkv, "1×1 .mkv", viaApp: false)
    }

    // MARK: - Damaged files that may open: inspect, analyze and export

    /// Inspect → analyze → export. Each stage either works (and its output is checked) or fails with a clear message.
    /// Returns the exported file when the export worked.
    @discardableResult
    func exercise(_ url: URL, _ label: String, codec: Codec = .hevc, maxDecodable: Int? = nil) async throws -> URL? {
        let inspected = await outcome("inspect \(label)") { try await SourceInspector.inspect(url) }
        guard case .success(let (d, colors))? = inspected else {
            if case .failure(let e)? = inspected { assertClear(e, "inspect \(label)") }
            return nil
        }
        print("[robustness] \(label): opened as \(d.summary), \(d.frameCount) frames, kind \(d.kind)")
        let color = try XCTUnwrap(colors.first)
        let analyzed = await outcome("analyze \(label)") { try await SceneAnalyzer.analyze(d, color: color) { _ in } }
        var analysis: AnalysisResult
        switch analyzed {
        case .success(let a)?:
            analysis = a
            XCTAssertGreaterThan(a.frameCount, 0)
            if let maxDecodable { XCTAssertLessThanOrEqual(a.frameCount, maxDecodable, "\(label): analyzed more frames than the file holds") }
            print("[robustness] \(label): analyzed \(a.frameCount) frames, \(a.scenes.count) scenes")
        case .failure(let e)?:
            assertClear(e, "analyze \(label)")
            analysis = Self.syntheticAnalysis(frames: min(d.frameCount, 200))
        case nil:
            return nil
        }
        let p = Prepared(d: d, color: color, analysis: analysis, preset: Self.preset(color: color, analysis: analysis))
        let out = try freshDir("out").appendingPathComponent("\(label.filter { $0.isLetter || $0.isNumber }).\(Self.container(codec, d))")
        let job = Self.job(p, codec: codec, out: out)
        let exported = await outcome("export \(label)", seconds: 60) { try await ExportEngine().run(job) { _, _ in } }
        switch exported {
        case .success(let u)?:
            let probe = try EndToEndTests.probe(u)
            print("[robustness] \(label): exported \(probe.frames) frames (\(probe.codec))")
            XCTAssertGreaterThan(probe.frames, 0, "\(label): export finished but holds no frames")
            if let maxDecodable { XCTAssertLessThanOrEqual(probe.frames, maxDecodable, "\(label): more frames out than the file holds") }
            if case .success? = analyzed {
                XCTAssertEqual(probe.frames, analysis.frameCount, "\(label): export should hold every decodable frame")
            }
            XCTAssertTrue(try decodesCleanly(u), "\(label): the exported file must decode without errors")
            return u
        case .failure(let e)?:
            assertClear(e, "export \(label)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "\(label): a failed export must not leave an output")
            return nil
        case nil:
            return nil
        }
    }

    func testTruncatedMKV() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("trunc-mkv")
        let full = try makeSource(dir.appendingPathComponent("full.mkv"))
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("half.mkv")
        try data.prefix(data.count / 2).write(to: cut)
        let decodable = try EndToEndTests.probe(cut).frames
        XCTAssertLessThan(decodable, 48, "instrument: the cut must really lose frames")
        try await exercise(cut, "truncated mkv", maxDecodable: max(decodable, 1))
    }

    func testMoovClaimsMoreFramesThanExist() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("moov-first")
        let full = try makeSource(dir.appendingPathComponent("full.mp4"), faststart: true)
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("claims48.mp4")
        try data.prefix(data.count / 2).write(to: cut)
        let decodable = max(1, try EndToEndTests.probe(cut).frames)
        XCTAssertLessThan(decodable, 48, "instrument: the cut must really lose frames")
        try await exercise(cut, "moov claims 48", maxDecodable: decodable)
    }

    func testImageRenamedMov() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("image")
        let png = dir.appendingPathComponent("still.png")
        try ff(["-f", "lavfi", "-i", "testsrc2=s=320x180", "-frames:v", "1", png.path])
        let mov = dir.appendingPathComponent("still.mov")
        try FileManager.default.moveItem(at: png, to: mov)
        try await exercise(mov, "png renamed mov", maxDecodable: 1)
        let model = try await openViaApp(mov, seconds: 30)
        XCTAssertTrue(model.errorMessage != nil || model.analysis?.frameCount == 1, "either refused or a one-frame clip")
    }

    func testSeventeenPixelVideo() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("17x17")
        let h264 = dir.appendingPathComponent("tiny.mp4")
        try ff(["-f", "lavfi", "-i", "testsrc2=s=64x64:r=24:d=1", "-vf", "scale=17:17", "-c:v", "libx264", "-pix_fmt", "yuv444p", h264.path])
        let prores = dir.appendingPathComponent("tiny.mov")
        try ff(["-f", "lavfi", "-i", "testsrc2=s=64x64:r=24:d=1", "-vf", "scale=17:17", "-c:v", "prores_ks", prores.path])
        XCTAssertEqual(try streams(h264).first?.width, 17, "instrument: fixture is 17 px wide")
        XCTAssertEqual(try streams(prores).first?.width, 17, "instrument: fixture is 17 px wide")
        for (url, label) in [(h264, "17x17 h264"), (prores, "17x17 prores")] {
            for codec in [Codec.hevc, .prores422HQ] {
                if let out = try await exercise(url, "\(label) to \(codec.rawValue)", codec: codec, maxDecodable: 24) {
                    let s = try streams(out).first { $0.type == "video" }
                    XCTAssertEqual(s?.width, 16, "odd sizes are trimmed to even")
                    XCTAssertEqual(s?.height, 16)
                }
            }
        }
    }

    func testMKVWithUnsupportedCodec() async throws {
        try TestHardware.requireGPU()
        let dir = try freshDir("unknown-codec")
        let ok = try makeSource(dir.appendingPathComponent("ok.mkv"), audio: false)
        var data = try Data(contentsOf: ok)
        let id = Data("V_MPEG4/ISO/AVC".utf8)
        let r = try XCTUnwrap(data.range(of: id), "instrument: codec id present")
        data.replaceSubrange(r, with: Data("V_LUMORA/BOGUS!".utf8))
        let bad = dir.appendingPathComponent("bogus.mkv")
        try data.write(to: bad)
        // Instrument: FFmpeg itself can't decode it.
        XCTAssertFalse(try decodesCleanly(bad))
        let inspected = await outcome("inspect unsupported mkv") { try await Self.prepare(bad) }
        switch inspected {
        case .success?: XCTFail("a video in an unknown codec must not open and analyze as if it were fine")
        case .failure(let e)?:
            let msg = assertClear(e, "unsupported codec")
            XCTAssertFalse(msg.hasSuffix("no frames"), "say why: \(msg)")
        case nil: break
        }
        let model = try await openViaApp(bad, seconds: 30)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.analysis)
    }

    func testStreamWhoseSizeChangesMidFile() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("size-change")
        let a = dir.appendingPathComponent("a.ts"), b = dir.appendingPathComponent("b.ts")
        try ff(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", a.path])
        try ff(["-f", "lavfi", "-i", "smptehdbars=s=640x360:r=24:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-output_ts_offset", "1", b.path])
        let ts = dir.appendingPathComponent("broadcast.ts")
        var joined = try Data(contentsOf: a); joined.append(try Data(contentsOf: b))
        try joined.write(to: ts)
        let mp4 = dir.appendingPathComponent("broadcast.mp4")
        try ff(["-i", ts.path, "-c", "copy", mp4.path])
        for (url, label) in [(ts, "size change ts"), (mp4, "size change mp4")] {
            XCTAssertEqual(try EndToEndTests.probe(url).frames, 48, "instrument: 48 frames in \(label)")
            if let out = try await exercise(url, label, maxDecodable: 48) {
                let s = try XCTUnwrap(try streams(out).first { $0.type == "video" })
                XCTAssertEqual(s.width, 320, "\(label): output keeps the size the file declares")
                XCTAssertEqual(s.height, 180)
                // The TS keeps exact timing (all 48 frames). The MP4 remux has a timestamp jump at the switch, so the
                // constant-rate decode may drop one frame there; the export must still match what analysis decoded.
                let frames = try EndToEndTests.probe(out).frames
                if url == ts { XCTAssertEqual(frames, 48, "\(label): every frame survives the size change") }
                else { XCTAssertGreaterThanOrEqual(frames, 46, "\(label): frames lost around the size change") }
                // The second half (color bars, scaled into 320×180) must be real picture, not black.
                guard let ffmpeg = EndToEndTests.ffmpeg else { continue }
                let tail = dir.appendingPathComponent("tail-\(UUID().uuidString.prefix(4)).mov")
                try EndToEndTests.sh(ffmpeg, ["-v", "error", "-y", "-ss", "1.2", "-i", out.path, "-c", "copy", tail.path])
                let y = try EndToEndTests.meanLuma(tail)
                XCTAssertGreaterThan(y, 0.1, "\(label): second half is black (\(y))")
            }
        }
    }

    /// The container says 100 hours; the file holds 2 seconds. Nothing may size itself by the claim.
    func testHundredHourClaimDoesNotAllocateForTheClaim() async throws {
        try TestHardware.requireHardwareHEVC()
        let dir = try freshDir("100h")
        let ok = try makeSource(dir.appendingPathComponent("short.mkv"))
        var data = try Data(contentsOf: ok)
        // Matroska Segment Info → Duration (ID 0x4489, 8-byte float, in milliseconds).
        let r = try XCTUnwrap(data.range(of: Data([0x44, 0x89, 0x88])), "instrument: duration element present")
        var ms = (100.0 * 3600 * 1000).bitPattern.bigEndian
        data.replaceSubrange(r.upperBound..<(r.upperBound + 8), with: Data(bytes: &ms, count: 8))
        let url = dir.appendingPathComponent("claims-100-hours.mkv")
        try data.write(to: url)

        let base = Self.footprint()
        let peak = Box<UInt64>(); peak.set(base)
        let sampling = Task.detached {
            while !Task.isCancelled {
                let f = Self.footprint()
                if f > (peak.value ?? 0) { peak.set(f) }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { sampling.cancel() }

        let prepared = await outcome("prepare 100h") { try await Self.prepare(url) }
        guard case .success(let p)? = prepared else {
            if case .failure(let e)? = prepared { XCTFail("a short file with a wrong duration should still open: \(e.localizedDescription)") }
            return
        }
        print("[robustness] 100h claim: descriptor says \(p.d.frameCount) frames; analysis found \(p.analysis.frameCount)")
        XCTAssertGreaterThan(p.d.frameCount, 1_000_000, "instrument: the descriptor really carries the 100-hour claim")
        XCTAssertEqual(p.analysis.frameCount, 48)
        let out = try freshDir("100h-out").appendingPathComponent("short.\(Self.container(.hevc, p.d))")
        let job = Self.job(p, out: out)
        let engine = ExportEngine()
        XCTAssertEqual(try engine.outputShape(job).frames, 48, "the export plan must follow the frames that exist")
        let exported = await outcome("export 100h", seconds: 60) { try await engine.run(job) { _, _ in } }
        switch exported {
        case .success(let u)?: XCTAssertEqual(try EndToEndTests.probe(u).frames, 48)
        case .failure(let e)?: XCTFail("export of a 2-second clip failed: \(e.localizedDescription)")
        case nil: break
        }
        sampling.cancel()
        let grew = (Double(peak.value ?? base) - Double(base)) / 1_048_576
        print("[robustness] 100h claim: peak footprint growth \(Int(grew)) MB")
        XCTAssertLessThan(grew, 150, "memory grew by \(Int(grew)) MB for a 2-second clip")

        // The full open path in the app (crop detection, content test, thumbnails) as well.
        let model = try await openViaApp(url, seconds: 60)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.analysis?.frameCount, 48)
    }

    // MARK: - Hostile names

    static let hostileNames: [String] = [
        #"Pat's "Film": Part 1, #2 100%"#,
        "-dash 😀🎬 Cafe\u{301} nai\u{308}ve; $HOME `x`",
        String(repeating: "😀", count: 100) + String(repeating: "e\u{301}", count: 20),   // 240 UTF-16 units
    ]

    func testFullExportAndPackagingWithHostileNames() async throws {
        try TestHardware.requireHardwareHEVC()
        for (n, name) in Self.hostileNames.enumerated() {
            for ext in n == 2 ? ["mp4"] : ["mp4", "mkv"] {
                let srcDir = try freshDir("src").appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
                let src = try makeSource(srcDir.appendingPathComponent(name).appendingPathExtension(ext))
                let outDir = try freshDir("dst").appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let label = "name #\(n) .\(ext)"

                let p = try await Self.prepare(src)
                XCTAssertEqual(p.d.frameCount, 48, label)
                let out = outDir.appendingPathComponent(exportName(src, p.preset, .sdr, ext: Self.container(.hevc, p.d)))
                let job = Self.job(p, out: out)
                let r = await outcome("export \(label)", seconds: 60) { try await ExportEngine().run(job) { _, _ in } }
                guard case .success(let exported)? = r else {
                    if case .failure(let e)? = r { XCTFail("\(label): export failed: \(e.localizedDescription)") }
                    continue
                }
                XCTAssertEqual(exported.deletingLastPathComponent().standardizedFileURL, outDir.standardizedFileURL)
                XCTAssertEqual(try EndToEndTests.probe(exported).frames, 48, label)
                XCTAssertTrue(try streams(exported).contains { $0.type == "audio" }, "\(label): source audio carried")

                var o = PackagingOptions()
                o.naming = .plexMovie
                o.appendices = [.settings, .qualityReport, .checksums, .nfo, .log]
                let facts = Packager.Facts(title: src.lastPathComponent, resolution: "180p", hdr: "SDR", codec: "HEVC", appVersion: "test",
                                           settings: ["source": src.lastPathComponent], qualityLines: ["Codec: HEVC"], hdrReport: [],
                                           logLines: ["exported \(exported.lastPathComponent)"], posterJPEG: nil)
                let streamsIn = SourceStreams.probe(src)
                XCTAssertEqual(streamsIn.audio.count, 1, "\(label): instrument")
                let pk = await outcome("package \(label)", seconds: 60) {
                    try await Packager.package(exported: exported, source: src, streams: streamsIn, options: o, destination: outDir,
                                               facts: facts, progress: ProgressReporter(task: nil))
                }
                guard case .success(let result)? = pk else {
                    if case .failure(let e)? = pk { XCTFail("\(label): packaging failed: \(e.localizedDescription)") }
                    continue
                }
                let root = outDir.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                XCTAssertTrue(result.video.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root), "\(label): stays in the folder")
                XCTAssertEqual(result.verified, true, "\(label): verification")
                XCTAssertEqual(try EndToEndTests.probe(result.video).frames, 48, label)
                let kinds = try streams(result.video).map(\.type)
                XCTAssertTrue(kinds.contains("video") && kinds.contains("audio"), "\(label): \(kinds)")
                XCTAssertEqual(result.appendices.count, 5, "\(label): \(result.appendices.map(\.lastPathComponent))")
                for a in result.appendices {
                    XCTAssertGreaterThan((try? Data(contentsOf: a).count) ?? 0, 0, "\(label): \(a.lastPathComponent) is empty")
                }
                if let sha = result.appendices.first(where: { $0.pathExtension == "sha256" }) {
                    let line = try String(contentsOf: sha, encoding: .utf8)
                    XCTAssertEqual(String(line.prefix(64)), result.sha256, label)
                    XCTAssertTrue(line.contains(result.video.lastPathComponent), "\(label): sidecar names the file")
                }
                print("[robustness] \(label): packaged as \(result.video.path.replacingOccurrences(of: outDir.path, with: "…"))")
            }
        }
    }

    /// Names that are legal on disk but long in UTF-16 (emoji, combining marks) must still yield writable files.
    func testDerivedNamesFitTheFileSystem() throws {
        let dir = try freshDir("long")
        for base in [String(repeating: "😀", count: 125), String(repeating: "e\u{301}", count: 125), String(repeating: "a", count: 250)] {
            let src = URL(fileURLWithPath: "/x/\(base).mov")
            XCTAssertTrue(FileManager.default.createFile(atPath: dir.appendingPathComponent(base + ".mov").path, contents: Data()),
                          "instrument: the source name itself is legal")
            let p = Self.preset(color: .testSDR, analysis: .empty)
            let name = exportName(src, p, .dolbyVision84, ext: "mov")
            XCTAssertTrue(FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()),
                          "export name (\(name.utf16.count) UTF-16 units) must be creatable")
            // AppModel also writes "<name>.original-fps.<ext>" next to an interpolated export.
            let plain = URL(fileURLWithPath: name).deletingPathExtension().appendingPathExtension("original-fps").appendingPathExtension("mov")
            XCTAssertLessThanOrEqual(plain.lastPathComponent.utf8.count, 255, "original-frame-rate name too long")
            XCTAssertTrue(name.hasPrefix(String(base.prefix(10))), "the name still starts with the source name")
            XCTAssertTrue(name.hasSuffix("Dolby Vision 8.4 (HLG-compatible, iPhone-style).mov"), name)
            var o = PackagingOptions(); o.naming = .plexMovie
            let rel = Naming.path(o, original: base, facts: ["title": base, "resolution": "2160p", "hdr": "HDR10", "codec": "HEVC"])
            for part in rel.split(separator: "/") {
                for suffix in [".mp4", ".mkv"] + Appendix.allCases.map(\.fileSuffix) {
                    let n = String(part) + suffix
                    XCTAssertLessThanOrEqual(n.utf8.count, 255, "\(n.utf8.count) bytes: \(n.prefix(20))…")
                }
            }
        }
    }

    // MARK: - Scratch drive named like "Pat's: SSD, #1"

    func testMultiSegmentCLIExportAndVMAFWithPunctuatedScratch() async throws {
        try TestHardware.requireHardwareHEVC()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let scratch = try freshDir("vol").appendingPathComponent("Pat's: SSD, #1", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let srcDir = try freshDir("Pat's: src, #2")
        let src = try makeSource(srcDir.appendingPathComponent("Long take, #3 – 100%.mkv"), seconds: 22)   // 528 frames
        let outDir = try freshDir("Pat's: out, #4")
        try await withScratchRoot(scratch) {
            XCTAssertTrue(try ScratchManager.jobDirectory("probe").path.hasPrefix(scratch.path), "instrument: scratch override applies")
            try await withMacProfile(cliAV1: 2, vtSessions: 2) {
                let p = try await Self.prepare(src)
                XCTAssertEqual(p.d.frameCount, 528)
                XCTAssertGreaterThanOrEqual(p.analysis.scenes.count, 2)
                for codec in [Codec.av1, .hevc] {
                    let labels = Labels()
                    let out = outDir.appendingPathComponent("Pat's: \(codec.rawValue), #5.mkv")
                    let job = Self.job(p, codec: codec, out: out)
                    let r = await outcome("export \(codec.rawValue)", seconds: 120) {
                        try await ExportEngine().run(job) { label, _ in labels.add(label) }
                    }
                    guard case .success(let u)? = r else {
                        if case .failure(let e)? = r { XCTFail("\(codec.rawValue) multi-segment export failed: \(e.localizedDescription)") }
                        continue
                    }
                    XCTAssertTrue(labels.values.contains { $0.contains("2 parallel segments") },
                                  "instrument: the export really ran two segments (forcing the concat list): \(Set(labels.values))")
                    let probe = try EndToEndTests.probe(u)
                    XCTAssertEqual(probe.codec, codec == .av1 ? "av1" : "hevc")
                    XCTAssertEqual(probe.frames, 528, "\(codec.rawValue): every frame across the segment join")
                    XCTAssertTrue(try streams(u).contains { $0.type == "audio" }, "audio carried through the join")
                    XCTAssertTrue(try decodesCleanly(u))
                    XCTAssertEqual(leftoverJobFolders(scratch), [], "job folders removed")
                }
            }

            // A VMAF / metric run whose work folder, reference and test file all carry the awkward characters.
            let ref = try makeSource(srcDir.appendingPathComponent("ref: a, 'b' #1.mp4"))
            let test = srcDir.appendingPathComponent("test: a, 'b' #1.mp4")
            try ff(["-i", ref.path, "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-an", test.path])
            let r = await outcome("file metrics", seconds: 60) {
                try await FileMetrics.measure(reference: ref, test: test, hdr: false, width: 320, height: 180, frames: 48, rate: (24, 1))
            }
            guard case .success(let m)? = r else {
                if case .failure(let e)? = r { XCTFail("metric run failed: \(e.localizedDescription)") }
                return
            }
            guard VMAFRunner.available else { throw XCTSkip("libvmaf not installed") }
            let vmaf = try XCTUnwrap(m.scores.pooled[.vmaf], "VMAF missing: \(m.scores.pooled.keys)")
            print("[robustness] VMAF \(vmaf.mean) over \(m.scores.perFrame[.vmaf]?.count ?? 0) frames; metrics \(m.scores.pooled.keys.map(\.rawValue))")
            XCTAssertGreaterThan(vmaf.mean, 85, "CRF 20 copy of the reference should score high")
            XCTAssertLessThanOrEqual(vmaf.mean, 100)
            XCTAssertGreaterThanOrEqual(m.scores.perFrame[.vmaf]?.count ?? 0, 20)
            if MetricSuite.ffmpegHasXPSNR {
                let x = try XCTUnwrap(m.scores.pooled[.xpsnr], "XPSNR filter (stats_file in an awkward folder) produced nothing")
                XCTAssertGreaterThan(x.mean, 30)
            }
            XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter { $0.hasPrefix("filemetrics-") }, [])
        }
    }

    func testFFmpegComparisonGraphsIgnoreColourTags() throws {
        guard let ffmpeg = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let filters = try EndToEndTests.sh(ffmpeg, ["-hide_banner", "-filters"])
        let dir = try freshDir("tags")
        let tagged = try makeSource(dir.appendingPathComponent("tagged.mp4"), audio: false)   // BT.709-tagged, like Lumora's encodes
        let ref = dir.appendingPathComponent("ref.y4m")                                       // untagged, like Lumora's RAM reference
        try ff(["-i", tagged.path, "-vf", "format=yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", ref.path])
        func run(_ metric: String, _ marker: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-hide_banner", "-nostdin", "-i", ref.path, "-r", "24/1", "-i", tagged.path, "-lavfi",
                           "[1:v]\(VMAFRunner.sameCodeValues)format=yuv420p10le[d];[0:v]\(VMAFRunner.sameCodeValues)format=yuv420p10le[r];[d][r]\(metric)",
                           "-f", "null", "-"]
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.split(separator: "\n").last { $0.contains(marker) }.map(String.init) ?? text.suffix(300).description
        }
        // Identical pictures: XPSNR must be infinite (perfect), VMAF near 100.
        if filters.contains("xpsnr") {
            let line = try run("xpsnr", "XPSNR")
            XCTAssertTrue(line.contains("y: inf"), "identical pictures compared after a matrix conversion: \(line)")
        }
        if filters.contains("libvmaf") {
            let line = try run("libvmaf=model=version=vmaf_v0.6.1", "VMAF score")
            let score = Double(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            XCTAssertGreaterThan(score, 97, "libvmaf filter on identical pictures: \(line)")
        }
    }

    // MARK: - Hostile run-time conditions

    func testReadOnlyOutputFolderGivesAClearError() async throws {
        try TestHardware.requireHardwareHEVC()
        let src = try makeSource(try freshDir("ro-src").appendingPathComponent("clip.mp4"))
        let p = try await Self.prepare(src)
        let ro = try freshDir("read-only")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        let out = ro.appendingPathComponent("clip.mov")
        let started = Date()
        let r = await outcome("read-only export") { try await ExportEngine().run(Self.job(p, out: out)) { _, _ in } }
        switch r {
        case .success?: XCTFail("writing into a read-only folder can't succeed")
        case .failure(let e)?:
            let msg = assertClear(e, "read-only folder")
            XCTAssertTrue(msg.localizedCaseInsensitiveContains("permission") || msg.localizedCaseInsensitiveContains("read-only")
                          || msg.localizedCaseInsensitiveContains("can't write"), msg)
            XCTAssertTrue(msg.contains(ro.lastPathComponent), "the message should name the folder: \(msg)")
            XCTAssertFalse(msg.contains("joined."), "the message should not name an internal temp file: \(msg)")
        case nil: break
        }
        print("[robustness] read-only folder reported after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testSourceDeletedDuringExportGivesAClearError() async throws {
        try TestHardware.requireHardwareHEVC()
        for ext in ["mp4", "mkv"] {
            let dir = try freshDir("vanish-\(ext)")
            let src = try makeSource(dir.appendingPathComponent("vanishing.\(ext)"), width: 1280, height: 720, seconds: 4)
            let p = try await Self.prepare(src)
            if ext == "mp4" { XCTAssertEqual(p.d.kind, .avfoundation, "instrument: the MP4 takes the AVFoundation path (passthrough stitch)") }
            let out = try freshDir("vanish-out").appendingPathComponent("vanishing.\(ext == "mp4" ? "mov" : "mkv")")
            let job = Self.job(p, out: out)
            let deleted = Box<Bool>()
            let r = await outcome("export with vanishing source \(ext)", seconds: 60) {
                try await ExportEngine().run(job) { _, _ in
                    if deleted.value == nil { deleted.set(true); try? FileManager.default.removeItem(at: src) }
                }
            }
            XCTAssertEqual(deleted.value, true, "instrument: the source was deleted mid-export")
            XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
            switch r {
            case .success(let u)?:
                // Acceptable only if nothing was lost: every frame and the audio.
                XCTAssertEqual(try EndToEndTests.probe(u).frames, 96, "\(ext): finished from the open file but lost frames")
                XCTAssertTrue(try streams(u).contains { $0.type == "audio" }, "\(ext): finished but silently dropped the source's audio")
            case .failure(let e)?:
                let msg = assertClear(e, "source deleted (\(ext))")
                XCTAssertTrue(msg.contains("vanishing.\(ext)"), "say which file went missing: \(msg)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
            case nil: break
            }
        }
    }

    func testCancellationLeavesNothingBehind() async throws {
        try TestHardware.requireHardwareHEVC()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let scratch = try freshDir("cancel-scratch")
        let src = try makeSource(try freshDir("cancel-src").appendingPathComponent("long.mkv"), width: 1280, height: 720, seconds: 12)
        let p = try await Self.prepare(src)
        // Warm up handles that are opened once and kept (log file, encoder and metric services), so the
        // descriptor count below measures leaks only.
        let warm = try await Self.prepare(try makeSource(try freshDir("cancel-warm").appendingPathComponent("w.mkv"), audio: false))
        let warmDir = try freshDir("cancel-warm-out")
        for (n, (kind, targeted)) in [(Codec.hevc, false), (.av1, false), (.av1, true)].enumerated() where !targeted || VMAFRunner.available {
            var j = Self.job(warm, codec: kind, out: warmDir.appendingPathComponent("w\(n).mkv"))
            if targeted {
                var t = QualityTarget(); t.profile = QualityProfile.presets(hdr: false).first { $0.name == "VMAF only" }!
                t.vmaf = 90; t.maxTrials = 2; t.fixDips = false; j.qualityTarget = t
            }
            _ = await outcome("warm-up export \(n)", seconds: 60) { try await ExportEngine().run(j) { _, _ in } }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let fdsBefore = openFDs()
        try await withScratchRoot(scratch) {
            for (kind, targeted) in [(Codec.av1, false), (.hevc, false), (.av1, true)] {
                if targeted && !VMAFRunner.available { continue }
                let out = try freshDir("cancel-out").appendingPathComponent("long.mkv")
                var job = Self.job(p, codec: kind, out: out)
                if kind == .av1 { job.encodeChoice?.presetValue = "8" }
                if targeted {
                    var t = QualityTarget()
                    t.profile = QualityProfile.presets(hdr: false).first { $0.name == "VMAF only" }!
                    t.vmaf = 90; t.maxTrials = 2; t.fixDips = false
                    job.qualityTarget = t
                }
                let ticks = Box<Int>()
                let task = Task.detached { try await ExportEngine().run(job) { _, _ in ticks.set((ticks.value ?? 0) + 1) } }
                let deadline = Date().addingTimeInterval(30)
                while ticks.value == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertNotNil(ticks.value, "instrument: export got going")
                XCTAssertFalse(leftoverJobFolders(scratch).isEmpty, "instrument: a scratch job folder exists while running")
                let cancelledAt = Date()
                task.cancel()
                let r = await outcome("canceled \(kind.rawValue) export") { try await task.value }
                let took = Date().timeIntervalSince(cancelledAt)
                let codec = targeted ? "\(kind.rawValue) target-quality" : kind.rawValue
                print("[robustness] cancel \(codec): stopped after \(String(format: "%.2f", took)) s")
                switch r {
                case .success?: XCTFail("\(codec): a canceled export must not finish and write its output")
                case .failure(let e)?: XCTAssertTrue(e is CancellationError || e.localizedDescription.localizedCaseInsensitiveContains("cancel"),
                                                     "\(codec): \(e)")
                case nil: break
                }
                XCTAssertLessThan(took, 10, "\(codec): cancellation should stop the export promptly")
                XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "\(codec): no partial output")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.deletingLastPathComponent().path), [])
                // Helpers stop too: no encoder or decoder processes left, scratch job folders gone.
                let settle = Date().addingTimeInterval(5)
                while (!childProcesses().isEmpty || !leftoverJobFolders(scratch).isEmpty), Date() < settle {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertEqual(childProcesses(), [], "\(codec): helper processes left running after cancel")
                XCTAssertEqual(leftoverJobFolders(scratch), [], "\(codec): scratch job folder left behind")
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertLessThanOrEqual(openFDs() - fdsBefore, 3, "file descriptors leaked by canceled exports (\(fdsBefore) → \(openFDs()))")
    }

    func testTwoExportsAtOnce() async throws {
        try TestHardware.requireHardwareHEVC()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let dir = try freshDir("concurrent")
        let a = try await Self.prepare(try makeSource(dir.appendingPathComponent("a.mp4")))
        let b = try await Self.prepare(try makeSource(dir.appendingPathComponent("b.mkv"), width: 640, height: 360))
        let c = try await Self.prepare(try makeSource(dir.appendingPathComponent("c.mp4"), width: 480, height: 270))
        let jobs = [Self.job(a, codec: .hevc, out: dir.appendingPathComponent("a-out.mov")),
                    Self.job(b, codec: .av1, out: dir.appendingPathComponent("b-out.mkv")),
                    Self.job(c, codec: .prores422HQ, out: dir.appendingPathComponent("c-out.mov"))]
        let r = await outcome("concurrent exports", seconds: 90) {
            try await withThrowingTaskGroup(of: (Int, URL).self) { g in
                for (i, j) in jobs.enumerated() { g.addTask { (i, try await ExportEngine().run(j) { _, _ in }) } }
                var urls: [Int: URL] = [:]
                for try await (i, u) in g { urls[i] = u }
                return urls
            }
        }
        guard case .success(let urls)? = r else {
            if case .failure(let e)? = r { XCTFail("concurrent export failed: \(e.localizedDescription)") }
            return
        }
        let expect: [(String, Int, Int)] = [("hevc", 320, 180), ("av1", 640, 360), ("prores", 480, 270)]
        for (i, (codec, w, h)) in expect.enumerated() {
            let u = try XCTUnwrap(urls[i])
            let probe = try EndToEndTests.probe(u)
            XCTAssertEqual(probe.codec, codec)
            XCTAssertEqual(probe.frames, 48, codec)
            let v = try XCTUnwrap(try streams(u).first { $0.type == "video" })
            XCTAssertEqual(v.width, w, "\(codec): frames from another export must not leak in"); XCTAssertEqual(v.height, h)
            let y = try EndToEndTests.meanLuma(u)
            XCTAssertGreaterThan(y, 0.15, codec); XCTAssertLessThan(y, 0.85, codec)
        }
    }

    func testOpeningTheSameFile20TimesDoesNotLeak() async throws {
        try TestHardware.requireGPU()
        let src = try makeSource(try freshDir("reopen").appendingPathComponent("again.mp4"))
        _ = try await openViaApp(src)            // warm caches, pipelines and lazy singletons
        try await Task.sleep(nanoseconds: 300_000_000)
        let fds = openFDs(), mem = Self.footprint()
        var models: [AppModel] = []
        for i in 0..<20 {
            let m = try await openViaApp(src, seconds: 30)
            XCTAssertNil(m.errorMessage, "open #\(i)")
            XCTAssertEqual(m.analysis?.frameCount, 48, "open #\(i)")
            if i == 19 { models.append(m) }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let fdsAfter = openFDs()
        let grew = (Double(Self.footprint()) - Double(mem)) / 1_048_576
        print("[robustness] 20 opens: fds \(fds) → \(fdsAfter), footprint +\(Int(grew)) MB")
        XCTAssertLessThanOrEqual(fdsAfter - fds, 4, "file descriptors leak per open (\(fds) → \(fdsAfter))")
        XCTAssertLessThan(grew, 400, "memory grows by \(Int(grew)) MB over 20 opens")
        XCTAssertEqual(childProcesses(), [], "no helper processes left behind")

        // Same with the lower-level pipeline on an FFmpeg-decoded file.
        let mkv = try makeSource(src.deletingLastPathComponent().appendingPathComponent("again.mkv"))
        _ = try await Self.prepare(mkv)
        let fds2 = openFDs()
        for _ in 0..<20 { _ = try await Self.prepare(mkv) }
        XCTAssertLessThanOrEqual(openFDs() - fds2, 3, "FFmpeg-decoded sources leak descriptors")
        XCTAssertEqual(childProcesses(), [])
    }

    func testMissingAV2EncoderIsReportedCleanly() async throws {
        try TestHardware.requireGPU()
        if ToolLocator.isAvailable("avmenc") { throw XCTSkip("avmenc is installed here; this test covers its absence") }
        XCTAssertFalse(Codec.av2.available)
        let src = try makeSource(try freshDir("av2").appendingPathComponent("clip.mp4"), audio: false)
        let p = try await Self.prepare(src)
        let out = try freshDir("av2-out").appendingPathComponent("clip.obu")
        let job = Self.job(p, codec: .av2, out: out)
        let problem = try XCTUnwrap(ExportEngine.validate(job))
        XCTAssertTrue(problem.contains("avm") && problem.contains("isn't installed"), problem)
        let scratch = try freshDir("av2-scratch")
        try await withScratchRoot(scratch) {
            let r = await outcome("AV2 export") { try await ExportEngine().run(job) { _, _ in } }
            guard case .failure(let e)? = r else { return XCTFail("AV2 export can't succeed without avmenc") }
            XCTAssertEqual(assertClear(e, "AV2 missing"), problem)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [], "nothing started before the check")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// Two software-encoder segments in parallel, ten times over. Waiting for the encoders with
    /// `Process.waitUntilExit()` on a worker thread could miss their exit and hang forever (seen about one run in four).
    func testRepeatedMultiSegmentSoftwareExportsNeverHang() async throws {
        try TestHardware.requireGPU()
        guard Codec.av1.available else { throw XCTSkip("SVT-AV1 not installed") }
        let src = try makeSource(try freshDir("repeat").appendingPathComponent("s.mkv"), seconds: 22)
        let outDir = try freshDir("repeat-out")
        try await withMacProfile(cliAV1: 2, vtSessions: 2) {
            let p = try await Self.prepare(src)
            for i in 0..<10 {
                let labels = Labels()
                let job = Self.job(p, codec: .av1, out: outDir.appendingPathComponent("o\(i).mkv"))
                let r = await outcome("repeated two-segment AV1 export #\(i)", seconds: 30) {
                    try await ExportEngine().run(job) { label, _ in labels.add(label) }
                }
                guard case .success(let u)? = r else {
                    if case .failure(let e)? = r { XCTFail("#\(i): \(e.localizedDescription)") }
                    return
                }
                XCTAssertTrue(labels.values.contains { $0.contains("2 parallel segments") }, "instrument: two segments")
                if i == 9 { XCTAssertEqual(try EndToEndTests.probe(u).frames, 528) }
            }
        }
    }
}
