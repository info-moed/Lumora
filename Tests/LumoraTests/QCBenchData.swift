import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lumora

/// Paths, constants and the shared vocabulary of the QC benchmark.
enum QCBench {
    static let env = ProcessInfo.processInfo.environment
    static let root = URL(fileURLWithPath: env["LUMORA_BENCH_ROOT"] ?? (NSHomeDirectory() + "/Library/Caches/Lumora-Bench"), isDirectory: true)
    static let dataset = root.appendingPathComponent("qc-dataset", isDirectory: true)
    static let results = root.appendingPathComponent("qc-results", isDirectory: true)
    static let film1080 = root.appendingPathComponent("bbb/bbb_sunflower_1080p_60fps_normal.mp4")
    static let film2160 = root.appendingPathComponent("bbb/bbb_sunflower_2160p_60fps_normal.mp4")
    /// The committed manifest: exact frame indices of every window, so results are reproducible.
    static let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/qc-bench-manifest.json")
    static let tile = 64
    static let filmFPS = 60
    /// The film's first frame has PTS 2/60 s (start_time 0.0333): app frame index = 0-based frame number + 2.
    static let ptsOffset = 2

    static let imageModel = "rife-4.25"
    static let flowModel = "rife-4.25-flow"

    static let mainSplits = ["train", "val", "test"]
    static let extraSplits = ["credits", "test4k", "testHDR", "testGrain", "synthetic", "cut", "fade"]
    static let heldOut = ["test", "credits", "test4k", "testHDR", "testGrain", "synthetic"]
    static var allSplits: [String] { mainSplits + extraSplits }

    /// Film-time split boundaries (fraction of the story, i.e. the frames before the end credits); no window may
    /// straddle one. The credits are a separate held-out split.
    static let splitBounds: [(String, Double, Double)] = [("train", 0, 0.6), ("val", 0.6, 0.8), ("test", 0.8, 1.0)]

    /// Motion strata on the window's 90th-percentile block displacement between the 15->60 endpoints
    /// (frames n-2 and n+2, i.e. 4 frames at 60 fps), in 1080p pixels.
    static let strata: [(String, Float, Float)] = [("low", 0, 8), ("medium", 8, 32), ("high", 32, 96), ("extreme", 96, .infinity)]
    static func stratum(_ m: Float) -> String { strata.first { m >= $0.1 && m < $0.2 }?.0 ?? "extreme" }

    static func ensureDir(_ u: URL) { try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }

    static func log(_ s: String) {
        print("QCBENCH \(s)")
        fflush(stdout)
    }

    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs ffmpeg quietly with at most two threads (the Mac is shared).
    static func ffmpegRun(_ args: [String]) throws {
        guard let ff = ffmpeg else { throw XCTSkip("FFmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-threads", "2"] + args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw LumoraError.unsupported("ffmpeg failed: \(text)") }
    }
}

/// A deterministic random generator (SplitMix64) so sampling never depends on the run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Manifest

/// One sampled moment of a source: frames center-2 ... center+2 give a "30->60" triplet (center-1, center+1 -> center)
/// and a "15->60" triplet (center-2, center+2 -> center-1, center, center+1 at t = 0.25 / 0.5 / 0.75).
struct QCWindow: Codable, Hashable {
    var id: String
    var split: String
    var source: String        // bbb1080 | bbb2160 | synth-<name>
    var center: Int           // 0-based frame number in the source (ffmpeg's n)
    var stratum: String       // low | medium | high | extreme | cut | fade | the synthetic clip's name
    var motion: Float         // p90 block displacement n-2 -> n+2, 1080p pixels (-1 when not measured)
    var variant: String       // sdr | hdr | grain | dissolve
    var note: String? = nil
    /// Synthetic transitions (variant "dissolve"): frame n = mix(source n, partner shot at the same offset, a(n)) with
    /// a(n) = alpha + alphaStep * (n - center); partner -1 = black (a fade to black).
    var partner: Int? = nil
    var alpha: Float? = nil
    var alphaStep: Float? = nil
}

struct QCManifest: Codable {
    var version = 1
    var film = "Big Buck Bunny (sunflower, 60 fps, 1080p and 2160p renders), CC-BY 3.0 Blender Foundation"
    var filmFrames: Int
    var ptsOffsetFrames = QCBench.ptsOffset
    var splitRule = "film time over the story (frames before the end credits): train 0-60%, val 60-80%, test 80-100%; the end credits + post-credits scene are the held-out 'credits' split; windows (center±3) never straddle a boundary"
    var storyFrames = 0
    var motionRule = "p90 over 16x16 blocks (480x270 luma, ±12 px exhaustive search per frame) of the summed displacement from frame n-2 to n+2, in 1080p px; strata low <8, medium 8-32, high 32-96, extreme >=96"
    var cutRule: String
    var transitionRule: String
    var exclusionCounts: [String: Int]
    var cuts: [Int]
    var transitions: [[Int]]
    var decode: [String: String]
    var synthetic: [String: String]
    var grain: String
    var hdr: String
    var windows: [QCWindow]
}

// MARK: - NV12 frame cache (exactly what the decoder produced, lzfse-compressed)

struct NV12Frame {
    var width: Int, height: Int
    var y: Data, uv: Data       // w*h luma bytes, w*h/2 interleaved CbCr bytes

    init(width: Int, height: Int, y: Data, uv: Data) { self.width = width; self.height = height; self.y = y; self.uv = uv }

