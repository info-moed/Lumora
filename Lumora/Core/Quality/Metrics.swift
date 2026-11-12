import Foundation

/// Every quality metric Lumora can use, what it's good at, and where it comes from.
enum QualityMetric: String, CaseIterable, Codable, Identifiable {
    case vmaf, vmafNeg, cvvdp, puPsnr, xpsnr, ssimulacra2, cambi, msssim, psnrHvs, ciede, avqt
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vmaf: return "VMAF"
        case .vmafNeg: return "VMAF NEG"
        case .cvvdp: return "ColorVideoVDP"
        case .puPsnr: return "PU21-PSNR"
        case .xpsnr: return "XPSNR"
        case .ssimulacra2: return "SSIMULACRA 2"
        case .cambi: return "CAMBI banding"
        case .msssim: return "MS-SSIM"
        case .psnrHvs: return "PSNR-HVS"
        case .ciede: return "CIEDE2000"
        case .avqt: return "AVQT (Apple)"
        }
    }

    var plainEnglish: String {
        switch self {
        case .vmaf: return "Netflix's perceptual score (0–100). Fast and well understood; trained on SDR viewing."
        case .vmafNeg: return "VMAF that ignores encoder sharpening tricks, so a score can't be inflated."
        case .cvvdp: return "Cambridge's model of human vision for SDR and HDR, colour and motion, on a described display. 10 = identical; a drop of 1 means 75% of viewers would notice."
        case .puPsnr: return "PSNR on perceptually uniform (PU21) HDR values. A cheap HDR-aware fidelity check."
        case .xpsnr: return "Fraunhofer's perceptually weighted PSNR (in FFmpeg). Tracks visible error better than plain PSNR."
        case .ssimulacra2: return "Cloudinary's psycho-visual metric. ~90 means hard to tell apart at normal viewing. SDR only."
        case .cambi: return "Netflix's banding detector. Lumora measures how much banding the encode adds over the master."
        case .msssim: return "Multi-scale structural similarity. A classic sanity check."
        case .psnrHvs: return "PSNR weighted by the eye's contrast sensitivity."
        case .ciede: return "Average colour difference (ΔE 2000). Catches colour shifts the luma metrics miss."
        case .avqt: return "Apple's Advanced Video Quality Tool (1–5), HDR10/HLG/Dolby Vision aware. Needs an Apple developer download; used when comparing files."
        }
    }

    var unit: String {
        switch self {
        case .cvvdp: return "JOD"
        case .puPsnr, .xpsnr, .psnrHvs: return "dB"
        case .ciede: return "ΔE"
        default: return ""
        }
    }

    var higherIsBetter: Bool { !(self == .cambi || self == .ciede) }
    var hdrAware: Bool { [.cvvdp, .puPsnr, .avqt, .cambi].contains(self) }
    /// Seconds per 1080p-equivalent frame on a modern Mac, roughly; used by the planner.
    var costPerFrame: Double {
        switch self {
        case .cvvdp: return 0.12
        case .ssimulacra2: return 0.05
        case .avqt: return 0.004
        case .xpsnr, .puPsnr: return 0.006
        default: return 0.004   // libvmaf features share one pass
        }
    }
    var slow: Bool { self == .cvvdp || self == .ssimulacra2 }

    /// Which tool provides it.
    var source: String {
        switch self {
        case .vmaf, .vmafNeg, .cambi, .msssim, .psnrHvs, .ciede: return "libvmaf (brew install libvmaf)"
        case .xpsnr: return "FFmpeg 7+ (xpsnr filter)"
        case .cvvdp, .puPsnr: return "ColorVideoVDP (Model Lab → Install quality metrics)"
        case .ssimulacra2: return "ssimulacra2_rs (cargo install ssimulacra2_rs)"
        case .avqt: return "AVQT from developer.apple.com"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .vmaf, .vmafNeg, .cambi, .msssim, .psnrHvs, .ciede: return VMAFRunner.backend == .vmafCLI || (self == .vmaf && VMAFRunner.available)
        case .xpsnr: return MetricSuite.ffmpegHasXPSNR
        case .cvvdp, .puPsnr: return MetricSuite.pythonMetricsReady
        case .ssimulacra2: return ToolLocator.isAvailable("ssimulacra2_rs")
        case .avqt: return ToolLocator.isAvailable("AVQT")
        }
    }
}

