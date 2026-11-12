import SwiftUI

/// Name, library, metadata, tracks and appendices for the finished file.
struct PackageSection: View {
    @Environment(AppModel.self) private var model
    @State private var showMetadata = false
    @State private var showTracks = false

    var body: some View {
        @Bindable var model = model
        InspectorSection(title: "Name and library") {
            Picker("Naming", selection: $model.packaging.naming) { ForEach(NamingScheme.allCases) { Text($0.rawValue).tag($0) } }
            if model.packaging.naming == .custom {
                TextField("Pattern", text: $model.packaging.customTemplate).textFieldStyle(.roundedBorder)
                Text("Tokens: {title} {year} {show} {season2} {episode2} {episodeTitle} {edition} {resolution} {hdr} {codec} {imdb} {original}")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            TextField("Rename to (optional)", text: $model.packaging.outputName).textFieldStyle(.roundedBorder)
            if let d = model.descriptor {
                Text(Naming.path(model.packaging, original: d.url.deletingPathExtension().lastPathComponent,
                                 facts: Naming.guess(from: d.url.deletingPathExtension().lastPathComponent)
                                    .merging(["resolution": d.outputHeight >= 2000 ? "2160p" : "\(d.outputHeight)p",
                                              "hdr": model.deliversHDR ? "HDR10" : "SDR", "codec": model.codec == .av1 ? "AV1" : "HEVC"]) { $1 }))
                    .font(Theme.note.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                TextField("Title", text: $model.packaging.bespoke.title).textFieldStyle(.roundedBorder)
                TextField("Year", text: $model.packaging.bespoke.year).textFieldStyle(.roundedBorder).frame(width: 64)
            }
            if model.packaging.naming == .plexTV {
                HStack {
                    TextField("Show", text: $model.packaging.bespoke.show).textFieldStyle(.roundedBorder)
                    TextField("S", text: $model.packaging.bespoke.season).textFieldStyle(.roundedBorder).frame(width: 40)
                    TextField("E", text: $model.packaging.bespoke.episode).textFieldStyle(.roundedBorder).frame(width: 44)
                }
            }
            HStack {
                Button("Look up online") { model.lookUpTitle() }
                Button("All metadata…") { showMetadata = true }
                Button("Tracks…") { showTracks = true }
            }
            ForEach(model.lookupMatches) { m in
                Button { model.useMatch(m) } label: {
                    Text("\(m.title) (\(m.year)): \(m.overview.prefix(80))…").font(Theme.note).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
            }
        }
        InspectorSection(title: "Metadata already in the file") {
            Picker("Existing metadata", selection: $model.packaging.metadataPolicy) {
                ForEach(MetadataPolicy.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.packaging.metadataPolicy.explanation).font(Theme.note).foregroundStyle(.secondary)
            let personal = model.sourceStreams.tags.keys.filter { MetadataPolicy.personalKeys.contains($0.lowercased()) }
            if !personal.isEmpty {
                Text("Found in this file: \(personal.sorted().joined(separator: ", "))").font(Theme.note).foregroundStyle(Theme.marginal)
            }
        }
        InspectorSection(title: "Appendices") {
            ForEach(Appendix.allCases) { a in
                Toggle(a.rawValue, isOn: Binding(get: { model.packaging.appendices.contains(a) },
                                                 set: { on in if on { model.packaging.appendices.insert(a) } else { model.packaging.appendices.remove(a) } }))
                    .font(Theme.note)
            }
            Toggle("Verify the finished file (decode every frame)", isOn: $model.packaging.verifyAfterExport).font(Theme.note)
        }
        .sheet(isPresented: $showMetadata) { MetadataEditor().frame(minWidth: 560, minHeight: 520) }
        .sheet(isPresented: $showTracks) { TrackPicker().frame(minWidth: 560, minHeight: 440) }
    }
}

/// Every field you can write into the file, plus your own keys.
struct MetadataEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Metadata written into the file").font(Theme.heading(18))
            Form {
                TextField("Title", text: $model.packaging.bespoke.title)
                TextField("Year", text: $model.packaging.bespoke.year)
                TextField("Edition (e.g. Director's Cut)", text: $model.packaging.bespoke.edition)
                TextField("Show", text: $model.packaging.bespoke.show)
                TextField("Season", text: $model.packaging.bespoke.season)
                TextField("Episode", text: $model.packaging.bespoke.episode)
                TextField("Episode title", text: $model.packaging.bespoke.episodeTitle)
                TextField("Genres (comma separated)", text: $model.packaging.bespoke.genre)
                TextField("Description", text: $model.packaging.bespoke.description, axis: .vertical).lineLimit(3...6)
                TextField("Comment", text: $model.packaging.bespoke.comment)
                TextField("IMDb ID", text: $model.packaging.bespoke.imdbID)
                TextField("TMDB ID", text: $model.packaging.bespoke.tmdbID)
                Section("Your own fields") {
                    ForEach($model.packaging.bespoke.custom) { $kv in
                        HStack {
                            TextField("Key", text: $kv.key).frame(width: 160)
                            TextField("Value", text: $kv.value)
                            Button { model.packaging.bespoke.custom.removeAll { $0.id == kv.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add field") { model.packaging.bespoke.custom.append(.init()) }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
    }
}

/// Which audio and subtitle tracks go into the finished file.
struct TrackPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio and subtitles").font(Theme.heading(18))
            List {
                Section("Audio (\(model.sourceStreams.audio.count))") {
                    ForEach(model.sourceStreams.audio) { t in toggle(t, set: \.keepAudio, all: model.sourceStreams.audio) }
                    Toggle("Add a Dolby Digital Plus compatibility track for devices that can't play lossless audio",
                           isOn: $model.packaging.addCompatibilityTrack)
                    if model.sourceStreams.audio.contains(where: \.isAtmos) {
                        Text("The lossless Atmos track is kept untouched; the compatibility track is a regular 5.1 mix of it.")
                            .font(Theme.note).foregroundStyle(.secondary)
                    }
                }
                Section("Subtitles (\(model.sourceStreams.subtitles.count))") {
                    ForEach(model.sourceStreams.subtitles) { t in toggle(t, set: \.keepSubtitles, all: model.sourceStreams.subtitles) }
                    if model.sourceStreams.subtitles.contains(where: \.isBitmapSubtitle) {
                        Text("Blu-ray (image) subtitles are kept by writing an MKV file.").font(Theme.note).foregroundStyle(.secondary)
                    }
                }
                Section("Chapters") {
                    Toggle("Keep \(model.sourceStreams.chapters) chapters", isOn: $model.packaging.keepChapters)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
    }

    private func toggle(_ t: MediaTrack, set kp: WritableKeyPath<PackagingOptions, Set<Int>>, all: [MediaTrack]) -> some View {
        Toggle(t.label, isOn: Binding(
            get: { model.packaging[keyPath: kp].isEmpty || model.packaging[keyPath: kp].contains(t.index) },
            set: { on in
                var s = model.packaging[keyPath: kp].isEmpty ? Set(all.map(\.index)) : model.packaging[keyPath: kp]
                if on { s.insert(t.index) } else { s.remove(t.index) }
                model.packaging[keyPath: kp] = s.count == all.count ? [] : s
            }))
        .font(Theme.body)
    }
}

/// Unattended runs: hours, battery, heat, notifications, iPhone webhook; online lookup key; archive verification.
struct RunRulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules = RunRules.current
    @State private var tmdb = LibraryLookup.apiKey

    var body: some View {
        Form {
            Section("Long runs") {
                Toggle("Only work between", isOn: $rules.onlyBetween)
                if rules.onlyBetween {
                    Stepper("From \(rules.startHour):00", value: $rules.startHour, in: 0...23)
                    Stepper("Until \(rules.endHour):00", value: $rules.endHour, in: 0...23)
                }
                Toggle("Pause on battery", isOn: $rules.pauseOnBattery)
                Toggle("Pause if the Mac gets critically hot", isOn: $rules.pauseWhenHot)
                if !QueueStore.pending.isEmpty {
                    Button("Resume the unfinished batch (\(QueueStore.pending.count) files)") { model.resumePendingBatch() }
                }
            }
            Section("When it's done") {
                Toggle("Mac notification", isOn: $rules.notifyMac)
                TextField("Webhook for your phone (ntfy.sh, Pushover, Home Assistant…)", text: $rules.webhookURL)
                Text("Lumora sends a short POST with the file name when something finishes. With ntfy.sh, use https://ntfy.sh/your-topic and the ntfy app on your iPhone.")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Section("Library") {
                SecureField("TMDB API key (optional, for online title lookup)", text: $tmdb)
                Text("Without a key everything still works; titles come from file names and what you type.").font(Theme.note).foregroundStyle(.secondary)
            }
            Section("Archive") {
                Button("Verify an archive folder against its checksums…") { model.verifyArchiveFolder() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: rules) { RunRules.current = rules }
        .onChange(of: tmdb) { LibraryLookup.apiKey = tmdb }
    }
}

/// Reference frames from your films that guard picture quality across updates.
struct RegressionView: View {
    @Environment(AppModel.self) private var model
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Picture regression set").font(Theme.heading(18))
            Text("Save frames you know look right. After any update to Lumora or its tools, Check re-renders them with the saved settings and flags any frame whose picture changed visibly (below 45 dB).")
                .font(Theme.note).foregroundStyle(.secondary)
            HStack {
                TextField("Note (e.g. 'skin tones, night street')", text: $note).textFieldStyle(.roundedBorder)
                Button("Add current frame") { model.addRegressionFrame(note: note); note = "" }.disabled(model.previewFrame == nil)
                Button("Check all") { model.runRegressionCheck() }
            }
            List {
                ForEach(RegressionSet.all()) { g in
                    let r = model.regressionResults.first { $0.id == g.id }
                    HStack {
                        Image(systemName: r == nil ? "circle" : (r!.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                            .foregroundStyle(r == nil ? .secondary : (r!.ok ? Theme.pass : Theme.fail))
                        VStack(alignment: .leading) {
                            Text("\(URL(fileURLWithPath: g.source).lastPathComponent) · frame \(g.frame) · \(g.look.displayName)").font(Theme.body)
                            if !g.note.isEmpty { Text(g.note).font(Theme.note).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let r { Text(r.missing ? "source missing" : String(format: "%.1f dB", r.psnr)).font(Theme.note.monospacedDigit()) }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 480)
    }
}