    init(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        self.width = width
        self.height = height
        func plane(_ i: Int, rows: Int) -> Data {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, i)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, i)
            var d = Data(count: rows * width)
            d.withUnsafeMutableBytes { dst in
                let p = dst.bindMemory(to: UInt8.self).baseAddress!
                for r in 0..<rows { memcpy(p + r * width, base + r * bpr, width) }
            }
            return d
        }
        y = plane(0, rows: height)
        uv = plane(1, rows: height / 2)
    }

    var raw: Data { y + uv }

    init?(raw: Data, width: Int, height: Int) {
        guard raw.count >= width * height * 3 / 2 else { return nil }
        self.width = width; self.height = height
        y = raw.subdata(in: 0..<(width * height))
        uv = raw.subdata(in: (width * height)..<(width * height * 3 / 2))
    }
}

enum FrameCache {
    static func url(_ source: String, _ key: String) -> URL {
        QCBench.dataset.appendingPathComponent("frames/\(source)/\(key).nv12z")
    }
    static func exists(_ source: String, _ key: String) -> Bool { FileManager.default.fileExists(atPath: url(source, key).path) }

    static func save(_ f: NV12Frame, _ source: String, _ key: String) throws {
        let u = url(source, key)
        QCBench.ensureDir(u.deletingLastPathComponent())
        var header = Data("NV12".utf8)
        var w = UInt32(f.width), h = UInt32(f.height)
        header.append(Data(bytes: &w, count: 4)); header.append(Data(bytes: &h, count: 4))
        let packed = try (f.raw as NSData).compressed(using: .lzfse) as Data
        try (header + packed).write(to: u, options: .atomic)
    }

    static func load(_ source: String, _ key: String) -> NV12Frame? {
        guard let d = try? Data(contentsOf: url(source, key)), d.count > 12, d.prefix(4) == Data("NV12".utf8) else { return nil }
        let w = d.subdata(in: 4..<8).withUnsafeBytes { Int($0.load(as: UInt32.self)) }
        let h = d.subdata(in: 8..<12).withUnsafeBytes { Int($0.load(as: UInt32.self)) }
        guard let raw = try? (d.subdata(in: 12..<d.count) as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return NV12Frame(raw: raw, width: w, height: h)
    }
}

/// YUV -> RGB parameters of the cached frames, calibrated against the app's own AVFoundation decode.
struct YUVConversion: Codable, Hashable {
    var kr: Float = 0.2126, kb: Float = 0.0722      // BT.709
    var legalOut = false
    var chromaX: Float = 0
    var description: String { "BT.709 video range, \(legalOut ? "legal-range" : "full-range") R'G'B', chroma x offset \(chromaX)" }
}

extension BenchGPU {
    func rgb(_ f: NV12Frame, _ c: YUVConversion) -> MTLTexture {
        let yT = ctx.makeTexture(width: f.width, height: f.height, format: .r8Unorm, usage: [.shaderRead], storage: .shared)
        let uvT = ctx.makeTexture(width: f.width / 2, height: f.height / 2, format: .rg8Unorm, usage: [.shaderRead], storage: .shared)
        f.y.withUnsafeBytes { yT.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: f.width) }
        f.uv.withUnsafeBytes { uvT.replace(region: MTLRegionMake2D(0, 0, f.width / 2, f.height / 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: f.width) }
        let out = texture(f.width, f.height)
        var p: [Float] = [c.kr, c.kb, 0, 0, c.chromaX, 0, 0, 0]
        p[2] = Float(bitPattern: UInt32(c.legalOut ? 1 : 0))
        run { cb in
            dispatch(cb, "nv12ToRGB", w: f.width, h: f.height) { e in
                e.setTexture(yT, index: 0); e.setTexture(uvT, index: 1); e.setTexture(out, index: 2)
                e.setBytes(&p, length: 32, index: 0)
            }
        }
        return out
    }
}

// MARK: - Decoding the film

/// Reads a film as NV12 in presentation order, with 0-based frame numbers from the PTS.
final class NV12Reader {
    let url: URL
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private(set) var lastIndex = -1
    private var skipFirst = false

    init(url: URL) { self.url = url }

    func start(at frame: Int) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LumoraError.noVideoTrack }
        let r = try AVAssetReader(asset: asset)
        // After a seek AVAssetReader also returns the frame overlapping the range start, with its PTS clamped to the
        // start: frame k-1 arrives labelled k (measured by test0b_SeekCheck). Start half a frame early and drop it.
        skipFirst = frame > 0
        if frame > 0 {
            let t = CMTime(value: CMTimeValue((frame + QCBench.ptsOffset) * 1000 - 500), timescale: 60_000)
            r.timeRange = CMTimeRange(start: t, duration: .positiveInfinity)
        }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { throw LumoraError.decodeFailed(r.error?.localizedDescription ?? "reader") }
        reader = r
        output = o
    }

    func next() throws -> (index: Int, buffer: CVPixelBuffer)? {
        if skipFirst {
            skipFirst = false
            _ = output?.copyNextSampleBuffer()
        }
        guard let output, let s = output.copyNextSampleBuffer() else {
            if let e = reader?.error { throw LumoraError.decodeFailed(e.localizedDescription) }
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(s) else { return try next() }
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        let idx = Int((pts.seconds * Double(QCBench.filmFPS)).rounded()) - QCBench.ptsOffset
        lastIndex = idx
        return (idx, pb)
    }

    func cancel() { reader?.cancelReading() }
}

// MARK: - Film scan: thumbnails, histograms and block motion for every frame

