import Foundation

/// Where the time went in one tick (about a second), as fractions 0...1 averaged over the active pipeline lanes.
struct PipelineWindow: Sendable, Equatable {
    var producerDecode = 0.0          // decoding the source
    var producerUpscale = 0.0         // MetalFX / Core ML upscaling
    var producerInterp = 0.0          // RIFE / IFRNet frame interpolation (and other producer work)
    var producerBlocked = 0.0         // producer waiting for the grader to take a frame
    var graderStarved = 0.0           // grader waiting for the producer
    var graderGPU = 0.0               // grade command buffers running on the GPU
    var graderBlocked = 0.0           // grader waiting for the writer
    var writerStarved: Double?        // CLI: writer waiting for frames (encoder idle)
    var writerBackpressure: Double?   // CLI: writer blocked in the pipe (encoder busy)
    var engineNotReady: Double?       // hardware: the encoder input wasn't ready (media engine busy)
    var chunksRenderBlocked: Double?  // target quality: rendering waits for the quality search
    var chunksEncodersStarved: Double? // target quality: the quality search waits for rendered chunks
    var activeLanes = 0

    static let keys: [WritableKeyPath<PipelineWindow, Double>] = [
        \.producerDecode, \.producerUpscale, \.producerInterp, \.producerBlocked, \.graderStarved, \.graderGPU, \.graderBlocked,
    ]
    static let optionalKeys: [WritableKeyPath<PipelineWindow, Double?>] = [
        \.writerStarved, \.writerBackpressure, \.engineNotReady, \.chunksRenderBlocked, \.chunksEncodersStarved,
    ]
}

/// The Mac's load in the same tick.
struct LoadWindow: Sendable, Equatable {
    var cores = 1
    var busyCores = 0.0
    var selfCores = 0.0
    var childCores = 0.0
    var othersCores = 0.0
    var performanceBusy = 0.0
    var efficiencyBusy = 0.0
    var gpuDevice: Double?
    var gpuLumora: Double?
    var gpuOthersKnown = true          // false while Core ML upscaling/interpolation runs (its GPU time isn't attributed)
    var pressure = 1                   // 1 normal, 2 warning, 4 critical
    var swapGrowthMBPerMin = 0.0
    var thermal = 0                    // 0 nominal, 1 fair, 2 serious, 3 critical
    var writeMBps: Double?
    var driveMBps: Double?
    var diskLow = false

    static let keys: [WritableKeyPath<LoadWindow, Double>] = [
        \.busyCores, \.selfCores, \.childCores, \.othersCores, \.performanceBusy, \.efficiencyBusy, \.swapGrowthMBPerMin,
    ]
    static let optionalKeys: [WritableKeyPath<LoadWindow, Double?>] = [\.gpuDevice, \.gpuLumora, \.writeMBps]
}

struct ClassifierContext: Sendable, Equatable {
    var encoderName = "The encoder"
    var segments = 1
    var totalFrames = 0
    var hardware = false
    var targetQuality = false
    var encoderScalesPoorly = false    // libaom / AVM: threads help less than parallel segments
    var fasterPresetHint: String?      // measured speedup of the next faster preset, when calibrated
    var interpolating = false
    var upscaling = false
}

struct ClassifierTick: Sendable {
    var time: Double                   // seconds since the run started
    var frames: Int                    // frames finished so far (all lanes)
    var paused: String?
    var pipeline: PipelineWindow
    var load: LoadWindow
}

enum Bottleneck: String, Codable, Sendable, CaseIterable {
    case measuring, paused, thermal, memory, disk, otherApps, encoderSaturated, encoderCoresIdle
    case decode, interpolation, upscale, gpu, gpuSerial, hardwareEngine, qualitySearch, mixed

