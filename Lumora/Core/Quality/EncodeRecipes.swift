import Foundation

/// One speed/efficiency step of an encoder (an SVT-AV1 preset, an x265 preset…), fastest first.
/// Seed numbers come from published benchmarks and are replaced by measurements once you run
/// "Measure on this Mac".
struct EncodeRung: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    var presetValue: String
    var seedSpeed: Double      // relative to the fastest rung (1.0)
    var seedSaving: Double     // fraction smaller than the fastest rung at the same quality
    var encoderKey: String? = nil   // nil = the codec's default encoder; "aomenc" = libaom on an AV1 ladder
}

/// An optional encoder setting, explained in plain terms. The planner turns these on or off to fit your time.
struct EncodeOption: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var args: [String]
    var probeFlag: String?            // only offered if the installed encoder lists this flag in --help
    var speedCost: Double = 1.0       // time multiplier (1.10 = 10% slower)
    var vmafSaving: Double = 0        // size saved at equal VMAF
    var visualOnly = false            // improves what eyes see; VMAF doesn't reward it
    var conflictsWithVMAF = false     // e.g. synthetic grain: VMAF can't judge it fairly
    var recommendedFor: [ContentKind] = ContentKind.allCases
    var encoderKey: String? = nil     // which encoder these flags belong to (nil = the codec's default)
    var rungs: Set<String>? = nil     // rung IDs this option is offered on (nil = every rung)
    var rungSpeedCost: [String: Double] = [:]   // measured time multiplier per rung; overrides speedCost there

    func offered(onRung rung: String) -> Bool { rungs?.contains(rung) ?? true }
    func speedCost(onRung rung: String) -> Double { rungSpeedCost[rung] ?? speedCost }
}

struct EncodeRecipe {
    var codec: Codec
    var kind: ContentKind
    var title: String
    var summary: String
    var rungs: [EncodeRung]
    var options: [EncodeOption]
    var baseFps1080: Double           // rough speed of the fastest rung at 1080p on an 8-core reference machine
}