struct FilmScan {
    static let smallW = 480, smallH = 270, block = 16, search = 12
    static let thumbW = 48, thumbH = 27
    static let blocksX = 30, blocksY = 17
    static var blocks: Int { blocksX * blocksY }
    static let recordSize = thumbW * thumbH + 64 * 4 + blocks * 2 + blocks * 2

    var frames: Int
    var thumbs: [UInt8]          // frames * 48*27
    var hists: [UInt32]          // frames * 64
    var mv: [Int8]               // frames * blocks * 2 (content motion k-1 -> k, 480x270 px)
    var sad: [UInt8]             // frames * blocks: best-match mean abs diff * 1020
    var zero: [UInt8]            // frames * blocks: zero-motion mean abs diff * 1020

    static var url: URL { QCBench.dataset.appendingPathComponent("scan/bbb1080.scan") }

    static let offsets: [SIMD2<Int32>] = {
        var o: [SIMD2<Int32>] = []
        for y in -search...search { for x in -search...search { o.append(SIMD2(Int32(x), Int32(y))) } }
        return o.sorted { ($0.x * $0.x + $0.y * $0.y, $0.y, $0.x) < ($1.x * $1.x + $1.y * $1.y, $1.y, $1.x) }
    }()

    /// One frame's measurements against the previous frame's small luma picture.
    final class Measurer {
        let gpu = BenchGPU.shared
        private var prev: MTLTexture?
        private let offsetBuf: MTLBuffer
        init() {
            var o = FilmScan.offsets.map { SIMD2<Int32>($0.x, $0.y) }
            offsetBuf = BenchGPU.shared.ctx.device.makeBuffer(bytes: &o, length: o.count * 8, options: .storageModeShared)!
        }