    var isAlarm: Bool { [.thermal, .memory, .disk, .otherApps].contains(self) }
    var label: String {
        switch self {
        case .measuring: return "not classified (too short to measure)"
        case .paused: return "paused"
        case .thermal: return "thermal limit"
        case .memory: return "memory"
        case .disk: return "disk"
        case .otherApps: return "other apps"
        case .encoderSaturated: return "encoder CPU, saturated"
        case .encoderCoresIdle: return "encoder CPU, cores idle"
        case .decode: return "decode"
        case .interpolation: return "interpolation"
        case .upscale: return "upscaling"
        case .gpu: return "GPU"
        case .gpuSerial: return "GPU, one frame at a time"
        case .hardwareEngine: return "media engine"
        case .qualitySearch: return "quality search"
        case .mixed: return "mixed"
        }
    }
}

struct Verdict: Sendable, Equatable {
    enum Confidence: String, Codable, Sendable { case high, medium, low }
    var kind: Bottleneck = .measuring
    var headline = "Measuring…"
    var reason = "Lumora needs a few seconds of frames to see where the time goes."
    var suggestion: String?
    var score: Double?                 // 0...1 of the capacity available to Lumora, for the limiting resource
    var cpuUse = 0.0
    var gpuUse = 0.0
    var engineUse = 0.0
    var confidence: Confidence = .low
    var isGood = false
    var scoreFormula = "CPU use = (Lumora + its encoders) ÷ (cores − other apps). GPU use = Lumora's GPU time ÷ (1 − other apps' GPU). Media engine use is inferred from how long the hardware encoder makes frames wait."

    /// One plain sentence for Simple mode.
    var sentence: String {
        guard let score else { return headline + "." }
        let pct = Int((score * 100).rounded())
        return "\(headline) (\(pct)%). \(reason)"
    }
}

/// Decides, from measurements only, what limits the render and how much of the Mac it uses. Pure and deterministic:
/// the same ticks always give the same verdicts, so it is unit-tested with synthetic windows.
final class BottleneckClassifier {
    let context: ClassifierContext
    private(set) var pipeline = PipelineWindow()
    private(set) var load = LoadWindow()
    private(set) var verdict = Verdict()
    private var lastTime: Double?
    private var started = false
    private var pending: Bottleneck?
    private var pendingCount = 0
    private var shownSince: Double = 0
    private var beforePause: Verdict?
    private var thermalSince: Double?
    private var earlyFPS: (frames: Int, time: Double)?
    private var lastFrames = 0
    private var fpsSmoothed: Double?
    let tau = 5.0

    init(context: ClassifierContext) { self.context = context }

    @discardableResult
    func update(_ t: ClassifierTick) -> Verdict {
        let dt = lastTime.map { max(0.05, t.time - $0) } ?? 1
        lastTime = t.time
        let a = started ? 1 - exp(-dt / tau) : 1
        started = true
        blend(t.pipeline, t.load, a)
        if t.time <= 60 { earlyFPS = (t.frames, max(0.001, t.time)) }
        let inst = Double(max(0, t.frames - lastFrames)) / dt
        lastFrames = t.frames
        fpsSmoothed = fpsSmoothed.map { $0 + (inst - $0) * a } ?? inst
        if t.load.thermal >= 2 { thermalSince = thermalSince ?? t.time } else { thermalSince = nil }

        if let p = t.paused {
            if verdict.kind != .paused { beforePause = verdict }
            verdict = Verdict(kind: .paused, headline: p, reason: "Nothing is rendering while paused; no work is lost.",
                              suggestion: nil, score: nil, confidence: .high)
            shownSince = t.time
            return verdict
        }
        if verdict.kind == .paused { verdict = beforePause ?? Verdict(); shownSince = t.time; pending = nil; pendingCount = 0 }

        let measuring = t.time < 15 || (t.frames < 48 && t.time < 120)
        let candidate = evaluate(time: t.time, frames: t.frames)
        if candidate.kind == verdict.kind {
            verdict = candidate                       // same verdict: refresh its numbers
            pending = nil; pendingCount = 0
            return verdict
        }
        if candidate.kind == pending { pendingCount += 1 } else { pending = candidate.kind; pendingCount = 1 }
        if measuring && !candidate.kind.isAlarm {
            var m = Verdict()
            m.cpuUse = candidate.cpuUse; m.gpuUse = candidate.gpuUse; m.engineUse = candidate.engineUse
            verdict = m
            return verdict
        }
        let need = candidate.kind.isAlarm ? 3 : 5
        let minShow = verdict.kind == .measuring ? 0 : 10.0
        if pendingCount >= need && t.time - shownSince >= minShow {
            verdict = candidate
            shownSince = t.time
            pending = nil; pendingCount = 0
        } else {
            // Keep showing the current verdict, but with today's numbers.
            verdict.cpuUse = candidate.cpuUse; verdict.gpuUse = candidate.gpuUse; verdict.engineUse = candidate.engineUse
        }
        return verdict
    }

