import SwiftUI
import AppKit

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title2.bold())
            Form {
                Picker("HDR format", selection: $model.delivery) {
                    ForEach(DeliveryFormat.allCases) { Text($0.displayName).tag($0) }
                }
                Text(model.delivery.plainEnglish).font(.caption).foregroundStyle(.secondary)
                if model.delivery.target.0 == .hdr10 {
                    Picker("Peak brightness", selection: $model.peakNits) {
                        Text("1000 nits (recommended)").tag(Float(1000))
                        Text("2000 nits").tag(Float(2000))
                        Text("4000 nits").tag(Float(4000))
                    }
                }
                Picker("Codec", selection: $model.codec) {
                    ForEach(Codec.allCases) { c in
                        Text(c.displayName + (c.available ? "" : " — not installed")).tag(c)
                    }
                }
                .onChange(of: model.codec) { _, c in
                    if !c.bitDepths.contains(model.bitDepth) { model.bitDepth = c.bitDepths[0] }
                    if !c.chromaFormats.contains(model.chroma) { model.chroma = c.chromaFormats[0] }
                }
                Text(model.codec.plainEnglish).font(.caption).foregroundStyle(.secondary)
                Picker("Bit depth", selection: $model.bitDepth) {
                    ForEach(model.codec.bitDepths, id: \.self) { Text("\($0)-bit").tag($0) }
                }
                Picker("Colour detail", selection: $model.chroma) {
                    ForEach(model.codec.chromaFormats, id: \.self) { Text($0.label).tag($0) }
                }
                if model.useTargetQuality && ![.prores422HQ, .prores4444XQ, .av2].contains(model.codec) {
                    LabeledContent("Quality", value: String(format: "VMAF %.1f target (%@)", model.qualityTarget.vmaf, model.qualityTarget.pool.rawValue.lowercased()))
                    Text(model.qualityTarget.plainEnglish).font(.caption).foregroundStyle(.secondary)
                } else if !model.codec.isHardware || model.codec == .hevc {
                    VStack(alignment: .leading) {
                        Text("Quality")
                        Slider(value: $model.quality, in: 0.3...1)
                    }
                }
                LabeledContent("Tuned for", value: model.contentKind.displayName)
            }
            .formStyle(.grouped)
            if model.interpolation.mode != .off {
                Toggle("Also export the original frame rate (same grade) to compare and choose", isOn: $model.alsoExportOriginalRate)
            }
            Text("Presets to export").font(.headline)
            List(model.presets, selection: $selected) { p in Text(p.name).tag(p.id) }
                .frame(height: 150)
            if let problem = validation { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Export Here"
                    if panel.runModal() == .OK, let folder = panel.url {
                        model.export(presetIDs: Array(selected), folder: folder)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || validation != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 680)
        .onAppear { if let id = model.selectedPresetID { selected = [id] } }
    }

    private var validation: String? {
        guard let p = model.presets.first, let a = model.analysis, let d = model.descriptor else { return nil }
        var job = ExportJob(descriptor: d, preset: p, analysis: a, delivery: model.delivery, codec: model.codec,
                            outputURL: URL(fileURLWithPath: "/tmp/x"))
        job.bitDepth = model.bitDepth
        job.chroma = model.chroma
        return ExportEngine.validate(job)
    }
}

struct AdvisorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var destination: FormatAdvisor.Destination = .youtube

    var body: some View {
        let advice = FormatAdvisor.advise(for: destination, source: model.descriptor, color: model.selectedColor,
                                          report: model.report)
        VStack(alignment: .leading, spacing: 14) {
            Text("Where is this video going?").font(.title2.bold())
            Picker("Destination", selection: $destination) {
                ForEach(FormatAdvisor.Destination.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Divider()
            Text(advice.headline).font(.title3.weight(.semibold))
            ForEach(advice.why, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) }
            if let also = advice.alsoMake { Label("Also make: \(also)", systemImage: "plus.circle").font(.callout) }
            ForEach(advice.watchOut, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Text("\(advice.delivery.displayName) · \(advice.codec.displayName) · \(advice.bitDepth)-bit"
                 + (advice.delivery.target.0 == .sdr ? "" : " · \(Int(advice.peakNits)) nits"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Use these settings") { model.apply(advice); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
    }
}

struct ReportCardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = model.report {
                Text(r.title).font(.title2.bold())
                Text(r.verdict.rawValue).font(.title3).foregroundStyle(.tint)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("Typical brightness"); Text("\(Int(r.medianNits)) nits") }
                    GridRow { Text("Bright highlights (99.9%)"); Text("\(Int(r.p999Nits)) nits") }
                    GridRow { Text("Estimated peak"); Text("\(Int(r.estimatedPeakNits)) nits") }
                    GridRow { Text("Picture above SDR white"); Text(String(format: "%.2f%%", r.shareAbove203 * 100)) }
                    GridRow { Text("Picture above 1000 nits"); Text(String(format: "%.3f%%", r.shareAbove1000 * 100)) }
                    GridRow { Text("Black floor"); Text(String(format: "%.3f nits", r.blackFloorNits)) }
                }
                .font(.callout)
                Divider()
                ForEach(r.findings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                if let rank = model.library.rank(r) { Label(rank, systemImage: "books.vertical").font(.callout) }
                Label(r.suggestion, systemImage: "wand.and.stars").font(.callout.weight(.medium))
                Text("Measured from luminance on a ~1K analysis grid; peaks are estimates.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Add to my library") {
                        try? model.library.add(HDRTitle(title: r.title, year: 0, edition: "My copy", hdrFormats: [r.format],
                                                        measuredP999Nits: Int(r.p999Nits),
                                                        rating: r.verdict == .vivid ? .great : (r.verdict == .balanced ? .average : .dim),
                                                        reasons: r.findings, sources: []))
                    }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: HDRLibrary
    @State private var filter: HDRTitle.Rating?
    @State private var urlText = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All").tag(HDRTitle.Rating?.none)
                    ForEach(HDRTitle.Rating.allCases, id: \.self) { Text($0.rawValue).tag(HDRTitle.Rating?.some($0)) }
                }
                .frame(width: 260)
                Spacer()
                TextField("Community library URL (JSON)", text: $urlText).frame(width: 340)
                Button("Sync") {
                    library.communityURL = URL(string: urlText)
                    Task {
                        do { try await library.syncCommunity(); message = "\(library.titles.count) titles" }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if library.titles.isEmpty {
                ContentUnavailableView("Your library is empty",
                                       systemImage: "books.vertical",
                                       description: Text("Measure your own files with the HDR Report, or sync a community-maintained library. Lumora ships without ratings of its own so every entry is backed by real measurements and sources."))
            } else {
                Table(library.titles.filter { filter == nil || $0.rating == filter }) {
                    TableColumn("Title") { Text("\($0.title)" + ($0.year > 0 ? " (\($0.year))" : "")) }
                    TableColumn("Rating") { Text($0.rating.rawValue) }
                    TableColumn("Formats") { Text($0.hdrFormats.joined(separator: ", ")) }
                    TableColumn("MaxCLL") { Text($0.maxCLL.map { "\($0)" } ?? "—") }
                    TableColumn("Highlights") { Text($0.measuredP999Nits.map { "\($0) nits" } ?? "—") }
                    TableColumn("Why") { Text($0.reasons.joined(separator: " · ")).lineLimit(2) }
                }
            }
        }
        .padding()
        .frame(minWidth: 900, minHeight: 500)
        .onAppear { urlText = library.communityURL?.absoluteString ?? "" }
    }
}