        /// - lumaPlane: an r8Unorm luma plane; factor: integer downscale to 480x270.
        func measure(lumaPlane: MTLTexture, factor: Int) -> (thumb: [UInt8], hist: [UInt32], mv: [Int8], sad: [UInt8], zero: [UInt8]) {
            let small = gpu.texture(FilmScan.smallW, FilmScan.smallH, .r32Float)
            let thumb = gpu.ctx.makeTexture(width: FilmScan.thumbW, height: FilmScan.thumbH, format: .r32Float, storage: .shared)
            let hist = gpu.zeroed(64 * 4)
            let best = gpu.ctx.device.makeBuffer(length: FilmScan.blocks * 4, options: .storageModeShared)!
            memset(best.contents(), 0xFF, best.length)
            let zero = gpu.zeroed(FilmScan.blocks * 4)
            var f1 = SIMD2<Int32>(Int32(factor), 0), f2 = SIMD2<Int32>(10, 0)
            var bm = SIMD4<Int32>(Int32(FilmScan.blocksX), Int32(FilmScan.blocksY), Int32(FilmScan.offsets.count), Int32(FilmScan.block))
            gpu.run { cb in
                gpu.dispatch(cb, "boxDown", w: FilmScan.smallW, h: FilmScan.smallH) { e in
                    e.setTexture(lumaPlane, index: 0); e.setTexture(small, index: 1); e.setBytes(&f1, length: 8, index: 0)
                }
                gpu.dispatch(cb, "boxDown", w: FilmScan.thumbW, h: FilmScan.thumbH) { e in
                    e.setTexture(small, index: 0); e.setTexture(thumb, index: 1); e.setBytes(&f2, length: 8, index: 0)
                }
                gpu.dispatch(cb, "hist64", w: FilmScan.smallW, h: FilmScan.smallH) { e in
                    e.setTexture(small, index: 0); e.setBuffer(hist, offset: 0, index: 0)
                }
                if let prev {
                    gpu.dispatch(cb, "blockMatch", w: FilmScan.blocks, h: FilmScan.offsets.count) { e in
                        e.setTexture(prev, index: 0); e.setTexture(small, index: 1)
                        e.setBuffer(offsetBuf, offset: 0, index: 0); e.setBuffer(best, offset: 0, index: 1)
                        e.setBuffer(zero, offset: 0, index: 2); e.setBytes(&bm, length: 16, index: 3)
                    }
                }
            }
            var th = [Float](repeating: 0, count: FilmScan.thumbW * FilmScan.thumbH)
            th.withUnsafeMutableBytes { thumb.getBytes($0.baseAddress!, bytesPerRow: FilmScan.thumbW * 4,
                                                        from: MTLRegionMake2D(0, 0, FilmScan.thumbW, FilmScan.thumbH), mipmapLevel: 0) }
            let h = Array(UnsafeBufferPointer(start: hist.contents().bindMemory(to: UInt32.self, capacity: 64), count: 64))
            var mv = [Int8](repeating: 0, count: FilmScan.blocks * 2)
            var sad = [UInt8](repeating: 0, count: FilmScan.blocks), zr = [UInt8](repeating: 0, count: FilmScan.blocks)
            if prev != nil {
                let b = best.contents().bindMemory(to: UInt32.self, capacity: FilmScan.blocks)
                let z = zero.contents().bindMemory(to: Float.self, capacity: FilmScan.blocks)
                for i in 0..<FilmScan.blocks {
                    let rank = Int(b[i] & 0x3FFF), m = Float(b[i] >> 14) / 16383
                    let o = FilmScan.offsets[rank]
                    // cur(q) matches prev(q + o): the content moved by -o.
                    mv[i * 2] = Int8(-o.x); mv[i * 2 + 1] = Int8(-o.y)
                    sad[i] = UInt8(min(255, (m * 1020).rounded()))
                    zr[i] = UInt8(min(255, (z[i] * 1020).rounded()))
                }
            }
            prev = small
            return (th.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }, h, mv, sad, zr)
        }
    }

    static func load() -> FilmScan? {
        guard let d = try? Data(contentsOf: url), d.count > 8 else { return nil }
        let n = d.prefix(8).withUnsafeBytes { Int($0.load(as: UInt64.self)) }
        guard d.count == 8 + n * recordSize else { return nil }
        var s = FilmScan(frames: n, thumbs: [], hists: [], mv: [], sad: [], zero: [])
        s.thumbs.reserveCapacity(n * thumbW * thumbH)
        d.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: 8)
            for k in 0..<n {
                let r = p.advanced(by: k * recordSize)
                let t = thumbW * thumbH
                s.thumbs.append(contentsOf: UnsafeBufferPointer(start: r.assumingMemoryBound(to: UInt8.self), count: t))
                var hh = [UInt32](repeating: 0, count: 64)
                memcpy(&hh, r.advanced(by: t), 256)
                s.hists.append(contentsOf: hh)
                let m = r.advanced(by: t + 256)
                s.mv.append(contentsOf: UnsafeBufferPointer(start: m.assumingMemoryBound(to: Int8.self), count: blocks * 2))
                s.sad.append(contentsOf: UnsafeBufferPointer(start: m.advanced(by: blocks * 2).assumingMemoryBound(to: UInt8.self), count: blocks))
                s.zero.append(contentsOf: UnsafeBufferPointer(start: m.advanced(by: blocks * 3).assumingMemoryBound(to: UInt8.self), count: blocks))
            }
        }
        return s
    }

    func save() throws {
        var d = Data()
        var n = UInt64(frames)
        d.append(Data(bytes: &n, count: 8))
        d.reserveCapacity(8 + frames * Self.recordSize)
        let t = Self.thumbW * Self.thumbH, b = Self.blocks
        for k in 0..<frames {
            d.append(contentsOf: thumbs[(k * t)..<((k + 1) * t)])
            hists[(k * 64)..<((k + 1) * 64)].withUnsafeBytes { d.append(contentsOf: $0) }
            mv[(k * b * 2)..<((k + 1) * b * 2)].withUnsafeBytes { d.append(contentsOf: $0) }
            d.append(contentsOf: sad[(k * b)..<((k + 1) * b)])
            d.append(contentsOf: zero[(k * b)..<((k + 1) * b)])
        }
        QCBench.ensureDir(Self.url.deletingLastPathComponent())
        try d.write(to: Self.url, options: .atomic)
    }

    /// Scans every frame of the 1080p film (hardware decode, one small GPU pass per frame).
    static func scan() async throws -> FilmScan {
        let reader = NV12Reader(url: QCBench.film1080)
        try await reader.start(at: 0)
        let m = Measurer()
        var s = FilmScan(frames: 0, thumbs: [], hists: [], mv: [], sad: [], zero: [])
        let started = Date()
        while let (idx, pb) = try reader.next() {
            precondition(idx == s.frames, "frame numbering: got \(idx), expected \(s.frames)")
            guard let (y, keep) = BenchGPU.shared.ctx.texture(from: pb, format: .r8Unorm, plane: 0) else { throw LumoraError.decodeFailed("plane") }
            let r = m.measure(lumaPlane: y, factor: 4)
            _ = keep
            s.thumbs += r.thumb; s.hists += r.hist; s.mv += r.mv; s.sad += r.sad; s.zero += r.zero
            s.frames += 1
            if s.frames % 2000 == 0 { QCBench.log("scan \(s.frames) frames, \(Int(Date().timeIntervalSince(started))) s") }
        }
        return s
    }

    // MARK: Per-frame signals

    func thumbMAD(_ a: Int, _ b: Int) -> Float {
        let t = Self.thumbW * Self.thumbH
        var s = 0
        for i in 0..<t { s += abs(Int(thumbs[a * t + i]) - Int(thumbs[b * t + i])) }
        return Float(s) / Float(t) / 255
    }

    /// Mean abs difference between thumbnail k and the average of thumbnails a and b.
    func thumbBlendErr(_ k: Int, _ a: Int, _ b: Int) -> Float {
        let t = Self.thumbW * Self.thumbH
        var s: Float = 0
        for i in 0..<t { s += abs(Float(thumbs[k * t + i]) - 0.5 * (Float(thumbs[a * t + i]) + Float(thumbs[b * t + i]))) }
        return s / Float(t) / 255
    }

    func meanLuma(_ k: Int) -> Float {
        let t = Self.thumbW * Self.thumbH
        var s = 0
        for i in 0..<t { s += Int(thumbs[k * t + i]) }
        return Float(s) / Float(t) / 255
    }

    func chi2(_ k: Int) -> Float {
        guard k > 0 else { return 0 }
        let tot = Float(Self.smallW * Self.smallH)
        var s: Float = 0
        for i in 0..<64 {
            let a = Float(hists[k * 64 + i]) / tot, b = Float(hists[(k - 1) * 64 + i]) / tot
            if a + b > 0 { s += (a - b) * (a - b) / (a + b) }
        }
        return 0.5 * s
    }

    /// Mean motion-compensated residual of frame k against k-1 (what block motion can't explain).
    func residual(_ k: Int) -> Float {
        var s = 0
        for i in 0..<Self.blocks { s += Int(sad[k * Self.blocks + i]) }
        return Float(s) / Float(Self.blocks) / 1020
    }

    /// p90 and mean of the summed block displacement over frames n-2 -> n+2, in 1080p pixels.
    func windowMotion(_ n: Int) -> (p90: Float, mean: Float) {
        var mags: [Float] = []
        for b in 0..<Self.blocks {
            var vx = 0, vy = 0
            for k in (n - 1)...(n + 2) { vx += Int(mv[(k * Self.blocks + b) * 2]); vy += Int(mv[(k * Self.blocks + b) * 2 + 1]) }
            mags.append(4 * sqrtf(Float(vx * vx + vy * vy)))
        }
        mags.sort()
        return (mags[Int(Float(mags.count - 1) * 0.9)], mags.reduce(0, +) / Float(mags.count))
    }
}

