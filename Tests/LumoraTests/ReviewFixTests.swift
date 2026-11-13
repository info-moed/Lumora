import XCTest
@testable import Lumora

/// Fixes from the review of the SVT-AV1, x265, VVenC and libaom preset tuning. Pure decisions only: no encodes, no
/// windows; the export paths they feed are covered end to end by the tuning test classes.
final class ReviewFixTests: XCTestCase {

    // MARK: - Helpers

    private func job(_ codec: Codec, kind: ContentKind = .realLifeHeavyGrain, delivery: DeliveryFormat = .sdr,
                     choice: EncodeChoice? = nil, texture: FilmTexture = .off) -> ExportJob {
        var d = SourceDescriptor(url: URL(fileURLWithPath: "/tmp/review-fix-in.mov"), kind: .avfoundation)
        d.width = 640; d.height = 360; d.frameCount = 48
        let p = PresetCandidate(name: "n", look: .natural, color: .testSDR, params: Look.natural.params, sceneExposures: [0], reason: "")
        var j = ExportJob(descriptor: d, preset: p, analysis: .empty, delivery: delivery, codec: codec,
                          outputURL: URL(fileURLWithPath: "/tmp/review-fix-out.mkv"))
        j.contentKind = kind
        j.encodeChoice = choice
        j.filmTexture = texture
        return j
    }

    /// A planner choice at `rung` with exactly these option ids.
    private func choice(_ codec: Codec, kind: ContentKind, rung: String, options: [String]) throws -> EncodeChoice {
        let recipe = EncodeRecipes.recipe(codec: codec, kind: kind)
        let r = try XCTUnwrap(recipe.rungs.first { $0.id == rung })
        let opts = try options.map { id in try XCTUnwrap(recipe.options.first { $0.id == id }, id) }
        return EncodeChoice(codec: codec, encoderKey: r.encoderKey, rungID: r.id, rungLabel: r.label, presetValue: r.presetValue,
                            optionIDs: opts.map(\.id), extraArgs: opts.flatMap(\.args))
    }

    private func plan(_ codec: Codec, _ kind: ContentKind, _ mode: PlanMode, budget: Double = 3600, overrides: [String: Bool] = [:],
                      calibration: EncodeCalibration? = nil) -> EncodePlan {
        EncodePlanner.plan(codec: codec, kind: kind, frames: 2400, width: 1920, height: 1080, vmafMode: false, renderFps: 200,
                           mode: mode, budget: budget, overrides: overrides, loadCalibration: { _, _ in calibration })
    }

    // MARK: 2. libaom grain table on the AV1 ladder

    func testLibaomMeasuredGrainTableOnTheAV1Ladder() throws {
        let c = try choice(.av1, kind: .realLifeHeavyGrain, rung: "aom4", options: ["aomtable10"])
        let j = job(.av1, choice: c)
        XCTAssertTrue(ExportEngine.runsLibaom(j))
        let roles = ExportEngine.grainRoles(j)
        XCTAssertTrue(roles.measured, "aomtable10 is a measured table: Lumora removes the grain and writes the table")
        // libaom's flag, not SVT-AV1's --fgs-table, which aomenc refuses.
        XCTAssertEqual(ExportEngine.grainTableFlag(j, path: "/t/grain.tbl"), ["--film-grain-table=/t/grain.tbl"])
        // A film texture on an aomenc rung of the AV1 ladder gets libaom's flag too; SVT-AV1 rungs and AV1 Pro keep theirs.
        XCTAssertEqual(ExportEngine.grainTableFlag(job(.av1, choice: try choice(.av1, kind: .realLife, rung: "aom2", options: []),
                                                       texture: .film35), path: "/t"), ["--film-grain-table=/t"])
        XCTAssertEqual(ExportEngine.grainTableFlag(job(.av1, choice: try choice(.av1, kind: .realLife, rung: "p4", options: [])), path: "/t"),
                       ["--fgs-table", "/t"])
        XCTAssertEqual(ExportEngine.grainTableFlag(job(.av1), path: "/t"), ["--fgs-table", "/t"])
        XCTAssertEqual(ExportEngine.grainTableFlag(job(.av1Pro), path: "/t"), ["--film-grain-table=/t"])
        // The table flag is the only grain argument left.
        let planned = c.extraArgs + ["--denoise-noise-level=4", "--enable-qm=1"]
        XCTAssertEqual(ExportEngine.settleGrainArgs(planned, tableFlag: ["--film-grain-table=/t/grain.tbl"]),
                       ["--enable-qm=1", "--film-grain-table=/t/grain.tbl"])
        XCTAssertEqual(ExportEngine.settleGrainArgs(["--film-grain", "12", "--film-grain-denoise", "1", "--fgs-table", "{grain_table}", "--tune", "0"],
                                                    tableFlag: ["--fgs-table", "/t"]),
                       ["--tune", "0", "--fgs-table", "/t"])
    }

