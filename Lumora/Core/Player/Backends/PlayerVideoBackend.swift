import Foundation
import Metal

/// A video decoder the player pulls frames from, on its own decode thread.
protocol PlayerVideoBackend: AnyObject {
    var choice: DecoderChoice { get }
    /// Positions the decoder; the first frame `next()` returns afterwards is exactly `atFrame`.
    func start(atFrame: Int) throws
    /// The next frame in display order; blocks until it is decoded. nil at the end (or after `interrupt`).
    func next() throws -> PlayerFrame?
    /// Makes a blocked `next()` return soon. Safe from any thread, never blocks.
    func interrupt()
    /// Kills child processes and closes pipes. Also done on deinit.
    func stop()
    /// Frame indices decoding can start at, when known.
    var randomAccessPoints: [Int]? { get }
    /// Set when the backend changed how it decodes after it was chosen (e.g. fell back to software).
    var note: String? { get }
}

extension PlayerVideoBackend {
    var note: String? { nil }
}

enum PlayerBackends {
    /// Frames the decoder may run ahead of the screen, from the RAM budget.
    static func queueCapacity(frameBytes: Int, budgetMB: Int) -> Int {
        let budget = max(64, budgetMB) << 20
        return max(4, min(240, budget / max(1, frameBytes)))
    }

    /// Frames larger than this are refused (a 16384×16384 4:4:4 16-bit frame is 1.6 GB).
    static let maxFrameBytes = 1_610_612_736

    static func make(info: MediaInfo, choice: DecoderChoice, settings: PlayerSettings, poolCapacity: Int) throws -> PlayerVideoBackend {
        switch choice.backend {
        case .avfoundation: return try AVFVideoBackend(info: info, choice: choice)
        case .ffmpeg: return try FFmpegPipeBackend(info: info, choice: choice, poolCapacity: poolCapacity)
        case .avm: return try AVMBackend(info: info, choice: choice, skipFilmGrain: settings.skipFilmGrain, poolCapacity: poolCapacity)
        }
    }
}

/// Decodes with FFmpeg and reads the decoder's own pixel format from a pipe, straight into pooled shared-memory
/// Metal buffers: no conversion, no per-frame allocation.
final class FFmpegPipeBackend: PlayerVideoBackend, @unchecked Sendable {
    let info: MediaInfo
    private(set) var choice: DecoderChoice
    private(set) var note: String?
    private let lock = NSLock()
    private var child: ChildProcess?
    private var layout: FrameLayout
    private var pool: BufferPool
    private let poolCapacity: Int
    private var nextIndex = 0
    private var discard = 0
    private var emitted = 0
    private var requested = 0
    private var readSinceStart = 0
    private var interrupted = false
    private var input: URL
    /// Frame rate of the file being read (a remuxed raw stream keeps the rate it was muxed at).
    private var inputRate: Double
    private var frameTable: FrameTable?
    /// Stop after this many frames (segment workers of the pre-decode cache).
    var limit: Int?
    var randomAccessPoints: [Int]? { frameTable?.keyFrames }

