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
                             detail: "Variance boost gives low-contrast areas (skies, shadows, flat color) more bits. Consistent gains in SVT-AV1 3.x tests.",
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
            // Values, speed costs and savings measured on this Mac at preset slow (docs/encoding/tuning-x265.md).
            let psy = x265Psy(kind)
            var opts: [EncodeOption] = [
                EncodeOption(id: "aq3", title: "Protect dark scenes",
                             detail: "AQ mode 3: adaptive quantization with a bias toward dark areas, where banding and blocking show first."
                                + (x265AQStrength(kind).map { " Strength \($0) for flat animation, which saves bits on plain areas." } ?? ""),
                             args: ["--aq-mode", "3"] + (x265AQStrength(kind).map { ["--aq-strength", $0] } ?? []), visualOnly: true,
                             recommendedFor: ContentKind.allCases.filter { $0 != .screenContent }),
                EncodeOption(id: "bframes", title: anime ? "16 B-frames" : "8 B-frames",
                             detail: "More bidirectional frames. Measured here: no smaller at equal quality, and clearly slower.",
                             args: ["--bframes", anime ? "16" : "8"], speedCost: anime ? 1.54 : 1.19, vmafSaving: 0),
                EncodeOption(id: "ref", title: "6 reference frames", detail: "More frames to predict from. Measured here: no smaller, 12% slower.",
                             args: ["--ref", "6"], speedCost: 1.12, vmafSaving: 0),
                EncodeOption(id: "rclook", title: "60-frame look-ahead",
                             detail: kind == .anime ? "Rate planning over longer stretches; about 2% smaller on flat animation, 11% slower."
                                                    : "Rate planning over longer stretches. Measured here: no smaller, 10% slower.",
                             args: ["--rc-lookahead", "60"], speedCost: 1.10, vmafSaving: kind == .anime ? 0.02 : 0),
                EncodeOption(id: "sao", title: anime ? "Limited SAO" : "SAO off (keep detail)",
                             detail: anime ? "Limits the edge-smoothing filter so line art and gradients stay clean." : "Turns off the filter that smooths fine detail and grain.",
                             args: anime ? ["--limit-sao"] : ["--no-sao"], visualOnly: true),
                EncodeOption(id: "deblock", title: anime ? "Gentle deblocking (-1)" : "Gentle deblocking (-2)",
                             detail: "Less deblocking keeps texture; live action tolerates -2, animation -1.",
                             args: ["--deblock", anime ? "-1:-1" : "-2:-2"], visualOnly: true),
                EncodeOption(id: "psy", title: grainy ? "Preserve grain energy" : "Preserve texture",
                             detail: grainy ? "Higher psy-rdoq keeps grain looking like grain instead of blotches (psy-rd \(psy.rd), psy-rdoq \(psy.rdoq))."
                                            : "Psycho-visual tuning keeps detail the eye notices (psy-rd \(psy.rd), psy-rdoq \(psy.rdoq)).",
                             args: ["--psy-rd", psy.rd, "--psy-rdoq", psy.rdoq], visualOnly: true),
                EncodeOption(id: "nosis", title: "No strong intra smoothing", detail: "Keeps sharp edges in intra-coded blocks.",
                             args: ["--no-strong-intra-smoothing"], visualOnly: true),
                EncodeOption(id: "rd6", title: "Full rate-distortion analysis", detail: "rd 6: the most thorough decisions. Much slower; pays off on noisy dark footage.",
                             args: ["--rd", "6"], speedCost: 1.78, vmafSaving: x265RD6Saving(kind), recommendedFor: x265RD6Kinds)
            ]
            if kind == .screenContent {
                opts.append(EncodeOption(id: "tskip", title: "Transform skip for text and UI",
                                         detail: "Lets small blocks skip the transform, which keeps sharp synthetic edges such as text.",
                                         args: ["--tskip"], probeFlag: "--tskip", vmafSaving: 0.08, recommendedFor: [.screenContent]))
            }
            return EncodeRecipe(codec: codec, kind: kind, title: "HEVC 12-bit archival · \(kind.displayName.lowercased())",
                                summary: "x265. Slow to slower is the usual archival range; veryslow and placebo add little.",
                                // Measured on an M3 Max at 1080p (docs/encoding/tuning-x265.md): CPU-time speed relative to
                                // `faster`, and saving at equal quality (mean of the VMAF and XPSNR BD-rates). `fast` is left
                                // out: it was slower than `medium` (it turns off early skip) and 3% larger.
                                rungs: [
                                    EncodeRung(id: "faster", label: "faster", presetValue: "faster", seedSpeed: 1.0, seedSaving: 0),
                                    EncodeRung(id: "medium", label: "medium", presetValue: "medium", seedSpeed: 0.62, seedSaving: 0.073),
                                    EncodeRung(id: "slow", label: "slow", presetValue: "slow", seedSpeed: 0.19, seedSaving: 0.215),
                                    EncodeRung(id: "slower", label: "slower", presetValue: "slower", seedSpeed: 0.048, seedSaving: 0.26),
                                    EncodeRung(id: "veryslow", label: "veryslow", presetValue: "veryslow", seedSpeed: 0.029, seedSaving: 0.269),
                                    EncodeRung(id: "placebo", label: "placebo", presetValue: "placebo", seedSpeed: 0.0124, seedSaving: 0.287)
                                ],
                                options: opts, baseFps1080: 39)
        case .av1Pro:
            return EncodeRecipe(codec: codec, kind: kind, title: "AV1 12-bit / 4:4:4 (libaom)",
                                summary: "libaom: slower than SVT-AV1 but supports 12-bit and full color.",
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

    /// Flags the installed encoder actually understands (parsed once from its help), so options from
    /// newer versions or forks are only offered when they'll work.
    private static var flagCache: [String: Set<String>] = [:]
    private static let lock = NSLock()

    /// Help arguments to try per encoder, most complete first. x265's `--help` leaves out about 50 options that
    /// `--fullhelp` lists (`--y4m`, `--qcomp`, `--zones`, …; compared on 4.3+1), so x265 is asked for `--fullhelp`
    /// and falls back to `--help` on builds that don't know it.
    static func helpArguments(_ binary: String) -> [String] {
        binary == "x265" ? ["--fullhelp", "--help"] : ["--help"]
    }

    /// Every `--flag` in a help text. `--[no-]name` (x265, VVenC) counts as both `--name` and `--no-name`, and
    /// `-b/--bframes` (x265's short/long pairs) as `--bframes`.
    static func parseFlags(_ text: String) -> Set<String> {
        var flags = Set<String>()
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "=" || $0 == "/" }) {
            var w = String(word)
            if w.hasPrefix("--[no-]") {
                let name = String(w.dropFirst(7)).split(separator: "[").first.map(String.init) ?? ""
                if !name.isEmpty { flags.insert("--" + name); flags.insert("--no-" + name) }
                continue
            }
            if let bracket = w.firstIndex(of: "[") { w = String(w[..<bracket]) }
            if w.hasPrefix("--"), w.count > 2 { flags.insert(w) }
        }
        return flags
    }

    static func supportedFlags(_ binary: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        if let c = flagCache[binary] { return c }
        guard let exe = ToolLocator.url(for: binary) else { return nil }
        var flags = Set<String>()
        for arg in helpArguments(binary) {
            let p = Process()
            p.executableURL = exe
            p.arguments = [arg]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            flags = parseFlags(String(decoding: data, as: UTF8.self))
            // An unknown help argument prints an error (and maybe a short usage line), not the option list.
            if flags.count >= 20 { break }
        }
        flagCache[binary] = flags
        Log.debug(.tools, "\(binary) supports \(flags.count) flags")
        return flags
    }

    // MARK: - x265 rules applied to the final command line

    static let x265Binary = "x265"

    /// psy-rd / psy-rdoq per content type. Live action, CG, fast motion and screen content: 1.0 / 1.0 (about 2% smaller
    /// than 2.0 / 1.5 on VMAF and XPSNR). Grainy kinds keep psy-rdoq 4.0, which holds the grain (lower values look
    /// better to VMAF and worse to XPSNR and to the grain measurement). Anime keeps 2.0 / 1.5 (1.0 missed the 1% bar).
    static func x265Psy(_ kind: ContentKind) -> (rd: String, rdoq: String) {
        switch kind {
        case .realLifeHeavyGrain, .lowLightNoisy, .oldAnime: return ("2.0", "4.0")
        case .anime: return ("2.0", "1.5")
        case .realLife, .cgiAnimation, .fastMotion, .screenContent: return ("1.0", "1.0")
        }
    }

    /// AQ strength with AQ mode 3, where it differs from x265's 1.0: 0.8 for flat modern anime (3% smaller).
    static func x265AQStrength(_ kind: ContentKind) -> String? {
        kind == .anime ? "0.8" : nil
    }

    /// Content types where `--rd 6` saves bits: 4% on low light, 7% on old anime (mean of the VMAF and XPSNR BD-rates),
    /// for 64-91% more CPU time. Nothing on heavy grain, where it used to be offered.
    static let x265RD6Kinds: [ContentKind] = [.lowLightNoisy, .oldAnime]
    static func x265RD6Saving(_ kind: ContentKind) -> Double {
        switch kind {
        case .lowLightNoisy: return 0.04
        case .oldAnime: return 0.07
        default: return 0
        }
    }

    /// x265 presets that leave rate-distortion optimized quantization off (`--rdoq-level 0`); x265's preset table.
    static let x265PresetsWithoutRDOQ: Set<String> = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium"]

    /// The x265 command line with the options that can't work in this combination removed:
    /// - `--hdr10-opt` (PQ-aware QP) works only for 10-bit 4:2:0; at 12-bit or 4:2:2/4:4:4 x265 logs an error,
    ///   disables it and still exits 0 ([x265-cli]; checked on 4.3+1).
    /// - `--psy-rdoq` acts inside RDOQ, which the presets up to `medium` turn off (`--rdoq-level 0`), so there it is
    ///   dropped unless the command line also sets `--rdoq-level` 1 or 2 ([x265-cli]; bit-identical output measured).
    ///
    /// Without a plan (`planned` false) the content type's base extras are appended, the same ones the planner always
    /// turns on, so an export with and without the planner encodes a content type the same way. x265's own
    /// `--tune grain` and `--tune animation` are not used: explicit options override what a tune sets, and on the
    /// measured clips both tunes lost to Lumora's per-type settings (docs/encoding/tuning-x265.md).
    static func x265Args(_ args: [String], bits: Int, chroma: ChromaFormat, preset: String,
                         kind: ContentKind? = nil, planned: Bool = true) -> [String] {
        var out: [String] = []
        let args = args + (planned || kind == nil ? [] : x265BaseOptions(kind!).flatMap(\.args))
        let explicitRDOQ = args.firstIndex(of: "--rdoq-level").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let rdoqOn = explicitRDOQ.map { $0 != "0" } ?? !x265PresetsWithoutRDOQ.contains(preset)
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--hdr10-opt" && !(bits == 10 && chroma == .c420) { i += 1; continue }
            if a == "--psy-rdoq" && !rdoqOn { i += 2; continue }
            out.append(a)
            i += 1
        }
        return out
    }

    /// The x265 extras the planner always enables for a content type: recommended for it and cheap (at most 5% slower).
    static func x265BaseOptions(_ kind: ContentKind) -> [EncodeOption] {
        recipe(codec: .hevc12, kind: kind).options.filter { $0.recommendedFor.contains(kind) && $0.speedCost <= 1.05 && available($0, codec: .hevc12) }
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
