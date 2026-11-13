import Foundation
import Metal
import AVFoundation

/// A pipeline lane: one parallel segment (keyed by its first output frame), the target-quality render, or one
/// trial encode of the quality search.
enum LaneID: Hashable, Sendable {
    case segment(Int)
    case trial(String)
}

enum ProbeStage: Sendable { case decode, upscale, pause }
enum ProbeChannel: Sendable { case prepared, packed, chunks }

/// The export engine's taps. Every call is a cheap no-op unless a monitored run is active, so code paths that
/// never call `begin` (previews, calibration, forecasts) pay nothing.
final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: MonitoredRun?

    /// The most recent run, also after it ended (tests and the export's own report read its summary).
    var lastRun: MonitoredRun? { lock.lock(); defer { lock.unlock() }; return active }

    var run: MonitoredRun? { lock.lock(); defer { lock.unlock() }; return active.flatMap { $0.ended ? nil : $0 } }

    /// Starts monitoring an export: sampler, preview, governor and disk watch. `end()` writes the summary.
    func begin(_ job: ExportJob, frames: Int, rate: (num: Int, den: Int)) -> MonitoredRun {
        let r = MonitoredRun(job: job, frames: frames, rate: rate)
        lock.lock(); active = r; lock.unlock()
        r.start()
        return r
    }

    /// Wraps the decoder so its time is measured on its own (interpolation is the producer's remaining work).
    func meteredSource(_ source: FrameSource, lane range: Range<Int>) -> FrameSource {
        guard let r = run else { return source }
        let id = LaneID.segment(range.lowerBound)
        r.openLane(id, range: range)
        return MeteredFrameSource(base: source, run: r, lane: id)
    }

    func meter(_ channel: ProbeChannel, lane: Int = 0) -> ChannelMeter? { run?.meter(channel, lane: .segment(lane)) }

    func time<T>(_ stage: ProbeStage, lane: Int, _ body: () throws -> T) rethrows -> T {
        guard let r = run else { return try body() }
        let t0 = CACurrentMediaTimeCompat()
        defer { r.add(stage, lane: .segment(lane), seconds: CACurrentMediaTimeCompat() - t0) }
        return try body()
    }

    /// Time spent in the pause gate (user pause, run rules, governor pacing), so it isn't mistaken for work.
    func paused(lane: Int, _ body: () async -> Void) async {
        guard let r = run else { await body(); return }
        let t0 = CACurrentMediaTimeCompat()
        await body()
        r.add(.pause, lane: .segment(lane), seconds: CACurrentMediaTimeCompat() - t0)
    }

    /// Hardware encodes: time with the encoder input not ready = the media engine is busy (backpressure).
    func watch(_ input: AVAssetWriterInput, lane: Int, frames: Int) { run?.watch(input, lane: .segment(lane), frames: frames) }

    /// Right before a grade's command buffer is committed: GPU time, progress, heartbeat and (time-gated) preview.
    func graded(_ cb: MTLCommandBuffer, rgb: MTLTexture, outputIndex: Int, lane: Int) {
        run?.graded(cb, rgb: rgb, outputIndex: outputIndex, lane: .segment(lane))
    }

    /// A target-quality trial encode (file names `chunk<ID>-<tag>`), shown as its own labeled lane.
    func trialLane(_ url: URL, frames: Int) -> TrialLane {
        guard let r = run else { return TrialLane(run: nil, id: .trial("")) }
        let tag = url.deletingPathExtension().lastPathComponent
        let id = LaneID.trial(tag + "#" + UUID().uuidString.prefix(4))
        r.openTrial(id, label: Self.trialLabel(tag), frames: frames)
        return TrialLane(run: r, id: id)
    }

    static func trialLabel(_ tag: String) -> String {
        // chunk12-t3, chunk12-g0, chunk12-p1, chunk-3-t1 (forecast samples have negative IDs)
        guard tag.hasPrefix("chunk") else { return tag }
        let body = tag.dropFirst(5)
        guard let dash = body.lastIndex(of: "-") else { return tag }
        let idText = body[..<dash]
        let kind = body[body.index(after: dash)...]
        guard let id = Int(idText) else { return tag }
        if id < 0 { return "Size forecast sample \(-id)" }
        let n = kind.dropFirst()
        switch kind.first {
        case "t": return "Chunk \(id) · trial \(Int(n).map { $0 + 1 } ?? 1) (quality search)"
        case "g": return "Chunk \(id) · raised quality \(Int(n).map { $0 + 1 } ?? 1) (perceptual check)"
        case "p": return "Chunk \(id) · part \(n.split(separator: "-").first.map(String.init) ?? "") (fixing dips)"
        default: return "Chunk \(id)"
        }
    }
}

struct TrialLane {
    let run: MonitoredRun?
    let id: LaneID
    func fed() { run?.trialFed(id) }
    func close() { run?.closeTrial(id) }
}

final class MeteredFrameSource: FrameSource {
    let base: FrameSource
    private let run: MonitoredRun
    private let lane: LaneID
    init(base: FrameSource, run: MonitoredRun, lane: LaneID) { self.base = base; self.run = run; self.lane = lane }
    var width: Int { base.width }
    var height: Int { base.height }
    var fps: Double { base.fps }
    var frameCount: Int { base.frameCount }
    func start(at frame: Int, count: Int?) throws { try base.start(at: frame, count: count) }
    func nextFrame() throws -> DecodedFrame? {
        let t0 = CACurrentMediaTimeCompat()
        defer { run.add(.decode, lane: lane, seconds: CACurrentMediaTimeCompat() - t0) }
        return try base.nextFrame()
    }
    func cancel() { base.cancel() }
}

