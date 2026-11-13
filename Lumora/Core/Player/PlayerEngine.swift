import Foundation
import Observation
import QuartzCore
import Metal

/// Live numbers for the info overlay.
struct PlayerStats: Equatable {
    var shown = 0
    var dropped = 0
    var late = 0
    var decodeFPS = 0.0
    var realTimeFactor = 0.0
    var queueDepth = 0
    var queueCapacity = 0
    var cacheBytes: Int64 = 0
}

/// Runs a backend on its own thread (decoders block on read(2), so they stay off the Swift concurrency pool) and
/// fills the frame queue. Seeks restart it; the queue's generation tells stale frames apart.
final class DecodeWorker: @unchecked Sendable {
    enum Event { case started(Int), endOfStream(lastIndex: Int), failed(Error) }

    let queue: FrameQueue
    private(set) var backend: PlayerVideoBackend
    private let cond = NSCondition()
    private var pendingStart: Int?
    private var running = false
    private var quit = false
    private var thread: Thread?
    private var decoded = 0
    private var decodeSeconds = 0.0
    private var lastIndex = -1
    var onEvent: (@Sendable (Event) -> Void)?

    init(backend: PlayerVideoBackend, queue: FrameQueue) {
        self.backend = backend
        self.queue = queue
    }

    func launch(at frame: Int) {
        cond.lock(); pendingStart = frame; cond.unlock()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "Lumora player decode"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Restarts decoding at `frame`. Safe from the main thread: it never blocks.
    func restart(at frame: Int) {
        // Interrupt under the lock: the worker reads pendingStart under it before starting, so the interrupt always
        // hits the run being replaced, never the new one.
        cond.lock()
        pendingStart = frame
        backend.interrupt()
        cond.signal()
        cond.unlock()
        queue.flush()
    }

    /// Swaps in a new backend (pre-decode cache), starting at `frame`.
    func replace(backend b: PlayerVideoBackend, at frame: Int) {
        cond.lock()
        let old = backend
        backend = b
        pendingStart = frame
        // The decode thread may still be inside old.next(); it stops the old backend itself once it returns. Added
        // under the lock: the decode thread takes `retired` under it before it starts the new backend.
        retired.append(old)
        old.interrupt()
        cond.signal()
        cond.unlock()
        queue.flush()
    }

    func shutdown() {
        cond.lock()
        quit = true
        backend.interrupt()
        cond.signal()
        cond.unlock()
        queue.close()
    }

    private var retired: [PlayerVideoBackend] = []

    /// Decoded frames per second of decoder time, over the last measurement window.
    func takeSpeed() -> Double? {
        cond.lock(); defer { cond.unlock() }
        guard decodeSeconds > 0.2, decoded >= 3 else { return nil }
        let fps = Double(decoded) / decodeSeconds
        decoded = 0; decodeSeconds = 0
        return fps
    }

    private func loop() {
        while true {
            cond.lock()
            while !quit && pendingStart == nil && !running { cond.wait() }
            if quit { cond.unlock(); break }
            if let s = pendingStart {
                pendingStart = nil
                let b = backend
                let old = retired
                retired = []
                cond.unlock()
                old.forEach { $0.stop() }
                do {
                    try b.start(atFrame: s)
                    cond.lock(); running = pendingStart == nil; lastIndex = s - 1; cond.unlock()
                    onEvent?(.started(s))
                } catch {
                    cond.lock(); running = false; let again = pendingStart != nil; cond.unlock()
                    if !again { onEvent?(.failed(error)) }
                }
                continue
            }
            let b = backend
            let gen = queue.generation
            cond.unlock()
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                if let f = try b.next() {
                    let dt = CFAbsoluteTimeGetCurrent() - t0
                    cond.lock(); decoded += 1; decodeSeconds += dt; lastIndex = f.index; cond.unlock()
                    queue.push(f, generation: gen)
                } else {
                    cond.lock()
                    let interrupted = pendingStart != nil || quit || b !== backend
                    if !interrupted { running = false }
                    let last = lastIndex
                    cond.unlock()
                    if !interrupted { onEvent?(.endOfStream(lastIndex: last)) }
                }
            } catch {
                cond.lock()
                let interrupted = pendingStart != nil || quit || b !== backend
                if !interrupted { running = false }
                cond.unlock()
                if !interrupted { onEvent?(.failed(error)) }
            }
        }
        cond.lock(); let old = retired; retired = []; cond.unlock()
        old.forEach { $0.stop() }
        backend.stop()
    }
}