// MARK: - Cut and transition detection on the scan

struct ShotAnalysis {
    var cuts: [Int] = []                  // first frame of a new shot
    var transitions: [ClosedRange<Int>] = []
    var creditsStart = 0                  // first frame of the end credits (black), from the scan
    static let cutRule = "frame k starts a shot when the block-motion residual res(k) > 0.045 and > 3x the median residual of k-8...k+8 (excluding k) + 0.01, and the 64-bin luma histogram chi-square vs k-1 > 0.05 or the thumbnail MAD > 0.06; at most one cut in any 4 frames"
    static let transitionRule = "a fade/dissolve run is >= 5 consecutive frames where the thumbnail of k is explained by the average of k-s and k+s for s = 2 or 4 (blend error < 0.45x the error vs the nearer of the two), the change is real (> 0.012 MAD), block motion leaves a residual (> 0.012) and no cut lies within k±s; the span is padded by 2 frames"

    init(_ s: FilmScan) {
        let n = s.frames
        let res = (0..<n).map { s.residual($0) }
        let chi = (0..<n).map { s.chi2($0) }
        var mad = [Float](repeating: 0, count: n)
        for k in 1..<n { mad[k] = s.thumbMAD(k, k - 1) }
        for k in 1..<n {
            let lo = max(1, k - 8), hi = min(n - 1, k + 8)
            var nb = (lo...hi).filter { $0 != k }.map { res[$0] }
            nb.sort()
            let med = nb.isEmpty ? 0 : nb[nb.count / 2]
            if res[k] > 0.045, res[k] > 3 * med + 0.01, chi[k] > 0.05 || mad[k] > 0.06 {
                if let last = cuts.last, k - last < 4 { if res[k] > res[last] { cuts[cuts.count - 1] = k }; continue }
                cuts.append(k)
            }
        }
        let cutSet = Set(cuts)
        var flag = [Bool](repeating: false, count: n)
        for k in 2..<(n - 4) {
            for span in [2, 4] where k - span >= 0 && !((k - span)...(k + span)).contains(where: { cutSet.contains($0) }) {
                let e = min(s.thumbMAD(k, k - span), s.thumbMAD(k, k + span))
                guard e > 0.012 else { continue }
                let d = s.thumbBlendErr(k, k - span, k + span)
                let r = (res[k] + res[k + 1]) / 2
                if d < 0.45 * e, r > 0.012 { flag[k] = true }
            }
        }
        var k = 0
        while k < n {
            if flag[k] {
                var j = k
                while j + 1 < n, flag[j + 1] { j += 1 }
                if j - k + 1 >= 5 { transitions.append(max(0, k - 2)...min(n - 1, j + 2)) }
                k = j + 1
            } else { k += 1 }
        }
        // End credits: the first stretch of >= 20 near-black frames in the last quarter of the film (the iris-out).
        creditsStart = n
        var dark = 0
        for k in (3 * n / 4)..<n {
            dark = s.meanLuma(k) < 0.075 ? dark + 1 : 0      // video-range luma: black is 16/255 = 0.063
            if dark >= 20 { creditsStart = k - 19; break }
        }
    }

    func inTransition(_ n: Int, margin: Int) -> Bool { transitions.contains { $0.overlaps((n - margin)...(n + margin)) } }
}

// MARK: - Window selection

enum WindowSelector {
    static let quotas: [String: Int] = ["train": 45, "val": 15, "test": 24, "credits": 6]   // per motion stratum

    static func id(_ split: String, _ i: Int) -> String { "\(split)-\(String(format: "%03d", i))" }

    /// Splits are by film time over the story (frames before the end credits): train 0-60%, val 60-80%, test 80-100%.
    /// The end credits (scrolling text, then the short post-credits scene) are their own held-out split.
    static func split(of c: Int, story: Int, frames: Int) -> (String, Int, Int)? {
        if c >= story { return ("credits", story, frames) }
        let f = Double(c) / Double(story)
        guard let b = QCBench.splitBounds.first(where: { f >= $0.1 && f < $0.2 }) else { return nil }
        return (b.0, Int(b.1 * Double(story)), Int(b.2 * Double(story)))
    }

