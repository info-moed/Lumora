import SwiftUI
import AppKit

/// "File check: OK", "Damaged: 2 frames at 0:01.9 — Repair a copy…", "Cut short: stops at 0:02.4 of 0:04.0".
struct SourceHealthSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let d = model.descriptor, let h = model.sourceHealth {
            SourceHealthRow(health: h, name: d.url.lastPathComponent,
                            fullCheck: { model.fullSourceCheck() }, repair: { model.showRepair = true })
        }
    }
}

struct SourceHealthRow: View {
    let health: SourceHealth
    let name: String
    var fullCheck: () -> Void = {}
    var repair: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: health.ok ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(health.ok ? Theme.pass : Theme.marginal)
            Text(health.summary(name)).font(Theme.body).lineLimit(2)
            Spacer(minLength: 6)
            if health.repairable { Button("Repair a copy…", action: repair).buttonStyle(.link) }
            if !health.full && health.ok { Button("Full check…", action: fullCheck).buttonStyle(.link).help("Decode every frame and list any damage") }
        }
        .font(Theme.note)
    }
}

/// What is wrong with the source, what a repair can and can't do, and the repair itself (always into a new file).
struct SourceRepairSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var progress = 0.0
    @State private var step = ""
    @State private var report: SourceRepair.Report?
    @State private var error: String?
    @AppStorage("damagedFrameMethod", store: Prefs.store) private var damagedFrameMethod = "recreate"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair a copy").font(Theme.heading(16))
            if let d = model.descriptor, let h = model.sourceHealth {
                let name = d.url.lastPathComponent
                ForEach(h.problems.filter { $0.kind != .mislabeled }) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.summary(name)).font(Theme.body.weight(.semibold))
                        Text(p.explanation(name)).font(Theme.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("In the repaired copy, frames that can't be decoded, and the frames that depend on them, are rebuilt by repeating the last good frame; every rebuilt frame is listed in the report, and every other frame is checked to be unchanged. Your original file is never changed.")
                    .font(Theme.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("When exporting this file as it is:", selection: $damagedFrameMethod) {
                    Text("Re-create damaged frames from the neighboring frames").tag("recreate")
                    Text("Repeat the previous good frame").tag("repeat")
                }
                .pickerStyle(.radioGroup).font(Theme.note)
                let dest = SourceRepair.destination(for: d.url, fallback: FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first)
                Text("Saves “\(dest.lastPathComponent)” in \(dest.deletingLastPathComponent().path.displayPath)").font(Theme.note)
                if running { ProgressView(value: progress) { Text(step).font(Theme.note) } }
                if let report {
                    Text(report.summary).font(Theme.body).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.output]) }
                        Spacer()
                        Button("Use the repaired copy") { model.useRepairedCopy(report.output); dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
                if let error { Text(error).font(Theme.body).foregroundStyle(Theme.fail).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if report == nil {
                        Button("Repair") { start(d.url, h, dest) }.buttonStyle(.borderedProminent).disabled(running || !h.repairable)
                    }
                }
            } else {
                Text("Open a video first.").font(Theme.body)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func start(_ url: URL, _ h: SourceHealth, _ dest: URL) {
        running = true
        error = nil
        Task {
            let result = await Task.detached { () -> Result<SourceRepair.Report, Error> in
                Result { try SourceRepair.repair(url, health: h, to: dest) { p, s in
                    Task { @MainActor in progress = p; step = s }
                } }
            }.value
            running = false
            switch result {
            case .success(let r):
                report = r
                Log.notice(.ingest, r.summary)
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}