    private func blend(_ p: PipelineWindow, _ l: LoadWindow, _ a: Double) {
        for k in PipelineWindow.keys { pipeline[keyPath: k] += (p[keyPath: k] - pipeline[keyPath: k]) * a }
        for k in PipelineWindow.optionalKeys {
            if let v = p[keyPath: k] { pipeline[keyPath: k] = pipeline[keyPath: k].map { $0 + (v - $0) * a } ?? v }
            else { pipeline[keyPath: k] = nil }
        }
        pipeline.activeLanes = p.activeLanes
        for k in LoadWindow.keys { load[keyPath: k] += (l[keyPath: k] - load[keyPath: k]) * a }
        for k in LoadWindow.optionalKeys {
            if let v = l[keyPath: k] { load[keyPath: k] = load[keyPath: k].map { $0 + (v - $0) * a } ?? v }
            else { load[keyPath: k] = nil }
        }
        load.cores = l.cores
        load.pressure = l.pressure
        load.thermal = l.thermal
        load.gpuOthersKnown = l.gpuOthersKnown
        load.driveMBps = l.driveMBps
        load.diskLow = l.diskLow
    }

    // MARK: - Rules

    static func cpuUse(_ l: LoadWindow) -> Double {
        let n = Double(max(1, l.cores))
        return min(1, (l.selfCores + l.childCores) / max(0.5, n - l.othersCores))
    }

    static func gpuUse(_ l: LoadWindow) -> Double {
        if l.gpuOthersKnown, let mine = l.gpuLumora {
            let others = max(0, (l.gpuDevice ?? mine) - mine)
            return min(1, mine / max(0.05, 1 - others))
        }
        return min(1, l.gpuDevice ?? l.gpuLumora ?? 0)
    }

    private func th(_ kind: Bottleneck, _ enter: Double, _ exit: Double) -> Double { verdict.kind == kind ? exit : enter }

    private func pct(_ x: Double) -> String { "\(Int((min(1, max(0, x)) * 100).rounded()))%" }
    private func cores(_ x: Double) -> String { String(format: "%.1f", x) }

