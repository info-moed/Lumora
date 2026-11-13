import Foundation
import AVFoundation
import VideoToolbox
import Metal

struct ExportJob {
    var descriptor: SourceDescriptor
    var preset: PresetCandidate
    var analysis: AnalysisResult
    var delivery: DeliveryFormat
    var peakNits: Float = 1000
    var codec: Codec
    var bitDepth: Int = 10
    var chroma: ChromaFormat = .c420
    var quality: Float = 0.8                   // 0...1, 1 = best
    var interpolation = InterpolationSettings()
    var sourcePeakNits: Float = 1000           // from the HDR Report Card, for Rip Revive
    var upscale: UpscaleMode = .off
    var qualityTarget: QualityTarget? = nil     // encode to a VMAF target instead of a fixed setting
    var encodeChoice: EncodeChoice? = nil       // preset + extras chosen by the time-budget planner
    var filmTexture: FilmTexture = .off         // AV1/AV2: add organic film grain at playback (no bitrate cost)
    var externalRepair: ExternalRepairPlan? = nil   // rebuild flagged frames of an already-interpolated file
    var frameRange: Range<Int>? = nil              // output only these planned frames (previews)
    var filmTextureStrength: Float = 1
    var contentKind: ContentKind = .realLife
    var outputURL: URL

    var target: OutputTarget {
        let kind = delivery.target.0
        return OutputTarget(kind: kind, peakNits: kind == .hdr10 ? peakNits : (kind == .hlg ? 1000 : 100))
    }
    var highPrecision: Bool { bitDepth >= 12 }
}

/// Renders a job: plan (with interpolation) -> measure light levels -> parallel segments on the
/// hardware engines or CPU encoders -> join with audio/subtitles -> inject HDR10+ / Dolby Vision metadata.
final class ExportEngine {
    let chip = ChipProfile.current
    private(set) var qcEvents: [QCEvent] = []

    private struct Context {
        var job: ExportJob
        var plan: [PlannedFrame]
        var rate: (num: Int, den: Int)
        var meta: HDRMetadata.Static?
        var levels: SceneAnalyzer.LightLevels?
        var width: Int
        var height: Int
        var kr: Float
        var kb: Float
        var grain = GrainPlan()
    }

    /// How grain is handled for this export (all modes keep scoring fair).
    struct GrainPlan {
        var cleanInput = false        // Lumora removes grain before the encoder (measured table re-adds it)
        var cleanReference = false    // metrics compare against the de-grained master
        var strip = false             // decode without synthetic grain when scoring
        var sigma: Float = 0.004
        var table: URL?
        var tableFlag: [String] = []  // encoder-specific way to pass the table
    }

