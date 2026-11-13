import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            PresetSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            if model.simpleMode {
                VStack(spacing: 0) { OptimizeBanner().padding([.horizontal, .top], 14); SimpleModeView() }
            } else {
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    OptimizeBanner()
                    ZStack {
                        Theme.surround
                        EDRViewer()
                            .overlay { NitsPickerOverlay() }
                            .overlay {
                                if model.descriptor == nil { EmptyStage() }
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if model.showScopes { ScopesView().frame(height: 200) }
                    SceneStrip().frame(height: 48)
                    TransportBar()
                }
                .padding(14)
                .background(Theme.surround)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                InspectorView().frame(width: 372).background(Theme.surround)
            }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.presentOpenPanel() } label: { Label("Open", systemImage: "plus.rectangle.on.folder") }
            }
            ToolbarItem {
                Button { model.paused.toggle() } label: {
                    Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.circle" : "pause.circle")
                }
                .help("Pauses rendering and encoding without losing work")
            }
            ToolbarItem { StopExportButton() }
            ToolbarItem {
                Button { openWindow(id: "airplay") } label: { Label("TV preview", systemImage: "airplayvideo") }
                    .disabled(model.descriptor == nil)
            }
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.simpleMode) {
                    Text("Simple").tag(true)
                    Text("Pro").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            ToolbarItemGroup {
                Picker("Display as", selection: $model.previewTarget) {
                    ForEach(OutputTarget.all, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(width: 170)
                ControlGroup {
                    Toggle(isOn: $model.splitCompare) { Label("Before / after", systemImage: "rectangle.split.2x1") }
                    Toggle(isOn: $model.falseColor) { Label("False color", systemImage: "paintpalette") }
                    Toggle(isOn: $model.nitsPicker) { Label("Nits picker", systemImage: "eyedropper") }
                    Toggle(isOn: $model.showScopes) { Label("Scopes", systemImage: "waveform.path.ecg") }
                }
                ActivityButton()
                Menu {
                    Button("Compare original and interpolated…") { model.prepareCompare(); openWindow(id: "compare") }
                    Button("Match to a reference release…") { model.matchToReference() }.disabled(model.selectedPreset == nil)
                    Button("HDR report") { model.showReport = true }.disabled(model.report == nil)
                    Divider()
                    Button("Export HDR still…") { model.exportStill() }.disabled(model.previewFrame == nil)
                    Menu("LUT") {
                        Button("Export .cube, 33 points") { model.exportLUT(size: 33) }
                        Button("Export .cube, 65 points") { model.exportLUT(size: 65) }
                    }
                    .disabled(model.selectedPreset == nil)
                    Button("Save look as preset…") { model.savePreset() }.disabled(model.selectedPreset == nil)
                    Button("Import preset…") { model.importPreset() }.disabled(model.presets.isEmpty)
                    Divider()
                    Button("Batch process a folder…") { model.batchProcess() }
                    Button("Estimate sizes for a folder…") { model.estimateFolder() }
                    Divider()
                    Button("Optimize for this Mac…") { openWindow(id: "optimize") }
                    Button("Preview on your TV (AirPlay)…") { openWindow(id: "airplay") }
                    Button("Picture regression set…") { openWindow(id: "regression") }
                    Button("Verify an archive folder…") { model.verifyArchiveFolder() }
                    if !QueueStore.pending.isEmpty { Button("Resume unfinished batch…") { model.resumePendingBatch() } }
                    Button("Model Lab") { openWindow(id: "models") }
                    Button("Encode monitor") { openWindow(id: "monitor") }
                    Button("Log") { openWindow(id: "logs") }
                    Button("UHD HDR library") { openWindow(id: "library") }
                } label: { Label("Tools", systemImage: "slider.horizontal.3") }
                Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.analysis == nil)
                    .keyboardShortcut("e")
            }
        }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showAdvisor) { AdvisorSheet() }
        .sheet(isPresented: $model.showReport) { ReportCardSheet() }
        .sheet(item: $model.renderFailure) { FailureSheet(report: $0) }         // export failures, in plain words
        .sheet(isPresented: $model.showRepair) { SourceRepairSheet() }
        .overlay(alignment: .top) { ResumeBanner().padding(.top, 8).padding(.horizontal, 60) }
        .task { model.refreshResumeOffers() }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("Show log") { openWindow(id: "logs"); model.errorMessage = nil }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first { model.open(u) }
            return true
        }
    }
}

