import XCTest
@testable import Lumora

/// A decoder slower than real time buffers instead of stuttering; the pre-decode cache stores frames exactly,
/// keeps to its limits, and its workers serve the playhead first.
@MainActor
final class SlowDecoderBufferingTests: XCTestCase {
    var savedRoot: URL?
    var savedFloor: Int64 = 0
    var savedFree: ((URL) -> Int64)?
    var root: URL!

    override func setUp() async throws {
        savedRoot = PreDecodeCache.rootOverride
        savedFloor = PreDecodeCache.floorBytes
        savedFree = PreDecodeCache.freeSpace
        root = PlayerFixtures.url("cache-\(UUID().uuidString.prefix(6))")
        PreDecodeCache.rootOverride = root
        PreDecodeCache.floorBytes = 1 << 20
        PreDecodeCache.freeSpace = { _ in 500 << 30 }
    }

    override func tearDown() async throws {
        PreDecodeCache.rootOverride = savedRoot
        PreDecodeCache.floorBytes = savedFloor
        if let savedFree { PreDecodeCache.freeSpace = savedFree }
        try? FileManager.default.removeItem(at: root)
    }

    func spin(_ s: Double = 0.01) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    /// Frames of the index pattern produced at a fixed rate.
    final class FakeSlowBackend: PlayerVideoBackend, @unchecked Sendable {
        let choice = DecoderChoice(backend: .ffmpeg, tool: "fake slow decoder", hardware: false, reason: "test")
        let layout: FrameLayout
        let pool: BufferPool
        let fps: Double
        let interval: TimeInterval
        let frames: Int
        private var nextIndex = 0
        private var stopped = false
        private let lock = NSLock()
        var randomAccessPoints: [Int]? { nil }

        init(frames: Int, fps: Double, speed: Double, poolCapacity: Int) {
            layout = FrameLayout.planar(width: 64, height: 36, chroma: .c420, sampleBytes: 1, bits: 8)
            pool = BufferPool(device: MetalContext.shared.device, length: layout.frameBytes, capacity: poolCapacity)
            self.fps = fps
            self.frames = frames
            interval = 1 / (fps * speed)
        }

        func start(atFrame i: Int) throws { lock.lock(); nextIndex = i; stopped = false; lock.unlock() }
        func next() throws -> PlayerFrame? {
            lock.lock(); let i = nextIndex; let s = stopped; lock.unlock()
            guard !s, i < frames, let b = pool.acquire() else { return nil }
            Thread.sleep(forTimeInterval: interval)
            memset(b.bytes, 100, layout.frameBytes)
            lock.lock(); nextIndex += 1; lock.unlock()
            return PlayerFrame(index: i, pts: Double(i) / fps, layout: layout, planes: .buffer(b), color: SignalColor())
        }
        func interrupt() { lock.lock(); stopped = true; lock.unlock() }
        func stop() { interrupt() }
    }

    func testSlowDecoderBuffersInsteadOfStuttering() throws {
        let e = PlayerEngine()
        e.preDecodeOverride = false
        var budget = PlayerSettings(); budget.bufferBudgetMB = 64
        e.settings = budget
        e.backendFactory = { _, _, cap in FakeSlowBackend(frames: 600, fps: 24, speed: 0.3, poolCapacity: cap) }
        var info = MediaInfo(url: URL(fileURLWithPath: "/tmp/slow.mkv"), container: "mkv")
        // 1080p 8-bit frames: the 64 MB budget holds about 20 of them, so the queue fills in a few seconds at 0.3x.
        info.video.width = 1920; info.video.height = 1080; info.frameCount = 600
        info.rateNum = 24; info.rateDen = 1
        let choice = DecoderChoice(backend: .ffmpeg, tool: "fake", hardware: false, pixelFormat: "yuv420p", reason: "test")
        e.open(info: info, choice: choice)
        // First frame, then play: the queue drains at 1x while the decoder makes 0.3x.
        let deadline = Date(timeIntervalSinceNow: 10)
        while e.currentFrame == nil && Date() < deadline { _ = e.frameForDisplay(targetHost: CACurrentMediaTime()); spin() }
        e.play()
        var progress: [Double] = []
        var buffered = false
        let end = Date(timeIntervalSinceNow: 20)
        while Date() < end {
            _ = e.frameForDisplay(targetHost: CACurrentMediaTime() + 0.016)
            if e.phase == .buffering {
                buffered = true
                progress.append(e.bufferingProgress)
                XCTAssertTrue(e.bufferingReason?.contains("slower than real time") == true, e.bufferingReason ?? "")
            } else if buffered { break }
            spin(0.016)
        }
        XCTAssertTrue(buffered, "entered buffering")
        XCTAssertEqual(progress, progress.sorted(), "buffering progress only grows")
        XCTAssertEqual(e.phase, .ready, "resumed once the queue was full")
        e.stop()
    }

