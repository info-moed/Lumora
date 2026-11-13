import AppKit
import SwiftUI

/// An export that failed, carrying its plain-language report up to the UI (instead of the generic alert).
struct ReportedFailure: LocalizedError {
    let report: FailureReport
    let underlying: Error
    private let message: String          // computed once, never while Foundation bridges this error (see GPUFault)
    init(report: FailureReport, underlying: Error) {
        self.report = report
        self.underlying = underlying
        message = underlying.localizedDescription
    }
    var errorDescription: String? { message }
}

/// Failures of the current batch, so one broken file doesn't stop the others and the summary says what happened.
@MainActor
enum BatchFailures {
    static var reports: [FailureReport] = []
}

/// Render recovery in the app: resume offers, the failure sheet's actions, source checks and repairs.
/// Kept apart from AppModel.swift so its own changes stay a few one-line hooks.
extension AppModel {

    // MARK: Running exports

    /// Saved progress for this job, when the Export sheet's "Resume from …" row is on.
    func recoveryOptions(for job: ExportJob) -> RecoveryOptions {
        var o = RecoveryOptions()
        if resumeSavedProgress, let offer = ResumeCoordinator.match(job, in: resumeOffers) { o.resume = offer.journal }
        return o                                // the Stop button decides at cancel time whether progress is kept
    }

    /// Runs one export with checkpointing; a failure comes back as a ReportedFailure with its explanation.
    /// Saved progress that can't be used any more (the encoder, Lumora or the source changed) is removed by the
    /// session, and the export starts over right away, as the Export sheet promises; `unattended` (batches) also does
    /// that when only the Mac changed, as nobody is there to choose "Resume anyway".
    func runExport(_ engine: ExportEngine, _ job: ExportJob, options: RecoveryOptions? = nil, unattended: Bool = false,
                   status: @escaping (String, Double) -> Void) async throws -> URL {
        let o = options ?? recoveryOptions(for: job)
        do {
            let url: URL
            do {
                url = try await engine.run(job, options: o, status: status)
            } catch let r as ResumeRefused where o.resume != nil && (!r.differentMac || unattended) {
                if let id = o.resume?.exportID { CheckpointStore.discard(id); resumeOffers.removeAll { $0.id == id } }
                Log.notice(.app, "\(job.outputURL.lastPathComponent): \(r.localizedDescription) Starting over.")
                status("Starting over: \(r.reason)", 0)
                var fresh = RecoveryOptions()
                fresh.skipDynamicMetadata = o.skipDynamicMetadata
                fresh.lessMemory = o.lessMemory
                url = try await engine.run(job, options: fresh, status: status)
            }
            refreshResumeOffers()
            return url
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let r = engine.lastFailure { throw ReportedFailure(report: r, underlying: error) }
            throw error
        }
    }

    /// One file of a batch: a failure is explained, recorded in the queue and skipped, and the batch goes on.
    func batchExport(_ job: ExportJob, file: URL, status: @escaping (String, Double) -> Void) async throws -> URL? {
        let engine = ExportEngine()
        do {
            return try await runExport(engine, job, options: {
                var o = RecoveryOptions()
                if let offer = ResumeCoordinator.match(job, in: resumeOffers) { o.resume = offer.journal }   // batches resume by themselves
                return o
            }(), unattended: true, status: status)
        } catch is CancellationError {
            throw CancellationError()            // Stop ends the whole batch; it isn't this file failing
        } catch {
            let report = (error as? ReportedFailure)?.report
                ?? FailureExplainer.explain(FailureClassifier.classify(error, context: FailureContext(sourceName: file.lastPathComponent)),
                                            facts: { var x = FailureExplainer.Facts(); x.sourceName = file.lastPathComponent; return x }())
            BatchFailures.reports.append(report)
            QueueStore.markFailed(file, failure: report.title, exportID: report.exportID)
            Log.error(.app, "Batch: \(file.lastPathComponent): \(report.title). \(report.simple)")
            return nil
        }
    }

