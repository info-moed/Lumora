import XCTest
import CoreVideo
@testable import Lumora

/// Test media for the player, generated in Swift (exact code values) and encoded with the installed tools at low
/// priority (nice 15), small sizes and a few frames. Everything lives in one temporary folder per test run.
enum PlayerFixtures {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraPlayer-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func tool(_ name: String) -> String? { ToolLocator.url(for: name)?.path }

    static func require(_ names: String...) throws {
        for n in names where tool(n) == nil { throw XCTSkip("\(n) is not installed") }
    }

    /// Runs a tool at nice 15; throws with its error output on failure.
    @discardableResult
    static func run(_ name: String, _ args: [String], cwd: URL? = nil) throws -> String {
        guard let exe = tool(name) else { throw XCTSkip("\(name) is not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "15", exe] + args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "fixture", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(name) \(args.joined(separator: " ")): \(text.suffix(800))"])
        }
        return text
    }

    static func ffmpeg(_ args: [String]) throws { try run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y"] + args) }

    /// Builds a fixture once per run.
    static func cached(_ name: String, _ make: (URL) throws -> Void) throws -> URL {
        let u = url(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        let tmp = url("tmp-" + name)
        try? FileManager.default.removeItem(at: tmp)
        try make(tmp)
        try FileManager.default.moveItem(at: tmp, to: u)
        return u
    }

    // MARK: Y4M written from Swift

    struct Spec {
        var width = 320, height = 180, bits = 10, chroma = PlayerChroma.c420, frames = 24, rateNum = 24, rateDen = 1
        var fullRange = false
        var chromaTag: String? = nil          // Y4M siting tag, e.g. "420mpeg2"
    }

    /// Writes a Y4M whose samples come from `sample(frame, plane, x, y)` (code values at `bits`).
    static func writeY4M(_ url: URL, _ s: Spec, sample: (Int, Int, Int, Int) -> Int) throws {
        let c: String
        switch s.chroma {
        case .c420: c = s.bits > 8 ? "420p\(s.bits)" : (s.chromaTag ?? "420mpeg2")
        case .c422: c = s.bits > 8 ? "422p\(s.bits)" : "422"
        case .c444: c = s.bits > 8 ? "444p\(s.bits)" : "444"
        case .mono: c = s.bits > 8 ? "mono\(s.bits)" : "mono"
        }
        var header = "YUV4MPEG2 W\(s.width) H\(s.height) F\(s.rateNum):\(s.rateDen) Ip A1:1 C\(c)"
        if s.fullRange { header += " XCOLORRANGE=FULL" }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.write(contentsOf: Data((header + "\n").utf8))
        let (sx, sy) = s.chroma.subsampling
        let cw = (s.width + sx - 1) / sx, ch = (s.height + sy - 1) / sy
        let wide = s.bits > 8
        for f in 0..<s.frames {
            var d = Data("FRAME\n".utf8)
            for plane in 0..<(s.chroma == .mono ? 1 : 3) {
                let (w, hh) = plane == 0 ? (s.width, s.height) : (cw, ch)
                var bytes = [UInt8](repeating: 0, count: w * hh * (wide ? 2 : 1))
                for y in 0..<hh {
                    for x in 0..<w {
                        let v = max(0, min((1 << s.bits) - 1, sample(f, plane, x, y)))
                        let i = y * w + x
                        if wide { bytes[2 * i] = UInt8(v & 0xFF); bytes[2 * i + 1] = UInt8(v >> 8) } else { bytes[i] = UInt8(v) }
                    }
                }
                d.append(contentsOf: bytes)
            }
            try h.write(contentsOf: d)
        }
    }

    // MARK: Frame-index pattern (seek tests)

    static let indexBits = 12

    /// Frame number as 12 black / white blocks across the middle of the picture, on mid-gray.
    static func indexSample(frame: Int, plane: Int, x: Int, y: Int, s: Spec) -> Int {
        let scale = 1 << (s.bits - 8)
        if plane > 0 { return 128 * scale }
        let bw = s.width / indexBits
        let top = s.height / 3, bottom = 2 * s.height / 3
        guard y >= top && y < bottom else { return 126 * scale }
        let bit = min(indexBits - 1, x / bw)
        let on = (frame >> (indexBits - 1 - bit)) & 1 == 1
        return (on ? 220 : 30) * scale
    }

    static func indexY4M(_ name: String, spec s: Spec) throws -> URL {
        try cached(name) { try writeY4M($0, s) { f, p, x, y in indexSample(frame: f, plane: p, x: x, y: y, s: s) } }
    }

    /// The frame number a decoded index frame shows.
    static func decodeIndex(_ f: PlayerFrame) -> Int {
        let l = f.layout
        let bw = l.width / indexBits
        let y = l.height / 2
        var v = 0
        for bit in 0..<indexBits {
            let code = luma(f, x: bit * bw + bw / 2, y: y)
            let mid = 125 << (l.bits - 8)
            v = v << 1 | (code > mid ? 1 : 0)
        }
        return v
    }

    /// The luma code value (at the frame's own bit depth) at x, y.
    static func luma(_ f: PlayerFrame, x: Int, y: Int) -> Int {
        let l = f.layout
        switch f.planes {
        case .buffer(let b):
            let p = b.bytes + l.offsets[0] + y * l.strides[0]
            let raw = l.sampleBytes == 1 ? Int(p.load(fromByteOffset: x, as: UInt8.self))
                                         : Int(p.load(fromByteOffset: 2 * x, as: UInt16.self))
            return l.msbAligned ? raw >> (16 - l.bits) : raw
        case .pixelBuffer(let pb):
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let p = base + y * stride
            let raw = l.sampleBytes == 1 ? Int(p.load(fromByteOffset: x, as: UInt8.self))
                                         : Int(p.load(fromByteOffset: 2 * x, as: UInt16.self))
            return l.msbAligned ? raw >> (16 - l.bits) : (l.bits == 16 ? raw : raw)
        }
    }

    /// Every decoder child has been killed and reaped (waits up to `timeout` for worker threads to finish reaping).
    static func noChildrenLeft(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !ChildProcess.livePIDs.isEmpty && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return ChildProcess.livePIDs.isEmpty
    }

    /// Opens a backend the way the engine does (probe, choose, make).
    static func backend(_ url: URL, prefs: PlayerSettings = PlayerSettings(), caps: DecoderCapabilities = .current) throws -> (MediaInfo, PlayerVideoBackend) {
        let info = try MediaProbe.probe(url, caps: caps)
        let choice = try DecoderSelector.choose(info, caps: caps, prefs: prefs)
        return (info, try PlayerBackends.make(info: info, choice: choice, settings: prefs, poolCapacity: 8))
    }

    /// Decodes every frame from `start` (frame indices and their pattern values).
    static func decodeAll(_ b: PlayerVideoBackend, from start: Int = 0, limit: Int = 10_000) throws -> [(Int, Int)] {
        try b.start(atFrame: start)
        var out: [(Int, Int)] = []
        while out.count < limit, let f = try b.next() { out.append((f.index, decodeIndex(f))) }
        return out
    }

    // MARK: Encoded fixtures

    /// The index pattern (320×180, 10-bit, 24 frames, key frame every 8) in several codecs and containers.
    static func indexClip(_ kind: String) throws -> URL {
        let spec = Spec()
        let y4m = try indexY4M("index.y4m", spec: spec)
        switch kind {
        case "y4m": return y4m
        case "hevc.mp4":
            return try cached("index-hevc.mp4") { try ffmpeg(["-i", y4m.path, "-c:v", "libx265", "-x265-params", "log-level=error:keyint=8:min-keyint=8:bframes=2",
                                                              "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", "-f", "mp4", $0.path]) }
        case "hevc.mkv":
            let mp4 = try indexClip("hevc.mp4")
            return try cached("index-hevc.mkv") { try ffmpeg(["-i", mp4.path, "-c", "copy", "-f", "matroska", $0.path]) }
        case "hevc12.mp4":
            return try cached("index-hevc12.mp4") { try ffmpeg(["-i", y4m.path, "-c:v", "libx265", "-x265-params", "log-level=error:keyint=8:min-keyint=8",
                                                                "-pix_fmt", "yuv420p12le", "-tag:v", "hvc1", "-f", "mp4", $0.path]) }
        case "av1.mkv":
            return try cached("index-av1.mkv") { try ffmpeg(["-i", y4m.path, "-c:v", "libsvtav1", "-preset", "12", "-g", "8", "-crf", "30",
                                                             "-pix_fmt", "yuv420p10le", "-f", "matroska", $0.path]) }
        case "av1.mp4":
            let mkv = try indexClip("av1.mkv")
            return try cached("index-av1.mp4") { try ffmpeg(["-i", mkv.path, "-c", "copy", "-f", "mp4", $0.path]) }
        case "vp9.webm":
            return try cached("index-vp9.webm") { try ffmpeg(["-i", y4m.path, "-c:v", "libvpx-vp9", "-g", "8", "-crf", "30", "-b:v", "0", "-deadline", "realtime",
                                                              "-cpu-used", "8", "-pix_fmt", "yuv420p10le", "-f", "webm", $0.path]) }
        case "h264.mp4":
            return try cached("index-h264.mp4") { try ffmpeg(["-i", y4m.path, "-c:v", "libx264", "-g", "8", "-pix_fmt", "yuv420p", "-f", "mp4", $0.path]) }
        case "vvc.266":
            return try cached("index-vvc.266") {
                try run("vvencapp", ["-i", y4m.path, "--preset", "faster", "-q", "30", "--intraperiod", "8", "-o", $0.path])
            }
        case "av2.obu":
            return try cached("index-av2.obu") {
                try run("avmenc", ["--obu", "--passes=1", "--cpu-used=9", "--end-usage=q", "--qp=120", "--kf-max-dist=8", "--kf-min-dist=8",
                                   "--limit=24", "--fps=24/1", "-o", $0.path, y4m.path])
            }
        case "av2.ivf":
            return try cached("index-av2.ivf") {
                try run("avmenc", ["--ivf", "--passes=1", "--cpu-used=9", "--end-usage=q", "--qp=120", "--kf-max-dist=8", "--kf-min-dist=8",
                                   "--limit=24", "--fps=24/1", "-o", $0.path, y4m.path])
            }
        default:
            throw XCTSkip("unknown fixture \(kind)")
        }
    }

    /// A mid-gray PQ HDR10 HEVC clip with known mastering metadata (x265: 1000-nit display, MaxCLL 800, MaxFALL 300).
    static func hdr10Clip(_ container: String) throws -> URL {
        let mp4 = try cached("hdr10.mp4") {
            try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=0.5", "-vf", "scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le",
                        "-c:v", "libx265", "-x265-params",
                        "log-level=error:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:repeat-headers=1:max-cll=800,300:" +
                        "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)",
                        "-tag:v", "hvc1", "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-f", "mp4", $0.path])
        }
        if container == "mp4" { return mp4 }
        return try cached("hdr10.mkv") { try ffmpeg(["-i", mp4.path, "-c", "copy", "-f", "matroska", $0.path]) }
    }
}
