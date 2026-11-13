import Foundation
import CryptoKit

/// The durable record of one export's progress: which segments are finished and checked, what was measured
/// before encoding, and what happened. It lives in `<scratch>/Checkpoints/<exportID>/journal.json` and never leaves
/// the Mac. Only files the journal lists, and that pass validation again, are ever reused.
struct ExportJournal: Codable, Identifiable {
    enum State: String, Codable { case running, failed, interrupted, cancelledKept, joined, deliveryPending, finished }

    struct SourceFingerprint: Codable, Hashable {
        var path: String
        var size: Int64
        var modified: Date
        var fileID: UInt64
        var headTail: String          // SHA-256 of the first and last 4 MB

        static func of(_ url: URL) -> SourceFingerprint? {
            let fm = FileManager.default
            guard let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let mod = a[.modificationDate] as? Date ?? .distantPast
            let id = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256()
            let chunk = 4 << 20
            if let head = try? h.read(upToCount: chunk) { hasher.update(data: head) }
            if size > Int64(chunk) {
                try? h.seek(toOffset: UInt64(max(Int64(chunk), size - Int64(chunk))))
                if let tail = try? h.readToEnd() { hasher.update(data: tail) }
            }
            return SourceFingerprint(path: url.path, size: size, modified: mod, fileID: id,
                                     headTail: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }

        /// The same content, even if the file was moved (path ignored) or touched (date ignored when the bytes match).
        func sameContent(_ o: SourceFingerprint) -> Bool { size == o.size && headTail == o.headTail }
    }

    struct EncodeFingerprint: Codable, Hashable {
        var binary: String
        var version: String
        var specHash: String
        var threads: Int
        var chip: String
        var osBuild: String
    }

    struct PlannedSegment: Codable, Hashable {
        var index: Int
        var start: Int
        var count: Int
        var preroll: Int
        var range: Range<Int> { start..<(start + count) }
    }

    struct Plan: Codable, Hashable {
        var frames: Int
        var rateNum: Int
        var rateDen: Int
        var workers: Int
        var segments: [PlannedSegment]
    }

    struct DoneSegment: Codable, Hashable {
        var index: Int
        var file: String              // relative to the checkpoint folder
        var frames: Int
        var bytes: Int64
        var sha256: String
        var packets: Int
        var validatedAt: Date
        var attempt: Int
    }

    var version = 1
    var exportID: String
    var created = Date()
    var updated = Date()
    var state: State = .running
    var recipeHash: String
    var renderVersion: Int
    var source: SourceFingerprint?
    var sourceName: String
    var outputPath: String
    var logFile: String?
    var encode: EncodeFingerprint?
    var plan: Plan?
    var levelsSaved = false
    var grain: ExportEngine.GrainPlan?
    var segments: [DoneSegment] = []
    var stages: [String: Date] = [:]
    var joinedFile: String?           // relative: the joined video, before HDR10 container / dynamic metadata
    var finalFile: String?            // relative: the finished video, ready to deliver
    var sleeps: [SystemSnapshot.SleepEvent] = []
    var lastEvent = "started"
    var willTerminate = false
    var failure: FailureReport?
    var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    var processStart = CheckpointStore.processStart
    var bootSession = SystemSnapshot.bootSessionUUID()
    var chip = ChipProfile.current.description
    var osBuild = CheckpointStore.osBuild
    var lastPressure: SystemSnapshot.Pressure = .normal
    var keepProgress = false

    var id: String { exportID }
    var savedFrames: Int { segments.reduce(0) { $0 + $1.frames } }
    var progress: Double {
        if finalFile != nil || joinedFile != nil { return 1 }
        guard let p = plan, p.frames > 0 else { return 0 }
        return min(1, Double(savedFrames) / Double(p.frames))
    }
    var outputName: String { URL(fileURLWithPath: outputPath).lastPathComponent }
}

/// The folder of saved progress: one subfolder per export under `<scratch>/Checkpoints/`.
enum CheckpointStore {
    /// Bumped whenever the pipeline's output for the same settings changes, so progress saved by an older Lumora is
    /// never joined with parts made by a newer one.
    static let renderVersion = 1
    static let expiryDays = 14.0

    static let processStart = Date()
    static let osBuild: String = {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    static var root: URL {
        let base = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                       ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Lumora Scratch").path)
        return base.appendingPathComponent("Checkpoints", isDirectory: true)
    }

    static func folder(_ id: String, root: URL = CheckpointStore.root) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    static func create(_ id: String) throws -> URL {
        let d = folder(id)
        for sub in ["", "segments", "prepass"] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        return d
    }

    // MARK: Durable writes

    /// Flushes a file all the way to the drive (not just the OS cache): `F_FULLFSYNC`.
    static func fullSync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        close(fd)
    }