/// Everything measured about one export while it runs, turned once a second into a snapshot for the UI and,
/// at the end, a summary for the log and report.
final class MonitoredRun: @unchecked Sendable {
    enum LaneKind: String, Sendable { case segment, render, trial }

    final class Lane {
        let id: LaneID
        var kind: LaneKind
        var label: String
        var range: Range<Int>?
        var total: Int
        var prepared: ChannelMeter?
        var packed: ChannelMeter?
        var chunks: ChannelMeter?
        var decode = 0.0
        var upscale = 0.0
        var pause = 0.0
        var graded = 0
        var position: Int?
        var lastFrameAt: Double?
        var gpuBusy = 0.0
        var lastGPUAt: Double?
        var hardware = false
        var vtNotReady = 0.0
        var vtNotReadyStart = 0.0
        var vtObservation: NSKeyValueObservation?
        var fed = 0
        var openedAt: Double
        var closedAt: Double?
        var last = Reading()
        init(id: LaneID, kind: LaneKind, label: String, total: Int, at: Double) {
            self.id = id; self.kind = kind; self.label = label; self.total = total; openedAt = at
        }
        struct Reading {
            var t: Double = 0, decode = 0.0, upscale = 0.0, pause = 0.0, gpu = 0.0, notReady = 0.0
            var prepSend = 0.0, prepRecv = 0.0, packSend = 0.0, packRecv = 0.0, chunkSend = 0.0, chunkRecv = 0.0
        }
        var closed: Bool {
            if closedAt != nil { return true }
            switch kind {
            case .trial: return false
            case .render, .segment:
                if let p = packed { return p.reading().closed }
                if hardware, let r = range { return graded >= r.count && (prepared?.reading().closed ?? true) }
                return chunks?.reading().closed ?? prepared?.reading().closed ?? false
            }
        }
    }

    struct LaneSnapshot: Sendable, Identifiable, Hashable {
        var id: String
        var label: String
        var detail: String
        var position: Int?
        var progress: Double?
        var closed: Bool
        var kind: String
    }

    struct HistoryPoint: Sendable, Identifiable, Hashable {
        var id: Int
        var t: Double
        var lumora: Double, encoders: Double, others: Double, idle: Double
        var gpuLumora: Double?, gpuDevice: Double?
        var fps: Double
    }

    struct StageTiming: Sendable, Hashable { var name: String; var msPerFrame: Double; var share: Double }

    struct Snapshot: Sendable {
        var id: UUID
        var name: String
        var codecName: String
        var encoderName: String
        var targetKind: OutputTarget.Kind
        var peakNits: Float
        var status: RunStatus = .starting
        var heartbeat: Double?               // seconds since the last finished frame
        var framesDone = 0
        var totalFrames = 0
        var fraction = 0.0
        var fps = 0.0
        var realtime = 0.0
        var eta: Double?
        var elapsed = 0.0
        var position: Int?
        var timecode = "00:00:00:00"
        var verdict = Verdict()
        var lanes: [LaneSnapshot] = []
        var history: [HistoryPoint] = []
        var sample = SystemSample()
        var stages: [StageTiming] = []
        var pipeline = PipelineWindow()
        var encoderStarved: Double?
        var pipeBlocked: Double?
        var engineNotReady: Double?
        var gpuLumora: Double?
        var targetQuality = false
        var hardware = false
        var probeCostMs = 0.0
        var ended = false
    }

    let id = UUID()
    let name: String
    let job: ExportJob
    let totalFrames: Int
    let rate: (num: Int, den: Int)
    let hub: LivePreviewHub
    let startedAt = CACurrentMediaTimeCompat()
    let startDate = Date()
    let encoderName: String
    let context: ClassifierContext
    private(set) var ended = false
    private(set) var summary: RenderSummary?

    private let lock = NSLock()
    private var lanes: [LaneID: Lane] = [:]
    private var laneOrder: [LaneID] = []
    private let classifier: BottleneckClassifier
    private var observer: UUID?
    private var lastTick: Double = 0
    private var intervals: [Double] = []
    private var gpuSpans: [(Double, Double)] = []
    private var history: [HistoryPoint] = []
    private var historyID = 0
    private var snapshotValue: Snapshot
    private var probeCost = 0.0
    private var tapCost = 0.0, tapCalls = 0, tickCost = 0.0, tickCount = 0, maxTick = 0.0
    private var lastFramesTotal = 0
    private var fpsSmoothed = 0.0
    private var lastPausedState: String?
    private var swapStart: Double?
    private var responsivenessMark = 0
    // Summary accumulators (unpaused ticks)
    private var acc = Accumulator()
    // Disk watch
    private var lastDiskCheck: Double = 0
    private var lastScratchBytes: Int64 = 0
    private var lastGrowthAt: Double?
    private var writeMBps: Double?
    private var lastBytesAt: Double = 0