    static func select(_ s: FilmScan, _ shots: ShotAnalysis) -> (windows: [QCWindow], excluded: [String: Int]) {
        let n = s.frames, story = shots.creditsStart
        var excluded: [String: Int] = [:]
        var byStratum: [String: [String: [(Int, Float)]]] = [:]
        for c in stride(from: 6, to: n - 6, by: 3) {
            guard let (split, lo, hi) = split(of: c, story: story, frames: n) else { continue }
            if c - 3 < lo || c + 3 >= hi { excluded["split boundary", default: 0] += 1; continue }
            if shots.cuts.contains(where: { $0 > c - 3 && $0 <= c + 3 }) { excluded["scene cut within ±3 frames", default: 0] += 1; continue }
            if shots.inTransition(c, margin: 3) { excluded["fade/dissolve", default: 0] += 1; continue }
            if s.thumbMAD(c - 2, c + 2) < 0.0015 { excluded["static (no visible change n-2 -> n+2)", default: 0] += 1; continue }
            let m = s.windowMotion(c).p90
            byStratum[split, default: [:]][QCBench.stratum(m), default: []].append((c, m))
        }
        var windows: [QCWindow] = []
        for split in ["train", "val", "test", "credits"] {
            var rng = SplitMix(state: split.unicodeScalars.reduce(UInt64(17)) { $0 &* 31 &+ UInt64($1.value) })
            var chosen: [Int] = []
            var picked: [(Int, Float, String)] = []
            var spare = 0
            // Rarest strata first so a short one hands its unused quota on to the others.
            for (st, _, _) in QCBench.strata.reversed() {
                var cands = byStratum[split]?[st] ?? []
                cands.shuffle(using: &rng)
                var taken = 0
                let want = quotas[split]! + spare
                for (c, m) in cands where taken < want {
                    if chosen.contains(where: { abs($0 - c) < 30 }) { continue }
                    chosen.append(c); picked.append((c, m, st)); taken += 1
                }
                spare = want - taken
            }
            picked.sort { $0.0 < $1.0 }
            for (i, p) in picked.enumerated() {
                windows.append(QCWindow(id: id(split, i), split: split, source: "bbb1080", center: p.0, stratum: p.2, motion: p.1, variant: "sdr"))
            }
        }
        // Held-out extras, all drawn from the test part of the story.
        let test = windows.filter { $0.split == "test" }
        func perStratum(_ k: Int, offset: Int) -> [QCWindow] {
            QCBench.strata.flatMap { st in test.filter { $0.stratum == st.0 }.dropFirst(offset).prefix(k) }
        }
        for (i, w) in perStratum(4, offset: 0).enumerated() {
            windows.append(QCWindow(id: id("test4k", i), split: "test4k", source: "bbb2160", center: w.center,
                                    stratum: w.stratum, motion: w.motion, variant: "sdr", note: "same frames as \(w.id)"))
        }
        for (i, w) in perStratum(6, offset: 4).enumerated() {
            windows.append(QCWindow(id: id("testHDR", i), split: "testHDR", source: "bbb1080", center: w.center,
                                    stratum: w.stratum, motion: w.motion, variant: "hdr", note: "same frames as \(w.id)"))
        }
        for (i, w) in perStratum(6, offset: 10).enumerated() {
            windows.append(QCWindow(id: id("testGrain", i), split: "testGrain", source: "bbb1080", center: w.center,
                                    stratum: w.stratum, motion: w.motion, variant: "grain", note: "same frames as \(w.id)"))
        }
        // Cuts: clean shot boundaries (no other cut within 8 frames), held-out part of the story first.
        let cutOK = shots.cuts.enumerated().filter { i, c in
            c > 8 && c < story - 8 && (i == 0 || c - shots.cuts[i - 1] > 8) && (i + 1 == shots.cuts.count || shots.cuts[i + 1] - c > 8)
                && !shots.inTransition(c, margin: 3)
        }.map(\.1)
        let cutPick = Array((cutOK.filter { Double($0) >= 0.8 * Double(story) } + cutOK.filter { Double($0) < 0.8 * Double(story) }.reversed()).prefix(16)).sorted()
        for (i, c) in cutPick.enumerated() {
            windows.append(QCWindow(id: id("cut", i), split: "cut", source: "bbb1080", center: c, stratum: "cut",
                                    motion: -1, variant: "sdr", note: "frame \(c) starts a new shot"))
        }
        // Fades and dissolves: every real one the scan found, plus dissolves between two test-part shots and fades
        // to black made by mixing the real frames with a linear 30-frame ramp (ground truth is the mix itself).
        var fi = 0
        for r in shots.transitions {
            var c = r.lowerBound + 2
            while c + 2 <= r.upperBound && fi < 8 {
                windows.append(QCWindow(id: id("fade", fi), split: "fade", source: "bbb1080", center: c, stratum: "real",
                                        motion: -1, variant: "sdr", note: "inside detected transition \(r.lowerBound)-\(r.upperBound)"))
                fi += 1; c += 8
            }
        }
        let movers = test.filter { $0.stratum != "low" }
        for (k, alpha) in [Float(0.2), 0.35, 0.5, 0.65, 0.8, 0.5].enumerated() where movers.count > 2 * k + 1 {
            let a = movers[2 * k], b = movers[movers.count - 1 - 2 * k]
            windows.append(QCWindow(id: id("fade", fi), split: "fade", source: "bbb1080", center: a.center, stratum: "dissolve",
                                    motion: max(a.motion, b.motion), variant: "dissolve",
                                    note: "30-frame dissolve from \(a.id) to \(b.id)", partner: b.center, alpha: alpha, alphaStep: 1.0 / 30))
            fi += 1
        }
        for (k, alpha) in [Float(0.3), 0.5, 0.7, 0.9].enumerated() where movers.count > 2 * k + 1 {
            let a = movers[2 * k + 1]
            windows.append(QCWindow(id: id("fade", fi), split: "fade", source: "bbb1080", center: a.center, stratum: "fadeToBlack",
                                    motion: a.motion, variant: "dissolve", note: "30-frame fade to black of \(a.id)",
                                    partner: -1, alpha: alpha, alphaStep: 1.0 / 30))
            fi += 1
        }
        for clip in SyntheticClips.all {
            for (i, c) in [5, 11, 17, 23, 29, 35].enumerated() {
                windows.append(QCWindow(id: "synthetic-\(clip.name)-\(i)", split: "synthetic", source: "synth-\(clip.name)", center: c,
                                        stratum: clip.name, motion: clip.motion, variant: "sdr"))
            }
        }
        return (windows, excluded)
    }
}