    func testUnfilledGrainTablePlaceholderNeverReachesTheEncoder() {
        // Paths that don't measure grain (size forecast, calibration) still carry the planner's table options.
        XCTAssertEqual(ExportEngine.settleGrainArgs(["--fgs-table", "{grain_table}", "--film-grain", "12"], tableFlag: nil),
                       ["--film-grain", "12"])
        XCTAssertEqual(ExportEngine.settleGrainArgs(["--cpu-used=4", "--film-grain-table={grain_table}", "--denoise-noise-level=4"], tableFlag: nil),
                       ["--cpu-used=4", "--denoise-noise-level=4"], "without a table, libaom's own grain stays")
        for codec in [Codec.av1, .av1Pro] {
            for kind in ContentKind.allCases {
                let args = EncodeRecipes.recipe(codec: codec, kind: kind).options.flatMap(\.args)
                XCTAssertFalse(ExportEngine.settleGrainArgs(args, tableFlag: nil).contains { $0.contains("{grain_table}") }, "\(codec) \(kind)")
                let settled = ExportEngine.settleGrainArgs(args, tableFlag: ["--fgs-table", "/t"])
                XCTAssertFalse(settled.contains { $0.contains("{") || $0 == "--film-grain" || $0.hasPrefix("--denoise-noise-level") })
            }
        }
    }

    // MARK: 3. Scoring reference with film texture

    func testFilmTextureTableMeansTheRealGrainIsScoredAgainstTheGrainyMaster() throws {
        let grain = try choice(.av1, kind: .realLifeHeavyGrain, rung: "p4", options: ["grain"])
        XCTAssertEqual(ExportEngine.grainRoles(job(.av1, choice: grain)), .init(measured: false, encoderGrain: true, texture: false))
        // The texture table replaces --film-grain, so the encoder codes the real grain: no de-grained reference.
        XCTAssertEqual(ExportEngine.grainRoles(job(.av1, choice: grain, texture: .film35)),
                       .init(measured: false, encoderGrain: false, texture: true))
        // The same for SVT-AV1 grain flags in the extras and for the grain tune without a plan.
        var flags = grain; flags.optionIDs = []
        XCTAssertFalse(ExportEngine.grainRoles(job(.av1, choice: flags, texture: .heavy)).encoderGrain)
        XCTAssertTrue(ExportEngine.grainRoles(job(.av1, choice: flags)).encoderGrain)
        XCTAssertFalse(ExportEngine.grainRoles(job(.av1, texture: .fine)).encoderGrain)
        if EncodeRecipes.synthesizesGrain(EncoderCatalog.shared.spec(for: "svtav1")?.tunes?["grain"] ?? []) {
            XCTAssertTrue(ExportEngine.grainRoles(job(.av1)).encoderGrain, "the grain tune synthesizes without a texture")
        }
        // libaom's grain synthesis is removed with a table as well, and counts without one.
        let aom = try choice(.av1, kind: .realLifeHeavyGrain, rung: "aom4", options: ["aomgrain10"])
        XCTAssertTrue(ExportEngine.grainRoles(job(.av1, choice: aom)).encoderGrain)
        XCTAssertFalse(ExportEngine.grainRoles(job(.av1, choice: aom, texture: .film35)).encoderGrain)
        // A measured table always scores against the de-grained master (Lumora removes the grain).
        let table = try choice(.av1, kind: .realLifeHeavyGrain, rung: "p4", options: ["grain", "grainTable"])
        XCTAssertTrue(ExportEngine.grainRoles(job(.av1, choice: table, texture: .film35)).measured)
    }

    // MARK: 4. Targeted repair renders grain like the export