enum MetricRole: String, CaseIterable, Codable, Identifiable {
    case target = "Search on"       // drives the bitrate search (fast metric)
    case mustPass = "Must pass"     // checked before a chunk is accepted
    case report = "Report"
    case off = "Off"
    var id: String { rawValue }
}

struct MetricRule: Codable, Hashable, Identifiable {
    var metric: QualityMetric
    var role: MetricRole
    var threshold: Double
    var useWorstFrames = false        // pool on the worst 5% instead of the average
    var id: String { metric.rawValue }

    func passes(_ value: Double) -> Bool { metric.higherIsBetter ? value >= threshold : value <= threshold }
}

/// A named set of rules: what "good enough" means for this export.
struct QualityProfile: Codable, Hashable, Identifiable {
    var name: String
    var summary: String
    var rules: [MetricRule]
    var id: String { name }

    var primary: MetricRule? { rules.first { $0.role == .target } }
    var gates: [MetricRule] { rules.filter { $0.role == .mustPass } }

    static func presets(hdr: Bool) -> [QualityProfile] {
        let cvvdpDisplay = hdr ? "HDR display" : "4K display"
        return [
            QualityProfile(name: "Imperceptible",
                           summary: "Searches with a relaxed VMAF, then proves the result with ColorVideoVDP (\(cvvdpDisplay)), banding and colour checks. Usually reaches invisible quality at a lower bitrate than chasing VMAF 95 alone.",
                           rules: [MetricRule(metric: .vmaf, role: .target, threshold: 93),
                                   MetricRule(metric: .cvvdp, role: .mustPass, threshold: 9.6),
                                   MetricRule(metric: .cambi, role: .mustPass, threshold: 1.0),
                                   MetricRule(metric: .vmafNeg, role: .mustPass, threshold: 88, useWorstFrames: true),
                                   MetricRule(metric: .ciede, role: .mustPass, threshold: 1.5),
                                   MetricRule(metric: .ssimulacra2, role: hdr ? .off : .mustPass, threshold: 85),
                                   MetricRule(metric: .xpsnr, role: .report, threshold: 40),
                                   MetricRule(metric: .puPsnr, role: hdr ? .report : .off, threshold: 40),
                                   MetricRule(metric: .msssim, role: .report, threshold: 0.98),
                                   MetricRule(metric: .psnrHvs, role: .report, threshold: 38)]),
            QualityProfile(name: "Visually lossless",
                           summary: "Slightly looser: differences only on close, side-by-side inspection of hard scenes.",
                           rules: [MetricRule(metric: .vmaf, role: .target, threshold: 92),
                                   MetricRule(metric: .cvvdp, role: .mustPass, threshold: 9.3),
                                   MetricRule(metric: .cambi, role: .mustPass, threshold: 1.5),
                                   MetricRule(metric: .ciede, role: .mustPass, threshold: 2.0),
                                   MetricRule(metric: .xpsnr, role: .report, threshold: 39),
                                   MetricRule(metric: .vmafNeg, role: .report, threshold: 86)]),
            QualityProfile(name: "Transparent streaming",
                           summary: "Excellent streaming quality; VMAF drives it, perceptual scores are reported.",
                           rules: [MetricRule(metric: .vmaf, role: .target, threshold: 93),
                                   MetricRule(metric: .cambi, role: .mustPass, threshold: 2.0),
                                   MetricRule(metric: .cvvdp, role: .report, threshold: 9.0),
                                   MetricRule(metric: .xpsnr, role: .report, threshold: 38)]),
            QualityProfile(name: "VMAF only",
                           summary: "The classic single-number target.",
                           rules: [MetricRule(metric: .vmaf, role: .target, threshold: 95)])
        ]
    }

    /// Drops rules whose tools aren't installed; if a gate is missing, tightens the search target to compensate.
    func effective() -> (profile: QualityProfile, notes: [String]) {
        var p = self
        var notes: [String] = []
        for i in p.rules.indices where p.rules[i].role != .off && !p.rules[i].metric.isAvailable {
            notes.append("\(p.rules[i].metric.displayName) isn't installed (\(p.rules[i].metric.source)); skipped.")
            if p.rules[i].role == .mustPass, p.rules[i].metric == .cvvdp, let t = p.rules.firstIndex(where: { $0.role == .target }) {
                p.rules[t].threshold = max(p.rules[t].threshold, 95)
                notes.append("Without ColorVideoVDP, the VMAF target is raised to 95 to stay safe.")
            }
            p.rules[i].role = .off
        }
        return (p, notes)
    }
}