    init(info: MediaInfo, choice: DecoderChoice, poolCapacity: Int) throws {
        self.info = info
        self.choice = choice
        self.poolCapacity = poolCapacity
        self.input = info.url
        self.inputRate = info.fps
        guard let fmt = choice.pixelFormat, let l = FrameLayout.ffmpeg(fmt, width: info.video.width, height: info.video.height) else {
            throw PlayerError.unsupportedCodec("pixel format \(choice.pixelFormat ?? "?")")
        }
        guard l.frameBytes <= PlayerBackends.maxFrameBytes else { throw PlayerError.tooLarge(info.video.width, info.video.height) }
        layout = l
        pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: poolCapacity)
    }

    deinit { stop() }

    /// Exact presentation times and key frames, read in the background after the file opened.
    func setFrameTable(_ t: FrameTable) { lock.lock(); frameTable = t; lock.unlock() }

    /// Switches to an indexed copy of a raw elementary stream (remuxed to MP4), which seeks directly.
    func useIndexedCopy(_ url: URL, rate: Double) {
        lock.lock()
        input = url
        inputRate = rate
        choice.seekModel = .random
        lock.unlock()
    }

    private func pts(_ i: Int) -> Double {
        if let t = frameTable, t.timed, i < t.pts.count, t.pts.count >= (info.frameCount ?? 0) - 1 { return t.pts[i] }
        return Double(i) / info.fps
    }

    func start(atFrame i: Int) throws {
        lock.lock()
        let old = child
        child = nil
        interrupted = false
        lock.unlock()
        old?.terminate()
        let target = max(0, i)
        var args = ["-v", "error", "-nostdin"]
        if choice.hwaccel { args += ["-hwaccel", "videotoolbox"] }
        if let dec = choice.ffmpegDecoder { args += ["-c:v", dec] }
        lock.lock()
        let seekable = choice.seekModel == .random
        let src = input, rate = inputRate
        let table = frameTable.flatMap { $0.timed ? $0 : nil }
        lock.unlock()
        var outputSeek: [String] = []
        if seekable && target > 0 {
            // Two-stage seek, exact even with open GOPs (leading pictures before an intra frame, as VVenC and x265 write
            // them): a coarse input seek to at least one key frame before the target, then -copyts and an output -ss
            // that drops every frame shown before the target. The first frame out is exactly `target`.
            let t = info.startTime + (table.flatMap { target < $0.pts.count ? $0.pts[target] : nil } ?? Double(target) / rate)
            var coarse = t - 3
            if let table {
                let keys = table.keyFrames.filter { $0 <= target }
                if keys.count >= 2 { coarse = info.startTime + table.pts[keys[keys.count - 2]] - 0.5 / rate }
                else { coarse = 0 }
            }
            if coarse > 0 { args += ["-ss", String(format: "%.6f", coarse)] }
            args += ["-copyts"]
            outputSeek = ["-ss", String(format: "%.6f", max(0, t - min(0.25 / rate, 0.002)))]
            discard = 0
            nextIndex = target
        } else {
            discard = target
            nextIndex = 0
        }
        args += ["-i", src.path] + outputSeek + ["-map", "0:v:0", "-an", "-sn", "-dn", "-fps_mode", "passthrough",
                 "-f", "rawvideo", "-pix_fmt", choice.pixelFormat ?? "yuv420p", "-"]
        let c = try ChildProcess(tool: "ffmpeg", args: args, qos: .userInitiated)
        lock.lock()
        child = c
        let wasInterrupted = interrupted
        lock.unlock()
        if wasInterrupted { c.interrupt() }
        requested = target
        emitted = 0
        readSinceStart = 0
    }

    func next() throws -> PlayerFrame? {
        while true {
            lock.lock()
            let c = child
            let l = layout
            let p = pool
            lock.unlock()
            guard let c else { return nil }
            if let limit, emitted >= limit { c.interrupt(); return nil }
            guard let buf = p.acquire() else { return nil }
            let got = c.read(into: buf.bytes, count: l.frameBytes)
            if got == l.frameBytes {
                readSinceStart += 1
                if discard > 0 { discard -= 1; nextIndex += 1; continue }
                let idx = nextIndex
                nextIndex += 1
                emitted += 1
                return PlayerFrame(index: idx, pts: pts(idx), layout: l, planes: .buffer(buf), color: info.video.color)
            }
            lock.lock(); let wasInterrupted = interrupted; lock.unlock()
            if wasInterrupted { return nil }
            let status = c.waitForExit(timeout: 3)
            if got == 0 && readSinceStart == 0 && status != 0 {
                if choice.hwaccel, let fb = choice.softwareFallback {
                    // VideoToolbox couldn't start on this stream (profile, level, odd size): software decode.
                    switchToSoftware(fb)
                    try start(atFrame: requested)
                    continue
                }
                throw PlayerError.decoderFailed("ffmpeg", c.stderrTail)
            }
            if got > 0 {
                note = "The file ends early at frame \(nextIndex) (a partial frame was dropped)."
            }
            return nil
        }
    }

    private func switchToSoftware(_ decoder: String) {
        lock.lock()
        choice.hwaccel = false
        choice.hardware = false
        choice.ffmpegDecoder = decoder
        choice.tool = "ffmpeg \(decoder)"
        choice.pixelFormat = DecoderSelector.softwarePixelFormat(info.video)
        if let l = FrameLayout.ffmpeg(choice.pixelFormat!, width: info.video.width, height: info.video.height) {
            layout = l
            pool.close()
            pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: poolCapacity)
        }
        note = "VideoToolbox couldn't decode this stream, so FFmpeg decodes it in software (\(decoder))."
        lock.unlock()
    }

    func interrupt() {
        lock.lock()
        interrupted = true
        let c = child
        lock.unlock()
        c?.interrupt()
    }

    func stop() {
        lock.lock()
        let c = child
        child = nil
        interrupted = true
        lock.unlock()
        c?.terminate()
    }
}

