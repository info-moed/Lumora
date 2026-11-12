import SwiftUI
import AppKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case source = "Source", look = "Look", motion = "Motion", enhance = "Enhance", deliver = "Deliver"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .source: return "film"
        case .look: return "camera.aperture"
        case .motion: return "wind"
        case .enhance: return "arrow.up.left.and.arrow.down.right"
        case .deliver: return "shippingbox"
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    /// The tab a new inspector opens on (documentation screenshots set it; the app always starts on Source).
    static var defaultTab: InspectorTab = .source
    @State private var tab: InspectorTab = InspectorView.defaultTab

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 15, weight: .medium))
                            Text(t.rawValue).font(.system(size: 9, weight: .medium))
                        }
                        .frame(width: 54, height: 48)
                        .foregroundStyle(tab == t ? Theme.signal : .secondary)
                        .background(tab == t ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(t.rawValue)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(Theme.rail)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .source: SourcePanel()
                    case .look: LookPanel()
                    case .motion: InterpolationSection()
                    case .enhance: UpscaleSection()
                    case .deliver: DeliverPanel()
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .onChange(of: model.params) { model.renderToken += 1 }
    }
}

struct SourcePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let d = model.descriptor {
            InspectorSection(title: d.url.lastPathComponent) {
                Text(d.summary).font(Theme.body).foregroundStyle(.secondary)
                if let c = model.selectedColor {
                    HStack { Text("Read as").font(Theme.body); Spacer(); Text(c.name).font(Theme.body) }
                    if let n = c.note { Text(n).font(Theme.note).foregroundStyle(Theme.marginal) }
                }
                if let a = model.analysis {
                    HStack(spacing: 18) {
                        Metric(value: "\(a.scenes.count)", caption: "scenes")
                        Metric(value: "\(a.transitions.count)", caption: "fades")
                        Metric(value: String(format: "%.0f", d.durationSeconds / 60), unit: "min", caption: "length")
                    }
                }
            }
            ContentCard()
            InspectorSection(title: "Picture") {
                Toggle("Remove black bars", isOn: Binding(get: { model.removeBlackBars }, set: { model.setRemoveBlackBars($0) }))
                if model.detectedCrop != UniformBuilder.fullFrame {
                    Text("Picture area \(d.outputWidth)×\(d.outputHeight)").font(Theme.note).foregroundStyle(.secondary)
                }
                Picker("Scan", selection: Binding(get: { d.scanFix }, set: { model.setScanFix($0) })) {
                    ForEach(ScanFix.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if d.suggestedScanFix != .none {
                    Text("Detected: \(d.suggestedScanFix.displayName.lowercased()).").font(Theme.note).foregroundStyle(.secondary)
                }
            }
            StorageCard()
        } else {
            InspectorSection(title: "No video open") {
                Text("Drop a video, a camera RAW file, or a folder of DNGs onto the window.").font(Theme.body).foregroundStyle(.secondary)
                Button("Open…") { model.presentOpenPanel() }
            }
        }
    }
}