    func evaluate(time: Double, frames: Int) -> Verdict {
        let p = pipeline, l = load
        let n = Double(max(1, l.cores))
        let cpu = Self.cpuUse(l), gpu = Self.gpuUse(l), engine = p.engineNotReady ?? 0
        let lumora = l.selfCores + l.childCores
        func make(_ kind: Bottleneck, _ headline: String, _ reason: String, _ suggestion: String?, score: Double?,
                  margin: Double, good: Bool = false) -> Verdict {
            var v = Verdict()
            v.kind = kind; v.reason = reason; v.suggestion = suggestion
            v.cpuUse = cpu; v.gpuUse = gpu; v.engineUse = engine; v.isGood = good
            v.score = score ?? max(cpu, gpu, engine)
            v.confidence = margin >= 0.2 && frames >= 30 ? .high : (margin >= 0.08 ? .medium : .low)
            v.headline = v.confidence == .high ? headline : (v.confidence == .medium ? "Probably: " + headline.prefix(1).lowercased() + headline.dropFirst()
                                                              : "Not sure yet: " + headline.prefix(1).lowercased() + headline.dropFirst())
            return v
        }

        // 2. Thermal
        if let since = thermalSince, time - since >= 10 {
            var drop = ""
            if let e = earlyFPS, e.frames > 0, let now = fpsSmoothed, e.time > 5 {
                let early = Double(e.frames) / e.time
                if early > 0, now < early { drop = " Speed is \(pct(1 - now / early)) below the first minute." }
            }
            return make(.thermal, "The Mac is hot and slowing itself down",
                        "macOS reports a \(l.thermal >= 3 ? "critical" : "serious") thermal state.\(drop)",
                        "Give the Mac some airflow, or pause until it cools. Lumora has slowed down to help.", score: nil, margin: 0.3)
        }
        // 3. Memory
        let swapEnter = verdict.kind == .memory ? 60.0 : 100.0
        if l.pressure >= 2 || l.swapGrowthMBPerMin > swapEnter {
            let what = l.pressure >= 4 ? "critical" : (l.pressure >= 2 ? "a warning" : "normal")
            let swap = l.swapGrowthMBPerMin > 1 ? String(format: ", and swap is growing by %.0f MB a minute", l.swapGrowthMBPerMin) : ""
            return make(.memory, "Memory is tight", "macOS reports memory pressure \(what)\(swap).",
                        "Close apps that use a lot of memory. Lumora runs fewer chunks at once until memory recovers.", score: nil, margin: 0.3)
        }
        // 4. Disk
        let bp = p.writerBackpressure ?? 0
        let writing = p.writerBackpressure != nil ? bp : engine
        if l.diskLow {
            return make(.disk, "The disk is almost full", "Free space is below the safe reserve for this export.",
                        "Free space on the drive, or clear Lumora's caches.", score: nil, margin: 0.3)
        }
        if writing >= th(.disk, 0.7, 0.6), l.childCores < 0.3 * n, let w = l.writeMBps, let d = l.driveMBps, d > 0, w >= 0.8 * d {
            return make(.disk, "The drive is the limit",
                        String(format: "Writing %.0f MB/s, close to the drive's measured %.0f MB/s, while the encoder waits.", w, d),
                        "Choose a faster scratch drive in Settings → Storage.", score: min(1, w / d), margin: writing - 0.7)
        }
        // 5. Other apps. Lumora must be CPU-limited: a CPU encoder holding up the pipe, or (CPU-light hardware
        // encodes) the media engine waiting on Lumora rather than the other way round.
        let cpuLimited = context.hardware ? engine < 0.6 : (bp >= 0.7 || lumora < 0.7 * n)
        if l.busyCores >= 0.92 * n, l.othersCores >= th(.otherApps, 0.25, 0.15) * n, cpuLimited {
            return make(.otherApps, "Other apps are competing for the CPU",
                        "Other apps use \(cores(l.othersCores)) of \(l.cores) cores, so Lumora gets \(cores(lumora)).",
                        "Close the busy apps listed below, or choose Lower priority to let them go first.",
                        score: cpu, margin: l.othersCores / n - 0.25 + 0.1)
        }
        // 10. Target quality: the quality search or the render
        if context.targetQuality, let blocked = p.chunksRenderBlocked, blocked >= th(.qualitySearch, 0.5, 0.4) {
            let saturated = l.busyCores >= 0.92 * n || cpu >= 0.85
            return make(.qualitySearch, saturated ? "Making good use of your Mac" : "The quality search is the limit",
                        "Rendering waits for trial encodes and quality checks \(pct(blocked)) of the time; CPU \(pct(l.busyCores / n)) busy.",
                        saturated ? "A lower quality target or fewer trials per chunk would finish sooner."
                                  : "More chunks at once would use the idle cores. Optimize for this Mac measures the best count.",
                        score: cpu, margin: blocked - 0.5 + 0.1, good: saturated)
        }
        // 6 / 7. Encoder-bound
        if p.writerBackpressure != nil, bp >= th(.encoderSaturated, 0.7, 0.6) || (verdict.kind == .encoderCoresIdle && bp >= 0.6) {
            // Judged on what other apps leave free: a Mac kept busy by others doesn't make a lightly threaded
            // encoder "saturated".
            let saturated = l.busyCores >= 0.92 * n || cpu >= 0.85
            if saturated || cpu >= 0.7 {
                return make(.encoderSaturated, "Making good use of your Mac",
                            "\(context.encoderName) is using every core (CPU \(pct(l.busyCores / n)) busy) and Lumora waits on it \(pct(bp)) of the time, so this is as fast as this quality setting goes.",
                            context.fasterPresetHint ?? "For more speed, choose a faster encoder preset (a little less quality for the size).",
                            score: cpu, margin: bp - 0.7 + (saturated ? 0.1 : 0), good: true)
            }
            var suggestion = "More parallel segments would use the idle cores. Optimize for this Mac measures the best count."
            if context.segments <= 1 && context.totalFrames <= 480 {
                suggestion = "This clip is too short to split into parallel segments, so there is nothing to change."
            } else if context.encoderScalesPoorly {
                suggestion = "This encoder gains little from more threads; more parallel segments help. Optimize for this Mac measures the best count."
            }
            let free = max(0, n - l.othersCores)
            return make(.encoderCoresIdle, "Cores are sitting idle",
                        "\(context.encoderName) is the limit (Lumora waits on it \(pct(bp)) of the time), but Lumora uses only \(cores(lumora)) of the \(cores(free)) cores other apps leave free.",
                        suggestion, score: cpu, margin: min(bp - 0.7, 0.7 - cpu) + 0.1)
        }
        // 9. Hardware engine
        if context.hardware, engine >= th(.hardwareEngine, 0.7, 0.6) {
            return make(.hardwareEngine, "Making good use of the media engine",
                        "The hardware encoder keeps Lumora waiting \(pct(engine)) of the time, so it is running flat out (inferred: macOS doesn't report media engine use).",
                        "This is as fast as hardware encoding goes. ProRes encodes faster still when file size doesn't matter.",
                        score: engine, margin: engine - 0.7 + 0.1, good: true)
        }
        // 8. Upstream-bound
        let starved: Double? = p.writerStarved ?? (context.hardware ? max(0, 1 - engine - p.graderBlocked) : nil)
            ?? (context.targetQuality ? p.chunksEncodersStarved : nil)
        if let starved, starved >= th(.decode, 0.5, 0.4) || [.decode, .interpolation, .upscale, .gpu, .gpuSerial].contains(verdict.kind) && starved >= 0.4 {
            if p.graderStarved >= 0.5 {
                let work = p.producerDecode + p.producerInterp + p.producerUpscale
                let shares: [(Bottleneck, Double)] = work > 0.01
                    ? [(.decode, p.producerDecode / work), (.interpolation, p.producerInterp / work), (.upscale, p.producerUpscale / work)]
                    : []
                if let top = shares.max(by: { $0.1 < $1.1 }), top.1 >= 0.5 {
                    switch top.0 {
                    case .interpolation:
                        return make(.interpolation, "Frame interpolation is the limit",
                                    "Making the in-between frames takes \(pct(top.1)) of the frame-preparation time; the encoder waits for frames \(pct(starved)) of the time.",
                                    "A faster interpolation model, or a lower output frame rate, would speed this up.",
                                    score: gpu, margin: top.1 - 0.5 + 0.1)
                    case .upscale:
                        return make(.upscale, "Upscaling is the limit",
                                    "Upscaling takes \(pct(top.1)) of the frame-preparation time; the encoder waits for frames \(pct(starved)) of the time.",
                                    "MetalFX upscaling is much faster than a Core ML model, at some cost in detail.",
                                    score: gpu, margin: top.1 - 0.5 + 0.1)
                    default:
                        return make(.decode, "Reading and decoding the source is the limit",
                                    "Decoding takes \(pct(top.1)) of the frame-preparation time; the encoder waits for frames \(pct(starved)) of the time.",
                                    "A source on a fast internal SSD decodes faster (Settings → Storage can copy it to the scratch drive first).",
                                    score: cpu, margin: top.1 - 0.5 + 0.1)
                    }
                }
                return make(.mixed, "Frame preparation is the limit",
                            "Decoding, interpolation and upscaling share the time; the encoder waits for frames \(pct(starved)) of the time.",
                            nil, score: nil, margin: 0.05)
            }
            if gpu >= 0.8 || (l.gpuDevice ?? 0) >= 0.9 {
                return make(.gpu, "The GPU is the limit",
                            "The GPU is \(pct(l.gpuDevice ?? gpu)) busy and the encoder waits for graded frames \(pct(starved)) of the time.",
                            "Extra grade steps (grain removal, 12-bit precision) cost GPU time; other GPU-heavy apps slow this too.",
                            score: gpu, margin: max(gpu - 0.8, (l.gpuDevice ?? 0) - 0.9) + 0.1)
            }
            return make(.gpuSerial, "Grading waits on the GPU one frame at a time",
                        "The encoder waits for graded frames \(pct(starved)) of the time, yet the GPU is only \(pct(l.gpuDevice ?? gpu)) busy.",
                        "More parallel segments would overlap the GPU work.", score: max(cpu, gpu), margin: 0.0)
        }
        // 11. Mixed
        return make(.mixed, "Mixed: no single step dominates", "Every stage takes a share of the time.",
                    nil, score: max(cpu, gpu, engine), margin: 0.0)
    }
}

