import Foundation
import CryptoKit

/// The small pieces ExportEngine calls into; kept here so the engine's own changes stay one-liners.
enum RecoveryHooks {
    /// The segment planner's view of an export.
    static func planInput(_ job: ExportJob, plan: [PlannedFrame], width: Int, height: Int, workers: Int) -> CheckpointPlanner.Input {
        let cuts = job.analysis.cutFrames
        var cutStarts: [Int] = []
        var shotStart = [Int](repeating: 0, count: plan.count)
        var currentScene = -1
        var start = 0
        for (i, p) in plan.enumerated() {
            if i > 0 && p.kind == .original && cuts.contains(p.a) { cutStarts.append(i) }
            let scene = job.analysis.sceneIndex(for: p.a)
            if scene != currentScene { currentScene = scene; start = i }
            shotStart[i] = start
        }
        let measured = EncodeCalibration.load(job.codec, job.contentKind).flatMap { cal in
            job.encodeChoice.flatMap { cal.rungs[$0.rungID]?.fps1080 }
        }
        let fps = Double(job.descriptor.fpsNum) / Double(max(1, job.descriptor.fpsDen))
        let rate = InterpolationPlanner.plan(sourceFrames: 1, sourceRate: (job.descriptor.fpsNum, job.descriptor.fpsDen),
                                             settings: job.interpolation, analysis: nil).rate
        let outFps = Double(rate.num) / Double(max(1, rate.den))
        return CheckpointPlanner.Input(frames: plan.count, fps: outFps.isFinite && outFps > 0 ? outFps : fps, pixels: width * height,
                                       codec: job.codec, workers: workers, cutStarts: cutStarts,
                                       shotStart: { shotStart[safe: $0] ?? 0 }, measuredFps1080: measured)
    }

    /// How undecodable frames of a damaged source are rebuilt while exporting: "recreate" (default) makes runs of up to
    /// three of them again from the good frames on either side with Lumora's interpolation (the same engines and
    /// checks as interpolated-file repair; a plain blend when no model is installed); "repeat" keeps the previous good
    /// frame. Longer runs always keep the previous frame (a frozen picture), as nothing trustworthy can be made up.
    /// The setting, for new exports. A running export uses the method it began with (`exportDamagedFrameMethod`,
    /// kept in its journal), so a resumed file never mixes the two.
    static var damagedFrameMethodSetting: String { Prefs.store.string(forKey: "damagedFrameMethod") ?? "recreate" }
    @TaskLocal static var exportDamagedFrameMethod: String?
    static var damagedFrameMethod: String { exportDamagedFrameMethod ?? damagedFrameMethodSetting }
    static let maxRecreatedRun = 3

    /// The export's source with its damaged frames rebuilt (see `damagedFrameMethod`); unchanged when the source has
    /// no known missing frames or an interpolated-file repair already rebuilds frames.
    static func rebuildingDamagedFrames(_ source: FrameSource, _ job: ExportJob) -> FrameSource {
        guard job.externalRepair == nil, let damage = job.analysis.damage else { return source }
        let missing = damage.spans.filter { $0.kind == .missing && $0.start > 0 }
        guard !missing.isEmpty else { return source }
        let last = max(job.analysis.frameCount, job.descriptor.frameCount) - 1
        let recreate = damagedFrameMethod != "repeat"
        let short = recreate ? missing.filter { $0.count <= maxRecreatedRun && $0.start + $0.count <= last } : []
        let held = missing.filter { !short.contains($0) }
        var out = source
        if !held.isEmpty {
            out = HeldFrameSource(base: out, held: Set(held.flatMap { Array($0.range) }))
            let at = held.map { "\(FailureText.time(damage.seconds($0.start), precise: true)) (\($0.count))" }.joined(separator: ", ")
            RenderLog.current?.warn("Damaged frames shown as the previous good frame at \(at)", tag: "decode")
        }
        if !short.isEmpty {
            let fps = Double(job.descriptor.fpsNum) / Double(max(1, job.descriptor.fpsDen))
            let plan = ExternalRepairPlan(flagged: Set(short.flatMap { Array($0.range) }), originalFps: fps, interpolatedFps: fps,
                                          offsetSeconds: 0, damagedFrames: true)
            out = PatchedFrameSource(base: out, plan: plan, proxyUniforms: UniformBuilder.analysis(source: job.preset.color, gridW: 1, gridH: 1))
            let at = short.map { "\(FailureText.time(damage.seconds($0.start), precise: true)) (\($0.count))" }.joined(separator: ", ")
            RenderLog.current?.warn("Damaged frames re-created from the neighboring frames at \(at)", tag: "decode")
        }
        return out
    }