/// Archival recipes per codec and content type, from the encoder authors' notes and community testing
/// (JET encoding guide, SVT-AV1 docs and deep dives, Doom9/VideoHelp x265 anime threads). See README → Encode recipes.
enum EncodeRecipes {
    static func recipe(codec: Codec, kind: ContentKind) -> EncodeRecipe {
        let anime = kind == .anime || kind == .oldAnime
        let grainy = [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy].contains(kind)
        switch codec {
        case .av1:
            let svtGrain = svtGrainLevel(kind)
            var opts: [EncodeOption] = [
                EncodeOption(id: "varboost", title: "Protect flat and dark areas",
                             detail: "Variance boost gives low-contrast areas (skies, shadows, flat color) more bits. Consistent gains in SVT-AV1 3.x tests.",
                             // Ahead on VMAF, VMAF NEG and XPSNR: the low-medium contrast curve on low light, the mild
                             // strength on fast motion.
                             args: ["--enable-variance-boost", "1"] + (kind == .lowLightNoisy ? ["--variance-boost-curve", "1"] : [])
                                 + (kind == .fastMotion ? ["--variance-boost-strength", "1"] : []),
                             probeFlag: "--enable-variance-boost", speedCost: 1.01, vmafSaving: 0.02),
                EncodeOption(id: "qm", title: "Quantization matrices",
                             detail: "Frequency-shaped quantization; usually a small efficiency win.",
                             args: ["--enable-qm", "1", "--qm-min", "\(svtQMMin(kind))"], probeFlag: "--enable-qm", vmafSaving: 0.015,
                             recommendedFor: ContentKind.allCases.filter { $0 != .screenContent }),
                EncodeOption(id: "acbias", title: "Keep texture energy",
                             detail: "AC bias (1.0) steers rate-distortion decisions toward keeping texture instead of smoothing it. On live action, CG, heavy grain and low light it was smaller at equal VMAF and XPSNR.",
                             // CPU time +7% on average (-5% to +20%) at presets 4 and 6, full size, measured on an M3 Max.
                             args: ["--ac-bias", "1.0"], probeFlag: "--ac-bias", speedCost: 1.07, vmafSaving: 0.025,
                             recommendedFor: [.realLife, .cgiAnimation, .realLifeHeavyGrain, .lowLightNoisy]),
                EncodeOption(id: "vq", title: "Tune for visual quality",
                             detail: "SVT-AV1's visual-quality tune (tune 0). On flat-color animation it was smaller at equal VMAF and XPSNR.",
                             args: ["--tune", "0"], probeFlag: "--tune", recommendedFor: [.anime]),
                EncodeOption(id: "sharp", title: anime ? "Crisper line art" : "Sharper fine detail",
                             detail: "Gentler deblocking and sharper rate-distortion decisions. Looks more like the source; VMAF barely notices.",
                             args: ["--sharpness", anime ? "2" : "1"], probeFlag: "--sharpness", visualOnly: true),
                // Grainy kinds synthesize their grain, so the encoder sees (and should filter) a clean picture: strength 1
                // beat no temporal filter by 15-46% BD-rate against the noise-free truth (tuning-svtav1.md).
                EncodeOption(id: "tf", title: kind == .anime ? "No temporal smoothing" : "Gentle temporal filter",
                             detail: kind == .anime ? "Turns off the temporal filter that can smear line art." : "Keeps texture that the temporal filter would soften.",
                             args: kind == .anime ? ["--enable-tf", "0"] : ["--tf-strength", "1"],
                             probeFlag: kind == .anime ? "--enable-tf" : "--tf-strength", visualOnly: true),
                EncodeOption(id: "lumabias", title: "Brighter handling of dark scenes",
                             detail: "Biases quality toward dark areas, where AV1 artifacts show first. SDR and HLG only: it reads brightness from SDR-style code values, so HDR10 (PQ) exports leave it out.",
                             args: ["--luminance-qp-bias", "25"], probeFlag: "--luminance-qp-bias", visualOnly: true,
                             recommendedFor: [.realLife, .realLifeHeavyGrain, .lowLightNoisy, .oldAnime]),
                EncodeOption(id: "grain", title: "Film grain synthesis (level \(svtGrain))",
                             detail: "Removes the grain before encoding and describes it instead; the player re-creates it. Much smaller files for grainy sources. Quality checks score the picture with the synthetic grain stripped, against a de-grained master, so the comparison is fair. Preset 6 and slower only: SVT-AV1's grain analysis costs about the same time per frame at every preset, which would erase what a faster preset saves.",
                             args: ["--film-grain", "\(svtGrain)", "--film-grain-denoise", "1"], probeFlag: "--film-grain", speedCost: 2.07,
                             vmafSaving: grainy ? 0.15 : 0.05,
                             recommendedFor: [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy],
                             rungs: ["p6", "p5", "p4", "p3", "p2", "p1", "p0"],
                             // CPU time with / without grain, 1920x800, measured on an M3 Max (tuning-svtav1.md);
                             // preset 0 not measured, taken as preset 1.
                             rungSpeedCost: ["p6": 2.42, "p5": 2.40, "p4": 2.07, "p3": 1.50, "p2": 1.12, "p1": 1.0, "p0": 1.0]),
                EncodeOption(id: "grainTable", title: "Grain measured from this film",
                             detail: "Lumora measures the grain of this exact film (strength per brightness) and hands the encoder a matching grain table, instead of the encoder's own estimate.",
                             args: ["--fgs-table", "{grain_table}"], probeFlag: "--fgs-table", speedCost: 1.0,
                             vmafSaving: grainy ? 0.02 : 0, visualOnly: true,
                             recommendedFor: [.realLifeHeavyGrain, .oldAnime])
            ]
            // libaom options (used only on the libaom rungs of this ladder).
            opts += [
                EncodeOption(id: "aomqm10", title: "Quantization matrices (libaom)", detail: EncodeRecipes.aomQMDetail,
                             args: ["--enable-qm=1"], probeFlag: "--enable-qm", speedCost: 1.07, recommendedFor: [], encoderKey: "aomenc"),
                EncodeOption(id: "aomgrain10", title: "Film grain synthesis (libaom)", detail: EncodeRecipes.aomGrainDetail,
                             args: ["--denoise-noise-level=\(EncodeRecipes.aomGrainLevel)"], probeFlag: "--denoise-noise-level",
                             speedCost: EncodeRecipes.aomGrainSpeedCost, recommendedFor: [], encoderKey: "aomenc"),
                EncodeOption(id: "aomtable10", title: "Grain measured from this film (libaom)",
                             detail: "A grain table measured by Lumora instead of libaom's own estimate.",
                             args: ["--film-grain-table={grain_table}"], probeFlag: "--film-grain-table", visualOnly: true,
                             recommendedFor: [.realLifeHeavyGrain, .oldAnime], encoderKey: "aomenc")
            ]
            if kind == .screenContent {
                opts.append(EncodeOption(id: "scm", title: "Screen-content tools", detail: "Palette and intra-block-copy tools for text and UI.",
                                         args: ["--scm", "1"], probeFlag: "--scm", speedCost: 1.05, vmafSaving: 0.1, recommendedFor: [.screenContent]))
            }
            return EncodeRecipe(codec: codec, kind: kind,
                                title: "AV1 archival · \(kind.displayName.lowercased())",
                                summary: "SVT-AV1 for nearly everything (preset 4 is the balance point, 2 the efficient high end). For archival runs with days to spare, the ladder continues into libaom: cpu-used 4 is about as small as preset 1, and 3 and 2 go a little further.",
                                rungs: [
                                    // SVT-AV1 speeds: CPU time per frame relative to preset 10, measured on an M3 Max over
                                    // four clips (tuning-svtav1.md). Preset 10 itself is no longer offered: SVT-AV1 warns that
                                    // non-RTC presets 10+ are for automation and may show artifacts, and preset 9 was 23%
                                    // smaller for 32% more time. Speeds and savings stay on the preset-10 scale that the
                                    // libaom rungs below share; preset 9's saving sits where its measured saving falls
                                    // between presets 10 and 8.
                                    EncodeRung(id: "p9", label: "Preset 9", presetValue: "9", seedSpeed: 0.76, seedSaving: 0.071),
                                    EncodeRung(id: "p8", label: "Preset 8", presetValue: "8", seedSpeed: 0.54, seedSaving: 0.093),
                                    EncodeRung(id: "p6", label: "Preset 6", presetValue: "6", seedSpeed: 0.26, seedSaving: 0.167),
                                    EncodeRung(id: "p5", label: "Preset 5", presetValue: "5", seedSpeed: 0.19, seedSaving: 0.185),
                                    EncodeRung(id: "p4", label: "Preset 4", presetValue: "4", seedSpeed: 0.16, seedSaving: 0.204),
                                    EncodeRung(id: "p3", label: "Preset 3", presetValue: "3", seedSpeed: 0.088, seedSaving: 0.213),
                                    EncodeRung(id: "p2", label: "Preset 2", presetValue: "2", seedSpeed: 0.049, seedSaving: 0.222),
                                    EncodeRung(id: "p1", label: "Preset 1", presetValue: "1", seedSpeed: 0.026, seedSaving: 0.226),
                                    EncodeRung(id: "p0", label: "Preset 0", presetValue: "0", seedSpeed: 0.010, seedSaving: 0.229),
                                    // libaom, measured against SVT-AV1 presets 10 and 4 on the same four clips (tuning-aomenc.md):
                                    // CPU time per frame relative to preset 10, and the saving placed on the SVT-AV1 seed scale
                                    // above through SVT-AV1's own measured-to-seed mapping. cpu-used 4 is about as small as
                                    // preset 1 at a similar speed; 3 and 2 go further. cpu-used 1 and 0 were not measured:
                                    // their speeds keep the old step from cpu-used 2, their savings the old seeds.
                                    EncodeRung(id: "aom4", label: "libaom cpu-used 4", presetValue: "4", seedSpeed: 0.033, seedSaving: 0.227, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom3", label: "libaom cpu-used 3", presetValue: "3", seedSpeed: 0.021, seedSaving: 0.229, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom2", label: "libaom cpu-used 2", presetValue: "2", seedSpeed: 0.008, seedSaving: 0.233, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom1", label: "libaom cpu-used 1", presetValue: "1", seedSpeed: 0.004, seedSaving: 0.236, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom0", label: "libaom cpu-used 0", presetValue: "0", seedSpeed: 0.0016, seedSaving: 0.240, encoderKey: "aomenc")
                                ],
                                options: opts, baseFps1080: 55)
        case .hevc12:
            let opts: [EncodeOption] = [
                EncodeOption(id: "aq3", title: "Protect dark scenes",
                             detail: "AQ mode 3: adaptive quantization with a bias toward dark areas, where banding and blocking show first. A staple for anime.",
                             args: ["--aq-mode", "3"], visualOnly: true,
                             recommendedFor: ContentKind.allCases.filter { $0 != .screenContent }),
                EncodeOption(id: "bframes", title: anime ? "16 B-frames" : "8 B-frames",
                             detail: "More bidirectional frames; helps static and slow scenes. Cost is small.",
                             args: ["--bframes", anime ? "16" : "8"], speedCost: anime ? 1.08 : 1.04, vmafSaving: 0.02),
                EncodeOption(id: "ref", title: "6 reference frames", detail: "More frames to predict from.",
                             args: ["--ref", "6"], speedCost: 1.10, vmafSaving: 0.01),
                EncodeOption(id: "rclook", title: "60-frame look-ahead", detail: "Better rate planning over longer stretches.",
                             args: ["--rc-lookahead", "60"], speedCost: 1.03, vmafSaving: 0.01),
                EncodeOption(id: "sao", title: anime ? "Limited SAO" : "SAO off (keep detail)",
                             detail: anime ? "Limits the edge-smoothing filter so line art and gradients stay clean." : "Turns off the filter that smooths fine detail and grain.",
                             args: anime ? ["--limit-sao"] : ["--no-sao"], visualOnly: true),
                EncodeOption(id: "deblock", title: anime ? "Gentle deblocking (-1)" : "Gentle deblocking (-2)",
                             detail: "Less deblocking keeps texture; live action tolerates -2, animation -1.",
                             args: ["--deblock", anime ? "-1:-1" : "-2:-2"], visualOnly: true),
                EncodeOption(id: "psy", title: grainy ? "Preserve grain energy" : "Preserve texture",
                             detail: grainy ? "Higher psy-rdoq keeps grain looking like grain instead of blotches."
                                            : "Psycho-visual tuning keeps detail the eye notices (psy-rd 2, psy-rdoq 1.5).",
                             args: ["--psy-rd", "2.0", "--psy-rdoq", grainy ? "4.0" : "1.5"], visualOnly: true),
                EncodeOption(id: "nosis", title: "No strong intra smoothing", detail: "Keeps sharp edges in intra-coded blocks.",
                             args: ["--no-strong-intra-smoothing"], visualOnly: true),
                EncodeOption(id: "rd6", title: "Full rate-distortion analysis", detail: "rd 6: the most thorough decisions. Slow; helps grain.",
                             args: ["--rd", "6"], speedCost: 1.25, vmafSaving: 0.01, recommendedFor: [.realLifeHeavyGrain, .oldAnime])
            ]
            return EncodeRecipe(codec: codec, kind: kind, title: "HEVC 12-bit archival · \(kind.displayName.lowercased())",
                                summary: "x265. Slow to slower is the usual archival range; veryslow and placebo add little.",
                                rungs: [
                                    EncodeRung(id: "fast", label: "fast", presetValue: "fast", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "medium", label: "medium", presetValue: "medium", seedSpeed: 0.55, seedSaving: 0.03),
                                    EncodeRung(id: "slow", label: "slow", presetValue: "slow", seedSpeed: 0.25, seedSaving: 0.09),
                                    EncodeRung(id: "slower", label: "slower", presetValue: "slower", seedSpeed: 0.09, seedSaving: 0.12),
                                    EncodeRung(id: "veryslow", label: "veryslow", presetValue: "veryslow", seedSpeed: 0.045, seedSaving: 0.135),
                                    EncodeRung(id: "placebo", label: "placebo", presetValue: "placebo", seedSpeed: 0.012, seedSaving: 0.14)
                                ],
                                options: opts, baseFps1080: 40)
        case .av1Pro:
            return EncodeRecipe(codec: codec, kind: kind, title: "AV1 12-bit / 4:4:4 (libaom)",
                                summary: "libaom: slower than SVT-AV1 but supports 12-bit and full color.",
                                // CPU time per frame relative to cpu-used 6 and the size saved against it at equal quality (mean
                                // of the VMAF and XPSNR BD-rates), measured on an M3 Max over four clips at --threads=4
                                // (tuning-aomenc.md). cpu-used 5 buys little over 6; 4 is where libaom's search opens up.
                                rungs: [
                                    EncodeRung(id: "c6", label: "cpu-used 6", presetValue: "6", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "c5", label: "cpu-used 5", presetValue: "5", seedSpeed: 0.82, seedSaving: 0.029),
                                    EncodeRung(id: "c4", label: "cpu-used 4", presetValue: "4", seedSpeed: 0.40, seedSaving: 0.151),
                                    EncodeRung(id: "c3", label: "cpu-used 3", presetValue: "3", seedSpeed: 0.26, seedSaving: 0.174),
                                    EncodeRung(id: "c2", label: "cpu-used 2", presetValue: "2", seedSpeed: 0.099, seedSaving: 0.216)
                                ],
                                options: [
                                    EncodeOption(id: "aomqm", title: "Quantization matrices", detail: EncodeRecipes.aomQMDetail,
                                                 args: ["--enable-qm=1"], probeFlag: "--enable-qm", speedCost: 1.07, recommendedFor: []),
                                    EncodeOption(id: "aomgrain", title: "Film grain synthesis", detail: EncodeRecipes.aomGrainDetail,
                                                 args: ["--denoise-noise-level=\(EncodeRecipes.aomGrainLevel)"], probeFlag: "--denoise-noise-level",
                                                 speedCost: EncodeRecipes.aomGrainSpeedCost, recommendedFor: [])
                                ], baseFps1080: 8)
        case .vvc:
            // CPU time per frame relative to faster and the size saved against faster at equal quality (mean of the VMAF
            // and XPSNR BD-rates), measured on an M3 Max over four clips at --threads 4; slower on one clip, scaled from
            // slow (tuning-vvenc.md). medium stays the default: slow costs 3.2x its time for about 4% more.
            return EncodeRecipe(codec: codec, kind: kind, title: "H.266 / VVC (VVenC)",
                                summary: "VVenC presets. medium is the balance point, slow the efficient archival choice; slower adds about 3% for 4x the time.",
                                rungs: [
                                    EncodeRung(id: "faster", label: "faster", presetValue: "faster", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "fast", label: "fast", presetValue: "fast", seedSpeed: 0.40, seedSaving: 0.102),
                                    EncodeRung(id: "medium", label: "medium", presetValue: "medium", seedSpeed: 0.118, seedSaving: 0.168),
                                    EncodeRung(id: "slow", label: "slow", presetValue: "slow", seedSpeed: 0.037, seedSaving: 0.204),
                                    EncodeRung(id: "slower", label: "slower", presetValue: "slower", seedSpeed: 0.0085, seedSaving: 0.232)
                                ], options: [], baseFps1080: 14)
        case .hevc:
            return EncodeRecipe(codec: codec, kind: kind, title: "HEVC on the media engine",
                                summary: "Apple's hardware encoder: dozens of times faster than x265, about 15–25% larger files at the same quality.",
                                rungs: [EncodeRung(id: "vt", label: "Media engine", presetValue: "", seedSpeed: 1.0, seedSaving: 0)],
                                options: [], baseFps1080: 420)
        default:
            return EncodeRecipe(codec: codec, kind: kind, title: codec.displayName, summary: "",
                                rungs: [EncodeRung(id: "default", label: "Default", presetValue: "", seedSpeed: 1.0, seedSaving: 0)],
                                options: [], baseFps1080: 200)
        }
    }