/// AV2 through the AVM reference decoder. It reads only real files (not stdin) and writes 16-bit (or 8-bit)
/// little-endian planar frames with --rawvideo. It can't seek: it starts at a random access point
/// (--random-access-point-index) and the frames before the target are decoded and dropped.
final class AVMBackend: PlayerVideoBackend, @unchecked Sendable {
    let info: MediaInfo
    let choice: DecoderChoice
    let skipFilmGrain: Bool
    private let lock = NSLock()
    private var child: ChildProcess?
    private let layout: FrameLayout
    private let pool: BufferPool
    private var nextIndex = 0
    private var discard = 0
    private var emitted = 0
    private var interrupted = false
    var limit: Int?
    let raps: [Int]
    var randomAccessPoints: [Int]? { raps }

    init(info: MediaInfo, choice: DecoderChoice, skipFilmGrain: Bool, poolCapacity: Int) throws {
        self.info = info
        self.choice = choice
        self.skipFilmGrain = skipFilmGrain
        let d = info.av2 ?? AV2Details(temporalUnits: 0, randomAccessPoints: [0], sampleBytes: 2)
        raps = d.randomAccessPoints.isEmpty ? [0] : d.randomAccessPoints
        let l = FrameLayout.planar(width: info.video.width, height: info.video.height, chroma: info.video.chroma,
                                   sampleBytes: d.sampleBytes, bits: info.video.bitDepth)
        guard l.frameBytes <= PlayerBackends.maxFrameBytes else { throw PlayerError.tooLarge(info.video.width, info.video.height) }
        layout = l
        pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: poolCapacity)
    }

    deinit { stop() }

    /// The random access point decoding starts from for `frame`: (its position in the list, its frame index).
    func startPoint(for frame: Int) -> (Int, Int) {
        var k = 0
        for (n, r) in raps.enumerated() where r <= frame { k = n }
        return (k, raps[k])
    }

    func start(atFrame i: Int) throws {
        lock.lock()
        let old = child
        child = nil
        interrupted = false
        lock.unlock()
        old?.terminate()
        let (k, rapFrame) = startPoint(for: max(0, i))
        var args = ["--rawvideo", "-o", "-"]
        if k > 0 { args.append("--random-access-point-index=\(k)") }
        if skipFilmGrain { args.append("--skip-film-grain") }
        discard = max(0, i) - rapFrame
        // No --limit: avmdec counts decoded frames there, hidden ones included. `limit` is enforced on shown frames.
        args.append(info.url.path)
        nextIndex = rapFrame
        emitted = 0
        let c = try ChildProcess(tool: "avmdec", args: args, qos: .utility)
        lock.lock()
        child = c
        let wasInterrupted = interrupted
        lock.unlock()
        if wasInterrupted { c.interrupt() }
    }

    func next() throws -> PlayerFrame? {
        while true {
            lock.lock(); let c = child; lock.unlock()
            guard let c else { return nil }
            if let limit, emitted >= limit { c.interrupt(); return nil }
            guard let buf = pool.acquire() else { return nil }
            let got = c.read(into: buf.bytes, count: layout.frameBytes)
            if got == layout.frameBytes {
                if discard > 0 { discard -= 1; nextIndex += 1; continue }
                let idx = nextIndex
                nextIndex += 1
                emitted += 1
                return PlayerFrame(index: idx, pts: Double(idx) / info.fps, layout: layout, planes: .buffer(buf), color: info.video.color)
            }
            lock.lock(); let wasInterrupted = interrupted; lock.unlock()
            if wasInterrupted { return nil }
            let status = c.waitForExit(timeout: 3)
            if emitted == 0, discard > 0 || got == 0, let status, status != 0 {
                throw PlayerError.decoderFailed("avmdec", c.stderrTail)
            }
            return nil
        }
    }

    func interrupt() {
        lock.lock(); interrupted = true; let c = child; lock.unlock()
        c?.interrupt()
    }

    func stop() {
        lock.lock(); let c = child; child = nil; interrupted = true; lock.unlock()
        c?.terminate()
    }
}