    func testAV2PreDecodesThenPlaysWithoutDrops() throws {
        try PlayerFixtures.require("avmenc", "avmdec")
        let url = try PlayerFixtures.indexClip("av2.obu")
        let e = PlayerEngine()
        e.open(url)
        XCTAssertTrue(e.waitUntilOpened(timeout: 60))
        XCTAssertNil(e.errorMessage)
        XCTAssertTrue(e.preDecoding, "AV2 always goes through the pre-decode cache")
        let deadline = Date(timeIntervalSinceNow: 30)
        while e.currentFrame == nil && Date() < deadline { _ = e.frameForDisplay(targetHost: CACurrentMediaTime()); spin() }
        e.play()
        // Playback waits until enough is cached that it can't run dry at the measured decode speed.
        while e.phase == .buffering && Date() < deadline {
            XCTAssertTrue(e.bufferingReason?.contains("AV2") == true, e.bufferingReason ?? "")
            _ = e.frameForDisplay(targetHost: CACurrentMediaTime())
            spin()
        }
        XCTAssertEqual(e.phase, .ready)
        // Then 24 frames at 24 fps on a simulated display: every frame shown once, none dropped.
        let t0 = CACurrentMediaTime()
        var shown: [Int] = []
        for k in 0..<60 {
            if let f = e.frameForDisplay(targetHost: t0 + Double(k) / 48), shown.last != f.index { shown.append(f.index) }
            spin(1.0 / 48)
            if e.phase == .ended { break }
        }
        XCTAssertEqual(e.stats.dropped, 0, "frames shown: \(shown)")
        XCTAssertEqual(shown.last, 23)
        XCTAssertGreaterThan(e.stats.cacheBytes, 0)
        e.stop()
        XCTAssertTrue(PlayerFixtures.noChildrenLeft(), "no decoder left running")
    }

    // MARK: Cache

    func testCacheRoundTripIsBitExact() throws {
        let src = PlayerFixtures.url("cache-src.bin")
        try Data("source".utf8).write(to: src)
        let bytes = 64 * 1024
        let c = try PreDecodeCache(source: src, options: "t", frameBytes: bytes, capBytes: 1 << 30, blockFrames: 4)
        var compressible = [UInt8](repeating: 0, count: bytes)
        for i in 0..<bytes { compressible[i] = UInt8((i / 64) & 0xFF) }
        var noise = [UInt8](repeating: 0, count: bytes)
        var g = SystemRandomNumberGenerator()
        for i in 0..<bytes { noise[i] = UInt8.random(in: 0...255, using: &g) }
        XCTAssertTrue(c.store(0, bytes: compressible))
        XCTAssertTrue(c.store(1, bytes: noise))
        var out = [UInt8](repeating: 1, count: bytes)
        XCTAssertTrue(c.load(0, into: &out)); XCTAssertEqual(out, compressible)
        XCTAssertTrue(c.load(1, into: &out)); XCTAssertEqual(out, noise, "incompressible frames are stored raw")
        XCTAssertLessThan(c.bytesOnDisk, Int64(bytes) + Int64(bytes) / 2, "the compressible frame shrank")
        XCTAssertEqual(c.cachedRanges, [0..<2])
        // A new instance for the same source and options finds the frames again; a changed source invalidates them.
        c.flushIndex()
        let again = try PreDecodeCache(source: src, options: "t", frameBytes: bytes, capBytes: 1 << 30, blockFrames: 4)
        XCTAssertTrue(again.contains(1))
        Thread.sleep(forTimeInterval: 1.1)
        try Data("changed".utf8).write(to: src)
        let changed = try PreDecodeCache(source: src, options: "t", frameBytes: bytes, capBytes: 1 << 30, blockFrames: 4)
        XCTAssertFalse(changed.contains(1), "the key covers size and modification time")
    }