/// The token of the audio start that may still run, readable from the background start.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token = 0
    func set(_ t: Int) { lock.lock(); token = t; lock.unlock() }
    func isCurrent(_ t: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return token == t }
}

/// One player: probes the file, picks the decoder, decodes on its own thread, keeps audio and video in sync on the
/// audio clock (or the host clock when there is no audio), and hands the view the frame due at each display refresh.
@MainActor
@Observable
final class PlayerEngine {
    enum Phase: Equatable {
        case idle, opening, ready, buffering, ended
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var info: MediaInfo?
    private(set) var choice: DecoderChoice?
    private(set) var isPlaying = false
    /// 1, 2 or 4 forward; reverse play steps backward.
    private(set) var rate: Double = 1
    private(set) var reversing = false
    private(set) var currentIndex = 0
    private(set) var stats = PlayerStats()
    private(set) var bufferingReason: String?
    private(set) var bufferingProgress = 0.0
    private(set) var bufferingETA: Double?
    private(set) var message: String?
    private(set) var cachedRanges: [Range<Int>] = []
    private(set) var keyFrames: [Int] = []
    private(set) var toneMap: ToneMapSummary?
    private(set) var renderToken = 0
    private(set) var audioActive = false
    private(set) var preDecoding = false
    private(set) var decoderNote: String?
    var loop = false
    var showInfo = false
    var volume: Float = 1 { didSet { applyVolume() } }
    var interpret: InterpretMode = .auto { didSet { renderToken += 1 } }
    var audioTrack = 0 { didSet { if isPlaying { restartAudio() } } }
    var settings = PlayerSettings.current { didSet { renderToken += 1 } }

    var frameCount: Int { max(1, info?.estimatedFrameCount ?? 1) }
    var fps: Double { info?.fps ?? 24 }
    var currentTime: Double { Double(currentIndex) / fps }
    var duration: Double { Double(frameCount) / fps }
    var errorMessage: String? { if case .failed(let m) = phase { return m }; return nil }

    @ObservationIgnored private(set) var currentFrame: PlayerFrame?
    @ObservationIgnored private var worker: DecodeWorker?
    @ObservationIgnored private var queue: FrameQueue?
    @ObservationIgnored private var audio: AudioOutput?
    @ObservationIgnored private var hostClock = HostClock()
    @ObservationIgnored private var awaiting: Int?
    /// The highest frame index a decoder has delivered (it exists), and whether a seek is looking for the real end.
    @ObservationIgnored private var highestSeen = -1
    @ObservationIgnored private var endSearch = false
    @ObservationIgnored private var endOfStream: Int?
    @ObservationIgnored private var lastStatsUpdate: CFTimeInterval = 0
    @ObservationIgnored private var reverseTimer: Timer?
    @ObservationIgnored private var messageTimer: Timer?
    @ObservationIgnored private var cache: PreDecodeCache?
    @ObservationIgnored private var preDecoder: PreDecoder?
    @ObservationIgnored private var slowSince: CFTimeInterval?
    @ObservationIgnored private var audioStarting = 0
    @ObservationIgnored private let audioGate = AudioGate()
    private static let audioStartQueue = DispatchQueue(label: "Lumora player audio start", qos: .userInteractive)
    @ObservationIgnored private var frameLayout: FrameLayout?
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var speedSamples: [Double] = []
    /// Tests run audio through an offline engine and drive the clock themselves.
    @ObservationIgnored var manualAudio = false
    @ObservationIgnored var clockOverride: ((CFTimeInterval) -> Double)?
    @ObservationIgnored var capabilities: DecoderCapabilities?
    /// Forces the pre-decode cache on (tests), or off.
    @ObservationIgnored var preDecodeOverride: Bool?
    @ObservationIgnored var fpsOverride: (Int, Int)?
    /// Tests substitute a backend (e.g. a deliberately slow one).
    @ObservationIgnored var backendFactory: ((MediaInfo, DecoderChoice, Int) throws -> PlayerVideoBackend)?

    init() {}

    var audioOutputForTests: AudioOutput? { audio }
    var queueDepthForTests: Int? { queue?.count }

    // MARK: Opening

