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
            let grainLevel = kind == .realLifeHeavyGrain ? 12 : (anime ? 4 : 8)
            var opts: [EncodeOption] = [
                EncodeOption(id: "varboost", title: "Protect flat and dark areas",
                             detail: "Variance boost gives low-contrast areas (skies, shadows, flat colour) more bits. Consistent gains in SVT-AV1 3.x tests.",
                             args: ["--enable-variance-boost", "1"], probeFlag: "--enable-variance-boost", speedCost: 1.01, vmafSaving: 0.02),
                EncodeOption(id: "qm", title: "Quantization matrices",
                             detail: "Frequency-shaped quantization; usually a small efficiency win, more so with a lower minimum level.",
                             args: ["--enable-qm", "1", "--qm-min", "4"], probeFlag: "--enable-qm", vmafSaving: 0.015,
                             recommendedFor: ContentKind.allCases.filter { $0 != .screenContent }),
                EncodeOption(id: "lookahead", title: "Deeper look-ahead",
                             detail: "Plans bit allocation over more frames. Small gain, small cost.",
                             args: ["--lookahead", "120"], probeFlag: "--lookahead", speedCost: 1.03, vmafSaving: 0.005),
                EncodeOption(id: "sharp", title: anime ? "Crisper line art" : "Sharper fine detail",
                             detail: "Gentler deblocking and sharper rate-distortion decisions. Looks more like the source; VMAF barely notices.",
                             args: ["--sharpness", anime ? "2" : "1"], probeFlag: "--sharpness", visualOnly: true),
                EncodeOption(id: "tf", title: anime || grainy ? "No temporal smoothing" : "Gentle temporal filter",
                             detail: anime || grainy ? "Turns off the temporal filter that can smear grain and line art." : "Keeps texture that the temporal filter would soften.",
                             args: anime || grainy ? ["--enable-tf", "0"] : ["--tf-strength", "1"],
                             probeFlag: anime || grainy ? "--enable-tf" : "--tf-strength", visualOnly: true),
                EncodeOption(id: "lumabias", title: "Brighter handling of dark scenes",
                             detail: "Biases quality toward dark areas, where AV1 artifacts show first.",
                             args: ["--luminance-qp-bias", "25"], probeFlag: "--luminance-qp-bias", visualOnly: true,
                             recommendedFor: [.realLife, .realLifeHeavyGrain, .lowLightNoisy, .oldAnime]),
                EncodeOption(id: "grain", title: "Film grain synthesis (level \(grainLevel))",
                             detail: "Removes the grain before encoding and describes it instead; the player re-creates it. Much smaller files for grainy sources. Quality checks score the picture with the synthetic grain stripped, against a de-grained master, so the comparison is fair.",
                             args: ["--film-grain", "\(grainLevel)", "--film-grain-denoise", "1"], probeFlag: "--film-grain", speedCost: 1.04,
                             vmafSaving: grainy ? 0.15 : 0.05,
                             recommendedFor: [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy]),
                EncodeOption(id: "grainTable", title: "Grain measured from this film",
                             detail: "Lumora measures the grain of this exact film (strength per brightness) and hands the encoder a matching grain table, instead of the encoder's own estimate.",
                             args: ["--fgs-table", "{grain_table}"], probeFlag: "--fgs-table", speedCost: 1.0,
                             vmafSaving: grainy ? 0.02 : 0, visualOnly: true,
                             recommendedFor: [.realLifeHeavyGrain, .oldAnime])
            ]
            // libaom options (used only on the libaom rungs of this ladder).
            opts += [
                EncodeOption(id: "aomqm10", title: "Quantization matrices (libaom)", detail: "Small efficiency gain.",
                             args: ["--enable-qm=1"], probeFlag: "--enable-qm", vmafSaving: 0.015, encoderKey: "aomenc"),
                EncodeOption(id: "aomgrain10", title: "Film grain synthesis (libaom)",
                             detail: "libaom's noise model removes the grain and re-creates it on playback; scored with the synthetic grain stripped.",
                             args: ["--denoise-noise-level=\(grainLevel)"], probeFlag: "--denoise-noise-level", speedCost: 1.05,
                             vmafSaving: grainy ? 0.13 : 0.04, recommendedFor: [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy], encoderKey: "aomenc"),
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
                                summary: "SVT-AV1 for nearly everything (preset 4 is the balance point, 2 the efficient high end). For archival runs with days to spare, the ladder continues into libaom, which is marginally smaller at its slowest settings.",
                                rungs: [
                                    EncodeRung(id: "p10", label: "Preset 10", presetValue: "10", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "p8", label: "Preset 8", presetValue: "8", seedSpeed: 0.55, seedSaving: 0.093),
                                    EncodeRung(id: "p6", label: "Preset 6", presetValue: "6", seedSpeed: 0.20, seedSaving: 0.167),
                                    EncodeRung(id: "p5", label: "Preset 5", presetValue: "5", seedSpeed: 0.13, seedSaving: 0.185),
                                    EncodeRung(id: "p4", label: "Preset 4", presetValue: "4", seedSpeed: 0.085, seedSaving: 0.204),
                                    EncodeRung(id: "p3", label: "Preset 3", presetValue: "3", seedSpeed: 0.058, seedSaving: 0.213),
                                    EncodeRung(id: "p2", label: "Preset 2", presetValue: "2", seedSpeed: 0.040, seedSaving: 0.222),
                                    EncodeRung(id: "p1", label: "Preset 1", presetValue: "1", seedSpeed: 0.020, seedSaving: 0.226),
                                    EncodeRung(id: "p0", label: "Preset 0", presetValue: "0", seedSpeed: 0.009, seedSaving: 0.229),
                                    // libaom: marginally smaller at its slowest settings, for a very large time cost.
                                    EncodeRung(id: "aom4", label: "libaom cpu-used 4", presetValue: "4", seedSpeed: 0.020, seedSaving: 0.214, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom3", label: "libaom cpu-used 3", presetValue: "3", seedSpeed: 0.011, seedSaving: 0.224, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom2", label: "libaom cpu-used 2", presetValue: "2", seedSpeed: 0.005, seedSaving: 0.231, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom1", label: "libaom cpu-used 1", presetValue: "1", seedSpeed: 0.0025, seedSaving: 0.236, encoderKey: "aomenc"),
                                    EncodeRung(id: "aom0", label: "libaom cpu-used 0", presetValue: "0", seedSpeed: 0.0010, seedSaving: 0.240, encoderKey: "aomenc")
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
                                summary: "libaom: slower than SVT-AV1 but supports 12-bit and full colour.",
                                rungs: [
                                    EncodeRung(id: "c6", label: "cpu-used 6", presetValue: "6", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "c5", label: "cpu-used 5", presetValue: "5", seedSpeed: 0.5, seedSaving: 0.03),
                                    EncodeRung(id: "c4", label: "cpu-used 4", presetValue: "4", seedSpeed: 0.25, seedSaving: 0.06),
                                    EncodeRung(id: "c3", label: "cpu-used 3", presetValue: "3", seedSpeed: 0.12, seedSaving: 0.09),
                                    EncodeRung(id: "c2", label: "cpu-used 2", presetValue: "2", seedSpeed: 0.05, seedSaving: 0.11)
                                ],
                                options: [
                                    EncodeOption(id: "aomqm", title: "Quantization matrices", detail: "Small efficiency gain.",
                                                 args: ["--enable-qm=1"], probeFlag: "--enable-qm", vmafSaving: 0.015),
                                    EncodeOption(id: "aomgrain", title: "Film grain synthesis", detail: "Removes grain before encoding and re-creates it on playback; scored with the synthetic grain stripped.",
                                                 args: ["--denoise-noise-level=10"], probeFlag: "--denoise-noise-level", speedCost: 1.05,
                                                 vmafSaving: grainy ? 0.12 : 0.04,
                                                 recommendedFor: [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy])
                                ], baseFps1080: 8)
        case .vvc:
            return EncodeRecipe(codec: codec, kind: kind, title: "H.266 / VVC (VVenC)", summary: "VVenC presets; slow is the efficient choice.",
                                rungs: [
                                    EncodeRung(id: "faster", label: "faster", presetValue: "faster", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "fast", label: "fast", presetValue: "fast", seedSpeed: 0.45, seedSaving: 0.06),
                                    EncodeRung(id: "medium", label: "medium", presetValue: "medium", seedSpeed: 0.18, seedSaving: 0.11),
                                    EncodeRung(id: "slow", label: "slow", presetValue: "slow", seedSpeed: 0.07, seedSaving: 0.14),
                                    EncodeRung(id: "slower", label: "slower", presetValue: "slower", seedSpeed: 0.03, seedSaving: 0.15)
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
