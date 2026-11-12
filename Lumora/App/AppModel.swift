import SwiftUI
import AppKit
import Metal
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    // Source
    var descriptor: SourceDescriptor?
    var colorCandidates: [SourceColor] = []
    var selectedColor: SourceColor?
    var analysis: AnalysisResult?
    var report: HDRReportCard?

    // Presets & grading
    var presets: [PresetCandidate] = []
    var selectedPresetID: UUID? { didSet { if let p = selectedPreset { params = p.params } } }
    var params = GradeParams()
    var thumbnails: [UUID: CGImage] = [:]

    // Preview
    var previewTarget: OutputTarget = .hdr10_1000
    var previewTime: Double = 0
    var previewFrame: DecodedFrame?
    var splitCompare = false
    var renderToken = 0

    // Interpolation & upscaling
    var interpolation = InterpolationSettings()
    var qcEvents: [QCEvent] = []
    var upscale: UpscaleMode = .off

    // Viewing tools
    var showScopes = false { didSet { refreshScopes() } }
    var scopes: GradeRenderer.Scopes?
    var falseColor = false { didSet { renderToken += 1 } }
    var nitsPicker = false
    var probeReadout: String?
    var removeBlackBars = true
    var detectedCrop = UniformBuilder.fullFrame
    var matchReport: ReferenceMatcher.Report?

    // Content, storage and quality
    var contentProfile: ContentProfile?
    var contentKind: ContentKind = .realLife { didSet { if oldValue != contentKind { applyTuning() } } }
    var storagePlan: StoragePlan?
    var proxyDescriptor: SourceDescriptor?
    var autoStage = UserDefaults.standard.object(forKey: "autoStage") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStage, forKey: "autoStage") }
    }
    var useTargetQuality = true
    var qualityTarget = QualityTarget()
    /// Which metrics decide "good enough". Presets differ for HDR and SDR deliveries.
    var qualityProfile: QualityProfile = QualityProfile.presets(hdr: true)[0] {
        didSet {
            qualityTarget.profile = qualityProfile
            if let p = qualityProfile.primary, p.metric == .vmaf { qualityTarget.vmaf = p.threshold }
            planVersion += 1
        }
    }
    var deliversHDR: Bool { delivery.target.0 != .sdr }
    var suggestedUpscaleModel: String?

    // Time budget planner
    var planMode: PlanMode = PlanMode(rawValue: UserDefaults.standard.string(forKey: "planMode") ?? "") ?? .bestForMac {
        didSet { UserDefaults.standard.set(planMode.rawValue, forKey: "planMode") }
    }
    var budgetHours: Double = UserDefaults.standard.object(forKey: "budgetHours") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(budgetHours, forKey: "budgetHours") }
    }
    var optionOverrides: [String: Bool] = [:]
    var dismissedUpgrades: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dismissedUpgrades") ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedUpgrades), forKey: "dismissedUpgrades") }
    }
    var planVersion = 0

    // Packaging
    var packaging = PackagingOptions()
    var sourceStreams = SourceStreams()
    var lookupMatches: [LibraryLookup.Match] = []
    var lastPackage: Packager.Result?
    var paused = false { didSet { let p = paused; Task { await PauseGate.shared.setPaused(p) } } }
    var regressionResults: [RegressionSet.Result] = []

    // Display-aware grading
    var thisDisplay: DisplayProfile?
    var gradeFor: DisplayProfile? { didSet { applyDisplay() } }
    var makeItPop = false { didSet { applyDisplay() } }

    // Beginner mode
    var simpleMode = UserDefaults.standard.object(forKey: "simpleMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "simpleMode") }
    }
    var goal: Goal = .watchOnTV
    var playsAV1 = UserDefaults.standard.object(forKey: "playsAV1") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playsAV1, forKey: "playsAV1") }
    }
    var trial: InterpolationTrial?
    var trialBusy = false
    var playing = false
    private var playTask: Task<Void, Never>?

    // Motion intelligence, grain and repair
    var motionMap: MotionMap?
    var filmTexture: FilmTexture = .off
    var filmTextureStrength: Float = 1

    // Size forecast
    var sourceSizes: StreamSizes?
    var sampledForecast: SizeForecast?
    var forecastBusy = false
    var folderEstimate: String?

    // Export
    var delivery: DeliveryFormat = .hdr10 {
        didSet {
            // HDR and SDR deliveries use different metric presets (e.g. SSIMULACRA 2 is SDR-only).
            if (oldValue.target.0 != .sdr) != deliversHDR,
               let p = QualityProfile.presets(hdr: deliversHDR).first(where: { $0.name == qualityProfile.name }) { qualityProfile = p }
        }
    }
    var codec: Codec = .hevc
    var bitDepth = 10
    var chroma: ChromaFormat = .c420
    var quality: Float = 0.8
    var peakNits: Float = 1000

    // Status
    var status = "Open a video, a RAW sequence folder, or a camera RAW file."
    var progress: Double?
    var errorMessage: String?
    var showExport = false
    var showAdvisor = false
    var showReport = false

    let chip = ChipProfile.current
    let library = HDRLibrary()
    let compare = CompareModel()
    var alsoExportOriginalRate = true
    var lastExportURL: URL?
    var lastOriginalRateURL: URL?
    private var task: Task<Void, Never>?

    var selectedPreset: PresetCandidate? { presets.first { $0.id == selectedPresetID } }

    /// The frame on screen at time `t`. Times built by adding 1/fps (the frame-step buttons) land a hair below
    /// n/fps, so plain truncation would show frame n-1, stepping would stall, and the picture would disagree with
    /// the timecode; the small tolerance keeps n/fps on frame n.
    nonisolated static func frameIndex(at t: Double, fps: Double) -> Int { max(0, Int((t * fps + 1e-4).rounded(.down))) }

    // MARK: Open & analyse

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .image, .folder, .data]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        run("Inspecting \(url.lastPathComponent)") { [self] in
            var (d, colors) = try await SourceInspector.inspect(url)
            status = "Checking the drive"
            let plan = StoragePlan.make(for: d)
            storagePlan = plan
            if plan.strategy == .stageToScratch && autoStage {
                let t = TaskCenter.shared.begin("Copying \(url.lastPathComponent) to the scratch SSD", symbol: "externaldrive.badge.plus")
                do {
                    let staged = try await Stager.stage(url, progress: ProgressReporter(task: t))
                    TaskCenter.shared.finish(t)
                    (d, colors) = try await SourceInspector.inspect(staged)
                } catch { TaskCenter.shared.finish(t, error: error); throw error }
            }
            status = "Looking for black bars"
            detectedCrop = (try? await CropDetector.detect(d)) ?? UniformBuilder.fullFrame
            d.crop = removeBlackBars ? detectedCrop : UniformBuilder.fullFrame
            descriptor = d
            matchReport = nil
            presets = []                      // a new file starts from its own recommended look
            selectedPresetID = nil
            thumbnails = [:]
            colorCandidates = colors
            selectedColor = colors.first
            previewTime = d.durationSeconds / 2
            await loadPreview()
            try await analyzeNow()
            refreshDisplay()
        }
    }

    func setScanFix(_ fix: ScanFix) {
        guard let d = descriptor, d.scanFix != fix else { return }
        descriptor = d.applying(fix)
        run("Re-reading with \(fix.displayName.lowercased())") { [self] in
            await loadPreview()
            try await analyzeNow()
        }
    }

    func setRemoveBlackBars(_ on: Bool) {
        removeBlackBars = on
        guard var d = descriptor else { return }
        d.crop = on ? detectedCrop : UniformBuilder.fullFrame
        descriptor = d
        run("Re-analysing") { [self] in try await analyzeNow() }
    }

    func chooseColor(_ c: SourceColor) {
        selectedColor = c
        run("Re-analysing as \(c.name)") { [self] in try await analyzeNow() }
    }

    private func analyzeNow() async throws {
        guard let d = descriptor, let color = selectedColor else { return }
        status = "Scanning scenes"
        let task = TaskCenter.shared.begin("Analysing \(d.url.lastPathComponent)", symbol: "waveform")
        let reporter = ProgressReporter(task: task)
        let wantsProxy = (storagePlan?.buildProxy ?? false) && proxyDescriptor == nil
        let proxy = wantsProxy ? try? ProxyWriter(for: d) : nil
        let readAhead = (storagePlan?.maxConcurrentReaders == 1) ? ReadAheadAdvisor(url: d.url) : nil
        let started = Date()
        let a: AnalysisResult
        do {
            a = try await SceneAnalyzer.analyze(d, color: color, chip: chip, proxy: proxy, readAhead: readAhead) { p in
                let fps = Double(d.frameCount) * p / max(0.001, Date().timeIntervalSince(started))
                reporter.update(p, detail: "\(Int(p * Double(d.frameCount))) of \(d.frameCount) frames", rate: String(format: "%.0f fps", fps))
                Task { @MainActor in self.progress = p }
            }
            TaskCenter.shared.finish(task)
        } catch { TaskCenter.shared.finish(task, error: error); throw error }
        if let proxy, let url = await proxy.finish() {
            var pd = d
            pd.url = url; pd.kind = .avfoundation; pd.scanFix = .none
            (pd.width, pd.height) = ProxyWriter.outputSize(for: d)
            proxyDescriptor = pd
            Log.info(.storage, "Preview proxy ready on the scratch SSD: \(url.lastPathComponent)")
        }
        analysis = a
        sourceSizes = await StreamSizes.probe(d)
        sourceStreams = await Task.detached { SourceStreams.probe(d.url) }.value
        let guess = Naming.guess(from: d.url.deletingPathExtension().lastPathComponent)
        packaging.bespoke = BespokeMetadata(title: guess["title"] ?? "", year: guess["year"] ?? "", show: guess["show"] ?? "",
                                            season: guess["season"] ?? "", episode: guess["episode"] ?? "")
        if guess["season"] != nil { packaging.naming = .plexTV }
        sampledForecast = nil
        let ct = TaskCenter.shared.begin("Content test", symbol: "sparkle.magnifyingglass")
        if let profile = try? await ContentProfiler.profile(d, color: color, analysis: a, progress: ProgressReporter(task: ct)) {
            contentProfile = profile
            contentKind = profile.kind
            TaskCenter.shared.finish(ct)
        } else { TaskCenter.shared.finish(ct, error: LumoraError.unsupported("content test failed")) }
        let keepLook = selectedPreset?.look
        report = (color.transfer == .pq || color.transfer == .hlg || color.transfer.isSDR)
            ? HDRReportCard.make(title: d.url.deletingPathExtension().lastPathComponent, descriptor: d, color: color, analysis: a)
            : nil
        presets = AutoPresetEngine.generate(colors: colorCandidates.filter { $0 == color } + colorCandidates.filter { $0 != color },
                                            analysis: a, report: report)
        applyTuningToPresets()
        // Re-analysing (black bars, scan fix, colour reading, an applied recommendation) keeps the chosen look.
        selectedPresetID = keepLook.flatMap { l in presets.first { $0.look == l && $0.color == color }?.id }
            ?? presets.first(where: \.recommended)?.id ?? presets.first?.id
        status = "\(a.scenes.count) scenes, \(presets.count) presets ready for \(contentKind.displayName.lowercased())"
        renderThumbnails()
    }

    func loadPreview() async {
        guard let d0 = descriptor else { return }
        let d = proxyDescriptor ?? d0      // scrub from the SSD proxy when the source is on a slow drive
        do {
            let src = try await d.makeFrameSource()
            let index = min(d.frameCount - 1, Self.frameIndex(at: previewTime, fps: d.fps))
            try src.start(at: index, count: 1)
            previewFrame = try src.nextFrame()
            src.cancel()
            renderToken += 1
            renderThumbnails()
            refreshScopes()
        } catch { errorMessage = error.localizedDescription }
    }

    func scrub(to t: Double) {
        previewTime = t
        Task { await loadPreview() }
    }

    // MARK: Time budget planner

    func draftJob() -> ExportJob? {
        guard let d = descriptor, let a = analysis, let p = selectedPreset else { return nil }
        var job = ExportJob(descriptor: d, preset: p, analysis: a, delivery: delivery, codec: codec,
                            outputURL: URL(fileURLWithPath: "/tmp/plan"))
        job.bitDepth = bitDepth; job.chroma = chroma; job.interpolation = interpolation
        job.upscale = upscale; job.contentKind = contentKind
        return job
    }

    /// How fast Lumora itself can feed the encoder (render is the floor for any plan).
    private func estimatedRenderFps(width: Int, height: Int) -> Double {
        let scale = Double(1920 * 1080) / Double(max(1, width * height))
        var fps = 160.0 * scale
        if interpolation.mode != .off { fps = min(fps, 24 * scale) }
        if case .model = upscale { fps = min(fps, 5 * scale) }
        return fps
    }

    func currentPlan() -> EncodePlan? {
        _ = planVersion
        guard let job = draftJob() else { return nil }
        let fallback = (width: descriptor?.outputWidth ?? 1920, height: descriptor?.outputHeight ?? 1080, frames: descriptor?.frameCount ?? 1)
        let shape = (try? ExportEngine().outputShape(job)) ?? fallback
        let vmaf = useTargetQuality && ![.prores422HQ, .prores4444XQ, .av2].contains(codec) && VMAFRunner.available
        // Perceptual gates cost time too: slow metrics run on ~half the frames, ~1.5 times per chunk.
        let gates = qualityProfile.effective().profile.rules.filter { $0.role != .off && $0.metric.slow }
        let pixelScale = Double(shape.width * shape.height) / Double(1920 * 1080)
        let metricCost = vmaf ? gates.reduce(0) { $0 + $1.metric.costPerFrame } * 0.75 * pixelScale : 0
        return EncodePlanner.plan(codec: codec, kind: contentKind, frames: shape.frames, width: shape.width, height: shape.height,
                                  vmafMode: vmaf, renderFps: estimatedRenderFps(width: shape.width, height: shape.height),
                                  mode: planMode, budget: budgetHours * 3600, overrides: optionOverrides,
                                  metricSecondsPerFrame: metricCost)
    }

    func applyUpgrade(_ u: EncodePlan.Upgrade) {
        // The upgrade's extra time is relative to the plan on screen, so measure it before switching modes.
        let base = currentPlan()?.seconds ?? 0
        planMode = .budget
        budgetHours = (base + u.extraSeconds) / 3600 + 0.05
        planVersion += 1
    }

    func measureOnThisMac() {
        guard var job = draftJob() else { return }
        job.qualityTarget = nil
        let target = qualityTarget.vmaf
        let t = TaskCenter.shared.begin("Measuring \(codec.displayName) on this Mac", symbol: "speedometer")
        Task {
            do {
                _ = try await ExportEngine().calibrate(job, target: target, progress: ProgressReporter(task: t))
                TaskCenter.shared.finish(t)
                planVersion += 1
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Packaging, library and archive safety

    /// Runs after every export: names, metadata, tracks, appendices, verification, checksums, notification.
    func packageExport(_ exported: URL, folder: URL, job: ExportJob, startedAt: Date) async {
        guard let d = descriptor else { return }
        let t = TaskCenter.shared.begin("Packaging \(exported.lastPathComponent)", symbol: "shippingbox")
        let reporter = ProgressReporter(task: t)
        let monitor = EncodeMonitor.shared
        var quality = ["Codec: \(job.codec.displayName)\(job.encodeChoice.map { ", \($0.rungLabel)" } ?? "")",
                       "Quality standard: \(job.qualityTarget?.profile.name ?? "fixed quality \(Int(job.quality * 100))")"]
        if !monitor.frameScores.isEmpty {
            let v = monitor.frameScores.values.map(\.self)
            quality.append(String(format: "Per-frame primary metric: mean %.2f, worst %.2f", v.reduce(0, +) / Double(v.count), v.min() ?? 0))
        }
        quality += monitor.chunks.map { c in "Chunk \(c.id + 1): \(c.state.rawValue)\(c.vmafMean.map { String(format: ", VMAF %.2f", $0) } ?? "")" }
        quality += qcEvents.isEmpty ? [] : ["Interpolation: \(qcEvents.count) frames repaired"]
        var settings: [String: Any] = [
            "source": packaging.metadataPolicy == .keep ? d.url.path : d.url.lastPathComponent, "frames": d.frameCount, "fps": "\(d.fpsNum)/\(d.fpsDen)",
            "look": job.preset.look.rawValue, "delivery": job.delivery.rawValue, "codec": job.codec.rawValue,
            "encoder": job.encodeChoice?.encoderKey ?? job.codec.cliKey ?? "videotoolbox",
            "preset": job.encodeChoice?.rungLabel ?? "", "extras": job.encodeChoice?.optionIDs ?? [],
            "bitDepth": job.bitDepth, "chroma": job.chroma.label, "qualityProfile": job.qualityTarget?.profile.name ?? "fixed",
            "contentType": job.contentKind.rawValue, "interpolation": "\(job.interpolation.mode)",
            "intelligence": job.interpolation.intelligence.rawValue, "grainAware": job.interpolation.grainAware,
            "filmTexture": job.filmTexture.rawValue, "crop": "\(d.crop)", "scanFix": d.scanFix.rawValue,
            "upscale": "\(job.upscale)", "started": ISO8601DateFormatter().string(from: startedAt),
            "finished": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONEncoder().encode(job.preset.params), let obj = try? JSONSerialization.jsonObject(with: data) { settings["gradeParameters"] = obj }
        let poster: Data? = {
            guard let f = previewFrame, let c = selectedColor else { return nil }
            let u = UniformBuilder.make(source: c, params: params, target: .sdr, sceneExposureStops: 0, viewport: .zero, crop: d.crop)
            guard let img = GradeRenderer().thumbnail(f.texture, uniforms: u, width: 1000) else { return nil }
            return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }()
        let facts = Packager.Facts(title: d.url.lastPathComponent, resolution: job.target.isHDR || job.descriptor.outputHeight >= 2000 ? "2160p" : "\(job.descriptor.outputHeight)p",
                                   hdr: job.delivery == .dolbyVision81 || job.delivery == .dolbyVision84 ? "DV" : (job.target.isHDR ? "HDR10" : "SDR"),
                                   codec: job.codec == .av1 || job.codec == .av1Pro ? "AV1" : (job.codec == .vvc ? "VVC" : (job.codec == .av2 ? "AV2" : (job.codec.isHardware && job.codec != .hevc ? "ProRes" : "HEVC"))),
                                   appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                                   settings: settings, qualityLines: quality, hdrReport: report?.findings ?? [],
                                   logLines: LogStore.shared.entries.filter { $0.date >= startedAt }.map { "\($0.date) [\($0.category.rawValue)] \($0.message)" }
                                       .map { packaging.metadataPolicy == .keep ? $0 : PrivacyScrub.paths($0) },
                                   posterJPEG: poster)
        do {
            let result = try await Packager.package(exported: exported, source: d.url, streams: sourceStreams, options: packaging,
                                                    destination: folder, facts: facts, progress: reporter)
            if result.video != exported { try? FileManager.default.removeItem(at: exported) }
            lastPackage = result
            lastExportURL = result.video
            QueueStore.markDone(d.url, output: result.video)
            TaskCenter.shared.finish(t)
            Notifier.send("Lumora finished", "\(result.video.lastPathComponent)\(result.verified == false ? " (verification FAILED)" : "")")
        } catch {
            TaskCenter.shared.finish(t, error: error)
            errorMessage = "Packaging failed: \(error.localizedDescription). The encoded file is still at \(exported.path)."
            Notifier.send("Lumora: packaging failed", exported.lastPathComponent)
        }
    }

    func lookUpTitle() {
        let b = packaging.bespoke
        let tv = packaging.naming == .plexTV
        Task {
            do {
                lookupMatches = try await LibraryLookup.search(tv ? (b.show.isEmpty ? b.title : b.show) : b.title,
                                                               year: b.year.isEmpty ? nil : b.year, tv: tv)
                if lookupMatches.isEmpty { status = "No matches found online" }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func useMatch(_ m: LibraryLookup.Match) {
        Task {
            var b = packaging.bespoke
            await LibraryLookup.details(m, into: &b)
            packaging.bespoke = b
            lookupMatches = []
        }
    }

    func verifyArchiveFolder() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true; pick.canChooseFiles = false
        guard pick.runModal() == .OK, let folder = pick.url else { return }
        let t = TaskCenter.shared.begin("Verifying archive", symbol: "checkmark.shield")
        Task {
            let r = await Verifier.verifyFolder(folder, progress: ProgressReporter(task: t))
            TaskCenter.shared.finish(t)
            status = r.bad.isEmpty ? "All \(r.checked) files match their checksums" : "\(r.bad.count) of \(r.checked) files don't match: \(r.bad.joined(separator: ", "))"
            Notifier.send("Archive verification", status)
        }
    }

    func addRegressionFrame(note: String) {
        Task {
            do { try await RegressionSet.add(from: self, note: note); status = "Reference frame added" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func runRegressionCheck() {
        let t = TaskCenter.shared.begin("Checking reference frames", symbol: "checklist")
        Task {
            regressionResults = await RegressionSet.check(progress: ProgressReporter(task: t))
            TaskCenter.shared.finish(t)
        }
    }

    // MARK: Display-aware grading

    func refreshDisplay() { thisDisplay = DisplayInspector.current() }

    /// Grades for a chosen screen: target peak, brightness-limiter guard, optional "pop".
    func applyDisplay() {
        guard let disp = gradeFor, let a = analysis else { return }
        if let i = presets.firstIndex(where: { $0.id == selectedPresetID }) {
            let base = AutoPresetEngine.generate(colors: [presets[i].color], analysis: a, report: report)
                .first { $0.look == presets[i].look } ?? presets[i]
            var adapted = AutoPresetEngine.adapt(base, for: disp, analysis: a, pop: makeItPop)
            adapted.name = presets[i].name
            presets[i].params = adapted.params
            presets[i].sceneExposures = adapted.sceneExposures
            params = adapted.params
        }
        if disp.peakNits > 100 {
            previewTarget = OutputTarget(kind: .hdr10, peakNits: disp.peakNits)
            peakNits = disp.peakNits
            if delivery == .sdr { delivery = .hdr10 }
        } else {
            previewTarget = .sdr
            delivery = .sdr
        }
        planVersion += 1
        renderToken += 1
        Log.notice(.app, "Grading for \(disp.name): \(disp.summary)\(makeItPop ? ", pop on" : "")")
    }

    /// Two files in one go: a future-proof 12-bit 4000-nit master and a viewing copy for today's screens
    /// (HEVC with Dolby Vision 8.1, so every TV maps the master's light well).
    func exportFutureProof() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true; pick.canChooseFiles = false; pick.prompt = "Export Here"
        guard pick.runModal() == .OK, let folder = pick.url, let p = selectedPreset else { return }
        let saved = (delivery, codec, bitDepth, chroma, peakNits, gradeFor)
        gradeFor = .futureProof
        delivery = .hdr10; codec = .prores4444XQ; bitDepth = 12; chroma = .c444; peakNits = 4000
        export(presetIDs: [p.id], folder: folder)
        Task {
            while task != nil, progress != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            gradeFor = DisplayProfile(name: "Today's HDR TVs", peakNits: 1000, sustainedNits: 400, panel: .oled, source: "typical")
            delivery = .dolbyVision81; codec = .hevc12; bitDepth = 10; chroma = .c420; peakNits = 1000
            export(presetIDs: [p.id], folder: folder)
            (delivery, codec, bitDepth, chroma, peakNits) = (saved.0, saved.1, saved.2, saved.3, saved.4)
            gradeFor = saved.5
        }
    }

    // MARK: Beginner mode: recommendations, playback, motion test

    func currentRecommendation() -> RecommendedSettings? {
        guard let d = descriptor, let c = selectedColor, let a = analysis else { return nil }
        return Recommender.recommend(goal: goal, playsAV1: playsAV1, descriptor: d, color: c, analysis: a,
                                     profile: contentProfile, report: report, sizes: sourceSizes,
                                     detectedCrop: detectedCrop != UniformBuilder.fullFrame)
    }

    /// One click: every setting the recommendation lists.
    func applyRecommendation() {
        guard let r = currentRecommendation() else { return }
        if let p = presets.first(where: { $0.look == r.look && $0.color == selectedColor }) ?? presets.first(where: { $0.look == r.look }) {
            selectedPresetID = p.id
        }
        delivery = r.delivery
        codec = r.codec
        bitDepth = r.codec.bitDepths.contains(10) ? 10 : r.codec.bitDepths[0]
        chroma = r.codec.chromaFormats[0]
        if let p = QualityProfile.presets(hdr: deliversHDR).first(where: { $0.name == r.profileName }) { qualityProfile = p }
        useTargetQuality = ![.prores422HQ, .prores4444XQ, .av2].contains(codec)
        planMode = r.planMode
        budgetHours = r.budgetHours
        interpolation.mode = r.interpolation
        interpolation.intelligence = r.intelligence
        interpolation.grainAware = r.grainAware
        filmTexture = r.filmTexture
        if removeBlackBars != r.removeBlackBars { setRemoveBlackBars(r.removeBlackBars) }
        previewTarget = OutputTarget(kind: r.delivery.target.0, peakNits: r.delivery.target.0 == .hdr10 ? 1000 : (r.delivery.target.0 == .hlg ? 1000 : 100))
        if r.delivery == .dolbyVision81 || (descriptor?.isDolbyVision ?? false && (r.codec == .hevc || r.codec == .hevc12) && r.look == .original) {
            delivery = .dolbyVision81
        }
        planVersion += 1
        renderToken += 1
        Log.notice(.app, "Applied recommendation — \(r.headline)")
        if r.interpolation != .off, r.intelligence != .eachFrame, motionMap == nil { buildMotionMap() }
    }

    var hotspots: [MotionHotspot] {
        guard let a = analysis, let d = descriptor else { return [] }
        return MotionScan.hotspots(a, fps: d.fps)
    }

    func runTrial(_ h: MotionHotspot) {
        guard let d = descriptor, let c = selectedColor, let a = analysis, let p = selectedPreset else { return }
        trialBusy = true
        let settings = interpolation, target = previewTarget
        let t = TaskCenter.shared.begin("Interpolation test on scene \(h.scene + 1)", symbol: "play.rectangle")
        Task {
            do {
                trial = try await MotionScan.trial(d, color: c, analysis: a, preset: p, settings: settings, hotspot: h, previewTarget: target)
                TaskCenter.shared.finish(t)
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
            trialBusy = false
        }
    }

    /// Live playback of the graded picture (from the SSD proxy when the source is on a slow drive).
    func togglePlay() {
        if playing { playTask?.cancel(); playing = false; return }
        guard let d0 = descriptor else { return }
        let d = proxyDescriptor ?? d0
        playing = true
        playTask = Task {
            do {
                let src = try await d.makeFrameSource()
                let startFrame = Self.frameIndex(at: previewTime, fps: d.fps)
                try src.start(at: startFrame, count: nil)
                var shown = 0
                let t0 = Date()
                while !Task.isCancelled, let f = try src.nextFrame() {
                    previewFrame = f
                    previewTime = Double(startFrame + shown) / d.fps
                    renderToken += 1
                    shown += 1
                    let due = Double(shown) / d.fps - Date().timeIntervalSince(t0)
                    if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
                }
                src.cancel()
            } catch {}
            // A paused (cancelled) loop must not flip the state of a playback started after it.
            if !Task.isCancelled { playing = false }
        }
    }

    // MARK: Repair an interpolated file made by any app (needs the original)

    func repairExternal(original: SourceDescriptor, interpolated: SourceDescriptor, interpolatedColor: SourceColor, report: InterpolationEvaluator.Report?) {
        guard let oc = compare.colorA else { return }
        let t = TaskCenter.shared.begin("Repairing \(interpolated.url.lastPathComponent)", symbol: "bandage")
        let reporter = ProgressReporter(task: t)
        let c = codec, q = qualityProfile, target = qualityTarget, depth = bitDepth
        Task {
            do {
                reporter.update(0, detail: "Checking every in-between frame against the original")
                let full = try await InterpolationEvaluator.evaluate(original: original, originalColor: oc, analysis: nil,
                                                                     interpolated: interpolated, interpolatedColor: interpolatedColor,
                                                                     fullScan: true) { v in reporter.update(v * 0.4, detail: "Full scan \(Int(v * 100))%") }
                let flagged = Set(full.flagged.map(\.outputIndex))
                guard !flagged.isEmpty else {
                    TaskCenter.shared.finish(t)
                    status = "No problem frames found; nothing to repair."
                    return
                }
                reporter.update(0.4, detail: "Reading the interpolated file")
                let analysisB = try await SceneAnalyzer.analyze(interpolated, color: interpolatedColor) { v in reporter.update(0.4 + v * 0.1, detail: nil) }
                var keep = Look.original.params
                keep.passthrough = true
                let preset = PresetCandidate(name: "Keep original look", look: .original, color: interpolatedColor, params: keep,
                                             sceneExposures: Array(repeating: 0, count: analysisB.scenes.count), reason: "repair")
                let hdr = interpolatedColor.transfer == .pq ? DeliveryFormat.hdr10 : (interpolatedColor.transfer == .hlg ? .hlg : .sdr)
                let out = interpolated.url.deletingPathExtension().appendingPathExtension("repaired").appendingPathExtension("mkv")
                var job = ExportJob(descriptor: interpolated, preset: preset, analysis: analysisB, delivery: hdr, codec: c, outputURL: out)
                job.bitDepth = c.bitDepths.contains(depth) ? depth : c.bitDepths[0]
                job.chroma = c.chromaFormats[0]
                var tq = target
                tq.profile = q
                job.qualityTarget = [.prores422HQ, .prores4444XQ, .av2].contains(c) ? nil : tq
                job.externalRepair = ExternalRepairPlan(flagged: flagged, originalFps: original.fps, interpolatedFps: interpolated.fps,
                                                        offsetSeconds: full.offsetSeconds)
                Log.notice(.interpolation, "External repair: \(flagged.count) frames flagged in \(interpolated.url.lastPathComponent); writing \(out.lastPathComponent)")
                let url = try await ExportEngine().run(job) { label, v in reporter.update(0.5 + v * 0.5, detail: label) }
                TaskCenter.shared.finish(t)
                status = "Saved \(url.lastPathComponent) with \(flagged.count) rebuilt frames"
                compare.loadPair(original: original.url, processed: url, analysis: nil)
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Motion map and repair

    /// Builds (or reuses) the per-scene model routing for this film.
    func buildMotionMap() {
        guard let d = descriptor, let a = analysis, let color = selectedColor else { return }
        let key = MotionMap.key(for: d)
        if let cached = MotionMap.load(key), cached.mode == interpolation.intelligence, cached.confidenceTarget >= interpolation.confidence {
            apply(cached)
            status = "Motion map reused (\(cached.routes.count) scenes)"
            return
        }
        let settings = interpolation, kind = contentKind
        let t = TaskCenter.shared.begin("Mapping interpolation per scene", symbol: "map")
        Task {
            do {
                let map = try await MotionRouter.build(d, color: color, analysis: a, settings: settings, kind: kind,
                                                       progress: ProgressReporter(task: t))
                apply(map)
                TaskCenter.shared.finish(t)
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ map: MotionMap) {
        motionMap = map
        interpolation.routes = Dictionary(uniqueKeysWithValues: map.routes.filter { $0.status != .skipped }.map { ($0.scene, $0) })
        renderToken += 1
    }

    /// Re-renders and re-encodes only the chunks of the last export that contain the given frames, then splices them in.
    func repairLastExport(frames: Set<Int>) {
        guard let url = lastExportURL, let manifest = ExportManifest.load(for: url), var job = draftJob() else {
            errorMessage = "Repair needs a target-quality export from this session (its chunk map is saved with it)."
            return
        }
        qualityTarget.profile = qualityProfile
        job.qualityTarget = useTargetQuality ? qualityTarget : nil
        job.encodeChoice = currentPlan()?.choice
        job.filmTexture = filmTexture
        job.filmTextureStrength = filmTextureStrength
        job.outputURL = url
        let t = TaskCenter.shared.begin("Repairing \(frames.count) flagged frames", symbol: "bandage")
        Task {
            do {
                _ = try await ExportEngine().repair(job, manifest: manifest, flaggedFrames: frames) { label, v in
                    Task { @MainActor in t.detail = label; t.progress = v }
                }
                TaskCenter.shared.finish(t)
                status = "Repaired in place; the previous version was kept alongside it."
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Size forecast

    /// Settings that change the answer; a sampled forecast is only shown while these still match.
    private var forecastKey: String {
        let plan = (!codec.isHardware ? currentPlan()?.choice.rungID : nil) ?? "-"
        let grain = optionOverrides["grain"] == true ? "g" : ""
        return [codec.rawValue, "\(bitDepth)", chroma.label, delivery.rawValue, contentKind.rawValue,
                useTargetQuality ? qualityProfile.name + "\(qualityProfile.primary?.threshold ?? 0)" : "q\(quality)",
                "\(interpolation.mode)", "\(upscale)", plan, grain, "\(peakNits)"].joined(separator: "|")
    }

    private var carriesSourceStreams: Bool {
        if case .slowMotion = interpolation.mode { return false }
        return descriptor.map { $0.kind == .avfoundation || $0.kind == .ffmpeg } ?? false
    }

    /// The forecast to show: the sampled one if it matches the current settings, otherwise an instant estimate.
    func currentForecast() -> SizeForecast? {
        _ = planVersion
        let key = forecastKey
        if let f = sampledForecast, f.key == key { return f }
        guard let job = draftJob(), let sizes = sourceSizes else { return nil }
        let fallback = (width: descriptor?.outputWidth ?? 1920, height: descriptor?.outputHeight ?? 1080, frames: descriptor?.frameCount ?? 1)
        let shape = (try? ExportEngine().outputShape(job)) ?? fallback
        let outFps = Double(shape.frames) / max(0.001, job.descriptor.durationSeconds)
        let grainSynth = optionOverrides["grain"] == true
        return SizeForecaster.quick(width: shape.width, height: shape.height, outputFrames: shape.frames, outputFps: outFps,
                                    codec: codec, kind: contentKind, grainSynthesis: grainSynth,
                                    target: useTargetQuality ? qualityTarget : nil, quality: quality,
                                    bitDepth: bitDepth, chroma: chroma, source: sizes, carryOther: carriesSourceStreams, key: key)
    }

    /// Encodes ~8 short samples of contrasting scenes exactly as the export would, then extrapolates.
    func refineForecast() {
        guard var job = draftJob(), let a = analysis, let sizes = sourceSizes else { return }
        qualityTarget.profile = qualityProfile
        job.qualityTarget = useTargetQuality && ![.prores422HQ, .prores4444XQ, .av2].contains(codec) ? qualityTarget : nil
        job.quality = quality
        if !codec.isHardware { job.encodeChoice = currentPlan()?.choice }
        let key = forecastKey, carry = carriesSourceStreams, kind = contentKind, c = codec
        forecastBusy = true
        let t = TaskCenter.shared.begin("Forecasting file size", symbol: "chart.bar.xaxis")
        Task {
            do {
                let r = try await ExportEngine().forecastSamples(job, progress: ProgressReporter(task: t))
                sampledForecast = SizeForecaster.fromSamples(r.samples, analysis: a, sceneOutputFrames: r.sceneOutputFrames,
                                                             chunkFrames: r.chunkFrames, sampleFrames: r.sampleFrames,
                                                             codec: c, kind: kind, source: sizes, carryOther: carry, key: key)
                TaskCenter.shared.finish(t)
                if let f = sampledForecast { Log.notice(.encode, "Forecast: \(SizeForecast.gb(f.mid)) (\(SizeForecast.gb(f.low))–\(SizeForecast.gb(f.high)))") }
            } catch {
                TaskCenter.shared.finish(t, error: error)
                errorMessage = error.localizedDescription
            }
            forecastBusy = false
        }
    }

    /// Quick, metadata-only estimate for a whole folder (no analysis): "412 files: 24.7 TB → about 6.8 TB".
    func estimateFolder() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true
        pick.canChooseFiles = false
        guard pick.runModal() == .OK, let folder = pick.url else { return }
        let exts: Set<String> = ["mov", "mp4", "m4v", "mkv", "m2ts", "ts", "mxf", "webm"]
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
        let c = codec, kind = contentKind, target = useTargetQuality ? qualityTarget : nil, q = quality, bits = bitDepth, ch = chroma
        let t = TaskCenter.shared.begin("Estimating \(files.count) files", symbol: "externaldrive")
        let reporter = ProgressReporter(task: t)
        Task {
            var before: Int64 = 0, low: Int64 = 0, mid: Int64 = 0, high: Int64 = 0
            for (i, f) in files.enumerated() {
                guard let inspected = try? await SourceInspector.inspect(f) else { continue }
                let d = inspected.0
                let sizes = await StreamSizes.probe(d)
                let est = SizeForecaster.quick(width: d.width, height: d.height, outputFrames: d.frameCount, outputFps: d.fps,
                                               codec: c, kind: kind, grainSynthesis: false, target: target, quality: q,
                                               bitDepth: bits, chroma: ch, source: sizes, carryOther: true, key: "")
                before += sizes.total; low += est.low; mid += est.mid; high += est.high
                reporter.update(Double(i + 1) / Double(max(1, files.count)), detail: f.lastPathComponent)
            }
            folderEstimate = "\(files.count) files: \(SizeForecast.gb(before)) → about \(SizeForecast.gb(mid)) (\(SizeForecast.gb(low))–\(SizeForecast.gb(high))), assuming \(kind.displayName.lowercased()). Quick estimate; analysing files tightens it."
            TaskCenter.shared.finish(t)
            Log.notice(.encode, folderEstimate ?? "")
        }
    }

    // MARK: Content tuning

    /// Applies the content type's tuning to interpolation, quality target and upscaling choices.
    func applyTuning() {
        let t = ContentTuning.preset(contentKind)
        if let best = ModelLab.shared.bestModel(for: contentKind) { interpolation.primaryModelID = best }
        interpolation.repairModelID = t.repairModel
        interpolation.sensitivity = t.qcSensitivity
        interpolation.smoothDuplicates = t.smoothDuplicates
        interpolation.grainAware = [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy].contains(contentKind)
            || (contentProfile?.grain ?? 0) > 0.008
        qualityTarget.vmaf = t.targetVMAF
        qualityTarget.model = t.vmafModel
        if qualityProfile.name == "VMAF only", let i = qualityProfile.rules.firstIndex(where: { $0.role == .target }) {
            qualityProfile.rules[i].threshold = t.targetVMAF
        }
        suggestedUpscaleModel = t.upscaleModel
        applyTuningToPresets()
        Log.notice(.app, "Tuned for \(contentKind.displayName): model \(interpolation.primaryModelID), QC \(t.qcSensitivity), target VMAF \(t.targetVMAF)")
    }

    private func applyTuningToPresets() {
        let t = ContentTuning.preset(contentKind)
        for i in presets.indices where presets[i].look != .original {
            presets[i].params.deband = t.deband
            presets[i].params.edgeProtection = t.edgeProtection
            presets[i].params.localContrast = presets[i].look.params.localContrast * t.punchScale
        }
        if let p = selectedPreset { params = p.params }
        renderThumbnails()
    }

    // MARK: Rendering helpers

    func sceneExposure(for preset: PresetCandidate) -> Float {
        guard let a = analysis, let d = descriptor else { return 0 }
        return preset.sceneExposures[safe: a.sceneIndex(for: Self.frameIndex(at: previewTime, fps: d.fps))] ?? 0
    }

    func previewUniforms(viewport: SIMD4<Float>) -> GradeUniforms? {
        guard let p = selectedPreset else { return nil }
        return UniformBuilder.make(source: p.color, params: params, target: previewTarget,
                                   sceneExposureStops: sceneExposure(for: p), viewport: viewport,
                                   split: splitCompare ? 0.5 : 0, sourcePeakNits: report?.p999Nits ?? 1000,
                                   crop: descriptor?.crop ?? UniformBuilder.fullFrame, falseColor: falseColor)
    }

    func renderThumbnails() {
        guard let frame = previewFrame else { return }
        let renderer = GradeRenderer()
        for p in presets {
            let u = UniformBuilder.make(source: p.color, params: p.params, target: .sdr,
                                        sceneExposureStops: sceneExposure(for: p), viewport: .zero,
                                        sourcePeakNits: report?.p999Nits ?? 1000,
                                        crop: descriptor?.crop ?? UniformBuilder.fullFrame)
            thumbnails[p.id] = renderer.thumbnail(frame.texture, uniforms: u, width: 240)
        }
    }

    // MARK: Scopes & nits picker

    func refreshScopes() {
        guard showScopes, let frame = previewFrame, let u = previewUniforms(viewport: .zero) else { return }
        var uu = u
        uu.falseColor = 0
        uu.split = 0
        scopes = GradeRenderer().scopes(frame.texture, uniforms: uu)
    }

    /// `uv` is the clicked point inside the picture (0...1).
    func probe(at uv: SIMD2<Float>) {
        guard let frame = previewFrame, var u = previewUniforms(viewport: .zero) else { return }
        u.falseColor = 0
        u.split = 0
        let v = GradeRenderer().probe(frame.texture, uniforms: u, at: uv)
        probeReadout = String(format: "%.0f nits  (R %.0f · G %.0f · B %.0f)", v.w, v.x, v.y, v.z)
    }

    // MARK: Reference match

    func matchToReference() {
        guard let d = descriptor, let a = analysis, let p = selectedPreset, let color = selectedColor else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the official HDR release of the same film or show (e.g. your 4K UHD copy)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var preset = p
        preset.params = params
        let target = previewTarget.isHDR ? previewTarget : .hdr10_1000
        run("Matching to reference") { [self] in
            let (curve, report) = try await ReferenceMatcher.match(source: d, color: color, preset: preset, analysis: a,
                                                                   target: target, reference: url) { v in
                Task { @MainActor in self.progress = v }
            }
            params.matchCurve = curve
            matchReport = report
            commitParams()
            status = report.summary
        }
    }

    func clearMatch() {
        params.matchCurve = nil
        matchReport = nil
        commitParams()
    }

    // MARK: Presets, stills, batch

    func savePreset() {
        guard let p = selectedPreset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [PresetFile.type]
        panel.nameFieldStringValue = "\(p.look.displayName).lumorapreset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PresetFile.save(p, params: params, to: url); status = "Saved preset \(url.lastPathComponent)" }
        catch { errorMessage = error.localizedDescription }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [PresetFile.type]
        guard panel.runModal() == .OK, let url = panel.url,
              let base = presets.first(where: { $0.color == selectedColor }) ?? presets.first else { return }
        do {
            let f = try PresetFile.load(url)
            var p = base
            p = PresetCandidate(name: f.name, look: f.look, color: base.color, params: f.params,
                                sceneExposures: presets.first(where: { $0.look == f.look && $0.color == base.color })?.sceneExposures
                                    ?? base.sceneExposures,
                                reason: "Imported" + (f.madeFor.map { " · made for \($0)" } ?? ""))
            presets.insert(p, at: 0)
            selectedPresetID = p.id
            renderThumbnails()
        } catch { errorMessage = error.localizedDescription }
    }

    func exportStill() {
        guard let frame = previewFrame, let p = selectedPreset, let d = descriptor else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(d.url.deletingPathExtension().lastPathComponent) \(Int(previewTime))s"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let files = try StillExporter.export(frame: frame.texture, preset: p, params: params,
                                                 sceneExposure: sceneExposure(for: p), crop: d.crop,
                                                 target: previewTarget, to: url.deletingPathExtension())
            status = "Saved " + files.map(\.lastPathComponent).joined(separator: ", ")
        } catch { errorMessage = error.localizedDescription }
    }

    /// Runs every video in a folder through detection, analysis and the recommended (or currently selected)
    /// look, exporting with the current export settings. Unattended: perfect for a season of episodes.
    func batchProcess() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true
        pick.canChooseFiles = false
        pick.message = "Choose a folder of videos to process"
        guard pick.runModal() == .OK, let input = pick.url else { return }
        let dest = NSOpenPanel()
        dest.canChooseDirectories = true
        dest.canChooseFiles = false
        dest.prompt = "Export Here"
        guard dest.runModal() == .OK, let output = dest.url else { return }
        let exts: Set<String> = ["mov", "mp4", "m4v", "mkv", "mxf", "avi", "ts", "m2ts", "webm", "braw", "r3d"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        QueueStore.enqueue(files, folder: output)
        runBatch(files, output: output)
    }

    /// Picks up a batch that was interrupted (quit, crash, restart).
    func resumePendingBatch() {
        guard let folder = QueueStore.pendingFolder else { return }
        runBatch(QueueStore.pending, output: folder)
    }

    private func runBatch(_ files: [URL], output: URL) {
        let look = selectedPreset?.look
        Notifier.requestPermission()
        run("Batch: \(files.count) files") { [self] in
            for (n, file) in files.enumerated() {
                await PauseGate.shared.wait()
                status = "Batch \(n + 1)/\(files.count): \(file.lastPathComponent)"
                var (d, colors) = try await SourceInspector.inspect(file)
                if removeBlackBars { d.crop = (try? await CropDetector.detect(d)) ?? UniformBuilder.fullFrame }
                guard let color = colors.first else { continue }
                let a = try await SceneAnalyzer.analyze(d, color: color, chip: chip) { _ in }
                let r = (color.transfer == .pq || color.transfer == .hlg)
                    ? HDRReportCard.make(title: file.lastPathComponent, descriptor: d, color: color, analysis: a) : nil
                let profileTask = TaskCenter.shared.begin("Content test: \(file.lastPathComponent)", symbol: "sparkle.magnifyingglass")
                let profile = try? await ContentProfiler.profile(d, color: color, analysis: a, progress: ProgressReporter(task: profileTask))
                TaskCenter.shared.finish(profileTask)
                let kind = profile?.kind ?? contentKind
                let tuning = ContentTuning.preset(kind)
                let candidates = AutoPresetEngine.generate(colors: colors, analysis: a, report: r)
                guard let preset = candidates.first(where: { $0.look == look && $0.color == color })
                        ?? candidates.first(where: \.recommended) ?? candidates.first else { continue }
                let ext = codec.defaultContainer == "mov" && d.kind != .avfoundation ? "mkv" : codec.defaultContainer
                var job = ExportJob(descriptor: d, preset: preset, analysis: a, delivery: delivery, codec: codec,
                                    outputURL: output.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                                        .appendingPathExtension(ext))
                job.peakNits = peakNits; job.bitDepth = bitDepth; job.chroma = chroma; job.quality = quality
                job.interpolation = interpolation; job.upscale = upscale
                job.contentKind = kind
                if !codec.isHardware, let shape = try? ExportEngine().outputShape(job) {
                    job.encodeChoice = EncodePlanner.plan(codec: codec, kind: kind, frames: shape.frames, width: shape.width,
                                                          height: shape.height, vmafMode: useTargetQuality && VMAFRunner.available,
                                                          renderFps: estimatedRenderFps(width: shape.width, height: shape.height),
                                                          mode: planMode, budget: budgetHours * 3600, overrides: [:]).choice
                }
                if let best = ModelLab.shared.bestModel(for: kind) { job.interpolation.primaryModelID = best }
                job.interpolation.sensitivity = tuning.qcSensitivity
                job.interpolation.smoothDuplicates = tuning.smoothDuplicates
                if useTargetQuality, ![.prores422HQ, .prores4444XQ, .av2].contains(codec) {
                    var t = qualityTarget
                    t.vmaf = tuning.targetVMAF
                    job.qualityTarget = t
                }
                Log.notice(.encode, "Batch \(n + 1)/\(files.count): \(file.lastPathComponent) as \(kind.displayName), look \(preset.look.displayName)")
                job.sourcePeakNits = r?.p999Nits ?? 1000
                job.filmTexture = filmTexture
                let started = Date()
                let encoded = try await ExportEngine().run(job) { label, v in
                    Task { @MainActor in self.progress = (Double(n) + v) / Double(files.count) }
                }
                // Package each file with its own name, tracks and metadata (your other packaging choices apply to all).
                var opts = packaging
                let guess = Naming.guess(from: file.deletingPathExtension().lastPathComponent)
                opts.bespoke = BespokeMetadata(title: guess["title"] ?? "", year: guess["year"] ?? "", show: guess["show"] ?? "",
                                               season: guess["season"] ?? "", episode: guess["episode"] ?? "")
                opts.naming = guess["season"] != nil ? .plexTV : (packaging.naming == .plexTV ? .plexMovie : packaging.naming)
                opts.outputName = ""
                opts.keepAudio = []; opts.keepSubtitles = []
                let streams = SourceStreams.probe(file)
                let facts = Packager.Facts(title: file.lastPathComponent, resolution: d.outputHeight >= 2000 ? "2160p" : "\(d.outputHeight)p",
                                           hdr: job.target.isHDR ? (job.delivery == .dolbyVision81 ? "DV" : "HDR10") : "SDR",
                                           codec: codec == .av1 || codec == .av1Pro ? "AV1" : (codec == .vvc ? "VVC" : "HEVC"),
                                           appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                                           settings: ["source": opts.metadataPolicy == .keep ? file.path : file.lastPathComponent, "look": preset.look.rawValue, "codec": codec.rawValue,
                                                      "contentType": kind.rawValue, "preset": job.encodeChoice?.rungLabel ?? "",
                                                      "started": ISO8601DateFormatter().string(from: started)],
                                           qualityLines: ["Quality standard: \(job.qualityTarget?.profile.name ?? "fixed")"],
                                           hdrReport: r?.findings ?? [],
                                           logLines: LogStore.shared.entries.filter { $0.date >= started }.map { "\($0.date) \($0.message)" }
                                               .map { opts.metadataPolicy == .keep ? $0 : PrivacyScrub.paths($0) },
                                           posterJPEG: nil)
                let packTask = TaskCenter.shared.begin("Packaging \(file.lastPathComponent)", symbol: "shippingbox")
                let packaged = try await Packager.package(exported: encoded, source: file, streams: streams, options: opts,
                                                          destination: output, facts: facts, progress: ProgressReporter(task: packTask))
                TaskCenter.shared.finish(packTask)
                if packaged.video != encoded, encoded.standardizedFileURL != file.standardizedFileURL { try? FileManager.default.removeItem(at: encoded) }
                QueueStore.markDone(file, output: packaged.video)
            }
            status = "Batch finished: \(files.count) files"
            Notifier.send("Lumora batch finished", "\(files.count) files processed")
        }
    }

    /// Opens the compare window with the current source on the left and the last export on the right.
    func prepareCompare() {
        compare.loadPair(original: descriptor?.url, processed: lastExportURL, analysis: analysis)
    }

    func commitParams() {
        guard let i = presets.firstIndex(where: { $0.id == selectedPresetID }) else { return }
        presets[i].params = params
        renderToken += 1
    }

    // MARK: Advisor

    func apply(_ advice: FormatAdvisor.Advice) {
        delivery = advice.delivery
        codec = advice.codec
        bitDepth = advice.bitDepth
        peakNits = advice.peakNits
        chroma = advice.codec.chromaFormats.first ?? .c420
        if let look = advice.look, let p = presets.first(where: { $0.look == look }) { selectedPresetID = p.id }
        previewTarget = OutputTarget(kind: advice.delivery.target.0, peakNits: advice.peakNits)
        renderToken += 1
    }

    // MARK: Interpolation scan

    func scanInterpolation() {
        guard let d = descriptor, let a = analysis, let color = selectedColor else { return }
        run("Scanning interpolation for artifacts") { [self] in
            qcEvents = try await InterpolationScanner.scan(d, color: color, analysis: a, settings: interpolation) { p in
                Task { @MainActor in self.progress = p }
            }
            let fixed = qcEvents.filter { $0.action != .accepted }.count
            status = fixed == 0 ? "No interpolation problems found." : "\(fixed) frames needed fixing — all repaired automatically."
        }
    }

    // MARK: Export

    func export(presetIDs: [UUID], folder: URL) {
        guard let d = descriptor, let a = analysis else { return }
        let chosen = presets.filter { presetIDs.contains($0.id) }
        run("Exporting") { [self] in
            for var p in chosen {
                try Task.checkCancellation()
                if p.id == selectedPresetID { p.params = params }
                let ext = delivery == .dolbyVision81 || delivery == .hdr10Plus ? "mkv"
                        : (codec.defaultContainer == "mov" && d.kind != .avfoundation ? "mkv" : codec.defaultContainer)
                var job = ExportJob(descriptor: d, preset: p, analysis: a, delivery: delivery, codec: codec,
                                    outputURL: folder.appendingPathComponent(Self.exportFileName(source: d.url, look: p.look,
                                                                                                 delivery: delivery, ext: ext)))
                job.peakNits = peakNits
                job.bitDepth = bitDepth
                job.chroma = chroma
                job.quality = quality
                job.interpolation = interpolation
                job.sourcePeakNits = report?.p999Nits ?? 1000
                job.upscale = upscale
                job.contentKind = contentKind
                job.filmTexture = filmTexture
                job.filmTextureStrength = filmTextureStrength
                qualityTarget.profile = qualityProfile
                job.qualityTarget = useTargetQuality && ![.prores422HQ, .prores4444XQ, .av2].contains(codec) ? qualityTarget : nil
                if !codec.isHardware { job.encodeChoice = currentPlan()?.choice }
                if let t = job.qualityTarget {
                    let eff = t.profile.effective()
                    Log.notice(.quality, "Quality profile \(t.profile.name): " + eff.profile.rules.filter { $0.role != .off }
                        .map { "\($0.metric.displayName) \($0.role.rawValue.lowercased()) \($0.threshold)" }.joined(separator: "; "))
                    for n in eff.notes { Log.warning(.quality, n) }
                }
                let forecast = currentForecast()
                EncodeMonitor.shared.forecast = forecast
                let started = Date()
                let engine = ExportEngine()
                let url = try await engine.run(job) { label, value in
                    Task { @MainActor in self.status = "\(p.look.displayName): \(label)"; self.progress = value }
                }
                qcEvents = engine.qcEvents
                try Task.checkCancellation()          // cancelled while finishing: don't package or announce it
                lastExportURL = url
                if let f = forecast, let actual = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    // Learn on the video part (audio passes through unchanged).
                    ForecastLearner.shared.record(ForecastLearner.key(codec, contentKind, f.method),
                                                  forecast: f.videoMid, actual: Int64(actual) - f.otherBytes)
                }
                // Library-ready packaging (name, tracks, metadata, appendices, checksum, verification).
                let savedEdition = packaging.bespoke.edition
                if chosen.count > 1 && savedEdition.isEmpty { packaging.bespoke.edition = p.look.displayName }
                await packageExport(url, folder: folder, job: job, startedAt: started)
                packaging.bespoke.edition = savedEdition
                if let m = ExportManifest.load(for: url), let final = lastPackage?.video, final != url {
                    var moved = m; moved.output = final.path; moved.save()
                }
                status = "Saved \(lastPackage?.video.lastPathComponent ?? url.lastPathComponent)"
                // Same grade at the original frame rate, so you can keep whichever you prefer.
                if alsoExportOriginalRate, interpolation.mode != .off {
                    try Task.checkCancellation()
                    var plain = job
                    plain.interpolation.mode = .off
                    plain.outputURL = job.outputURL.deletingPathExtension()
                        .appendingPathExtension("original-fps").appendingPathExtension(job.outputURL.pathExtension)
                    lastOriginalRateURL = try await ExportEngine().run(plain) { label, value in
                        Task { @MainActor in self.status = "Original frame rate: \(label)"; self.progress = value }
                    }
                    status = "Saved interpolated and original-frame-rate versions"
                }
            }
        }
    }

    /// "<source name> – <look> – <delivery>.<ext>", the file name an export is written under.
    nonisolated static func exportFileName(source: URL, look: Look, delivery: DeliveryFormat, ext: String) -> String {
        // The source name is shortened if needed so the whole name (look, delivery, ".original-fps.mov") still fits
        // the 255-byte limit; a long emoji or accented source name is legal on disk but would not fit otherwise.
        let base = Naming.truncated(source.deletingPathExtension().lastPathComponent, maxBytes: 140)
        let name = "\(base) – \(look.displayName) – \(delivery.displayName)"
            .replacingOccurrences(of: "/", with: "-")
        return name + "." + ext
    }

    func exportLUT(size: Int) {
        guard let p = selectedPreset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = "Lumora \(p.look.displayName) \(p.color.name) to \(previewTarget.displayName).cube"
            .replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var preset = p
        preset.params = params
        do {
            try LUTExporter.export(preset: preset, target: previewTarget, size: size, to: url)
            status = "Saved LUT \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Task plumbing

    private func run(_ label: String, _ body: @escaping () async throws -> Void) {
        task?.cancel()
        status = label
        progress = 0
        Log.info(.app, label)
        task = Task {
            do { try await body() } catch is CancellationError {
                status = "Cancelled"
            } catch {
                errorMessage = error.localizedDescription
                Log.error(.app, "\(label): \(error.localizedDescription)")
            }
            progress = nil
        }
    }

    func cancel() { task?.cancel() }
}
