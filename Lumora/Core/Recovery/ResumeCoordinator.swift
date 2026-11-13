import Foundation

/// Saved progress offered as "Resume export from 63%".
struct ResumeOffer: Identifiable, Hashable {
    var id: String { journal.exportID }
    var journal: ExportJournal
    var folder: URL
    var report: FailureReport
    var bytes: Int64

    static func == (a: ResumeOffer, b: ResumeOffer) -> Bool { a.id == b.id && a.journal.updated == b.journal.updated }
    func hash(into h: inout Hasher) { h.combine(id) }

    var percent: Int { Int((journal.progress * 100).rounded(.down)) }
    var savedDate: String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: journal.updated)
    }
    var recipe: ExportRecipe? { CheckpointStore.loadRecipe(folder) }
    /// The finished video is saved: only delivering it is left.
    var onlyDeliveryLeft: Bool { journal.finalFile != nil }
}

/// At launch (and after a failure), finds exports that stopped and works out why, from the journal, its heartbeat,
/// the boot session and crash reports.
enum ResumeCoordinator {
    /// Every scratch folder Lumora has used (saved progress stays on the drive it was made on).
    static func scan() -> [ResumeOffer] {
        CheckpointStore.knownRoots.flatMap { scan(root: $0) }.sorted { $0.journal.updated > $1.journal.updated }
    }

    static func scan(root: URL) -> [ResumeOffer] {
        CheckpointStore.prune(root: root, active: ActiveExports.all)
        var offers: [ResumeOffer] = []
        for (dir, j0) in CheckpointStore.all(root: root) {
            var j = j0
            if j.state == .finished || CheckpointStore.isRunningElsewhere(j) { continue }
            guard CheckpointStore.loadRecipe(dir) != nil else { continue }
            let report: FailureReport
            if j.state == .running || j.state == .interrupted || j.state == .joined || (j.state == .deliveryPending && j.failure == nil) {
                let kind = reason(j, dir: dir)
                var facts = FailureExplainer.Facts()
                facts.progress = j.progress
                facts.sourceName = j.sourceName
                facts.finishedVideoKept = j.finalFile != nil
                var f = RenderFailure(kind: kind, stage: .encode, message: "interrupted")
                if kind == .interruptedCrash, let s = CrashReports.summary(newerThan: (CheckpointStore.heartbeat(dir)?.time ?? j.updated).addingTimeInterval(-30)) {
                    f.chain = [s]
                }
                var r = FailureExplainer.explain(f, facts: facts)
                r.exportID = j.exportID
                r.logPath = j.logFile.map { RenderLog.folder.appendingPathComponent($0).path }
                r.progress = j.progress
                report = r
                j.state = .interrupted
                j.failure = r
                try? CheckpointStore.save(j, in: dir)
            } else if let r = j.failure {
                report = r
            } else {
                continue
            }
            offers.append(ResumeOffer(journal: j, folder: dir, report: report, bytes: CheckpointStore.size(dir)))
        }
        return offers
    }

    /// Why an export that was running isn't any more.
    static func reason(_ j: ExportJournal, dir: URL) -> RenderFailure.Kind {
        let hb = CheckpointStore.heartbeat(dir)
        let lastEvent = hb?.lastEvent ?? j.lastEvent
        if j.willTerminate || lastEvent == "quit" { return .interruptedQuit }
        let boot = SystemSnapshot.bootSessionUUID()
        let bootChanged = !(hb?.boot ?? j.bootSession).isEmpty && (hb?.boot ?? j.bootSession) != boot
        if bootChanged { return lastEvent == "sleep" || j.lastEvent == "sleep" ? .interruptedShutdownAsleep : .interruptedRestart }
        let since = (hb?.time ?? j.updated).addingTimeInterval(-30)
        if CrashReports.newest(newerThan: since) != nil { return .interruptedCrash }
        if (hb?.pressure ?? j.lastPressure) == .critical { return .outOfMemory }
        return .interruptedUnknown
    }

    /// Saved progress for this very job (same source, same settings), for the Export sheet's resume row.
    static func match(_ job: ExportJob, in offers: [ResumeOffer]) -> ResumeOffer? {
        let h = ExportRecipe(job).hash()
        return offers.first { $0.journal.recipeHash == h && $0.journal.outputPath == job.outputURL.path }
            ?? offers.first { $0.journal.recipeHash == h }
    }
}