    private final class SegmentProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        let total: Int
        let report: (String, Double) -> Void
        init(total: Int, report: @escaping (String, Double) -> Void) { self.total = total; self.report = report }
        func tick(_ label: String) {
            lock.lock(); done += 1; let d = done; lock.unlock()
            if d % 12 == 0 { report(label, Double(d) / Double(max(1, total))) }
        }
    }

    // MARK: - Validation

    static func validate(_ job: ExportJob) -> String? {
        if job.outputURL.standardizedFileURL.resolvingSymlinksInPath().path
            == job.descriptor.url.standardizedFileURL.resolvingSymlinksInPath().path {
            return "The export would overwrite the source file. Choose a different folder or name."
        }
        if !job.codec.bitDepths.contains(job.bitDepth) {
            return "\(job.codec.displayName) can't do \(job.bitDepth)-bit. Choose \(job.codec.bitDepths.map { "\($0)-bit" }.joined(separator: " or "))."
        }
        if !job.codec.chromaFormats.contains(job.chroma) {
            return "\(job.codec.displayName) supports \(job.codec.chromaFormats.map(\.label).joined(separator: ", ")) color only."
        }
        if !job.codec.supports(bitDepth: job.bitDepth, chroma: job.chroma) {
            return "\(job.codec.displayName) can't encode \(job.bitDepth)-bit \(job.chroma.label). Choose another bit depth or chroma format."
        }
        if !job.delivery.supported(by: job.codec) {
            let able = Codec.allCases.filter { job.delivery.supported(by: $0) }.map(\.displayName)
            return "\(job.delivery.displayName) isn't available with \(job.codec.displayName). Choose "
                + able.joined(separator: " or ") + "."
        }
        if !job.codec.available, let key = job.codec.cliKey {
            let binary = EncoderCatalog.shared.spec(for: key)?.binary ?? key
            return "\(job.codec.displayName) needs the \(binary) encoder, which isn't installed. See README → Encoders."
        }
        if case .slowMotion = job.interpolation.mode, job.codec == .av2 {
            return "Slow motion with AV2 isn't supported yet."
        }
        return nil
    }

    /// The output folder must exist and be writable, checked before any work so a read-only or vanished folder is
    /// reported up front, in plain words, instead of after the whole encode as a failed move of a temp file.
    static func checkOutputFolder(_ output: URL) throws {
        let folder = output.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw LumoraError.unsupported("The output folder “\(folder.lastPathComponent)” doesn't exist (was the drive disconnected?). Choose another folder.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw LumoraError.unsupported("Lumora can't write to the folder “\(folder.lastPathComponent)”: it is read-only or you don't have permission. Choose another folder.")
        }
    }

    /// An older file at the output path goes to the Trash (recoverable), never straight to deletion, and the
    /// source itself is never touched.
    static func clearOutput(_ job: ExportJob) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: job.outputURL.path) else { return }
        guard job.outputURL.standardizedFileURL.resolvingSymlinksInPath().path
                != job.descriptor.url.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw LumoraError.unsupported("The export would overwrite the source file. Choose a different folder or name.")
        }
        do { try fm.trashItem(at: job.outputURL, resultingItemURL: nil) } catch { try fm.removeItem(at: job.outputURL) }
    }

    // MARK: - Run

    private func baseContext(_ job: ExportJob) throws -> Context {
        let d = job.descriptor
        // Analysis decoded every frame once, so its count is the truth; the container's count is only a claim
        // (a truncated file, a header saying 100 hours, a duration-based estimate).
        let sourceFrames = job.analysis.frameCount > 0 ? job.analysis.frameCount : d.frameCount
        let (fullPlan, rate) = InterpolationPlanner.plan(sourceFrames: sourceFrames, sourceRate: (d.fpsNum, d.fpsDen),
                                                     settings: job.interpolation, analysis: job.analysis)
        let wide = job.target.outputGamut == .rec2020
        let probeStage = try PreGradeStage(sourceWidth: d.width, sourceHeight: d.height, crop: d.crop, mode: job.upscale)
        var plan = fullPlan
        if let r = job.frameRange { plan = Array(plan[max(0, r.lowerBound)..<min(plan.count, r.upperBound)]) }
        return Context(job: job, plan: plan, rate: rate, meta: nil, levels: nil,
                       width: probeStage.outputWidth, height: probeStage.outputHeight,
                       kr: wide ? 0.2627 : 0.2126, kb: wide ? 0.0593 : 0.0722)
    }

    /// Decides the grain strategy and, when needed, measures this film's grain and writes a grain table (AV1's
    /// "filmgrn1" for SVT-AV1 and libaom, AV2's "filmgrn2" for AVM: avmenc accepts a filmgrn1 file without an error
    /// but codes no grain from it).
    private func planGrain(_ ctx: Context, workDir: URL) async throws -> GrainPlan {
        let job = ctx.job
        var g = GrainPlan()
        let ids = Set(job.encodeChoice?.optionIDs ?? [])
        let av1 = job.codec == .av1 || job.codec == .av1Pro
        let tables = av1 || job.codec == .av2
        let measured = tables && ids.contains("grainTable")
        // Without a plan the content tune applies; the SVT-AV1 and libaom grain tunes synthesize grain like the grain extras do.
        let tuneGrain = av1 && job.encodeChoice == nil
            && EncodeRecipes.synthesizesGrain(encoderSpec(job)?.tunes?[ContentTuning.preset(job.contentKind).encoderTune] ?? [])
        // libaom's grain (--denoise-noise-level, on either AV1 ladder) counts too: before, only SVT-AV1's was recognized,
        // so libaom grain synthesis was scored with the synthetic grain applied, against the grainy master.
        let encoderGrain = ids.contains("grain") || ids.contains("aomgrain") || ids.contains("aomgrain10")
            || (av1 && EncodeRecipes.synthesizesGrain(job.encodeChoice?.extraArgs ?? [])) || tuneGrain
        let texture = tables && job.filmTexture != .off
        guard measured || encoderGrain || texture else { return g }
        g.strip = true
        g.cleanReference = measured || encoderGrain
        g.cleanInput = measured
        // Measure grain on three graded frames from different parts of the film.
        let processor = GrainProcessor()
        var stats: [GrainStats] = []
        for f in [0.25, 0.5, 0.75].map({ Int(Double(ctx.plan.count) * $0) }) {
            if let rgb = try await renderRGB(ctx, outputFrame: f) { stats.append(processor.measure(rgb)) }
        }
        let bins = (0..<Int(GRAIN_BINS)).map { i in stats.map { $0.sigmaPerBin[i] }.reduce(0, +) / Float(max(1, stats.count)) }
        let measuredStats = GrainStats(sigmaPerBin: bins, overall: stats.map(\.overall).reduce(0, +) / Float(max(1, stats.count)))
        g.sigma = max(0.002, measuredStats.overall)
        if measured || texture {
            let tableStats = texture ? job.filmTexture.stats(strength: job.filmTextureStrength) : measuredStats
            let url = workDir.appendingPathComponent("grain.tbl")
            try GrainTable.write(tableStats, bitDepth: job.bitDepth, format: job.codec == .av2 ? .av2 : .av1, to: url)
            g.table = url
            // SVT-AV1 spells it --fgs-table; libaom (also on the libaom rungs of the AV1 ladder) and AVM --film-grain-table.
            g.tableFlag = encoderSpec(job)?.binary == EncodeRecipes.svtBinary ? ["--fgs-table", url.path] : ["--film-grain-table=\(url.path)"]
        }
        Log.notice(.encode, "Grain: measured σ \(String(format: "%.4f", measuredStats.overall)); \(measured ? "Lumora removes grain and supplies a measured table" : encoderGrain ? "encoder grain synthesis" : "")\(texture ? "; film texture \(job.filmTexture.rawValue)" : ""). Scoring strips synthetic grain.")
        return g
    }

    /// One graded output frame as an RGB texture (for measurements).
    private func renderRGB(_ ctx: Context, outputFrame: Int) async throws -> MTLTexture? {
        let metal = MetalContext.shared
        let r = max(0, min(ctx.plan.count - 1, outputFrame))
        let (prepared, producer) = try await startProducer(ctx, range: r..<(r + 1), depth: 1)
        defer { producer.cancel() }
        guard let f = try await prepared.receive() else { return nil }
        let rgb = metal.makeTexture(width: ctx.width, height: ctx.height, format: .rgba16Float)
        let cb = metal.queue.makeCommandBuffer()!
        GradeRenderer().encodeGrade(cb, source: f.texture, destination: rgb,
                                    uniforms: uniforms(ctx, sourceIndex: f.sourceIndex, outputIndex: f.outputIndex, crop: f.crop))
        await cb.commitAndWait()
        return rgb
    }

    // MARK: - Targeted repair of a finished export

    /// Re-renders only the chunks that contain flagged frames (stricter interpolation: exhaustive, double generation,
    /// higher strictness), re-encodes them to the same standard, and splices them into the finished file.
    func repair(_ job: ExportJob, manifest: ExportManifest, flaggedFrames: Set<Int>,
                status: @escaping (String, Double) -> Void) async throws -> URL {
        guard manifest.delivery != .dolbyVision81 && manifest.delivery != .hdr10Plus else {
            throw LumoraError.unsupported("Repair can't splice files with per-frame Dolby Vision / HDR10+ metadata yet. Re-export instead.")
        }
        var strict = job
        strict.interpolation.intelligence = .exhaustive
        strict.interpolation.artifactRepair = true
        strict.interpolation.sensitivity = min(1, job.interpolation.sensitivity + 0.25)
        var ctx = try baseContext(strict)
        let tmp = try ScratchManager.jobDirectory("repair")
        defer { try? FileManager.default.removeItem(at: tmp) }
        ctx.grain = try await planGrain(ctx, workDir: tmp)
        let affected = manifest.chunks.enumerated().filter { _, c in flaggedFrames.contains { $0 >= c.start && $0 < c.start + c.count } }
        guard !affected.isEmpty else { throw LumoraError.unsupported("None of the flagged frames fall inside this export's chunks.") }
        Log.notice(.encode, "Repair: \(flaggedFrames.count) flagged frames in \(affected.count) of \(manifest.chunks.count) chunks")
        let threads = chip.cpuCores
        let encodeOne = chunkEncoder(ctx, tmp: tmp, threads: threads)
        var replacements: [Int: [URL]] = [:]
        for (n, (idx, chunk)) in affected.enumerated() {
            try Task.checkCancellation()
            status("Repairing chunk \(n + 1) of \(affected.count)", Double(n) / Double(affected.count))
            let frames = try await renderPlanar(ctx, range: chunk.start..<(chunk.start + chunk.count))
            if var target = strict.qualityTarget {
                target.fixDips = true
                let pieces = try await TargetQualityEncoder(engine: self).encode(
                    frames: frames, chunkID: -100 - idx, start: chunk.start,
                    sceneStats: job.analysis.scenes[safe: job.analysis.sceneIndex(for: ctx.plan[chunk.start].a)] ?? job.analysis.scenes[0],
                    interpolatedShare: 0.5, kind: job.contentKind, encodeOne: encodeOne, target: target, rate: ctx.rate,
                    workDir: tmp, threads: threads, codec: job.codec, hdr: job.target.isHDR, hlg: job.target.kind == .hlg, stripSyntheticGrain: ctx.grain.strip)
                replacements[idx] = pieces.map(\.url)
            } else {
                let ext = job.codec == .hevc ? "mov" : (EncoderCatalog.shared.spec(for: job.codec.cliKey ?? "")?.ext ?? "bin")
                let url = tmp.appendingPathComponent("fix\(idx).\(ext)")
                try await encodeOne(frames, chunk.level, url)
                replacements[idx] = [url]
            }
        }
        status("Splicing", 0.95)
        // Split the finished video at chunk boundaries (every chunk starts on a keyframe), swap in the repaired ones.
        let original = URL(fileURLWithPath: manifest.output)
        let segDir = tmp.appendingPathComponent("segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segDir, withIntermediateDirectories: true)
        let cuts = manifest.chunks.dropFirst().map { "\($0.start)" }.joined(separator: ",")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", original.path, "-map", "0:v:0", "-c", "copy", "-f", "segment",
                                       "-segment_frames", cuts, "-reset_timestamps", "1", "-segment_format", "matroska",
                                       segDir.appendingPathComponent("seg%05d.mkv").path])
        var list: [String] = []
        for i in manifest.chunks.indices {
            if let urls = replacements[i] {
                for (k, u) in urls.enumerated() {
                    let mkv = tmp.appendingPathComponent("rep\(i)-\(k).mkv")
                    let raw = ["hevc", "266"].contains(u.pathExtension)
                    let input = raw ? try Self.wrapRawVideo(u, rate: (manifest.rateNum, manifest.rateDen), in: tmp) : u
                    try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", input.path, "-c", "copy", mkv.path])
                    list.append(FFConcat.line(mkv))
                }
            } else {
                list.append(FFConcat.line(segDir.appendingPathComponent(String(format: "seg%05d.mkv", i))))
            }
        }
        let listURL = tmp.appendingPathComponent("list.txt")
        try list.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)
        let repaired = tmp.appendingPathComponent("repaired." + original.pathExtension)
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listURL.path, "-i", original.path,
                                       "-map", "0:v:0", "-map", "1", "-map", "-1:v", "-c", "copy"]
                            + Packager.quickTimeVideoArgs(video: original, outputExtension: repaired.pathExtension) + [repaired.path])
        let backup = original.deletingPathExtension().appendingPathExtension("before-repair." + original.pathExtension)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: original, to: backup)
        try FileManager.default.moveItem(at: repaired, to: original)
        Log.notice(.encode, "Repair finished; the previous version is kept as \(backup.lastPathComponent)")
        status("Repaired", 1)
        return original
    }

    /// Output size and frame count of a job (after crop, upscaling and interpolation), for the planner.
    func outputShape(_ job: ExportJob) throws -> (width: Int, height: Int, frames: Int) {
        let c = try baseContext(job)
        return (c.width, c.height, c.plan.count)
    }

    /// "Measure on this Mac": renders two short, contrasting samples of this very file, encodes them at four
    /// presets and two quality levels, scores them with VMAF, and stores real speed and size-at-target.
    func calibrate(_ job: ExportJob, target: Double, progress: ProgressReporter) async throws -> EncodeCalibration {
        guard let key = job.codec.cliKey, let spec = EncoderCatalog.shared.spec(for: key) else {
            throw LumoraError.unsupported("Nothing to measure for the hardware encoder; it runs at media-engine speed.")
        }
        var ctx = try baseContext(job)
        ctx.job.qualityTarget = nil
        let tmp = try ScratchManager.jobDirectory("calibrate")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Two contrasting scenes: brightest highlights and darkest overall.
        let scenes = job.analysis.scenes.filter { $0.end - $0.start >= 30 }
        let picks = [scenes.max { $0.p995 < $1.p995 }, scenes.min { $0.keyStops < $1.keyStops }].compactMap { $0 }
        var frames: [PlanarFrame] = []
        for s in picks.isEmpty ? Array(job.analysis.scenes.prefix(1)) : picks {
            guard let start = ctx.plan.firstIndex(where: { $0.a >= s.start }) else { continue }
            let r = start..<min(ctx.plan.count, start + 24)
            frames += try await renderPlanar(ctx, range: r)
        }
        guard !frames.isEmpty else { throw LumoraError.unsupported("No frames to measure.") }
        progress.update(0.15, detail: "Rendered \(frames.count) sample frames")
        let recipe = EncodeRecipes.recipe(codec: job.codec, kind: job.contentKind)
        let primary = recipe.rungs.indices.filter { recipe.rungs[$0].encoderKey == nil }
        var chosen = Array(Set([primary.first! + 1, primary.count / 2 - 1, primary.count / 2 + 1, primary.last! - 2]
            .map { max(primary.first!, min(primary.last!, $0)) })).sorted()
        // One libaom rung is enough to anchor the rest of its ladder.
        if let aom = recipe.rungs.indices.first(where: { recipe.rungs[$0].encoderKey == "aomenc" }),
           EncodeRecipes.available(recipe.rungs[aom], codec: job.codec) { chosen.append(aom) }
        let range = TargetQualityEncoder.levelRange(job.codec)
        let base = range.start
        let threads = chip.cpuCores
        let pixelNorm = Double(ctx.width * ctx.height) / Double(1920 * 1080)
        var measured: [String: EncodeCalibration.Rung] = [:]
        var firstSize: Double?
        var vmafRates: [Double] = []
        for (n, i) in chosen.enumerated() {
            let rung = recipe.rungs[i]
            let rungSpec = rung.encoderKey.flatMap { EncoderCatalog.shared.spec(for: $0) } ?? spec
            var points: [(score: Double, size: Double)] = []
            var seconds = 0.0
            for (k, level) in [base, base - 6 * range.step].enumerated() {
                try Task.checkCancellation()
                let ext = rungSpec.ext
                let url = tmp.appendingPathComponent("r\(rung.id)-\(k).\(ext)")
                let t0 = Date()
                let (process, handle, log) = try await startCLIEncoder(ctx, spec: rungSpec, out: url, tmp: tmp, tag: "cal\(rung.id)\(k)",
                                                                       threads: threads, quality: String(Int(-level)),
                                                                       preset: rung.presetValue, extra: [])
                guard let first = frames.first else { throw LumoraError.decodeFailed("No frames rendered for calibration.") }
                try handle.write(contentsOf: Data(first.y4mHeader(fpsNum: ctx.rate.num, fpsDen: ctx.rate.den).utf8))
                for f in frames { try f.write(to: handle) }
                try handle.close()
                await process.exited()
                guard process.terminationStatus == 0 else {
                    throw LumoraError.toolFailed(rungSpec.binary, String((try? String(contentsOf: log, encoding: .utf8))?.suffix(800) ?? ""))
                }
                seconds += Date().timeIntervalSince(t0)
                let size = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
                var score = 0.0
                if VMAFRunner.available {
                    let v0 = Date()
                    let w = ctx.width, h = ctx.height, rate = ctx.rate
                    let r = try await VMAFRunner.score(writeReference: { hdl in
                        try hdl.write(contentsOf: Data(PlanarFrame.y4mHeader420p10(width: w, height: h, fps: rate).utf8))
                        for f in frames { try f.writeY4M420p10(to: hdl) }
                    }, distorted: url, frameRate: rate,
                       options: VMAFRunner.Options(model: "vmaf_v0.6.1", subsample: 2, threads: threads, downscaleHeight: h > 1600 ? 1080 : nil),
                       workDir: tmp)
                    score = r.mean
                    vmafRates.append(Double(frames.count) / max(0.01, Date().timeIntervalSince(v0)) * min(1, pixelNorm))
                }
                points.append((score, size))
                progress.update(0.15 + 0.85 * Double(n * 2 + k + 1) / Double(chosen.count * 2),
                                detail: "\(rung.label): \(String(format: "%.1f", Double(frames.count) / max(0.01, Date().timeIntervalSince(t0)))) fps")
            }
            // Size at the target VMAF (log-linear between the two points); without VMAF, size at equal CRF.
            var sizeAtTarget = points[0].size
            // Extrapolate at most one bracket beyond the measured pair: on easy footage both scores sit near 100 and an
            // unbounded line through two almost-equal scores lands at absurd sizes (e.g. "99% smaller").
            if points[0].score > points[1].score + 0.05, VMAFRunner.available {
                let (a, b) = (points[0], points[1])
                let t = min(2, max(-1, (target - a.score) / (b.score - a.score)))
                sizeAtTarget = exp(log(a.size) + t * (log(b.size) - log(a.size)))
            }
            if firstSize == nil { firstSize = sizeAtTarget / max(0.01, 1 - recipe.rungs[i].seedSaving) }
            let saving = max(0, 1 - sizeAtTarget / firstSize!)
            measured[rung.id] = EncodeCalibration.Rung(fps1080: Double(frames.count * 2) / max(0.01, seconds) * pixelNorm, saving: saving)
            Log.notice(.encode, "Measured \(rung.label): \(String(format: "%.1f", measured[rung.id]!.fps1080)) fps @1080p-equivalent, \(Int(saving * 100))% smaller than the fastest preset")
        }
        let cal = EncodeCalibration(rungs: measured, vmafFps1080: vmafRates.isEmpty ? nil : vmafRates.reduce(0, +) / Double(vmafRates.count), date: Date())
        cal.save(job.codec, job.contentKind)
        return cal
    }

    /// Renders a range of output frames once into planar 10/12-bit frames in RAM.
    private func renderPlanar(_ ctx: Context, range: Range<Int>) async throws -> [PlanarFrame] {
        let metal = MetalContext.shared
        let (prepared, producer) = try await startProducer(ctx, range: range, depth: MacProfile.current?.pipelineDepth ?? 4)
        let renderer = GradeRenderer()
        let rgb = metal.makeTexture(width: ctx.width, height: ctx.height, format: ctx.job.highPrecision ? .rgba32Float : .rgba16Float)
        var out: [PlanarFrame] = []
        while let f = try await prepared.receive() {
            let planes = PlanarFrame(device: metal.device, width: ctx.width, height: ctx.height, bits: ctx.job.bitDepth, chroma: ctx.job.chroma)
            let cb = metal.queue.makeCommandBuffer()!
            renderer.encodeGrade(cb, source: f.texture, destination: rgb,
                                 uniforms: uniforms(ctx, sourceIndex: f.sourceIndex, outputIndex: f.outputIndex, crop: f.crop))
            renderer.encodePackPlanar(cb, rgb: rgb, planes: planes, matrixKr: ctx.kr, matrixKb: ctx.kb)
            await cb.commitAndWait()
            out.append(planes)
        }
        _ = try await producer.value
        return out
    }

    func run(_ job: ExportJob, status: @escaping (String, Double) -> Void) async throws -> URL {
        if let problem = Self.validate(job) { throw LumoraError.unsupported(problem) }
        try Self.checkOutputFolder(job.outputURL)
        var ctx = try baseContext(job)
        let d = job.descriptor
        let plan = ctx.plan
        if let c = job.encodeChoice { Log.notice(.encode, "Encoder settings: \(c.rungLabel) + \(c.optionIDs.joined(separator: ", ")) → \(c.extraArgs.joined(separator: " "))") }
        let grainTmp = try ScratchManager.jobDirectory("grain")
        defer { try? FileManager.default.removeItem(at: grainTmp) }
        ctx.grain = try await planGrain(ctx, workDir: grainTmp)

        if job.target.isHDR {
            status("Measuring HDR light levels", 0)
            let levels = try await SceneAnalyzer.measureLightLevels(d, color: job.preset.color, preset: job.preset,
                                                                    analysis: job.analysis, target: job.target,
                                                                    sourcePeakNits: job.sourcePeakNits) { status("Measuring HDR light levels", $0) }
            ctx.levels = levels
            ctx.meta = HDRMetadata.Static(peakNits: job.target.effectivePeak, maxCLL: levels.maxCLL, maxFALL: levels.maxFALL)
        }

        let tmp = try ScratchManager.jobDirectory("export")   // all temp writes on the fast scratch SSD
        Log.info(.encode, "Export \(job.outputURL.lastPathComponent): \(job.codec.displayName), \(job.bitDepth)-bit \(job.chroma.label), \(job.delivery.displayName), scratch \(tmp.path)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        if let t = job.qualityTarget, ![.prores422HQ, .prores4444XQ, .av2].contains(job.codec) {
            Log.notice(.encode, "Encoding to VMAF \(t.vmaf) (\(t.pool.rawValue)) for \(job.contentKind.displayName)")
            let pieces = try await runTargetQuality(ctx, tmp: tmp, status: status)
            status("Finishing file", 1)
            var result = try addContainerHDR10Metadata(ctx, file: try await join(ctx, segments: pieces, tmp: tmp), tmp: tmp)
            if Self.needsMetadataPass(job.delivery) { result = try injectDynamicMetadata(ctx, file: result, tmp: tmp) }
            try Task.checkCancellation()          // never move a canceled export into place
            try Self.clearOutput(job)
            try FileManager.default.moveItem(at: result, to: job.outputURL)
            ExportManifest(output: job.outputURL.path, source: job.descriptor.url.path, codec: job.codec, rateNum: ctx.rate.num,
                           rateDen: ctx.rate.den, frames: ctx.plan.count, delivery: job.delivery,
                           chunks: lastPieces.map { .init(start: $0.start, count: $0.count, level: $0.level) }, created: Date()).save()
            return job.outputURL
        }
        let ranges = segmentRanges(ctx, count: chip.segments(for: job.codec, frameCount: plan.count))
        let progress = SegmentProgress(total: plan.count) { status($0, $1) }
        let label = "Encoding \(job.codec.displayName) · \(ranges.count) parallel segment\(ranges.count == 1 ? "" : "s")"
        let threads = chip.threadsPerSegment(segments: ranges.count)
        let frozen = ctx   // immutable copy for the concurrent segment tasks

        let segmentFiles: [URL] = try await withThrowingTaskGroup(of: (Int, URL, [QCEvent]).self) { group in
            for (n, range) in ranges.enumerated() {
                group.addTask {
                    if job.codec.isHardware {
                        let url = tmp.appendingPathComponent("seg\(n).mov")
                        let ev = try await self.encodeVideoToolbox(frozen, range: range, to: url) { progress.tick(label) }
                        return (n, url, ev)
                    } else {
                        let ext = self.encoderSpec(job)!.ext
                        let url = tmp.appendingPathComponent("seg\(n).\(ext)")
                        let ev = try await self.encodeCLI(frozen, range: range, to: url, tmp: tmp, index: n,
                                                          threads: threads) { progress.tick(label) }
                        return (n, url, ev)
                    }
                }
            }
            var out: [(Int, URL)] = []
            for try await (n, url, events) in group {
                out.append((n, url))
                qcEvents += events
            }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }

        try Task.checkCancellation()
        status("Finishing file", 1)
        var result = try addContainerHDR10Metadata(ctx, file: try await join(ctx, segments: segmentFiles, tmp: tmp), tmp: tmp)
        if Self.needsMetadataPass(job.delivery) {
            status("Adding \(job.delivery.displayName) metadata", 1)
            result = try injectDynamicMetadata(ctx, file: result, tmp: tmp)
        }
        try Task.checkCancellation()              // never move a canceled export into place
        try Self.clearOutput(job)
        try FileManager.default.moveItem(at: result, to: job.outputURL)
        return job.outputURL
    }

    /// Deliveries whose metadata lives in the HEVC bitstream and the container's Dolby Vision record: they get a
    /// final Annex-B pass (inject or keep the RPUs / HDR10+ SEI) and a remux that signals them.
    static func needsMetadataPass(_ d: DeliveryFormat) -> Bool { [.dolbyVision81, .dolbyVision84, .hdr10Plus].contains(d) }

    /// Splits the output into roughly equal parts, snapped to scene cuts so every segment starts on a
    /// fresh shot (clean keyframes, no visible seams).
    private func segmentRanges(_ ctx: Context, count: Int) -> [Range<Int>] {
        let n = ctx.plan.count
        guard count > 1, n > count * 48 else { return [0..<n] }
        let cuts = ctx.job.analysis.cutFrames
        var bounds = [0]
        for k in 1..<count {
            let ideal = n * k / count
            let window = max(24, n / (count * 10))
            let snapped = (max(1, ideal - window)..<min(n - 1, ideal + window))
                .filter { ctx.plan[$0].kind == .original && cuts.contains(ctx.plan[$0].a) }
                .min { abs($0 - ideal) < abs($1 - ideal) } ?? ideal
            if snapped > bounds.last! + 24 { bounds.append(snapped) }
        }
        bounds.append(n)
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }
    }

    private func uniforms(_ ctx: Context, sourceIndex: Int, outputIndex: Int, crop: SIMD4<Float>) -> GradeUniforms {
        let scene = ctx.job.analysis.sceneIndex(for: sourceIndex)
        return UniformBuilder.make(source: ctx.job.preset.color, params: ctx.job.preset.params, target: ctx.job.target,
                                   sceneExposureStops: ctx.job.preset.sceneExposures[safe: scene] ?? 0,
                                   viewport: SIMD4<Float>(0, 0, Float(ctx.width), Float(ctx.height)),
                                   sourcePeakNits: ctx.job.sourcePeakNits, crop: crop,
                                   ditherBits: ctx.job.bitDepth, frameSeed: outputIndex)
    }

    /// A frame that has been decoded, interpolated and upscaled, ready for grading.
    private struct Prepared {
        var texture: MTLTexture
        var crop: SIMD4<Float>
        var outputIndex: Int
        var sourceIndex: Int
        var keep: [AnyObject]
    }

    /// Stage 1 (own task): decode + interpolation (Neural Engine / GPU Neural Accelerators) + upscaling.
    /// Runs ahead of grading and encoding by up to `depth` frames.
    private func startProducer(_ ctx: Context, range: Range<Int>, depth: Int) async throws
        -> (BoundedChannel<Prepared>, Task<[QCEvent], Error>) {
        let job = ctx.job
        var source = try await job.descriptor.makeFrameSource(highPrecision: job.highPrecision)
        if let repairPlan = job.externalRepair {
            source = PatchedFrameSource(base: source, plan: repairPlan,
                                        proxyUniforms: UniformBuilder.analysis(source: job.preset.color, gridW: 1, gridH: 1))
        }
        let analysis = job.analysis
        let stream = try FrameStream(source: source, plan: ctx.plan[range], settings: job.interpolation,
                                     proxyUniforms: UniformBuilder.analysis(source: job.preset.color, gridW: 1, gridH: 1),
                                     sceneOf: { analysis.sceneIndex(for: $0) })
        let stage = try PreGradeStage(sourceWidth: job.descriptor.width, sourceHeight: job.descriptor.height,
                                      crop: job.descriptor.crop, mode: job.upscale)
        let channel = BoundedChannel<Prepared>(capacity: depth)
        let task = Task<[QCEvent], Error> {
            do {
                while let f = try stream.next() {
                    try Task.checkCancellation()
                    await PauseGate.shared.wait()            // pause / battery / heat / schedule, without losing work
                    let (tex, crop) = try stage.process(f.texture)
                    await channel.send(Prepared(texture: tex, crop: crop, outputIndex: f.outputIndex,
                                                sourceIndex: f.sourceIndex, keep: f.backing + [f.texture]))
                }
                await channel.finish()
            } catch {
                stream.cancel()
                await channel.fail(error)
                throw error
            }
            return stream.events
        }
        return (channel, task)
    }

    // MARK: - Hardware: VideoToolbox (HEVC Main10, ProRes 422 HQ, ProRes 4444 XQ 12-bit)

    private func videoSettings(_ ctx: Context, includeCompression: Bool) -> [String: Any] {
        let job = ctx.job
        let color: [String: Any]
        switch job.target.kind {
        case .hdr10: color = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                              AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                              AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .hlg:   color = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                              AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                              AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .sdr:   color = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                              AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                              AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let codecType: AVVideoCodecType
        switch job.codec {
        case .prores422HQ: codecType = .proRes422HQ
        case .prores4444XQ: codecType = AVVideoCodecType(rawValue: "ap4x")
        default: codecType = .hevc
        }
        var settings: [String: Any] = [AVVideoCodecKey: codecType, AVVideoWidthKey: ctx.width,
                                       AVVideoHeightKey: ctx.height, AVVideoColorPropertiesKey: color]
        guard includeCompression else { return settings }
        var comp: [String: Any] = [:]
        if job.codec == .hevc {
            comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            comp[kVTCompressionPropertyKey_Quality as String] = job.quality
            comp[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false
            if job.delivery == .dolbyVision84 {
                // Apple's encoder generates Dolby Vision 8.4 metadata for HLG content, as on iPhone.
                comp[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
            }
        }
        if let m = ctx.meta, job.target.kind == .hdr10 {
            comp[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = HDRMetadata.vtMasteringDisplay(m)
            comp[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = HDRMetadata.vtContentLightLevel(m)
        }
        if !comp.isEmpty { settings[AVVideoCompressionPropertiesKey] = comp }
        return settings
    }

    /// Three concurrent stages: producer (decode/interpolate/upscale) -> grader (GPU, never blocks a thread)
    /// -> writer (media engine). Each hands frames to the next through a bounded channel.
    private func encodeVideoToolbox(_ ctx: Context, range: Range<Int>, to url: URL,
                                    tick: @escaping () -> Void) async throws -> [QCEvent] {
        let job = ctx.job
        let metal = MetalContext.shared
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings = videoSettings(ctx, includeCompression: true)
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = videoSettings(ctx, includeCompression: false)   // never crash on an unsupported key
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Frame times are i * den / num; the track must count in 1/num s or 23.976/59.94 fps get rounded to 1/600 s.
        input.mediaTimeScale = CMTimeScale(ctx.rate.num)
        let pixelFormat: OSType
        switch job.codec {
        case .prores422HQ: pixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .prores4444XQ: pixelFormat = kCVPixelFormatType_4444AYpCbCr16
        default: pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: ctx.width,
            kCVPixelBufferHeightKey as String: ctx.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        writer.add(input)
        guard writer.startWriting() else { throw LumoraError.unsupported(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let (prepared, producer) = try await startProducer(ctx, range: range, depth: MacProfile.current?.pipelineDepth ?? 4)
        let encoded = BoundedChannel<(CVPixelBuffer, CMTime)>(capacity: 3)
        let renderer = GradeRenderer()
        let rgbFormat: MTLPixelFormat = job.highPrecision ? .rgba32Float : .rgba16Float
        let rgb = metal.makeTexture(width: ctx.width, height: ctx.height, format: rgbFormat)

        let grader = Task {
            do {
                var i = 0
                while let f = try await prepared.receive() {
                    guard let pool = adaptor.pixelBufferPool else { throw LumoraError.unsupported("No pixel buffer pool") }
                    var out: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                    guard let pb = out else { throw LumoraError.unsupported("Out of pixel buffers") }
                    let cb = metal.queue.makeCommandBuffer()!
                    renderer.encodeGrade(cb, source: f.texture, destination: rgb,
                                         uniforms: uniforms(ctx, sourceIndex: f.sourceIndex, outputIndex: f.outputIndex, crop: f.crop),
                                         temporalKey: job.analysis.sceneIndex(for: f.sourceIndex))
                    let keep = job.codec == .prores4444XQ
                        ? renderer.encodePackY416(cb, rgb: rgb, into: pb, matrixKr: ctx.kr, matrixKb: ctx.kb)
                        : renderer.encodePack(cb, rgb: rgb, into: pb, matrixKr: ctx.kr, matrixKb: ctx.kb)
                    await cb.commitAndWait()                 // suspends; no thread is blocked
                    _ = (keep, f.keep)
                    await encoded.send((pb, CMTime(value: CMTimeValue(i) * CMTimeValue(ctx.rate.den),
                                                   timescale: CMTimeScale(ctx.rate.num))))
                    i += 1
                }
                await encoded.finish()
            } catch {
                await encoded.fail(error)
            }
        }

        do {
            while let item = try await encoded.receive() {
                try Task.checkCancellation()
                let (pb, time) = item
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                guard adaptor.append(pb, withPresentationTime: time) else {
                    throw LumoraError.unsupported(writer.error?.localizedDescription ?? "append failed")
                }
                tick()
            }
        } catch {
            // The producer and grader are separate tasks blocked on their channels: fail the channels so they wake,
            // see the cancellation and stop (closing the decoder), instead of waiting forever for a reader.
            producer.cancel(); grader.cancel()
            await prepared.fail(error); await encoded.fail(error)     // release stages waiting to send
            _ = await grader.value
            _ = await producer.result
            writer.cancelWriting()
            throw error
        }
        _ = await grader.value
        let events = try await producer.value
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw LumoraError.unsupported(writer.error?.localizedDescription ?? "write failed") }
        return events
    }

    // MARK: - Software encoders (SVT-AV1, libaom, VVenC, AVM, x265)

    /// The encoder for this job: the planner's choice (e.g. libaom on the AV1 ladder) or the codec's default.
    private func encoderSpec(_ job: ExportJob) -> EncoderSpec? {
        (job.encodeChoice?.encoderKey ?? job.codec.cliKey).flatMap { EncoderCatalog.shared.spec(for: $0) }
    }

    /// Builds and starts an encoder process; returns it with the handle to write Y4M into.
    private func startCLIEncoder(_ ctx: Context, spec: EncoderSpec, out: URL, tmp: URL, tag: String, threads: Int,
                                 quality: String, preset: String? = nil, extra: [String]? = nil) async throws -> (Process, FileHandle, URL) {
        let job = ctx.job
        guard let exe = ToolLocator.url(for: spec.binary) else { throw LumoraError.missingTool(spec.binary) }
        let kindKey = job.target.kind == .hdr10 ? "pq" : (job.target.kind == .hlg ? "hlg" : "sdr")
        let names = spec.colorNames[kindKey] ?? [:]
        let nums: (String, String, String) = kindKey == "pq" ? ("9", "16", "9") : (kindKey == "hlg" ? ("9", "18", "9") : ("1", "1", "1"))
        let meta = ctx.meta ?? HDRMetadata.Static(peakNits: job.target.effectivePeak, maxCLL: 0, maxFALL: 0)
        let inArg = spec.inputArg.replacingOccurrences(of: "{fifo}", with: tmp.appendingPathComponent("in-\(tag)").path)
        let profile = job.chroma == .c420 ? "" : (job.chroma == .c422 ? "422-" : "444-")
        let values: [String: String] = [
            "in": inArg, "out": out.path, "w": "\(ctx.width)", "h": "\(ctx.height)",
            "fps_num": "\(ctx.rate.num)", "fps_den": "\(ctx.rate.den)", "bits": "\(job.bitDepth)",
            "preset": preset ?? job.encodeChoice.flatMap { $0.presetValue.isEmpty ? nil : $0.presetValue } ?? spec.preset,
            "quality": quality, "threads": "\(threads)",
            "cp": nums.0, "tc": nums.1, "mc": nums.2,
            "cp_name": names["cp"] ?? "", "tc_name": names["tc"] ?? "", "mc_name": names["mc"] ?? "",
            "vvenc_hdr": names["vvenc_hdr"] ?? "off", "vvenc_sdr": names["vvenc_sdr"] ?? "off",
            "vvenc_qpa": EncodeRecipes.vvencQPA(kind: job.contentKind, pq: kindKey == "pq") ? "1" : "0",
            // VVenC takes HDR10 static metadata (SEI) only through --additional.
            "vvenc_additional": kindKey == "pq"
                ? "MasteringDisplayColourVolume=\(HDRMetadata.vvencMastering(meta)) MaxContentLightLevel=\(max(1, Int(meta.maxCLL))),\(max(1, Int(meta.maxFALL)))"
                : (names["vvenc_additional"] ?? ""),
            "maxcll": "\(Int(meta.maxCLL))", "maxfall": "\(Int(meta.maxFALL))",
            "svt_mastering": HDRMetadata.svtMastering(meta), "x265_mastering": HDRMetadata.x265Mastering(meta),
            "aom_profile": EncodeRecipes.aomProfile(bitDepth: job.bitDepth, chroma: job.chroma),
            "x265_profile": "main\(profile)\(job.bitDepth)",
            "grain_table": ctx.grain.table?.path ?? "",
            "svt_grain": "\(EncodeRecipes.svtGrainLevel(job.contentKind))"
        ]
        // The planner's extras replace the simpler per-content tune when present.
        var planned = extra ?? job.encodeChoice?.extraArgs
        if ctx.grain.table != nil, var p = planned {
            // A grain table replaces the encoder's own grain estimate.
            var cleaned: [String] = []
            var skip = false
            for a in p {
                if skip { skip = false; continue }
                if a == "--film-grain" || a == "--film-grain-denoise" || a == "--fgs-table" { skip = true; continue }
                if a.hasPrefix("--film-grain-table=") { continue }
                cleaned.append(a)
            }
            p = cleaned + ctx.grain.tableFlag
            planned = p
        } else if ctx.grain.table != nil {
            planned = ctx.grain.tableFlag
        }
        if spec.binary == EncodeRecipes.svtBinary, let p = planned { planned = EncodeRecipes.svtArgs(p, pq: kindKey == "pq") }
        let tune = planned == nil ? ContentTuning.preset(job.contentKind).encoderTune : "default"
        let process = Process()
        process.executableURL = exe
        var arguments = spec.render(values, hdr: job.target.kind == .hdr10, tune: tune) + (planned ?? [])
        if spec.binary == EncodeRecipes.x265Binary {
            arguments = EncodeRecipes.x265Args(arguments, bits: job.bitDepth, chroma: job.chroma, preset: values["preset"] ?? spec.preset,
                                               kind: job.contentKind, planned: planned != nil)
        }
        process.arguments = arguments
        Log.debug(.tools, "\(spec.binary) \(process.arguments!.joined(separator: " "))")
        let log = tmp.appendingPathComponent("enc-\(tag).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardOutput = FileHandle.nullDevice
        process.trackExit()
        if spec.input == "fifo" {
            guard mkfifo(inArg, 0o600) == 0 else { throw LumoraError.unsupported("Couldn't create pipe for \(spec.binary)") }
            try process.runWatched()
            let h = try await Task.detached { try FileHandle(forWritingTo: URL(fileURLWithPath: inArg)) }.value
            return (process, h, log)
        }
        let pipe = Pipe()
        process.standardInput = pipe
        try process.runWatched()
        return (process, pipe.fileHandleForWriting, log)
    }

    // MARK: - Target-VMAF encoding

    private struct ChunkFrames { var id: Int; var start: Int; var frames: [PlanarFrame]; var reference: [PlanarFrame]? }

    /// Scene-aligned chunks small enough to keep their lossless masters in RAM (no frame dumps to disk).
    private func chunkRanges(_ ctx: Context, maxFrames: Int, minFrames: Int) -> [Range<Int>] {
        let cuts = ctx.job.analysis.cutFrames
        var bounds = [0]
        for (i, p) in ctx.plan.enumerated() where i > 0 && p.kind == .original && cuts.contains(p.a) { bounds.append(i) }
        bounds.append(ctx.plan.count)
        var ranges: [Range<Int>] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) where b > a {
            var s = a
            while b - s > maxFrames { ranges.append(s..<(s + maxFrames)); s += maxFrames }
            ranges.append(s..<b)
        }
        var merged: [Range<Int>] = []
        for r in ranges {
            if let last = merged.last, last.count < minFrames, last.count + r.count <= maxFrames {
                merged[merged.count - 1] = last.lowerBound..<r.upperBound
            } else { merged.append(r) }
        }
        return merged
    }

    private(set) var lastPieces: [TargetQualityEncoder.Piece] = []

    private func runTargetQuality(_ ctx: Context, tmp: URL, status: @escaping (String, Double) -> Void) async throws -> [URL] {
        let job = ctx.job
        guard let target = job.qualityTarget else { return [] }
        guard VMAFRunner.available else { throw LumoraError.missingTool("vmaf (brew install libvmaf)") }
        let metal = MetalContext.shared
        let fps = max(1, ctx.rate.num / max(1, ctx.rate.den))
        let perFrame = Double(ctx.width * ctx.height * 2) * (job.chroma == .c444 ? 3 : (job.chroma == .c422 ? 2 : 1.5))
            * (ctx.grain.cleanReference && !ctx.grain.cleanInput ? 2 : 1)
        let concurrent = MacProfile.current?.concurrentChunks ?? max(1, min(3, chip.cpuCores / 6))
        let budget = Double(ProcessInfo.processInfo.physicalMemory) * (MacProfile.current?.ramFraction ?? 0.30) / Double(concurrent + 1)
        let maxFrames = max(fps, min(Int(budget / perFrame), fps * 10))
        let chunks = chunkRanges(ctx, maxFrames: maxFrames, minFrames: fps * 3 / 2)
        let threads = max(2, chip.cpuCores / concurrent)
        Log.notice(.quality, "Target VMAF \(target.vmaf) (\(target.pool.rawValue)): \(chunks.count) chunks ≤ \(maxFrames) frames, \(concurrent) at a time, \(threads) threads each. RAM per chunk ≈ \(ByteCountFormatter.string(fromByteCount: Int64(perFrame * Double(maxFrames)), countStyle: .memory))")
        await MainActor.run { EncodeMonitor.shared.reset(target: target, chunks: chunks, totalFrames: ctx.plan.count) }

        // Stage 1+2: render every output frame once into RAM, grouped by chunk.
        let (prepared, producer) = try await startProducer(ctx, range: 0..<ctx.plan.count, depth: MacProfile.current?.pipelineDepth ?? 4)
        let channel = BoundedChannel<ChunkFrames>(capacity: 1)
        let renderer = GradeRenderer()
        let rgb = metal.makeTexture(width: ctx.width, height: ctx.height, format: job.highPrecision ? .rgba32Float : .rgba16Float)
        let rgbClean = (ctx.grain.cleanInput || ctx.grain.cleanReference)
            ? metal.makeTexture(width: ctx.width, height: ctx.height, format: job.highPrecision ? .rgba32Float : .rgba16Float) : nil
        let grainProcessor = GrainProcessor()
        let render = Task {
            do {
                var chunkIndex = 0
                var current: [PlanarFrame] = []
                var currentRef: [PlanarFrame] = []
                await MainActor.run { EncodeMonitor.shared.update(0) { $0.state = .rendering } }
                while let f = try await prepared.receive() {
                    let planes = PlanarFrame(device: metal.device, width: ctx.width, height: ctx.height, bits: job.bitDepth, chroma: job.chroma)
                    let cb = metal.queue.makeCommandBuffer()!
                    renderer.encodeGrade(cb, source: f.texture, destination: rgb,
                                         uniforms: uniforms(ctx, sourceIndex: f.sourceIndex, outputIndex: f.outputIndex, crop: f.crop),
                                         temporalKey: job.analysis.sceneIndex(for: f.sourceIndex))
                    var refPlanes: PlanarFrame?
                    if let rgbClean {
                        grainProcessor.denoise(cb, rgb, into: rgbClean, sigma: ctx.grain.sigma)
                        if ctx.grain.cleanInput {
                            renderer.encodePackPlanar(cb, rgb: rgbClean, planes: planes, matrixKr: ctx.kr, matrixKb: ctx.kb)
                        } else {
                            renderer.encodePackPlanar(cb, rgb: rgb, planes: planes, matrixKr: ctx.kr, matrixKb: ctx.kb)
                            let r = PlanarFrame(device: metal.device, width: ctx.width, height: ctx.height, bits: job.bitDepth, chroma: job.chroma)
                            renderer.encodePackPlanar(cb, rgb: rgbClean, planes: r, matrixKr: ctx.kr, matrixKb: ctx.kb)
                            refPlanes = r
                        }
                    } else {
                        renderer.encodePackPlanar(cb, rgb: rgb, planes: planes, matrixKr: ctx.kr, matrixKb: ctx.kb)
                    }
                    await cb.commitAndWait()
                    _ = f.keep
                    current.append(planes)
                    if let refPlanes { currentRef.append(refPlanes) }
                    status("Rendering and encoding to VMAF \(Int(target.vmaf))", Double(f.outputIndex) / Double(max(1, ctx.plan.count)))
                    if current.count == chunks[chunkIndex].count {
                        await channel.send(ChunkFrames(id: chunkIndex, start: chunks[chunkIndex].lowerBound, frames: current,
                                                       reference: currentRef.isEmpty ? nil : currentRef))
                        current = []
                        currentRef = []
                        chunkIndex += 1
                        if chunkIndex < chunks.count {
                            let next = chunkIndex
                            await MainActor.run { EncodeMonitor.shared.update(next) { $0.state = .rendering } }
                        }
                    }
                }
                await channel.finish()
            } catch {
                await channel.fail(error)
            }
        }

        // Stage 3: per-chunk search + validation, several chunks at once.
        let tq = TargetQualityEncoder(engine: self)
        let encodeOne = chunkEncoder(ctx, tmp: tmp, threads: threads)
        var pieces: [TargetQualityEncoder.Piece] = []
        // The render and producer stages are separate tasks waiting on channels; on cancel, stop them and fail the
        // channels so every waiting stage (and this loop) wakes up instead of rendering the rest of the film.
        do {
        try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: [TargetQualityEncoder.Piece].self) { group in
            var running = 0
            while let chunk = try await channel.receive() {
                try Task.checkCancellation()
                if running >= concurrent, let done = try await group.next() { pieces += done; running -= 1 }
                let scene = job.analysis.scenes[safe: job.analysis.sceneIndex(for: ctx.plan[chunk.start].a)]
                    ?? SceneStats(start: 0, end: 0, keyStops: -1.2, p005: -6, p50: -1, p995: 3, skinFraction: 0, avgChroma: 0)
                let r = chunk.start..<(chunk.start + chunk.frames.count)
                let share = Double(ctx.plan[r].filter { $0.kind != .original }.count) / Double(max(1, r.count))
                group.addTask {
                    try await tq.encode(frames: chunk.frames, chunkID: chunk.id, start: chunk.start, sceneStats: scene,
                                        interpolatedShare: share, kind: job.contentKind, encodeOne: encodeOne,
                                        target: target, rate: ctx.rate, workDir: tmp, threads: threads, codec: job.codec,
                                        hdr: job.target.isHDR, hlg: job.target.kind == .hlg, referenceFrames: chunk.reference,
                                        stripSyntheticGrain: ctx.grain.strip)
                }
                running += 1
            }
            for try await done in group { pieces += done }
        }
        } onCancel: {
            producer.cancel(); render.cancel()
            Task { await channel.fail(CancellationError()); await prepared.fail(CancellationError()) }
        }
        } catch {
            // Stop the render and decode stages and wait for them: they hold every rendered frame and the decoder,
            // and must not keep writing into a scratch folder that's about to be removed.
            render.cancel(); producer.cancel()
            await prepared.fail(error); await channel.fail(error)
            _ = await render.value
            _ = await producer.result
            throw error
        }
        _ = await render.value
        qcEvents += try await producer.value
        let scores = await MainActor.run { Array(EncodeMonitor.shared.frameScores.values) }
        if !scores.isEmpty {
            Log.notice(.quality, String(format: "Final VMAF: mean %.2f, worst %.2f over %d scored frames", scores.reduce(0, +) / Double(scores.count), scores.min()!, scores.count))
        }
        lastPieces = pieces.sorted { $0.start < $1.start }
        return lastPieces.map(\.url)
    }

    /// Encodes a run of RAM frames at an encoder level (CLI: -CRF/QP; VideoToolbox: quality × 100) to a file.
    private func chunkEncoder(_ ctx: Context, tmp: URL, threads: Int) -> ([PlanarFrame], Double, URL) async throws -> Void {
        let job = ctx.job
        let spec = encoderSpec(job)
        return { [unowned self] frames, level, url in
            if job.codec == .hevc {
                try await self.encodeChunkVT(ctx, frames: frames, quality: level / 100, to: url)
            } else if let spec {
                let (process, handle, log) = try await self.startCLIEncoder(ctx, spec: spec, out: url, tmp: tmp,
                                                                            tag: url.deletingPathExtension().lastPathComponent,
                                                                            threads: threads, quality: String(Int(-level)))
                // Canceling stops the trial encode at once (a slow encoder can block a write or its flush for minutes).
                try await withTaskCancellationHandler {
                    do {
                        guard let first = frames.first else { throw LumoraError.decodeFailed("No frames rendered for this chunk.") }
                        try handle.write(contentsOf: Data(first.y4mHeader(fpsNum: ctx.rate.num, fpsDen: ctx.rate.den).utf8))
                        for f in frames { try Task.checkCancellation(); try f.write(to: handle) }
                        try handle.close()
                    } catch {
                        if process.isRunning { process.terminate() }
                        await process.exited()
                        throw Task.isCancelled ? CancellationError() : error
                    }
                    await process.exited()
                    try Task.checkCancellation()
                } onCancel: {
                    if process.isRunning { process.terminate() }
                }
                guard process.terminationStatus == 0 else {
                    throw LumoraError.toolFailed(spec.binary, String((try? String(contentsOf: log, encoding: .utf8))?.suffix(1200) ?? ""))
                }
            }
        }
    }

    struct ForecastSamples {
        var samples: [SizeForecaster.Sample]
        var sceneOutputFrames: [Int: Int]
        var chunkFrames: Int
        var sampleFrames: Int
        var outputFrames: Int
    }

    /// Encodes short samples of contrasting scenes exactly as the real export would (same settings, same quality
    /// standard and checks) and returns real bytes per frame for each.
    func forecastSamples(_ job: ExportJob, sampleCount: Int = 8, progress: ProgressReporter) async throws -> ForecastSamples {
        let ctx = try baseContext(job)
        let tmp = try ScratchManager.jobDirectory("forecast")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fps = max(1, ctx.rate.num / max(1, ctx.rate.den))
        let sampleFrames = max(24, fps * 2)
        var sceneFrames: [Int: Int] = [:]
        for p in ctx.plan { sceneFrames[job.analysis.sceneIndex(for: p.a), default: 0] += 1 }
        let scenes = SizeForecaster.pickScenes(job.analysis, count: sampleCount)
        let threads = chip.cpuCores
        let encodeOne = chunkEncoder(ctx, tmp: tmp, threads: threads)
        var samples: [SizeForecaster.Sample] = []
        for (n, sc) in scenes.enumerated() {
            try Task.checkCancellation()
            let scene = job.analysis.scenes[sc]
            guard let start = ctx.plan.firstIndex(where: { $0.a >= scene.start }) else { continue }
            let frames = try await renderPlanar(ctx, range: start..<min(ctx.plan.count, start + sampleFrames))
            guard !frames.isEmpty else { continue }
            var bytes: Int64 = 0
            if var target = job.qualityTarget, ![.prores422HQ, .prores4444XQ, .av2].contains(job.codec), VMAFRunner.available {
                target.fixDips = false
                target.maxTrials = 3
                let pieces = try await TargetQualityEncoder(engine: self).encode(
                    frames: frames, chunkID: -1 - n, start: 0, sceneStats: scene, interpolatedShare: 0, kind: job.contentKind,
                    encodeOne: encodeOne, target: target, rate: ctx.rate, workDir: tmp, threads: threads, codec: job.codec,
                    hdr: job.target.isHDR, hlg: job.target.kind == .hlg)
                bytes = pieces.reduce(0) { $0 + Int64((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            } else if job.codec.cliKey != nil || job.codec == .hevc {
                let level = job.codec == .hevc ? Double(job.quality) * 100
                    : -Double(EncoderCatalog.shared.spec(for: job.codec.cliKey!).map { Int($0.qualityValue(job.quality)) ?? 30 } ?? 30)
                let url = tmp.appendingPathComponent("s\(n).\(job.codec == .hevc ? "mov" : (EncoderCatalog.shared.spec(for: job.codec.cliKey ?? "")?.ext ?? "bin"))")
                try await encodeOne(frames, level, url)
                bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            if bytes > 0 { samples.append(SizeForecaster.Sample(scene: sc, bytesPerFrame: Double(bytes) / Double(frames.count))) }
            progress.update(Double(n + 1) / Double(scenes.count), detail: "Sample \(n + 1) of \(scenes.count)")
            Log.info(.encode, "Forecast sample \(n + 1): scene \(sc), \(frames.count) frames → \(SizeForecast.gb(bytes))")
        }
        await MainActor.run { EncodeMonitor.shared.reset(target: nil, chunks: [], totalFrames: 0) }
        return ForecastSamples(samples: samples, sceneOutputFrames: sceneFrames, chunkFrames: fps * 6,
                               sampleFrames: sampleFrames, outputFrames: ctx.plan.count)
    }

    private func encodeChunkVT(_ ctx: Context, frames: [PlanarFrame], quality: Double, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings = videoSettings(ctx, includeCompression: true)
        if var comp = settings[AVVideoCompressionPropertiesKey] as? [String: Any] {
            comp[kVTCompressionPropertyKey_Quality as String] = quality
            settings[AVVideoCompressionPropertiesKey] = comp
        }
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { settings = videoSettings(ctx, includeCompression: false) }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Frame times are i * den / num; the track must count in 1/num s or 23.976/59.94 fps get rounded to 1/600 s.
        input.mediaTimeScale = CMTimeScale(ctx.rate.num)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: ctx.width, kCVPixelBufferHeightKey as String: ctx.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (i, f) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            f.fill(pb)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i) * CMTimeValue(ctx.rate.den), timescale: CMTimeScale(ctx.rate.num)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw LumoraError.unsupported(writer.error?.localizedDescription ?? "chunk write failed") }
    }

    private func encodeCLI(_ ctx: Context, range: Range<Int>, to url: URL, tmp: URL, index: Int, threads: Int,
                           tick: @escaping () -> Void) async throws -> [QCEvent] {
        let job = ctx.job
        guard let spec = encoderSpec(job) else {
            throw LumoraError.unsupported("No encoder configured for \(job.codec.displayName)")
        }
        let metal = MetalContext.shared
        let (process, handle, log) = try await startCLIEncoder(ctx, spec: spec, out: url, tmp: tmp, tag: "seg\(index)",
                                                               threads: threads, quality: spec.qualityValue(job.quality))

        let (prepared, producer) = try await startProducer(ctx, range: range, depth: MacProfile.current?.pipelineDepth ?? 4)
        // Planar frames are recycled: the grader may run up to `slots - 2` frames ahead of the writer.
        let slots = 6
        let frames = (0..<slots).map { _ in PlanarFrame(device: metal.device, width: ctx.width, height: ctx.height,
                                                        bits: job.bitDepth, chroma: job.chroma) }
        let packed = BoundedChannel<PlanarFrame>(capacity: slots - 2)
        let renderer = GradeRenderer()
        let rgbFormat: MTLPixelFormat = job.highPrecision ? .rgba32Float : .rgba16Float
        let rgb = metal.makeTexture(width: ctx.width, height: ctx.height, format: rgbFormat)
        try handle.write(contentsOf: Data(frames[0].y4mHeader(fpsNum: ctx.rate.num, fpsDen: ctx.rate.den).utf8))

        let grader = Task {
            do {
                var i = 0
                let rgbClean = ctx.grain.cleanInput ? metal.makeTexture(width: ctx.width, height: ctx.height, format: rgbFormat) : nil
                while let f = try await prepared.receive() {
                    let planes = frames[i % slots]
                    let cb = metal.queue.makeCommandBuffer()!
                    renderer.encodeGrade(cb, source: f.texture, destination: rgb,
                                         uniforms: uniforms(ctx, sourceIndex: f.sourceIndex, outputIndex: f.outputIndex, crop: f.crop),
                                         temporalKey: job.analysis.sceneIndex(for: f.sourceIndex))
                    if let rgbClean { GrainProcessor().denoise(cb, rgb, into: rgbClean, sigma: ctx.grain.sigma) }
                    renderer.encodePackPlanar(cb, rgb: rgbClean ?? rgb, planes: planes, matrixKr: ctx.kr, matrixKb: ctx.kb)
                    await cb.commitAndWait()
                    _ = f.keep
                    await packed.send(planes)
                    i += 1
                }
                await packed.finish()
            } catch {
                await packed.fail(error)
            }
        }

        // Canceling stops the encoder at once: a slow encoder can keep a frame write (or its final flush) blocked
        // for minutes, so checking between frames alone isn't enough.
        return try await withTaskCancellationHandler {
            do {
                // Writer stage: the encoder process (CPU cores) consumes frames while the GPU grades the next ones.
                while let planes = try await packed.receive() {
                    try Task.checkCancellation()
                    try planes.write(to: handle)
                    tick()
                }
            } catch {
                producer.cancel(); grader.cancel()
                await prepared.fail(error); await packed.fail(error)      // release stages waiting to send
                _ = await grader.value
                _ = await producer.result
                // If the encoder quit on its own, its log says why; that beats a broken-pipe or cancellation error.
                let exitedByItself = !process.isRunning
                if process.isRunning { process.terminate() }
                await process.exited()
                if Task.isCancelled { throw CancellationError() }
                if exitedByItself { throw Self.encoderFailure(spec.binary, log: log) }   // quit before taking every frame
                throw error
            }
            _ = await grader.value
            let events = try await producer.value
            try handle.close()
            await process.exited()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw Self.encoderFailure(spec.binary, log: log) }
            // An encoder that "succeeds" without writing pictures (e.g. aomenc two-pass on a pipe) must not pass.
            let written = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard written > 64 || range.isEmpty else {
                throw LumoraError.toolFailed(spec.binary, "it exited normally but wrote no video (\(written) bytes). "
                                             + String(((try? String(contentsOf: log, encoding: .utf8)) ?? "").suffix(600)))
            }
            return events
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// An AV2 stream must say what it is: BT.709 for SDR, BT.2020 with PQ or HLG for HDR. avmenc takes the CICP
    /// names on the command line and writes them into the content interpretation OBU; a wrong or missing description
    /// makes players guess (and HDR look washed out), so it fails the export instead.
    static func checkAV2Signaling(_ url: URL, target: OutputTarget.Kind) throws {
        let want: (Int, Int, Int) = target == .hdr10 ? (9, 16, 9) : (target == .hlg ? (9, 18, 9) : (1, 1, 1))
        let s = try AV2Stream.summary(of: url)
        guard let c = s.color else {
            throw LumoraError.toolFailed("avmenc", "the AV2 stream has no color description (content interpretation OBU).")
        }
        guard (c.primaries, c.transfer, c.matrix) == want, !c.fullRange else {
            throw LumoraError.toolFailed("avmenc", "the AV2 stream is signaled as primaries \(c.primaries), transfer \(c.transfer), matrix \(c.matrix)\(c.fullRange ? ", full range" : ""); expected \(want.0)/\(want.1)/\(want.2), limited range.")
        }
        Log.info(.encode, "AV2 stream: \(s.temporalUnits) temporal units, \(s.sequenceHeaders) sequence header(s), CICP \(c.primaries)/\(c.transfer)/\(c.matrix) (description \(c.descriptionIDC))")
    }

    private static func encoderFailure(_ binary: String, log: URL) -> LumoraError {
        let tail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(1500) ?? ""
        return LumoraError.toolFailed(binary, String(tail))
    }

    // MARK: - Join segments, carry audio + subtitles

    private func join(_ ctx: Context, segments: [URL], tmp: URL) async throws -> URL {
        let job = ctx.job
        let out = tmp.appendingPathComponent("joined." + job.outputURL.pathExtension)
        var isSlowMo = false
        if case .slowMotion = job.interpolation.mode { isSlowMo = true }
        let carrySource = !isSlowMo && (job.descriptor.kind == .avfoundation || job.descriptor.kind == .ffmpeg)
        // The decoders may have finished from already-open files, but the audio and subtitles are read from the
        // source now: if it vanished mid-export, say so instead of failing in a tool or dropping the audio.
        if carrySource, !FileManager.default.fileExists(atPath: job.descriptor.url.path) {
            throw LumoraError.unsupported("The source file “\(job.descriptor.url.lastPathComponent)” was moved or deleted during the export, so its audio and subtitles can't be added. Put it back and export again.")
        }
        let ext = segments[0].pathExtension

        // AV2: no container binding yet; OBU streams concatenate directly (each segment starts with its own temporal
        // delimiter, sequence header and key frame). FFmpeg can't read AV2, so the color signaling is checked here.
        if ext == "obu" {
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let h = try FileHandle(forWritingTo: out)
            for s in segments { try h.write(contentsOf: try Data(contentsOf: s)) }
            try h.close()
            try Self.checkAV2Signaling(out, target: job.target.kind)
            return out
        }

        // Hardware .mov segments: AVFoundation passthrough stitch keeps HDR tags; adds the source audio.
        if ext == "mov", ["mov", "mp4", "m4v"].contains(job.outputURL.pathExtension.lowercased()), job.descriptor.kind == .avfoundation {
            try await Self.stitch(segments: segments, audioFrom: carrySource ? job.descriptor.url : nil, to: out,
                                  fileType: job.outputURL.pathExtension.lowercased() == "mov" ? .mov : .mp4)
            return out
        }

        // Everything else: FFmpeg. Raw Annex-B segments (HEVC/VVC) are concatenated first.
        var args = ["-y", "-v", "error"]
        var video = segments[0]
        if ["hevc", "266"].contains(ext) {
            let rawJoined = tmp.appendingPathComponent("joined_raw.\(ext)")
            FileManager.default.createFile(atPath: rawJoined.path, contents: nil)
            let h = try FileHandle(forWritingTo: rawJoined)
            for s in segments { try h.write(contentsOf: try Data(contentsOf: s)) }
            try h.close()
            video = try Self.wrapRawVideo(rawJoined, rate: ctx.rate, in: tmp)
            args += ["-i", video.path]
        } else if segments.count > 1 {
            let list = tmp.appendingPathComponent("list.txt")
            try segments.map(FFConcat.line).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            args += ["-f", "concat", "-safe", "0", "-i", list.path]
        } else {
            args += ["-i", segments[0].path]
        }
        if carrySource {
            args += ["-i", job.descriptor.url.path, "-map", "0:v:0", "-map", "1", "-map", "-1:v", "-map", "-1:d?"]
        } else {
            args += ["-map", "0:v:0"]
        }
        args += ["-c", "copy"] + Packager.quickTimeVideoArgs(video: video, outputExtension: out.pathExtension)
        if carrySource, out.pathExtension.lowercased() == "mkv" {
            // MP4 text subtitles (tx3g) have no Matroska mapping; SubRip carries the same text.
            for (i, t) in SourceStreams.probe(job.descriptor.url).subtitles.enumerated() where t.codec == "mov_text" {
                args += ["-c:s:\(i)", "srt"]
            }
        }
        args.append(out.path)
        try ToolLocator.run("ffmpeg", args)
        return out
    }

    /// Raw Annex-B HEVC / VVC (x265, VVenC) carries no timestamps. FFmpeg 9 refuses to mux such packets into
    /// Matroska ("unknown timestamp") and into MP4 it guesses decode-order times and drops the leading frames.
    /// MP4Box (or mkvmerge, HEVC only) rebuilds presentation times from the picture order counts.
    static func wrapRawVideo(_ raw: URL, rate: (num: Int, den: Int), in dir: URL) throws -> URL {
        let base = raw.deletingPathExtension().lastPathComponent + "-ts"
        if ToolLocator.isAvailable("MP4Box") {
            let out = dir.appendingPathComponent(base + ".mp4")
            try? FileManager.default.removeItem(at: out)
            // MP4Box parses ':' and '#' inside -add arguments, so pass names relative to the folder.
            let name = raw.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL ? raw.lastPathComponent : raw.path
            try ToolLocator.run("MP4Box", ["-quiet", "-add", "\(name):fps=\(rate.num)/\(rate.den)", "-new", out.lastPathComponent], in: dir)
            return out
        }
        if raw.pathExtension == "hevc", ToolLocator.isAvailable("mkvmerge") {
            let out = dir.appendingPathComponent(base + ".mkv")
            try? FileManager.default.removeItem(at: out)
            try ToolLocator.run("mkvmerge", ["-q", "-o", out.path, "--default-duration", "0:\(rate.num)/\(rate.den)fps", raw.path])
            return out
        }
        throw LumoraError.missingTool("MP4Box")
    }

    static func stitch(segments: [URL], audioFrom source: URL?, to out: URL, fileType: AVFileType) async throws {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LumoraError.unsupported("composition")
        }
        var cursor = CMTime.zero
        for s in segments {
            let asset = AVURLAsset(url: s)
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let r = try await t.load(.timeRange)
            // Keep the segments' exact frame clock (e.g. 1/48000 for 47.952 fps) instead of the default 1/600.
            if cursor == .zero { video.naturalTimeScale = try await t.load(.naturalTimeScale) }
            try video.insertTimeRange(r, of: t, at: cursor)
            cursor = cursor + r.duration
        }
        if let source {
            let asset = AVURLAsset(url: source)
            for t in try await asset.loadTracks(withMediaType: .audio) {
                let r = try await t.load(.timeRange)
                let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try a?.insertTimeRange(CMTimeRange(start: r.start, duration: CMTimeMinimum(r.duration, cursor)), of: t, at: .zero)
            }
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw LumoraError.unsupported("export session")
        }
        try await session.export(to: out, as: fileType)
    }

    /// aomenc has no way to write HDR10 static metadata into the AV1 stream, so for Matroska output it goes into
    /// the container's Color element (MaxCLL/MaxFALL and the mastering display), which players read instead.
    private func addContainerHDR10Metadata(_ ctx: Context, file: URL, tmp: URL) throws -> URL {
        guard ctx.job.codec == .av1Pro, ctx.job.target.kind == .hdr10, let m = ctx.meta,
              file.pathExtension.lowercased() == "mkv" else { return file }
        guard ToolLocator.isAvailable("mkvmerge") else {
            Log.warning(.encode, "libaom AV1 can't carry HDR10 MaxCLL/mastering metadata itself; install mkvmerge (mkvtoolnix) to add it to the .mkv")
            return file
        }
        let p = HDRMetadata.p3
        func xy(_ v: (Int, Int)) -> String { String(format: "%.5f,%.5f", Double(v.0) / 50000, Double(v.1) / 50000) }
        let out = tmp.appendingPathComponent("hdr10-static.mkv")
        try ToolLocator.run("mkvmerge", ["-q", "-o", out.path,
                                         "--max-content-light", "0:\(Int(m.maxCLL.rounded()))",
                                         "--max-frame-light", "0:\(Int(m.maxFALL.rounded()))",
                                         "--max-luminance", "0:\(Int(m.peakNits))",
                                         "--min-luminance", "0:\(m.minNits)",
                                         "--chromaticity-coordinates", "0:\(xy(p.r)),\(xy(p.g)),\(xy(p.b))",
                                         "--white-colour-coordinates", "0:\(xy(p.wp))",
                                         file.path])
        return out
    }

    // MARK: - HDR10+ / Dolby Vision 8.1 injection (HEVC)

    private func injectDynamicMetadata(_ ctx: Context, file: URL, tmp: URL) throws -> URL {
        guard let levels = ctx.levels, let meta = ctx.meta else { return file }
        let job = ctx.job
        let annexB = tmp.appendingPathComponent("video.hevc")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", file.path, "-map", "0:v:0", "-c:v", "copy",
                                       "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", annexB.path])
        // Shots in output-frame terms, light levels from the nearest source frame.
        var shots: [HDRMetadata.Shot] = []
        var lastScene = -1
        for (k, p) in ctx.plan.enumerated() {
            let src = p.t < 0.5 ? p.a : p.b
            let scene = job.analysis.sceneIndex(for: src)
            let mx = levels.perFrameMax[safe: src] ?? meta.maxCLL, av = levels.perFrameAvg[safe: src] ?? meta.maxFALL
            if scene != lastScene {
                shots.append(HDRMetadata.Shot(start: k, duration: 1, maxNits: mx, avgNits: av))
                lastScene = scene
            } else {
                shots[shots.count - 1].duration += 1
                shots[shots.count - 1].maxNits = max(shots[shots.count - 1].maxNits, mx)
                shots[shots.count - 1].avgNits = max(shots[shots.count - 1].avgNits, av)
            }
        }
        var injected = tmp.appendingPathComponent("video_dyn.hevc")
        let decision = DolbyVisionRetimer.decide(source: job.descriptor, look: job.preset.look, passthrough: job.preset.params.passthrough,
                                                 codec: job.codec, delivery: job.delivery)
        var retimed: URL?
        if decision == .retimeOriginal {
            do {
                retimed = try DolbyVisionRetimer.retime(source: job.descriptor.url, mapping: DolbyVisionRetimer.sourceFrames(for: ctx.plan),
                                                        cropped: job.descriptor.crop != UniformBuilder.fullFrame, workDir: tmp)
            } catch {
                Log.warning(.encode, "Couldn't retime the original Dolby Vision (\(error.localizedDescription)); generating new metadata instead")
            }
        } else if case .generateNew(let why) = decision {
            Log.notice(.encode, "Generating new Dolby Vision metadata because \(why)")
        }
        if job.delivery == .dolbyVision84 {
            // Apple's encoder writes the 8.4 RPUs into the HLG stream itself; only the container record is missing.
            // Should it not have (another OS or encoder), generate them as for 8.1.
            let found = tmp.appendingPathComponent("vt-rpu.bin")
            if (try? ToolLocator.run("dovi_tool", ["extract-rpu", "-i", annexB.path, "-o", found.path])) != nil,
               ((try? DolbyVisionRetimer.frameCount(of: found)) ?? 0) > 0 {
                injected = annexB
            } else {
                Log.warning(.encode, "The hardware encoder wrote no Dolby Vision 8.4 metadata; generating it instead")
                let gen = tmp.appendingPathComponent("dovi_gen.json"), rpu = tmp.appendingPathComponent("rpu.bin")
                try HDRMetadata.doviGeneratorJSON(frames: ctx.plan.count, shots: shots, s: meta, profile: "8.4").write(to: gen)
                try ToolLocator.run("dovi_tool", ["generate", "-j", gen.path, "-o", rpu.path])
                try ToolLocator.run("dovi_tool", ["inject-rpu", "-i", annexB.path, "--rpu-in", rpu.path, "-o", injected.path])
            }
        } else if let retimed {
            try ToolLocator.run("dovi_tool", ["inject-rpu", "-i", annexB.path, "--rpu-in", retimed.path, "-o", injected.path])
        } else if job.delivery == .dolbyVision81 {
            let gen = tmp.appendingPathComponent("dovi_gen.json"), rpu = tmp.appendingPathComponent("rpu.bin")
            try HDRMetadata.doviGeneratorJSON(frames: ctx.plan.count, shots: shots, s: meta).write(to: gen)
            try ToolLocator.run("dovi_tool", ["generate", "-j", gen.path, "-o", rpu.path])
            try ToolLocator.run("dovi_tool", ["inject-rpu", "-i", annexB.path, "--rpu-in", rpu.path, "-o", injected.path])
        } else {
            let json = tmp.appendingPathComponent("hdr10plus.json")
            try HDRMetadata.hdr10PlusJSON(frames: ctx.plan.count, shots: shots).write(to: json)
            try ToolLocator.run("hdr10plus_tool", ["inject", "-i", annexB.path, "-j", json.path, "-o", injected.path])
        }
        // Remux with the audio/subtitles already in `file`. A raw HEVC stream only carries the HDR10 mastering display
        // and light levels when the encoder wrote them as SEI (x265 does; VideoToolbox puts them in the container
        // only), so they are restated to the muxer.
        let ext = job.outputURL.pathExtension.lowercased()
        let out = tmp.appendingPathComponent("final.\(ext)")
        let fps = "\(ctx.rate.num)/\(ctx.rate.den)"
        let staticMeta = job.target.kind == .hdr10 ? meta : nil
        if ext == "mp4" || ext == "mov", ToolLocator.isAvailable("MP4Box") {
            let dv = job.delivery == .dolbyVision81 ? ":dvp=8.1" : (job.delivery == .dolbyVision84 ? ":dvp=8.4" : "")
            // MP4Box parses ':' and '#' inside -add arguments, so pass plain names relative to the job folder.
            func rel(_ u: URL) -> String { u.deletingLastPathComponent().standardizedFileURL == tmp.standardizedFileURL ? u.lastPathComponent : u.path }
            var args = ["-add", "\(rel(injected)):fps=\(Double(ctx.rate.num) / Double(ctx.rate.den))\(dv)"]
            let audio = try? ToolLocator.run("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                                         "-of", "csv=p=0", file.path])
            if audio.map({ !$0.isEmpty }) ?? true { args += ["-add", "\(rel(file))#audio"] }   // "#audio" fails on a silent file
            if let staticMeta {
                try HDRMetadata.mp4BoxHDRXML(staticMeta).write(to: tmp.appendingPathComponent("hdr.xml"), atomically: true, encoding: .utf8)
                args += ["-hdr", "hdr.xml"]
            }
            try ToolLocator.run("MP4Box", args + ["-new", out.path], in: tmp)
        } else if ToolLocator.isAvailable("mkvmerge") {
            let mkv = out.deletingPathExtension().appendingPathExtension("mkv")
            try ToolLocator.run("mkvmerge", ["-o", mkv.path, "--default-duration", "0:\(fps)fps"]
                                + (staticMeta.map { HDRMetadata.mkvmergeStaticArgs($0, track: 0) } ?? [])
                                + [injected.path, "-D", file.path])
            return mkv
        } else {
            try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-r", fps, "-i", injected.path, "-i", file.path,
                                           "-map", "0:v:0", "-map", "1", "-map", "-1:v", "-c", "copy"]
                                + Packager.quickTimeVideoArgs(video: injected, outputExtension: ext) + [out.path])
        }
        return out
    }
}