/// Decides whether a render is alive. A slow frame (AV2 at 90 s a frame, Real-ESRGAN at 4K) is never called stalled:
/// the limit scales with this run's own frame times, and any sign of life (encoder CPU, GPU work, files growing)
/// counts as waiting, not stalled.
enum RunStatus: Equatable, Sendable {
    case starting
    case rendering
    case paused(String)
    case waiting(String)
    case stalled(seconds: Int, on: String)
    case finishing(String)
    case done

    var text: String {
        switch self {
        case .starting: return "Starting"
        case .rendering: return "Rendering live"
        case .paused(let r): return r.hasPrefix("Paused") ? r : "Paused: \(r)"
        case .waiting(let s): return "Waiting on \(s)"
        case .stalled(let sec, let on): return "Stalled \(sec >= 120 ? "\(sec / 60)m" : "\(sec)s"): waiting on \(on)"
        case .finishing(let s): return s
        case .done: return "Done"
        }
    }
    var isStalled: Bool { if case .stalled = self { return true }; return false }
    var isPaused: Bool { if case .paused = self { return true }; return false }
}

struct StallInput: Sendable {
    var now: Double
    var startedAt: Double
    var lastFrameAt: Double?
    var paused: String?
    var finishing: String?
    var p95FrameInterval: Double?
    var expectedFirstFrame: Double = 30
    var setting: Double = 60
    var childCores: Double = 0
    var lastGPUAt: Double?
    var lastGrowthAt: Double?
    var inputsClosed = false           // every lane has handed over its last frame
    var waitingOn = "the next frame"
}