    /// Writes `journal.json.tmp`, flushes it, renames it over `journal.json`, flushes the folder. A power loss leaves
    /// either the old or the new journal, never a torn one (a torn .tmp is ignored).
    static func save(_ j: ExportJournal, in dir: URL) throws {
        var j = j
        j.updated = Date()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(j)
        let tmp = dir.appendingPathComponent("journal.json.tmp")
        try data.write(to: tmp)
        if FaultInjection.tearJournalTmp { return }          // simulated power loss mid-write: the .tmp stays torn
        fullSync(tmp)
        guard rename(tmp.path, dir.appendingPathComponent("journal.json").path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: dir.path])
        }
        fullSync(dir)
    }

    static func load(_ dir: URL) -> ExportJournal? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: dir.appendingPathComponent("journal.json"))).flatMap { try? dec.decode(ExportJournal.self, from: $0) }
    }

    static func saveRecipe(_ r: ExportRecipe, in dir: URL) throws {
        let data = try JSONEncoder().encode(r)
        let url = dir.appendingPathComponent("recipe.json")
        try data.write(to: url, options: .atomic)
        fullSync(url)
    }

    static func loadRecipe(_ dir: URL) -> ExportRecipe? {
        (try? Data(contentsOf: dir.appendingPathComponent("recipe.json"))).flatMap { try? JSONDecoder().decode(ExportRecipe.self, from: $0) }
    }

    /// Heartbeat: pid, process start, boot session, time, memory pressure. Written every 10 s while an export runs.
    struct Heartbeat: Codable { var pid: Int32; var processStart: Date; var boot: String; var time: Date; var pressure: SystemSnapshot.Pressure; var lastEvent: String }

    static func beat(_ dir: URL, pressure: SystemSnapshot.Pressure, lastEvent: String) {
        let h = Heartbeat(pid: ProcessInfo.processInfo.processIdentifier, processStart: processStart,
                          boot: SystemSnapshot.bootSessionUUID(), time: Date(), pressure: pressure, lastEvent: lastEvent)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(h).write(to: dir.appendingPathComponent("heartbeat"), options: .atomic)
    }

    static func heartbeat(_ dir: URL) -> Heartbeat? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: dir.appendingPathComponent("heartbeat"))).flatMap { try? dec.decode(Heartbeat.self, from: $0) }
    }

    // MARK: Listing, sizes, pruning

    static func all(root: URL = CheckpointStore.root) -> [(dir: URL, journal: ExportJournal)] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { d in load(d).map { (d, $0) } }
            .sorted { $0.journal.updated > $1.journal.updated }
    }

    static func size(_ dir: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            for case let u as URL in e {
                let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            }
        }
        return total
    }

    static func discard(_ id: String, root: URL = CheckpointStore.root) {
        try? FileManager.default.removeItem(at: folder(id, root: root))
    }

    /// Saved progress expires after 14 days; the oldest goes first when all of it together takes more than a quarter of
    /// the scratch drive's free space. Never while that export is running (`active`). Progress for a source that lived
    /// in the temporary folder and is gone can never resume, so it goes too.
    static func prune(root: URL = CheckpointStore.root, active: Set<String> = [], now: Date = Date()) {
        let items = all(root: root).filter { !active.contains($0.journal.exportID) && !isRunningElsewhere($0.journal) }
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        var keep: [(URL, ExportJournal, Int64)] = []
        for (d, j) in items {
            let gone = j.source.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            let inTemp = j.source.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path.hasPrefix(tmp) } ?? false
            if now.timeIntervalSince(j.updated) > expiryDays * 86_400 || j.state == .finished || (gone && inTemp) {
                try? FileManager.default.removeItem(at: d)
            } else {
                keep.append((d, j, size(d)))
            }
        }
        let free = SystemSnapshot.volume(root)?.free ?? Int64.max
        var total = keep.reduce(0) { $0 + $1.2 }
        for (d, _, s) in keep.sorted(by: { $0.1.updated < $1.1.updated }) where total > free / 4 {
            try? FileManager.default.removeItem(at: d)
            total -= s
        }
        // Folders without a readable journal (a crash before the first journal write) are leftovers.
        for d in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard load(d) == nil, !active.contains(d.lastPathComponent) else { continue }
            let mod = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mod) > 3600 { try? FileManager.default.removeItem(at: d) }
        }
    }

    /// Process liveness check, replaceable in tests.
    nonisolated(unsafe) static var isProcessAlive: (Int32) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }

    /// The export is running in another live Lumora (same pid, same process start, same boot).
    static func isRunningElsewhere(_ j: ExportJournal) -> Bool {
        guard j.state == .running else { return false }
        if j.pid == ProcessInfo.processInfo.processIdentifier && abs(j.processStart.timeIntervalSince(processStart)) < 1 {
            return ActiveExports.contains(j.exportID)
        }
        guard j.bootSession == SystemSnapshot.bootSessionUUID(), isProcessAlive(j.pid) else { return false }
        if let hb = heartbeat(folder(j.exportID)), Date().timeIntervalSince(hb.time) > 120 { return false }
        return true
    }
}

/// Export IDs running in this process right now.
enum ActiveExports {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: Set<String> = []
    static func insert(_ id: String) { lock.lock(); ids.insert(id); lock.unlock() }
    static func remove(_ id: String) { lock.lock(); ids.remove(id); lock.unlock() }
    static func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    static var all: Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
}