    /// One file of a batch that can't even be opened or analyzed (missing index, unsupported, unreadable): explained,
    /// marked failed and skipped. Returns nil (skip this file) unless the batch was stopped.
    func batchSource<T>(_ file: URL, _ body: () async throws -> T) async throws -> T? {
        do { return try await body() } catch is CancellationError { throw CancellationError() } catch {
            var facts = FailureExplainer.Facts()
            facts.sourceName = file.lastPathComponent
            let report = FailureExplainer.explain(FailureClassifier.classify(error, context: FailureContext(stage: .decode, sourceName: file.lastPathComponent)), facts: facts)
            BatchFailures.reports.append(report)
            QueueStore.markFailed(file, failure: report.title, exportID: nil)
            Log.error(.app, "Batch: \(file.lastPathComponent): \(report.title). \(report.simple)")
            return nil
        }
    }

    func batchFailureNote() -> String {
        let n = BatchFailures.reports.count
        defer { if let last = BatchFailures.reports.last { renderFailure = last }; BatchFailures.reports = [] }
        return n == 0 ? "" : "; \(n) failed (see Activity and the export logs)"
    }

    func refreshResumeOffers() {
        let offers = ResumeCoordinator.scan()
        resumeOffers = offers
    }

    /// Saved progress whose source is the file open now (the Export sheet's resume row).
    var resumeOfferForOpenFile: ResumeOffer? {
        guard let d = descriptor else { return nil }
        return resumeOffers.first { $0.recipe?.source.url.standardizedFileURL == d.url.standardizedFileURL && !$0.report.failure.kind.isSource }
    }

    // MARK: The failure sheet's actions