    struct Accumulator {
        var ticks = 0, selfCores = 0.0, childCores = 0.0, othersCores = 0.0, pBusy = 0.0, eBusy = 0.0
        var gpuDevice = 0.0, gpuDeviceTicks = 0, gpuLumora = 0.0, gpuLumoraTicks = 0
        var worstPressure = 1, worstThermal = 0
        var verdictTicks: [Bottleneck: Int] = [:]
        var score = 0.0, scoreTicks = 0
        var starved = 0.0, blocked = 0.0, writerTicks = 0
        var notReady = 0.0, notReadyTicks = 0
        var pauses = 0, stalls = 0, wasStalled = false
        var childNames: [String: Int] = [:]
        var maxChildren = 0
    }

    init(job: ExportJob, frames: Int, rate: (num: Int, den: Int)) {
        self.job = job
        self.totalFrames = frames
        self.rate = rate
        self.name = job.outputURL.lastPathComponent
        let spec = ExportEngine.encoder(for: job)
        self.encoderName = job.codec.isHardware ? (job.codec == .hevc ? "The hardware HEVC encoder" : "The ProRes engine") : (spec?.binary ?? job.codec.displayName)
        var c = ClassifierContext()
        c.encoderName = encoderName
        c.totalFrames = frames
        c.hardware = job.codec.isHardware
        c.targetQuality = job.qualityTarget != nil && ![.prores422HQ, .prores4444XQ, .av2].contains(job.codec)
        c.encoderScalesPoorly = ["aomenc", "avmenc"].contains(spec?.binary ?? "")
        c.segments = job.codec.isHardware ? 1 : ChipProfile.current.segments(for: job.codec, frameCount: frames)
        if case .off = job.interpolation.mode {} else { c.interpolating = true }
        c.upscaling = job.upscale != .off
        self.context = c
        classifier = BottleneckClassifier(context: c)
        hub = LivePreviewHub(target: job.target, rate: rate, totalFrames: frames)
        snapshotValue = Snapshot(id: id, name: job.outputURL.lastPathComponent, codecName: job.codec.displayName, encoderName: encoderName,
                                 targetKind: job.target.kind, peakNits: job.target.effectivePeak)
        snapshotValue.totalFrames = frames
        snapshotValue.targetQuality = c.targetQuality
        snapshotValue.hardware = c.hardware
        hub.filmstripEnabled = { !LoadGovernor.shared.memoryTight }
    }

    func start() {
        lastTick = startedAt
        SystemSampler.shared.retain()
        ResponsivenessProbe.shared.retain()
        responsivenessMark = ResponsivenessProbe.shared.mark()
        observer = SystemSampler.shared.observe { [weak self] s in self?.tick(s) }
        RenderMonitor.register(self)
        Log.info(.encode, "Render monitor: \(totalFrames) frames, \(context.hardware ? "hardware" : encoderName) encode")
    }