// MARK: - Synthetic hard clips (ffmpeg)

struct SyntheticClips {
    let name: String
    let motion: Float          // nominal displacement over 4 frames, px
    let graph: String          // ffmpeg lavfi input graph (nil inputs handled by `args`)
    let args: (URL) -> [String]

    static let frames = 40
    static let tagNV12 = "scale=out_color_matrix=bt709:out_range=tv,format=nv12"

    static var textImage: URL { QCBench.dataset.appendingPathComponent("synthetic/credits.png") }

    static let all: [SyntheticClips] = [
        SyntheticClips(name: "textscroll", motion: 96, graph: "credits text (CoreText) cropped with y=n*24: fast vertical scroll, 24 px/frame") { _ in
            ["-loop", "1", "-framerate", "60", "-i", textImage.path,
             "-vf", "crop=1920:1080:0:'n*24'," + tagNV12]
        },
        SyntheticClips(name: "finepattern", motion: 13.2, graph: "gray geq 128+100*sin(2pi(X+3.3N)/5.1)*sin(2pi Y/4.7): fine grating panning 3.3 px/frame (aliasing-ambiguous)") { _ in
            ["-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=60,format=gray,geq=lum='128+100*sin(2*PI*(X+N*3.3)/5.1)*sin(2*PI*Y/4.7)',format=rgb24," + tagNV12]
        },
        SyntheticClips(name: "thinlines", motion: 28, graph: "gray geq 1.5 px diagonal lines every 48 px moving 7 px/frame") { _ in
            ["-f", "lavfi", "-i", "color=c=black:s=1920x1080:r=60,format=gray,geq=lum='if(lt(mod(X+0.5*Y+1000-N*7,48),1.5),235,30)',format=rgb24," + tagNV12]
        },
        SyntheticClips(name: "occlusion", motion: 88, graph: "testsrc2 3840x2160 panning (6,3) px/frame behind a 480x480 testsrc moving -22 px/frame") { _ in
            ["-f", "lavfi", "-i", "testsrc2=s=3840x2160:r=60", "-f", "lavfi", "-i", "testsrc=s=480x480:r=60",
             "-filter_complex", "[0]crop=1920:1080:'n*6':'n*3'[bg];[bg][1]overlay=x='1300-n*22':y=300:shortest=1," + tagNV12]
        },
    ]

    /// Credits-like text, rendered with Core Text (FFmpeg here has no drawtext).
    static func renderText() throws {
        if FileManager.default.fileExists(atPath: textImage.path) { return }
        QCBench.ensureDir(textImage.deletingLastPathComponent())
        let w = 1920, h = 2400
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var rng = SplitMix(state: 7)
        let words = ["Animation", "Lighting", "Rendering", "Compositing", "Modeling", "Rigging", "Texturing", "Sound", "Music",
                     "Producer", "Director", "Technical", "Supervisor", "Assistant", "Pipeline", "Shading", "Layout", "Editing"]
        var text = ""
        for _ in 0..<70 {
            let n = Int(rng.next() % 4) + 2
            text += (0..<n).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ") + "\n"
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1)]
        let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 300, y: 0, width: 1320, height: h), transform: nil), nil)
        CTFrameDraw(frame, cg)
        let img = cg.makeImage()!
        let dest = CGImageDestinationCreateWithURL(textImage as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw LumoraError.unsupported("PNG write failed") }
    }

    /// Generates the clip as raw NV12 and caches every frame.
    func ensureCached() throws {
        if FrameCache.exists("synth-\(name)", "\(Self.frames - 1)") { return }
        if name == "textscroll" { try Self.renderText() }
        let tmp = QCBench.dataset.appendingPathComponent("tmp/\(name).nv12")
        QCBench.ensureDir(tmp.deletingLastPathComponent())
        try QCBench.ffmpegRun(args(tmp) + ["-frames:v", "\(Self.frames)", "-f", "rawvideo", "-pix_fmt", "nv12", tmp.path])
        let d = try Data(contentsOf: tmp)
        let fsz = 1920 * 1080 * 3 / 2
        guard d.count >= fsz * Self.frames else { throw LumoraError.unsupported("synthetic \(name): \(d.count) bytes") }
        for k in 0..<Self.frames {
            try FrameCache.save(NV12Frame(raw: d.subdata(in: (k * fsz)..<((k + 1) * fsz)), width: 1920, height: 1080)!, "synth-\(name)", "\(k)")
        }
        try? FileManager.default.removeItem(at: tmp)
    }
}

/// Synthetic film grain added by FFmpeg's noise filter in the coded (Y'CbCr) domain, seeded per window.
enum GrainMaker {
    static let filter = "noise=c0s=14:c0f=t:c1s=5:c1f=t:c2s=5:c2f=t:all_seed=%d"

