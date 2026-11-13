import Foundation

/// What one export used and where its time went, kept for review after the export: one line in the log (and so in
/// the packaged report), and a small JSON file for the "Last export" card. File names only, never paths.
struct RenderSummary: Codable, Sendable, Equatable {
    var name: String
    var outcome: String
    var date: Date
    var frames: Int
    var totalFrames: Int
    var seconds: Double
    var fps: Double
    var outputFPS: Double
    var bottleneck: String
    var bottleneckKind: String
    var verdictHeadline: String
    var score: Double?
    var encoders: [String]
    var lumoraCores: Double
    var encoderCores: Double
    var otherCores: Double
    var cores: Int
    var performanceBusy: Double
    var efficiencyBusy: Double
    var gpuDevice: Double?
    var gpuLumora: Double?
    var pressure: String
    var swapGrowthMB: Double
    var thermal: String
    var decodeMs: Double
    var upscaleMs: Double?
    var gradeGPUMs: Double
    var encoderStarved: Double?
    var pipeBlocked: Double?
    var engineBusy: Double?
    var pauses: Int
    var stalls: Int
    var uiP95Ms: Double?
    var uiBaselineP95Ms: Double?
    var uiMaxMs: Double?
    var monitorCostMs: Double
    var prepSeconds: Double? = nil          // grain / HDR light-level measurement before the first frame

    var realtime: Double { outputFPS > 0 ? fps / outputFPS : 0 }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? "\(t / 3600)h\(String(format: "%02d", t / 60 % 60))m" : "\(t / 60)m\(String(format: "%02d", t % 60))s"
    }

    private static func pct(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }

    /// e.g. "1,412 frames in 2m03s (11.5 fps, 0.48× realtime); bottleneck encoder CPU (SvtAv1EncApp ×2), saturated; score 91%; …"
    var line: String {
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        var parts: [String] = []
        parts.append("\(nf.string(from: NSNumber(value: frames)) ?? "\(frames)") frames in \(Self.duration(seconds)) (\(String(format: "%.1f", fps)) fps, \(String(format: "%.2f", realtime))× realtime)\(outcome == "finished" ? "" : ", \(outcome)")")
        if let p = prepSeconds { parts.append("measuring before the first frame \(Self.duration(p))") }
        parts.append("bottleneck \(bottleneck) (\(encoders.joined(separator: ", ")))")
        parts.append("score \(Self.pct(score))")
        parts.append(String(format: "CPU Lumora %.1f, encoders %.1f, other apps %.1f cores (P %@, E %@)", lumoraCores, encoderCores, otherCores,
                            Self.pct(performanceBusy), Self.pct(efficiencyBusy)))
        parts.append("GPU \(Self.pct(gpuDevice)) (Lumora \(Self.pct(gpuLumora)))")
        parts.append(String(format: "pressure %@, swap %+.0f MB, thermal %@", pressure, swapGrowthMB, thermal))
        var stages = String(format: "per frame decode %.1f ms", decodeMs)
        if let u = upscaleMs { stages += String(format: ", upscale %.1f ms", u) }
        stages += String(format: ", grade GPU %.1f ms", gradeGPUMs)
        parts.append(stages)
        if let s = encoderStarved, let b = pipeBlocked { parts.append("encoder starved \(Self.pct(s)), pipe blocked \(Self.pct(b))") }
        if let e = engineBusy { parts.append("media engine busy \(Self.pct(e)) (inferred)") }
        parts.append("pauses \(pauses), stalls \(stalls)")
        if let u = uiP95Ms { parts.append(String(format: "UI main-thread p95 %.0f ms", u) + (uiBaselineP95Ms.map { String(format: " (baseline %.0f ms)", $0) } ?? "")) }
        parts.append(String(format: "monitor cost %.0f ms", monitorCostMs))
        return parts.joined(separator: "; ")
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumora/RenderSummaries", isDirectory: true)
    }

    func save() {
        let dir = Self.folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let file = dir.appendingPathComponent("\(df.string(from: date))-\(UUID().uuidString.prefix(4)).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: file)
        // Keep the 50 most recent.
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(50) { try? FileManager.default.removeItem(at: old) }
    }

    static func latest() -> RenderSummary? {
        let all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return all.lazy.compactMap { try? dec.decode(RenderSummary.self, from: Data(contentsOf: $0)) }.first
    }
}
