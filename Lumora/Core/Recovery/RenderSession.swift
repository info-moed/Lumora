import Foundation
import AppKit

/// How an export run should treat saved progress.
struct RecoveryOptions {
    var resume: ExportJournal?
    var keepProgressOnCancel = false
    /// "Save without Dolby Vision / HDR10+": deliver the HDR10 base layer when the metadata step keeps failing.
    var skipDynamicMetadata = false
    /// "Resume using less memory": one segment at a time.
    var lessMemory = false
    /// Pro: resume even though the Mac or macOS changed since the export began.
    var allowDifferentMac = false
}

/// Saved progress that can't be used: the source, the settings, the encoder or Lumora itself changed.
struct ResumeRefused: LocalizedError {
    var reason: String
    var errorDescription: String? { "Lumora has to start this export over: \(reason)" }
}

/// One export, from start to finish or failure: owns its log, journal and checkpoint folder, keeps the Mac awake,
/// watches for sleep, unmounts, memory pressure, heat and quitting, runs the segments with retries, and turns a
/// failure into a plain-language report.
final class RenderSession: @unchecked Sendable {
    let exportID: String
    let log: RenderLog
    let job: ExportJob
    let options: RecoveryOptions
    let resuming: Bool
    private(set) var dir: URL?
    private(set) var journal: ExportJournal
    private(set) var stage: RenderStage = .prepare
    private(set) var report: FailureReport?
    private(set) var encodedSegments: [Int] = []           // encoded in this run (resumed runs skip saved ones)
    private(set) var reusedSegments: [Int] = []
    private let lock = NSLock()
    private var failing: (Int, Range<Int>)?
    private var retried = false
    private var activity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var heartbeat: Task<Void, Never>?
    private var segmentURLs: [Int: URL] = [:]
    private var fps: Double = 24
    private var rate: (num: Int, den: Int) = (24, 1)
    private var sleptAt: Date?