    /// What must not change for saved segments to be reused: the encoder binary and version, its argument template,
    /// threads per segment, and (for the hardware encoder) the chip and macOS build.
    static func fingerprint(_ job: ExportJob, threads: Int) -> ExportJournal.EncodeFingerprint {
        if job.codec.isHardware {
            return .init(binary: "VideoToolbox", version: CheckpointStore.osBuild, specHash: job.codec.rawValue, threads: threads,
                         chip: ChipProfile.current.description, osBuild: CheckpointStore.osBuild)
        }
        let spec = ExportEngine.encoder(for: job)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let hash = spec.flatMap { try? enc.encode($0) }.map(ToolVersions.sha) ?? ""
        return .init(binary: spec?.binary ?? "?", version: spec.map { ToolVersions.version($0.binary) } ?? "?",
                     specHash: hash, threads: threads, chip: ChipProfile.current.description, osBuild: CheckpointStore.osBuild)
    }

    /// The grain plan: measured once, saved, and reused on resume (the table moves with the checkpoint folder).
    static func grain(_ session: RenderSession, _ job: ExportJob,
                      measure: () async throws -> ExportEngine.GrainPlan) async throws -> ExportEngine.GrainPlan {
        if var g = session.savedGrain {
            if g.table != nil, let pre = session.prepassFolder {
                let t = pre.appendingPathComponent("grain.tbl")
                if FileManager.default.fileExists(atPath: t.path) {
                    g.table = t
                    g.tableFlag = ExportEngine.grainTableFlag(job, path: t.path)
                    RenderLog.current?.info("Reusing the saved grain plan", tag: "grain")
                    return g
                }
            } else if g.table == nil {
                return g
            }
        }
        let g = try await measure()
        session.saveGrain(g)
        if let t = g.table { CheckpointStore.fullSync(t) }
        return g
    }

    /// A hard link (same drive, no copy) of a checkpointed file inside the job folder, so tools that take names
    /// relative to it (MP4Box parses ':' and '#') keep working whatever the scratch path contains.
    static func link(_ url: URL, into dir: URL) throws -> URL {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.linkItem(at: url, to: dest) } catch { try FileManager.default.copyItem(at: url, to: dest) }
        return dest
    }

    static func settingsDropped(_ job: ExportJob) {
        let m = "The hardware encoder didn't accept the \(job.codec.displayName) compression or HDR settings; this segment is encoded with its defaults"
        Log.warning(.encode, m)
    }

    /// Encoder stderr into the export log: the last 12 lines after a good segment, 200 after a failure.
    static func encoderLog(_ binary: String, log: URL, tag: String, failed: Bool) {
        guard let r = RenderLog.current, let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty else { return }
        r.stderrTail(text, lines: failed ? 200 : 12, tag: tag)
    }
}

/// Low scratch space pauses an export (instead of failing it) until there is room again.
enum DiskSpaceGuard {
    static let reserve: Int64 = 2 << 30
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (Date, String?) = (.distantPast, nil)
    /// Tests set this to simulate a nearly full scratch drive.
    nonisolated(unsafe) static var freeOverride: (() -> Int64)?

    static func pauseReason() -> String? {
        guard !ActiveExports.all.isEmpty else { return nil }
        lock.lock()
        if Date().timeIntervalSince(cached.0) < 5 { let r = cached.1; lock.unlock(); return r }
        lock.unlock()
        var reason: String?
        let root = CheckpointStore.root.deletingLastPathComponent()
        let free = freeOverride?() ?? SystemSnapshot.volume(root)?.free
        if let free, free < reserve {
            let name = SystemSnapshot.volume(root)?.name ?? "scratch"
            reason = "Paused: “\(name)” is almost full (\(ByteCountFormatter.string(fromByteCount: max(0, free), countStyle: .file)) left). Free up space and Lumora continues."
        }
        lock.lock(); cached = (Date(), reason); lock.unlock()
        return reason
    }
}