    // MARK: - SVT-AV1 rules (docs/encoding/tuning-svtav1.md)

    static let svtBinary = "SvtAv1EncApp"

    /// SVT-AV1's `--lp` is a level of parallelism from 0 to 6, not a thread count; v4.3.0 clamps anything above 6
    /// with a warning. Maps the cores one encoder instance is meant to fill to a level.
    static func svtParallelism(cores: Int) -> Int {
        switch cores {
        case ..<2: return 1
        case 2: return 2
        case 3...5: return 3
        case 6...11: return 4
        case 12...23: return 5
        default: return 6
        }
    }

    /// SVT-AV1 film-grain level per content kind, shared by the planner's "grain" extra and the encoders.json grain
    /// tune ({svt_grain}); both denoise (--film-grain-denoise 1), because Lumora scores grain synthesis against a
    /// de-grained master. Measured on the tuning clips: heavy film grain 12, grainy old animation 8, low-light
    /// sensor noise 4. Kinds without grain only get it when the user asks; they keep the old defaults.
    static func svtGrainLevel(_ kind: ContentKind) -> Int {
        switch kind {
        case .realLifeHeavyGrain: return 12
        case .oldAnime: return 8
        case .lowLightNoisy: return 4
        case .anime: return 4
        default: return 8
        }
    }

