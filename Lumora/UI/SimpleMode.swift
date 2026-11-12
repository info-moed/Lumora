import SwiftUI

/// Beginner mode: the picture, the facts that matter, one question ("what do you want?"), and Lumora's answer.
struct SimpleModeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Theme.surround
                    EDRViewer().overlay { if model.descriptor == nil { SimpleEmpty() } }
                    if model.descriptor != nil { InfoHUD().padding(12) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                SceneStrip().frame(height: 40)
                HStack(spacing: 12) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.descriptor == nil)
                    if let d = model.descriptor {
                        Slider(value: Binding(get: { model.previewTime }, set: { model.scrub(to: $0) }), in: 0...max(0.1, d.durationSeconds))
                    }
                    Text(model.status).font(Theme.note).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 320, alignment: .trailing)
                }
            }
            .padding(14)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView { SimplePanel() }
                .frame(width: 400)
                .scrollIndicators(.never)
        }
        .background(Theme.surround)
    }
}

private struct SimpleEmpty: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Drop a movie, show or video here").font(Theme.heading(18))
            Text("Lumora reads every part of it (picture, HDR, motion, grain), then tells you the best settings in plain words.")
                .font(Theme.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Choose a file…") { model.presentOpenPanel() }.buttonStyle(.borderedProminent)
        }
    }
}

/// The facts on the picture: what it is, how bright, how much it's moving, where we are.
private struct InfoHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let d = model.descriptor {
            let a = model.analysis
            let f = Int(model.previewTime * d.fps)
            let scene = a.map { $0.sceneIndex(for: f) }
            let motion = a.flatMap { an in scene.map { an.sceneMotion($0) } } ?? 0
            VStack(alignment: .leading, spacing: 3) {
                Text(d.url.deletingPathExtension().lastPathComponent).font(Theme.heading(13))
                Text("\(d.outputWidth)×\(d.outputHeight) · \(String(format: "%.3g", d.fps)) fps · \(model.selectedColor?.name ?? "")")
                    .font(Theme.note)
                if let r = model.report { Text("HDR: \(r.verdict.rawValue.lowercased()), highlights ≈\(Int(r.p999Nits)) nits").font(Theme.note) }
                if let p = model.contentProfile { Text("Looks like: \(p.kind.displayName.lowercased())").font(Theme.note) }
                HStack(spacing: 10) {
                    Text(String(format: "%02d:%02d:%02d", Int(model.previewTime) / 3600, (Int(model.previewTime) / 60) % 60, Int(model.previewTime) % 60))
                        .font(Theme.note.monospacedDigit())
                    if let scene { Text("scene \(scene + 1)").font(Theme.note) }
                    Text(motion > 0.03 ? "fast motion" : (motion > 0.01 ? "some motion" : "calm")).font(Theme.note)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SimplePanel: View {
    @Environment(AppModel.self) private var model
    @State private var showTrial = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection(title: "What do you want to do?") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Goal.allCases) { g in
                        Button { model.goal = g } label: {
                            VStack(spacing: 6) {
                                Image(systemName: g.symbol).font(.system(size: 18))
                                Text(g.rawValue).font(Theme.note).multilineTextAlignment(.center).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .padding(6)
                            .background(model.goal == g ? Theme.signal.opacity(0.16) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.goal == g ? Theme.signal : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle("My TV or player can play AV1", isOn: $model.playsAV1).font(Theme.note)
            }
            if let r = model.currentRecommendation() {
                InspectorSection(title: "Lumora recommends") {
                    ForEach(r.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.area).font(Theme.note).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                Text(item.value).font(Theme.body.weight(.medium))
                            }
                            Text(item.why).font(Theme.note).foregroundStyle(.secondary).padding(.leading, 72)
                        }
                    }
                    HStack {
                        Button("Use these settings") { model.applyRecommendation() }.buttonStyle(.borderedProminent)
                        Button("Export…") { model.applyRecommendation(); model.showExport = true }
                    }
                    .padding(.top, 4)
                }
                ForecastSection()
            } else if model.descriptor != nil {
                InspectorSection(title: "Reading the file") {
                    Text("Lumora is reading every frame: scenes, brightness, HDR quality, grain and motion. Recommendations appear when it's done.")
                        .font(Theme.note).foregroundStyle(.secondary)
                    if let p = model.progress { ProgressView(value: p) }
                }
            }
            if model.analysis != nil { DisplayTargetSection(); PackageSection() }
            if !model.hotspots.isEmpty {
                InspectorSection(title: "Busiest moments", trailing: "where smoothing is hardest") {
                    ForEach(model.hotspots) { h in
                        HStack {
                            Button(h.label) { if let d = model.descriptor { model.scrub(to: Double(h.start) / d.fps) } }.buttonStyle(.link)
                            Spacer()
                            Button("Test smoothing") { model.runTrial(h); showTrial = true }
                                .controlSize(.small).disabled(model.trialBusy)
                        }
                    }
                    Text("Shows the original next to an interpolated version of that moment, using your current settings.")
                        .font(Theme.note).foregroundStyle(.secondary)
                }
            }
            InspectorSection(title: "More control") {
                Button("Switch to Pro mode") { model.simpleMode = false }.buttonStyle(.link)
            }
        }
        .sheet(isPresented: $showTrial) { TrialView().frame(minWidth: 1000, minHeight: 560) }
    }
}

/// The original (judder and all) next to the interpolated version, in step, with new frames marked.
struct TrialView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var speed = 1.0
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Smoothing test").font(Theme.heading(18))
                Spacer()
                Picker("Speed", selection: $speed) {
                    Text("Real time").tag(1.0); Text("Half speed").tag(0.5); Text("Quarter speed").tag(0.25)
                }
                .pickerStyle(.segmented).frame(width: 300)
                Button("Done") { dismiss() }
            }
            if let t = model.trial {
                TimelineView(.animation) { ctx in
                    let n = max(1, t.interpolated.count)
                    let i = Int(ctx.date.timeIntervalSince(started) * t.outputFps * speed) % n
                    HStack(spacing: 12) {
                        panel(t.original[min(i, t.original.count - 1)], title: "Original", note: "as filmed")
                        panel(t.interpolated[i], title: "Smoothed (\(Int(t.outputFps.rounded())) fps)",
                              note: t.generatedMask[i] ? "new frame" : "original frame", highlight: t.generatedMask[i])
                    }
                }
                Text("\(t.hotspot.label) · model: \(t.model)").font(Theme.note).foregroundStyle(.secondary)
                Label(t.verdict, systemImage: t.repairs.isEmpty ? "checkmark.seal" : "bandage").font(Theme.body)
            } else {
                ProgressView("Interpolating the busiest moment…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .onAppear { started = Date() }
    }

    private func panel(_ img: CGImage, title: String, note: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if highlight { Text("new").font(.system(size: 10, weight: .semibold)).padding(4)
                        .background(Theme.signal.opacity(0.85), in: Capsule()).padding(6) }
                }
            HStack { Text(title).font(Theme.heading(12)); Spacer(); Text(note).font(Theme.note).foregroundStyle(.secondary) }
        }
    }
}