struct ContentCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Content", trailing: model.contentProfile.map { "detected \(Int($0.confidence * 100))%" }) {
            Picker("Content type", selection: $model.contentKind) {
                ForEach(ContentKind.allCases) { k in Label(k.displayName, systemImage: k.symbol).tag(k) }
            }
            .labelsHidden()
            Text(ContentTuning.preset(model.contentKind).summary).font(Theme.note).foregroundStyle(.secondary)
            if let p = model.contentProfile, p.kind == model.contentKind {
                ForEach(p.evidence, id: \.self) { e in
                    Label(e, systemImage: "checkmark").font(Theme.note).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StorageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let plan = model.storagePlan {
            InspectorSection(title: "Storage") {
                HStack(alignment: .top, spacing: 18) {
                    Metric(value: plan.source?.measuredReadMBps.map { String(format: "%.0f", $0) } ?? "–", unit: "MB/s",
                           caption: plan.source?.kindDescription ?? "Source")
                    Metric(value: String(format: "%.0f", plan.sourceBitrateMBps), unit: "MB/s", caption: "file needs")
                }
                Text(plan.strategy.rawValue).font(Theme.body)
                Text(plan.explanation).font(Theme.note).foregroundStyle(.secondary)
                if model.proxyDescriptor != nil {
                    Label("Scrubbing from the SSD proxy", systemImage: "bolt.horizontal").font(Theme.note).foregroundStyle(Theme.pass)
                }
                if let s = plan.scratch {
                    Text("Temp and intermediates: \(s.name) (\(s.kindDescription), \(ByteCountFormatter.string(fromByteCount: s.freeBytes, countStyle: .file)) free)")
                        .font(Theme.note).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LookPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let p = model.selectedPreset {
            let base = p.look.params
            InspectorSection(title: p.look.displayName, trailing: p.color.name) {
                ParamSlider(label: "Exposure", value: $model.params.exposureStops, range: -3...3, defaultValue: 0, unit: "stops")
                ParamSlider(label: "Brightness", value: $model.params.midGreyStops, range: -1...1, defaultValue: base.midGreyStops, unit: "stops")
                ParamSlider(label: "Contrast", value: $model.params.contrast, range: 0.7...1.5, defaultValue: base.contrast)
                ParamSlider(label: "Punch", value: $model.params.localContrast, range: 0...0.8, defaultValue: base.localContrast)
                ParamSlider(label: "Halo protection", value: $model.params.edgeProtection, range: 0...1, defaultValue: 0.5)
                ParamSlider(label: "Shadow depth", value: $model.params.toe, range: 0...1, defaultValue: base.toe)
                ParamSlider(label: "Highlight snap", value: $model.params.shoulder, range: 1...4, defaultValue: base.shoulder)
                ParamSlider(label: "Highlight softening", value: $model.params.highlightDesat, range: 0...1, defaultValue: base.highlightDesat)
            }
            InspectorSection(title: "Colour") {
                ParamSlider(label: "Saturation", value: $model.params.saturation, range: 0.6...1.4, defaultValue: base.saturation)
                ParamSlider(label: "Vibrance", value: $model.params.vibrance, range: 0...1, defaultValue: base.vibrance)
                ParamSlider(label: "Skin protection", value: $model.params.skinProtect, range: 0...1, defaultValue: base.skinProtect)
                ParamSlider(label: "Warmth", value: $model.params.temperature, range: -1...1, defaultValue: 0)
                ParamSlider(label: "Tint", value: $model.params.tint, range: -1...1, defaultValue: 0)
            }
            InspectorSection(title: "Clean-up and HDR") {
                ParamSlider(label: "Deband", value: $model.params.deband, range: 0...1, defaultValue: 0)
                ParamSlider(label: "Highlight rebuild", value: $model.params.highlightExpansion, range: 0...8, defaultValue: base.highlightExpansion)
                Toggle("Rebuild highlights of HDR sources too", isOn: $model.params.expandHDRSources)
                Toggle("Keep the original look (no regrade)", isOn: $model.params.passthrough)
                Button("Save changes to this preset") { model.commitParams() }
            }
            if let r = model.matchReport {
                InspectorSection(title: "Matched to reference") {
                    Text(r.summary).font(Theme.note)
                    ForEach(r.bands, id: \.self) { b in
                        HStack {
                            Text(b.name).font(Theme.note)
                            Spacer()
                            Text(String(format: "%+.2f → %+.2f", b.beforeStops, b.afterStops)).font(Theme.note.monospacedDigit())
                        }
                    }
                    Button("Remove match") { model.clearMatch() }
                }
            }
        } else {
            InspectorSection(title: "Look") { Text("Pick a preset on the left.").font(Theme.body).foregroundStyle(.secondary) }
        }
    }
}

struct DeliverPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let supported = ![.prores422HQ, .prores4444XQ, .av2].contains(model.codec)
        ForecastSection()
        InspectorSection(title: "Quality", trailing: model.deliversHDR ? "HDR delivery" : "SDR delivery") {
            Toggle("Encode to a quality target", isOn: $model.useTargetQuality).disabled(!supported)
            if model.useTargetQuality && supported {
                Picker("Standard", selection: Binding(get: { model.qualityProfile.name },
                                                       set: { n in if let p = QualityProfile.presets(hdr: model.deliversHDR).first(where: { $0.name == n }) { model.qualityProfile = p } })) {
                    ForEach(QualityProfile.presets(hdr: model.deliversHDR)) { Text($0.name).tag($0.name) }
                }
                Text(model.qualityProfile.summary).font(Theme.note).foregroundStyle(.secondary)
                MetricRulesView()
                Stepper("Worst frames may dip \(Int(model.qualityTarget.floorMargin)) below the search target",
                        value: $model.qualityTarget.floorMargin, in: 1...8)
                Toggle("Re-encode stretches that dip below target", isOn: $model.qualityTarget.fixDips)
                Toggle("Fast validation (4K scored at 1080p, every 2nd frame)", isOn: $model.qualityTarget.fastValidation)
                ForEach(model.qualityProfile.effective().notes, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").font(Theme.note).foregroundStyle(Theme.marginal)
                }
                Text("Scores compare each encode to Lumora's lossless render of your graded, interpolated master. Everything runs on this Mac; nothing is written to disk.")
                    .font(Theme.note).foregroundStyle(.secondary)
            } else if !supported {
                Text("\(model.codec.displayName) doesn't use a quality target (ProRes is near-lossless; AV2 can't be decoded for scoring yet).")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
        }
        TimeQualitySection()
        DisplayTargetSection()
        PackageSection()
        if model.codec == .av1 || model.codec == .av1Pro {
            InspectorSection(title: "Film texture") {
                Picker("Restore film texture", selection: $model.filmTexture) {
                    ForEach(FilmTexture.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.filmTexture != .off {
                    ParamSlider(label: "Strength", value: $model.filmTextureStrength, range: 0.3...2, defaultValue: 1)
                }
                Text("Adds organic grain to over-processed or grain-scrubbed transfers. Stored as a few bytes of AV1 grain data and re-created by the player, so it costs no bitrate. Quality checks score the picture without it.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
        }
        InspectorSection(title: "Format") {
            Text("\(model.delivery.displayName), \(model.codec.displayName)").font(Theme.body)
            Text("\(model.bitDepth)-bit \(model.chroma.label)" + (model.delivery.target.0 == .hdr10 ? ", \(Int(model.peakNits)) nits" : ""))
                .font(Theme.note).foregroundStyle(.secondary)
            if let d = model.descriptor, let p = model.selectedPreset {
                switch DolbyVisionRetimer.decide(source: d, look: p.look, passthrough: model.params.passthrough, codec: model.codec, delivery: model.delivery) {
                case .retimeOriginal:
                    Label("Keeps the film's original Dolby Vision (retimed to the new frames)", systemImage: "checkmark.seal").font(Theme.note).foregroundStyle(Theme.pass)
                case .generateNew(let why):
                    Label("New Dolby Vision metadata: \(why)", systemImage: "info.circle").font(Theme.note).foregroundStyle(.secondary)
                case .none:
                    EmptyView()
                }
            }
            HStack {
                Button("What should I export?") { model.showAdvisor = true }
                Spacer()
                Button("Export…") { model.showExport = true }.keyboardShortcut("e").buttonStyle(.borderedProminent)
                    .disabled(model.analysis == nil)
            }
            Button("Open encode monitor") { openWindow(id: "monitor") }.buttonStyle(.link)
        }
    }
}

struct InterpolationSection: View {
    @Environment(AppModel.self) private var model
    @State private var choice = "off"

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Frame interpolation") {
            Picker("Frame rate", selection: $choice) {
                Text("Off").tag("off")
                Text("2× smoother").tag("x2")
                Text("4× smoother").tag("x4")
                Text("Exactly 60 fps").tag("60")
                Text("59.94 fps").tag("5994")
                Text("120 fps").tag("120")
                Text("Slow motion 2×").tag("slo2")
                Text("Slow motion 4×").tag("slo4")
                Text("Slow motion 8×").tag("slo8")
            }
            .onChange(of: choice) { _, c in
                switch c {
                case "x2": model.interpolation.mode = .multiply(2)
                case "x4": model.interpolation.mode = .multiply(4)
                case "60": model.interpolation.mode = .targetFPS(num: 60, den: 1)
                case "5994": model.interpolation.mode = .targetFPS(num: 60000, den: 1001)
                case "120": model.interpolation.mode = .targetFPS(num: 120, den: 1)
                case "slo2": model.interpolation.mode = .slowMotion(factor: 2)
                case "slo4": model.interpolation.mode = .slowMotion(factor: 4)
                case "slo8": model.interpolation.mode = .slowMotion(factor: 8)
                default: model.interpolation.mode = .off
                }
            }
            let specs = InterpolationModelSpec.all()
            Picker("Model", selection: $model.interpolation.primaryModelID) {
                ForEach(specs.filter(\.isInstalled)) { s in Text(s.displayName).tag(s.id) }
                if !specs.contains(where: \.isInstalled) { Text("No models installed — open Model Lab").tag(model.interpolation.primaryModelID) }
            }
            Picker("Intelligence", selection: $model.interpolation.intelligence) {
                ForEach(MotionIntelligence.allCases) { Text($0.rawValue).tag($0) }
            }
            Text(model.interpolation.intelligence.explanation).font(Theme.note).foregroundStyle(.secondary)
            if model.interpolation.intelligence != .eachFrame {
                HStack {
                    Text("Confidence").font(Theme.body)
                    Slider(value: $model.interpolation.confidence, in: 0.90...0.995, step: 0.005)
                    Text("\(String(format: "%.1f", model.interpolation.confidence * 100))%").font(Theme.body.monospacedDigit()).frame(width: 52)
                }
                Button(model.motionMap == nil ? "Build motion map" : "Rebuild motion map") { model.buildMotionMap() }
                    .disabled(model.analysis == nil || choice == "off")
                if let map = model.motionMap { MotionMapSummary(map: map) }
            }
            Toggle("Grain-aware (de-grain, interpolate, re-grain)", isOn: $model.interpolation.grainAware)
            Toggle("Check for flicker between generated frames", isOn: $model.interpolation.flickerCheck)
            Toggle("Find and fix artifacts", isOn: $model.interpolation.artifactRepair)
            Toggle("Smooth repeated frames (animation)", isOn: $model.interpolation.smoothDuplicates)
            if model.interpolation.artifactRepair {
                Picker("Repair model", selection: Binding(get: { model.interpolation.repairModelID ?? "" },
                                                          set: { model.interpolation.repairModelID = $0.isEmpty ? nil : $0 })) {
                    Text("Patch only").tag("")
                    ForEach(specs) { s in Text(s.displayName).tag(s.id) }
                }
                ParamSlider(label: "Artifact strictness", value: $model.interpolation.sensitivity, range: 0...1,
                            defaultValue: ContentTuning.preset(model.contentKind).qcSensitivity)
            }
            Text("Never blends across cuts. Fades and dissolves are cross-faded instead of warped. Works on the original 10/12-bit HDR or log signal.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Scan for interpolation problems") { model.scanInterpolation() }
                .disabled(model.analysis == nil || choice == "off")
            if !model.qcEvents.isEmpty {
                DisclosureGroup("\(model.qcEvents.filter { $0.action != .accepted }.count) frames repaired") {
                    ForEach(model.qcEvents.filter { $0.action != .accepted }.prefix(200)) { e in
                        HStack {
                            Text("Frame \(e.outputIndex)").monospacedDigit()
                            Spacer()
                            Text(e.action.rawValue).font(.caption)
                            Text("\(Int(e.badFraction * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}



struct UpscaleSection: View {
    @Environment(AppModel.self) private var model
    @State private var engine = "off"
    @State private var height = 2160

    var body: some View {
        InspectorSection(title: "Upscaling") {
            Picker("Engine", selection: $engine) {
                Text("Off").tag("off")
                Text("MetalFX (built in, fast)").tag("metalfx")
                ForEach(UpscaleModelSpec.all()) { s in
                    Text(s.displayName + (s.isInstalled ? "" : " (not installed)")).tag(s.id)
                }
            }
            Picker("Output height", selection: $height) {
                Text("1080p").tag(1080)
                Text("1440p").tag(1440)
                Text("4K (2160p)").tag(2160)
                Text("8K (4320p)").tag(4320)
                Text("12K (6480p)").tag(6480)
            }
            .disabled(engine == "off")
            Text("Runs on the original log / HDR signal before grading, after black bars are removed.")
                .font(.caption).foregroundStyle(.secondary)
            if let s = model.suggestedUpscaleModel, let spec = UpscaleModelSpec.all().first(where: { $0.id == s }) {
                Text("Suggested for \(model.contentKind.displayName.lowercased()): \(spec.displayName)")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
        }
        .onChange(of: engine) { update() }
        .onChange(of: height) { update() }
    }

    private func update() {
        switch engine {
        case "off": model.upscale = .off
        case "metalfx": model.upscale = .metalFX(targetHeight: height)
        default: model.upscale = .model(id: engine, targetHeight: height)
        }
    }
}


/// "How long are you willing to wait?" — the planner picks the preset and extras that fit, and tells you
/// what a bit more time would buy.
struct TimeQualitySection: View {
    @Environment(AppModel.self) private var model

    private let budgetStops: [Double] = [0.25, 0.5, 1, 2, 4, 8, 12, 24, 48]

    var body: some View {
        @Bindable var model = model
        if let plan = model.currentPlan() {
            let recipe = EncodeRecipes.recipe(codec: model.codec, kind: model.contentKind)
            InspectorSection(title: "Time and quality", trailing: plan.measured ? "measured on this Mac" : "estimated") {
                Picker("How much time", selection: $model.planMode) {
                    ForEach(PlanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.planMode.explanation).font(Theme.note).foregroundStyle(.secondary)
                if model.planMode == .budget {
                    HStack {
                        Text("Finish within").font(Theme.body)
                        Spacer()
                        Text(EncodePlanner.duration(model.budgetHours * 3600)).font(Theme.body.monospacedDigit())
                    }
                    Slider(value: Binding(get: { Double(budgetStops.firstIndex { $0 >= model.budgetHours } ?? budgetStops.count - 1) },
                                          set: { model.budgetHours = budgetStops[Int($0.rounded())] }),
                           in: 0...Double(budgetStops.count - 1), step: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Metric(value: EncodePlanner.duration(plan.seconds), caption: "about, on this Mac")
                    Metric(value: "\(Int((plan.saving * 100).rounded()))%", caption: "smaller than fastest")
                }
                Text(plan.headline).font(Theme.heading(12))
                Text(recipe.summary).font(Theme.note).foregroundStyle(.secondary)

                if let u = plan.upgrade, !model.dismissedUpgrades.contains(u.key) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("With about \(EncodePlanner.duration(u.extraSeconds)) more, this file would be ≈\(Int((u.smallerFraction * 100).rounded()))% smaller at the same quality — or ≈+\(String(format: "%.1f", u.vmafGain)) VMAF at the same size (\(u.label)).")
                            .font(Theme.note)
                        HStack {
                            Button("Use the extra time") { model.applyUpgrade(u) }
                            Button("Dismiss") { model.dismissedUpgrades.insert(u.key) }.buttonStyle(.link)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Theme.signal.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }

                if !plan.options.isEmpty {
                    Text("Extras").font(Theme.heading(11)).padding(.top, 4)
                    ForEach(plan.options) { o in
                        let auto = plan.enabled.contains(o.id)
                        let manual = model.optionOverrides[o.id]
                        Toggle(isOn: Binding(get: { manual ?? auto },
                                             set: { model.optionOverrides[o.id] = $0; model.planVersion += 1 })) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(o.title).font(Theme.body)
                                    if manual != nil { Text("your choice").font(Theme.note).foregroundStyle(Theme.signal) }
                                }
                                Text(tag(o)).font(Theme.note).foregroundStyle(.secondary)
                            }
                        }
                        .help(o.detail + "\n" + o.args.joined(separator: " "))
                    }
                    if !model.optionOverrides.isEmpty {
                        Button("Let Lumora choose the extras again") { model.optionOverrides = [:]; model.planVersion += 1 }.buttonStyle(.link)
                    }
                }
                ForEach(plan.notes, id: \.self) { Text($0).font(Theme.note).foregroundStyle(.secondary) }
                if !model.codec.isHardware {
                    Button(plan.measured ? "Measure again on this Mac" : "Measure on this Mac") { model.measureOnThisMac() }
                        .help("Encodes two short samples of this file at four presets and scores them, so times and gains are real.")
                }
            }
        }
    }

    private func tag(_ o: EncodeOption) -> String {
        var parts: [String] = []
        if o.visualOnly { parts.append("for the eye") }
        if o.vmafSaving > 0 { parts.append("≈\(Int((o.vmafSaving * 100).rounded()))% smaller") }
        if o.speedCost > 1.005 { parts.append("+\(Int(((o.speedCost - 1) * 100).rounded()))% time") } else { parts.append("free") }
        if o.conflictsWithVMAF { parts.append("not judged by VMAF") }
        return parts.joined(separator: ", ")
    }
}


/// One row per metric: what it checks, whether it drives the search, must pass, or is only reported.
struct MetricRulesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            ForEach($model.qualityProfile.rules) { $rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(color: rule.metric.isAvailable ? (rule.role == .off ? .secondary.opacity(0.4) : Theme.pass) : Theme.fail)
                        Text(rule.metric.displayName).font(Theme.body.weight(.medium))
                        if rule.metric.hdrAware {
                            Text("HDR").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Theme.signal.opacity(0.18), in: Capsule())
                        }
                        Spacer()
                        Picker("", selection: $rule.role) { ForEach(MetricRole.allCases) { Text($0.rawValue).tag($0) } }
                            .labelsHidden().frame(width: 104).controlSize(.small)
                    }
                    if rule.role != .off {
                        HStack {
                            Text(rule.metric.higherIsBetter ? "at least" : "at most").font(Theme.note).foregroundStyle(.secondary)
                            TextField("", value: $rule.threshold, format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 60).textFieldStyle(.roundedBorder).controlSize(.small)
                            Text(rule.metric.unit).font(Theme.note).foregroundStyle(.secondary)
                            Toggle("worst 5%", isOn: $rule.useWorstFrames).toggleStyle(.checkbox).controlSize(.small)
                        }
                    }
                    Text(rule.metric.isAvailable ? rule.metric.plainEnglish : "Not installed: \(rule.metric.source)")
                        .font(Theme.note).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(.vertical, 2)
            }
        }
    }
}


/// The one line people want before pressing Export.
struct ForecastSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorSection(title: "Result", trailing: model.currentForecast()?.method.rawValue) {
            if let f = model.currentForecast() {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("≈" + SizeForecast.gb(f.mid)).font(Theme.figure(30))
                    Text("\(SizeForecast.gb(f.low))–\(SizeForecast.gb(f.high))").font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                }
                let pct = Int((f.savingFraction * 100).rounded())
                Text(pct > 0 ? "\(pct)% smaller than the \(SizeForecast.gb(f.sourceBytes)) source" : "about \(SizeForecast.gb(f.mid - f.sourceBytes)) larger than the source")
                    .font(Theme.body)
                HStack(spacing: 14) {
                    Label(qualityLine, systemImage: "eye").font(Theme.note)
                    if let p = model.currentPlan(), !model.codec.isHardware {
                        Label("about \(EncodePlanner.duration(p.seconds))", systemImage: "clock").font(Theme.note)
                    }
                }
                .foregroundStyle(.secondary)
                Text("Video ≈\(SizeForecast.gb(f.videoMid))" + (f.otherBytes > 0 ? " + audio and subtitles \(SizeForecast.gb(f.otherBytes)) (kept as is)" : "")
                     + (f.learnedFrom > 0 ? ". Corrected from \(f.learnedFrom) finished encodes." : "."))
                    .font(Theme.note).foregroundStyle(.secondary)
                HStack {
                    Button(f.method == .sampled ? "Measure again" : "Refine with samples") { model.refineForecast() }
                        .disabled(model.forecastBusy)
                    if model.forecastBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(f.confidenceText).font(Theme.note.monospacedDigit()).foregroundStyle(.secondary)
                }
                if f.method == .quick {
                    Text("Encodes ~8 short samples of contrasting scenes with your exact settings (a few minutes) for about ±10–15%.")
                        .font(Theme.note).foregroundStyle(.secondary)
                }
            } else {
                Text("Appears once the video is analysed.").font(Theme.note).foregroundStyle(.secondary)
            }
            if let folder = model.folderEstimate {
                Text(folder).font(Theme.note).padding(.top, 4)
            }
        }
    }

    private var qualityLine: String {
        guard model.useTargetQuality, ![.prores422HQ, .prores4444XQ, .av2].contains(model.codec) else {
            return model.codec == .prores4444XQ || model.codec == .prores422HQ ? "near-lossless master" : "fixed quality setting"
        }
        switch model.qualityProfile.name {
        case "Imperceptible": return "looks identical to the source"
        case "Visually lossless": return "differences only on close inspection"
        case "Transparent streaming": return "excellent streaming quality"
        default: return "VMAF \(Int(model.qualityProfile.primary?.threshold ?? 95))"
        }
    }
}


/// Compact view of the per-scene routing: how confident, which models won, and the hardest scenes.
struct MotionMapSummary: View {
    @Environment(AppModel.self) private var model
    let map: MotionMap

    var body: some View {
        let routed = map.routes.filter { $0.status != .skipped }
        let wins = Dictionary(grouping: routed, by: \.model).mapValues(\.count).sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Int(map.confidentShare * 100))% of \(routed.count) scenes settled at \(Int(map.confidenceTarget * 100))% confidence")
                .font(Theme.note)
            ForEach(wins.prefix(4), id: \.key) { id, n in
                Text("\(InterpolationModelSpec.all().first { $0.id == id }?.displayName ?? id): \(n) scenes").font(Theme.note).foregroundStyle(.secondary)
            }
            if !map.hardest.isEmpty {
                Text("Hardest scenes").font(Theme.heading(10)).padding(.top, 2)
                ForEach(map.hardest.prefix(5), id: \.scene) { r in
                    Button {
                        if let s = model.analysis?.scenes[safe: r.scene], let d = model.descriptor { model.scrub(to: Double(s.start) / d.fps) }
                    } label: {
                        Text("Scene \(r.scene + 1): \(Int(r.pain * 100))% of frames need repair, \(r.status.rawValue.lowercased())")
                            .font(Theme.note)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}


/// "Grade it for…": this Mac's screen (read live), other devices, or a future-proof master.
struct DisplayTargetSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Grade for a screen", trailing: model.thisDisplay?.source) {
            Picker("Screen", selection: Binding(get: { model.gradeFor?.name ?? "" },
                                                set: { n in model.gradeFor = allTargets.first { $0.name == n } })) {
                Text("No specific screen").tag("")
                if let d = model.thisDisplay { Text("\(d.name), \(Int(d.peakNits)) nits").tag(d.name) }
                ForEach(DisplayProfile.devices) { Text("\($0.name), \(Int($0.peakNits)) nits").tag($0.name) }
                Text(DisplayProfile.futureProof.name).tag(DisplayProfile.futureProof.name)
            }
            if let g = model.gradeFor {
                Text(g.summary).font(Theme.note).foregroundStyle(.secondary)
                Toggle("Make it pop on this screen", isOn: $model.makeItPop)
                Text(g.panel == .oled ? "Bright scenes are held back slightly so the TV's brightness limiter doesn't dim the whole picture."
                     : "Highlights are graded to this screen's real peak; the preview shows it the way this screen would.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Button("Export a future-proof master + viewing copy…") { model.exportFutureProof() }
                .disabled(model.analysis == nil)
                .help("A 12-bit, 4000-nit ProRes 4444 XQ master for tomorrow's screens, plus an HEVC Dolby Vision 8.1 copy at 1000 nits for today's.")
        }
        .onAppear { if model.thisDisplay == nil { model.refreshDisplay() } }
    }

    private var allTargets: [DisplayProfile] {
        (model.thisDisplay.map { [$0] } ?? []) + DisplayProfile.devices + [DisplayProfile.futureProof]
    }
}