    /// Lowest (steepest) quantization matrix SVT-AV1 may use. 0, the community suggestion, lost 3-8% XPSNR BD-rate on
    /// every clip; flatter minimums won where both VMAF and XPSNR agreed (tuning-svtav1.md).
    static func svtQMMin(_ kind: ContentKind) -> Int {
        switch kind {
        case .anime, .cgiAnimation, .lowLightNoisy: return 8
        case .realLife, .oldAnime: return 6
        default: return 4
        }
    }

    /// The flattest QM minimum for PQ (HDR10) output, measured on live action graded to PQ.
    static let svtQMMinPQ = 8

    /// Adjusts SVT-AV1 options for the output transfer. For PQ (HDR10): `--luminance-qp-bias` judges a frame by its
    /// mean code value as if it were SDR, which Codec Wiki advises against and which cost XPSNR BD-rate on Lumora's
    /// PQ clips, so it is dropped; and quantization matrices stay flatter (`--qm-min 8`).
    static func svtArgs(_ args: [String], pq: Bool) -> [String] {
        guard pq else { return args }
        var out: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--luminance-qp-bias" { i += 2; continue }
            if a == "--qm-min", i + 1 < args.count {
                out += [a, "\(max(svtQMMinPQ, Int(args[i + 1]) ?? 0))"]
                i += 2; continue
            }
            out.append(a)
            i += 1
        }
        return out
    }

    /// Whether these AV1 encoder arguments make the encoder synthesize film grain: SVT-AV1 `--film-grain N` or libaom
    /// `--denoise-noise-level=N` with N > 0. Lumora then scores against a de-grained master with the grain stripped.
    static func synthesizesGrain(_ args: [String]) -> Bool {
        for (i, a) in args.enumerated() {
            if a == "--film-grain", i + 1 < args.count, (Int(args[i + 1]) ?? 1) > 0 { return true }   // a {placeholder} counts
            if a.hasPrefix("--denoise-noise-level="), (Int(a.dropFirst("--denoise-noise-level=".count)) ?? 1) > 0 { return true }
        }
        return false
    }

    // MARK: - VVenC rules (docs/encoding/tuning-vvenc.md)

    /// Whether VVenC keeps its perceptual QP adaptation (`--qpa 1`, the vvencapp default). Turning it off was smaller at
    /// equal VMAF *and* at equal XPSNR (the metric QPA is built on) on low-light footage and on live action graded to
    /// PQ, and costs about 25% less CPU time. Everywhere else QPA's XPSNR gain outweighs what VMAF says, so it stays on.
    static func vvencQPA(kind: ContentKind, pq: Bool) -> Bool {
        !(pq || kind == .lowLightNoisy)
    }

    // MARK: - libaom rules (docs/encoding/tuning-aomenc.md)

    /// libaom's own grain synthesis (`--denoise-noise-level`) was larger at equal VMAF and XPSNR than coding the grain, on
    /// heavy grain, low light and old animation, against both Lumora's de-grained master and the noise-free original, at
    /// every level from 4 to 16 (+3% to +26%, more the higher the level), and 15-35% slower: its denoiser removed so
    /// little that the bitrate hardly fell, and the synthetic grain lands on top of the coded grain. It is no longer
    /// recommended; when turned on it uses the least harmful level measured.
    static let aomGrainLevel = 4
    static let aomGrainSpeedCost = 1.3
    static let aomGrainDetail = "libaom's noise model denoises lightly and re-creates grain on playback. Measured larger than coding the grain on every grainy test clip, so it is off unless you turn it on; SVT-AV1's grain synthesis is the one that saves space."

    /// libaom's default quantization matrices (qm-min 5 to qm-max 9) were larger at equal XPSNR on every tuning clip
    /// (+0.8% to +5.8%) for at most 1.6% at equal VMAF and 4-16% more CPU time, so the planner no longer turns them on.
    static let aomQMDetail = "Frequency-shaped quantization. Measured larger at equal XPSNR on every test clip and slower, so it is off unless you turn it on."

    /// `--profile` for aomenc. AV1 puts 10-bit 4:4:4 in the High profile (1) and 4:2:2 or any 12-bit stream in the
    /// Professional profile (2). aomenc 3.15.3 stops with "Failed to set chroma subsampling x" when `--profile=2` is
    /// passed with 12-bit 4:2:2 or 4:4:4 input, but raises profile 0 to 2 itself for that input (checked: the streams
    /// are Professional profile, 12-bit, and decode to the same quality as 12-bit 4:2:0 at the same cq-level).
    static func aomProfile(bitDepth: Int, chroma: ChromaFormat) -> String {
        if bitDepth >= 12 { return chroma == .c420 ? "2" : "0" }   // 0: aomenc raises it to 2 (an explicit 2 is refused)
        switch chroma {
        case .c420: return "0"
        case .c422: return "2"
        case .c444: return "1"
        }
    }

    /// Flags the installed encoder actually understands (parsed once from its --help), so options from
    /// newer versions or forks are only offered when they'll work.
    private static var flagCache: [String: Set<String>] = [:]
    private static let lock = NSLock()

    static func supportedFlags(_ binary: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        if let c = flagCache[binary] { return c }
        guard let exe = ToolLocator.url(for: binary) else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--help"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let flags = Set(text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "=" || $0 == "[" })
                        .map(String.init).filter { $0.hasPrefix("--") })
        flagCache[binary] = flags
        Log.debug(.tools, "\(binary) supports \(flags.count) flags")
        return flags
    }

    static func available(_ o: EncodeOption, codec: Codec) -> Bool {
        guard let flag = o.probeFlag, let key = o.encoderKey ?? codec.cliKey, let spec = EncoderCatalog.shared.spec(for: key),
              let flags = supportedFlags(spec.binary) else { return true }
        return flags.contains(flag)
    }

    static func available(_ r: EncodeRung, codec: Codec) -> Bool {
        guard let key = r.encoderKey, let spec = EncoderCatalog.shared.spec(for: key) else { return true }
        return ToolLocator.isAvailable(spec.binary)
    }
}
