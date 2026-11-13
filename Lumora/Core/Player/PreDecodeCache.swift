import Foundation
import Compression
import CryptoKit

/// Decoded frames on disk, for decoders too slow to play in real time (AV2's reference decoder above all).
/// Each frame is compressed with LZFSE (Apple's Compression framework; about 3x on 10-bit video) or stored raw when
/// that saves less than 10 %. Frames live in block files of `blockFrames` consecutive frames, which is also the unit
/// of eviction. Hard limits: a per-file cap, a global cap across files, and a free-space floor on the scratch volume.
final class PreDecodeCache: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var block: Int
        var offset: Int64
        var length: Int
        var compressed: Bool
    }

    struct Index: Codable {
        var version = 1
        var source: String
        var size: Int64
        var mtime: Double
        var options: String
        var frameBytes: Int
        var frames: [Int: Entry] = [:]
        var lastUsed = Date()
    }

    // MARK: Configuration (tests inject their own)

    nonisolated(unsafe) static var rootOverride: URL?
    /// Free bytes on the volume holding `url`.
    nonisolated(unsafe) static var freeSpace: (URL) -> Int64 = { url in
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    /// Never write when the volume would drop below this.
    nonisolated(unsafe) static var floorBytes: Int64 = 10 << 30
    nonisolated(unsafe) static var globalCapBytes: Int64 = 40 << 30

    /// "Player Cache" in the scratch folder (Settings → Storage), so it follows the scratch drive.
    static var root: URL {
        if let r = rootOverride { return r }
        let base = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                       ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora Scratch").path)
        return base.appendingPathComponent("Player Cache", isDirectory: true)
    }

    static func key(source: URL, options: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(size)|\(mtime)|\(options)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: Instance

    let dir: URL
    let frameBytes: Int
    let blockFrames: Int
    let capBytes: Int64
    private let lock = NSLock()
    private let available = NSCondition()
    private var index: Index
    private var handles: [Int: FileHandle] = [:]
    private var blockBytes: [Int: Int64] = [:]
    private var dirty = 0
    private(set) var isFull = false

    /// - capBytes: most this file's cache may hold (Settings → Player, at most 25 % of the free space).
    init(source: URL, options: String, frameBytes: Int, capBytes: Int64, blockFrames: Int = 48) throws {
        self.frameBytes = frameBytes
        self.blockFrames = max(1, blockFrames)
        let a = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        dir = Self.root.appendingPathComponent(Self.key(source: source, options: options), isDirectory: true)
        let free = Self.freeSpace(Self.root.deletingLastPathComponent())
        self.capBytes = max(0, min(capBytes, free / 4))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var idx = Index(source: source.path, size: size, mtime: mtime, options: options, frameBytes: frameBytes)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let old = try? JSONDecoder().decode(Index.self, from: data),
           old.version == idx.version, old.size == size, old.mtime == mtime, old.frameBytes == frameBytes, old.options == options {
            // Keep the frames whose block file is still complete.
            var sizes: [Int: Int64] = [:]
            for e in old.frames.values where sizes[e.block] == nil {
                let f = dir.appendingPathComponent(Self.blockName(e.block))
                sizes[e.block] = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? NSNumber)?.int64Value ?? -1
            }
            idx.frames = old.frames.filter { _, e in (sizes[e.block] ?? -1) >= e.offset + Int64(e.length) }
            for (b, s) in sizes where s > 0 { blockBytes[b] = s }
        } else {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: f)
            }
        }
        index = idx
        flushIndex()
    }

    deinit {
        flushIndex()
        for h in handles.values { try? h.close() }
    }

    static func blockName(_ b: Int) -> String { String(format: "frames-%05d.bin", b) }

    var bytesOnDisk: Int64 { lock.lock(); defer { lock.unlock() }; return blockBytes.values.reduce(0, +) }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return index.frames.count }

    func contains(_ i: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return index.frames[i] != nil }

    /// Frames cached contiguously from `i` on.
    func contiguous(from i: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        while index.frames[i + n] != nil { n += 1 }
        return n
    }

    /// Cached frames as ranges, for the scrubber.
    var cachedRanges: [Range<Int>] {
        lock.lock()
        let keys = index.frames.keys.sorted()
        lock.unlock()
        var out: [Range<Int>] = []
        var start = -1, prev = -2
        for k in keys {
            if k != prev + 1 { if start >= 0 { out.append(start..<(prev + 1)) }; start = k }
            prev = k
        }
        if start >= 0 { out.append(start..<(prev + 1)) }
        return out
    }

    /// Compresses and stores one frame. false when the caps or the free-space floor leave no room.
    @discardableResult
    func store(_ i: Int, bytes: UnsafeRawPointer) -> Bool {
        if contains(i) { return true }
        // Compress outside the lock: it costs about 0.1 CPU-s per 1080p frame.
        let dstCap = frameBytes - frameBytes / 10
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, dstCap))
        defer { dst.deallocate() }
        let n = compression_encode_buffer(dst, dstCap, bytes.assumingMemoryBound(to: UInt8.self), frameBytes, nil, COMPRESSION_LZFSE)
        let compressed = n > 0
        let length = compressed ? n : frameBytes
        let others = othersBytes()
        lock.lock()
        if index.frames[i] != nil { lock.unlock(); return true }
        let total = blockBytes.values.reduce(0, +)
        if total + Int64(length) > capBytes || Self.freeSpace(dir) - Int64(length) < Self.floorBytes
            || others + total + Int64(length) > Self.globalCapBytes {
            isFull = true
            lock.unlock()
            return false
        }
        let block = i / blockFrames
        do {
            let h = try handle(block)
            let offset = try h.seekToEnd()
            try h.write(contentsOf: UnsafeRawBufferPointer(start: compressed ? UnsafeRawPointer(dst) : bytes, count: length))
            index.frames[i] = Entry(block: block, offset: Int64(offset), length: length, compressed: compressed)
            blockBytes[block, default: 0] = Int64(offset) + Int64(length)
        } catch {
            isFull = true
            lock.unlock()
            return false
        }
        dirty += 1
        if dirty >= 120 { writeIndexLocked() }
        lock.unlock()
        // Never take `available` while holding `lock`: waiters hold `available` and then call contains().
        available.lock(); available.broadcast(); available.unlock()
        return true
    }

    /// Bytes the other files' caches use, re-measured at most every few seconds (it lists their folders).
    private var othersCache: (Int64, CFAbsoluteTime) = (0, 0)
    private func othersBytes() -> Int64 {
        lock.lock()
        let (v, t) = othersCache
        lock.unlock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - t < 5 && t > 0 { return v }
        let fresh = Self.totalBytesExcluding(dir)
        lock.lock(); othersCache = (fresh, now); lock.unlock()
        return fresh
    }

    private func handle(_ block: Int) throws -> FileHandle {
        if let h = handles[block] { return h }
        let url = dir.appendingPathComponent(Self.blockName(block))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forUpdating: url)
        if handles.count > 16, let (k, old) = handles.first { try? old.close(); handles[k] = nil }
        handles[block] = h
        return h
    }

    /// Reads frame `i` into `into` (frameBytes long). false when it isn't cached or the file is damaged.
    func load(_ i: Int, into: UnsafeMutableRawPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let e = index.frames[i], let h = try? handle(e.block) else { return false }
        do {
            try h.seek(toOffset: UInt64(e.offset))
            guard let data = try h.read(upToCount: e.length), data.count == e.length else { return false }
            return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
                if !e.compressed {
                    into.copyMemory(from: src.baseAddress!, byteCount: min(frameBytes, e.length))
                    return e.length == frameBytes
                }
                let n = compression_decode_buffer(into.assumingMemoryBound(to: UInt8.self), frameBytes,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, e.length, nil, COMPRESSION_LZFSE)
                return n == frameBytes
            }
        } catch {
            return false
        }
    }

    /// Waits until frame `i` is cached; false on timeout.
    func wait(for i: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        available.lock()
        defer { available.unlock() }
        while !contains(i) {
            if !available.wait(until: deadline) { return contains(i) }
        }
        return true
    }

    /// Wakes anyone waiting (the player stopped).
    func wakeAll() { available.lock(); available.broadcast(); available.unlock() }

    /// Frees room for frame `storing` by dropping whole blocks: first those more than `behind` frames behind the
    /// playhead, farthest first, then blocks farther ahead than `storing` (they play later than it does).
    /// Returns the bytes freed.
    @discardableResult
    func evict(playhead: Int, behind: Int, storing: Int, needBytes: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let keepFrom = max(0, playhead - behind) / blockFrames
        let storingBlock = storing / blockFrames
        let blocks = Set(index.frames.values.map(\.block))
        let behindBlocks = blocks.filter { $0 < keepFrom }.sorted()
        let aheadBlocks = blocks.filter { $0 > storingBlock && $0 > playhead / blockFrames + 1 }.sorted(by: >)
        var freed: Int64 = 0
        for b in behindBlocks + aheadBlocks where freed < needBytes {
            freed += blockBytes[b] ?? 0
            dropBlockLocked(b)
        }
        if freed > 0 { isFull = false; writeIndexLocked() }
        return freed
    }

    private func dropBlockLocked(_ b: Int) {
        try? handles[b]?.close()
        handles[b] = nil
        blockBytes[b] = nil
        index.frames = index.frames.filter { $0.value.block != b }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.blockName(b)))
    }

    func flushIndex() { lock.lock(); writeIndexLocked(); lock.unlock() }

    private func writeIndexLocked() {
        dirty = 0
        index.lastUsed = Date()
        if let d = try? JSONEncoder().encode(index) { try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic) }
    }

    /// Removes this file's cache entirely.
    func removeAll() {
        lock.lock()
        for h in handles.values { try? h.close() }
        handles = [:]
        blockBytes = [:]
        index.frames = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: All caches

    static func cacheFolders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func folderBytes(_ url: URL) -> Int64 {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static var totalBytes: Int64 { cacheFolders().reduce(0) { $0 + folderBytes($1) } }

    private static func totalBytesExcluding(_ dir: URL) -> Int64 {
        cacheFolders().filter { $0.standardizedFileURL != dir.standardizedFileURL }.reduce(0) { $0 + folderBytes($1) }
    }

    /// At launch: drops caches untouched for `maxAge` or whose source changed or vanished, then the least recently
    /// used ones until the total fits the global cap.
    static func cleanup(maxAge: TimeInterval = 7 * 86_400, now: Date = Date()) {
        var live: [(URL, Date, Int64)] = []
        for f in cacheFolders() {
            guard let d = try? Data(contentsOf: f.appendingPathComponent("index.json")),
                  let idx = try? JSONDecoder().decode(Index.self, from: d) else {
                try? FileManager.default.removeItem(at: f); continue
            }
            let a = try? FileManager.default.attributesOfItem(atPath: idx.source)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            if now.timeIntervalSince(idx.lastUsed) > maxAge || size != idx.size || mtime != idx.mtime {
                try? FileManager.default.removeItem(at: f); continue
            }
            live.append((f, idx.lastUsed, folderBytes(f)))
        }
        var total = live.reduce(0) { $0 + $1.2 }
        for (f, _, bytes) in live.sorted(by: { $0.1 < $1.1 }) where total > globalCapBytes {
            try? FileManager.default.removeItem(at: f)
            total -= bytes
        }
    }

    static func clearAll() {
        for f in cacheFolders() { try? FileManager.default.removeItem(at: f) }
    }
}

/// Fills a pre-decode cache with several decoder processes at once, one segment each (a segment runs from one
/// random access point to the next), always serving the segment just ahead of the playhead first. The AVM
/// decoder gains little from threads, so separate processes are what gets AV2 close to real time.
final class PreDecoder: @unchecked Sendable {
    typealias Factory = (_ start: Int, _ count: Int) throws -> PlayerVideoBackend

    let cache: PreDecodeCache
    let segments: [Range<Int>]
    let workers: Int
    private let factory: Factory
    private let lock = NSLock()
    private var playhead = 0
    private var claimed: Set<Int> = []
    private var finished: Set<Int> = []
    private var stopped = false
    private var active: [Int: PlayerVideoBackend] = [:]
    private var threads: [Thread] = []
    private var decodedFrames = 0
    private var startTime = CFAbsoluteTimeGetCurrent()
    private(set) var lastError: Error?
    /// Seconds of video behind the playhead kept when the cache has to make room.
    var keepBehindFrames = 240

    init(cache: PreDecodeCache, segments: [Range<Int>], workers: Int, factory: @escaping Factory) {
        self.cache = cache
        self.segments = segments.filter { !$0.isEmpty }
        self.workers = max(1, min(workers, max(1, segments.count)))
        self.factory = factory
    }

    deinit { stop() }

    /// Segments from random access points over `frameCount` frames.
    static func segments(randomAccessPoints raps: [Int], frameCount: Int) -> [Range<Int>] {
        let starts = Array(Set(raps.filter { $0 >= 0 && $0 < frameCount } + [0])).sorted()
        return starts.enumerated().map { n, s in s..<(n + 1 < starts.count ? starts[n + 1] : frameCount) }
    }

    func start() {
        startTime = CFAbsoluteTimeGetCurrent()
        for n in 0..<workers {
            let t = Thread { [weak self] in self?.run() }
            t.name = "Lumora pre-decode \(n)"
            t.qualityOfService = .utility
            threads.append(t)
            t.start()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let a = Array(active.values)
        lock.unlock()
        a.forEach { $0.interrupt() }
        cache.wakeAll()
    }

    func setPlayhead(_ i: Int) { lock.lock(); playhead = i; lock.unlock() }

    /// Frames decoded per second across all workers since starting.
    var framesPerSecond: Double {
        lock.lock(); defer { lock.unlock() }
        let t = CFAbsoluteTimeGetCurrent() - startTime
        return t > 0.5 ? Double(decodedFrames) / t : 0
    }

    /// Where the stream really ends, once a decoder ran out of frames before its segment did.
    private(set) var knownEnd: Int?
    var endFrame: Int? { lock.lock(); defer { lock.unlock() }; return knownEnd }

    private func clipped(_ r: Range<Int>) -> Range<Int> {
        guard let e = knownEnd else { return r }
        return r.lowerBound..<max(r.lowerBound, min(r.upperBound, e))
    }

    /// Every frame of the file is in the cache.
    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return segments.allSatisfy { let c = clipped($0); return c.isEmpty || cache.contiguous(from: c.lowerBound) >= c.count }
    }

    /// Next segment to decode: the one holding the playhead, then the following ones in order, then those behind.
    /// A segment counts as done only while all of its frames are still cached (eviction can undo it).
    private func claim() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        let here = segments.firstIndex { $0.contains(playhead) } ?? 0
        let order = Array(here..<segments.count) + Array(0..<here)
        for s in order where !claimed.contains(s) {
            let c = clipped(segments[s])
            if c.isEmpty || cache.contiguous(from: c.lowerBound) >= c.count { finished.insert(s); continue }
            finished.remove(s)
            // Behind the playhead and the cache is full: decoding it would only evict what is about to play.
            if s < here && cache.isFull { continue }
            claimed.insert(s)
            return s
        }
        return nil
    }

    private func run() {
        while true {
            lock.lock(); let quit = stopped || lastError is PlayerError; lock.unlock()
            if quit { break }
            guard let s = claim() else { Thread.sleep(forTimeInterval: 0.3); continue }
            let seg = segments[s]
            var ok = false
            do {
                let backend = try factory(seg.lowerBound, seg.count)
                lock.lock()
                if stopped { lock.unlock(); backend.stop(); break }
                active[s] = backend
                lock.unlock()
                try backend.start(atFrame: seg.lowerBound)
                ok = true
                var last = seg.lowerBound - 1
                var reachedEnd = true
                while let f = try backend.next() {
                    last = max(last, f.index)
                    guard seg.contains(f.index) else { if f.index >= seg.upperBound { reachedEnd = false; break } else { continue } }
                    guard case .buffer(let b) = f.planes else { continue }
                    var stored = cache.store(f.index, bytes: b.bytes)
                    var waited = 0.0
                    while !stored {
                        // Full: make room behind the playhead (a sliding window), or wait for the playhead to move on.
                        lock.lock(); let ph = playhead; let quit = stopped; lock.unlock()
                        if quit { break }
                        if f.index >= ph, cache.evict(playhead: ph, behind: keepBehindFrames, storing: f.index,
                                                      needBytes: Int64(cache.frameBytes) * 8) > 0 {
                            stored = cache.store(f.index, bytes: b.bytes)
                            continue
                        }
                        if f.index < ph { break }            // already played; skip the rest of this segment
                        Thread.sleep(forTimeInterval: 0.25)
                        waited += 0.25
                        if waited > 30 && cache.frameCount == 0 {
                            lock.lock(); lastError = PlayerError.cacheFull(PreDecodeCache.freeSpace(cache.dir)); lock.unlock()
                            break
                        }
                        stored = cache.store(f.index, bytes: b.bytes)
                    }
                    if !stored { ok = false; reachedEnd = false; break }
                    lock.lock(); decodedFrames += 1; let quit = stopped; lock.unlock()
                    if quit { ok = false; reachedEnd = false; break }
                }
                backend.stop()
                lock.lock()
                if ok && reachedEnd && !stopped && last + 1 < seg.upperBound {
                    // The decoder ran out before the segment did: that is the real end of the stream.
                    knownEnd = min(knownEnd ?? Int.max, last + 1)
                }
                lock.unlock()
            } catch {
                lock.lock(); lastError = error; lock.unlock()
                ok = false
            }
            lock.lock()
            active[s] = nil
            claimed.remove(s)
            let c = clipped(seg)
            if ok && (c.isEmpty || cache.contiguous(from: c.lowerBound) >= c.count) { finished.insert(s) }
            lock.unlock()
            if !ok { Thread.sleep(forTimeInterval: 0.3) }     // a failing or full segment must not spin
        }
        lock.lock(); exitedWorkers += 1; lock.unlock()
        cache.wakeAll()
    }

    private var exitedWorkers = 0
    /// Every worker has quit (all done, stopped, or failed).
    var allWorkersExited: Bool { lock.lock(); defer { lock.unlock() }; return exitedWorkers >= threads.count && !threads.isEmpty }
}

