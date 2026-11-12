---
title: SVT-AV1
parent: Encoding settings
nav_order: 2
---

{% raw %}

# SVT-AV1

**Documented version:** SVT-AV1 v4.3.0 (release) · **Codec:** AV1 · **License:** BSD 3-Clause Clear License plus the Alliance for Open Media Patent License 1.0 · **Homepage:** <https://gitlab.com/AOMediaCodec/SVT-AV1> · **Homebrew:** [`svt-av1`](https://formulae.brew.sh/formula/svt-av1)

SVT-AV1 is the Alliance for Open Media's production AV1 encoder (Scalable Video Technology, originally from Intel and Netflix). Its strengths are good multi-core scaling, a very wide preset range from research-slow to real-time, solid efficiency around presets 2-6, and built-in film-grain synthesis plus perceptual tools ported from the community PSY forks (variance boost, AC bias, sharpness, IQ tune). Its weaknesses: the installed build only encodes 4:2:0 at 8 or 10 bits, it never places keyframes at scene cuts, it has no HDR10+ or Dolby Vision options in the stand-alone CLI, and the many forks and fast-moving defaults make guides go stale quickly.

**Bit depths:** 8, 10 · **Chroma:** 4:2:0

Machine-readable data: [`data/svtav1.json`](data/svtav1.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

Feed a 10-bit Y4M (or raw YUV with `--input-depth` 10) that is already PQ or HLG encoded; SVT-AV1 does not convert transfer functions or bit depth. Signal the color description with `--color-primaries` 9 (bt2020), `--transfer-characteristics` 16 (smpte2084, HDR10/PQ) or 18 (hlg), `--matrix-coefficients` 9 (bt2020-ncl) and `--color-range` 0 (studio). For HDR10, add static metadata with `--mastering-display` 'G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)' where the luminance values are plain nits (floats), and `--content-light` MaxCLL,MaxFALL as integers. `--chroma-sample-position` topleft (colocated) follows the official HDR example and the usual siting of BT.2020 UHD masters. HLG normally needs only the color description. The stand-alone CLI has no HDR10+ or Dolby Vision input; FFmpeg's libsvtav1 wrapper can pass through Dolby Vision RPUs (-dolbyvision) and copies mastering/CLL side data when it is present on the input stream.

**Flags involved:** `--input-depth`, `--color-primaries`, `--transfer-characteristics`, `--matrix-coefficients`, `--color-range`, `--chroma-sample-position`, `--mastering-display`, `--content-light`, `--color-help`

**Example (HDR10):**

```bash
SvtAv1EncApp -i master_pq_10bit.y4m -b out.ivf --preset 4 --crf 27 --input-depth 10 --color-primaries 9 --transfer-characteristics 16 --matrix-coefficients 9 --color-range 0 --chroma-sample-position topleft --mastering-display 'G(0.2650,0.6900)B(0.1500,0.0600)R(0.6800,0.3200)WP(0.3127,0.3290)L(1000,0.0001)' --content-light 1000,400 --enable-variance-boost 1 --keyint 10s
```

**Pitfalls:**

- Luminance values in `--mastering-display` are nits as decimals (L(1000,0.0001)), not the 0.0001-cd/m2 integer units x265 uses; primaries are written G, B, R, then white point.
- `--input-depth` only accepts 8 or 10 and describes the input file as well as the output; an 8-bit pipe cannot become a real HDR encode, and there is no 12-bit or 4:2:2/4:4:4 support in this build (use libaom for those).
- `--luminance-qp-bias` assumes a gamma-like signal; the Codec Wiki parameter study says to use it only on SDR and HLG, not on PQ (HDR10) material.
- Mainline variance boost curves are not PQ-aware; the PQ-tuned curve (`--variance-boost-curve` 3) exists only in the svt-av1-hdr fork, so do not copy fork command lines into mainline.
- The IVF output carries the color description in the AV1 sequence header and HDR10 static metadata in metadata OBUs; when remuxing, check that the container also gets matching color tags, since some muxers do not derive them from the bitstream.
- `--content-light` 0,0 means unknown; supply real MaxCLL/MaxFALL when you have measured them.
- No `--hdr10plus-json` or `--dolby-vision-rpu` in the installed mainline CLI (those are svt-av1-hdr fork options); dynamic metadata must be handled by FFmpeg (-dolbyvision) or added at mux time.
- FFmpeg's -crf for libsvtav1 is an integer 0-63; fractional or >63 CRF needs -svtav1-params crf=..., and -svtav1-params is parsed last so it overrides FFmpeg-level color fields.
- HDR sources are often 4K or larger: v4.3.0 caps random-access encodes at preset 9 at 4K and above, and rejects presets 4 and below above 4K (for example 8K).

## Presets

| Preset | Speed | Notes |
|---|---|---|
| -1 | Slowest (research mode, MR); somewhat slower than preset 0 | Reference point in the Codec Wiki v3.0 study; preset 0 averaged only about 1% worse BD-rate. In v1.8 tests preset 4 was about 50-60x faster than -1. The help calls negative presets debugging presets. Not worth it for real encodes. |
| 0 | Extremely slow; about 5-10x slower than preset 4 in v1.8 tests | About 0.97% worse than -1 (v3.0, average of SSIMULACRA2/Butteraugli/XPSNR/W-VMAF). Codec Wiki v2.2 tests advised against spending time on 0 and -1 except at extremely low quality targets; Streaming Learning Center suggests it only for files with millions of views. |
| 1 | Very slow; roughly 2x slower than preset 2 | About 3.79% worse than -1 in v3.0 tests; only a narrow gain over preset 2. |
| 2 | Slow; slightly more than 2x faster than preset 1 and about 2x slower than preset 3 | About 7.82% worse than -1, i.e. close to preset 1. Codec Wiki calls presets 2 and 4 the best value for the time spent among the slower presets. |
| 3 | Slow; about 1.5x faster than preset 2 (v2.2 tests) | About 17.08% worse than -1 in v3.0; there is a large efficiency step between 2 and 3, and preset 4 is close behind 3. |
| 4 | Moderate; roughly 2x faster than preset 2 in v1.8 tests; there is a large speed jump from 4 to 5 | About 22.41% worse than -1 in v3.0, but very close to preset 3. Widely used as the balance point (Codec Wiki deep dives; Streaming Learning Center measured 98.92% of the best VMAF at 3.5% of the encode time on v1.4). Lumora's default. Above 4K (for example 8K), v4.3.0 rejects presets 4 and below for video encodes (all-intra excepted) because of memory use. |
| 5 | Moderately fast; much faster than 4 | In v3.0 about 44% faster than in v2.0 but about 4.5% less efficient (worse on gaming clips). Good start of the 'fast but still good' range. |
| 6 | Fast | v3.0 about 47% faster than v2.0 at 8.8% lower efficiency. Codec Wiki suggests 6 or 8 if 4 is too slow. Highest preset that does not print the film-grain compute-overhead warning (the warning fires above preset 6 when `--film-grain` is on). |
| 7 | Fast | v3.0 about 68% faster than v2.0 for about 11.6% efficiency loss; preset 8 sometimes matches or beats it. |
| 8 | Fast (library default) | Codec Wiki considers 8 the last truly usable preset in v3.0 and found it occasionally equal to 6 by W-VMAF. Film grain above preset 6 triggers a compute-overhead warning. |
| 9 | Very fast | Codec Wiki saw non-monotonic, inconsistent quality at low CRF for 9 and 10. In v4.3.0 random-access encodes at 4K and above are capped to preset 9. |
| 10 | Very fast | Outside `--rtc`, v4.3.0 warns that M10 and faster are meant for automation tooling and may show artifacts. Not recommended for quality work. |
| 11 | Fastest random-access (VOD) preset in v4.3.0 | Speed/testing use only. The v3.0 changelog speaks of a max of M10; the v4.3.0 source clamps random-access presets above 11 to 11, so whether 11 differs from 10 for VOD was not verified. |
| 12 | Same as 11 for VOD | Mapped to M11 with a warning in random-access mode (v4.3.0 source); distinct only with `--rtc`. |
| 13 | Same as 11 for VOD; fastest RTC preset | Mapped to M11 in random access; with `--rtc` it is labeled experimental and meant for speed evaluation. |

## Rate control

| Mode | Flags | Notes |
|---|---|---|
| CRF (constant rate factor) | --rc 0 --crf <1-70> (0.25 steps) | Default and recommended for home/archival use. Equivalent to `--rc` 0 `--aq-mode` 2 `--qp` x. Values above 63 use the extended quarter-step range added in v4.0. |
| CQP (fixed quantizer) | --cqp <1-70> or --rc 0 --aq-mode 0 --qp <1-63> | Turns adaptive QP off; useful for experiments and per-frame QP files, less efficient for real encodes. |
| Capped CRF | --rc 0 --crf <n> --mbr <kbps> [--mbr-overshoot-pct] | Quality-targeted encode with a bitrate ceiling, useful for streaming ladders. |
| Multi-pass CRF | --passes 2 --rc 0 --crf <n> [--stats file] | The project says extra passes in CRF mainly help corner cases such as high motion; usually not critical. |
| VBR one-pass | --rc 1 --tbr <kbps> [--lookahead] | Targets an average bitrate; less efficient than CRF; rate tolerance via `--undershoot-pct`/--overshoot-pct. |
| VBR two-pass | --passes 2 --rc 1 --tbr <kbps> --stats file (or --pass 1 / --pass 2) | Best way to hit a file size; `--gop-constraint-rc` 1 matches rate per GOP when GOP > 119 frames. |
| CBR | --rc 2 --tbr <kbps> [--buf-sz --buf-initial-sz --buf-optimal-sz] (usually with --pred-struct 1 or --rtc) | Always single pass; for real-time/low-delay streaming. Variance boost is disabled automatically in CBR. |

## Recipes

### Balanced archive, live action (SDR)

**Goal:** Small file, transparent-looking quality, reasonable time · **Content:** live action

```bash
--preset 4 --crf 30 --input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0 --tf-strength 1 --keyint 10s --irefresh-type 2
```

Preset 4 is the community balance point; variance boost, QMs and weaker temporal filtering each tested positive; long closed GOPs suit home playback. CRF is a starting point to adjust by eye or metric.

Sources: [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1), [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2), [source](https://codecs.wiki/docs/encoders/SVT-AV1), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md)

### Maximum efficiency archive

**Goal:** Smallest file when encode time does not matter · **Content:** any

```bash
--preset 2 --crf 28 --input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0 --tf-strength 1 --qp-scale-compress-strength 1 --keyint 10s
```

Preset 2 sits near preset 1 efficiency at half the time; QP-scale compression 1 adds consistency almost free.

Sources: [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md)

### Film with normal grain (synthesis)

**Goal:** Keep the grain look without paying for it in bits · **Content:** live action, normal grain

```bash
--preset 4 --crf 30 --input-depth 10 --film-grain 8 --film-grain-denoise 0 --enable-variance-boost 1 --tf-strength 1
```

Level 8 is the project's live-action default; leaving denoise off keeps real detail when the level is verified.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://codecs.wiki/docs/encoders/SVT-AV1)

### Heavy grain, maximum savings

**Goal:** Strongly reduce bitrate on very grainy or high-ISO sources · **Content:** heavy grain, low light

```bash
--preset 4 --crf 30 --input-depth 10 --film-grain 12 --film-grain-denoise 1 --adaptive-film-grain 1
```

Noisier sources take levels 10-15; denoising the coded picture gives the big savings at some risk to fine detail.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md)

### Heavy grain, keep the real grain

**Goal:** Preserve authentic grain instead of synthesizing it (bigger files) · **Content:** heavy grain

```bash
--preset 4 --crf 26 --input-depth 10 --ac-bias 4.0 --enable-tf 0 --enable-cdef 0 --enable-variance-boost 1
```

The SVT-AV1 psychovisual appendix names this combination for dramatically better grain and noise retention.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md)

### Hand-drawn anime

**Goal:** Clean lines and flat color at low bitrate · **Content:** anime

```bash
--preset 4 --crf 32 --input-depth 10 --film-grain 4 --enable-variance-boost 1 --variance-boost-strength 1 --enable-qm 1 --qm-min 0 --sharpness 1
```

Low grain level and mild variance boost suit smooth animation; QMs helped the anime test set; +1 sharpness is in the safe range. Higher CRF than live action is fine per the FAQ.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md), [source](https://codecs.wiki/blog/svt-av1-deep-dive), [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)

### Old film-era anime

**Goal:** Keep the cel grain character · **Content:** old anime

```bash
--preset 4 --crf 30 --input-depth 10 --film-grain 10 --film-grain-denoise 0 --enable-variance-boost 1 --variance-boost-strength 2 --enable-tf 0
```

Grainy animation can use levels up to about 10; turning TF off keeps more of the source grain; the animation deep dive found TF-off results clip dependent, so compare against `--tf-strength` 1.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://codecs.wiki/blog/svt-av1-deep-dive)

### Clean CGI / 3D animation

**Goal:** Detail retention without needless grain processing · **Content:** CGI

```bash
--preset 4 --crf 30 --input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0
```

Grainless 3D animation should skip film grain (faster, no detail loss); default variance boost strength suits detailed textures.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md)

### Screen recording

**Goal:** Sharp text and UI · **Content:** screen content

```bash
--preset 6 --crf 30 --scm 1 --enable-intrabc 1 --keyint 10s
```

Mode 1 forces palette and block-copy tools that make text and UI cheap to code.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md)

### HDR10 master

**Goal:** Correctly signaled PQ HDR · **Content:** HDR

```bash
--preset 4 --crf 27 --input-depth 10 --color-primaries 9 --transfer-characteristics 16 --matrix-coefficients 9 --color-range 0 --chroma-sample-position topleft --mastering-display 'G(0.2650,0.6900)B(0.1500,0.0600)R(0.6800,0.3200)WP(0.3127,0.3290)L(1000,0.0001)' --content-light 1000,400 --enable-variance-boost 1
```

Full color description plus ST 2086 and CLL metadata in the documented syntax; luminance-qp-bias left off because it is not suited to PQ.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md), [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)

### HLG broadcast-style HDR

**Goal:** Backward-compatible HDR · **Content:** HDR

```bash
--preset 4 --crf 27 --input-depth 10 --color-primaries 9 --transfer-characteristics 18 --matrix-coefficients 9 --color-range 0 --enable-variance-boost 1 --luminance-qp-bias 20
```

HLG needs only the color description; Codec Wiki allows luminance bias on HLG (test 10-50).

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md), [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)

### Streaming rendition with a bitrate cap

**Goal:** Quality-targeted encode that never exceeds the delivery ceiling · **Content:** streaming/small size

```bash
--preset 5 --crf 32 --mbr 6000 --keyint 2s --tile-columns 1 --fast-decode 1
```

Capped CRF bounds peaks; short GOPs help seeking; tiles and fast-decode help weaker decoders.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md), [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)

### Exact size (two-pass VBR)

**Goal:** Hit a file-size budget · **Content:** any

```bash
--preset 5 --passes 2 --rc 1 --tbr 4000 --stats pass.log
```

Multi-pass matters most for VBR targeting.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md)

### Fast preview

**Goal:** Quick check encodes · **Content:** speed

```bash
--preset 8 --crf 35
```

Preset 8 is the fastest preset Codec Wiki still considers usable; 9+ shows inconsistent quality.

Sources: [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1)

### Still image (AVIF payload)

**Goal:** Best still-image quality · **Content:** still image