/// Scores for one encode, per metric: per-frame values where the tool provides them, and pooled values.
struct MetricScores {
    var perFrame: [QualityMetric: [(index: Int, value: Double)]] = [:]
    var pooled: [QualityMetric: (mean: Double, worst: Double)] = [:]

    func value(_ r: MetricRule) -> Double? {
        guard let p = pooled[r.metric] else { return nil }
        return r.useWorstFrames ? p.worst : p.mean
    }

    /// Pass/fail against the profile's search target and gates. Metrics that weren't measured don't block.
    func passes(_ profile: QualityProfile, includeSlow: Bool) -> (ok: Bool, failures: [String]) {
        var failures: [String] = []
        for r in profile.rules where r.role == .target || r.role == .mustPass {
            if r.metric.slow && !includeSlow { continue }
            guard let v = value(r) else { continue }
            if !r.passes(v) {
                failures.append("\(r.metric.displayName) \(String(format: "%.2f", v)) \(r.metric.higherIsBetter ? "<" : ">") \(String(format: "%.2f", r.threshold))")
            }
        }
        return (failures.isEmpty, failures)
    }

    static func pool(_ values: [Double], higherIsBetter: Bool) -> (mean: Double, worst: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        let k = max(0, Int(Double(values.count) * 0.05) - 1)
        let worst = higherIsBetter ? sorted[k] : sorted[sorted.count - 1 - k]
        return (values.reduce(0, +) / Double(values.count), worst)
    }
}

/// Runs the requested metrics concurrently, streaming the RAM reference into each tool through pipes.
enum MetricSuite {
    static let ffmpegHasXPSNR: Bool = {
        guard let d = try? ToolLocator.run("ffmpeg", ["-hide_banner", "-filters"]) else { return false }
        return String(decoding: d, as: UTF8.self).contains("xpsnr")
    }()

    static var pythonMetricsReady: Bool {
        FileManager.default.fileExists(atPath: ModelLab.lab.appendingPathComponent("venv/bin/python").path)
            && FileManager.default.fileExists(atPath: ModelLab.lab.appendingPathComponent(".metrics-installed").path)
    }

    struct Context {
        var width: Int, height: Int
        var rate: (Int, Int)
        var hdr: Bool
        var frames: Int
        var threads: Int
        var fast: Bool
        var workDir: URL
        /// AV1 grain synthesis: decode without applying the synthetic grain (scored against a de-grained master).
        var stripSyntheticGrain = false
        var decoderArgs: [String] { stripSyntheticGrain ? ["-export_side_data", "film_grain"] : [] }
    }

    static func measure(_ metrics: Set<QualityMetric>, reference: @escaping (FileHandle) throws -> Void,
                        distorted: URL, ctx: Context) async throws -> MetricScores {
        var scores = MetricScores()
        try await withThrowingTaskGroup(of: MetricScores.self) { group in
            let libvmafSet = metrics.intersection([.vmaf, .vmafNeg, .cambi, .msssim, .psnrHvs, .ciede])
            if !libvmafSet.isEmpty {
                group.addTask { try await libvmaf(libvmafSet, reference: reference, distorted: distorted, ctx: ctx) }
            }
            if metrics.contains(.xpsnr) {
                group.addTask { try await xpsnr(reference: reference, distorted: distorted, ctx: ctx) }
            }
            if metrics.contains(.ssimulacra2) && !ctx.hdr {
                group.addTask { try await ssimulacra2(reference: reference, distorted: distorted, ctx: ctx) }
            }
            let py = metrics.intersection([.cvvdp, .puPsnr])
            if !py.isEmpty {
                group.addTask { try await python(py, reference: reference, distorted: distorted, ctx: ctx) }
            }
            for try await s in group {
                scores.perFrame.merge(s.perFrame) { a, _ in a }
                scores.pooled.merge(s.pooled) { a, _ in a }
            }
        }
        Log.debug(.quality, "Metrics for \(distorted.lastPathComponent): " + scores.pooled.map { "\($0.key.displayName) \(String(format: "%.3f", $0.value.mean))" }.joined(separator: ", "))
        return scores
    }

    // MARK: libvmaf: VMAF, VMAF NEG, CAMBI (full-reference, PQ-aware), MS-SSIM, PSNR-HVS, CIEDE2000 in one pass