/// Plays frames from the pre-decode cache: each `next()` waits until the workers have cached that frame.
final class CacheBackend: PlayerVideoBackend, @unchecked Sendable {
    let choice: DecoderChoice
    let info: MediaInfo
    let cache: PreDecodeCache
    let preDecoder: PreDecoder
    private let layout: FrameLayout
    private let pool: BufferPool
    private let lock = NSLock()
    private var nextIndex = 0
    private var interrupted = false
    let raps: [Int]?
    var randomAccessPoints: [Int]? { raps }

    init(info: MediaInfo, choice: DecoderChoice, layout: FrameLayout, cache: PreDecodeCache, preDecoder: PreDecoder,
         randomAccessPoints: [Int]?, poolCapacity: Int) {
        self.info = info
        self.choice = choice
        self.layout = layout
        self.cache = cache
        self.preDecoder = preDecoder
        self.raps = randomAccessPoints
        pool = BufferPool(device: MetalContext.shared.device, length: layout.frameBytes, capacity: poolCapacity)
    }

    deinit { stop() }

    func start(atFrame i: Int) throws {
        lock.lock(); nextIndex = max(0, i); interrupted = false; lock.unlock()
        preDecoder.setPlayhead(max(0, i))
    }

    func next() throws -> PlayerFrame? {
        lock.lock(); let i = nextIndex; lock.unlock()
        if let n = info.frameCount, i >= n { return nil }
        while !cache.contains(i) {
            lock.lock(); let stop = interrupted; lock.unlock()
            if stop { return nil }
            if let e = preDecoder.endFrame, i >= e { return nil }     // the stream ended before its expected length
            if preDecoder.isDone { return nil }                       // every segment decoded: past the end
            if preDecoder.allWorkersExited {
                if let e = preDecoder.lastError { throw e }
                return nil
            }
            _ = cache.wait(for: i, timeout: 0.25)
        }
        guard let buf = pool.acquire() else { return nil }
        guard cache.load(i, into: buf.bytes) else { throw PlayerError.damaged("the pre-decode cache lost frame \(i).") }
        lock.lock(); nextIndex = i + 1; lock.unlock()
        preDecoder.setPlayhead(i)
        return PlayerFrame(index: i, pts: Double(i) / info.fps, layout: layout, planes: .buffer(buf), color: info.video.color)
    }

    func interrupt() {
        lock.lock(); interrupted = true; lock.unlock()
        cache.wakeAll()
    }

    func stop() { interrupt() }
}
