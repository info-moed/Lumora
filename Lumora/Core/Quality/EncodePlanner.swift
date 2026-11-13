import Foundation

/// How much time you're willing to give a file.
enum PlanMode: String, CaseIterable, Codable, Identifiable {
    case fastest = "Fastest"
    case budget = "Time budget"
    case bestForMac = "Best for this Mac"
    case maximum = "Maximum"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .fastest: return "Quickest settings that still use every free improvement."
        case .budget: return "The most efficient settings that finish within your time."
        case .bestForMac: return "Stops where extra time stops paying off on this Mac (less than 2% smaller per doubling of time)."
        case .maximum: return "Smallest possible file: slowest settings and every extra. Can take days."
        }
    }
}

/// The encoder settings the planner picked.
struct EncodeChoice: Codable, Hashable {
    var codec: Codec
    var encoderKey: String? = nil       // set when a rung uses another encoder (libaom on the AV1 ladder)
    var rungID: String
    var rungLabel: String
    var presetValue: String
    var optionIDs: [String]
    var extraArgs: [String]
}

/// Measured on this Mac by "Measure on this Mac": real speed and real size-at-target per preset.
struct EncodeCalibration: Codable {
    struct Rung: Codable { var fps1080: Double; var saving: Double }
    var rungs: [String: Rung]
    var vmafFps1080: Double?
    var date: Date
    /// The recipe's seed ladder when this was measured (`EncodeRecipe.seedSignature`). Measured savings are anchored to
    /// the seed of the first measured rung and mixed with the seeds of the rungs that weren't measured, so a calibration
    /// from another seed ladder (or from before this was stored) would overrate or underrate the unmeasured rungs.
    var seedSignature: String? = nil

    /// The calibration if it was measured against this recipe's seeds; nil otherwise (the planner then uses the seeds).
    static func matching(_ cal: EncodeCalibration?, _ recipe: EncodeRecipe) -> EncodeCalibration? {
        guard let cal, cal.seedSignature == recipe.seedSignature else { return nil }
        return cal
    }

    private static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/Calibration")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func key(_ codec: Codec, _ kind: ContentKind) -> String { "\(codec.rawValue)-\(kind.rawValue)" }
    static func load(_ codec: Codec, _ kind: ContentKind) -> EncodeCalibration? {
        try? JSONDecoder().decode(EncodeCalibration.self, from: Data(contentsOf: folder.appendingPathComponent(key(codec, kind) + ".json")))
    }
    func save(_ codec: Codec, _ kind: ContentKind) {
        try? JSONEncoder().encode(self).write(to: Self.folder.appendingPathComponent(Self.key(codec, kind) + ".json"))
    }
}

struct EncodePlan {
    struct Upgrade: Hashable {
        var key: String
        var extraSeconds: Double
        var smallerFraction: Double      // at the same VMAF
        var vmafGain: Double             // at the same file size
        var label: String
        var choice: EncodeChoice
    }
    var choice: EncodeChoice
    var seconds: Double
    var saving: Double                   // vs the fastest preset with no extras
    var measured: Bool
    var options: [EncodeOption]          // offered for this codec/content/encoder build
    var enabled: Set<String>
    var upgrade: Upgrade?
    var notes: [String]

    var headline: String {
        let extras = enabled.count
        return "\(choice.rungLabel)" + (extras > 0 ? " with \(extras) extra\(extras == 1 ? "" : "s")" : "")
    }
}

private func plan_enabledGrain(_ offered: [EncodeOption], _ kind: ContentKind) -> Bool {
    offered.contains { ($0.id == "grain" || $0.id == "aomgrain") && $0.recommendedFor.contains(kind) }
}

enum EncodePlanner {
    /// libaom on the AV1 ladder, measured against SVT-AV1 with Lumora's extras (docs/encoding/tuning-aomenc.md).
    static let libaomNote = "This setting uses libaom. On Lumora's test clips, SVT-AV1 presets 2 to 0 with their extras were as small or smaller in the same time."