    func testChunkGrainRenderMatchesTheTargetQualityExport() {
        var g = ExportEngine.GrainPlan()
        XCTAssertEqual(ExportEngine.chunkGrainRender(g), .init())
        g.strip = true
        XCTAssertEqual(ExportEngine.chunkGrainRender(g), .init(), "a film texture alone scores against the grainy master")
        g.cleanReference = true
        XCTAssertEqual(ExportEngine.chunkGrainRender(g), .init(denoise: true, encodeDegrained: false, degrainedReference: true),
                       "encoder grain synthesis: grainy frames in, de-grained reference")
        g.cleanInput = true
        XCTAssertEqual(ExportEngine.chunkGrainRender(g), .init(denoise: true, encodeDegrained: true, degrainedReference: false),
                       "measured table: de-grained frames in, which are also the reference")
        // A fixed-quality repair isn't scored: no de-grained reference, and no denoise unless the encoder gets it.
        XCTAssertEqual(ExportEngine.chunkGrainRender(g, scored: false), .init(denoise: true, encodeDegrained: true, degrainedReference: false))
        g.cleanInput = false
        XCTAssertEqual(ExportEngine.chunkGrainRender(g, scored: false), .init(), "encoder grain synthesis, unscored: plain frames")
    }

    // MARK: 5. HDR10 container metadata for every libaom encode

    func testLibaomOnTheAV1LadderGetsContainerHDR10Metadata() throws {
        let aom = try choice(.av1, kind: .realLife, rung: "aom3", options: [])
        let svt = try choice(.av1, kind: .realLife, rung: "p2", options: [])
        XCTAssertTrue(ExportEngine.needsContainerHDR10Metadata(job(.av1, kind: .realLife, delivery: .hdr10, choice: aom)))
        XCTAssertTrue(ExportEngine.needsContainerHDR10Metadata(job(.av1Pro, kind: .realLife, delivery: .hdr10)))
        XCTAssertFalse(ExportEngine.needsContainerHDR10Metadata(job(.av1, kind: .realLife, delivery: .hdr10, choice: svt)),
                       "SVT-AV1 writes HDR10 metadata into the stream itself")
        XCTAssertFalse(ExportEngine.needsContainerHDR10Metadata(job(.av1, kind: .realLife, delivery: .hdr10)))
        XCTAssertFalse(ExportEngine.needsContainerHDR10Metadata(job(.av1, kind: .realLife, delivery: .sdr, choice: aom)))
        XCTAssertEqual(ExportEngine.encoder(for: job(.av1, choice: aom))?.binary, "aomenc")
    }

    // MARK: 6. Calibrations from other seed ladders

    func testCalibrationFromOtherSeedsIsIgnored() throws {
        let recipe = EncodeRecipes.recipe(codec: .av1, kind: .realLife)
        let rungs = ["p8": EncodeCalibration.Rung(fps1080: 60, saving: 0.1), "p2": EncodeCalibration.Rung(fps1080: 3, saving: 0.3)]
        let old = EncodeCalibration(rungs: rungs, vmafFps1080: 40, date: Date())
        var current = old; current.seedSignature = recipe.seedSignature
        var other = old; other.seedSignature = "p10:0,p8:0.093"
        XCTAssertNil(EncodeCalibration.matching(old, recipe))
        XCTAssertNil(EncodeCalibration.matching(other, recipe))
        XCTAssertNotNil(EncodeCalibration.matching(current, recipe))
        XCTAssertTrue(recipe.seedSignature.hasPrefix("p9:0.071,p8:0.093,"))
        XCTAssertNotEqual(recipe.seedSignature, EncodeRecipes.recipe(codec: .hevc12, kind: .realLife).seedSignature)
        // Files saved before the signature existed still decode, without one.
        let json = #"{"rungs":{"p8":{"fps1080":60,"saving":0.1}},"date":0}"#
        XCTAssertNil(try JSONDecoder().decode(EncodeCalibration.self, from: Data(json.utf8)).seedSignature)
        // The planner falls back to the seeds and asks for a new measurement.
        for cal in [old, other] {
            let p = plan(.av1, .realLife, .bestForMac, calibration: cal)
            XCTAssertFalse(p.measured)
            XCTAssertTrue(p.notes.contains { $0.contains("Measure on this Mac") })
        }
        let p = plan(.av1, .realLife, .bestForMac, calibration: current)
        XCTAssertTrue(p.measured)
        XCTAssertFalse(p.notes.contains { $0.contains("Measure on this Mac") })
    }