    private static func libvmaf(_ set: Set<QualityMetric>, reference: @escaping (FileHandle) throws -> Void,
                                distorted: URL, ctx: Context) async throws -> MetricScores {
        var extra: [String] = []
        let big = ctx.height > 1600 && !ctx.fast
        extra += ["--model", "version=\(big ? "vmaf_4k_v0.6.1" : "vmaf_v0.6.1")"]
        if set.contains(.vmafNeg) { extra += ["--model", "version=vmaf_v0.6.1neg:name=vmaf_neg"] }
        if set.contains(.cambi) { extra += ["--feature", "cambi=full_ref=true:eotf=\(ctx.hdr ? "pq" : "bt1886")"] }
        if set.contains(.msssim) { extra += ["--feature", "float_ms_ssim"] }
        if set.contains(.psnrHvs) { extra += ["--feature", "psnr_hvs"] }
        if set.contains(.ciede) { extra += ["--feature", "ciede"] }
        let frames = try await VMAFRunner.runLibvmaf(writeReference: reference, distorted: distorted, frameRate: ctx.rate,
                                                     threads: ctx.threads, subsample: ctx.fast ? 2 : 1,
                                                     downscaleHeight: ctx.fast && ctx.height > 1600 ? 1080 : nil,
                                                     extraArgs: extra, workDir: ctx.workDir, decoderInputArgs: ctx.decoderArgs)
        var s = MetricScores()
        func collect(_ m: QualityMetric, _ pick: ([String: Double]) -> Double?) {
            let v = frames.compactMap { f in pick(f.metrics).map { (f.index, $0) } }
            guard !v.isEmpty else { return }
            s.perFrame[m] = v
            s.pooled[m] = MetricScores.pool(v.map(\.1), higherIsBetter: m.higherIsBetter)
        }
        collect(.vmaf) { $0["vmaf"] }
        if set.contains(.vmafNeg) { collect(.vmafNeg) { d in d["vmaf_neg"] ?? d.first { $0.key.contains("neg") }?.value } }
        if set.contains(.cambi) { collect(.cambi) { d in d["cambi_full_reference"] ?? d.first { $0.key.contains("cambi") && $0.key.contains("full") }?.value ?? d["cambi"] } }
        if set.contains(.msssim) { collect(.msssim) { $0["float_ms_ssim"] } }
        if set.contains(.psnrHvs) { collect(.psnrHvs) { $0["psnr_hvs"] ?? $0["psnr_hvs_y"] } }
        if set.contains(.ciede) { collect(.ciede) { $0["ciede2000"] } }
        return s
    }

    // MARK: XPSNR (FFmpeg filter)