    static func duration(_ s: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.day, .hour, .minute] : [.minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: max(60, s)) ?? "\(Int(s / 60)) min"
    }

    /// - renderFps: how fast Lumora renders (decode + interpolate + upscale + grade) — the floor for any plan.
    static func plan(codec: Codec, kind: ContentKind, frames: Int, width: Int, height: Int, vmafMode: Bool,
                     renderFps: Double, mode: PlanMode, budget: TimeInterval, overrides: [String: Bool],
                     metricSecondsPerFrame: Double = 0, chip: ChipProfile = .current,
                     loadCalibration: (Codec, ContentKind) -> EncodeCalibration? = EncodeCalibration.load) -> EncodePlan {
        let recipe = EncodeRecipes.recipe(codec: codec, kind: kind)
        // A calibration measured against other seeds is ignored: mixed with these it misjudges the unmeasured rungs.
        let cal = EncodeCalibration.matching(loadCalibration(codec, kind), recipe)
        let pixelScale = Double(1920 * 1080) / Double(max(1, width * height))
        let coreScale = codec.isHardware ? Double(chip.videoEncodeEngines) : Double(chip.cpuCores) / 8.0
        let samples = QualityPredictor.shared.sampleCounts[codec.rawValue] ?? 0
        let trials = vmafMode ? (samples >= 40 ? 1.7 : 2.6) * 1.1 : 1.0
        let vmafFps = (cal?.vmafFps1080 ?? 30 * Double(chip.cpuCores) / 8 * 2) * (height > 1600 ? 1 : pixelScale)

        // Rung speed and saving: measured where available, seeds scaled by the nearest measurement otherwise.
        func rungStats(_ i: Int) -> (fps: Double, saving: Double) {
            let r = recipe.rungs[i]
            if let m = cal?.rungs[r.id] { return (m.fps1080, m.saving) }
            var fps = recipe.baseFps1080 * r.seedSpeed * coreScale
            if let cal, let near = recipe.rungs.enumerated().filter({ cal.rungs[$0.element.id] != nil })
                .min(by: { abs($0.offset - i) < abs($1.offset - i) }) {
                let m = cal.rungs[near.element.id]!
                fps = m.fps1080 * r.seedSpeed / max(0.0001, near.element.seedSpeed)
            }
            // What the preset itself does that the seeds' test content didn't reward (x265's rd 6 on old anime, say).
            let builtIn = recipe.options.filter { $0.encoderKey == r.encoderKey && $0.presetRungs.contains(r.id) }
            return (fps, 1 - (1 - r.seedSaving) * builtIn.reduce(1.0) { $0 * (1 - $1.vmafSaving) })
        }

        let offered = recipe.options.filter { EncodeRecipes.available($0, codec: codec) }
        // Options can be limited to some rungs and can cost a different amount of time on each.
        func baseSet(_ enc: String?, _ rung: String) -> [EncodeOption] {
            offered.filter { $0.encoderKey == enc && $0.offered(onRung: rung) }.filter { o in
                if let forced = overrides[o.id] { return forced }
                if o.conflictsWithVMAF && vmafMode { return false }
                guard o.recommendedFor.contains(kind) else { return false }
                return o.speedCost(onRung: rung) <= 1.05          // cheap extras are always worth it
            }
        }
        func expensive(_ enc: String?, _ rung: String) -> [EncodeOption] {
            offered.filter { o in
                o.encoderKey == enc && o.offered(onRung: rung) && o.speedCost(onRung: rung) > 1.05 && overrides[o.id] == nil
                    && o.recommendedFor.contains(kind) && !(o.conflictsWithVMAF && vmafMode)
            }
        }

        struct Candidate { var rung: Int; var opts: [EncodeOption]; var seconds: Double; var saving: Double }
        var all: [Candidate] = []
        for i in recipe.rungs.indices where EncodeRecipes.available(recipe.rungs[i], codec: codec) {
            let enc = recipe.rungs[i].encoderKey
            let rungID = recipe.rungs[i].id
            let exp = expensive(enc, rungID)
            let subsets = (0..<(1 << exp.count)).map { mask in exp.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element) }
            let (fps0, s0) = rungStats(i)
            for sub in subsets {
                let opts = baseSet(enc, rungID) + sub
                let cost = opts.reduce(1.0) { $0 * $1.speedCost(onRung: rungID) }
                let fps = fps0 * pixelScale / cost
                let saving = 1 - (1 - s0) * opts.reduce(1.0) { $0 * (1 - $1.vmafSaving) }
                let encode = Double(frames) * trials / max(0.01, fps)
                let score = vmafMode ? Double(frames) * trials / max(0.01, vmafFps) + Double(frames) * metricSecondsPerFrame : 0
                let render = Double(frames) / max(0.01, renderFps)
                var seconds = max(render, encode + score) * 1.05 + 60
                // Long jobs run at the throttled, heat-soaked speed measured on this Mac.
                if seconds > 1200, let f = MacProfile.current?.sustainedFactor, f > 0 { seconds /= f }
                all.append(Candidate(rung: i, opts: opts, seconds: seconds, saving: saving))
            }
        }
        // Pareto frontier: each step is slower but strictly more efficient.
        let frontier = all.sorted { $0.seconds < $1.seconds }.reduce(into: [Candidate]()) { f, c in
            if c.saving > (f.last?.saving ?? -1) + 0.001 { f.append(c) }
        }
        var pick: Candidate
        switch mode {
        case .fastest:
            pick = frontier.first!
        case .budget:
            pick = frontier.last { $0.seconds <= budget } ?? frontier.first!
        case .maximum:
            pick = frontier.last!
        case .bestForMac:
            pick = frontier.first!
            for c in frontier.dropFirst() {
                let gain = 1 - (1 - c.saving) / (1 - pick.saving)
                let doublings = log2(c.seconds / pick.seconds)
                if doublings > 0, gain / doublings >= 0.02, c.seconds <= 86_400 { pick = c } else { break }
            }
        }
        func choice(_ c: Candidate) -> EncodeChoice {
            let r = recipe.rungs[c.rung]
            var args = c.opts.flatMap(\.args)
            if codec == .av1 && r.encoderKey == nil {
                // The temporal filter follows whether SVT-AV1 synthesizes the grain, as ExportEngine applies it.
                args = EncodeRecipes.svtTemporalFilter(args, kind: kind)
            }
            return EncodeChoice(codec: codec, encoderKey: r.encoderKey, rungID: r.id, rungLabel: r.label, presetValue: r.presetValue,
                                optionIDs: c.opts.map(\.id), extraArgs: args)
        }
        var upgrade: EncodePlan.Upgrade?
        if let next = frontier.first(where: { $0.seconds > pick.seconds && $0.saving > pick.saving + 0.01 }) {
            let ratio = (1 - next.saving) / (1 - pick.saving)
            let ch = choice(next)
            upgrade = EncodePlan.Upgrade(key: "\(codec.rawValue)-\(kind.rawValue)-\(ch.rungID)-\(ch.optionIDs.sorted().joined())",
                                         extraSeconds: next.seconds - pick.seconds, smallerFraction: 1 - ratio,
                                         vmafGain: 6.5 * -log(ratio), label: ch.rungLabel, choice: ch)
        }
        var notes: [String] = []
        if cal == nil && !codec.isHardware { notes.append("Times are estimates. Measure on this Mac for real numbers (about 3–6 minutes, remembered).") }
        if vmafMode, plan_enabledGrain(offered, kind) {
            notes.append("Grain synthesis is scored fairly: quality checks strip the synthetic grain and compare against a de-grained master.")
        }
        if offered.contains(where: \.visualOnly) {
            notes.append("Extras marked “for the eye” improve fidelity that VMAF doesn't measure; the VMAF target may spend a few more bits to keep its score.")
        }
        let pickedRung = recipe.rungs[pick.rung]
        for o in offered where overrides[o.id] == true && o.encoderKey == pickedRung.encoderKey && !o.offered(onRung: pickedRung.id) {
            // x265 options are limited to the presets that don't already set them; elsewhere it's a time trade-off.
            notes.append(codec == .hevc12 ? "\(o.title) isn't added at \(pickedRung.label): that preset already uses it."
                                          : "\(o.title) isn't used at \(pickedRung.label): it would cost more time than the faster setting saves.")
        }
        let pickedEncoder = recipe.rungs[pick.rung].encoderKey
        if pickedEncoder == "aomenc" { notes.append(EncodePlanner.libaomNote) }
        // Seeds and measurements count from a reference that need not be offered (SVT-AV1's preset 10 is gone), so the
        // reported saving is taken against the fastest rung offered here with no extras, which is what it promises.
        let fastest = recipe.rungs.indices.first { EncodeRecipes.available(recipe.rungs[$0], codec: codec) } ?? 0
        let saving = 1 - (1 - pick.saving) / max(0.0001, 1 - rungStats(fastest).saving)
        let plan = EncodePlan(choice: choice(pick), seconds: pick.seconds, saving: saving, measured: cal != nil,
                              options: offered.filter { $0.encoderKey == pickedEncoder }, enabled: Set(pick.opts.map(\.id)), upgrade: upgrade, notes: notes)
        Log.debug(.encode, "Plan \(mode.rawValue): \(plan.headline), ~\(duration(plan.seconds)), saving \(Int(plan.saving * 100))% vs fastest")
        return plan
    }
}