    /// Ends monitoring and writes the summary (on success, failure and cancel alike).
    func end() {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        for l in lanes.values { l.vtObservation?.invalidate(); l.vtObservation = nil }
        lock.unlock()
        // One last reading, so a render shorter than a sampling interval still has lanes and stage numbers.
        SystemSampler.shared.sampleNow()
        if let observer { SystemSampler.shared.stopObserving(observer) }
        let outcome: String
        if Task.isCancelled { outcome = "canceled" }
        else if let m = (try? job.outputURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                m >= startDate.addingTimeInterval(-1) { outcome = "finished" }
        else { outcome = "stopped" }
        let summary = makeSummary(outcome: outcome)
        lock.lock(); self.summary = summary; lock.unlock()
        Log.notice(.encode, "Render summary: " + summary.line)
        summary.save()
        LoadGovernor.shared.setDiskPause(nil)
        SystemSampler.shared.release()
        ResponsivenessProbe.shared.release()
        RenderMonitor.unregister(self, summary: summary)
    }

    // MARK: - Lanes

    private var aliases: [LaneID: LaneID] = [:]

    /// The lane for a key. A segment key that falls inside another lane's frame range (a producer that starts a few
    /// frames early to warm up temporal state, for instance) is the same lane.
    private func lane(_ id: LaneID) -> Lane {
        if let l = lanes[id] { return l }
        if let a = aliases[id], let l = lanes[a] { return l }
        if case .segment(let k) = id, let l = lanes.values.first(where: { $0.range?.contains(k) ?? false }) {
            aliases[id] = l.id
            return l
        }
        let l = Lane(id: id, kind: context.targetQuality ? .render : .segment, label: "", total: totalFrames, at: CACurrentMediaTimeCompat())
        lanes[id] = l
        laneOrder.append(id)
        return l
    }

    func openLane(_ id: LaneID, range: Range<Int>) {
        lock.lock(); defer { lock.unlock() }
        if lanes[id] == nil, let existing = lanes.values.first(where: { l in
            if case .segment(let k) = l.id { return l.range == nil && range.contains(k) && k != range.lowerBound }
            return false
        }) {
            aliases[id] = existing.id
        }
        let l = lane(id)
        l.range = range
        l.total = range.count
        l.hardware = context.hardware
    }

    func meter(_ channel: ProbeChannel, lane id: LaneID) -> ChannelMeter {
        let m = ChannelMeter()
        lock.lock()
        let l = lane(id)
        switch channel {
        case .prepared: l.prepared = m
        case .packed: l.packed = m
        case .chunks: l.chunks = m
        }
        lock.unlock()
        return m
    }

    func add(_ stage: ProbeStage, lane id: LaneID, seconds: Double) {
        lock.lock()
        let l = lane(id)
        switch stage {
        case .decode: l.decode += seconds
        case .upscale: l.upscale += seconds
        case .pause: l.pause += seconds
        }
        lock.unlock()
    }

    func watch(_ input: AVAssetWriterInput, lane id: LaneID, frames: Int) {
        lock.lock()
        let l = lane(id)
        l.hardware = true
        if l.range == nil { l.total = frames }
        lock.unlock()
        let obs = input.observe(\.isReadyForMoreMediaData, options: [.initial, .new]) { [weak self, weak l] inp, change in
            guard let self, let l else { return }
            let ready = change.newValue ?? inp.isReadyForMoreMediaData
            let t = CACurrentMediaTimeCompat()
            self.lock.lock()
            if !ready, l.vtNotReadyStart == 0 { l.vtNotReadyStart = t }
            if ready, l.vtNotReadyStart > 0 { l.vtNotReady += t - l.vtNotReadyStart; l.vtNotReadyStart = 0 }
            self.lock.unlock()
        }
        lock.lock(); l.vtObservation = obs; lock.unlock()
    }

    func graded(_ cb: MTLCommandBuffer, rgb: MTLTexture, outputIndex: Int, lane id: LaneID) {
        let c0 = Self.threadCPU()
        let t0 = CACurrentMediaTimeCompat()
        lock.lock()
        let l = lane(id)
        lock.unlock()
        hub.offer(cb, rgb: rgb, outputIndex: outputIndex, lane: id, now: t0)
        cb.addCompletedHandler { [weak self, weak l] buffer in
            guard let self, let l else { return }
            let now = CACurrentMediaTimeCompat()
            let start = buffer.gpuStartTime, end = buffer.gpuEndTime
            self.lock.lock()
            if end > start, start > 0 {
                l.gpuBusy += end - start
                self.gpuSpans.append((start, end))
                if self.gpuSpans.count > 4096 { self.gpuSpans.removeFirst(2048) }
            }
            l.lastGPUAt = now
            if let last = l.lastFrameAt {
                self.intervals.append(now - last)
                if self.intervals.count > 256 { self.intervals.removeFirst(128) }
            }
            l.lastFrameAt = now
            l.graded += 1
            l.position = outputIndex
            self.lock.unlock()
        }
        let cost = Self.threadCPU() - c0
        lock.lock(); probeCost += cost; tapCost += cost; tapCalls += 1; lock.unlock()
    }

    /// CPU time of the calling thread: the monitor's own cost, unaffected by the thread being preempted on a busy Mac.
    @inline(__always) static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    func openTrial(_ id: LaneID, label: String, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let l = Lane(id: id, kind: .trial, label: label, total: frames, at: CACurrentMediaTimeCompat())
        lanes[id] = l
        laneOrder.append(id)
        // Only the recent trials matter on screen.
        let trials = laneOrder.filter { if case .trial = $0 { return true }; return false }
        if trials.count > 24, let old = trials.first(where: { lanes[$0]?.closedAt != nil }) {
            lanes[old] = nil
            laneOrder.removeAll { $0 == old }
        }
    }

    func trialFed(_ id: LaneID) {
        let t = CACurrentMediaTimeCompat()
        lock.lock()
        if let l = lanes[id] { l.fed += 1; l.lastFrameAt = t; l.position = l.fed }
        lock.unlock()
    }

    func closeTrial(_ id: LaneID) {
        lock.lock(); lanes[id]?.closedAt = CACurrentMediaTimeCompat(); lock.unlock()
    }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snapshotValue }

    /// Cumulative per-lane timings: wall time of the producer, and the measured parts of it.
    struct LaneTotals: Sendable { var lane: String; var producerWall: Double; var decode: Double; var upscale: Double; var pause: Double; var producerBlocked: Double
        var graderStarved: Double; var gpu: Double; var writerStarved: Double?; var engineNotReady: Double; var graded: Int; var fed: Int; var kind: String }
    func laneTotals() -> [LaneTotals] {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTimeCompat()
        return laneOrder.compactMap { lanes[$0] }.map { l in
            let p = l.prepared?.reading(at: now)
            let wall = p.map { ($0.closedAt ?? now) - $0.openedAt } ?? 0
            return LaneTotals(lane: "\(l.id)", producerWall: wall, decode: l.decode, upscale: l.upscale, pause: l.pause, producerBlocked: p?.sendWait ?? 0,
                              graderStarved: p?.receiveWait ?? 0, gpu: l.gpuBusy, writerStarved: l.packed?.reading(at: now).receiveWait,
                              engineNotReady: l.vtNotReady, graded: l.graded, fed: l.fed, kind: l.kind.rawValue)
        }
    }