```bash
--avif 1 --tune 3 --preset 4 --crf 25 --input-depth 10
```

IQ tune is designed for still images and sets QMs, sharpness, variance boost curve 2 and transform limits itself.

Sources: [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_handle.c)

## Fork and version notes

### summary

Only the installed mainline v4.3.0 options are documented above. Options that look familiar from guides may belong to forks or other versions.

### newInMainline

- v4.3.0: timed --fgs-table entries; experimental --fast-decode 3 (special build only, not in this help)
- v4.2.0: --tune 5 (VMAF), --cqp, --enable-intrabc, --hbd-mds, --enable-kf-tf, --obu, --max-intra-bitrate-pct/--max-inter-bitrate-pct
- v4.0.0: --tune 3 (IQ), --max-tx-size, --adaptive-film-grain, --ac-bias, --scm 3, extended CRF to 70 in 0.25 steps, --sframe-qp/--sframe-qp-offset, --sframe-mode 4 (all ported from SVT-AV1-PSY where noted)
- v3.1.0: --chroma-qm-min/--chroma-qm-max, --rtc, random-access S-frames, variance boost refinements
- v2.3.0/v3.0.0: --lp redefined as level of parallelism; preset renumbering

### forkOnlyNotInInstalledBuild

- svt-av1-hdr: --tune 6 (film grain), --variance-boost-curve 3 (PQ), --noise/--noise-chroma/--noise-size, --enable-qmpsnr, --cdef-scaling, --noise-adaptive-filtering, --alt-ssim-tuning, --noise-norm-strength, --tx-bias, --kf-tf-strength, --sharp-tx, presets -2/-3, --dolby-vision-rpu, --hdr10plus-json, 4:4:4 input
- SVT-AV1-PSY (archived 2025): its tune 3 was 'subjective SSIM', not mainline IQ; most of its features were merged into mainline 3.x/4.x
- Successor: the PSY README points to svt-av1-hdr, while the Codec Wiki PSY page names svt-av1-psyex; the two sources disagree

### helpVsDocsDisagreements

- --tbr default: help 7000, Parameters.md 2000
- --min-qp: help 1 [1-63], Parameters.md 0 [0-63]
- --buf-sz/--buf-initial-sz/--buf-optimal-sz: help 6000/4000/5000, docs and v4.3.0 library 1000/600/600
- qindex offsets: help -256-255, Parameters.md -64-63
- --tile-rows/--tile-columns default: help 1 (per resolution), Parameters.md 0
- --hierarchical-levels and --pred-struct: docs list extra values (0-1, all-intra) not in the help
- --qp-scale-compress-strength: API comment says default 1, help and library say 0
- --variance-octile default: help 5, Codec Wiki v3.0 article 6
- --svtav1-params: help says keys follow config-file option names; Parameters.md and the parser use CLI names without '--'
- --recode-loop: help lists only 0 and 4; Parameters.md documents levels 0-4 with default 4

## Lumora findings

- Tuning results (docs/encoding/tuning-svtav1.md, SVT-AV1 v4.3.0 on an M3 Max): every finding below was measured with BD-rates on VMAF, VMAF NEG and XPSNR plus CAMBI, scoring grain synthesis against a de-grained master as Lumora does.
- --lp is now a level derived from each instance's share of the cores (EncodeRecipes.svtParallelism), no longer the core count that the encoder clamped to 6.
- --luminance-qp-bias is dropped for HDR10 (PQ) exports and --qm-min is raised to at least 8 there (EncodeRecipes.svtArgs).
- Grain synthesis uses one level per content type on both paths (heavy grain 12, old anime 8, low light 4) with --film-grain-denoise 1, and is offered on presets 6 and slower only, priced per rung from measured CPU time.
- With grain synthesis the temporal filter stays on (--tf-strength 1): 15-46% smaller than --enable-tf 0 against the noise-free original.
- Per content type: --qm-min 6 for live action and old anime, 8 for anime, CG and low light; --ac-bias 1.0 for live action, CG, heavy grain and low light; --tune 0 for anime; --variance-boost-curve 1 for low light; --variance-boost-strength 1 for fast motion.
- The --lookahead 120 extra produced bit-identical output and was removed; preset 10 was dropped from the ladder in favor of preset 9.
- GrainTable.write output (filmgrn1, one entry, lag 0, seed 7391) matches the v4.3.0 parser rules.

## All options