    private static func xpsnr(reference: @escaping (FileHandle) throws -> Void, distorted: URL, ctx: Context) async throws -> MetricScores {
        let stats = ctx.workDir.appendingPathComponent("xpsnr-\(UUID().uuidString.prefix(6)).txt")
        defer { try? FileManager.default.removeItem(at: stats) }
        let p = Process()
        p.executableURL = ToolLocator.url(for: "ffmpeg")
        p.arguments = ["-v", "error", "-f", "yuv4mpegpipe", "-i", "pipe:0"] + ctx.decoderArgs + ["-r", "\(ctx.rate.0)/\(ctx.rate.1)", "-i", distorted.path,
                       "-lavfi", "[1:v]format=yuv420p10le[d];[0:v]format=yuv420p10le[r];[d][r]xpsnr=stats_file=\(stats.path)",
                       "-f", "null", "-"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        try await Task.detached { try reference(pipe.fileHandleForWriting); try pipe.fileHandleForWriting.close() }.value
        await Task.detached { p.waitUntilExit() }.value
        // Lines look like: "n:    1  XPSNR y: 41.2345  XPSNR u: 44.1  XPSNR v: 45.0"
        let text = (try? String(contentsOf: stats, encoding: .utf8)) ?? ""
        var values: [(Int, Double)] = []
        for (i, line) in text.split(separator: "\n").enumerated() {
            guard let r = line.range(of: "XPSNR y:") else { continue }
            let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if let v = Double(tail.split(separator: " ").first ?? "") { values.append((i, v)) }
        }
        var s = MetricScores()
        if !values.isEmpty {
            s.perFrame[.xpsnr] = values
            s.pooled[.xpsnr] = MetricScores.pool(values.map(\.1), higherIsBetter: true)
        }
        return s
    }

    // MARK: SSIMULACRA 2 (SDR) via ssimulacra2_rs

    private static func ssimulacra2(reference: @escaping (FileHandle) throws -> Void, distorted: URL, ctx: Context) async throws -> MetricScores {
        let tag = UUID().uuidString.prefix(6)
        let ref = ctx.workDir.appendingPathComponent("s2ref-\(tag).y4m").path, dist = ctx.workDir.appendingPathComponent("s2dist-\(tag).y4m").path
        guard mkfifo(ref, 0o600) == 0, mkfifo(dist, 0o600) == 0 else { return MetricScores() }
        defer { unlink(ref); unlink(dist) }
        let dec = Process()
        dec.executableURL = ToolLocator.url(for: "ffmpeg")
        dec.arguments = ["-v", "error"] + ctx.decoderArgs + ["-r", "\(ctx.rate.0)/\(ctx.rate.1)", "-i", distorted.path, "-pix_fmt", "yuv420p10le",
                         "-strict", "-1", "-f", "yuv4mpegpipe", "-y", dist]
        dec.standardError = FileHandle.nullDevice
        let tool = Process()
        tool.executableURL = ToolLocator.url(for: "ssimulacra2_rs")
        tool.arguments = ["video", ref, dist, "--frame-threads", "\(max(1, ctx.threads / 2))"]
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        try dec.run(); try tool.run()
        try await Task.detached {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: ref))
            try reference(h); try h.close()
        }.value
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        await Task.detached { dec.waitUntilExit(); tool.waitUntilExit() }.value
        // Expected lines: "Frame 12: 87.12345" (VERIFY against your ssimulacra2_rs version).
        var values: [(Int, Double)] = []
        for line in text.split(separator: "\n") where line.hasPrefix("Frame") {
            let parts = line.split(separator: ":")
            if parts.count == 2, let n = Int(parts[0].split(separator: " ").last ?? ""),
               let v = Double(parts[1].trimmingCharacters(in: .whitespaces)) { values.append((n, v)) }
        }
        var s = MetricScores()
        if !values.isEmpty {
            s.perFrame[.ssimulacra2] = values
            s.pooled[.ssimulacra2] = MetricScores.pool(values.map(\.1), higherIsBetter: true)
        }
        return s
    }

    // MARK: ColorVideoVDP + PU21-PSNR via the bundled Python helper (runs in Model Lab's environment, on MPS if possible)

    private static func python(_ set: Set<QualityMetric>, reference: @escaping (FileHandle) throws -> Void,
                               distorted: URL, ctx: Context) async throws -> MetricScores {
        guard let script = Bundle.main.url(forResource: "lumora_metrics", withExtension: "py") else { return MetricScores() }
        let tag = UUID().uuidString.prefix(6)
        let ref = ctx.workDir.appendingPathComponent("pyref-\(tag).y4m").path, dist = ctx.workDir.appendingPathComponent("pydist-\(tag).y4m").path
        guard mkfifo(ref, 0o600) == 0, mkfifo(dist, 0o600) == 0 else { return MetricScores() }
        defer { unlink(ref); unlink(dist) }
        let dec = Process()
        dec.executableURL = ToolLocator.url(for: "ffmpeg")
        dec.arguments = ["-v", "error"] + ctx.decoderArgs + ["-r", "\(ctx.rate.0)/\(ctx.rate.1)", "-i", distorted.path, "-pix_fmt", "yuv420p10le",
                         "-strict", "-1", "-f", "yuv4mpegpipe", "-y", dist]
        dec.standardError = FileHandle.nullDevice
        let py = Process()
        py.executableURL = ModelLab.lab.appendingPathComponent("venv/bin/python")
        py.arguments = [script.path, "--ref", ref, "--dist", dist, "--hdr", ctx.hdr ? "1" : "0", "--total-frames", "\(ctx.frames)",
                        "--metrics", set.map(\.rawValue).joined(separator: ","), "--windows", ctx.fast ? "3" : "6"]
        py.environment = ["PYTORCH_ENABLE_MPS_FALLBACK": "1"]
        let out = Pipe()
        py.standardOutput = out
        py.standardError = FileHandle.nullDevice
        try dec.run(); try py.run()
        try await Task.detached {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: ref))
            try reference(h); try h.close()
        }.value
        let data = out.fileHandleForReading.readDataToEndOfFile()
        await Task.detached { dec.waitUntilExit(); py.waitUntilExit() }.value
        var s = MetricScores()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.warning(.quality, "Python metrics returned no result: \(String(decoding: data.prefix(300), as: UTF8.self))")
            return s
        }
        for m in set {
            if let d = obj[m.rawValue] as? [String: Any], let mean = d["mean"] as? Double {
                let worst = d["worst"] as? Double ?? mean
                s.pooled[m] = (mean, worst)
            }
        }
        return s
    }
}
