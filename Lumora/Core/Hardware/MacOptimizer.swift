import Foundation
import Metal
import CoreML
import AVFoundation
import VideoToolbox

/// "Optimize for this Mac": measures what this machine is actually best at and bakes it into a profile.
/// Tests saturate the GPU, Neural Engine, media engines, every CPU core and the memory system on purpose.
@MainActor
@Observable
final class MacOptimizer {
    static let shared = MacOptimizer()

    enum Level: String, CaseIterable, Identifiable {
        case quick = "Quick (about 5 min)", thorough = "Thorough (about 30 min)", burnIn = "Burn-in (several hours)"
        var id: String { rawValue }
    }

    struct Step: Identifiable { let id = UUID(); var name: String; var state = "Waiting"; var progress = 0.0; var result = "" }

    var steps: [Step] = []
    var running = false
    var summary: [String] = MacProfile.current?.findings ?? []
    private var task: Task<Void, Never>?

    func start(_ level: Level, footage app: AppModel?) {
        guard !running else { return }
        running = true
        SystemMonitor.shared.start()
        let names = ["GPU threadgroup shapes", "Neural models (Core ML units)", "Media engine sessions", "CPU encoder parallelism",
                     "Memory and pipeline", "Scratch drive", "Sustained load (heat soak)"]
            + (level == .burnIn && app?.analysis != nil ? ["Encoder calibration on your film", "Interpolation benchmark on your film"] : [])
        steps = names.map { Step(name: $0) }
        let t = TaskCenter.shared.begin("Optimizing for this Mac", symbol: "cpu") { [weak self] in self?.task?.cancel() }
        task = Task {
            var p = MacProfile(machine: MacProfile.machineModel, chip: ChipProfile.current.brand, os: MacProfile.osVersion,
                               created: Date(), level: level.rawValue)
            do {
                try await run(0) { try await self.tuneThreadgroups(&p, level) }
                try await run(1) { try await self.tuneCoreML(&p, level) }
                try await run(2) { try await self.tuneMediaEngines(&p, level) }
                try await run(3) { try await self.tuneCPUEncoders(&p, level) }
                try await run(4) { self.tuneMemory(&p) }
                try await run(5) {
                    let root = ScratchManager.shared.root
                    p.scratchWriteMBps = await Task.detached { StorageInspector.measureWrite(root, bytes: 512 << 20) }.value
                    return p.scratchWriteMBps.map { String(format: "%.0f MB/s write on %@", $0, ScratchManager.shared.volume?.name ?? "scratch") } ?? "couldn't measure"
                }
                try await run(6) { try await self.sustained(&p, minutes: level == .quick ? 1 : (level == .thorough ? 4 : 25)) }
                if level == .burnIn, let app, steps.count > 7 {
                    try await run(7) { try await self.calibrateEncoders(app) }
                    try await run(8) { try await self.benchmarkInterpolation(app) }
                }
                p.findings = steps.map { "\($0.name): \($0.result)" }
                p.save()
                summary = p.findings
                TaskCenter.shared.finish(t)
                Log.notice(.app, "Mac profile saved:\n" + p.findings.joined(separator: "\n"))
            } catch {
                TaskCenter.shared.finish(t, error: error)
            }
            running = false
        }
    }

    func stop() { task?.cancel() }

    private func run(_ i: Int, _ body: () async throws -> String) async throws {
        try Task.checkCancellation()
        steps[i].state = "Running"
        if let t = TaskCenter.shared.active.first(where: { $0.title == "Optimizing for this Mac" }) {
            t.detail = steps[i].name
            t.progress = Double(i) / Double(steps.count)
        }
        let result = try await body()
        steps[i].state = "Done"
        steps[i].progress = 1
        steps[i].result = result
    }

    // MARK: 1. GPU: the fastest threadgroup shape per heavy kernel, timed on the GPU itself (4K frames).