142 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--input`](#input) | file path, or 'stdin' / '-' for a pipe; y4m or raw yuv | not stated | Source video. | ✓ | ✓ |
| [`--allow-mmap-file`](#allow-mmap-file) | switch | not stated | Lets the app memory-map a regular input file instead of reading it with normal file I/O. |  |  |
| [`--output`](#output) | file path, or 'stdout' / '-'; .ivf or .obu chooses the format | IVF | Where the compressed bitstream is written. |  | ✓ |
| [`--ivf`](#ivf) | switch | IVF is the default | Forces IVF container output regardless of file extension. |  |  |
| [`--obu`](#obu) | switch | not stated | Writes the raw sequence of OBUs (low-overhead bitstream format) with no IVF wrapper. |  |  |
| [`--config`](#config) | path to a .cfg file | not stated | Reads encoder settings from a configuration file using the config-file key names (for example EncoderMode, CRF). |  |  |
| [`--svtav1-params`](#svtav1-params) | colon-separated key=value list using option names without '--' | not stated | Sets any option through one string, the same syntax FFmpeg's -svtav1-params uses. |  |  |
| [`--width`](#width) | 4-16384 | 0 | Frame width for raw YUV input; taken from the header for Y4M. |  |  |
| [`--height`](#height) | 4-8704 | 0 | Frame height for raw YUV input; taken from the header for Y4M. |  |  |
| [`--forced-max-frame-width`](#forced-max-frame-width) | 4-16384 | 0 | Declares a larger maximum frame width in the sequence header than the first frame has, so later frames can change resolution. |  |  |
| [`--forced-max-frame-height`](#forced-max-frame-height) | 4-8704 | 0 | Height counterpart of `--forced-max-frame-width`. |  |  |
| [`--frames`](#frames) | 0: until EOF, 1-(2^63)-1 | 0 | Number of frames to encode. |  |  |
| [`--skip`](#skip) | 0: don't skip, 1-(2^63)-1 | 0 | Skips this many input frames before encoding starts. |  |  |
| [`--nb`](#nb) | -1: no buffering, 1-(2^31)-1 | -1 | Loads n frames into memory up front and encodes only those, removing input I/O from speed measurements. |  |  |
| [`--color-format`](#color-format) | 0: yuv400, 1: yuv420, 2: yuv422, 3: yuv444 (only yuv420 supported) | 1 | Chroma subsampling of the input and output. | ✓ |  |
| [`--fps-num`](#fps-num) | 0-2^32-1 | 60000 | Frame-rate numerator for raw input; Y4M supplies it. |  |  |
| [`--fps-denom`](#fps-denom) | 0-2^32-1 | 1000 | Frame-rate denominator; use 1001 for NTSC-style rates such as 24000/1001. |  |  |
| [`--inj`](#inj) | 0-1 | 0 | Feeds pictures to the library at a fixed rate to simulate a live source. |  |  |
| [`--inj-frm-rt`](#inj-frm-rt) | 0-240 | 60 | Picture rate used by the injector when `--inj` 1 is set. |  |  |

### Rate control

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--rc`](#rc) | 0: CRF or CQP (if --aq-mode 0), 1: VBR, 2: CBR | 0 | Selects the rate-control family: quality-targeted, average-bitrate, or constant-bitrate. |  |  |
| [`--qp`](#qp) | 1-63 | 35 | Base quantizer. |  |  |
| [`--crf`](#crf) | 1-70, in 0.25 steps | 35 | Constant rate factor: the main quality dial. |  | ✓ |
| [`--cqp`](#cqp) | 1-70, in 0.25 steps | 35 | Constant quantizer with adaptive QP off, using the same extended scale as `--crf`. |  |  |
| [`--tbr`](#tbr) | 1-100000 (kbps) | 7000 | Target bitrate for VBR and CBR. |  |  |
| [`--mbr`](#mbr) | 1-100000 (kbps) | 0 | Maximum bitrate for capped CRF: keeps CRF quality targeting but limits peaks. |  |  |
| [`--use-q-file`](#use-q-file) | 0-1 | 0 | Replaces the encoder's own per-picture QP choice with values read from `--qpfile`. |  |  |
| [`--qpfile`](#qpfile) | text file, one QP per line | not stated | File of per-picture QP values used when `--use-q-file` 1 is set. |  |  |
| [`--max-qp`](#max-qp) | 1-63 | 63 | Highest quantizer (worst quality) VBR/CBR may use. |  |  |
| [`--min-qp`](#min-qp) | 1-63 | 1 | Lowest quantizer (best quality) VBR/CBR may use, preventing waste on easy scenes. |  |  |
| [`--aq-mode`](#aq-mode) | 0: off, 1: variance based using AV1 segments, 2: deltaq pred efficiency | 2 | Adaptive quantization inside a frame. |  |  |
| [`--use-fixed-qindex-offsets`](#use-fixed-qindex-offsets) | 0-2 | 0 | Uses user-supplied qindex offsets per frame type and temporal layer instead of the encoder's built-in hierarchy. |  |  |
| [`--key-frame-qindex-offset`](#key-frame-qindex-offset) | -256-255 | 0 | Qindex offset applied to key frames when fixed offsets are used; negative means better keyframes. |  |  |
| [`--key-frame-chroma-qindex-offset`](#key-frame-chroma-qindex-offset) | -256-255 | 0 | Chroma qindex offset for key frames, added on top of the luma value. |  |  |
| [`--qindex-offsets`](#qindex-offsets) | comma list, one per hierarchical layer, each -256-255 | 0,0,..,0 | Luma qindex offsets per temporal layer for fixed-offset mode; needs hierarchical-levels + 1 entries. |  |  |
| [`--chroma-qindex-offsets`](#chroma-qindex-offsets) | comma list per layer, each -256-255 | 0,0,..,0 | Chroma qindex offsets per temporal layer, applied on top of the layer's luma qindex. |  |  |
| [`--luma-y-dc-qindex-offset`](#luma-y-dc-qindex-offset) | not stated (Parameters.md: -64-63) | not stated | Offset for the luma DC quantizer relative to the AC quantizer; negative values protect flat-area brightness accuracy. | ✓ |  |
| [`--chroma-u-dc-qindex-offset`](#chroma-u-dc-qindex-offset) | not stated (Parameters.md: -64-63) | not stated | DC quantizer offset for the Cb plane. | ✓ |  |
| [`--chroma-u-ac-qindex-offset`](#chroma-u-ac-qindex-offset) | not stated (Parameters.md: -64-63) | not stated | AC quantizer offset for the Cb plane. | ✓ |  |
| [`--chroma-v-dc-qindex-offset`](#chroma-v-dc-qindex-offset) | not stated (Parameters.md: -64-63) | not stated | DC quantizer offset for the Cr plane. | ✓ |  |
| [`--chroma-v-ac-qindex-offset`](#chroma-v-ac-qindex-offset) | not stated (Parameters.md: -64-63) | not stated | AC quantizer offset for the Cr plane. | ✓ |  |
| [`--lambda-scale-factors`](#lambda-scale-factors) | comma list of integers per SvtAv1FrameUpdateType (value/128 = scale) | 128,128,..,128 | Scales the rate-distortion lambda for each frame-update type; above 128 favors fewer bits, below favors quality. |  |  |
| [`--undershoot-pct`](#undershoot-pct) | 0-100 | 25 (varies by rate control) | How far below the target bitrate VBR/CBR may fall before correcting. |  |  |
| [`--overshoot-pct`](#overshoot-pct) | 0-100 | 25 (varies by rate control) | How far above the target bitrate VBR/CBR may go before correcting. |  |  |
| [`--mbr-overshoot-pct`](#mbr-overshoot-pct) | 0-100 | 50 | Allowed overshoot above `--mbr` in capped CRF. |  |  |
| [`--max-intra-bitrate-pct`](#max-intra-bitrate-pct) | percentage, 0 disables | 300 | Caps the size of intra frames as a percentage of the per-frame target. |  |  |
| [`--max-inter-bitrate-pct`](#max-inter-bitrate-pct) | percentage, 0 disables | 0 | Caps the size of inter frames as a percentage of the per-frame target. |  |  |
| [`--gop-constraint-rc`](#gop-constraint-rc) | 0-1 | 0 | Makes VBR hit the target within each GOP instead of only over the whole file. |  |  |
| [`--buf-sz`](#buf-sz) | 0-10000 (ms) | 6000 | Client buffer size for CBR (hypothetical decoder buffer). |  |  |
| [`--buf-initial-sz`](#buf-initial-sz) | 0-10000 (ms) | 4000 | Initial buffer fullness for CBR at start-up. |  |  |
| [`--buf-optimal-sz`](#buf-optimal-sz) | 0-10000 (ms) | 5000 | Buffer level CBR tries to maintain. |  |  |
| [`--recode-loop`](#recode-loop) | 0: off, 1: keyframes and max-bandwidth, 2: key/alt-ref/golden, 3: all frames, 4: preset based | not stated | Lets the encoder re-encode frames that miss their bit budget, trading time for rate accuracy. |  |  |
| [`--minsection-pct`](#minsection-pct) | 0-100 | 0 | Minimum share of the target rate any GOP gets in VBR. |  |  |
| [`--maxsection-pct`](#maxsection-pct) | 0-10000 | 2000 | Maximum share of the target rate any GOP may take in VBR. |  |  |
| [`--roi-map-file`](#roi-map-file) | text file: frame number then QP offsets per 64x64 block, row by row | off | Region-of-interest map that shifts QP per 64x64 block per picture, for steering bits to faces, text or VR viewports. |  |  |
| [`--pass`](#pass) | 0: single pass, 1: first pass, 2: second pass | 0 | Runs one pass of a manual multi-pass encode, writing (pass 1) or reading (pass 2) the stats file. |  |  |
| [`--stats`](#stats) | file path | svtav1_2pass.log | File holding first-pass statistics for multi-pass encoding. |  |  |
| [`--passes`](#passes) | 1: one pass, 2: multi-pass | preset dependent, generally 1 | Runs the whole multi-pass sequence in one command. |  |  |
| [`--startup-qp-offset`](#startup-qp-offset) | -63 to 63 | 0 | QP offset added for the first GOP before picture QPs are derived, e.g. |  |  |

### Speed and presets

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--preset`](#preset) | -1-13 (negative = debugging) | 8 | Main speed/efficiency dial. |  | ✓ |
| [`--rtc`](#rtc) | 0-1 | 0 | Real-time communication mode: forces low-delay prediction and fast RTC-tuned settings. |  |  |
| [`--fast-decode`](#fast-decode) | 0-2 | 0 | Restricts tools so the bitstream decodes faster in software; 2 is more aggressive than 1. |  |  |
| [`--hbd-mds`](#hbd-mds) | -1: preset-determined, 0: 8-bit, 1: 10-bit, 2: hybrid 8/10-bit | -1 | Bit depth of the mode-decision path for 10-bit encodes. | ✓ |  |

### GOP and keyframes

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--keyint`](#keyint) | -2: ~5 s, -1: infinite (CRF only), 0: same as -1, or frames; 's' suffix for seconds | -2 | Maximum distance between key frames. |  |  |
| [`--irefresh-type`](#irefresh-type) | 1: FWD frame (open GOP), 2: KEY frame (closed GOP) | 2 | Whether periodic intra refreshes are full key frames (closed GOP) or forward key frames (open GOP). |  |  |
| [`--scd`](#scd) | 0-1 | 0 | Scene change detection switch. |  |  |
| [`--lookahead`](#lookahead) | -1: auto, 0-120 | -1 | Extra future frames analyzed beyond what the mini-GOP, temporal filter and rate control already need. |  | ✓ |
| [`--hierarchical-levels`](#hierarchical-levels) | 2: 3 temporal layers, 3: 4 layers, 4: 5 layers, 5: 6 layers | <=M12: 5, else: 4 | Depth of the hierarchical mini-GOP. |  |  |
| [`--pred-struct`](#pred-struct) | 1: low delay, 2: random access | 2 | Random access uses future references (best for files); low delay only references past frames for real-time use. |  |  |
| [`--force-key-frames`](#force-key-frames) | comma list of '#f' frame numbers or '#.#s' seconds | not stated | Places key frames at given frames or timestamps, for chapter points or manual scene cuts. |  |  |
| [`--startup-mg-size`](#startup-mg-size) | 0: off, 2: 3 temporal layers, 3: 4 layers, 4: 5 layers | 0 | Uses a shorter mini-GOP right after each key frame, so playback can start and seek faster. |  |  |
| [`--enable-dg`](#enable-dg) | 0-1 | 1 | Dynamic GOP: changes the hierarchical structure based on content (for example shorter mini-GOPs in high motion). |  |  |
| [`--enable-overlays`](#enable-overlays) | 0-1 | 0 | Inserts overlay pictures that give the base layer an extra, unfiltered reference. |  |  |
| [`--sframe-dist`](#sframe-dist) | 0: off, >0: interval in frames | 0 | Inserts switch frames (S-frames) at this interval so players can switch between streams at those points. |  |  |
| [`--sframe-mode`](#sframe-mode) | 1: only if alt-ref, 2: next alt-ref (default), 3: adjust mini-GOP for a given position, 4: position in decode order | 2 | How S-frame positions are chosen. |  |  |
| [`--sframe-posi`](#sframe-posi) | comma list of 0-based frame numbers | not stated | Exact frames to make into S-frames for modes 3/4. |  |  |
| [`--sframe-qp`](#sframe-qp) | comma list of QPs (1-63) | not stated | QP for inserted S-frames; one value applies to all. |  |  |
| [`--sframe-qp-offset`](#sframe-qp-offset) | comma list of offsets (-63-63) | not stated | QP offset for inserted S-frames; one value applies to all. |  |  |

### Psychovisual and tuning

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--luminance-qp-bias`](#luminance-qp-bias) | 0-100 | 0 | Lowers the QP of darker frames in proportion to how dark they are, to fight dark-scene artifacts. | ✓ | ✓ |
| [`--sharpness`](#sharpness) | -7 to 7 | 0 | Biases the deblocking filter and rate-distortion decisions toward a softer (negative) or crisper (positive) result. |  | ✓ |
| [`--tune`](#tune) | 0 = VQ, 1 = PSNR, 2 = SSIM, 3 = IQ (Image Quality), 4 = MS_SSIM (MS-SSIM and SSIMULACRA2 optimized), 5 = VMAF | 1 | Chooses what the encoder optimizes for: subjective sharpness (VQ), PSNR, SSIM, still-image quality, MS-SSIM/SSIMULACRA2, or VMAF. |  | ✓ |
| [`--scm`](#scm) | 0: off, 1: on, 2: content adaptive, 3: content adaptive (anti-alias aware) | 2 | Screen-content mode: enables palette and intra block copy tools for text, UI and graphics, either always (1) or when detection says so (2, 3). |  | ✓ |
| [`--enable-variance-boost`](#enable-variance-boost) | 0-1 | 0 | Variance-based adaptive quantization: gives low-contrast superblocks (skies, skin, fog, night scenes) a lower qindex so they keep detail instead of collapsing into blocks. | ✓ | ✓ |
| [`--variance-boost-strength`](#variance-boost-strength) | 1-4 | 2 | How hard low-contrast superblocks are boosted (1 mild, 2 gentle, 3 medium, 4 aggressive). |  | ✓ |
| [`--variance-octile`](#variance-octile) | 1-8 | 5 | How much of a superblock must be low-contrast before it is boosted: 1 boosts if 1/8 is flat, 8 only if all of it is. |  |  |
| [`--variance-boost-curve`](#variance-boost-curve) | 0-2 (0 default, 1 low-medium contrast, 2 still picture) | 0 | Selects the variance boost formula: 0 standard, 1 extends boosting to low-medium contrast areas at a modest bitrate cost, 2 tuned for still images (SSIMULACRA2 on CID22). |  | ✓ |
| [`--qp-scale-compress-strength`](#qp-scale-compress-strength) | 0-3 | 0 | Narrows the QP gap between temporal layers in a mini-GOP, so quality fluctuates less frame to frame at some cost in average efficiency. |  |  |
| [`--ac-bias`](#ac-bias) | 0.0-8.0 | 0.0 | Psychovisual energy-preservation term: penalizes reconstructions that lose high-frequency 'energy' compared with the source, like x264/x265 psy-rd. |  | ✓ |

### Film grain and noise

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--tf-strength`](#tf-strength) | 0-4 | 3 | Strength of the motion-compensated temporal filter used to build alt-ref frames. |  | ✓ |
| [`--enable-tf`](#enable-tf) | 0-2 (0 off, 1 on, 2 adaptive) | 1 | Builds temporally filtered alt-ref frames. |  | ✓ |
| [`--enable-kf-tf`](#enable-kf-tf) | 0-1 | 1 | Applies the temporal filter to key frames as well. |  |  |
| [`--film-grain`](#film-grain) | 0: off, 1-50: denoising level | 0 | Enables film-grain synthesis: the encoder estimates a grain model and signals it so the decoder adds matching synthetic grain. |  | ✓ |
| [`--film-grain-denoise`](#film-grain-denoise) | 0: no denoising (grain params still sent), 1: denoise at the --film-grain level | 0 | Chooses whether the encoder also removes the grain from the picture it codes. |  | ✓ |
| [`--fgs-table`](#fgs-table) | path to a 'filmgrn1' text grain table | not stated | Supplies a pre-computed AV1 film-grain table instead of the encoder's own estimate. |  | ✓ |
| [`--adaptive-film-grain`](#adaptive-film-grain) | 0-1 | 1 | Chooses the block size the grain model is estimated from based on resolution, which reduces visible repeating grain patterns. |  |  |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--color-help`](#color-help) | none (switch) | not stated | Prints the color-metadata appendix: the numeric and named values for primaries, transfer, matrix, range and chroma position, and the syntax of `--mastering-display` and `--content-light`. | ✓ |  |
| [`--input-depth`](#input-depth) | 8, 10 | 8 | Bit depth of the input file and of the output bitstream. | ✓ | ✓ |
| [`--color-primaries`](#color-primaries) | 0-12, 22 (1 bt709, 2 unspecified, 9 bt2020, 12 smpte432 ...; names accepted) | 2 | Signals the color primaries of the content in the sequence header. | ✓ | ✓ |
| [`--transfer-characteristics`](#transfer-characteristics) | 0-22 (1 bt709, 13 srgb, 16 smpte2084/PQ, 18 hlg ...; names accepted) | 2 | Signals the transfer function (gamma, PQ or HLG). | ✓ | ✓ |
| [`--matrix-coefficients`](#matrix-coefficients) | 0-14 (1 bt709, 9 bt2020-ncl, 14 ictcp ...; names accepted) | 2 | Signals the RGB-to-YUV matrix used to make the input. | ✓ | ✓ |
| [`--color-range`](#color-range) | 0: studio, 1: full | 0 | Signals limited (16-235 style) or full range samples. | ✓ | ✓ |
| [`--chroma-sample-position`](#chroma-sample-position) | 'unknown', 'vertical'/'left', 'colocated'/'topleft' | unknown | Signals where 4:2:0 chroma samples sit relative to luma, so the decoder upsamples chroma correctly. | ✓ |  |
| [`--mastering-display`](#mastering-display) | 'G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)'; x,y CIE 1931 0.0-1.0; L in nits (floats) | not stated | Writes SMPTE ST 2086 mastering-display metadata (display primaries, white point, peak and minimum luminance) into the AV1 stream for HDR10. | ✓ | ✓ |
| [`--content-light`](#content-light) | 'max_cll,max_fall' integers 0-65535 | not stated | Writes CTA-861.3 content light level metadata: brightest pixel (MaxCLL) and brightest frame average (MaxFALL) in nits. | ✓ | ✓ |

### Analysis and motion search

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-mfmv`](#enable-mfmv) | -1: auto, 0-1 | -1 | Motion-field motion vectors: projects motion from reference frames to predict current vectors. |  |  |
| [`--enable-intrabc`](#enable-intrabc) | 0: off, 1: on | 1 | Allows intra block copy (copying an already-coded area of the same frame), mainly useful for screen content. |  |  |

### Partitioning and transforms

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-qm`](#enable-qm) | 0-1 | 0 | Turns on quantization matrices so high-frequency coefficients are quantized more coarsely than low ones, instead of a flat matrix. |  | ✓ |
| [`--qm-min`](#qm-min) | 0-15 | 8 | Steepest (least flat) luma quantization matrix allowed; lower values mean stronger frequency shaping. |  | ✓ |
| [`--qm-max`](#qm-max) | 0-15 | 15 | Flattest luma matrix allowed (15 = flat). |  |  |
| [`--chroma-qm-min`](#chroma-qm-min) | 0-15 | 8 | Steepest chroma quantization matrix allowed. |  |  |
| [`--chroma-qm-max`](#chroma-qm-max) | 0-15 | 15 | Flattest chroma quantization matrix allowed. |  |  |
| [`--max-tx-size`](#max-tx-size) | 32, 64 | 64 | Largest transform allowed. |  |  |

### In-loop filters

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-dlf`](#enable-dlf) | 0-2 (0 off, 1 on, 2 slower more accurate) | 1 | Deblocking loop filter. |  |  |
| [`--enable-cdef`](#enable-cdef) | 0-1 | 1 | Constrained Directional Enhancement Filter: removes ringing around edges, but can smear fine grain. |  |  |
| [`--enable-restoration`](#enable-restoration) | 0-1 | 1 | Loop restoration (Wiener and self-guided filters), which smooths reconstruction toward the source. |  |  |

### Threading and performance

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--asm`](#asm) | c, neon, crc32, neon_dotprod, neon_i8mm, sve, sve2, max | max | Caps which SIMD instruction sets the encoder may use. |  |  |
| [`--lp`](#lp) | 0, 6 (levels 0-6; 0 = auto from core count) | 0 | Level of parallelism, not a thread count. |  | ✓ |
| [`--tile-rows`](#tile-rows) | 0-6 (log2 of the count) | 1 (changes per resolution) | Splits frames into tile rows for parallel decoding. |  |  |
| [`--tile-columns`](#tile-columns) | 0-4 (log2 of the count) | 1 (changes per resolution) | Splits frames into tile columns so multi-threaded decoders can work in parallel. |  |  |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--errlog`](#errlog) | file path | stderr | Redirects error messages to a file instead of standard error. |  |  |
| [`--recon`](#recon) | file path | not stated | Writes the decoder-side reconstructed frames as raw YUV, useful for metric checks without a separate decode. |  |  |
| [`--stat-file`](#stat-file) | file path | not stated | Writes per-picture PSNR and SSIM to a file. |  |  |
| [`--progress`](#progress) | 0: none, 1: default, 2: detailed | 1 | Controls how much progress output the app prints while encoding. |  |  |
| [`--no-progress`](#no-progress) | 1: same as --progress 0, 0: same as --progress 1 | 0 | Shortcut to silence progress printing. |  |  |
| [`--enable-stat-report`](#enable-stat-report) | 0-1 | 0 | Computes PSNR and SSIM against the source and prints a summary at the end (and per frame with `--stat-file`). |  |  |

### Other

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--help`](#help) | none (switch) | not stated | Prints the full list of command-line options for the installed build and exits. |  |  |
| [`--version`](#version) | none (switch) | not stated | Prints the version of the linked SVT-AV1 library. |  |  |
| [`--profile`](#profile) | 0: main, 1: high, 2: professional | 0 | AV1 bitstream profile to signal. |  |  |
| [`--tier`](#tier) | 0: main, 1: high | 0 | AV1 tier, which sets the allowed maximum bitrate for a given level. |  |  |
| [`--level`](#level) | 0: autodetect, 2.0-7.3 | 0 | AV1 level to signal (spec annex A.3). |  |  |
| [`--superres-mode`](#superres-mode) | 0: off, 1-3, 4: auto-select | 0 | Super-resolution: codes frames at reduced width and lets the decoder upscale them (1 fixed, 2 random, 3 by qindex threshold, 4 tries both and picks). |  |  |
| [`--superres-denom`](#superres-denom) | 8: no scaling, 9-15, 16: half | 8 | Horizontal downscale factor (8/denom) for superres mode 1. |  |  |
| [`--superres-kf-denom`](#superres-kf-denom) | 8: no scaling, 9-15, 16: half | 8 | Superres downscale factor for key frames in mode 1. |  |  |
| [`--superres-qthres`](#superres-qthres) | 0-63 | 43 | Qindex threshold above which mode 3 starts downscaling frames (63 means never). |  |  |
| [`--superres-kf-qthres`](#superres-kf-qthres) | 0-63 | 43 | Key-frame threshold for superres mode 3. |  |  |
| [`--resize-mode`](#resize-mode) | 0: none, 1: fixed scale, 2: random scale, 3: dynamic scale, 4: random access | not stated | Reference scaling: codes frames at a lower resolution in both directions (fixed, random, buffer-driven for CBR low delay, or event-driven). |  |  |
| [`--resize-denom`](#resize-denom) | 8-16 | not stated | Scale factor (8/denom) for resize mode 1. |  |  |
| [`--resize-kf-denom`](#resize-kf-denom) | 8-16 | not stated | Key-frame scale factor for resize mode 1. |  |  |
| [`--frame-resz-events`](#frame-resz-events) | comma list of frame numbers | not stated | Frames where resize mode 4 switches to new scale factors. |  |  |
| [`--frame-resz-kf-denoms`](#frame-resz-kf-denoms) | comma list of 8-16 | not stated | Key-frame scale factors for each resize event. |  |  |
| [`--frame-resz-denoms`](#frame-resz-denoms) | comma list of 8-16 | not stated | Inter-frame scale factors for each resize event. |  |  |
| [`--lossless`](#lossless) | 0-1 | 0 | Requests lossless coding. |  |  |
| [`--avif`](#avif) | 0-1 | 0 | Still-picture mode with optimizations and lower memory for single images (AVIF). |  |  |

## Options in detail

### Input and output

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** file path, or 'stdin' / '-' for a pipe; y4m or raw yuv · **Default:** not stated · **HDR-relevant**

Source video. Y4M carries width, height, frame rate and bit depth in its header; raw YUV needs them on the command line.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `10-bit y4m on stdin` | Y4M passes dimensions, rate and depth automatically, avoiding the 60 fps / 8-bit defaults that apply to raw YUV. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** Always '`-i` stdin': Lumora pipes Y4M frames into the encoder (encoders.json svtav1.args, input 'stdin').

**Notes:** SVT-AV1 does no color or scaling conversion; whatever is piped in is what is encoded.

<a id="allow-mmap-file"></a>

#### `--allow-mmap-file`

**Type:** bool · **Values:** switch · **Default:** not stated · advanced

Lets the app memory-map a regular input file instead of reading it with normal file I/O. Speed impact depends on the platform.

**Effect:** quality none · speed ± platform dependent · size none

**Notes:** Has no effect on pipes such as stdin.

<a id="output"></a>

#### `--output` (also `-b`)

**Type:** path · **Values:** file path, or 'stdout' / '-'; .ivf or .obu chooses the format · **Default:** IVF

Where the compressed bitstream is written. The extension picks IVF or raw OBU; IVF is used otherwise.

**In Lumora:** '`-b` {out}' with extension 'ivf'; Lumora muxes the IVF afterwards.

<a id="ivf"></a>

#### `--ivf`

**Type:** bool · **Values:** switch · **Default:** IVF is the default · advanced

Forces IVF container output regardless of file extension.

**Notes:** Raw OBU output (`--obu`) and this explicit switch were added in v4.2.0.

<a id="obu"></a>

#### `--obu`

**Type:** bool · **Values:** switch · **Default:** not stated · advanced

Writes the raw sequence of OBUs (low-overhead bitstream format) with no IVF wrapper.

**Effect:** quality none · speed none · size slightly smaller (no IVF frame headers)

**Notes:** New in v4.2.0; older builds only write IVF. Check that your muxer accepts raw OBU input.

<a id="config"></a>

#### `--config` (also `-c`)

**Type:** path · **Values:** path to a .cfg file · **Default:** not stated · advanced

Reads encoder settings from a configuration file using the config-file key names (for example EncoderMode, CRF).

**Effect:** quality depends on contents · speed depends on contents · size depends on contents

**Notes:** Key names differ from CLI names; see the Configuration file parameter column of Parameters.md.

<a id="svtav1-params"></a>

#### `--svtav1-params`

**Type:** string · **Values:** colon-separated key=value list using option names without '--' · **Default:** not stated · advanced

Sets any option through one string, the same syntax FFmpeg's -svtav1-params uses. Handy for passing a whole profile through tools.

**Effect:** quality depends on contents · speed depends on contents · size depends on contents

**Notes:** Duplicate keys are not detected, only invalid keys or values. In FFmpeg it is parsed after the wrapper's own fields, so it wins over -crf, -preset and color options. The help says keys follow config-file names, but Parameters.md and the v4.3.0 parser use the CLI names without '--' (for example preset=4:crf=30).

<a id="width"></a>

#### `--width` (also `-w`)

**Type:** int · **Values:** 4-16384 · **Default:** 0

Frame width for raw YUV input; taken from the header for Y4M.

<a id="height"></a>

#### `--height` (also `-h`)

**Type:** int · **Values:** 4-8704 · **Default:** 0

Frame height for raw YUV input; taken from the header for Y4M.

**Notes:** Note `-h` is height, not help.

<a id="forced-max-frame-width"></a>

#### `--forced-max-frame-width`

**Type:** int · **Values:** 4-16384 · **Default:** 0 · advanced

Declares a larger maximum frame width in the sequence header than the first frame has, so later frames can change resolution.

**Notes:** For on-the-fly resolution changes through the API.

<a id="forced-max-frame-height"></a>

#### `--forced-max-frame-height`

**Type:** int · **Values:** 4-8704 · **Default:** 0 · advanced

Height counterpart of `--forced-max-frame-width`.

<a id="frames"></a>

#### `--frames` (also `-n`)

**Type:** int · **Values:** 0: until EOF, 1-(2^63)-1 · **Default:** 0

Number of frames to encode. If larger than the input, the app loops back to the start.

**Notes:** The looping behavior is a trap for scripts that over-estimate frame counts.

<a id="skip"></a>

#### `--skip`

**Type:** int · **Values:** 0: don't skip, 1-(2^63)-1 · **Default:** 0

Skips this many input frames before encoding starts.

<a id="nb"></a>

#### `--nb`

**Type:** int · **Values:** -1: no buffering, 1-(2^31)-1 · **Default:** -1 · advanced

Loads n frames into memory up front and encodes only those, removing input I/O from speed measurements.

**Effect:** quality none · speed + for benchmarks · size none

**Notes:** Benchmarking aid; only the buffered frames are encoded.

<a id="color-format"></a>

#### `--color-format`

**Type:** enum · **Values:** 0: yuv400, 1: yuv420, 2: yuv422, 3: yuv444 (only yuv420 supported) · **Default:** 1 · **HDR-relevant** · advanced

Chroma subsampling of the input and output. The help states only 4:2:0 currently works.

**Notes:** 4:4:4 / High profile support exists only in the svt-av1-hdr fork; mainline users needing 4:2:2/4:4:4 or 12-bit should use libaom (Lumora's av1Pro path does).

<a id="fps-num"></a>

#### `--fps-num`

**Type:** int · **Values:** 0-2^32-1 · **Default:** 60000

Frame-rate numerator for raw input; Y4M supplies it. Affects rate control, keyint in seconds and grain-table timing.

**Effect:** quality ± via rate control · speed none · size ± in VBR/CBR

**Notes:** The separate `--fps` option was removed in v4.0; rates below 1 fps are rejected.

<a id="fps-denom"></a>

#### `--fps-denom`

**Type:** int · **Values:** 0-2^32-1 · **Default:** 1000

Frame-rate denominator; use 1001 for NTSC-style rates such as 24000/1001.

**Effect:** quality ± via rate control · speed none · size ± in VBR/CBR

<a id="inj"></a>

#### `--inj`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Feeds pictures to the library at a fixed rate to simulate a live source.

**Effect:** quality none · speed caps throughput · size none

**Notes:** Testing aid for real-time pipelines.

<a id="inj-frm-rt"></a>

#### `--inj-frm-rt`

**Type:** int · **Values:** 0-240 · **Default:** 60 · advanced

Picture rate used by the injector when `--inj` 1 is set.

**Effect:** quality none · speed caps throughput · size none

### Rate control

<a id="rc"></a>

#### `--rc`

**Type:** enum · **Values:** 0: CRF or CQP (if --aq-mode 0), 1: VBR, 2: CBR · **Default:** 0

Selects the rate-control family: quality-targeted, average-bitrate, or constant-bitrate.

**Effect:** quality CRF best per bit · speed VBR two-pass slower · size VBR/CBR predictable

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (with --crf)` | CRF gives the best quality per file size when no bitrate target is needed. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**Notes:** Lumora relies on the default (0) and passes `--crf`.

<a id="qp"></a>

#### `--qp` (also `-q`)

**Type:** int · **Values:** 1-63 · **Default:** 35 · advanced

Base quantizer. In CQP it is the fixed level; in CRF it is the starting point the rate control works from.

**Effect:** quality - as it rises · speed slightly + as it rises · size smaller as it rises

**Notes:** `--crf` and `--cqp` are the friendlier forms with quarter steps and a range up to 70.

<a id="crf"></a>

#### `--crf`

**Type:** float · **Values:** 1-70, in 0.25 steps · **Default:** 35

Constant rate factor: the main quality dial. Lower values mean higher quality and larger files; it implies adaptive QP (aq-mode 2).

**Effect:** quality - as it rises · speed slightly + as it rises · size smaller as it rises

| For | Value | Why | Source |
|---|---|---|---|
| anime | `relatively high CRF (with low film-grain)` | The project notes 2D animation looks good at higher CRF than live action because it is easy to compress. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| live action | `raise CRF a little when enabling variance boost` | Variance boost adds bits to flat areas; Codec Wiki suggests compensating with a higher CRF. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**In Lumora:** '`--crf` {quality}'; Lumora's target-quality search moves within qualityBest 16 to qualityWorst 40.

**Notes:** Values above 63 and quarter steps come from the extended CRF added in v4.0 (from SVT-AV1-PSY); v4.3.0 fixed a bitrate inversion at fractional values above 63. No authoritative source gives a universal CRF table; pick by metric targeting.

<a id="cqp"></a>

#### `--cqp`

**Type:** float · **Values:** 1-70, in 0.25 steps · **Default:** 35 · advanced

Constant quantizer with adaptive QP off, using the same extended scale as `--crf`.

**Effect:** quality less consistent than CRF · speed ≈ · size usually larger than CRF at equal quality

**Notes:** New in v4.2.0.

<a id="tbr"></a>

#### `--tbr`

**Type:** int · **Values:** 1-100000 (kbps) · **Default:** 7000

Target bitrate for VBR and CBR.

**Effect:** quality + as it rises · speed ≈ · size proportional

**Notes:** Parameters.md lists 2000 as the default and b/k/m suffixes; the installed help says 7000. Ignored in CRF mode.

<a id="mbr"></a>

#### `--mbr`

**Type:** int · **Values:** 1-100000 (kbps) · **Default:** 0

Maximum bitrate for capped CRF: keeps CRF quality targeting but limits peaks.

**Effect:** quality - in complex scenes when the cap bites · speed ≈ · size caps peaks

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `set to the delivery ceiling` | Capped CRF is the documented way to combine CRF with a hard maximum. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

<a id="use-q-file"></a>

#### `--use-q-file`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Replaces the encoder's own per-picture QP choice with values read from `--qpfile`.

**Effect:** quality depends on file · speed ≈ · size depends on file

**Notes:** The help text refers to '`--qp-file`' but the real option is `--qpfile`.

<a id="qpfile"></a>

#### `--qpfile`

**Type:** path · **Values:** text file, one QP per line · **Default:** not stated · advanced

File of per-picture QP values used when `--use-q-file` 1 is set.

**Effect:** quality depends on file · speed ≈ · size depends on file

<a id="max-qp"></a>

#### `--max-qp`

**Type:** int · **Values:** 1-63 · **Default:** 63 · advanced

Highest quantizer (worst quality) VBR/CBR may use.

**Effect:** quality + floor when lowered · speed ≈ · size may overshoot when lowered

**Notes:** Range checks were fixed in v3.1.1.

<a id="min-qp"></a>

#### `--min-qp`

**Type:** int · **Values:** 1-63 · **Default:** 1 · advanced

Lowest quantizer (best quality) VBR/CBR may use, preventing waste on easy scenes.

**Effect:** quality caps peak quality when raised · speed ≈ · size saves bits on easy scenes

**Notes:** Parameters.md lists 0-63 with default 0; the library uses an automatic value. The installed help says 1.

<a id="aq-mode"></a>

#### `--aq-mode`

**Type:** enum · **Values:** 0: off, 1: variance based using AV1 segments, 2: deltaq pred efficiency · **Default:** 2 · advanced

Adaptive quantization inside a frame. Mode 2 adjusts quality per superblock by how useful a block is as a reference; mode 1 uses segment-based variance AQ.

**Effect:** quality + with 2 · speed 2 fastest · size 2 most efficient

| For | Value | Why | Source |
|---|---|---|---|
| live action | `2` | Codec Wiki found mode 2 the most efficient and fastest; mode 0 hurt SSIMULACRA2 on nearly every clip. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |

**Notes:** Variance boost is turned off automatically with `--aq-mode` 1.

<a id="use-fixed-qindex-offsets"></a>

#### `--use-fixed-qindex-offsets`

**Type:** enum · **Values:** 0-2 · **Default:** 0 · advanced

Uses user-supplied qindex offsets per frame type and temporal layer instead of the encoder's built-in hierarchy.

**Effect:** quality depends on offsets · speed ≈ · size depends on offsets

**Notes:** Works with `--rc` 0; set `--hierarchical-levels` before the offset lists.

<a id="key-frame-qindex-offset"></a>

#### `--key-frame-qindex-offset`

**Type:** int · **Values:** -256-255 · **Default:** 0 · advanced

Qindex offset applied to key frames when fixed offsets are used; negative means better keyframes.

**Effect:** quality + on keyframes if negative · speed ≈ · size + if negative

**Notes:** Parameters.md shows the range as -64-63.

<a id="key-frame-chroma-qindex-offset"></a>

#### `--key-frame-chroma-qindex-offset`

**Type:** int · **Values:** -256-255 · **Default:** 0 · advanced

Chroma qindex offset for key frames, added on top of the luma value.

**Effect:** quality chroma ± · speed ≈ · size ±

**Notes:** Parameters.md shows the range as -64-63.

<a id="qindex-offsets"></a>

#### `--qindex-offsets`

**Type:** list · **Values:** comma list, one per hierarchical layer, each -256-255 · **Default:** 0,0,..,0 · advanced

Luma qindex offsets per temporal layer for fixed-offset mode; needs hierarchical-levels + 1 entries.

**Effect:** quality redistributes quality across layers · speed ≈ · size ±

**Notes:** May be enclosed in []. Parameters.md range: -64-63.

<a id="chroma-qindex-offsets"></a>

#### `--chroma-qindex-offsets`

**Type:** list · **Values:** comma list per layer, each -256-255 · **Default:** 0,0,..,0 · advanced

Chroma qindex offsets per temporal layer, applied on top of the layer's luma qindex.

**Effect:** quality chroma ± · speed ≈ · size ±

<a id="luma-y-dc-qindex-offset"></a>

#### `--luma-y-dc-qindex-offset`

**Type:** int · **Values:** not stated (Parameters.md: -64-63) · **Default:** not stated · **HDR-relevant** · advanced

Offset for the luma DC quantizer relative to the AC quantizer; negative values protect flat-area brightness accuracy.

**Effect:** quality ± flat areas · speed none · size ±

**Notes:** Docs default 0.

<a id="chroma-u-dc-qindex-offset"></a>

#### `--chroma-u-dc-qindex-offset`

**Type:** int · **Values:** not stated (Parameters.md: -64-63) · **Default:** not stated · **HDR-relevant** · advanced

DC quantizer offset for the Cb plane.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Docs default 0.

<a id="chroma-u-ac-qindex-offset"></a>

#### `--chroma-u-ac-qindex-offset`

**Type:** int · **Values:** not stated (Parameters.md: -64-63) · **Default:** not stated · **HDR-relevant** · advanced

AC quantizer offset for the Cb plane.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Docs default 0.

<a id="chroma-v-dc-qindex-offset"></a>

#### `--chroma-v-dc-qindex-offset`

**Type:** int · **Values:** not stated (Parameters.md: -64-63) · **Default:** not stated · **HDR-relevant** · advanced

DC quantizer offset for the Cr plane.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Docs default 0.

<a id="chroma-v-ac-qindex-offset"></a>

#### `--chroma-v-ac-qindex-offset`

**Type:** int · **Values:** not stated (Parameters.md: -64-63) · **Default:** not stated · **HDR-relevant** · advanced

AC quantizer offset for the Cr plane.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Docs default 0.

<a id="lambda-scale-factors"></a>

#### `--lambda-scale-factors`

**Type:** list · **Values:** comma list of integers per SvtAv1FrameUpdateType (value/128 = scale) · **Default:** 128,128,..,128 · advanced

Scales the rate-distortion lambda for each frame-update type; above 128 favors fewer bits, below favors quality.

**Effect:** quality ± · speed none · size ±

**Notes:** Expert tuning only.

<a id="undershoot-pct"></a>

#### `--undershoot-pct`

**Type:** int · **Values:** 0-100 · **Default:** 25 (varies by rate control) · advanced

How far below the target bitrate VBR/CBR may fall before correcting.

**Effect:** quality ± · speed none · size rate accuracy

**Notes:** Parameters.md says 25 for CBR and 50 for VBR.

<a id="overshoot-pct"></a>

#### `--overshoot-pct`

**Type:** int · **Values:** 0-100 · **Default:** 25 (varies by rate control) · advanced

How far above the target bitrate VBR/CBR may go before correcting.

**Effect:** quality ± · speed none · size rate accuracy

**Notes:** The FAQ mentions a `--bias-pct` option for VBR flexibility; it is not in this build's help.

<a id="mbr-overshoot-pct"></a>

#### `--mbr-overshoot-pct`

**Type:** int · **Values:** 0-100 · **Default:** 50 · advanced

Allowed overshoot above `--mbr` in capped CRF.

**Effect:** quality + when higher · speed none · size peaks

<a id="max-intra-bitrate-pct"></a>

#### `--max-intra-bitrate-pct`

**Type:** int · **Values:** percentage, 0 disables · **Default:** 300 · advanced

Caps the size of intra frames as a percentage of the per-frame target.

**Effect:** quality - on keyframes if tight · speed none · size smoother rate

**Notes:** Exposed on the CLI in v4.2.0, mainly for RTC/CBR.

<a id="max-inter-bitrate-pct"></a>

#### `--max-inter-bitrate-pct`

**Type:** int · **Values:** percentage, 0 disables · **Default:** 0 · advanced

Caps the size of inter frames as a percentage of the per-frame target.

**Effect:** quality - in bursts if tight · speed none · size smoother rate

**Notes:** New on the CLI in v4.2.0.

<a id="gop-constraint-rc"></a>

#### `--gop-constraint-rc`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Makes VBR hit the target within each GOP instead of only over the whole file.

**Effect:** quality less adaptive · speed none · size steadier per GOP

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `1 with VBR and GOP > 119 frames` | The FAQ says it is supported in VBR when the GOP is longer than 119 frames. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

<a id="buf-sz"></a>

#### `--buf-sz`

**Type:** int · **Values:** 0-10000 (ms) · **Default:** 6000 · advanced

Client buffer size for CBR (hypothetical decoder buffer).

**Effect:** quality + when larger · speed none · size rate smoothness

**Notes:** Parameters.md and the v4.3.0 library defaults say 1000 ms (range 20-10000); the installed help says 6000.

<a id="buf-initial-sz"></a>

#### `--buf-initial-sz`

**Type:** int · **Values:** 0-10000 (ms) · **Default:** 4000 · advanced

Initial buffer fullness for CBR at start-up.

**Effect:** quality ± at start · speed none · size none

**Notes:** Docs/library default 600 ms; help says 4000.

<a id="buf-optimal-sz"></a>

#### `--buf-optimal-sz`

**Type:** int · **Values:** 0-10000 (ms) · **Default:** 5000 · advanced

Buffer level CBR tries to maintain.

**Effect:** quality ± · speed none · size none

**Notes:** Docs/library default 600 ms; help says 5000.

<a id="recode-loop"></a>

#### `--recode-loop`

**Type:** enum · **Values:** 0: off, 1: keyframes and max-bandwidth, 2: key/alt-ref/golden, 3: all frames, 4: preset based · **Default:** not stated · advanced

Lets the encoder re-encode frames that miss their bit budget, trading time for rate accuracy.

**Effect:** quality ± · speed - when higher · size better rate accuracy

**Notes:** Parameters.md gives default 4 and the level table; the help lists only 0 and 4.

<a id="minsection-pct"></a>

#### `--minsection-pct`

**Type:** int · **Values:** 0-100 · **Default:** 0 · advanced

Minimum share of the target rate any GOP gets in VBR.

**Effect:** quality + on easy GOPs · speed none · size ±

<a id="maxsection-pct"></a>

#### `--maxsection-pct`

**Type:** int · **Values:** 0-10000 · **Default:** 2000 · advanced

Maximum share of the target rate any GOP may take in VBR.

**Effect:** quality - on hard GOPs if lowered · speed none · size ±

<a id="roi-map-file"></a>

#### `--roi-map-file`

**Type:** path · **Values:** text file: frame number then QP offsets per 64x64 block, row by row · **Default:** off · advanced

Region-of-interest map that shifts QP per 64x64 block per picture, for steering bits to faces, text or VR viewports.

**Effect:** quality + where offsets are negative · speed ≈ · size ±

**Notes:** Overrides variance AQ segments when `--aq-mode` 1 is also on.

<a id="pass"></a>

#### `--pass`

**Type:** enum · **Values:** 0: single pass, 1: first pass, 2: second pass · **Default:** 0 · advanced

Runs one pass of a manual multi-pass encode, writing (pass 1) or reading (pass 2) the stats file.

**Effect:** quality + rate allocation in VBR · speed - (two runs) · size accurate targeting

**Notes:** Pass 2 is only for VBR; both passes need `--stats`.

<a id="stats"></a>

#### `--stats`

**Type:** path · **Values:** file path · **Default:** svtav1_2pass.log · advanced

File holding first-pass statistics for multi-pass encoding.

**Notes:** Use a unique name per parallel encode to avoid collisions.

<a id="passes"></a>

#### `--passes`

**Type:** enum · **Values:** 1: one pass, 2: multi-pass · **Default:** preset dependent, generally 1

Runs the whole multi-pass sequence in one command.

**Effect:** quality + in VBR; small in CRF · speed - (first pass) · size better targeting

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `2 with --rc 1` | Multi-pass mostly matters for hitting a VBR target; in CRF it only helps corner cases such as high motion. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**Notes:** CBR is always one pass. The first pass runs at a fast internal preset.

<a id="startup-qp-offset"></a>

#### `--startup-qp-offset`

**Type:** int · **Values:** -63 to 63 · **Default:** 0 · advanced

QP offset added for the first GOP before picture QPs are derived, e.g. to make the opening look better.

**Effect:** quality + at start if negative · speed none · size + if negative

**Notes:** CRF/CQP only; added in v3.0.

### Speed and presets

<a id="preset"></a>

#### `--preset`

**Type:** int · **Values:** -1-13 (negative = debugging) · **Default:** 8

Main speed/efficiency dial. Lower presets enable more coding tools and search harder, giving smaller files at the same quality but much longer encodes.

**Effect:** quality + at lower presets · speed - at lower presets (roughly exponential) · size smaller at lower presets

| For | Value | Why | Source |
|---|---|---|---|
| archive | `2` | Efficiency close to preset 1 at about half its time; Codec Wiki names presets 2 and 4 the best efficiency-for-time choices. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1) |
| live action | `4` | Nearly as efficient as preset 3 and the usual balance point for enthusiasts; presets 4-6 are the project's suggested home range. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| anime | `4` | Codec Wiki's animation deep dive used and recommended preset 4 as the balance; going to preset 0 cost 5-10x time for about 1.5 SSIMULACRA2 points. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |
| speed | `6 or 8` | Suggested when preset 4 is too slow; 8 is the last preset Codec Wiki considers fully usable in v3.0. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1) |
| streaming/small size | `3-6 (0 for very high view counts)` | Streaming Learning Center found 3-6 the useful VOD range on v1.4 and only very popular titles justify preset 0. | [source](https://streaminglearningcenter.com/encoding/choosing-a-preset-for-svt-av1-and-libaom-av1.html) |

**In Lumora:** '`--preset` {preset}', default '4'. EncodeRecipes AV1 ladder offers presets 9, 8, 6, 5, 4, 3, 2, 1, 0 (preset 10 dropped: SVT-AV1 warns that non-RTC presets 10+ may show artifacts, and 9 was 23% smaller for 32% more CPU time), then continues into libaom cpu-used 4-0. Speeds are CPU time per frame measured on an M3 Max, relative to preset 10 (the scale the libaom rungs share); film-grain synthesis is offered on presets 6 and slower only. MacOptimizer benchmarks a fast preset to choose the instance count (docs/encoding/tuning-svtav1.md).

**Notes:** v4.3.0 source: random-access presets above 11 map to 11; 4K+ random access caps at 9 (so Lumora's preset 10 rung equals preset 9 at 4K); still-image (`--avif`) caps at 9; `--rtc` only allows 7-13. Presets were renumbered in v2.3.0 and v3.0.0, so older preset numbers do not translate one-to-one. Film grain above preset 6 prints a compute-overhead warning. Above 4K resolution, presets 4 and below are rejected for video (all-intra excepted).

<a id="rtc"></a>

#### `--rtc`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Real-time communication mode: forces low-delay prediction and fast RTC-tuned settings.

**Effect:** quality - vs VOD · speed + latency · size larger

**Notes:** Added in v3.1.0; only presets 7-13 are allowed (lower values become 7).

<a id="fast-decode"></a>

#### `--fast-decode`

**Type:** enum · **Values:** 0-2 · **Default:** 0

Restricts tools so the bitstream decodes faster in software; 2 is more aggressive than 1.

**Effect:** quality - (about 1% BD-rate for level 1, 1-3% for level 2 per changelog) · speed decode +; level 2 also encodes faster · size slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| speed | `1 or 2 for weak playback devices` | The FAQ lists it first among decode-speed tips; Codec Wiki's v3.0 tests measured average decode gains between about -0.6% and +14.7% depending on preset, level and quality, and saw more macroblocking on some sources. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**Notes:** Docs mention an experimental level 3 for still images that requires a special build flag; the installed help lists 0-2. Developed with tune 1, with a warning when combined with tune 0.

<a id="hbd-mds"></a>

#### `--hbd-mds`

**Type:** enum · **Values:** -1: preset-determined, 0: 8-bit, 1: 10-bit, 2: hybrid 8/10-bit · **Default:** -1 · **HDR-relevant** · advanced

Bit depth of the mode-decision path for 10-bit encodes. Full 10-bit decisions are more accurate for gradients but slower.

**Effect:** quality + with 1 on 10-bit sources · speed - with 1 · size ≈

**Notes:** New in v4.2.0. Values 1 and 2 are rejected with 8-bit encoding. No published benchmark found; whether 1 reduces banding in HDR gradients is unverified.

### GOP and keyframes

<a id="keyint"></a>

#### `--keyint`

**Type:** int · **Values:** -2: ~5 s, -1: infinite (CRF only), 0: same as -1, or frames; 's' suffix for seconds · **Default:** -2

Maximum distance between key frames. Longer GOPs save bits; shorter ones help seeking and error recovery.

**Effect:** quality + per bit when longer · speed none · size smaller when longer

| For | Value | Why | Source |
|---|---|---|---|
| archive | `5s-10s` | The FAQ notes home users prefer 5-10 second GOPs; Codec Wiki suggests about 10x the frame rate. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| streaming/small size | `about 1s (e.g. 24 at 24 fps)` | VOD commonly uses ~1 second GOPs for seeking and packet-loss recovery. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**Notes:** SVT-AV1 never inserts keyframes at scene cuts; chunk-based tools (or Lumora's segments) supply them. The 's' suffix works in SvtAv1EncApp but not in FFmpeg's `-g`. svt-av1-hdr's -2 means ~10 s.

<a id="irefresh-type"></a>

#### `--irefresh-type`

**Type:** enum · **Values:** 1: FWD frame (open GOP), 2: KEY frame (closed GOP) · **Default:** 2 · advanced

Whether periodic intra refreshes are full key frames (closed GOP) or forward key frames (open GOP).

**Effect:** quality open GOP sometimes + at high CRF · speed open GOP slower · size ±

| For | Value | Why | Source |
|---|---|---|---|
| live action | `2` | Codec Wiki advises closed GOP because open-GOP support is incomplete. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |
| heavy grain | `1 (unconfirmed)` | The animation deep dive saw open GOP tie or win at high CRF and guessed it might help very grainy content, but flagged this as unconfirmed. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |

**Notes:** Forward key frames force `--hierarchical-levels` 4 (v4.3.0) and are rejected with CBR.

<a id="scd"></a>

#### `--scd`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Scene change detection switch. In v4.3.0 the library forces it back to 0 with a warning; scene changes are handled inside mode decision without new keyframes.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `leave at 0; split by scenes externally` | The project states SVT-AV1 does not insert keyframes at scene changes regardless of this option and suggests chunked encoding instead. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**Notes:** Effectively a no-op in the installed version.

<a id="lookahead"></a>

#### `--lookahead`

**Type:** int · **Values:** -1: auto, 0-120 · **Default:** -1 · advanced

Extra future frames analyzed beyond what the mini-GOP, temporal filter and rate control already need.

**Effect:** quality small + when larger · speed small - · size slightly smaller

**In Lumora:** Not set. Lumora used to offer '`--lookahead` 120'; at preset 4 in CRF mode it produced bit-identical output on a 20 s clip, so the option was removed (docs/encoding/tuning-svtav1.md).

**Notes:** v4.3.0 fixed nondeterministic output with `--lookahead` 0.

<a id="hierarchical-levels"></a>

#### `--hierarchical-levels`

**Type:** enum · **Values:** 2: 3 temporal layers, 3: 4 layers, 4: 5 layers, 5: 6 layers · **Default:** <=M12: 5, else: 4 · advanced

Depth of the hierarchical mini-GOP. More layers mean longer mini-GOPs (up to 32 frames) and better compression of static content; fewer layers react faster to motion.

**Effect:** quality ± by content · speed ≈ · size deeper usually smaller

**Notes:** Parameters.md lists 0-5 including flat/2-layer modes; the installed help lists 2-5. Codec Wiki's v2.2 test used 4 to get smaller mini-GOPs but did not recommend a value.

<a id="pred-struct"></a>

#### `--pred-struct`

**Type:** enum · **Values:** 1: low delay, 2: random access · **Default:** 2 · advanced

Random access uses future references (best for files); low delay only references past frames for real-time use.

**Effect:** quality random access much better · speed low delay lower latency · size random access smaller

**Notes:** Low delay forces tune 0 to 1 and disallows superres and overlays. Docs also list 0 (all intra).

<a id="force-key-frames"></a>

#### `--force-key-frames`

**Type:** string · **Values:** comma list of '#f' frame numbers or '#.#s' seconds · **Default:** not stated · advanced

Places key frames at given frames or timestamps, for chapter points or manual scene cuts.

**Effect:** quality + at cuts · speed none · size + per extra keyframe

**Notes:** Supported for CRF from the command line.

<a id="startup-mg-size"></a>

#### `--startup-mg-size`

**Type:** enum · **Values:** 0: off, 2: 3 temporal layers, 3: 4 layers, 4: 5 layers · **Default:** 0 · advanced

Uses a shorter mini-GOP right after each key frame, so playback can start and seek faster.

**Effect:** quality slight - · speed none · size slight +

**Notes:** CRF/CQP only; must not exceed `--hierarchical-levels`.

<a id="enable-dg"></a>

#### `--enable-dg`

**Type:** bool · **Values:** 0-1 · **Default:** 1 · advanced

Dynamic GOP: changes the hierarchical structure based on content (for example shorter mini-GOPs in high motion).

**Effect:** quality + · speed ≈ · size smaller

<a id="enable-overlays"></a>

#### `--enable-overlays`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Inserts overlay pictures that give the base layer an extra, unfiltered reference.

**Effect:** quality no gain in tests · speed slight - · size none

| For | Value | Why | Source |
|---|---|---|---|
| anime | `0` | Codec Wiki saw neither efficiency nor speed benefit. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |

**Notes:** Not allowed in low delay. v4.3.0 fixed nondeterministic output with overlays. v4.3.0 also rejects overlays with multi-pass encoding.

<a id="sframe-dist"></a>

#### `--sframe-dist`

**Type:** int · **Values:** 0: off, >0: interval in frames · **Default:** 0 · advanced

Inserts switch frames (S-frames) at this interval so players can switch between streams at those points.

**Effect:** quality slight - · speed none · size slight +

**Notes:** Random-access S-frames since v3.1.0; rejected with all-intra in v4.3.0.

<a id="sframe-mode"></a>

#### `--sframe-mode`

**Type:** enum · **Values:** 1: only if alt-ref, 2: next alt-ref (default), 3: adjust mini-GOP for a given position, 4: position in decode order · **Default:** 2 · advanced

How S-frame positions are chosen.

**Notes:** Help prints range [1-3] but describes mode 4 (added v4.0).

<a id="sframe-posi"></a>

#### `--sframe-posi`

**Type:** list · **Values:** comma list of 0-based frame numbers · **Default:** not stated · advanced

Exact frames to make into S-frames for modes 3/4.

<a id="sframe-qp"></a>

#### `--sframe-qp`

**Type:** list · **Values:** comma list of QPs (1-63) · **Default:** not stated · advanced

QP for inserted S-frames; one value applies to all.

**Effect:** quality ± · speed none · size ±

**Notes:** New in v4.0.

<a id="sframe-qp-offset"></a>

#### `--sframe-qp-offset`

**Type:** list · **Values:** comma list of offsets (-63-63) · **Default:** not stated · advanced

QP offset for inserted S-frames; one value applies to all.

**Effect:** quality ± · speed none · size ±

**Notes:** New in v4.0.

### Psychovisual and tuning

<a id="luminance-qp-bias"></a>

#### `--luminance-qp-bias`

**Type:** int · **Values:** 0-100 · **Default:** 0 · **HDR-relevant** · advanced

Lowers the QP of darker frames in proportion to how dark they are, to fight dark-scene artifacts.

**Effect:** quality + in dark SDR scenes · speed none · size larger on dark content

| For | Value | Why | Source |
|---|---|---|---|
| low light | `10-50 (test), SDR or HLG only` | Codec Wiki's BD-rate figures improved most on anime and got worse on live action and gaming clips; the author suggests testing values such as 10, 30 and 50, considers values below 50 safe, and says it is not suited to PQ. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| HDR | `0 for PQ (HDR10)` | Frame-average luma does not map to perceived darkness the same way on PQ; the study restricts the feature to SDR and HLG. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**In Lumora:** Optional 'Brighter handling of dark scenes': '`--luminance-qp-bias` 25', recommended for real life, heavy grain, low light and old anime. Dropped for HDR10 (PQ) exports by EncodeRecipes.svtArgs on every path (Codec Wiki: SDR and HLG only; on Lumora's PQ clips dropping it saved 1.6-1.9% XPSNR BD-rate). Kept for SDR and HLG: removing it there saved XPSNR but cost VMAF (docs/encoding/tuning-svtav1.md).

**Notes:** Documented since v3.0.2. The svt-av1-hdr fork has its own PQ-aware variants.

<a id="sharpness"></a>

#### `--sharpness`

**Type:** int · **Values:** -7 to 7 · **Default:** 0 · advanced

Biases the deblocking filter and rate-distortion decisions toward a softer (negative) or crisper (positive) result.

**Effect:** quality ± (+1/+2 usually neutral-to-good) · speed slightly - when positive · size ±

| For | Value | Why | Source |
|---|---|---|---|
| live action | `0 or 1-2` | Codec Wiki saw consistent small gains or neutral results at +1/+2 and frequent losses at +4 and above. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| anime | `1-2` | The animated test clip (Sol Levante) benefited from positive sharpness while gaming clips did not. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**In Lumora:** Optional 'Sharper fine detail' / 'Crisper line art': '`--sharpness` 1' (2 for anime), marked visual-only.

**Notes:** Tunes 3 and 4 force sharpness 7. The svt-av1-hdr fork defaults to 1.

<a id="tune"></a>

#### `--tune`

**Type:** enum · **Values:** 0 = VQ, 1 = PSNR, 2 = SSIM, 3 = IQ (Image Quality), 4 = MS_SSIM (MS-SSIM and SSIMULACRA2 optimized), 5 = VMAF · **Default:** 1

Chooses what the encoder optimizes for: subjective sharpness (VQ), PSNR, SSIM, still-image quality, MS-SSIM/SSIMULACRA2, or VMAF. IQ and MS-SSIM also override sharpness, variance boost and QM settings.

**Effect:** quality depends on metric/eye · speed ≈ between 0-2 · size ≈

| For | Value | Why | Source |
|---|---|---|---|
| live action | `1` | Codec Wiki's v3.0 parameter study found tune 1 best overall across SSIMULACRA2, XPSNR, Butteraugli and VMAF, with tune 2 sometimes trading wins. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| live action | `0` | The Codec Wiki encoder page calls tune 0 the safe psychovisual choice and discourages PSNR tuning; the project FAQ says tune 0 often looks sharper. This disagrees with the metric study above. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |
| anime | `2 at low quality, 1 at high quality` | The animation deep dive found tunes 1 and 2 matched at high quality and tune 2 ahead at low quality; tune 0 kept detail but could ring. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |
| archive | `3 for still images only` | Parameters.md marks IQ as still-image only. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |
| streaming/small size | `5 when VMAF is the delivery metric` | Added in v4.2.0 targeting about 15% VMAF BD-rate gain at a small PSNR cost. The encoder warns that it applies unsharp-mask pre-processing, so higher VMAF may not mean higher fidelity. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/CHANGELOG.md) |

**In Lumora:** '`--tune` 0' for anime, both in the planner ('Tune for visual quality', measured -1.1% VMAF and -2.0% XPSNR BD-rate) and in the encoders.json anime tune; every other kind keeps the default (1). Tunes 2 and 4 were larger on Lumora's clips (docs/encoding/tuning-svtav1.md).

**Notes:** Tune numbers differ between projects: SVT-AV1-PSY's tune 3 was 'subjective SSIM', mainline's tune 3 is IQ; svt-av1-hdr adds tune 6 (film grain). Low delay forces tune 0 to 1. Tune 5 (VMAF) arrived in v4.2.0; tune 4 (MS-SSIM) is also post-v4.0, but the changelog does not name its release. v4.3.0 validation: tunes 2-5 accept only CRF (`--rc` 0); tune 3 (IQ) is rejected with random access, so it is for `--avif`/all-intra (low delay is experimental); tunes 2 and 4 reject low delay; tune 5 needs random access.

<a id="scm"></a>

#### `--scm`

**Type:** enum · **Values:** 0: off, 1: on, 2: content adaptive, 3: content adaptive (anti-alias aware) · **Default:** 2

Screen-content mode: enables palette and intra block copy tools for text, UI and graphics, either always (1) or when detection says so (2, 3).

**Effect:** quality + on screen content · speed - when forced on · size much smaller on screen content

| For | Value | Why | Source |
|---|---|---|---|
| screen content | `1 (or keep 2/3 for mixed sources)` | Mode 1 forces block copy and palette tools on; modes 2 and 3 detect it per content. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--scm` 1' for the screen-content kind (encoders.json screen tune and EncodeRecipes 'Screen-content tools').

**Notes:** Mode 3 was added in v4.0 from SVT-AV1-PSY; v4.3.0 runs it on I-frames only in multi-threaded mode. Tune 3 forces mode 3.

<a id="enable-variance-boost"></a>

#### `--enable-variance-boost`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · **HDR-relevant**

Variance-based adaptive quantization: gives low-contrast superblocks (skies, skin, fog, night scenes) a lower qindex so they keep detail instead of collapsing into blocks.

**Effect:** quality + in flat/low-contrast areas · speed slight - (from larger output) · size + unless CRF is raised

| For | Value | Why | Source |
|---|---|---|---|
| live action | `1` | Codec Wiki found the default strength beats no boost on nearly every clip and metric except VMAF. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| low light | `1` | The appendix targets night, foggy and overexposed scenes specifically. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| HDR | `1 (mainline curves are SDR-tuned)` | Still helpful on flat areas, but only the svt-av1-hdr fork has a PQ-specific curve. | [source](https://github.com/juliobbv-p/svt-av1-hdr) |

**In Lumora:** Optional 'Protect flat and dark areas': '`--enable-variance-boost` 1', plus '`--variance-boost-curve` 1' for low light and '`--variance-boost-strength` 1' for fast motion; turning it off cost 2-17% XPSNR BD-rate on every clip (docs/encoding/tuning-svtav1.md).

**Notes:** Automatically disabled with CBR and with `--aq-mode` 1. Forced on by tunes 3 and 4. Default on in svt-av1-hdr.

<a id="variance-boost-strength"></a>

#### `--variance-boost-strength`

**Type:** int · **Values:** 1-4 · **Default:** 2 · advanced

How hard low-contrast superblocks are boosted (1 mild, 2 gentle, 3 medium, 4 aggressive).

**Effect:** quality + in flat areas as it rises · speed slight - · size larger as it rises

| For | Value | Why | Source |
|---|---|---|---|
| anime | `1` | Best for simple, untextured or smooth animation. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| live action | `2` | Broadly compatible; good for most live action and textured animation. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| CGI | `2` | Detailed-texture animation fits the default curve. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| low light | `3` | Suited to content mixing very high- and low-contrast scenes such as horror or thrillers. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| archive | `3 (below CRF 20, with octile 3)` | Codec Wiki suggests this pairing for more consistent gains at very high quality. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**In Lumora:** '`--variance-boost-strength` 1' with variance boost for fast motion only (ahead on VMAF, VMAF NEG and XPSNR on the action clip); the default (2) elsewhere, where 1 and 3 split VMAF and XPSNR (docs/encoding/tuning-svtav1.md).

**Notes:** 4 prints an 'aggressive' warning and can inflate bitrate and make grain preservation inconsistent.

<a id="variance-octile"></a>

#### `--variance-octile`

**Type:** int · **Values:** 1-8 · **Default:** 5 · advanced

How much of a superblock must be low-contrast before it is boosted: 1 boosts if 1/8 is flat, 8 only if all of it is.

**Effect:** quality lower = more consistent · speed lower = slightly slower · size lower = larger

| For | Value | Why | Source |
|---|---|---|---|
| live action | `4-7` | Recommended range in the appendix; lower is less efficient, higher leaves low-quality holes. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md) |
| archive | `avoid 8` | Codec Wiki found octile 8 barely helps and can hurt. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**Notes:** Codec Wiki's v3.0 article treats 6 as the default; the installed help says 5.

<a id="variance-boost-curve"></a>

#### `--variance-boost-curve`

**Type:** enum · **Values:** 0-2 (0 default, 1 low-medium contrast, 2 still picture) · **Default:** 0 · advanced

Selects the variance boost formula: 0 standard, 1 extends boosting to low-medium contrast areas at a modest bitrate cost, 2 tuned for still images (SSIMULACRA2 on CID22).

**Effect:** quality ± · speed none · size 1 slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| live action | `0` | Codec Wiki found curves 0-2 mostly indistinguishable, with curve 2 better on a few clips. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**In Lumora:** '`--variance-boost-curve` 1' with variance boost for low light only (ahead on VMAF, VMAF NEG and XPSNR there); default curve elsewhere (docs/encoding/tuning-svtav1.md).

**Notes:** Curve 3 (PQ-optimized) exists only in svt-av1-hdr. Tunes 3 and 4 force curve 2.

<a id="qp-scale-compress-strength"></a>

#### `--qp-scale-compress-strength`

**Type:** int · **Values:** 0-3 · **Default:** 0 · advanced

Narrows the QP gap between temporal layers in a mini-GOP, so quality fluctuates less frame to frame at some cost in average efficiency.

**Effect:** quality + consistency, - average · speed none · size ≈ to slight +

| For | Value | Why | Source |
|---|---|---|---|
| live action | `1` | The psychovisual appendix says level 1 improves consistency at almost all quality levels at nearly no cost. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |
| archive | `2-3 at very low CRF` | Higher levels help when maximum fidelity or very low CRF is the goal. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**Notes:** The API header comment says default 1, but the v4.3.0 library default and help say 0.

<a id="ac-bias"></a>

#### `--ac-bias`

**Type:** float · **Values:** 0.0-8.0 · **Default:** 0.0 · advanced

Psychovisual energy-preservation term: penalizes reconstructions that lose high-frequency 'energy' compared with the source, like x264/x265 psy-rd.

**Effect:** quality + texture/grain retention · speed slight - · size larger

| For | Value | Why | Source |
|---|---|---|---|
| fast motion | `1.0-1.5` | Moderate values keep sharpness in textures and complex motion. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |
| heavy grain | `4.0-6.0 with --enable-tf 0 --enable-cdef 0` | High values with TF and CDEF off can dramatically improve retention of real grain. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** Optional 'Keep texture energy': '`--ac-bias` 1.0' for live action, CG, heavy grain and low light (smaller at equal VMAF and XPSNR on those clips; about +7% CPU time) (docs/encoding/tuning-svtav1.md).

**Notes:** Added in v4.0 (from SVT-AV1-PSY). svt-av1-hdr's tune 6 bundles ac-bias 4.0 with fork-only options.

### Film grain and noise

<a id="tf-strength"></a>

#### `--tf-strength`

**Type:** int · **Values:** 0-4 · **Default:** 3 · advanced

Strength of the motion-compensated temporal filter used to build alt-ref frames. Each step down halves the filtering; strong filtering smooths noise and texture.

**Effect:** quality lower keeps texture/grain · speed none · size slightly larger when lower

| For | Value | Why | Source |
|---|---|---|---|
| live action | `1` | Codec Wiki found 1 or lower removes keyframe blocking/smoothing issues, gains flatten below 2, and 4 performs very poorly. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| heavy grain | `1 (or --enable-tf 0)` | Weaker temporal filtering preserves real grain; the PSY-derived forks default to 1. | [source](https://github.com/juliobbv-p/svt-av1-hdr) |

**In Lumora:** '`--tf-strength` 1' ('Gentle temporal filter') for every content type except anime, including heavy grain, old anime and low light: with grain synthesis the encoder sees a denoised picture, and strength 1 was 15-46% smaller than no temporal filter against the noise-free original (docs/encoding/tuning-svtav1.md).

**Notes:** In tune 0 the key-frame filter strength is offset too. The fork-only `--kf-tf-strength` does not exist in mainline. v4.0.1 fixed the default shown in the help.

<a id="enable-tf"></a>

#### `--enable-tf`

**Type:** enum · **Values:** 0-2 (0 off, 1 on, 2 adaptive) · **Default:** 1 · advanced

Builds temporally filtered alt-ref frames. They improve compression, but the filtering removes noise from those frames, which can soften grain and fine detail. Mode 2 adapts strength per 64x64 block (experimental).

**Effect:** quality off keeps grain/lines · speed off slightly faster · size off slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| anime | `0 (clip dependent)` | The animation deep dive found turning TF off can slightly improve efficiency at high quality and speeds things up, depending on the clip. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |
| heavy grain | `0 with high --ac-bias` | Recommended by the SVT-AV1 psychovisual appendix for grain retention. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--enable-tf` 0' for anime only: in the planner's 'No temporal smoothing' option and the encoders.json anime tune (docs/encoding/tuning-svtav1.md).

**Notes:** Codec Wiki's v3.0 study found TF-off competitive with low `--tf-strength` but sometimes slightly worse; Minecraft-like content did worse.

<a id="enable-kf-tf"></a>

#### `--enable-kf-tf`

**Type:** bool · **Values:** 0-1 · **Default:** 1 · advanced

Applies the temporal filter to key frames as well.

**Effect:** quality off keeps keyframe texture · speed slight + off · size slight + off

**Notes:** New in v4.2.0. Forks expose a separate `--kf-tf-strength` instead.

<a id="film-grain"></a>

#### `--film-grain`

**Type:** int · **Values:** 0: off, 1-50: denoising level · **Default:** 0

Enables film-grain synthesis: the encoder estimates a grain model and signals it so the decoder adds matching synthetic grain. The number sets how strongly grain is analyzed (and removed, with `--film-grain-denoise` 1).

**Effect:** quality keeps grain look; too high stacks noise or removes fine detail · speed slight - · size much smaller on grainy sources

| For | Value | Why | Source |
|---|---|---|---|
| live action | `8` | The project FAQ says about 8 suits live action with normal grain; Codec Wiki agrees. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| heavy grain | `10-15` | Noisier video benefits from higher levels per the FAQ. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| low light | `10-15` | High-ISO sensor noise behaves like heavy grain for this purpose (FAQ treats CCD noise the same way). | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| anime | `4` | Hand-drawn animation usually has little grain; about 4 works well. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| old anime | `up to about 10` | Grainy (film-era) animation can use higher levels up to around 10. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| CGI | `0` | If the 3D animation has no grain, leaving it off is faster and avoids losing fine detail. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**In Lumora:** Same level on both paths: EncodeRecipes.svtGrainLevel gives 12 for heavy grain, 8 for old anime, 4 for low light (8 for other kinds when forced on), used by the planner's 'grain' extra and by the encoders.json 'grain' tune through {svt_grain}. Offered on presets 6 and slower only, priced per rung from measured CPU time (+142% at preset 6 down to none at preset 1). Dropped when a measured `--fgs-table` is used (docs/encoding/tuning-svtav1.md).

**Notes:** Above preset 6 the encoder warns of significant compute overhead (Lumora's ladder includes presets 8 and 10). Lumora's level for old anime (4) is lower than the FAQ's 'up to ~10' for grainy animation. `--adaptive-film-grain` (default on) adapts the synthesis block size to resolution.

<a id="film-grain-denoise"></a>

#### `--film-grain-denoise`

**Type:** bool · **Values:** 0: no denoising (grain params still sent), 1: denoise at the --film-grain level · **Default:** 0

Chooses whether the encoder also removes the grain from the picture it codes. With 0 it codes the original and only adds a grain description; with 1 it codes a denoised picture and relies on synthesis.

**Effect:** quality 0 keeps real detail; 1 can erase fine detail · speed 1 slightly slower · size 1 much smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (with a verified level)` | The FAQ says disabling source denoising can give higher fidelity if the level is checked by eye or high-fidelity metrics, warning that too high a level then stacks noise. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| heavy grain | `0` | Codec Wiki recommends plain `--film-grain` without denoise in most cases because denoising always removes fine detail. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |
| streaming/small size | `1` | The FAQ says removing the grain and replacing it with synthetic grain is where the large efficiency gains come from. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**In Lumora:** Always 1, on the planner path and in the encoders.json grain tune: Lumora scores grain synthesis against a de-grained master, and denoise 0 cost 22-30% VMAF BD-rate on heavy grain while stacking synthetic grain on coded grain. Removed when `--fgs-table` is used; Lumora then denoises the frames itself (docs/encoding/tuning-svtav1.md).

**Notes:** Default changed to 0 (from SVT-AV1-PSY). Ignored with a warning when `--film-grain` is 0. With `--fgs-table` the app disables encoder denoising.

<a id="fgs-table"></a>

#### `--fgs-table`

**Type:** path · **Values:** path to a 'filmgrn1' text grain table · **Default:** not stated · advanced

Supplies a pre-computed AV1 film-grain table instead of the encoder's own estimate. Format: a 'filmgrn1' line, then per time range 'E start end apply_grain seed update', and if update is 1 a 'p' line (ar_coeff_lag ar_coeff_shift grain_scale_shift scaling_shift chroma_scaling_from_luma overlap_flag cb_mult cb_luma_mult cb_offset cr_mult cr_luma_mult cr_offset), 'sY n x y...', 'sCb n ...', 'sCr n ...', then 'cY' with 2*lag*(lag+1) AR coefficients and 'cCb'/'cCr' with one more each. Times are 100 ns units from the first encoded frame; ranges include start, exclude end, and grain is off outside them.

**Effect:** quality as good as the table · speed faster than encoder estimation · size much smaller if the input is pre-denoised

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `a table measured from the film, fed with a denoised input` | With a table the encoder does not denoise (the app turns `--film-grain` off), so the input must already be clean or grain doubles. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/App/app_config.c) |

**In Lumora:** 'Grain measured from this film': '`--fgs-table` {grain_table}' written by GrainTable.write (one E entry 0..INT64_MAX, seed 7391, lag 0, scaling_shift 11, 10 luma points, no chroma). Lumora strips `--film-grain`/--film-grain-denoise and denoises the frames itself. That layout satisfies the v4.3.0 parser (seed <= 65535, lag <= 3, <= 14 luma points, one cCb/cCr coefficient at lag 0).

**Notes:** v4.3.0 added timed tables (multiple time ranges) and per-picture grain via the API; earlier builds used the table more simply, so multi-entry tables may behave differently on older versions. Seeds advance per picture. Frame timing comes from `--fps-num`/--fps-denom, so raw input needs a correct rate. Same format as libaom's `--film-grain-table`.

<a id="adaptive-film-grain"></a>

#### `--adaptive-film-grain`

**Type:** bool · **Values:** 0-1 · **Default:** 1 · advanced

Chooses the block size the grain model is estimated from based on resolution, which reduces visible repeating grain patterns.

**Effect:** quality + grain consistency · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `1` | The appendix says it often greatly improves grain consistency. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**Notes:** Made switchable in v4.0 (from SVT-AV1-PSY).

### Color and HDR

<a id="color-help"></a>

#### `--color-help`

**Type:** bool · **Values:** none (switch) · **Default:** not stated · **HDR-relevant**

Prints the color-metadata appendix: the numeric and named values for primaries, transfer, matrix, range and chroma position, and the syntax of `--mastering-display` and `--content-light`.

**Notes:** Listed twice in the help (Options and Color Description sections); it is one switch.

<a id="input-depth"></a>

#### `--input-depth`

**Type:** enum · **Values:** 8, 10 · **Default:** 8 · **HDR-relevant**

Bit depth of the input file and of the output bitstream. SVT-AV1 does not change depth, so 10-bit output needs a 10-bit input.

**Effect:** quality + with 10-bit (less banding) · speed slightly - at very fast presets · size about +5% when an 8-bit source is promoted to 10-bit (project FAQ)

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `10` | The FAQ notes HDR video is normally encoded at 10 bits; feed a 10-bit pipe so PQ/HLG gradients are not cut to 8 bits. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |
| live action | `10 (even from 8-bit sources)` | Codec Wiki recommends 10-bit output for efficiency; the project FAQ says it reduces rounding and banding at a small (~5%) size cost. The two sources disagree on whether it saves or costs bits. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |

**In Lumora:** '`--input-depth` {bits}' from the export's bit depth (12-bit and 4:2:2/4:4:4 go to the libaom av1Pro path).

**Notes:** Disagreement noted: Codec Wiki says 10-bit is more efficient, the SVT-AV1 FAQ describes a ~5% size cost for slightly better fidelity.

<a id="color-primaries"></a>

#### `--color-primaries`

**Type:** enum · **Values:** 0-12, 22 (1 bt709, 2 unspecified, 9 bt2020, 12 smpte432 ...; names accepted) · **Default:** 2 · **HDR-relevant**

Signals the color primaries of the content in the sequence header. Only a label: it does not convert pixels.

**Effect:** quality none (wrong value = wrong colors on playback) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9 (bt2020)` | HDR10 and HLG use BT.2020/BT.2100 primaries, as in the official HDR example. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--color-primaries` {cp}': 1 for SDR, 9 for PQ and HLG targets.

**Notes:** Default 2 means unspecified; players then guess, usually BT.709.

<a id="transfer-characteristics"></a>

#### `--transfer-characteristics`

**Type:** enum · **Values:** 0-22 (1 bt709, 13 srgb, 16 smpte2084/PQ, 18 hlg ...; names accepted) · **Default:** 2 · **HDR-relevant**

Signals the transfer function (gamma, PQ or HLG). This is what tells players a stream is HDR.

**Effect:** quality none (wrong value = wrong brightness) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `16 (smpte2084) for HDR10, 18 (hlg) for HLG` | Listed values for PQ and HLG in the color appendix. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--transfer-characteristics` {tc}': 1 SDR, 16 HDR10, 18 HLG.

**Notes:** In the svt-av1-hdr fork, 16 also switches variance boost to its PQ curve automatically; mainline has no such link.

<a id="matrix-coefficients"></a>

#### `--matrix-coefficients`

**Type:** enum · **Values:** 0-14 (1 bt709, 9 bt2020-ncl, 14 ictcp ...; names accepted) · **Default:** 2 · **HDR-relevant**

Signals the RGB-to-YUV matrix used to make the input.

**Effect:** quality none (wrong value = color shifts) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9 (bt2020-ncl)` | Matches BT.2100 YCbCr used by HDR10/HLG. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--matrix-coefficients` {mc}': 1 SDR, 9 HDR.

<a id="color-range"></a>

#### `--color-range`

**Type:** enum · **Values:** 0: studio, 1: full · **Default:** 0 · **HDR-relevant**

Signals limited (16-235 style) or full range samples.

**Effect:** quality none (mismatch = crushed or washed-out levels) · speed none · size none

**In Lumora:** Always '`--color-range` 0' (studio).

**Notes:** HDR10 deliverables are normally studio range.

<a id="chroma-sample-position"></a>

#### `--chroma-sample-position`

**Type:** enum · **Values:** 'unknown', 'vertical'/'left', 'colocated'/'topleft' · **Default:** unknown · **HDR-relevant** · advanced

Signals where 4:2:0 chroma samples sit relative to luma, so the decoder upsamples chroma correctly.

**Effect:** quality slight (avoids chroma shift) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `topleft` | The official HDR example uses topleft (colocated), the usual chroma siting for BT.2020 UHD masters. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**Notes:** Parameters.md says FFmpeg does not pass this through, but current FFmpeg libsvtav1 code maps left and topleft chroma locations, so that note looks outdated. 'left' (vertical) is the usual SDR position. Lumora does not set it (unknown).

<a id="mastering-display"></a>

#### `--mastering-display`

**Type:** string · **Values:** 'G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)'; x,y CIE 1931 0.0-1.0; L in nits (floats) · **Default:** not stated · **HDR-relevant**

Writes SMPTE ST 2086 mastering-display metadata (display primaries, white point, peak and minimum luminance) into the AV1 stream for HDR10.

**Effect:** quality none (affects tone mapping on playback) · speed none · size negligible

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `G(0.2650,0.6900)B(0.1500,0.0600)R(0.6800,0.3200)WP(0.3127,0.3290)L(1000,0.0001) for a P3-D65 1000-nit master` | Same syntax and coordinate set as the official example; luminance is given directly in nits. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--mastering-display` {svt_mastering}' on HDR10 exports only: HDRMetadata.svtMastering always writes P3-D65 primaries and L(peak nits as integer, min nits).

**Notes:** Unlike x265, no 50000/10000 scaling. Out-of-range values are clipped. Lumora assumes a P3 mastering display for every HDR10 job, which is the common case but not universal.

<a id="content-light"></a>

#### `--content-light`

**Type:** string · **Values:** 'max_cll,max_fall' integers 0-65535 · **Default:** not stated · **HDR-relevant**

Writes CTA-861.3 content light level metadata: brightest pixel (MaxCLL) and brightest frame average (MaxFALL) in nits.

**Effect:** quality none (helps tone mapping) · speed none · size negligible

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `measured MaxCLL,MaxFALL (e.g. 1000,400)` | Format given in the color appendix; real values let displays tone-map well. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--content-light` {maxcll},{maxfall}' on HDR10 exports, from the measured or target metadata (0,0 when unknown).

### Analysis and motion search

<a id="enable-mfmv"></a>

#### `--enable-mfmv`

**Type:** enum · **Values:** -1: auto, 0-1 · **Default:** -1 · advanced

Motion-field motion vectors: projects motion from reference frames to predict current vectors.

**Effect:** quality + · speed slight - · size smaller

**Notes:** Auto enables it on all presets 0-10 per the FAQ feature table. That table was compiled at v2.2.0 and may be outdated.

<a id="enable-intrabc"></a>

#### `--enable-intrabc`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 1 · advanced

Allows intra block copy (copying an already-coded area of the same frame), mainly useful for screen content.

**Effect:** quality + on screen content · speed - when used · size smaller on screen content

**Notes:** New in v4.2.0; still gated by `--scm` decisions and presets.

### Partitioning and transforms

<a id="enable-qm"></a>

#### `--enable-qm`

**Type:** bool · **Values:** 0-1 · **Default:** 0

Turns on quantization matrices so high-frequency coefficients are quantized more coarsely than low ones, instead of a flat matrix.

**Effect:** quality + at high quality · speed none to slight + · size smaller at the same quality

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1` | Codec Wiki found QMs improve efficiency at high quality with no real speed cost. | [source](https://codecs.wiki/blog/svt-av1-deep-dive) |
| live action | `1` | Recommended by the Codec Wiki SVT-AV1 page. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |

**In Lumora:** Optional 'Quantization matrices': '`--enable-qm` 1 `--qm-min` N' with N from EncodeRecipes.svtQMMin, offered for every content type except screen content (docs/encoding/tuning-svtav1.md).

**Notes:** Tunes 3 (IQ) and 4 (MS-SSIM) force QMs on with levels 4-10. The svt-av1-hdr fork enables QMs by default.

<a id="qm-min"></a>

#### `--qm-min`

**Type:** int · **Values:** 0-15 · **Default:** 8 · advanced

Steepest (least flat) luma quantization matrix allowed; lower values mean stronger frequency shaping.

**Effect:** quality ± (detail vs efficiency) · speed none · size smaller when lower

| For | Value | Why | Source |
|---|---|---|---|
| live action | `0` | Codec Wiki recommends 0 unless the source has extremely heavy grain; its tests show gains on some clips at no time cost. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |
| heavy grain | `keep higher (default 8)` | Codec Wiki advises against qm-min 0 for extremely heavy grain. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |
| archive | `4` | The encoder's own IQ and MS-SSIM tunes pick 4 as the floor (v4.3.0 source), a middle ground between 0 and 8. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_handle.c) |

**In Lumora:** Per content type (EncodeRecipes.svtQMMin): 8 for anime, CG and low light, 6 for live action and old anime, 4 for heavy grain and fast motion; at least 8 for HDR10 (PQ) exports. 0 lost 3-8% XPSNR BD-rate on every clip (docs/encoding/tuning-svtav1.md).

**Notes:** The SVT-AV1 docs say lower levels lower bitrate with slightly worse quality in CRF, more so at low CRF; community tests saw net efficiency gains. Sources disagree on the best floor (0 vs 4); test on your content.

<a id="qm-max"></a>

#### `--qm-max`

**Type:** int · **Values:** 0-15 · **Default:** 15 · advanced

Flattest luma matrix allowed (15 = flat). The encoder maps each frame's qindex into the min-max range.

**Effect:** quality ± · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| live action | `15` | Codec Wiki says leave the maximum alone. | [source](https://codecs.wiki/docs/encoders/SVT-AV1) |

**Notes:** Must be >= `--qm-min` or the encoder errors.

<a id="chroma-qm-min"></a>

#### `--chroma-qm-min`

**Type:** int · **Values:** 0-15 · **Default:** 8 · advanced

Steepest chroma quantization matrix allowed.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Added in v3.1.0 from SVT-AV1-PSY.

<a id="chroma-qm-max"></a>

#### `--chroma-qm-max`

**Type:** int · **Values:** 0-15 · **Default:** 15 · advanced

Flattest chroma quantization matrix allowed.

**Effect:** quality chroma ± · speed none · size ±

**Notes:** Added in v3.1.0.

<a id="max-tx-size"></a>

#### `--max-tx-size`

**Type:** enum · **Values:** 32, 64 · **Default:** 64 · advanced

Largest transform allowed. AV1's 64-point transforms drop their top 32 frequencies, which can blur fine texture; 32 prevents that.

**Effect:** quality + texture with 32 at high quality · speed ≈ · size larger with 32 at low/medium quality

| For | Value | Why | Source |
|---|---|---|---|
| archive | `32 for still images or very high quality` | The appendix says it improves consistency especially for stills at medium-high quality; the encoder warns it may cost efficiency when QP >= 25. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**Notes:** Tune 3 sets 32 when QP <= 45.

### In-loop filters

<a id="enable-dlf"></a>

#### `--enable-dlf`

**Type:** enum · **Values:** 0-2 (0 off, 1 on, 2 slower more accurate) · **Default:** 1 · advanced

Deblocking loop filter. Level 2 searches filter levels more precisely at extra cost.

**Effect:** quality + (off causes blocking) · speed 2 slightly slower · size ±

**Notes:** Level 2 is a PSY-derived addition; its help text was corrected in v4.1.

<a id="enable-cdef"></a>

#### `--enable-cdef`

**Type:** bool · **Values:** 0-1 · **Default:** 1 · advanced

Constrained Directional Enhancement Filter: removes ringing around edges, but can smear fine grain.

**Effect:** quality + generally; - for grain retention · speed + when off · size larger when off

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `0 together with --ac-bias 4.0-6.0 and --enable-tf 0` | The SVT-AV1 psychovisual appendix says this combination can greatly improve retention of real grain and noise. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**Notes:** svt-av1-hdr's tune 6 (film grain) also turns CDEF off; that tune is not in mainline.

<a id="enable-restoration"></a>

#### `--enable-restoration`

**Type:** bool · **Values:** 0-1 · **Default:** 1 · advanced

Loop restoration (Wiener and self-guided filters), which smooths reconstruction toward the source.

**Effect:** quality + generally; can soften grain · speed + when off · size ±

**Notes:** Faster presets disable parts of it automatically (Wiener off from preset 9, self-guided off from preset 4 per the FAQ table). That table was compiled at v2.2.0 and may be outdated.

### Threading and performance

<a id="asm"></a>

#### `--asm`

**Type:** enum · **Values:** c, neon, crc32, neon_dotprod, neon_i8mm, sve, sve2, max · **Default:** max · advanced

Caps which SIMD instruction sets the encoder may use. The list shown is the Arm set for this Apple-silicon build; x86 builds list SSE/AVX levels instead.

**Effect:** quality none · speed - when restricted · size none

**Notes:** Only for debugging or reproducing results across CPUs.

<a id="lp"></a>

#### `--lp`

**Type:** int · **Values:** 0, 6 (levels 0-6; 0 = auto from core count) · **Default:** 0 · advanced

Level of parallelism, not a thread count. Higher levels create more threads and keep more pictures in flight for speed at the cost of memory; levels 4+ in CRF also process extra mini-GOPs in parallel.

**Effect:** quality none (CRF output is identical across --lp) · speed + at higher levels · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `lower level per instance (e.g. 3-4) with several instances pinned to separate cores` | The docs show running parallel encodes with a modest `--lp` each; since output is unchanged, chunked parallel instances scale better than one encode on many cores. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md) |

**In Lumora:** '`--lp` {svt_lp}': EncoderSpec.render derives the level from the cores one instance fills (threads = cpuCores for a single encode, cpuCores / instances for segments and target-quality chunks) with EncodeRecipes.svtParallelism: 1 core -> 1, 2 -> 2, 3-5 -> 3, 6-11 -> 4, 12-23 -> 5, 24+ -> 6, the table the library's automatic level applies to the whole machine. Measured on an M3 Max: level 6 was never faster than 5 and used 6-12% more memory; memory grows with every level (docs/encoding/tuning-svtav1.md).

**Notes:** Replaced the old thread-count meaning (`--lp` as logical processors) in v2.3.0/v3.0.0. Docs mention a `--pin` option, but it is not in this build's help.

<a id="tile-rows"></a>

#### `--tile-rows`

**Type:** int · **Values:** 0-6 (log2 of the count) · **Default:** 1 (changes per resolution) · advanced

Splits frames into tile rows for parallel decoding. SVT-AV1 does not need tiles for its own threading.

**Effect:** quality slight - · speed decode + (less than columns) · size slight +

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | Codec Wiki found tile rows help decoding less than columns and sometimes regress at low quality. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**Notes:** Parameters.md lists default 0; the help says it changes per resolution but is 1.

<a id="tile-columns"></a>

#### `--tile-columns`

**Type:** int · **Values:** 0-4 (log2 of the count) · **Default:** 1 (changes per resolution)

Splits frames into tile columns so multi-threaded decoders can work in parallel.

**Effect:** quality usually negligible - · speed decode +67% to +250% (Codec Wiki) · size slight +

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1 for 1080p+, 2 for 4K+` | Codec Wiki measured large decode-speed gains with negligible efficiency cost in most clips. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |
| speed | `2 (decode)` | The FAQ suggests tiles to help slow software decoders, warning that many tiles can cause visible artifacts. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md) |

**Notes:** The encoder prints a reminder to consider `--fast-decode` when tiles are used for decode speed. Tiles are switched off when superres or resize is enabled (v4.3.0 warns). Codec Wiki's v3.0 tests also treat 0 as the default.

### Logging and statistics

<a id="errlog"></a>

#### `--errlog`

**Type:** path · **Values:** file path · **Default:** stderr · advanced

Redirects error messages to a file instead of standard error.

**Notes:** Lumora captures stderr into enc-<tag>.log instead.

<a id="recon"></a>

#### `--recon` (also `-o`)

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Writes the decoder-side reconstructed frames as raw YUV, useful for metric checks without a separate decode.

**Effect:** quality none · speed - (extra I/O) · size none

**Notes:** v4.3.0 fixed recon output changing the deblocking search, so older builds could produce slightly different bitstreams with `-o`.

<a id="stat-file"></a>

#### `--stat-file`

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Writes per-picture PSNR and SSIM to a file. Only works together with `--enable-stat-report` 1.

**Effect:** quality none · speed - (metric computation) · size none

<a id="progress"></a>

#### `--progress`

**Type:** enum · **Values:** 0: none, 1: default, 2: detailed · **Default:** 1

Controls how much progress output the app prints while encoding.

**Notes:** The detailed mode (2) was reworked in v4.0 (ported from SVT-AV1-PSY).

<a id="no-progress"></a>

#### `--no-progress`

**Type:** enum · **Values:** 1: same as --progress 0, 0: same as --progress 1 · **Default:** 0

Shortcut to silence progress printing.

<a id="enable-stat-report"></a>

#### `--enable-stat-report`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Computes PSNR and SSIM against the source and prints a summary at the end (and per frame with `--stat-file`).

**Effect:** quality none · speed - (metric cost) · size none

**Notes:** Unverified: the film grain appendix says the denoised picture replaces the source when grain denoising is on, so reported PSNR/SSIM may be measured against it. The library warns that stat reports slow the encode.

### Other

<a id="help"></a>

#### `--help`

**Type:** bool · **Values:** none (switch) · **Default:** not stated

Prints the full list of command-line options for the installed build and exits.

<a id="version"></a>

#### `--version`

**Type:** bool · **Values:** none (switch) · **Default:** not stated

Prints the version of the linked SVT-AV1 library.

**Notes:** Installed build reports 'SVT-AV1 v4.3.0 (release)'.

<a id="profile"></a>

#### `--profile`

**Type:** enum · **Values:** 0: main, 1: high, 2: professional · **Default:** 0 · advanced

AV1 bitstream profile to signal. Main covers 8/10-bit 4:2:0, which is all this build encodes.

<a id="tier"></a>

#### `--tier`

**Type:** enum · **Values:** 0: main, 1: high · **Default:** 0 · advanced

AV1 tier, which sets the allowed maximum bitrate for a given level.

**Notes:** v4.3.0 fixed `--tier` being ignored when writing the sequence header; older builds always wrote main.

<a id="level"></a>

#### `--level`

**Type:** enum · **Values:** 0: autodetect, 2.0-7.3 · **Default:** 0 · advanced

AV1 level to signal (spec annex A.3). Auto picks one from resolution and rate.

**Notes:** Level/tier compliance was fixed in v4.0.0.

<a id="superres-mode"></a>

#### `--superres-mode`

**Type:** enum · **Values:** 0: off, 1-3, 4: auto-select · **Default:** 0 · advanced

Super-resolution: codes frames at reduced width and lets the decoder upscale them (1 fixed, 2 random, 3 by qindex threshold, 4 tries both and picks).

**Effect:** quality - detail; + at very low bitrates · speed - (mode 4 encodes twice) · size smaller

**Notes:** Not supported in low delay.

<a id="superres-denom"></a>

#### `--superres-denom`

**Type:** int · **Values:** 8: no scaling, 9-15, 16: half · **Default:** 8 · advanced

Horizontal downscale factor (8/denom) for superres mode 1.

**Effect:** quality - as it rises · speed + · size smaller

<a id="superres-kf-denom"></a>

#### `--superres-kf-denom`

**Type:** int · **Values:** 8: no scaling, 9-15, 16: half · **Default:** 8 · advanced

Superres downscale factor for key frames in mode 1.

**Effect:** quality - as it rises · speed + · size smaller

<a id="superres-qthres"></a>

#### `--superres-qthres`

**Type:** int · **Values:** 0-63 · **Default:** 43 · advanced

Qindex threshold above which mode 3 starts downscaling frames (63 means never).

**Effect:** quality ± · speed ± · size ±

<a id="superres-kf-qthres"></a>

#### `--superres-kf-qthres`

**Type:** int · **Values:** 0-63 · **Default:** 43 · advanced

Key-frame threshold for superres mode 3.

**Effect:** quality ± · speed ± · size ±

<a id="resize-mode"></a>

#### `--resize-mode`

**Type:** enum · **Values:** 0: none, 1: fixed scale, 2: random scale, 3: dynamic scale, 4: random access · **Default:** not stated · advanced

Reference scaling: codes frames at a lower resolution in both directions (fixed, random, buffer-driven for CBR low delay, or event-driven).

**Effect:** quality - detail · speed + · size smaller

**Notes:** Docs default 0. Mode 3 only works in 1-pass CBR low delay.

<a id="resize-denom"></a>

#### `--resize-denom`

**Type:** int · **Values:** 8-16 · **Default:** not stated · advanced

Scale factor (8/denom) for resize mode 1.

**Effect:** quality - as it rises · speed + · size smaller

**Notes:** Docs default 8.

<a id="resize-kf-denom"></a>

#### `--resize-kf-denom`

**Type:** int · **Values:** 8-16 · **Default:** not stated · advanced

Key-frame scale factor for resize mode 1.

**Effect:** quality - as it rises · speed + · size smaller

**Notes:** Docs default 8.

<a id="frame-resz-events"></a>

#### `--frame-resz-events`

**Type:** list · **Values:** comma list of frame numbers · **Default:** not stated · advanced

Frames where resize mode 4 switches to new scale factors.

**Effect:** quality ± · speed ± · size ±

**Notes:** All three event lists must have the same length.

<a id="frame-resz-kf-denoms"></a>

#### `--frame-resz-kf-denoms`

**Type:** list · **Values:** comma list of 8-16 · **Default:** not stated · advanced

Key-frame scale factors for each resize event.

**Effect:** quality ± · speed ± · size ±

<a id="frame-resz-denoms"></a>

#### `--frame-resz-denoms`

**Type:** list · **Values:** comma list of 8-16 · **Default:** not stated · advanced

Inter-frame scale factors for each resize event.

**Effect:** quality ± · speed ± · size ±

<a id="lossless"></a>

#### `--lossless`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Requests lossless coding.

**Effect:** quality intended exact · speed slower than lossy encodes (no verified figure) · size very large

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (use another lossless codec)` | Codec Wiki's v3.0 tests found the output not bit-exact on most clips and often larger than x264 -qp 0. | [source](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2) |

**Notes:** v3.1.1 and v4.3.0 contain lossless fixes, so the v3.0 finding may be outdated; not re-verified for v4.3.0.

<a id="avif"></a>

#### `--avif`

**Type:** bool · **Values:** 0-1 · **Default:** 0 · advanced

Still-picture mode with optimizations and lower memory for single images (AVIF).

**Effect:** quality + for stills · speed + · size smaller for stills

**Notes:** Presets above 9 map to 9. v4.0 allows 2-3 frames for alpha layers.

## Sources

- [SVT-AV1 Parameters (Docs/Parameters.md)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md)
- [SVT-AV1 Common Questions and Topics of Interest](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md)
- [SVT-AV1 Film Grain Synthesis Appendix](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md)
- [SVT-AV1 Variance Boost Appendix](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md)
- [SVT-AV1 Rate Control Appendix](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Rate-Control.md)
- [SVT-AV1 CHANGELOG](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/CHANGELOG.md)
- [SVT-AV1 v4.3.0 enc_settings.c (defaults and validation)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_settings.c)
- [SVT-AV1 v4.3.0 enc_handle.c (preset mapping, --lp clamp, tune overrides)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_handle.c)
- [SVT-AV1 v4.3.0 public API header EbSvtAv1Enc.h](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/API/EbSvtAv1Enc.h)
- [SVT-AV1 v4.3.0 app_film_grain.c (filmgrn1 parser)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/App/app_film_grain.c)
- [SVT-AV1 v4.3.0 app_config.c (CLI parsing, fgs-table handling)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/App/app_config.c)
- [Codec Wiki: Deep Dive into SVT-AV1's Evolution (Part 1): Presets v2.0 to v3.0](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1)
- [Codec Wiki: Deep Dive into SVT-AV1's Evolution (Part 2): Encoder Parameters Revisited](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)
- [Codec Wiki: SVT-AV1 v2.2.x Deep Dive](https://codecs.wiki/blog/svt-av1-third-deep-dive)
- [Codec Wiki: Encoding Animation with SVT-AV1: A Deep Dive](https://codecs.wiki/blog/svt-av1-deep-dive)
- [Codec Wiki: SVT-AV1 encoder page](https://codecs.wiki/docs/encoders/SVT-AV1)
- [Codec Wiki: SVT-AV1-PSY](https://codecs.wiki/docs/encoders/SVT-AV1-PSY)
- [SVT-AV1-PSY repository (archived)](https://github.com/gianni-rosato/svt-av1-psy)
- [svt-av1-hdr fork](https://github.com/juliobbv-p/svt-av1-hdr)
- [Streaming Learning Center: Choosing a Preset for SVT-AV1 and libaom-AV1](https://streaminglearningcenter.com/encoding/choosing-a-preset-for-svt-av1-and-libaom-av1.html)
- [FFmpeg libsvtav1.c wrapper source](https://code.ffmpeg.org/FFmpeg/FFmpeg/raw/branch/master/libavcodec/libsvtav1.c)

{% endraw %}