    /// CPU seconds the probe itself has spent (taps and ticks), for the overhead check.
    var selfCost: Double { lock.lock(); defer { lock.unlock() }; return probeCost }
    var costBreakdown: String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "taps %.1f ms over %d frames, ticks %.1f ms over %d (max %.1f ms)", tapCost * 1000, tapCalls, tickCost * 1000, tickCount, maxTick * 1000)
    }

    // MARK: - Tick (sampler queue, once a second)

    func tick(_ s: SystemSample) {
        let c0 = Self.threadCPU()
        let now = s.time
        lock.lock()
        let dt = max(0.05, now - lastTick)
        let windowStart = lastTick
        lastTick = now

        var w = PipelineWindow()
        var weight = 0.0
        var writerWeight = 0.0, engineWeight = 0.0, chunkWeight = 0.0
        var sumStarved = 0.0, sumBP = 0.0, sumNotReady = 0.0, sumRenderBlocked = 0.0, sumEncStarved = 0.0
        var framesDone = 0
        var lastFrame: Double?
        var lastGPU: Double?
        var position: Int?
        var latestAt = 0.0
        var lanesOut: [LaneSnapshot] = []
        var allClosed = true
        var anyMain = false
        var segmentIndex = 0
        let sorted = laneOrder.compactMap { lanes[$0] }
        for l in sorted {
            if let f = l.lastFrameAt { lastFrame = max(lastFrame ?? f, f) }
            if let g = l.lastGPUAt { lastGPU = max(lastGPU ?? g, g) }
            let closed = l.closed
            if l.kind != .trial {
                anyMain = true
                framesDone += l.graded
                if !closed { allClosed = false }
                if let f = l.lastFrameAt, f >= latestAt { latestAt = f; position = l.position }
            }
            // Lane time in this window.
            let from = max(windowStart, l.openedAt)
            let to = min(now, l.closedAt ?? (closed ? (l.packed?.reading().closedAt ?? now) : now))
            let span = max(0, to - from)
            var r = Lane.Reading(t: now)
            r.decode = l.decode; r.upscale = l.upscale; r.pause = l.pause; r.gpu = l.gpuBusy
            r.notReady = l.vtNotReady + (l.vtNotReadyStart > 0 ? now - l.vtNotReadyStart : 0)
            if let m = l.prepared?.reading(at: now) { r.prepSend = m.sendWait; r.prepRecv = m.receiveWait }
            if let m = l.packed?.reading(at: now) { r.packSend = m.sendWait; r.packRecv = m.receiveWait }
            if let m = l.chunks?.reading(at: now) { r.chunkSend = m.sendWait; r.chunkRecv = m.receiveWait }
            if span > 0.05, l.kind != .trial {
                func f(_ x: Double) -> Double { min(1, max(0, x / span)) }
                let decode = f(r.decode - l.last.decode), upscale = f(r.upscale - l.last.upscale)
                let blocked = f(r.prepSend - l.last.prepSend)
                let pausing = f(r.pause - l.last.pause)
                let busy = max(0, 1 - blocked - pausing)
                let interp = context.interpolating ? max(0, busy - decode - upscale) : 0
                w.producerDecode += (context.interpolating ? decode : max(decode, busy - upscale)) * span
                w.producerUpscale += upscale * span
                w.producerInterp += interp * span
                w.producerBlocked += blocked * span
                w.graderStarved += f(r.prepRecv - l.last.prepRecv) * span
                w.graderGPU += f(r.gpu - l.last.gpu) * span
                w.graderBlocked += f(r.packSend - l.last.packSend) * span
                weight += span
                if l.packed != nil {
                    let starved = f(r.packRecv - l.last.packRecv)
                    sumStarved += starved * span; sumBP += (1 - starved) * span; writerWeight += span
                }
                if l.hardware { sumNotReady += f(r.notReady - l.last.notReady) * span; engineWeight += span }
                if l.chunks != nil {
                    sumRenderBlocked += f(r.chunkSend - l.last.chunkSend) * span
                    sumEncStarved += f(r.chunkRecv - l.last.chunkRecv) * span
                    chunkWeight += span
                }
                w.activeLanes += closed ? 0 : 1
            }
            l.last = r
            // Lane list
            var label = l.label
            var detail = ""
            var progress: Double?
            switch l.kind {
            case .segment:
                segmentIndex += 1
                if let range = l.range {
                    label = "Segment \(segmentIndex) · frames \(range.lowerBound)–\(range.upperBound - 1)"
                    progress = Double(l.graded) / Double(max(1, range.count))
                }
                detail = closed ? "done" : (l.position.map { "at frame \($0) · \(PreviewFrame.timecode(frame: $0, rate: rate))" } ?? "starting")
            case .render:
                label = "Rendering frames for the quality search"
                progress = Double(l.graded) / Double(max(1, totalFrames))
                detail = l.position.map { "at frame \($0)" } ?? "starting"
            case .trial:
                progress = Double(l.fed) / Double(max(1, l.total))
                detail = l.closedAt != nil ? "done" : "\(l.fed) of \(l.total) frames fed"
            }
            lanesOut.append(LaneSnapshot(id: "\(l.id)", label: label, detail: detail, position: l.position, progress: progress,
                                         closed: closed || l.closedAt != nil, kind: l.kind.rawValue))
        }
        if weight > 0 {
            for k in PipelineWindow.keys { w[keyPath: k] /= weight }
        }
        if writerWeight > 0 { w.writerStarved = sumStarved / writerWeight; w.writerBackpressure = sumBP / writerWeight }
        if engineWeight > 0 { w.engineNotReady = sumNotReady / engineWeight }
        if chunkWeight > 0 { w.chunksRenderBlocked = sumRenderBlocked / chunkWeight; w.chunksEncodersStarved = sumEncStarved / chunkWeight }

        // Lumora's GPU time: the union of grade command buffers in this window.
        let spans = gpuSpans.filter { $0.1 > windowStart }.sorted { $0.0 < $1.0 }
        gpuSpans.removeAll { $0.1 <= windowStart }
        var gpuBusy = 0.0
        var curStart = -1.0, curEnd = -1.0
        for (a0, b0) in spans {
            let a = max(a0, windowStart), b = min(b0, now)
            guard b > a else { continue }
            if a > curEnd { if curEnd > curStart { gpuBusy += curEnd - curStart }; curStart = a; curEnd = b } else { curEnd = max(curEnd, b) }
        }
        if curEnd > curStart { gpuBusy += curEnd - curStart }
        let gpuLumora = anyMain ? min(1, gpuBusy / dt) : nil
        let p95 = Self.percentile(intervals, 0.95)
        let lanesSnapshot = lanesOut
        lock.unlock()

        // Load
        var load = LoadWindow()
        load.cores = s.cores
        load.busyCores = s.busyCores
        load.selfCores = s.selfCores
        load.childCores = s.childCores
        load.othersCores = s.othersCores
        load.performanceBusy = s.performanceBusy
        load.efficiencyBusy = s.efficiencyBusy
        load.gpuDevice = s.gpuDevice
        load.gpuLumora = gpuLumora
        load.gpuOthersKnown = !(context.upscaling || context.interpolating)
        load.pressure = s.pressureLevel
        load.swapGrowthMBPerMin = LoadGovernor.shared.swapGrowthMBPerMin
        load.thermal = s.thermal.rawValue
        let diskPause = LoadGovernor.shared.current.diskPause
        load.diskLow = diskPause != nil
        load.writeMBps = writeMBps
        load.driveMBps = MacProfile.current?.scratchWriteMBps

        LoadGovernor.shared.observe(s, rendering: true)
        SystemSampler.shared.wantAppScan(LoadGovernor.shared.overloadSuspected || RenderMonitor.panelOpen)
        let paused = LoadGovernor.shared.pauseReason ?? PauseGateMirror.reason
        // Once every lane has handed over its last frame the pipeline is only flushing: keep the verdict it earned.
        let flushing = allClosed && anyMain
        let verdict = flushing ? classifier.verdict
            : classifier.update(ClassifierTick(time: now - startedAt, frames: framesDone, paused: paused, pipeline: w, load: load))

        // Disk watch, every 5 s.
        if now - lastDiskCheck >= 5 { diskWatch(now: now, framesDone: framesDone) }

        // Status
        let finishing = allClosed && anyMain ? Self.finishingStep(children: s.children) : nil
        let waitingOn = waitingOn(w, children: s.children, allClosed: allClosed)
        var stall = StallInput(now: now, startedAt: startedAt, lastFrameAt: lastFrame, paused: paused,
                               finishing: finishing, p95FrameInterval: p95, setting: RenderMonitor.stallSeconds,
                               childCores: s.childCores, lastGPUAt: lastGPU, lastGrowthAt: lastGrowthAt,
                               inputsClosed: allClosed && anyMain && finishing == nil, waitingOn: waitingOn)
        stall.expectedFirstFrame = 60
        let status = StallDetector.evaluate(stall)

        // Speed
        lock.lock()
        let inst = Double(max(0, framesDone - lastFramesTotal)) / dt
        lastFramesTotal = framesDone
        fpsSmoothed = fpsSmoothed == 0 ? inst : fpsSmoothed + (inst - fpsSmoothed) * (1 - exp(-dt / 4))
        let elapsed = now - startedAt
        let avgFPS = elapsed > 0 ? Double(framesDone) / elapsed : 0
        let fps = max(0, framesDone >= 5 ? fpsSmoothed : avgFPS)
        let outFPS = Double(rate.num) / Double(max(1, rate.den))
        let remaining = Double(max(0, totalFrames - framesDone))
        let rateForETA = avgFPS > 0 ? (fps * 0.5 + avgFPS * 0.5) : fps
        historyID += 1
        let idle = max(0, Double(s.cores) - s.busyCores)
        history.append(HistoryPoint(id: historyID, t: elapsed, lumora: s.selfCores, encoders: s.childCores, others: s.othersCores,
                                    idle: idle, gpuLumora: gpuLumora, gpuDevice: s.gpuDevice, fps: fps))
        if history.count > 120 { history.removeFirst(history.count - 120) }

        // Summary accumulators
        if paused == nil && (!flushing || acc.ticks == 0) {     // a render shorter than one tick still counts once
            acc.ticks += 1
            acc.selfCores += s.selfCores; acc.childCores += s.childCores; acc.othersCores += s.othersCores
            acc.pBusy += s.performanceBusy; acc.eBusy += s.efficiencyBusy
            if let g = s.gpuDevice { acc.gpuDevice += g; acc.gpuDeviceTicks += 1 }
            if let g = gpuLumora { acc.gpuLumora += g; acc.gpuLumoraTicks += 1 }
            if verdict.kind != .measuring { acc.verdictTicks[verdict.kind, default: 0] += 1 }
            if let sc = verdict.score, verdict.kind != .measuring { acc.score += sc; acc.scoreTicks += 1 }
            for c in s.children where c.cores > 0.3 { acc.childNames[c.name, default: 0] += 1 }
            acc.maxChildren = max(acc.maxChildren, s.children.filter { $0.cores > 0.3 }.count)
        }
        if paused == nil {     // the writer's waits count up to the last frame, flush included
            if let st = w.writerStarved, let bp = w.writerBackpressure { acc.starved += st; acc.blocked += bp; acc.writerTicks += 1 }
            if let nr = w.engineNotReady { acc.notReady += nr; acc.notReadyTicks += 1 }
        }
        acc.worstPressure = max(acc.worstPressure, s.pressureLevel)
        acc.worstThermal = max(acc.worstThermal, s.thermal.rawValue)
        if swapStart == nil { swapStart = s.swapUsedMB }
        if (paused != nil) != (lastPausedState != nil), paused != nil { acc.pauses += 1 }
        lastPausedState = paused
        if status.isStalled && !acc.wasStalled { acc.stalls += 1; Log.warning(.encode, "Render \(status.text)") }
        acc.wasStalled = status.isStalled

        var snap = snapshotValue
        snap.status = status
        snap.heartbeat = lastFrame.map { now - $0 }
        snap.framesDone = framesDone
        snap.fraction = Double(framesDone) / Double(max(1, totalFrames))
        snap.fps = fps
        snap.realtime = fps / max(0.001, outFPS)
        snap.eta = rateForETA > 0.01 ? remaining / rateForETA : nil
        snap.elapsed = elapsed
        snap.position = position
        snap.timecode = PreviewFrame.timecode(frame: position ?? 0, rate: rate)
        snap.verdict = verdict
        snap.lanes = lanesSnapshot
        snap.history = history
        snap.sample = s
        snap.pipeline = classifier.pipeline
        snap.encoderStarved = w.writerStarved
        snap.pipeBlocked = w.writerBackpressure
        snap.engineNotReady = w.engineNotReady
        snap.gpuLumora = gpuLumora
        snap.stages = stageTimingsLocked(framesDone: framesDone)
        let tc = Self.threadCPU() - c0
        probeCost += tc; tickCost += tc; tickCount += 1; maxTick = max(maxTick, tc)
        snap.probeCostMs = probeCost * 1000
        snapshotValue = snap
        lock.unlock()
    }

    private func waitingOn(_ w: PipelineWindow, children: [SystemSample.Child], allClosed: Bool) -> String {
        let busyChild = children.first { $0.cores > 0.05 }?.name
        if allClosed { return busyChild ?? encoderName }
        if let bp = w.writerBackpressure, bp >= 0.5 { return busyChild ?? encoderName }
        if let nr = w.engineNotReady, nr >= 0.5 { return "the media engine" }
        if let rb = w.chunksRenderBlocked, rb >= 0.5 { return "the quality search" }
        if w.graderStarved >= 0.5 {
            if w.producerUpscale >= max(w.producerDecode, w.producerInterp) { return "upscaling" }
            if w.producerInterp >= w.producerDecode { return "frame interpolation" }
            return "decoding"
        }
        if w.graderGPU >= 0.5 { return "the GPU" }
        return busyChild ?? "the next frame"
    }

    static func finishingStep(children: [SystemSample.Child]) -> String? {
        let names = Set(children.map { $0.name.lowercased() })
        if names.contains("dovi_tool") { return "Finishing file: adding Dolby Vision metadata" }
        if names.contains("hdr10plus_tool") { return "Finishing file: adding HDR10+ metadata" }
        if names.contains("mkvmerge") || names.contains("mp4box") { return "Finishing file: writing the container" }
        if names.contains("ffmpeg") { return "Finishing file: joining segments" }
        return nil
    }

    private func diskWatch(now: Double, framesDone: Int) {
        lastDiskCheck = now
        let scratch = DiskBudget.Roots.app.scratch
        let since = startDate.addingTimeInterval(-5)
        var bytes: Int64 = 0
        for f in (try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created >= since, f.lastPathComponent != "Proxies" { bytes += DiskBudget.size(f) }
        }
        if bytes > lastScratchBytes + 65536 {
            if lastBytesAt > 0 { writeMBps = Double(bytes - lastScratchBytes) / max(1, now - lastBytesAt) / 1_048_576 }
            lastGrowthAt = now
        } else if lastBytesAt > 0 { writeMBps = 0 }
        lastScratchBytes = bytes
        lastBytesAt = now
        let paused = LoadGovernor.shared.current.diskPause != nil
        guard framesDone >= 48 || paused, let quick = DiskBudget.quickSpace(scratch) else { return }
        let perFrame = Double(bytes) / Double(max(1, framesDone))
        let remaining = totalFrames - framesDone
        let finish = Int64(perFrame * Double(totalFrames)) * ([.dolbyVision81, .dolbyVision84, .hdr10Plus].contains(job.delivery) ? 3 : 1)
        var pause = DiskBudget.shouldPause(free: quick.free, total: quick.total, remainingFrames: remaining, bytesPerFrame: perFrame, finishBytes: finish)
        // Confirm with the slower reading that counts purgeable space before pausing or staying paused.
        guard pause, let v = DiskBudget.space(scratch) else {
            if paused { LoadGovernor.shared.setDiskPause(nil) }
            return
        }
        pause = DiskBudget.shouldPause(free: v.free, total: v.total, remainingFrames: remaining, bytesPerFrame: perFrame, finishBytes: finish)
        if pause {
            let need = Int64(perFrame * Double(remaining)) + finish + DiskBudget.floor(total: v.total) - v.free
            LoadGovernor.shared.setDiskPause("Paused: \(v.name) is almost full. Free \(DiskBudget.gb(max(need, 1 << 30))) to continue.")
        } else if LoadGovernor.shared.current.diskPause != nil {
            LoadGovernor.shared.setDiskPause(nil)
        }
    }

    private func stageTimingsLocked(framesDone: Int) -> [StageTiming] {
        guard framesDone > 0 else { return [] }
        let all = lanes.values.filter { $0.kind != .trial }
        let decode = all.reduce(0) { $0 + $1.decode }
        let upscale = all.reduce(0) { $0 + $1.upscale }
        let gpu = all.reduce(0) { $0 + $1.gpuBusy }
        let n = Double(framesDone)
        let total = max(0.000001, decode + upscale + gpu)
        var out = [StageTiming(name: "Decode", msPerFrame: decode / n * 1000, share: decode / total)]
        if context.upscaling { out.append(StageTiming(name: "Upscale", msPerFrame: upscale / n * 1000, share: upscale / total)) }
        out.append(StageTiming(name: "Grade (GPU)", msPerFrame: gpu / n * 1000, share: gpu / total))
        return out
    }

    static func percentile(_ a: [Double], _ p: Double) -> Double? {
        guard a.count >= 4 else { return nil }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    // MARK: - Summary

    private func makeSummary(outcome: String) -> RenderSummary {
        let snap = snapshot
        lock.lock()
        let a = acc
        let swap0 = swapStart ?? 0
        let all = lanes.values.filter { $0.kind != .trial }
        let decode = all.reduce(0) { $0 + $1.decode }, upscale = all.reduce(0) { $0 + $1.upscale }, gpu = all.reduce(0) { $0 + $1.gpuBusy }
        let cost = probeCost
        let frames = all.reduce(0) { $0 + $1.graded }
        lock.unlock()
        let t = max(1, a.ticks)
        let wall = CACurrentMediaTimeCompat() - startedAt
        let top = a.verdictTicks.max { $0.value < $1.value }?.key ?? (snap.verdict.kind == .paused ? .paused : snap.verdict.kind)
        let encoders = a.childNames.sorted { $0.value > $1.value }.prefix(2).map { name, _ in
            a.maxChildren > 1 && a.childNames.count == 1 ? "\(name) ×\(a.maxChildren)" : name }
        let n = Double(max(1, frames))
        let resp = ResponsivenessProbe.shared
        let busy = resp.busyMain(since: responsivenessMark)
        let base = resp.report.mainIdle
        return RenderSummary(
            name: name, outcome: outcome, date: startDate, frames: frames, totalFrames: totalFrames, seconds: wall,
            fps: wall > 0 ? Double(frames) / wall : 0, outputFPS: Double(rate.num) / Double(max(1, rate.den)),
            bottleneck: top.label, bottleneckKind: top.rawValue, verdictHeadline: snap.verdict.headline,
            score: a.scoreTicks > 0 ? a.score / Double(a.scoreTicks) : nil,
            encoders: encoders.isEmpty ? [encoderName] : Array(encoders),
            lumoraCores: a.selfCores / Double(t), encoderCores: a.childCores / Double(t), otherCores: a.othersCores / Double(t),
            cores: snap.sample.cores, performanceBusy: a.pBusy / Double(t), efficiencyBusy: a.eBusy / Double(t),
            gpuDevice: a.gpuDeviceTicks > 0 ? a.gpuDevice / Double(a.gpuDeviceTicks) : nil,
            gpuLumora: a.gpuLumoraTicks > 0 ? a.gpuLumora / Double(a.gpuLumoraTicks) : nil,
            pressure: LoadGovernor.pressureName(a.worstPressure), swapGrowthMB: snap.sample.swapUsedMB - swap0,
            thermal: ["nominal", "fair", "serious", "critical"][min(3, max(0, a.worstThermal))],
            decodeMs: decode / n * 1000, upscaleMs: context.upscaling ? upscale / n * 1000 : nil, gradeGPUMs: gpu / n * 1000,
            encoderStarved: a.writerTicks > 0 ? a.starved / Double(a.writerTicks) : nil,
            pipeBlocked: a.writerTicks > 0 ? a.blocked / Double(a.writerTicks) : nil,
            engineBusy: a.notReadyTicks > 0 ? a.notReady / Double(a.notReadyTicks) : nil,
            pauses: a.pauses, stalls: a.stalls,
            uiP95Ms: busy.count > 0 ? busy.p95 : nil, uiBaselineP95Ms: base.count > 0 ? base.p95 : nil,
            uiMaxMs: busy.count > 0 ? busy.max : nil,
            monitorCostMs: cost * 1000 + SystemSampler.shared.averageCostMs * Double(a.ticks))
    }
}

/// The user-pause reason as last seen (PauseGate is an actor; the monitor reads a mirror updated from the UI).
enum PauseGateMirror {
    nonisolated(unsafe) static var reason: String?
}