    private func tuneThreadgroups(_ p: inout MacProfile, _ level: Level) async throws -> String {
        let ctx = MetalContext.shared
        let w = 3840, h = 2160
        let a = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        let b = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        let c = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        let guide = ctx.makeTexture(width: w / 4, height: h / 4, format: .rg32Float)
        var u = UniformBuilder.make(source: SourceColor(name: "t", transfer: .pq, gamut: .rec2020, legalToFull: false, confidence: 1),
                                    params: Look.punchy.params, target: .hdr10_1000, sceneExposureStops: 0,
                                    viewport: SIMD4<Float>(0, 0, Float(w), Float(h)))
        var d = DenoiseUniforms(sigmaSpatial: 1.6, sigmaRange: 0.01, radius: 3, pad: 0)
        var t: Float = 0.5
        var off = SIMD2<Int32>(17, 23)
        let kernels: [(String, (MTLComputeCommandEncoder) -> Void)] = [
            ("gradeKernel", { e in e.setTexture(a, index: 0); e.setTexture(guide, index: 1); e.setTexture(c, index: 2)
                e.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0) }),
            ("bilateralKernel", { e in e.setTexture(a, index: 0); e.setTexture(c, index: 1)
                e.setBytes(&d, length: MemoryLayout<DenoiseUniforms>.stride, index: 0) }),
            ("blendKernel", { e in e.setTexture(a, index: 0); e.setTexture(b, index: 1); e.setTexture(c, index: 2)
                e.setBytes(&t, length: 4, index: 0) }),
            ("regrainKernel", { e in e.setTexture(a, index: 0); e.setTexture(b, index: 1); e.setTexture(a, index: 2)
                e.setTexture(c, index: 3); e.setBytes(&off, length: 8, index: 0) })
        ]
        let shapes = [(8, 8), (16, 8), (8, 16), (16, 16), (32, 8), (32, 4), (64, 4), (32, 16)]
        var findings: [String] = []
        for (name, bind) in kernels {
            let pso = ctx.pipeline(name)
            var best: ((Int, Int), Double)?
            var baseline = 0.0
            for (i, s) in shapes.enumerated() where s.0 * s.1 <= pso.maxTotalThreadsPerThreadgroup {
                try Task.checkCancellation()
                let cb = ctx.queue.makeCommandBuffer()!
                let enc = cb.makeComputeCommandEncoder()!
                for _ in 0..<(level == .quick ? 4 : 10) {
                    bind(enc)
                    ctx.dispatch2D(enc, pso, width: w, height: h, threadgroup: s)
                }
                enc.endEncoding()
                await cb.commitAndWait()
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                if i == 0 { baseline = ms }
                if best == nil || ms < best!.1 { best = (s, ms) }
            }
            if let best {
                p.threadgroups[name] = [best.0.0, best.0.1]
                findings.append("\(name.replacingOccurrences(of: "Kernel", with: "")) \(best.0.0)×\(best.0.1)\(baseline > 0 ? String(format: " (%.0f%% faster)", (baseline / best.1 - 1) * 100) : "")")
            }
        }
        return findings.joined(separator: ", ")
    }

    // MARK: 2. Neural models: which compute units (Neural Engine, GPU Neural Accelerators, CPU) run each model fastest.

    private func tuneCoreML(_ p: inout MacProfile, _ level: Level) async throws -> String {
        let ctx = MetalContext.shared
        let specs = InterpolationModelSpec.all().filter(\.isInstalled).prefix(level == .quick ? 2 : 8)
        guard !specs.isEmpty else { return "no interpolation models installed yet (Model Lab)" }
        let a = ctx.makeTexture(width: 1920, height: 1080, format: .rgba16Float)
        let b = ctx.makeTexture(width: 1920, height: 1080, format: .rgba16Float)
        let out = ctx.makeTexture(width: 1920, height: 1080, format: .rgba16Float)
        let proxy = UniformBuilder.analysis(source: SourceColor(name: "t", transfer: .pq, gamut: .rec2020, legalToFull: false, confidence: 1), gridW: 1, gridH: 1)
        var findings: [String] = []
        for spec in specs {
            var best: (MLComputeUnits, Double)?
            for units in [MLComputeUnits.all, .cpuAndGPU, .cpuAndNeuralEngine] {
                try Task.checkCancellation()
                guard let e = try? CoreMLInterpolator(spec: spec, proxyUniforms: proxy, computeUnits: units) else { continue }
                _ = try? e.interpolate(a, b, times: [0.5], into: [out], qcTiles: (1, 1))       // warm-up / compile
                let reps = level == .quick ? 3 : 8
                let t0 = Date()
                for _ in 0..<reps { _ = try e.interpolate(a, b, times: [0.5], into: [out], qcTiles: (1, 1)) }
                let ms = Date().timeIntervalSince(t0) * 1000 / Double(reps)
                if best == nil || ms < best!.1 { best = (units, ms) }
            }
            if let best {
                p.coreMLUnits[spec.id] = best.0.rawValue
                p.modelMsPerFrame[spec.id] = best.1
                let where_ = best.0 == .all ? "Neural Engine + GPU" : (best.0 == .cpuAndGPU ? "GPU" : "Neural Engine")
                findings.append("\(spec.displayName): \(where_), \(Int(best.1)) ms/frame at 1080p")
            }
        }
        return findings.joined(separator: "; ")
    }

    // MARK: 3. Media engines: how many hardware HEVC encodes really run in parallel (counts engines, now and future).

    private func tuneMediaEngines(_ p: inout MacProfile, _ level: Level) async throws -> String {
        let frames = level == .quick ? 60 : 180
        var results: [(Int, Double)] = []
        for n in [1, 2, 3, 4, 6, 8] {
            try Task.checkCancellation()
            let t0 = Date()
            try await withThrowingTaskGroup(of: Void.self) { g in
                for i in 0..<n { g.addTask { try await Self.hardwareEncode(frames: frames, tag: "\(n)-\(i)") } }
                try await g.waitForAll()
            }
            let fps = Double(frames * n) / Date().timeIntervalSince(t0)
            results.append((n, fps))
            if let prev = results.dropLast().last, fps < prev.1 * 1.08 { break }      // stopped scaling
        }
        let best = results.filter { $0.1 >= (results.map(\.1).max() ?? 0) * 0.95 }.min { $0.0 < $1.0 } ?? (1, 0)
        p.vtSessions = best.0
        let single = results.first?.1 ?? 1
        return String(format: "%d parallel 4K HEVC encodes (%.0f fps total, %.1f× one session)", best.0, best.1, best.1 / max(1, single))
    }

    nonisolated private static func hardwareEncode(frames: Int, tag: String) async throws {
        let url = try ScratchManager.jobDirectory("vt").appendingPathComponent("t\(tag).mov")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 3840, AVVideoHeightKey: 2160,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 3840, kCVPixelBufferHeightKey as String: 2160,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            // A moving gradient so the encoder does real work.
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                for y in Swift.stride(from: 0, to: 2160, by: 1) {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in Swift.stride(from: 0, to: 3840, by: 8) { row[x] = UInt16(((x + y + i * 9) & 1023) << 6) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    // MARK: 4. CPU encoders: best number of parallel instances (every core busy, no oversubscription).

    private func tuneCPUEncoders(_ p: inout MacProfile, _ level: Level) async throws -> String {
        let cores = ChipProfile.current.cpuCores
        var findings: [String] = []
        for codec in [Codec.av1, .hevc12, .vvc, .av1Pro] {
            guard let key = codec.cliKey, let spec = EncoderCatalog.shared.spec(for: key), ToolLocator.isAvailable(spec.binary) else { continue }
            let fast = codec == .av1 ? "8" : (codec == .hevc12 ? "medium" : (codec == .vvc ? "faster" : "6"))
            var results: [(Int, Double)] = []
            for k in [1, 2, 3, 4, 6].filter({ $0 <= cores }) {
                try Task.checkCancellation()
                let frames = level == .quick ? 24 : 72
                let t0 = Date()
                try await withThrowingTaskGroup(of: Void.self) { g in
                    for i in 0..<k {
                        g.addTask { try await Self.cliEncode(spec: spec, preset: fast, threads: max(1, cores / k), frames: frames, tag: "\(key)\(k)\(i)") }
                    }
                    try await g.waitForAll()
                }
                let fps = Double(frames * k) / Date().timeIntervalSince(t0)
                results.append((k, fps))
                if results.count >= 2, fps < results[results.count - 2].1 * 1.05 { break }
            }
            if let best = results.max(by: { $0.1 < $1.1 }) {
                p.cliInstances[codec.rawValue] = best.0
                p.cliFps[codec.rawValue] = best.1
                findings.append(String(format: "%@ %d × %d threads (%.0f fps @1080p)", spec.binary, best.0, max(1, cores / best.0), best.1))
            }
        }
        return findings.isEmpty ? "no software encoders installed" : findings.joined(separator: "; ")
    }

    /// Placeholder values for a benchmark encode. Every placeholder in encoders.json needs one: an unfilled
    /// `{vvenc_sdr}` reached vvencapp verbatim, which refused it, so VVenC was never measured.
    nonisolated static func benchmarkValues(spec: EncoderSpec, inArg: String, out: String, preset: String, threads: Int) -> [String: String] {
        ["in": inArg, "out": out, "w": "1920", "h": "1080", "fps_num": "24", "fps_den": "1", "bits": "10",
         "preset": preset, "quality": spec.qualityValue(0.8), "threads": "\(threads)", "cp": "9", "tc": "16", "mc": "9",
         "cp_name": "bt2020", "tc_name": "smpte2084", "mc_name": "bt2020ncl", "vvenc_hdr": "off", "vvenc_sdr": "sdr_709",
         "vvenc_additional": "", "vvenc_qpa": "1", "maxcll": "1000",
         "maxfall": "400", "svt_mastering": "", "x265_mastering": "", "aom_profile": "0", "x265_profile": "main10", "grain_table": "",
         "svt_grain": "8"]
    }

    nonisolated private static func cliEncode(spec: EncoderSpec, preset: String, threads: Int, frames: Int, tag: String) async throws {
        let dir = try ScratchManager.jobDirectory("cpu")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("o.\(spec.ext)")
        let inArg = spec.inputArg.replacingOccurrences(of: "{fifo}", with: dir.appendingPathComponent("in").path)
        let values = benchmarkValues(spec: spec, inArg: inArg, out: out.path, preset: preset, threads: threads)
        let proc = Process()
        proc.executableURL = ToolLocator.url(for: spec.binary)
        proc.arguments = spec.render(values, hdr: false)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let handle: FileHandle
        if spec.input == "fifo" {
            mkfifo(inArg, 0o600)
            try proc.run()
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: inArg))
        } else {
            let pipe = Pipe(); proc.standardInput = pipe; try proc.run(); handle = pipe.fileHandleForWriting
        }
        let frame = PlanarFrame(device: MetalContext.shared.device, width: 1920, height: 1080, bits: 10, chroma: .c420)
        try handle.write(contentsOf: Data(frame.y4mHeader(fpsNum: 24, fpsDen: 1).utf8))
        let y = frame.y.contents().bindMemory(to: UInt16.self, capacity: 1920 * 1080)
        let cb = frame.cb.contents().bindMemory(to: UInt16.self, capacity: 960 * 540)
        let cr = frame.cr.contents().bindMemory(to: UInt16.self, capacity: 960 * 540)
        for i in 0..<frames {
            for p in 0..<(1920 * 1080) { y[p] = UInt16(64 + ((p % 1920 + p / 1920 + i * 7) * 3 + (p &* 2654435761 >> 28)) % 876) }
            for p in 0..<(960 * 540) { cb[p] = UInt16(512 + (p + i) % 64); cr[p] = UInt16(512 - (p + i) % 64) }
            try frame.write(to: handle)
        }
        try handle.close()
        await proc.waitForExit()
    }

    // MARK: 5. Memory and pipeline depth from real RAM.

    private func tuneMemory(_ p: inout MacProfile) -> String {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        p.ramFraction = gb >= 192 ? 0.55 : (gb >= 96 ? 0.45 : (gb >= 48 ? 0.35 : 0.25))
        p.pipelineDepth = max(3, min(16, Int(gb / 8)))
        let encoders = p.cliInstances.values.max() ?? 2
        p.concurrentChunks = max(1, min(8, max(encoders, Int(gb / 32))))
        return String(format: "%.0f GB: %.0f%% for frame masters, %d frames in flight, %d chunks at once",
                      gb, p.ramFraction * 100, p.pipelineDepth, p.concurrentChunks ?? 1)
    }

    // MARK: 6. Sustained load: GPU and every CPU core at once until heat soak; how much speed survives.

    private func sustained(_ p: inout MacProfile, minutes: Double) async throws -> String {
        let ctx = MetalContext.shared
        let w = 3840, h = 2160
        let a = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        let c = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        var d = DenoiseUniforms(sigmaSpatial: 1.6, sigmaRange: 0.01, radius: 3, pad: 0)
        let end = Date().addingTimeInterval(minutes * 60)
        let cpuLoad = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<ChipProfile.current.cpuCores {
                    g.addTask {
                        var x = 1.0
                        while Date() < end && !Task.isCancelled { for i in 0..<200_000 { x = x * 1.0000001 + Double(i & 7) } }
                        _ = x
                    }
                }
            }
        }
        var rates: [Double] = []
        var startThermal = ProcessInfo.processInfo.thermalState
        while Date() < end {
            try Task.checkCancellation()
            let t0 = Date()
            let cb = ctx.queue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            for _ in 0..<20 {
                enc.setTexture(a, index: 0); enc.setTexture(c, index: 1)
                enc.setBytes(&d, length: MemoryLayout<DenoiseUniforms>.stride, index: 0)
                ctx.dispatch2D(enc, ctx.pipeline("bilateralKernel"), width: w, height: h)
            }
            enc.endEncoding()
            await cb.commitAndWait()
            rates.append(20 / Date().timeIntervalSince(t0))
            if rates.count == 1 { startThermal = ProcessInfo.processInfo.thermalState }
        }
        cpuLoad.cancel()
        let early = rates.prefix(max(1, rates.count / 10)).reduce(0, +) / Double(max(1, rates.count / 10))
        let late = rates.suffix(max(1, rates.count / 10)).reduce(0, +) / Double(max(1, rates.count / 10))
        p.sustainedFactor = max(0.3, min(1, late / max(0.001, early)))
        return String(format: "%.0f%% of peak speed after %.0f min (thermal %@ → %@)", p.sustainedFactor * 100, minutes,
                      "\(startThermal.rawValue)", "\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    // MARK: 7–8. Burn-in on your film: real encoder calibration and interpolation benchmark for its content type.

    private func calibrateEncoders(_ app: AppModel) async throws -> String {
        var out: [String] = []
        for codec in [Codec.av1, .hevc12, .vvc] where codec.available {
            let previous = app.codec
            app.codec = codec
            app.measureOnThisMac()
            app.codec = previous
            out.append(codec.displayName)
        }
        return out.isEmpty ? "no software encoders installed" : "started for " + out.joined(separator: ", ") + " (see Activity)"
    }

    private func benchmarkInterpolation(_ app: AppModel) async throws -> String {
        guard let d = app.descriptor, let c = app.selectedColor, let a = app.analysis else { return "open a film first" }
        let bm = try await InterpolationEvaluator.benchmark(original: d, color: c, analysis: a) { _ in }
        ModelLab.shared.record(benchmark: bm, for: app.contentKind)
        app.interpolation.sensitivity = bm.recommendedSensitivity
        return bm.summary
    }
}
