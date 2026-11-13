import SwiftUI
import AppKit

/// Every export's log: when, which file, how it ended. Open it, show it in Finder, or copy a privacy-scrubbed
/// diagnostic report to paste into an issue.
struct ExportLogsView: View {
    @State private var entries: [RenderLog.Entry] = []
    @State private var selection: RenderLog.Entry.ID?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Export logs").font(Theme.heading(15))
                Spacer()
                Text(RenderLog.folder.path.displayPath).font(Theme.note).foregroundStyle(.secondary)
                Button("Open folder") { NSWorkspace.shared.open(RenderLog.folder) }
            }
            Table(entries, selection: $selection) {
                TableColumn("Date") { e in Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute()) }.width(min: 110, ideal: 130)
                TableColumn("Output") { e in Text(URL(fileURLWithPath: e.output).lastPathComponent).lineLimit(1) }
                TableColumn("Result") { e in
                    Text(e.result).foregroundStyle(e.result == "finished" ? Theme.pass : (e.result == "failed" ? Theme.fail : Theme.marginal))
                }.width(80)
                TableColumn("Size") { e in Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)) }.width(70)
            }
            HStack {
                Button("Open") { selected.map { NSWorkspace.shared.open($0.url) } }.disabled(selected == nil)
                Button("Show in Finder") { selected.map { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) } }.disabled(selected == nil)
                Button("Copy diagnostic report") { if let e = selected { copyReport(e) } }.disabled(selected == nil)
                Spacer()
                Text(note).font(Theme.note).foregroundStyle(.secondary)
                Button("Refresh") { load() }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 360)
        .onAppear(perform: load)
    }

    private var selected: RenderLog.Entry? { entries.first { $0.id == selection } }

    private func load() { entries = RenderLog.entries() }

    private func copyReport(_ e: RenderLog.Entry) {
        let id = (RenderLog.tail(e.url, lines: 4000).first { $0.hasPrefix("Export ID: ") }).map { String($0.dropFirst(11)) }
        let saved = id.flatMap { id in CheckpointStore.knownRoots.flatMap { CheckpointStore.all(root: $0) }.first { $0.journal.exportID == id } }
        let report = saved?.journal.failure
            ?? FailureReport(failure: RenderFailure(kind: .unknown, stage: .finished, message: e.result), title: "Export log (\(e.result))",
                             simple: "This report was made from the export log.", means: "", actions: [], proLine: "")
        var names = DiagnosticScrub.Names(source: [], output: [URL(fileURLWithPath: e.output).lastPathComponent,
                                                               URL(fileURLWithPath: e.output).deletingPathExtension().lastPathComponent])
        if let r = saved.flatMap({ CheckpointStore.loadRecipe($0.dir) }) {
            names = DiagnosticScrub.names(source: r.source.url, output: r.outputURL)
        }
        let text = DiagnosticReport.make(report, logURL: e.url, journal: saved?.journal, names: names)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Copied (personal names and paths removed)"
    }
}

/// "Export logs…" for the Log window.
struct ExportLogsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Export logs…") { openWindow(id: "exportLogs") } }
}