    static func ensure(_ w: QCWindow) throws {
        let keys = ((w.center - 2)...(w.center + 2)).map { "\(w.id)_\($0)" }
        if keys.allSatisfy({ FrameCache.exists("bbb1080-grain", $0) }) { return }
        let tmpIn = QCBench.dataset.appendingPathComponent("tmp/\(w.id)-in.nv12"), tmpOut = QCBench.dataset.appendingPathComponent("tmp/\(w.id)-out.nv12")
        QCBench.ensureDir(tmpIn.deletingLastPathComponent())
        var raw = Data()
        for n in (w.center - 2)...(w.center + 2) {
            guard let f = FrameCache.load("bbb1080", "\(n)") else { throw LumoraError.decodeFailed("frame \(n) not cached") }
            raw += f.raw
        }
        try raw.write(to: tmpIn)
        let seed = 1000 + w.center % 100_000
        try QCBench.ffmpegRun(["-f", "rawvideo", "-pix_fmt", "nv12", "-s", "1920x1080", "-r", "60", "-i", tmpIn.path,
                               "-vf", "format=yuv420p," + String(format: filter, seed) + ",format=nv12",
                               "-f", "rawvideo", "-pix_fmt", "nv12", tmpOut.path])
        let d = try Data(contentsOf: tmpOut)
        let fsz = 1920 * 1080 * 3 / 2
        guard d.count == fsz * 5 else { throw LumoraError.unsupported("grain output \(d.count) bytes") }
        for (k, key) in keys.enumerated() {
            try FrameCache.save(NV12Frame(raw: d.subdata(in: (k * fsz)..<((k + 1) * fsz)), width: 1920, height: 1080)!, "bbb1080-grain", key)
        }
        try? FileManager.default.removeItem(at: tmpIn); try? FileManager.default.removeItem(at: tmpOut)
    }
}

// MARK: - Frames for a window, in the pipeline's encoded signal

final class FrameProvider {
    let gpu = BenchGPU.shared
    let sdr: SourceColor
    let conv: YUVConversion
    static let hdrColor = SourceColor(name: "HDR10 PQ BT.2020 (Lumora SDR->HDR10 grade, 10-bit)", transfer: .pq, gamut: .rec2020,
                                      legalToFull: false, confidence: 1)
    static let hdrRecipe = "Look.natural (SDR->HDR highlight expansion) graded to HDR10 1000 nits with GradeRenderer.encodeGrade, then quantized to 10-bit limited-range BT.2020 NCL Y'CbCr 4:4:4 and back"

    init(sdr: SourceColor, conv: YUVConversion) { self.sdr = sdr; self.conv = conv }

    func color(_ w: QCWindow) -> SourceColor { w.variant == "hdr" ? Self.hdrColor : sdr }

    func frame(_ w: QCWindow, _ n: Int) throws -> MTLTexture {
        switch w.variant {
        case "grain":
            guard let f = FrameCache.load("bbb1080-grain", "\(w.id)_\(n)") else { throw LumoraError.decodeFailed("grain frame \(w.id) \(n)") }
            return gpu.rgb(f, conv)
        case "hdr":
            guard let f = FrameCache.load("bbb1080", "\(n)") else { throw LumoraError.decodeFailed("frame \(n)") }
            return hdr(gpu.rgb(f, conv))
        case "dissolve":
            guard let f = FrameCache.load("bbb1080", "\(n)"), let p = w.partner, let a0 = w.alpha, let st = w.alphaStep else {
                throw LumoraError.decodeFailed("dissolve frame \(w.id) \(n)")
            }
            let a = gpu.rgb(f, conv)
            let b: MTLTexture
            if p < 0 {
                b = gpu.rgb(NV12Frame(width: f.width, height: f.height, y: Data(repeating: 16, count: f.width * f.height),
                                      uv: Data(repeating: 128, count: f.width * f.height / 2)), conv)
            } else {
                guard let g = FrameCache.load("bbb1080", "\(p + n - w.center)") else { throw LumoraError.decodeFailed("partner frame") }
                b = gpu.rgb(g, conv)
            }
            return gpu.blend(a, b, t: min(1, max(0, a0 + st * Float(n - w.center))))
        default:
            guard let f = FrameCache.load(w.source, "\(n)") else { throw LumoraError.decodeFailed("\(w.source) frame \(n)") }
            return gpu.rgb(f, conv)
        }
    }

    func hdr(_ t: MTLTexture) -> MTLTexture {
        let graded = gpu.texture(t.width, t.height, .rgba32Float)
        let u = UniformBuilder.make(source: sdr, params: Look.natural.params, target: .hdr10_1000, sceneExposureStops: 0,
                                    viewport: SIMD4<Float>(0, 0, Float(t.width), Float(t.height)))
        let r = GradeRenderer()
        gpu.run { cb in r.encodeGrade(cb, source: t, destination: graded, uniforms: u) }
        let q = gpu.texture(t.width, t.height)
        gpu.run { cb in gpu.dispatch(cb, "quant10", w: t.width, h: t.height) { $0.setTexture(graded, index: 0); $0.setTexture(q, index: 1) } }
        return q
    }
}

/// Serves precomputed frames to FrameStream as if they were a decoded file.
final class SequenceFrameSource: FrameSource {
    let width: Int, height: Int
    let fps: Double = 30
    var frameCount: Int { loaders.count }
    private let loaders: [() throws -> MTLTexture]
    private var nextIndex = 0, end = 0

    init(width: Int, height: Int, loaders: [() throws -> MTLTexture]) {
        self.width = width; self.height = height; self.loaders = loaders
    }

    func start(at frame: Int, count: Int?) throws {
        nextIndex = frame
        end = min(loaders.count, count.map { frame + $0 } ?? loaders.count)
    }

    func nextFrame() throws -> DecodedFrame? {
        guard nextIndex < end else { return nil }
        let t = try loaders[nextIndex]()
        defer { nextIndex += 1 }
        return DecodedFrame(texture: t, index: nextIndex, backing: [])
    }

    func cancel() { nextIndex = end }
}
