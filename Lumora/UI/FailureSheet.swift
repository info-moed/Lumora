import SwiftUI
import AppKit

/// Why an export failed, in plain words: what happened, what it means for your file, and one or two things to do.
/// The technical details (stage, tool, command, codes, last error lines, log) are one click away.
struct FailureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: FailureReport
    /// Screenshots render the sheet without a model action attached.
    var onAction: ((FailureAction) -> Void)?
    var simple: Bool?

    @State private var showDetails = false

    private var isSimple: Bool { simple ?? model.simpleMode }

    var body: some View { FailureCard(report: report, simple: isSimple, showDetails: $showDetails, onAction: act, onClose: { dismiss() }) }

    private func act(_ a: FailureAction) {
        if let onAction { onAction(a); return }
        dismiss()
        model.perform(a, report)
    }
}

/// The sheet's content (also rendered offscreen for the documentation screenshots).
struct FailureCard: View {
    let report: FailureReport
    let simple: Bool
    @Binding var showDetails: Bool
    var onAction: (FailureAction) -> Void
    var onClose: () -> Void

    private var primary: [FailureAction] { Array(report.actions.prefix(simple ? 2 : 3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.title).font(Theme.heading(16))
                    Text(report.simple).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What this means for your file").font(Theme.note.weight(.semibold)).foregroundStyle(.secondary)
                Text(report.means).font(Theme.body).fixedSize(horizontal: false, vertical: true)
            }
            if !simple {
                Text(report.proLine).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(report.technical.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let log = report.logPath {
                        HStack {
                            Text("Export log: \(log.displayPath)").font(.system(size: 10.5, design: .monospaced))
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)]) }
                                .buttonStyle(.link).font(Theme.note)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                HStack {
                    Text("Technical details").font(Theme.note)
                    Spacer()
                    if !primary.contains(.copyReport) {
                        Button("Copy diagnostic report") { onAction(.copyReport) }.buttonStyle(.link).font(Theme.note)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
                ForEach(Array(primary.enumerated().reversed()), id: \.offset) { i, a in
                    if i == 0 {
                        Button(a.label(report)) { onAction(a) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        Button(a.label(report)) { onAction(a) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private var icon: String {
        let k = report.failure.kind
        if k == .canceled { return "stop.circle" }
        if k.isInterruption { return "arrow.clockwise.circle" }
        if k.isSource { return "film.stack" }
        if [.diskFull, .outputDriveGone, .scratchDriveGone].contains(k) { return "externaldrive.badge.exclamationmark" }
        return "exclamationmark.triangle"
    }

    private var tint: Color {
        let k = report.failure.kind
        return k == .canceled || k.isInterruption ? Theme.signal : (k == .unknown ? Theme.marginal : Theme.fail)
    }
}

/// "Stop" for a running export. Simple mode asks whether to keep the finished part.
struct StopExportButton: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        if model.progress != nil {
            Button { if model.simpleMode { confirm = true } else { model.stopExport(keepProgress: NSEvent.modifierFlags.contains(.option)) } } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .help(model.simpleMode ? "Stop the export" : "Stop the export (Option-click keeps the finished part so it can resume)")
            .confirmationDialog("Stop the export?", isPresented: $confirm) {
                Button("Stop and keep progress") { model.stopExport(keepProgress: true) }
                Button("Stop and discard", role: .destructive) { model.stopExport(keepProgress: false, discard: true) }
                Button("Keep exporting", role: .cancel) {}
            } message: {
                Text("Keeping the progress lets you resume later without encoding the finished part again. It stays on the scratch drive until you resume or discard it.")
            }
        }
    }
}