    init(job: ExportJob, options: RecoveryOptions = RecoveryOptions()) {
        self.job = job
        self.options = options
        let r = options.resume
        resuming = r != nil
        exportID = r?.exportID ?? UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16).description
        let existing = r?.logFile.map { RenderLog.folder.appendingPathComponent($0) }
        if let existing, FileManager.default.fileExists(atPath: existing.path),
           let l = try? RenderLog(appendingTo: existing, exportID: exportID) {
            log = l
        } else if let l = try? RenderLog(exportID: exportID, outputName: job.outputURL.lastPathComponent) {
            log = l
        } else {
            // The log folder can't be written (full disk): log into the temporary folder rather than not at all.
            log = (try? RenderLog(exportID: exportID, outputName: job.outputURL.lastPathComponent,
                                  folder: FileManager.default.temporaryDirectory.appendingPathComponent("Lumora-logs")))!
        }
        journal = r ?? ExportJournal(exportID: exportID, recipeHash: ExportRecipe(job).hash(), renderVersion: CheckpointStore.renderVersion,
                                     source: nil, sourceName: job.descriptor.url.lastPathComponent, outputPath: job.outputURL.path)
        journal.logFile = log.url.lastPathComponent
    }

    var logURL: URL { log.url }
    var checkpointFolder: URL? { dir }
    var prepassFolder: URL? { dir?.appendingPathComponent("prepass", isDirectory: true) }
    var savedFrames: Int { lock.lock(); defer { lock.unlock() }; return journal.savedFrames }

    // MARK: Run

    func run<T>(_ body: @escaping () async throws -> T) async throws -> T {
        MemoryPressureWatch.shared.start()
        if ActiveExports.all.isEmpty { GPUFaults.reset() }     // an error from before this export isn't this export's
        ActiveExports.insert(exportID)
        startWatching()
        writeHeader()
        defer {
            stopWatching()
            ActiveExports.remove(exportID)
        }
        do {
            let result = try await RenderLog.$current.withValue(log) { try await body() }
            finishSuccessfully()
            return result
        } catch is FaultInjection.SimulatedCrash {
            heartbeat?.cancel()
            log.line(.error, "crash", "simulated crash: no cleanup, no journal update")
            log.close()
            throw FaultInjection.SimulatedCrash()
        } catch {
            fail(error)
            throw error
        }
    }

    private func writeHeader() {
        let j = job, d = j.descriptor
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .medium
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let size = (try? d.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
        let scratch = SystemSnapshot.volume(CheckpointStore.root.deletingLastPathComponent())
        var h = [
            resuming ? "=== Resumed \(fmt.string(from: Date())) ===" : "Lumora export log",
            "Export ID: \(exportID)",
            "Started: \(fmt.string(from: Date()))",
            "Lumora \(v) (\(b)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(ChipProfile.current.description)",
            "Source: \(d.url.path) (\(size), \(d.codec), \(d.width)×\(d.height), \(d.fpsNum)/\(d.fpsDen) fps, \(j.analysis.frameCount > 0 ? j.analysis.frameCount : d.frameCount) frames, primaries \(d.primariesTag ?? "untagged"), transfer \(d.transferTag ?? "untagged"), \(d.hasAudio ? "with audio" : "no audio"), read with \(d.kind.rawValue))",
            "Output: \(j.outputURL.path)",
            "Scratch: \(CheckpointStore.root.deletingLastPathComponent().path)" + (scratch.map { " (\(ByteCountFormatter.string(fromByteCount: $0.free, countStyle: .file)) free on “\($0.name)”)" } ?? ""),
            "Settings: \(j.codec.displayName), \(j.bitDepth)-bit \(j.chroma.label), \(j.delivery.displayName), peak \(Int(j.peakNits)) nits, quality \(j.quality)"
                + (ExportEngine.encoder(for: j).map { " → \($0.binary) level \($0.qualityValue(j.quality))" } ?? ""),
            "Look: \(j.preset.look.displayName) on \(j.preset.color.name); content \(j.contentKind.displayName)",
        ]
        if let c = j.encodeChoice { h.append("Encoder plan: \(c.rungLabel), preset \(c.presetValue), options \(c.optionIDs.joined(separator: ", ")) \(c.extraArgs.joined(separator: " "))") }
        let roles = ExportEngine.grainRoles(j)
        h.append("Grain: measured table \(roles.measured), encoder grain \(roles.encoderGrain), film texture \(j.filmTexture.rawValue)")
        h.append("Interpolation: \(String(describing: j.interpolation.mode)); upscale \(String(describing: j.upscale))")
        if let t = j.qualityTarget { h.append("Quality target: VMAF \(t.vmaf) (\(t.pool.rawValue)), profile \(t.profile.name)") }
        h.append("Tools: " + ToolVersions.relevant(j).map { "\($0) \(ToolVersions.version($0))" }.joined(separator: "; "))
        if resuming {
            h.append("Resuming: \(journal.segments.count) saved segments (\(journal.savedFrames) frames)\(journal.joinedFile != nil ? ", joined video saved" : "")\(journal.finalFile != nil ? ", finished video saved" : "")")
        }
        log.raw(h.joined(separator: "\n"))
        for l in SystemSnapshot.capture(scratch: CheckpointStore.root, output: j.outputURL).lines { log.line(.system, "start", l) }
    }

    // MARK: Checkpointing

    /// Starts (or, when resuming, checks) the checkpoint folder and journal. Called once the job has passed validation,
    /// so a refused job leaves nothing in the scratch folder.
    func beginCheckpointing(planInput: CheckpointPlanner.Input, rate: (num: Int, den: Int), encode: ExportJournal.EncodeFingerprint) throws {
        self.rate = rate
        self.fps = Double(rate.num) / Double(max(1, rate.den))
        var j = journal
        let src = job.descriptor.kind == .rawSequence ? nil : ExportJournal.SourceFingerprint.of(job.descriptor.url)
        if resuming {
            let d = CheckpointStore.folder(exportID)
            guard FileManager.default.fileExists(atPath: d.path) else { throw ResumeRefused(reason: "its saved progress was removed.") }
            dir = d
            if j.renderVersion != CheckpointStore.renderVersion { throw ResumeRefused(reason: "Lumora was updated and renders this export differently now.") }
            if let a = j.source, let b = src, !a.sameContent(b) {
                throw ResumeRefused(reason: "the source file “\(job.descriptor.url.lastPathComponent)” changed since the export began.")
            }
            if let old = j.encode {
                if old.binary != encode.binary || old.version != encode.version || old.specHash != encode.specHash {
                    throw ResumeRefused(reason: "the encoder changed since the export began (\(old.binary) \(old.version) → \(encode.binary) \(encode.version)).")
                }
                if job.codec.isHardware, old.chip != encode.chip || old.osBuild != encode.osBuild, !options.allowDifferentMac {
                    throw ResumeRefused(reason: "your Mac was updated since it began, and the hardware encoder may not match the saved part exactly.")
                }
            }
            if let p = j.plan, p.frames != planInput.frames || p.rateNum != rate.num || p.rateDen != rate.den {
                throw ResumeRefused(reason: "the export's frame plan changed (\(p.frames) → \(planInput.frames) frames).")
            }
            if j.plan == nil { j.plan = Self.makePlan(planInput, rate: rate, lessMemory: options.lessMemory) }
            if options.lessMemory { j.plan?.workers = 1 }
            j.source = src ?? j.source
            j.state = .running
            j.pid = ProcessInfo.processInfo.processIdentifier
            j.processStart = CheckpointStore.processStart
            j.bootSession = SystemSnapshot.bootSessionUUID()
            j.willTerminate = false
            j.failure = nil
            j.lastEvent = "resumed"
            journal = j
            revalidateSaved()
        } else {
            CheckpointStore.prune(active: ActiveExports.all)
            let d = try CheckpointStore.create(exportID)
            dir = d
            j.source = src
            j.encode = encode
            j.plan = Self.makePlan(planInput, rate: rate, lessMemory: options.lessMemory)
            j.keepProgress = options.keepProgressOnCancel
            journal = j
            try CheckpointStore.saveRecipe(ExportRecipe(job), in: d)
            warnIfScratchLooksSmall(planInput)
        }
        if let p = journal.plan {
            log.line(.info, "plan", "\(p.frames) frames at \(rate.num)/\(rate.den) fps in \(p.segments.count) segment\(p.segments.count == 1 ? "" : "s"), \(p.workers) at a time, \(encode.threads) threads each; encoder \(encode.binary) \(encode.version)")
            for s in p.segments.prefix(60) { log.line(.info, "plan", "seg \(s.index): frames \(s.start)–\(s.start + s.count - 1)\(s.preroll > 0 ? " (+\(s.preroll) preroll)" : "")") }
            if p.segments.count > 60 { log.line(.info, "plan", "… \(p.segments.count - 60) more") }
        }
        try saveJournal()
        startHeartbeat()
    }

    /// Up-front: segments, the joined file and the finished file can need about 2.2 × the output plus a reserve.
    /// A rough output estimate (the source size, or 0.1 bit per pixel when that is unknown) is enough for a warning;
    /// the pause gate handles the rest while the export runs.
    private func warnIfScratchLooksSmall(_ i: CheckpointPlanner.Input) {
        let src = Int64((try? job.descriptor.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let guess = src > 0 ? src : Int64(Double(i.frames * i.pixels) * 0.1 / 8)
        let needed = Int64(Double(guess) * 2.2) + DiskSpaceGuard.reserve
        guard let v = SystemSnapshot.volume(CheckpointStore.root.deletingLastPathComponent()), v.free < needed else { return }
        let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let m = "This export may need about \(f(needed)) on “\(v.name)”; \(f(v.free)) is free. Lumora pauses if the drive gets too full."
        Log.warning(.storage, m)            // also reaches this export's log
    }

    static func makePlan(_ i: CheckpointPlanner.Input, rate: (num: Int, den: Int), lessMemory: Bool) -> ExportJournal.Plan {
        var input = i
        if lessMemory { input.workers = 1 }
        return ExportJournal.Plan(frames: i.frames, rateNum: rate.num, rateDen: rate.den, workers: input.workers,
                                  segments: CheckpointPlanner.plan(input))
    }

    var plan: ExportJournal.Plan? { lock.lock(); defer { lock.unlock() }; return journal.plan }

    private func saveJournal() throws {
        guard let dir else { return }
        lock.lock(); let j = journal; lock.unlock()
        try CheckpointStore.save(j, in: dir)
    }

    private func update(_ f: (inout ExportJournal) -> Void) {
        lock.lock(); f(&journal); lock.unlock()
        try? saveJournal()
    }

    /// At resume: only files the journal lists, and that still check out, are kept; everything else in the folder goes.
    private func revalidateSaved() {
        guard let dir else { return }
        var keep: [ExportJournal.DoneSegment] = []
        for s in journal.segments {
            if let p = SegmentValidator.revalidate(s, in: dir, rate: rate) {
                log.warn("Saved segment \(s.index) can't be reused: \(p.localizedDescription) It will be encoded again.", tag: "resume")
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(s.file))
            } else {
                keep.append(s)
                segmentURLs[s.index] = dir.appendingPathComponent(s.file)
            }
        }
        journal.segments = keep
        let listed = Set(keep.map(\.file) + journal.pieces.map(\.file))
        let segDir = dir.appendingPathComponent("segments")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: segDir.path)) ?? [] where !listed.contains("segments/" + f) {
            try? FileManager.default.removeItem(at: segDir.appendingPathComponent(f))
            log.info("Removed \(f): not in the journal (it was being written when the export stopped)", tag: "resume")
        }
        for name in [journal.joinedFile, journal.finalFile].compactMap({ $0 }) where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            if journal.joinedFile == name { journal.joinedFile = nil }
            if journal.finalFile == name { journal.finalFile = nil }
        }
        log.info("Resuming with \(keep.count) of \(journal.plan?.segments.count ?? 0) segments saved (\(journal.savedFrames) frames)", tag: "resume")
    }

    // MARK: Stages and prepasses

    func setStage(_ s: RenderStage) {
        lock.lock(); let old = stage; stage = s; lock.unlock()
        if old != s { log.line(.stage, s.rawValue, "\(s.displayName)") }
        update { $0.stages[s.rawValue] = Date(); $0.lastEvent = s.rawValue }
    }

    func stage<T>(_ s: RenderStage, _ body: () async throws -> T) async throws -> T {
        setStage(s)
        log.stageStart(s.rawValue)
        let r = try await body()
        log.stageEnd(s.rawValue)
        return r
    }

    var savedGrain: ExportEngine.GrainPlan? { journal.stages["grain"] != nil && resuming ? journal.grain : nil }
    func saveGrain(_ g: ExportEngine.GrainPlan) { update { $0.grain = g } }

    private var levelsURL: URL? { prepassFolder?.appendingPathComponent("levels.json") }
    struct SavedLevels: Codable { var maxCLL: Float; var maxFALL: Float; var perFrameMax: [Float]; var perFrameAvg: [Float] }

    var savedLevels: SceneAnalyzer.LightLevels? {
        guard resuming, journal.levelsSaved, let u = levelsURL, let data = try? Data(contentsOf: u),
              let s = try? JSONDecoder().decode(SavedLevels.self, from: data) else { return nil }
        log.info("Reusing the saved HDR light levels", tag: "levels")
        return SceneAnalyzer.LightLevels(maxCLL: s.maxCLL, maxFALL: s.maxFALL, perFrameMax: s.perFrameMax, perFrameAvg: s.perFrameAvg)
    }

    func saveLevels(_ l: SceneAnalyzer.LightLevels) {
        guard let u = levelsURL else { return }
        let s = SavedLevels(maxCLL: l.maxCLL, maxFALL: l.maxFALL, perFrameMax: l.perFrameMax, perFrameAvg: l.perFrameAvg)
        if (try? JSONEncoder().encode(s).write(to: u, options: .atomic)) != nil {
            CheckpointStore.fullSync(u)
            update { $0.levelsSaved = true }
        }
    }

    // MARK: Segments

    /// Encodes every segment the journal doesn't have yet, `workers` at a time; returns all segment files in order.
    /// Transient failures (a crashed or reset encoder, a GPU fault, an encoder killed under memory pressure) are retried
    /// once or twice; everything else stops the export with the segment recorded for the explanation.
    func runSegments(ext: String,
                     encode: @escaping (_ segment: ExportJournal.PlannedSegment, _ url: URL, _ attempt: Int,
                                        _ tick: @escaping () -> Void) async throws -> [QCEvent],
                     tick: @escaping () -> Void) async throws -> (urls: [URL], events: [QCEvent]) {
        guard let dir, let plan = plan else { throw LumoraError.unsupported("The export has no segment plan.") }
        setStage(.encode)
        let todo = plan.segments.filter { segmentURLs[$0.index] == nil }
        reusedSegments = plan.segments.map(\.index).filter { segmentURLs[$0] != nil }
        if !reusedSegments.isEmpty {
            log.info("\(reusedSegments.count) segment\(reusedSegments.count == 1 ? "" : "s") already saved; encoding \(todo.count)", tag: "encode")
            let saved = plan.segments.filter { reusedSegments.contains($0.index) }.reduce(0) { $0 + $1.count }
            for _ in 0..<saved { tick() }
        }
        var events: [QCEvent] = []
        try await withThrowingTaskGroup(of: (Int, URL, [QCEvent]).self) { g in
            var pending = todo[...]
            var running = 0
            while running < max(1, plan.workers), let s = pending.popFirst() {
                g.addTask { try await self.encodeSegment(s, ext: ext, dir: dir, encode: encode, tick: tick) }
                running += 1
            }
            while let (i, u, ev) = try await g.next() {
                lock.withLock { segmentURLs[i] = u }
                events += ev
                if let s = pending.popFirst() {
                    g.addTask { try await self.encodeSegment(s, ext: ext, dir: dir, encode: encode, tick: tick) }
                }
            }
        }
        let urls = lock.withLock { plan.segments.compactMap { segmentURLs[$0.index] } }
        guard urls.count == plan.segments.count else { throw FrameCountMismatch(got: urls.count, expected: plan.segments.count) }
        return (urls, events)
    }

    private func encodeSegment(_ s: ExportJournal.PlannedSegment, ext: String, dir: URL,
                               encode: @escaping (ExportJournal.PlannedSegment, URL, Int, @escaping () -> Void) async throws -> [QCEvent],
                               tick: @escaping () -> Void) async throws -> (Int, URL, [QCEvent]) {
        let tag = "seg \(s.index)"
        var attempt = 1
        while true {
            try Task.checkCancellation()
            try checkSource()
            let url = dir.appendingPathComponent(String(format: "segments/s%05d.a%d.%@", s.index, attempt, ext))
            try? FileManager.default.removeItem(at: url)
            log.stageStart("segment", tag: tag)
            let counter = FrameCounter(log: log, tag: tag, total: s.count)
            var ticked = 0
            do {
                try FaultInjection.point(.beforeSegment(s.index), attempt: attempt)
                let ev = try await encode(s, url, attempt) { counter.tick(); ticked += 1; tick() }
                counter.finish()
                CheckpointStore.fullSync(url)
                if FaultInjection.crashBetweenSegmentAndJournal == s.index { throw FaultInjection.SimulatedCrash() }
                setStageQuiet(.validate)
                let v = try SegmentValidator.validate(url, frames: s.count, rate: rate)
                let done = ExportJournal.DoneSegment(index: s.index, file: "segments/" + url.lastPathComponent, frames: s.count,
                                                     bytes: v.bytes, sha256: v.sha256, packets: v.packets, validatedAt: Date(), attempt: attempt)
                let saved = lock.withLock {
                    journal.segments.removeAll { $0.index == s.index }
                    journal.segments.append(done)
                    journal.segments.sort { $0.index < $1.index }
                    encodedSegments.append(s.index)
                    return journal.segments.count
                }
                try saveJournal()
                log.stageEnd("segment", tag: tag, note: "\(s.count) frames, \(ByteCountFormatter.string(fromByteCount: v.bytes, countStyle: .file)), checked")
                if let n = FaultInjection.crashAfterSegments, saved >= n { throw FaultInjection.SimulatedCrash() }
                return (s.index, url, ev)
            } catch {
                if error is FaultInjection.SimulatedCrash || error is CancellationError || Task.isCancelled { throw error }
                // A decoder that failed because the source vanished or changed underneath it: say that, not "can't open".
                do { try checkSource() } catch { lock.withLock { failing = (s.index, s.range) }; throw error }
                let f = FailureClassifier.classify(error, context: context(segment: s))
                let allowed = retries(for: f, error: error)
                log.error("\(error.localizedDescription)", tag: tag)
                if attempt <= allowed {
                    log.line(.retry, tag, "attempt \(attempt) failed (\(f.kind.rawValue)); trying segment \(s.index) again")
                    if f.kind == .outOfMemory { await waitForNormalPressure() }
                    if f.kind == .gpuError { GPUFaults.reset() }
                    try? FileManager.default.removeItem(at: url)
                    // The frames this attempt counted are counted again by the next one.
                    lock.withLock { retried = true }
                    attempt += 1
                    _ = ticked
                    continue
                }
                lock.withLock { failing = (s.index, s.range) }
                throw error
            }
        }
    }

    private func setStageQuiet(_ s: RenderStage) { lock.lock(); if stage != .encode { stage = s }; lock.unlock() }

    private func retries(for f: RenderFailure, error: Error) -> Int {
        if error is SegmentValidator.Problem { return 1 }
        switch f.kind {
        case .hardwareEncoderReset: return 2
        case .gpuError, .toolCrashed: return 1
        case .outOfMemory: return f.signal != nil ? 1 : 0
        default: return 0
        }
    }

    /// "Stop and keep progress": set just before canceling an export from the app.
    nonisolated(unsafe) static var keepOnNextCancel = false

    /// How long a retry after an encoder killed under memory pressure waits for the pressure to ease (tests shorten it).
    nonisolated(unsafe) static var pressureWait: TimeInterval = 60

    private func waitForNormalPressure() async {
        let until = Date().addingTimeInterval(Self.pressureWait)
        while MemoryPressureWatch.shared.level != .normal, Date() < until {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// The source must still be there and unchanged (size and date: cheap) before each segment.
    func checkSource() throws {
        guard job.descriptor.kind != .rawSequence, let fp = journal.source else { return }
        let u = job.descriptor.url
        guard FileManager.default.fileExists(atPath: u.path) else {
            throw SourceChange(moved: true, file: u.lastPathComponent)
        }
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? fp.size
        let mod = a?[.modificationDate] as? Date ?? fp.modified
        if size != fp.size || abs(mod.timeIntervalSince(fp.modified)) > 0.5 {
            // Touched but identical bytes is fine; a different file is not.
            if let now = ExportJournal.SourceFingerprint.of(u), now.sameContent(fp) { return }
            throw SourceChange(moved: false, file: u.lastPathComponent)
        }
    }

    /// Full fingerprint before the join (audio and subtitles are read from the source then).
    func checkSourceBeforeJoin() throws {
        try checkSource()
        guard job.descriptor.kind != .rawSequence, let fp = journal.source, let now = ExportJournal.SourceFingerprint.of(job.descriptor.url) else { return }
        if !now.sameContent(fp) { throw SourceChange(moved: false, file: job.descriptor.url.lastPathComponent) }
    }

    // MARK: Target-quality chunks

    /// The chunk plan of a target-quality export: chosen once (it depends on this Mac's memory), then reused.
    func targetChunks(_ computed: [Range<Int>]) -> [Range<Int>] {
        if resuming, let saved = journal.chunkPlan, saved.allSatisfy({ $0.count == 2 }),
           saved.reduce(0, { $0 + $1[1] }) == computed.reduce(0, { $0 + $1.count }) {
            return saved.map { $0[0]..<($0[0] + $0[1]) }
        }
        update { $0.chunkPlan = computed.map { [$0.lowerBound, $0.count] }; $0.pieces = [] }
        return computed
    }

    /// The pieces of a chunk finished in an earlier run (checked again), or nil when it has to be encoded.
    func savedPieces(chunk: Int) -> [TargetQualityEncoder.Piece]? {
        guard resuming, let dir else { return nil }
        let saved = lock.withLock { journal.pieces.filter { $0.chunk == chunk } }
        guard !saved.isEmpty else { return nil }
        for p in saved {
            let u = dir.appendingPathComponent(p.file)
            let bytes = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard bytes == p.bytes, (try? SegmentValidator.sha256(u)) == p.sha256 else {
                log.warn("Saved chunk \(chunk) can't be reused (a piece changed on disk); it will be encoded again.", tag: "resume")
                update { $0.pieces.removeAll { $0.chunk == chunk } }
                return nil
            }
        }
        lock.withLock { reusedSegments.append(chunk) }
        log.info("Chunk \(chunk): reusing \(saved.count) saved piece\(saved.count == 1 ? "" : "s") (frames \(saved.map(\.start).min() ?? 0)–\(saved.map { $0.start + $0.count }.max() ?? 0))", tag: "resume")
        return saved.sorted { $0.start < $1.start }.map {
            TargetQualityEncoder.Piece(start: $0.start, url: dir.appendingPathComponent($0.file), count: $0.count, level: $0.level)
        }
    }

    /// A chunk's accepted pieces: moved into the checkpoint folder, flushed and journaled. Returns them at their new place.
    func chunkDone(_ chunk: Int, _ pieces: [TargetQualityEncoder.Piece]) throws -> [TargetQualityEncoder.Piece] {
        guard let dir else { return pieces }
        var out: [TargetQualityEncoder.Piece] = []
        var done: [ExportJournal.DonePiece] = []
        for (k, p) in pieces.enumerated() {
            let name = String(format: "segments/c%05d.p%d.%@", chunk, k, p.url.pathExtension)
            let dest = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: p.url, to: dest)
            CheckpointStore.fullSync(dest)
            let bytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            done.append(.init(chunk: chunk, start: p.start, count: p.count, level: p.level, file: name, bytes: bytes,
                              sha256: try SegmentValidator.sha256(dest)))
            var moved = p
            moved.url = dest
            out.append(moved)
        }
        lock.withLock {
            journal.pieces.removeAll { $0.chunk == chunk }
            journal.pieces += done
            encodedSegments.append(chunk)
        }
        try saveJournal()
        log.info("Chunk \(chunk) saved: \(pieces.count) piece\(pieces.count == 1 ? "" : "s"), \(pieces.reduce(0) { $0 + $1.count }) frames", tag: "chunk \(chunk)")
        if let n = FaultInjection.crashAfterSegments, lock.withLock({ Set(journal.pieces.map(\.chunk)).count }) >= n {
            throw FaultInjection.SimulatedCrash()
        }
        return out
    }

    // MARK: Join, metadata, delivery

    /// The joined video must have exactly the planned frames: a short or long result is never delivered.
    func checkFrameCount(_ url: URL, expected: Int) throws {
        guard ToolLocator.isAvailable("ffprobe") || url.pathExtension == "obu" else { return }
        let n = (try? SegmentValidator.packets(url, rate: rate)) ?? -1
        log.info("Joined video: \(n) frames (planned \(expected))", tag: "join")
        if n >= 0 && n != expected { throw FrameCountMismatch(got: n, expected: expected) }
    }

    /// The joined video, saved so the metadata steps can be retried without encoding again; the segments then go.
    func checkpointJoined(_ url: URL) -> URL {
        guard let dir else { return url }
        let dest = dir.appendingPathComponent("joined." + url.pathExtension)
        if url.standardizedFileURL == dest.standardizedFileURL { return url }
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return url }
        CheckpointStore.fullSync(dest)
        let segs = journal.segments.map(\.file)
        update { $0.joinedFile = dest.lastPathComponent; $0.state = .joined; $0.segments = [] }
        for f in segs { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        lock.lock(); segmentURLs = [:]; lock.unlock()
        log.info("Joined video saved; \(segs.count) segment files removed", tag: "join")
        return dest
    }

    var savedJoined: URL? {
        guard resuming, let dir, let f = journal.joinedFile else { return nil }
        let u = dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var savedFinal: URL? {
        guard let dir, let f = journal.finalFile else { return nil }
        let u = dir.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Moves the finished video into the checkpoint folder first, then into place: if the output drive went away or
    /// is full, the finished video is kept and "Save again" needs no rendering.
    func deliver(_ result: URL, move: (URL) throws -> Void) throws {
        setStage(.deliver)
        var kept = result
        if let dir {
            let dest = dir.appendingPathComponent("final." + result.pathExtension)
            if result.standardizedFileURL != dest.standardizedFileURL {
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: result, to: dest)) != nil { kept = dest }
            }
            if kept == dest { update { $0.finalFile = dest.lastPathComponent; $0.state = .deliveryPending } }
        }
        do {
            try FaultInjection.point(.deliver)
            try move(kept)
        } catch {
            throw DeliveryFailure(underlying: error, kept: kept)
        }
        log.stageEnd("deliver")
    }

    // MARK: Outcome

    private func finishSuccessfully() {
        heartbeat?.cancel()
        let size = (try? job.outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
        log.line(.result, "done", String(format: "finished in %.1f s → %@, %@", Date().timeIntervalSince(log.started), job.outputURL.path, size)
                 + (resuming ? " (resumed: \(reusedSegments.count) saved segments reused, \(encodedSegments.count) encoded)" : ""))
        if let dir { try? FileManager.default.removeItem(at: dir) }
        CheckpointStore.removeRootIfEmpty()
        log.close()
        RenderLog.prune(keep: Self.resumableLogs())
    }

    static func resumableLogs() -> Set<String> {
        Set(CheckpointStore.all().compactMap { $0.journal.logFile })
    }

    func context(segment: ExportJournal.PlannedSegment? = nil) -> FailureContext {
        lock.lock(); let st = stage; let f = failing; lock.unlock()
        var c = FailureContext(stage: st, fps: fps, scratch: CheckpointStore.root.deletingLastPathComponent(),
                               output: job.outputURL, sourceName: job.descriptor.url.lastPathComponent,
                               pressure: MemoryPressureWatch.shared.level)
        if let s = segment { c.segment = s.index; c.frames = s.range } else if let f { c.segment = f.0; c.frames = f.1 }
        return c
    }

    private func fail(_ error: Error) {
        heartbeat?.cancel()
        let canceled = error is CancellationError || Task.isCancelled && !(error is DeliveryFailure)
        let snapshot = SystemSnapshot.capture(scratch: CheckpointStore.root, output: job.outputURL, sleeps: journal.sleeps)
        var c = context()
        if error is ResumeRefused { c.stage = .prepare }
        var f = FailureClassifier.classify(error, context: c)
        if canceled { f.kind = .canceled }
        if let r = error as? ResumeRefused { f.kind = .unknown; f.message = r.localizedDescription }
        let keepWanted = options.keepProgressOnCancel || (canceled && Self.keepOnNextCancel)
        if canceled { Self.keepOnNextCancel = false }
        let keep = canceled ? keepWanted && (savedFrames > 0 || journal.joinedFile != nil) : true
        var facts = FailureExplainer.Facts()
        facts.progress = journal.progress
        facts.savedBytes = dir.map(CheckpointStore.size) ?? 0
        facts.finishedVideoKept = (error as? DeliveryFailure).map { FileManager.default.fileExists(atPath: $0.kept.path) && $0.kept.path.contains("/Checkpoints/") } ?? false
        facts.scratchVolume = snapshot.scratchVolume
        facts.outputFolder = job.outputURL.deletingLastPathComponent().lastPathComponent
        facts.sourceName = job.descriptor.url.lastPathComponent
        facts.retried = retried
        facts.delivery = job.delivery
        facts.freeBytes = f.stage == .deliver ? snapshot.outputFree : snapshot.scratchFree
        facts.upfront = dir == nil
        facts.mid = savedFrames > 0
        if let d = error as? SourceDamage, d.kind == .endedEarly || d.kind == .truncated {
            facts.claimedSeconds = Double(job.descriptor.frameCount) / max(1, job.descriptor.fps)
            facts.actualSeconds = d.seconds
        }
        var report = FailureExplainer.explain(f, facts: facts)
        if let r = error as? ResumeRefused {
            report.title = "This export has to start over"
            report.simple = r.localizedDescription
            report.means = "The saved progress can't be used safely; nothing was changed."
            report.actions = [.startOver, .discard]
        }
        if canceled && !keep { report.progress = 0 }
        report.exportID = exportID
        report.logPath = log.url.path
        self.report = report

        // Footer.
        log.raw("")
        log.line(.result, "failed", canceled ? "canceled at \(f.stage.rawValue)" : "failed at \(f.stage.rawValue): \(f.kind.rawValue)")
        log.raw("WHAT HAPPENED\n\(report.title)\n\(report.simple)\n\(report.means)")
        if !report.actions.isEmpty { log.raw("What you can do: " + report.actions.map { $0.label(report) }.joined(separator: " · ")) }
        log.raw("TECHNICAL\n\(report.proLine)\n" + report.technical.joined(separator: "\n"))
        log.raw("SYSTEM AT FAILURE\n" + snapshot.lines.joined(separator: "\n"))
        if let l = journal.plan {
            log.raw("PROGRESS: \(journal.segments.count) of \(l.segments.count) segments saved (\(journal.savedFrames) of \(l.frames) frames)"
                    + (journal.finalFile != nil ? "; the finished video is saved" : journal.joinedFile != nil ? "; the joined video is saved" : ""))
        }

        if let dir {
            if keep {
                update {
                    $0.state = canceled ? .cancelledKept : ($0.finalFile != nil ? .deliveryPending : .failed)
                    $0.failure = report
                    $0.lastEvent = canceled ? "canceled" : "failed"
                }
                log.info("Progress kept in the scratch folder (\(ByteCountFormatter.string(fromByteCount: facts.savedBytes, countStyle: .file))) so the export can resume", tag: "result")
            } else {
                try? FileManager.default.removeItem(at: dir)
                self.dir = nil
                CheckpointStore.removeRootIfEmpty()
            }
        }
        log.close()
    }

    // MARK: Watching the Mac

    private func startWatching() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting video")
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ f: @escaping (Notification) -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: nil, using: f)))
        }
        on(ws, NSWorkspace.willSleepNotification) { [weak self] _ in self?.slept() }
        on(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.woke() }
        on(ws, NSWorkspace.didUnmountNotification) { [weak self] n in
            guard let self, let v = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            let path = v.path
            if self.job.outputURL.path.hasPrefix(path) { self.log.line(.system, "system", "the output drive “\(v.lastPathComponent)” was disconnected") }
            if CheckpointStore.root.path.hasPrefix(path) { self.log.line(.system, "system", "the scratch drive “\(v.lastPathComponent)” was disconnected") }
            if self.job.descriptor.url.path.hasPrefix(path) { self.log.line(.system, "system", "the source drive “\(v.lastPathComponent)” was disconnected") }
        }
        on(nc, ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            let s = ProcessInfo.processInfo.thermalState
            self?.log.line(.system, "system", "thermal state is now \(["nominal", "fair", "serious", "critical"][min(3, s.rawValue)])")
        }
        on(nc, NSApplication.willTerminateNotification) { [weak self] _ in
            guard let self else { return }
            self.log.line(.system, "system", "Lumora is quitting during the export")
            self.lock.lock(); self.journal.willTerminate = true; self.journal.lastEvent = "quit"; self.journal.state = .interrupted; self.lock.unlock()
            try? self.saveJournal()
        }
    }

    private func stopWatching() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        for (c, o) in observers { c.removeObserver(o) }
        observers = []
        heartbeat?.cancel()
    }

    private func slept() {
        sleptAt = Date()
        log.line(.system, "system", "the Mac is going to sleep")
        update { $0.sleeps.append(.init(slept: Date(), woke: nil)); $0.lastEvent = "sleep" }
        if let dir { CheckpointStore.beat(dir, pressure: MemoryPressureWatch.shared.level, lastEvent: "sleep") }
    }

    private func woke() {
        let mins = sleptAt.map { Date().timeIntervalSince($0) / 60 } ?? 0
        log.line(.system, "system", String(format: "The Mac slept for %.0f min; the export continued.", mins))
        update {
            if let i = $0.sleeps.indices.last, $0.sleeps[i].woke == nil { $0.sleeps[i].woke = Date() }
            $0.lastEvent = "wake"
        }
    }

    /// Simulated sleep and wake for tests (the same path the system notifications take).
    func simulateSleepWake() { slept(); woke() }

    private func startHeartbeat() {
        guard let dir else { return }
        heartbeat?.cancel()
        heartbeat = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let p = MemoryPressureWatch.shared.level
                CheckpointStore.beat(dir, pressure: p, lastEvent: self.journal.lastEvent)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
}

/// Frames done per segment, written to the log every 10 seconds.
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var last = Date()
    private let started = Date()
    let log: RenderLog
    let tag: String
    let total: Int
    init(log: RenderLog, tag: String, total: Int) { self.log = log; self.tag = tag; self.total = total }
    func finish() {
        let done = lock.withLock { n }
        log.line(.frames, tag, String(format: "%d/%d frames, %.1f fps", done, total, Double(done) / max(0.01, Date().timeIntervalSince(started))))
    }
    func tick() {
        lock.lock()
        n += 1
        let now = Date()
        let due = now.timeIntervalSince(last) >= 10
        if due { last = now }
        let done = n
        lock.unlock()
        if due {
            log.line(.frames, tag, String(format: "%d/%d frames, %.1f fps", done, total, Double(done) / max(0.01, now.timeIntervalSince(started))))
        }
    }
}