enum StallDetector {
    static func limit(_ i: StallInput) -> Double {
        var t = max(i.setting, 8 * (i.p95FrameInterval ?? 0))
        if i.lastFrameAt == nil { t = max(t, i.expectedFirstFrame) }
        return t
    }

    static func evaluate(_ i: StallInput) -> RunStatus {
        if let p = i.paused { return .paused(p) }
        if let f = i.finishing { return .finishing(f) }
        let quiet = i.now - (i.lastFrameAt ?? i.startedAt)
        let t = limit(i)
        let active = i.childCores > 0.02
            || (i.lastGPUAt.map { i.now - $0 < 30 } ?? false)
            || (i.lastGrowthAt.map { i.now - $0 < 30 } ?? false)
        if i.inputsClosed {
            return active || quiet < t ? .waiting("\(i.waitingOn) (finishing its last frames)") : .stalled(seconds: Int(quiet), on: i.waitingOn)
        }
        if quiet >= t {
            return active ? .waiting(i.waitingOn) : .stalled(seconds: Int(quiet), on: i.waitingOn)
        }
        if i.lastFrameAt == nil { return quiet < 3 ? .starting : .waiting(i.waitingOn) }
        if quiet >= max(5, 3 * (i.p95FrameInterval ?? 0)) { return .waiting(i.waitingOn) }
        return .rendering
    }
}