    func testCapsSlidingWindowAndFloor() throws {
        let src = PlayerFixtures.url("cache-src2.bin")
        try Data("x".utf8).write(to: src)
        let bytes = 32 * 1024
        var noise = [UInt8](repeating: 0, count: bytes)
        for i in 0..<bytes { noise[i] = UInt8.random(in: 0...255) }
        // Room for 12 raw frames, blocks of 4.
        let c = try PreDecodeCache(source: src, options: "cap", frameBytes: bytes, capBytes: Int64(bytes * 12), blockFrames: 4)
        for i in 0..<12 { XCTAssertTrue(c.store(i, bytes: noise)) }
        XCTAssertFalse(c.store(12, bytes: noise), "cap reached")
        XCTAssertTrue(c.isFull)
        // Playhead at 10: blocks behind it (0-3, 4-7) can go, keeping 2 frames behind.
        let freed = c.evict(playhead: 10, behind: 2, storing: 12, needBytes: Int64(bytes))
        XCTAssertGreaterThanOrEqual(freed, Int64(bytes * 4))
        XCTAssertFalse(c.contains(0))
        XCTAssertTrue(c.contains(10))
        XCTAssertTrue(c.store(12, bytes: noise))
        // The free-space floor.
        PreDecodeCache.freeSpace = { _ in (1 << 20) + 10 }
        XCTAssertFalse(c.store(13, bytes: noise), "never below the floor")
    }

    func testStaleAndLRUCleanup() throws {
        let a = PlayerFixtures.url("cache-a.bin"), b = PlayerFixtures.url("cache-b.bin")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let bytes = 16 * 1024
        let frame = [UInt8](repeating: 7, count: bytes)
        let ca = try PreDecodeCache(source: a, options: "o", frameBytes: bytes, capBytes: 1 << 30)
        let cb = try PreDecodeCache(source: b, options: "o", frameBytes: bytes, capBytes: 1 << 30)
        ca.store(0, bytes: frame); cb.store(0, bytes: frame)
        ca.flushIndex(); cb.flushIndex()
        XCTAssertEqual(PreDecodeCache.cacheFolders().count, 2)
        PreDecodeCache.cleanup(maxAge: 7 * 86_400, now: Date(timeIntervalSinceNow: 8 * 86_400))
        XCTAssertEqual(PreDecodeCache.cacheFolders().count, 0, "untouched for a week")
        let c2 = try PreDecodeCache(source: a, options: "o", frameBytes: bytes, capBytes: 1 << 30)
        c2.store(0, bytes: frame); c2.flushIndex()
        try FileManager.default.removeItem(at: a)
        PreDecodeCache.cleanup()
        XCTAssertEqual(PreDecodeCache.cacheFolders().count, 0, "its source is gone")
    }

    func testWorkersServeThePlayheadFirst() throws {
        let src = PlayerFixtures.url("cache-src3.bin")
        try Data("w".utf8).write(to: src)
        let layout = FrameLayout.planar(width: 16, height: 16, chroma: .c420, sampleBytes: 1, bits: 8)
        let cache = try PreDecodeCache(source: src, options: "w", frameBytes: layout.frameBytes, capBytes: 1 << 30, blockFrames: 8)
        let segments = PreDecoder.segments(randomAccessPoints: [0, 10, 20, 30, 40], frameCount: 50)
        XCTAssertEqual(segments, [0..<10, 10..<20, 20..<30, 30..<40, 40..<50])
        let order = NSMutableArray()
        let pd = PreDecoder(cache: cache, segments: segments, workers: 1) { start, n in
            order.add(start)
            let b = FakeSlowBackend(frames: start + n, fps: 1000, speed: 1, poolCapacity: 4)
            return b
        }
        pd.setPlayhead(25)
        pd.start()
        let deadline = Date(timeIntervalSinceNow: 20)
        while !pd.isDone && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        pd.stop()
        XCTAssertTrue(pd.isDone)
        XCTAssertEqual(order.compactMap { $0 as? Int }, [20, 30, 40, 0, 10], "the playhead's segment, then ahead, then behind")
        XCTAssertEqual(cache.cachedRanges, [0..<50])
    }
}
