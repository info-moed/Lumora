import XCTest
@testable import Lumora

/// Shared fixtures for the render-recovery tests: small generated clips, a private scratch and log folder per test,
/// and helpers that compare exports frame by frame. Everything is headless; failures are injected through
/// FaultInjection (nothing is mounted, filled or unplugged).
class RecoveryTestCase: XCTestCase {
    /// Live child processes of this test process with that name (encoders must never be left behind).
    static func childProcesses(_ name: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(ProcessInfo.processInfo.processIdentifier), "-x", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").count
    }

    static let work: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoraRecovery-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var savedArgs: [String: Any] = [:]
    var scratch: URL!
    var logs: URL!
    var out: URL!

    override func setUp() async throws {
        try await super.setUp()
        FaultInjection.reset()
        let base = Self.work.appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(6))")
        scratch = base.appendingPathComponent("scratch", isDirectory: true)
        logs = base.appendingPathComponent("logs", isDirectory: true)
        out = base.appendingPathComponent("out", isDirectory: true)
        for d in [scratch!, logs!, out!] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // Process-local overrides (the argument domain): never written to the user's preferences, and never seen by
        // another Lumora process running at the same time.
        let ud = Prefs.store
        savedArgs = ud.volatileDomain(forName: UserDefaults.argumentDomain)
        var args = savedArgs
        args["scratchRoot"] = scratch.path
        args["renderLogFolder"] = logs.path
        args[CheckpointStore.historyKey] = [String]()        // never the scratch drives this Mac really used
        ud.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        ud.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(ud.string(forKey: "scratchRoot"), scratch.path)
    }

    /// Sets (or, with nil, removes) a preference for this test only, in the process-local argument domain.
    func setDefault(_ key: String, _ value: Any?) {
        let ud = Prefs.store
        var args = ud.volatileDomain(forName: UserDefaults.argumentDomain)
        args[key] = value
        ud.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        ud.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    override func tearDown() async throws {
        FaultInjection.reset()
        Prefs.store.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        Prefs.store.setVolatileDomain(savedArgs, forName: UserDefaults.argumentDomain)
        if let base = scratch?.deletingLastPathComponent() {
            if let e = FileManager.default.enumerator(atPath: base.path) {
                for case let rel as String in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent(rel).path)
                }
            }
            try? FileManager.default.removeItem(at: base)
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    // MARK: Tools

    static var ffmpeg: String { get throws { guard let f = EndToEndTests.ffmpeg else { throw XCTSkip("FFmpeg not installed") }; return f } }
    static var ffprobe: String { get throws { guard let f = EndToEndTests.ffprobe else { throw XCTSkip("ffprobe not installed") }; return f } }

    static func requireTool(_ name: String) throws {
        if !ToolLocator.isAvailable(name) { throw XCTSkip("\(name) not installed") }
    }

    /// Runs a tool niced, returning stdout + stderr.
    @discardableResult
    static func run(_ exe: String, _ args: [String], allowFailure: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "10", exe] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 && !allowFailure {
            throw NSError(domain: "run", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(exe) failed: \(text.suffix(800))"])
        }
        return text
    }

    static func ff(_ args: [String]) throws {
        try run(try ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }

    // MARK: Clips

    /// Two shots with a hard cut in the middle, a 440 Hz tone, H.264 (keyframe every `gop` frames) + AAC/Opus.
    @discardableResult
    static func makeSource(_ name: String, width: Int = 320, height: Int = 180, seconds: Double = 4, fps: String = "24",
                           gop: Int = 24, audio: Bool = true, faststart: Bool = false, bframes: Bool = false) throws -> URL {
        // Fixtures are shared between tests; the name carries every parameter so two tests never get each other's clip.
        let base = URL(fileURLWithPath: name)
        let tag = "\(width)x\(height)-\(seconds)s-\(fps)-g\(gop)\(audio ? "" : "-na")\(faststart ? "-fs" : "")\(bframes ? "-b" : "")"
        let url = work.appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(tag).\(base.pathExtension)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let half = seconds / 2
        var args = ["-f", "lavfi", "-i", "testsrc2=s=\(width)x\(height):r=\(fps):d=\(half)",
                    "-f", "lavfi", "-i", "smptehdbars=s=\(width)x\(height):r=\(fps):d=\(half)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)"] }
        args += ["-filter_complex", "[0:v][1:v]concat=n=2:v=1[v]", "-map", "[v]"]
        if audio { args += ["-map", "2:a", "-c:a", url.pathExtension == "mkv" ? "libopus" : "aac"] }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "\(gop)", "-keyint_min", "\(gop)",
                 "-sc_threshold", "0", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
        if !bframes { args += ["-bf", "0"] }
        if faststart { args += ["-movflags", "+faststart"] }
        try ff(args + [url.path])
        return url
    }

    /// A copy of a fixture under a new name (tests that modify their source never touch the shared one).
    static func copy(_ url: URL, as name: String) throws -> URL {
        let dest = work.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func prepare(_ url: URL) async throws -> CampaignRobustnessTests.Prepared {
        try await CampaignRobustnessTests.prepare(url)
    }

    func job(_ p: CampaignRobustnessTests.Prepared, codec: Codec, delivery: DeliveryFormat = .sdr, name: String) -> ExportJob {
        var j = CampaignRobustnessTests.job(p, codec: codec, delivery: delivery, out: out.appendingPathComponent(name))
        if codec == .av1 {
            j.encodeChoice = EncodeChoice(codec: .av1, rungID: "test", rungLabel: "test", presetValue: "12", optionIDs: [], extraArgs: [])
        }
        return j
    }

    // MARK: Comparing outputs

    struct Frames: Equatable { var hashes: [String]; var pts: [String] }

    /// Decoded frames of the first video stream: per-frame MD5 and presentation time (framemd5).
    static func frames(_ url: URL) throws -> Frames {
        // passthrough: framemd5's default frame-rate handling drops pictures from some Matroska files (measured on
        // VVC: 170 of 192), which would look like a lost frame.
        let text = try run(try ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-map", "0:v:0", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        var h: [String] = [], p: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 6 { p.append(parts[1]); h.append(parts[5]) }
        }
        return Frames(hashes: h, pts: p)
    }

    /// Presentation times in seconds of every decoded video frame.
    static func ptsSeconds(_ url: URL) throws -> [Double] {
        let text = try run(try ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time", "-of", "csv=p=0", url.path])
        return text.split(separator: "\n").compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
    }

    static func streamInfo(_ url: URL, _ entries: String, stream: String = "v:0") throws -> String {
        try run(try ffprobe, ["-v", "error", "-select_streams", stream, "-show_entries", entries, "-of", "default=nw=1", url.path])
    }

    static func audioDuration(_ url: URL) throws -> Double {
        let t = try run(try ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "packet=pts_time,duration_time", "-of", "csv=p=0", url.path])
        let rows = t.split(separator: "\n").map { $0.split(separator: ",").compactMap { Double($0) } }.filter { $0.count == 2 }
        guard let last = rows.max(by: { $0[0] < $1[0] }), let first = rows.min(by: { $0[0] < $1[0] }) else { return 0 }
        return last[0] + last[1] - first[0]
    }

    /// The export log of an engine's last run.
    static func log(_ e: ExportEngine) -> String {
        (e.session.flatMap { try? String(contentsOf: $0.logURL, encoding: .utf8) }) ?? ""
    }

    /// Encoder launches in a log (CMD lines for that binary).
    static func encoderLaunches(_ log: String, _ binary: String) -> Int {
        log.split(separator: "\n").filter { $0.contains(" CMD ") && $0.contains(" \(binary) ") }.count
    }

    static func checkpointFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: CheckpointStore.root, includingPropertiesForKeys: nil)) ?? []
    }

    /// Runs an export and returns the error it threw (fails the test when it succeeds).
    func failure(_ e: ExportEngine, _ j: ExportJob, options: RecoveryOptions = RecoveryOptions(),
                 file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        do {
            _ = try await e.run(j, options: options) { _, _ in }
            XCTFail("the export should have failed", file: file, line: line)
            return nil
        } catch { return error }
    }

    /// The journal of the (single) saved export.
    func savedJournal(file: StaticString = #filePath, line: UInt = #line) throws -> ExportJournal {
        let all = CheckpointStore.all()
        XCTAssertEqual(all.count, 1, "one export's progress is saved", file: file, line: line)
        return try XCTUnwrap(all.first?.journal, file: file, line: line)
    }
}