private struct EmptyStage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("Drop a video to begin").font(Theme.heading(17))
            Text("Camera log, RAW, SDR or HDR. Lumora reads it once, tests the content, and builds looks for it.")
                .font(Theme.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Open a video…") { model.presentOpenPanel() }.buttonStyle(.borderedProminent)
        }
    }
}

struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let d = model.descriptor {
                Button { model.scrub(to: max(0, model.previewTime - 1 / d.fps)) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.scrub(to: min(d.durationSeconds, model.previewTime + 1 / d.fps)) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).keyboardShortcut(.rightArrow, modifiers: [])
                Text(timecode(model.previewTime, fps: d.fps)).font(Theme.body.monospacedDigit()).frame(width: 96, alignment: .leading)
            }
            if let p = model.progress { ProgressView(value: p).frame(width: 140).controlSize(.small) }
            Text(model.status).font(Theme.note).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(model.chip.description).font(Theme.note).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func timecode(_ t: Double, fps: Double) -> String {
        let f = Int((t * fps).rounded())
        let r = max(1, Int(fps.rounded()))
        return String(format: "%02d:%02d:%02d:%02d", f / (r * 3600), (f / (r * 60)) % 60, (f / r) % 60, f % r)
    }
}

struct PresetSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedPresetID) {
            if model.colorCandidates.count > 1 {
                Section {
                    ForEach(model.colorCandidates) { c in
                        Button { model.chooseColor(c) } label: {
                            HStack(spacing: 8) {
                                StatusDot(color: c == model.selectedColor ? Theme.signal : .secondary.opacity(0.4))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name).font(Theme.body).foregroundStyle(Theme.ink)
                                    Text("\(Int(c.confidence * 100))% likely").font(Theme.note).foregroundStyle(Theme.inkSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Read the signal as").font(Theme.note).foregroundStyle(Theme.inkSecondary)
                }
            }
            Section {
                ForEach(model.presets) { p in
                    VStack(alignment: .leading, spacing: 5) {
                        if let img = model.thumbnails[p.id] {
                            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        HStack {
                            Text(p.name).font(Theme.heading(12)).foregroundStyle(Theme.ink)
                            Spacer()
                            if p.recommended { StatusDot(color: Theme.signal).help("Recommended for this footage") }
                        }
                        Text(p.reason).font(Theme.note).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                    }
                    .padding(.vertical, 5)
                    .tag(p.id)
                }
            } header: {
                Text("Looks").font(Theme.note).foregroundStyle(Theme.inkSecondary)
            }
        }
        .listStyle(.sidebar)
    }
}

/// Click anywhere on the picture to read its graded brightness in nits.
struct NitsPickerOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if model.nitsPicker, let frame = model.previewFrame {
                let crop = model.descriptor?.crop ?? UniformBuilder.fullFrame
                let aspect = CGFloat(Float(frame.texture.width) * crop.z / (Float(frame.texture.height) * crop.w))
                let fit = geo.size.width / geo.size.height > aspect
                    ? CGSize(width: geo.size.height * aspect, height: geo.size.height)
                    : CGSize(width: geo.size.width, height: geo.size.width / aspect)
                let origin = CGPoint(x: (geo.size.width - fit.width) / 2, y: (geo.size.height - fit.height) / 2)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        let uv = SIMD2<Float>(Float((p.x - origin.x) / fit.width), Float((p.y - origin.y) / fit.height))
                        if uv.x >= 0, uv.y >= 0, uv.x <= 1, uv.y <= 1 { model.probe(at: uv) }
                    }
                if let text = model.probeReadout {
                    Text(text).font(.callout.monospacedDigit()).padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}