    func perform(_ action: FailureAction, _ report: FailureReport) {
        let offer = resumeOffers.first { $0.id == report.exportID }
        switch action {
        case .resume, .retryLastStep, .saveAgain, .exportAnyway:
            if let offer { resume(offer) } else { renderFailure = nil; showExport = true }
        case .resumeLessMemory:
            if let offer { resume(offer) { $0.lessMemory = true } }
        case .saveWithoutDynamicMetadata:
            if let offer { resume(offer) { $0.skipDynamicMetadata = true } }
        case .resumeAnyway:
            if let offer { resume(offer) { $0.allowDifferentMac = true } }
        case .startOver:
            if let offer { startOver(offer) } else { renderFailure = nil; showExport = true }
        case .discard:
            if let offer { discard(offer) }
            renderFailure = nil
        case .saveElsewhere:
            guard let offer else { return }
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Save here"
            if p.runModal() == .OK, let folder = p.url { resume(offer, outputFolder: folder) }
        case .locateSource:
            guard let offer else { return }
            let p = NSOpenPanel(); p.canChooseFiles = true; p.prompt = "Use this file"
            p.message = "Find “\(offer.journal.sourceName)”"
            if p.runModal() == .OK, let file = p.url { resume(offer, source: file) }
        case .chooseScratch:
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Use this drive"
            if p.runModal() == .OK, let u = p.url {
                ScratchManager.shared.root = u.appendingPathComponent("Lumora Scratch")
                try? FileManager.default.createDirectory(at: ScratchManager.shared.root, withIntermediateDirectories: true)
                renderFailure = nil
                if let offer { moveSavedProgress(offer, to: ScratchManager.shared.root) } else { status = "Scratch drive changed; export again to use it" }
            }
        case .showFolder:
            if let path = report.failure.path ?? offer?.journal.outputPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .openPrivacySettings:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(u) }
        case .installTool:
            if let u = URL(string: "https://info-moed.github.io/Lumora/install/#encoders") { NSWorkspace.shared.open(u) }
        case .copyReport:
            copyDiagnosticReport(report)
        case .openLog:
            if let p = report.logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case .repairSource, .showDamage:
            renderFailure = nil
            showRepair = true
        case .chooseCodec, .resetSettings, .editEncoderOptions:
            renderFailure = nil
            showExport = true
            status = action == .resetSettings ? "Remove the custom encoder options in the Export sheet, then export again" : status
        case .restartMac, .quitOtherApps:
            renderFailure = nil
            status = action == .restartMac ? "Restart your Mac, then resume from Activity or the banner" : "Quit other apps, then resume"
        }
    }

    /// Saved progress follows the scratch drive the person picked ("Choose another scratch drive…" after the old one
    /// filled up): it moves there, keeps its resume offer, and stops taking room on the old drive.
    func moveSavedProgress(_ offer: ResumeOffer, to scratch: URL) {
        let id = offer.id
        let t = TaskCenter.shared.begin("Moving saved progress to the new scratch drive", symbol: "externaldrive")
        Task {
            let result = await Task.detached { Result { try CheckpointStore.move(id, toScratch: scratch) } }.value
            TaskCenter.shared.finish(t)
            refreshResumeOffers()
            switch result {
            case .success:
                status = "Scratch drive changed; the saved progress moved with it. Resume when you're ready."
                Log.notice(.storage, "Saved progress \(id) moved to \(scratch.path.displayPath)")
            case .failure(let e):
                status = "Scratch drive changed. The saved progress stays on the old drive (\(e.localizedDescription)); it still resumes from there."
                Log.warning(.storage, "Saved progress \(id) couldn't be moved: \(e.localizedDescription)")
            }
        }
    }

    /// The privacy-scrubbed report "Copy diagnostic report" puts on the clipboard. The source and output names are
    /// hidden whether or not saved progress exists (from its recipe, else from the export log's header).
    func diagnosticReportText(_ report: FailureReport) -> String {
        let offer = resumeOffers.first { $0.id == report.exportID }
        var names = DiagnosticScrub.Names()
        if let o = offer, let r = o.recipe { names = DiagnosticScrub.names(source: r.source.url, output: r.outputURL) }
        return DiagnosticReport.make(report, logURL: report.logPath.map { URL(fileURLWithPath: $0) }, journal: offer?.journal, names: names)
    }

    func copyDiagnosticReport(_ report: FailureReport) {
        let text = diagnosticReportText(report)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Diagnostic report copied (personal names and paths removed)"
    }

    /// Continues saved progress: only the missing parts are encoded. `outputFolder` or `source` override where the
    /// result goes ("Save to another folder…") or where the source now is ("Locate the file…").
    func resume(_ offer: ResumeOffer, outputFolder: URL? = nil, source: URL? = nil, adjust: (inout RecoveryOptions) -> Void = { _ in }) {
        if ActiveExports.contains(offer.id) {          // already resuming (the banner and the sheet both clicked)
            renderFailure = nil
            status = "“\(offer.journal.outputName)” is already being resumed"
            return
        }
        guard var job = offer.recipe?.job else {
            renderFailure = nil
            errorMessage = "The saved progress for “\(offer.journal.outputName)” can't be read any more. Export it again."
            return
        }
        if let outputFolder { job.outputURL = outputFolder.appendingPathComponent(job.outputURL.lastPathComponent) }
        if let source { job.descriptor.url = source }
        var o = RecoveryOptions(resume: offer.journal)
        adjust(&o)
        renderFailure = nil
        let options = o
        run("Resuming \(job.outputURL.lastPathComponent)") { [self] in
            let engine = ExportEngine()
            let started = Date()
            let url = try await runExport(engine, job, options: options) { label, value in
                Task { @MainActor in self.status = "Resuming: \(label)"; self.progress = value }
            }
            lastExportURL = url
            await packageExport(url, folder: url.deletingLastPathComponent(), job: job, startedAt: started)
            status = "Saved \(lastPackage?.video.lastPathComponent ?? url.lastPathComponent)"
        }
    }

    func startOver(_ offer: ResumeOffer) {
        guard let job = offer.recipe?.job else { discard(offer); return }
        discard(offer)
        renderFailure = nil
        run("Exporting \(job.outputURL.lastPathComponent)") { [self] in
            let engine = ExportEngine()
            let started = Date()
            let url = try await runExport(engine, job, options: RecoveryOptions()) { label, value in
                Task { @MainActor in self.status = label; self.progress = value }
            }
            lastExportURL = url
            await packageExport(url, folder: url.deletingLastPathComponent(), job: job, startedAt: started)
        }
    }

    /// Stop the running export; `keep` saves the finished part so it can resume later. A plain stop discards a new
    /// export's progress but keeps progress saved before (a resumed export); `discard` ("Stop and discard") removes
    /// that too.
    func stopExport(keepProgress keep: Bool, discard: Bool = false) {
        RenderSession.setStopIntent(keep ? .keep : (discard ? .discard : .stop))
        cancel()
    }

    func discard(_ offer: ResumeOffer) {
        CheckpointStore.discard(offer.id)
        resumeOffers.removeAll { $0.id == offer.id }
    }

    func discardAllSavedProgress() {
        for o in resumeOffers { CheckpointStore.discard(o.id) }
        resumeOffers = []
    }

    // MARK: Source health

    func checkSourceHealth(_ d: SourceDescriptor) async {
        guard d.kind != .rawSequence else { sourceHealth = nil; return }
        var h = await SourceIntegrity.quickCheck(d.url)
        if let damage = analysis?.damage, !damage.isEmpty {
            h.damage = damage
            if !h.problems.contains(where: { $0.kind == .damaged }), let first = damage.places.first {
                h.problems.append(SourceProblem(kind: .damaged, seconds: damage.seconds(first.start), detail: damage.summary))
            }
        }
        sourceHealth = h
        if !h.ok {
            Log.warning(.ingest, "\(d.url.lastPathComponent): \(h.summary(d.url.lastPathComponent))")
            status = h.summary(d.url.lastPathComponent)
        }
    }

    func fullSourceCheck() {
        guard let d = descriptor else { return }
        let url = d.url
        let t = TaskCenter.shared.begin("Checking every frame of \(url.lastPathComponent)", symbol: "checkmark.seal")
        Task {
            let h = await Task.detached { SourceIntegrity.fullScan(url, fps: d.fps) }.value
            TaskCenter.shared.finish(t)
            sourceHealth = h
            status = h.summary(url.lastPathComponent)
            // Exports of this file rebuild the frames the full check found (see RecoveryHooks.rebuildingDamagedFrames).
            if let found = h.damage, !found.isEmpty, descriptor?.url == url {
                var merged = analysis?.damage ?? DamageMap()
                merged.fps = found.fps
                for span in found.spans { merged.add(span) }
                merged.truncatedAtSeconds = merged.truncatedAtSeconds ?? found.truncatedAtSeconds
                analysis?.damage = merged
            }
        }
    }

    /// "Use the repaired copy": open it and keep the current look.
    func useRepairedCopy(_ url: URL) {
        if let p = selectedPreset { carriedGrade = (p.look, params) }
        showRepair = false
        open(url)
    }

    /// After opening a repaired copy, the look chosen for the damaged file is applied again.
    func applyCarriedGrade() {
        guard let g = carriedGrade else { return }
        carriedGrade = nil
        if let i = presets.firstIndex(where: { $0.look == g.look }) {
            presets[i].params = g.params
            selectedPresetID = presets[i].id
        }
    }
}

extension ResumeOffer {
    /// Why it stopped, in a few words for the banner.
    var reasonText: String {
        switch report.failure.kind {
        case .interruptedQuit: return "Lumora was quit"
        case .interruptedCrash: return "Lumora quit unexpectedly"
        case .interruptedRestart: return "your Mac restarted or lost power"
        case .interruptedShutdownAsleep: return "your Mac shut down while asleep"
        case .interruptedUnknown: return "Lumora stopped unexpectedly"
        case .canceled: return "you stopped it"
        default: return report.title.prefix(1).lowercased() + report.title.dropFirst()
        }
    }
}