    func open(_ url: URL) {
        stop()
        openGeneration += 1
        let gen = openGeneration
        phase = .opening
        let caps = capabilities ?? DecoderCapabilities.current
        let prefs = settings
        let rateOverride = fpsOverride ?? Self.rememberedRate(for: url)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> (MediaInfo, DecoderChoice) in
                let info = try MediaProbe.probe(url, caps: caps, fpsOverride: rateOverride)
                return (info, try DecoderSelector.choose(info, caps: caps, prefs: prefs))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.openGeneration else { return }
                    switch result {
                    case .success(let (info, choice)): self.start(info: info, choice: choice, caps: caps)
                    case .failure(let e): self.fail(e)
                    }
                }
            }
        }
    }

    /// Opens an already-probed file with a given decoder (tests).
    func open(info: MediaInfo, choice: DecoderChoice) {
        stop()
        openGeneration += 1
        start(info: info, choice: choice, caps: capabilities ?? DecoderCapabilities.current)
    }

    /// Blocks until opening finished (tests).
    func waitUntilOpened(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while phase == .opening && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return phase != .opening
    }

    private func fail(_ e: Error) {
        let msg = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        phase = .failed(msg)
        Log.warning(.app, "Player: \(msg)")
    }

    private func start(info: MediaInfo, choice: DecoderChoice, caps: DecoderCapabilities) {
        self.info = info
        self.choice = choice
        let bytes = Self.frameBytes(info: info, choice: choice)
        let capacity = PlayerBackends.queueCapacity(frameBytes: bytes, budgetMB: settings.bufferBudgetMB)
        let q = FrameQueue(capacity: capacity)
        queue = q
        stats = PlayerStats(queueCapacity: capacity)
        do {
            let backend: PlayerVideoBackend
            let wantsCache = preDecodeOverride ?? (choice.backend == .avm)
            if wantsCache, let cached = try makeCacheBackend(info: info, choice: choice, capacity: capacity) {
                backend = cached
            } else if let make = backendFactory {
                backend = try make(info, choice, capacity + 6)
            } else {
                backend = try PlayerBackends.make(info: info, choice: choice, settings: settings, poolCapacity: capacity + 6)
                if choice.backend == .avm {
                    decoderNote = "Not enough free space for the pre-decode cache: AV2 plays as fast as avmdec decodes, with pauses to buffer."
                }
            }
            let w = DecodeWorker(backend: backend, queue: q)
            w.onEvent = { [weak self] e in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(e) } }
            }
            worker = w
            awaiting = 0
            phase = .ready
            w.launch(at: 0)
            Log.info(.app, "Player: \(info.url.lastPathComponent) · \(info.video.codec) \(info.video.width)×\(info.video.height) · \(choice.tool)")
        } catch {
            fail(error)
            return
        }
        if let raps = info.av2?.randomAccessPoints { keyFrames = raps }
        indexInBackground(info: info, choice: choice, caps: caps)
    }

    static func frameBytes(info: MediaInfo, choice: DecoderChoice) -> Int {
        let v = info.video
        if let fmt = choice.pixelFormat, let l = FrameLayout.ffmpeg(fmt, width: v.width, height: v.height) { return l.frameBytes }
        let sb = choice.backend == .avm ? (info.av2?.sampleBytes ?? 2) : (v.bitDepth > 8 ? 2 : 1)
        return FrameLayout.planar(width: v.width, height: v.height, chroma: v.chroma, sampleBytes: sb, bits: v.bitDepth).frameBytes
    }

    /// The pre-decode cache: segment workers fill it, playback reads it. nil when the disk is too full for it.
    /// `template`: the FFmpeg backend playing now, when switching to the cache mid-file. Segment workers then read
    /// what it reads (a raw stream's indexed copy, with its frame table), never the raw stream itself, whose
    /// timestamps don't follow the player's rate.
    private func makeCacheBackend(info: MediaInfo, choice: DecoderChoice, capacity: Int,
                                  template: FFmpegPipeBackend? = nil) throws -> PlayerVideoBackend? {
        let v = info.video
        let layout: FrameLayout
        if choice.backend == .ffmpeg, let fmt = choice.pixelFormat, let l = FrameLayout.ffmpeg(fmt, width: v.width, height: v.height) {
            layout = l
        } else if choice.backend == .avm {
            layout = FrameLayout.planar(width: v.width, height: v.height, chroma: v.chroma, sampleBytes: info.av2?.sampleBytes ?? 2, bits: v.bitDepth)
        } else {
            return nil
        }
        let free = PreDecodeCache.freeSpace(PreDecodeCache.root.deletingLastPathComponent())
        guard free - PreDecodeCache.floorBytes > Int64(layout.frameBytes) * 48 else { return nil }
        let options = "\(choice.tool)|grain:\(settings.skipFilmGrain ? 0 : 1)|\(layout.frameBytes)"
        let c = try PreDecodeCache(source: info.url, options: options, frameBytes: layout.frameBytes,
                                   capBytes: Int64(settings.cacheCapGB * 1_073_741_824))
        let count = info.frameCount ?? 10_000_000
        let raps = choice.backend == .avm ? (info.av2?.randomAccessPoints ?? [0]) : (keyFrames.isEmpty ? [0] : keyFrames)
        let segments = PreDecoder.segments(randomAccessPoints: raps, frameCount: count)
        let prefs = settings
        let factory: PreDecoder.Factory = { start, n in
            if choice.backend == .avm {
                let b = try AVMBackend(info: info, choice: choice, skipFilmGrain: prefs.skipFilmGrain, poolCapacity: 4)
                b.limit = n
                return b
            }
            if let template { return try template.segmentWorker(limit: n) }
            let b = try FFmpegPipeBackend(info: info, choice: choice, poolCapacity: 4)
            b.limit = n
            return b
        }
        let pd = PreDecoder(cache: c, segments: segments, workers: prefs.parallelDecoders, factory: factory)
        cache = c
        preDecoder = pd
        preDecoding = true
        pd.start()
        return CacheBackend(info: info, choice: choice, layout: layout, cache: c, preDecoder: pd, randomAccessPoints: raps, poolCapacity: capacity + 6)
    }

    /// Exact frame table and, for raw elementary streams, an indexed MP4 copy so seeking is direct.
    private func indexInBackground(info: MediaInfo, choice: DecoderChoice, caps: DecoderCapabilities) {
        guard choice.backend == .ffmpeg, caps.hasFFprobe, let backend = worker?.backend as? FFmpegPipeBackend else { return }
        let gen = openGeneration
        DispatchQueue.global(qos: .utility).async { [weak backend] in
            var source = info.url
            var note: String?
            if info.isRawElementaryStream {
                if let copy = Self.remuxRawStream(info) {
                    backend?.useIndexedCopy(copy, rate: info.fps)
                    source = copy
                } else {
                    note = "Raw stream without an index: seeking decodes forward from the start."
                }
            }
            let table = try? FrameTable.read(source, timeout: 120)
            if let table, table.count > 0 { backend?.setFrameTable(table) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.openGeneration else { return }
                    if let note { self.decoderNote = note }
                    if let table, table.count > 0 {
                        self.info?.frameCount = table.count
                        if table.timed { self.keyFrames = table.keyFrames }
                        if source != info.url { self.choice?.seekModel = .random }
                    }
                }
            }
        }
    }

    /// `MP4Box -add stream:fps=R -new copy.mp4` into the player cache. Skipped when space is short.
    nonisolated static func remuxRawStream(_ info: MediaInfo) -> URL? {
        guard [.vvc, .hevc, .h264, .av1].contains(info.video.codec), ToolLocator.isAvailable("MP4Box") else { return nil }
        let dir = PreDecodeCache.root.appendingPathComponent("Remux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let free = PreDecodeCache.freeSpace(dir)
        guard free > info.fileSize + PreDecodeCache.floorBytes else { return nil }
        let out = dir.appendingPathComponent(PreDecodeCache.key(source: info.url, options: "remux \(info.rateNum)/\(info.rateDen)") + ".mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".mp4")
        let fps = String(format: "%.6f", info.fps)
        do {
            try ToolLocator.run("MP4Box", ["-add", "\(info.url.path):fps=\(fps)", "-new", tmp.path],
                                timeout: max(60, Double(info.fileSize) / 50_000_000))
            try FileManager.default.moveItem(at: tmp, to: out)
            return out
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }

    private static func rememberedRate(for url: URL) -> (Int, Int)? {
        guard let s = Prefs.store.string(forKey: "player.rate." + url.path) else { return nil }
        let p = s.split(separator: "/").compactMap { Int($0) }
        return p.count == 2 && p[0] > 0 && p[1] > 0 ? (p[0], p[1]) : nil
    }

    /// The frame rate for a raw stream that carries none; remembered per file.
    func setFrameRate(_ num: Int, _ den: Int) {
        guard let url = info?.url, num > 0, den > 0 else { return }
        Prefs.store.set("\(num)/\(den)", forKey: "player.rate." + url.path)
        let at = currentTime
        fpsOverride = (num, den)
        open(url)
        pendingSeekSeconds = at
    }
    @ObservationIgnored private var pendingSeekSeconds: Double?

    // MARK: Worker events

    private func handle(_ e: DecodeWorker.Event) {
        switch e {
        case .started:
            if let n = worker?.backend.note { decoderNote = n }
            if let c = (worker?.backend as? FFmpegPipeBackend)?.choice, c != choice { choice?.tool = c.tool; choice?.hardware = c.hardware }
        case .endOfStream(let last):
            if let a = awaiting, last < a {
                recoverPastEnd(target: a)
                return
            }
            if last >= 0 { highestSeen = max(highestSeen, last) }
            endOfStream = last
            if let n = worker?.backend.note { decoderNote = n }
            if last >= 0, let i = info, (i.frameCount ?? Int.max) > last + 1 || i.frameCount == nil {
                info?.frameCount = last + 1
            }
            if endSearch, last >= 0 {
                // The end was found: land on the last frame the user was heading for.
                endSearch = false
                if currentIndex != last { seek(toFrame: last) }
            }
        case .failed(let err):
            if case .ready = phase, currentFrame != nil {
                // Mid-stream decoder error: keep what was shown and say why playback stopped.
                pause()
                showMessage((err as? LocalizedError)?.errorDescription ?? err.localizedDescription, seconds: 10)
            } else {
                fail(err)
            }
        }
    }

    /// A seek ran past the real end: the frame count was an estimate (a container duration that includes a longer
    /// audio track, before the exact frame table arrives) and the decoder ended without delivering `a`. Frames from
    /// `a` on don't exist, so bisect between the highest frame seen and `a` until the decoder delivers, then land
    /// on the last frame (handled at that run's end of stream).
    private func recoverPastEnd(target a: Int) {
        guard a > 0 else {
            awaiting = nil
            endOfStream = -1
            return
        }
        info?.frameCount = a
        let low = max(0, min(highestSeen, a - 1))
        seek(toFrame: a - low <= 1 ? low : low + (a - low) / 2)
        endSearch = true
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard queue != nil, phase != .opening else { return }
        if case .failed = phase { return }
        stopReverse()
        if phase == .ended || (endOfStream != nil && currentIndex >= frameCount - 1) { seek(toFrame: 0) }
        isPlaying = true
        phase = .ready
        if preDecoding, needsMoreCache() { enterBuffering(cacheReason()); return }
        startClock()
    }

    func pause() {
        stopReverse()
        isPlaying = false
        rate = 1
        stopAudio()
        hostClock.set(media: currentFrame?.pts ?? currentTime, host: CACurrentMediaTime(), rate: 0)
        if phase == .buffering { phase = .ready; bufferingReason = nil }
    }

    /// J / K / L: K pauses; L plays forward, then 2x, then 4x; J plays backward by stepping.
    func jkl(_ key: Character) {
        switch key {
        case "k", "K": pause()
        case "l", "L":
            if reversing { stopReverse() }
            if !isPlaying { rate = 1; play() } else { setRate(rate >= 4 ? 4 : rate * 2) }
        case "j", "J":
            if choice?.backend == .avm && !preDecoding {
                showMessage("Reverse play needs the AV2 pre-decode cache (avmdec can't step backward).", seconds: 4)
                return
            }
            pause()
            reversing = true
            reverseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.reversing else { return }
                    if self.currentIndex <= 0 { self.stopReverse(); return }
                    if self.awaiting == nil { self.step(-1, keepReverse: true) }
                }
            }
        default: break
        }
    }

    private func stopReverse() {
        reversing = false
        reverseTimer?.invalidate()
        reverseTimer = nil
    }

    func setRate(_ r: Double) {
        rate = r
        guard isPlaying else { return }
        startClock()
    }

    private func startClock() {
        let at = currentFrame?.pts ?? currentTime
        stopAudio()
        if rate == 1, let info, !info.audio.isEmpty, !reversing {
            // Hold the video clock until audio is flowing, then audio drives it.
            hostClock.set(media: at, host: CACurrentMediaTime(), rate: 0)
            startAudio(at: at)
        } else {
            hostClock.set(media: at, host: CACurrentMediaTime(), rate: rate)
            applyVolume()
        }
    }

    private func restartAudio() { if isPlaying { startClock() } }

    /// Silences audio now and cancels a start still running in the background (it undoes itself when it finishes).
    private func stopAudio() {
        audioStarting += 1
        audioGate.set(audioStarting)
        audio?.stop()
        audioActive = false
    }

    private func startAudio(at t: Double) {
        guard let info else { return }
        audioStarting += 1
        let token = audioStarting
        let gate = audioGate
        gate.set(token)
        let track = min(audioTrack, max(0, info.audio.count - 1))
        let manual = manualAudio
        if audio == nil { audio = try? AudioOutput(manualRendering: manual) }
        guard let out = audio else { hostClock.set(media: t, host: CACurrentMediaTime(), rate: rate); return }
        // Starts run one at a time; each one checks the gate after its slow parts (spawning the decoder, pre-rolling a
        // second of audio): a pause, seek or newer start in the meantime makes it stop what it started.
        Self.audioStartQueue.async {
            guard gate.isCurrent(token) else { return }
            var ok = false
            if let src = try? PlayerAudio.makeSource(info: info, track: track, at: t) {
                if gate.isCurrent(token) { ok = (try? out.start(source: src, at: t)) != nil } else { src.stop() }
                if !gate.isCurrent(token) { out.stop(); return }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.audioStarting else { return }      // superseded: the newer start owns the output
                    guard self.isPlaying else { self.stopAudio(); return }
                    if ok {
                        self.audioActive = true
                        self.applyVolume()
                    } else {
                        self.hostClock.set(media: t, host: CACurrentMediaTime(), rate: self.rate)
                        self.showMessage("The audio track couldn't be decoded; playing video only.", seconds: 5)
                    }
                }
            }
        }
    }

    private func applyVolume() {
        audio?.volume = rate == 1 ? volume : 0
    }

    /// The media time the frame shown at host time `host` should have.
    func clockTime(atHost host: CFTimeInterval) -> Double {
        if let o = clockOverride { return o(host) }
        if audioActive, let a = audio?.mediaTime(atHost: host) { return a }
        return hostClock.time(atHost: host)
    }

    // MARK: Seeking and stepping

    func seek(toFrame i: Int) {
        guard let worker else { return }
        let target = max(0, min(i, frameCount - 1))
        endOfStream = nil
        endSearch = false
        stopReverse()
        let wasPlaying = isPlaying
        stopAudio()
        awaiting = target
        currentIndex = target
        worker.restart(at: target)
        if let raps = worker.backend.randomAccessPoints, choice?.seekModel == .fromRandomAccessPoint, !preDecoding {
            let rap = raps.last { $0 <= target } ?? 0
            if target - rap > 0 {
                showMessage("The AV2 reference decoder can't jump; decoding forward from the key frame at \(Self.timecode(Double(rap) / fps)).", seconds: 4)
            }
        } else if choice?.seekModel == .fromStart, target > 0 {
            showMessage("This raw stream has no index yet; decoding forward from the start.", seconds: 4)
        }
        if phase == .ended { phase = .ready }
        isPlaying = wasPlaying
        hostClock.set(media: Double(target) / fps, host: CACurrentMediaTime(), rate: 0)
    }

    func seek(toSeconds t: Double) { seek(toFrame: Int((t * fps).rounded())) }

    func step(_ delta: Int, keepReverse: Bool = false) {
        if !keepReverse { stopReverse() }
        if isPlaying { pause() }
        let target = max(0, min(frameCount - 1, currentIndex + delta))
        guard target != currentIndex || awaiting != nil else { return }
        if delta > 0, let q = queue, let f = q.take(atLeast: target), f.index == target {
            present(f)
            return
        }
        if delta < 0, choice?.backend == .avm, !preDecoding {
            showMessage("Stepping back needs a re-decode from the key frame.", seconds: 3)
        }
        seek(toFrame: target)
    }

    func stepSeconds(_ s: Double) { seek(toFrame: currentIndex + Int((s * fps).rounded())) }

    // MARK: Display

    private func present(_ f: PlayerFrame) {
        currentFrame = f
        highestSeen = max(highestSeen, f.index)
        if currentIndex != f.index { currentIndex = f.index }
        stats.shown += 1
        renderToken &+= 1
        preDecoder?.setPlayhead(f.index)
    }

    /// Called by the view at every display refresh with the time the next frame will be on screen. Returns the frame
    /// to draw (the current one when nothing new is due).
    func frameForDisplay(targetHost: CFTimeInterval) -> PlayerFrame? {
        guard let queue else { return currentFrame }
        let now = CACurrentMediaTime()
        if now - lastStatsUpdate > 0.5 { updateStats(now) }
        if let a = awaiting {
            guard let f = queue.take(atLeast: a) else { return currentFrame }
            awaiting = nil
            present(f)
            if let s = pendingSeekSeconds { pendingSeekSeconds = nil; seek(toSeconds: s); return currentFrame }
            if isPlaying && phase != .buffering { startClock() }
            return currentFrame
        }
        guard isPlaying else { return currentFrame }
        if phase == .buffering {
            updateBuffering()
            return currentFrame
        }
        let t = clockTime(atHost: targetHost)
        let (f, dropped) = queue.take(dueAt: t, tolerance: 0.25 / fps)
        if let f {
            stats.dropped += dropped
            present(f)
        }
        let behind = t - (currentFrame?.pts ?? 0)
        if f == nil, let end = endOfStream, queue.count == 0, currentIndex >= end, behind > 1 / fps {
            handleEnd()
        } else if f == nil, behind > 1.5 / fps {
            stats.late += 1
        }
        // More than half a second behind the clock: the decoder can't keep up. Stop and buffer instead of stuttering.
        if behind > max(0.5, 3 / fps), endOfStream == nil || queue.count > 0 {
            enterBuffering(preDecoding ? cacheReason() : "Decoding is slower than real time (\(String(format: "%.2f", stats.realTimeFactor))×): buffering ahead.")
        }
        return currentFrame
    }

    private func handleEnd() {
        if loop {
            seek(toFrame: 0)
        } else {
            pause()
            phase = .ended
        }
    }

    // MARK: Buffering

    private func enterBuffering(_ reason: String) {
        stopAudio()
        hostClock.set(media: currentFrame?.pts ?? currentTime, host: CACurrentMediaTime(), rate: 0)
        phase = .buffering
        bufferingReason = reason
        updateBuffering()
        considerPreDecode()
    }

    private func cacheReason() -> String {
        let speed = preDecoder?.framesPerSecond ?? 0
        let workers = preDecoder?.workers ?? 1
        let what = choice?.backend == .avm ? "AV2 with the AVM reference decoder" : "with \(choice?.tool ?? "the decoder")"
        let rate = speed > 0 ? String(format: " (≈%.1f fps × %d worker%@)", speed / Double(workers), workers, workers == 1 ? "" : "s") : ""
        let why = choice?.backend == .avm ? " AV2 has no fast decoder yet." : " The decoder is slower than real time on this Mac right now."
        return "Pre-decoding \(what)\(rate).\(why)"
    }

    /// Frames that must be cached ahead before playback can run to the end without an underrun.
    private func requiredAhead() -> Int {
        let speed = preDecoder?.framesPerSecond ?? 0
        let remaining = max(0, frameCount - currentIndex)
        let factor = min(1, speed / max(1, fps))
        let need = max(3 * fps, Double(remaining) * (1 - factor))
        return min(remaining, Int(need.rounded(.up)))
    }

    private func needsMoreCache() -> Bool {
        guard let cache else { return false }
        let need = requiredAhead()
        return need > 0 && cache.contiguous(from: currentIndex) < need && !(preDecoder?.isDone ?? true)
    }

    private func updateBuffering() {
        guard let queue else { return }
        if preDecoding, let cache {
            let need = max(1, requiredAhead())
            let have = cache.contiguous(from: currentIndex)
            bufferingProgress = min(1, Double(have) / Double(need))
            let speed = preDecoder?.framesPerSecond ?? 0
            bufferingETA = speed > 0 ? Double(max(0, need - have)) / speed : nil
            bufferingReason = cacheReason()
            if have >= need || (preDecoder?.isDone ?? false) || (preDecoder?.endFrame.map { currentIndex + have >= $0 } ?? false) {
                resumeFromBuffering()
            }
        } else {
            bufferingProgress = Double(queue.count) / Double(queue.capacity)
            bufferingETA = nil
            if queue.count >= queue.capacity - 1 || endOfStream != nil { resumeFromBuffering() }
        }
    }

    private func resumeFromBuffering() {
        phase = .ready
        bufferingReason = nil
        bufferingETA = nil
        if isPlaying { startClock() }
    }

    /// A decoder that stays below real time switches to the pre-decode cache (when it can start mid-file).
    private func considerPreDecode() {
        guard !preDecoding, preDecodeOverride != false, let info, let choice, choice.backend == .ffmpeg,
              let live = worker?.backend as? FFmpegPipeBackend, live.choice.seekModel == .random,
              stats.realTimeFactor > 0, stats.realTimeFactor < 1.05, let q = queue else { return }
        do {
            guard let b = try makeCacheBackend(info: info, choice: live.choice, capacity: q.capacity, template: live) else { return }
            worker?.replace(backend: b, at: currentIndex)
            awaiting = currentIndex
            decoderNote = "\(choice.tool) decodes at \(String(format: "%.2f", stats.realTimeFactor))× real time here, so frames are pre-decoded to disk first."
        } catch {
            Log.warning(.app, "Player: pre-decode cache unavailable: \(error.localizedDescription)")
        }
    }

    private func updateStats(_ now: CFTimeInterval) {
        lastStatsUpdate = now
        if preDecoding, let pd = preDecoder {
            stats.decodeFPS = pd.framesPerSecond
        } else if let s = worker?.takeSpeed() {
            speedSamples.append(s)
            if speedSamples.count > 4 { speedSamples.removeFirst() }
            stats.decodeFPS = speedSamples.reduce(0, +) / Double(speedSamples.count)
        }
        stats.realTimeFactor = stats.decodeFPS / max(1, fps)
        stats.queueDepth = queue?.count ?? 0
        if let cache {
            stats.cacheBytes = cache.bytesOnDisk
            cachedRanges = cache.cachedRanges
            if let e = preDecoder?.endFrame, (info?.frameCount ?? Int.max) > e { info?.frameCount = e }
        }
        if let n = worker?.backend.note, n != decoderNote, !preDecoding { decoderNote = n }
    }

    func showMessage(_ m: String, seconds: TimeInterval) {
        message = m
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.message = nil }
        }
    }

    /// The uniforms for drawing the current frame into a viewport, plus the tone-mapping summary for the overlay.
    func uniforms(for frame: PlayerFrame, display: DisplayState, viewport: SIMD4<Float>) -> PlayerUniforms? {
        guard let info else { return nil }
        let out = output(for: frame).kernelMode
        let (u, summary) = PlayerRenderer.uniforms(frame: frame, info: info, display: display, settings: settings,
                                                   interpret: interpret, viewport: viewport, outputMode: out)
        if summary != toneMap { toneMap = summary }
        return u
    }

    /// How `frame` reaches the screen: the kernel's output encoding and the layer's color space both come from it.
    func output(for frame: PlayerFrame) -> PlayerRenderer.Output {
        guard let info else { return .extendedLinear(edr: false) }
        return PlayerRenderer.output(frameColor: frame.color, storage: frame.layout.storage, info: info, settings: settings, interpret: interpret)
    }

    /// Whether the picture needs an EDR layer (HDR source or forced interpretation), by the same rule as `output(for:)`.
    var isHDR: Bool {
        if let f = currentFrame { return output(for: f).wantsEDR }
        guard let info else { return false }
        let v = info.video
        let converted = choice?.backend == .avfoundation && (v.dolbyVision.map { $0.blCompatibilityID == 0 && ($0.profile == 5 || $0.profile == 10) } ?? false)
        return PlayerRenderer.output(frameColor: v.color, storage: converted ? .rgbaTexture : .planarBuffer, info: info,
                                     settings: settings, interpret: interpret).wantsEDR
    }

    // MARK: Teardown

    /// Stops decoding, kills every child process and releases the frames. The window calls it on close.
    func stop() {
        openGeneration += 1
        stopReverse()
        messageTimer?.invalidate()
        isPlaying = false
        stopAudio()
        preDecoder?.stop()
        worker?.shutdown()
        cache?.flushIndex()
        worker = nil
        queue = nil
        preDecoder = nil
        cache = nil
        preDecoding = false
        currentFrame = nil
        awaiting = nil
        highestSeen = -1
        endSearch = false
        endOfStream = nil
        decoderNote = nil
        cachedRanges = []
        keyFrames = []
        if phase != .opening { phase = .idle }
    }

    static func timecode(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