    // MARK: 7. x265 options that restate a preset's default

    func testX265OptionsAreNotPricedWherePresetsAlreadyUseThem() {
        for kind in ContentKind.allCases {
            let options = EncodeRecipes.recipe(codec: .hevc12, kind: kind).options
            func offered(_ id: String) -> Set<String> {
                guard let o = options.first(where: { $0.id == id }) else { return [] }
                return Set(EncodeRecipes.recipe(codec: .hevc12, kind: kind).rungs.map(\.id).filter { o.offered(onRung: $0) })
            }
            // rd 6 and 8 B-frames: slower, veryslow and placebo use them already.
            XCTAssertEqual(offered("rd6"), ["faster", "medium", "slow"], "\(kind)")
            let anime = kind == .anime || kind == .oldAnime
            XCTAssertEqual(offered("bframes"), anime ? ["faster", "medium", "slow", "slower", "veryslow", "placebo"] : ["faster", "medium", "slow"],
                           "\(kind): 16 B-frames are never a preset default, 8 are from slower on")
            // A 60-frame look-ahead and transform skip: placebo's own settings.
            XCTAssertFalse(offered("rclook").contains("placebo"))
            XCTAssertTrue(offered("rclook").contains("veryslow"))
            if kind == .screenContent { XCTAssertEqual(offered("tskip").contains("placebo"), false) }
            // 6 references is more than any preset uses.
            XCTAssertEqual(offered("ref").count, 6)
        }
        XCTAssertEqual(EncodeRecipes.x265PresetsBelow("slower"), ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow"])
        // The slowest plans for low light and old anime no longer add --rd 6 on top of a preset that has it.
        for kind in [ContentKind.lowLightNoisy, .oldAnime] {
            let p = plan(.hevc12, kind, .maximum, budget: 1e9)
            if ["slower", "veryslow", "placebo"].contains(p.choice.rungID) {
                XCTAssertFalse(p.choice.extraArgs.contains("--rd"), "\(kind) \(p.choice.rungID): \(p.choice.extraArgs)")
            }
            let forced = plan(.hevc12, kind, .maximum, budget: 1e9, overrides: ["rd6": true])
            if forced.choice.rungID == "placebo" {
                XCTAssertTrue(forced.notes.contains { $0.contains("already uses it") }, "\(forced.notes)")
            }
        }
    }

    func testX265PresetsThatUseAnOptionStillGetItsSaving() {
        // The slow presets' seeds come from faces and CG, where rd 6, the look-ahead and transform skip save nothing;
        // on the content where they were measured, the presets that run them get their saving.
        func seedPlan(_ kind: ContentKind, _ rung: String) -> Double {
            let p = plan(.hevc12, kind, .maximum, budget: 1e9, overrides: Dictionary(uniqueKeysWithValues:
                EncodeRecipes.recipe(codec: .hevc12, kind: kind).options.map { ($0.id, false) }))
            return p.choice.rungID == rung ? p.saving : -1
        }
        let rd6 = EncodeRecipes.recipe(codec: .hevc12, kind: .oldAnime).options.first { $0.id == "rd6" }
        XCTAssertEqual(rd6?.presetRungs, ["slower", "veryslow", "placebo"])
        XCTAssertEqual(seedPlan(.oldAnime, "placebo"), 1 - (1 - 0.287) * 0.93, accuracy: 1e-9, "placebo runs rd 6 itself")
        XCTAssertEqual(seedPlan(.screenContent, "placebo"), 1 - (1 - 0.287) * 0.92, accuracy: 1e-9, "placebo runs --tskip itself")
        XCTAssertEqual(seedPlan(.realLife, "placebo"), 0.287, accuracy: 1e-9, "nothing to add where these save nothing")
        // So the slow presets stay reachable: sweeping the time budget visits each of them, and none adds the flag again.
        for kind in [ContentKind.oldAnime, .lowLightNoisy, .screenContent] {
            var picked: Set<String> = []
            var budget = 60.0
            while budget < 1e8 {
                let p = plan(.hevc12, kind, .budget, budget: budget)
                picked.insert(p.choice.rungID)
                if ["slower", "veryslow", "placebo"].contains(p.choice.rungID) { XCTAssertFalse(p.choice.extraArgs.contains("--rd"), "\(kind)") }
                if p.choice.rungID == "placebo" { XCTAssertFalse(p.choice.extraArgs.contains("--tskip"), "\(kind)") }
                budget *= 1.15
            }
            XCTAssertTrue(picked.isSuperset(of: ["slower", "veryslow", "placebo"]), "\(kind): \(picked.sorted())")
        }
        XCTAssertEqual(plan(.hevc12, .screenContent, .maximum, budget: 1e9).choice.rungID, "placebo")
        XCTAssertEqual(plan(.hevc12, .oldAnime, .maximum, budget: 1e9).choice.rungID, "placebo")
    }

    // MARK: 8. SVT-AV1 temporal filter follows grain synthesis

    func testTemporalFilterOffWhenHeavyGrainOrLowLightCodeTheRealGrain() throws {
        let tf = ["--enable-qm", "1", "--tf-strength", "1"]
        for kind in [ContentKind.realLifeHeavyGrain, .lowLightNoisy] {
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf, kind: kind), ["--enable-qm", "1", "--enable-tf", "0"], "\(kind)")
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf + ["--film-grain", "4", "--film-grain-denoise", "1"], kind: kind),
                           tf + ["--film-grain", "4", "--film-grain-denoise", "1"], "\(kind) with grain synthesis")
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf + ["--fgs-table", "/t"], kind: kind),
                           ["--enable-qm", "1", "--enable-tf", "0", "--fgs-table", "/t"], "\(kind): a grain table (measured or film texture)")
            // A table replaces SVT-AV1's grain synthesis on the command line, so the planned --film-grain doesn't count.
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf + ["--film-grain", "4", "--fgs-table", "{grain_table}"], kind: kind),
                           ["--enable-qm", "1", "--enable-tf", "0", "--film-grain", "4", "--fgs-table", "{grain_table}"], "\(kind)")
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf + ["--film-grain", "0"], kind: kind), ["--enable-qm", "1", "--enable-tf", "0", "--film-grain", "0"])
        }
        for kind in [ContentKind.oldAnime, .realLife, .cgiAnimation, .anime] {
            XCTAssertEqual(EncodeRecipes.svtTemporalFilter(tf, kind: kind), tf, "\(kind) keeps its filter")
        }
        // The planner's choice and the title agree with what the encoder gets.
        let fast = plan(.av1, .lowLightNoisy, .fastest)
        XCTAssertTrue(["p9", "p8"].contains(fast.choice.rungID))
        XCTAssertTrue(fast.choice.extraArgs.contains("--enable-tf") && !fast.choice.extraArgs.contains("--tf-strength"), "\(fast.choice.extraArgs)")
        let off = plan(.av1, .lowLightNoisy, .budget, budget: 1e9, overrides: ["grain": false])
        XCTAssertFalse(off.choice.extraArgs.contains("--tf-strength"), "grain turned off: \(off.choice.extraArgs)")
        let max = plan(.av1, .lowLightNoisy, .budget, budget: 1e9)
        if max.choice.encoderKey == nil && EncodeRecipes.synthesizesGrain(max.choice.extraArgs) {
            XCTAssertTrue(max.choice.extraArgs.contains("--tf-strength"), "\(max.choice.extraArgs)")
        }
        // Heavy grain: the measured grain table is cheap and recommended, so it is in every plan, preset 9 and 8 included,
        // and the encoder gets no grain synthesis of its own: the filter is off.
        let heavyFast = plan(.av1, .realLifeHeavyGrain, .fastest)
        XCTAssertEqual(heavyFast.choice.rungID, "p9")
        XCTAssertTrue(heavyFast.enabled.contains("grainTable"), "\(heavyFast.enabled)")
        XCTAssertTrue(heavyFast.choice.extraArgs.contains("--enable-tf") && !heavyFast.choice.extraArgs.contains("--tf-strength"),
                      "\(heavyFast.choice.extraArgs)")
        for mode in PlanMode.allCases {
            let p = plan(.av1, .realLifeHeavyGrain, mode, budget: 1e9)
            if p.choice.encoderKey == nil && p.enabled.contains("grainTable") {
                XCTAssertFalse(p.choice.extraArgs.contains("--tf-strength"), "\(mode) \(p.choice.rungID): \(p.choice.extraArgs)")
            }
        }
        let p8 = try choice(.av1, kind: .realLifeHeavyGrain, rung: "p8", options: ["tf", "grainTable"])
        XCTAssertEqual(EncodeRecipes.svtTemporalFilter(p8.extraArgs, kind: .realLifeHeavyGrain), ["--enable-tf", "0", "--fgs-table", "{grain_table}"])
        // Without the table, SVT-AV1's grain synthesis keeps the gentle filter.
        let synth = plan(.av1, .realLifeHeavyGrain, .maximum, budget: 1e9, overrides: ["grainTable": false, "grain": true])
        if synth.choice.encoderKey == nil {
            XCTAssertTrue(synth.choice.extraArgs.contains("--tf-strength") && EncodeRecipes.synthesizesGrain(synth.choice.extraArgs),
                          "\(synth.choice.extraArgs)")
        }
        XCTAssertEqual(EncodeRecipes.recipe(codec: .av1, kind: .realLifeHeavyGrain).options.first { $0.id == "tf" }?.title, "Temporal filter for grain")
        XCTAssertEqual(EncodeRecipes.recipe(codec: .av1, kind: .oldAnime).options.first { $0.id == "tf" }?.title, "Gentle temporal filter")
    }

    // MARK: 9. Saving against the fastest offered rung

    func testFastestPlanReportsOnlyWhatItsExtrasSave() {
        for kind in ContentKind.allCases {
            let p = plan(.av1, kind, .fastest)
            XCTAssertEqual(p.choice.rungID, "p9", "\(kind)")
            let extras = p.options.filter { p.enabled.contains($0.id) }.reduce(1.0) { $0 * (1 - $1.vmafSaving) }
            XCTAssertEqual(p.saving, 1 - extras, accuracy: 1e-9, "\(kind): no saving from preset 9 against itself")
        }
        // The x265 ladder starts at its reference, so nothing changes there.
        let x = plan(.hevc12, .realLife, .fastest)
        XCTAssertEqual(x.saving, 1 - x.options.filter { x.enabled.contains($0.id) }.reduce(1.0) { $0 * (1 - $1.vmafSaving) }, accuracy: 1e-9)
        // Upgrades and the frontier are unchanged: a slower plan still reports a larger saving.
        XCTAssertGreaterThan(plan(.av1, .realLife, .budget, budget: 1e9).saving, plan(.av1, .realLife, .fastest).saving)
    }

    // MARK: 10. libaom on the AV1 ladder

    func testPlannerRanksLibaomAsMeasuredAgainstTunedSVTAV1() {
        // Measured (tuning-aomenc.md): with Lumora's extras, SVT-AV1 presets 2/1/0 were as small or smaller than libaom
        // cpu-used 4/3/2 at about the same CPU time, so no plan with the extras on picks libaom.
        for kind in ContentKind.allCases {
            for p in [plan(.av1, kind, .maximum), plan(.av1, kind, .budget, budget: 1e9), plan(.av1, kind, .bestForMac)] {
                XCTAssertNil(p.choice.encoderKey, "\(kind): \(p.choice.rungLabel)")
            }
        }
        XCTAssertFalse(PlanMode.maximum.explanation.contains("libaom"))
        XCTAssertFalse(EncodeRecipes.recipe(codec: .av1, kind: .realLife).summary.contains("continues into libaom"))
        // Bare, libaom's slow rungs are smaller than SVT-AV1 preset 0, as measured bare against preset 4.
        let rungs = EncodeRecipes.recipe(codec: .av1, kind: .realLife).rungs
        let p0 = rungs.first { $0.id == "p0" }!, aom2 = rungs.first { $0.id == "aom2" }!
        XCTAssertGreaterThan(aom2.seedSaving, p0.seedSaving)
        if ToolLocator.isAvailable("aomenc") {
            let bare = ["varboost", "qm", "acbias", "scm", "grain", "grainTable"].reduce(into: [String: Bool]()) { $0[$1] = false }
            let p = plan(.av1, .realLife, .maximum, overrides: bare)
            XCTAssertEqual(p.choice.encoderKey, "aomenc", "with SVT-AV1's extras off libaom is the smallest")
            XCTAssertTrue(p.notes.contains(EncodePlanner.libaomNote))
        }
    }
}
