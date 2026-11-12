---
title: x265 tuning results
parent: Encoding settings
nav_order: 21
---

# x265 tuning results

What was measured to tune Lumora's x265 (HEVC) settings, on which clips, and what changed. The options themselves are
described in the [x265 reference](x265.md) and the [guide](index.md); this page is the evidence behind the values
Lumora now uses in `Lumora/Resources/encoders.json`, `Lumora/Core/Quality/EncodeRecipes.swift` (the `hevc12` recipe
and the x265 command-line rules) and the container code in `Lumora/Core/Workflow/Packager.swift` and
`Lumora/Core/Export/ExportEngine.swift`.

## Summary

| Area | Before | Now | Why |
|---|---|---|---|
| `--hdr10-opt` | passed on every HDR10 encode | only at 10-bit 4:2:0 | x265 disables it with an error at 12-bit and 4:2:2/4:4:4 and still exits 0; see [hdr10-opt](#--hdr10-opt-on-the-12-bit-path) |
| Grain and anime without a plan | `--tune grain` / `--tune animation`; with a plan, the recipe's options instead | the same per-type options on both paths, no x265 tunes | the planner's options override what a tune sets; both tunes lost badly to Lumora's own sets; see [grain tune](#grain-and-anime-tunes-against-the-planners-options) |
| `--psy-rdoq` on fast rungs | passed on `fast` and `medium` | dropped where RDOQ is off (`fast`, `medium` without `--rdoq-level`) | it acts only inside RDOQ; the streams were bit-identical with and without it |
| Flag probing | `x265 --help` | `x265 --fullhelp`, falling back to `--help` | `--help` omits 47 flags, including `--y4m`, `--tskip` and `--qcomp` |
| HEVC copied into MP4 | FFmpeg's default tag (`hev1` from Matroska or raw streams), Dolby Vision record dropped | `-tag:v hvc1 -strict unofficial` on every FFmpeg stream copy of HEVC into MP4/MOV | Apple devices need `hvc1`; FFmpeg's MP4 muxer writes `dvcC` only with `-strict unofficial` |
| psy-rd / psy-rdoq | 2.0 / 1.5 (grainy kinds 2.0 / 4.0) | 1.0 / 1.0 for live action, CG, fast motion and screen content; unchanged for anime and grainy kinds | -2.2% VMAF, -1.9% XPSNR BD-rate on live action |
| AQ strength | x265 default 1.0 | 0.8 for anime | -5.0% VMAF, -1.8% XPSNR |
| B-frames 8 (16 for anime), 6 references, 60-frame look-ahead | in the planner's always-on set for most types (claimed +3-10% time, 1-2% smaller) | priced at their measured +10-54% time and ~0 saving, so the planner leaves them out (look-ahead stays an option for anime, 2% smaller) | measured below |
| `--rd 6` | offered for heavy grain and old anime, priced +25% | offered for low light and old anime, priced +78% | nothing saved on heavy grain; 4% on low light, 7% on old anime |
| Screen content | no screen-specific x265 tool | `--tskip` | -4.7% VMAF, -11.9% XPSNR |
| Ladder speeds | published seeds | measured on this Mac | see [presets](#preset-ladder-on-this-mac) |

Everything else that was tried is listed under [Rejected](#rejected).

---

## How it was measured

**Machine and tools.** Apple M3 Max (14-core CPU: 10 performance, 4 efficiency; 36 GB), macOS 27.3. x265
4.3+1-e9b8812 (Homebrew, 8/10/12-bit), FFmpeg 9.0.2 for decoding and XPSNR, libvmaf 3.2.0 (`vmaf` command line). The
Mac was shared with other work the whole time (load average 13-78 on 14 cores), every encode ran at `nice -n 15` with
`--pools 4`, and only one encoder ran at a time. Speed is compared as CPU time (user + system of the encoder), which
the outside load disturbs much less than wall time; differences under about 10% in the sweep tables are still noise.

**Clips.** The short clips the encoder tuning shares (cut from Tears of Steel, live action, CC-BY Blender Foundation,
and Big Buck Bunny, CG animation), searched at about 720p and confirmed at full size, all 10-bit 4:2:0 Y4M, kept
locally and never committed (the same clips the SVT-AV1 tuning used):

| Clip | Stands in for | Search / confirm size | Frames |
|---|---|---|---|
| faces (close-up, robot hand, soft street) | live action | 1280x534 / 1920x800 | 96 at 24 fps |
| bright sky (two people on a bridge, overcast sky) | live action | same | 96 |
| dark (dark scope view over the city) | live action | same | 96 |
| action (whip pans and robots) | fast motion | same | 96 |
| heavy grain (bright sky + `noise=alls=12:allf=t+u`) | heavy grain | same | 96 |
| low light (darkened scene + luma noise) | low light, noisy | same | 96 |
| CG (Big Buck Bunny, soft shadows) | 3D animation / CGI | 1280x720 / 1920x1080 | 180 at 60 fps |
| anime* (BBB held on twos, flattened, posterized, dark edge lines) | anime (approximation) | same | 96 |
| old anime* (anime* + `noise=alls=8:allf=t+u`) | old anime (approximation) | same | 96 |
| screen (Lumora's own source as a scrolling editor page, sidebar, video panel, pointer) | screen content | same | 120 at 30 fps |
| HDR10 sky / HDR10 dark (bright sky / dark converted to PQ BT.2020, SDR white at 203 cd/m²) | live action on HDR10 | 1280x534 / 1920x800 | 96 |

*Approximations: real cel animation has cleaner lines and flatter fills than a filtered render.

The low-light clip is a Tears of Steel scene with luma code values scaled by 0.32 and chroma by 0.5, plus temporal
luma noise. The HDR10 clips were made without zscale: FFmpeg's scaler decodes the BT.709 picture to RGB, a 65-point 3D
LUT applies BT.1886 (gamma 2.4), places SDR white at 203 cd/m² as ITU-R BT.2408 does for SDR content in an HDR
container, converts BT.709 to BT.2020 primaries and encodes with the ST 2084 inverse EOTF, then the scaler writes
limited-range BT.2020 10-bit Y'CbCr. Nothing in them is brighter than 203 cd/m².

**Encodes.** `x265 --input clip.y4m --y4m --preset slow --crf <q> --output-depth 10 --profile main10 --pools 4
--range limited` with BT.709 signaling (or PQ BT.2020 with `--hdr10 --hdr10-opt --repeat-headers --master-display ...
--max-cll 203,100`) and the settings under test. Four CRF points per curve: 18, 22, 26, 30 (action 26-38, screen
20-35), chosen so VMAF spans roughly 88-98 around Lumora's targets (93-96). Sweeps ran at 10-bit, where every x265
tool works and most playback happens; the adopted live-action set was confirmed at 12-bit (Lumora's default depth for
this codec) and at full size. "Shipped" is the set the planner always enabled before this work at a slow rung (the
options at or under its 5% speed-cost line):

| Content type | Shipped x265 extras |
|---|---|
| live action, fast motion, CG | `--aq-mode 3 --bframes 8 --rc-lookahead 60 --no-sao --deblock -2:-2 --psy-rd 2.0 --psy-rdoq 1.5 --no-strong-intra-smoothing` |
| heavy grain, low light | the same with `--psy-rdoq 4.0` |
| anime | `--aq-mode 3 --rc-lookahead 60 --limit-sao --deblock -1:-1 --psy-rd 2.0 --psy-rdoq 1.5 --no-strong-intra-smoothing` |
| old anime | anime with `--psy-rdoq 4.0` |
| screen | live action without `--aq-mode 3` |

Without a plan, Lumora instead passed `--tune grain` for heavy grain, low light and old anime and `--tune animation`
for anime, and nothing for the rest.

**Metrics, scored the way Lumora scores.** Each encode is decoded by FFmpeg to 10-bit 4:2:0 and compared with the clip
as code values: the `vmaf` tool reads both as Y4M (VMAF v0.6.1, VMAF NEG v0.6.1 and CAMBI with `full_ref=true`,
`eotf=bt1886` or `pq`), and XPSNR runs in FFmpeg with every color tag cleared on both inputs first
(`VMAFRunner.untagged` in `Lumora/Core/Quality/VMAF.swift`), distorted first and reference second as in `MetricSuite`.
x265 has no grain synthesis in Lumora, so grainy clips are scored against the grainy source itself. CAMBI in the
tables is the banding of the encode (the `cambi` score; for PQ clips the full-reference score, which is all libvmaf
reports there) compared at equal bitrate; positive means more banding.

**Grain energy.** Because the grain clips were made by adding noise to clean footage, the noise-free original exists.
"Grain energy" compares the grain a viewer sees with the source: σ(decoded − truth) / σ(source − truth) on
high-passed luma (luma minus a 5x5 box blur). 1.00 means as much grain as the source; lower means grain smoothed away.

**BD-rate.** Bjontegaard delta rate with piecewise-cubic (PCHIP) interpolation of log bitrate over the overlapping
quality range of the two curves: negative means smaller files at equal quality.

**Adoption rule.** A candidate was adopted for a content type when the VMAF and XPSNR BD-rates average a saving of at
least 1%, neither is worse by more than 0.5%, and CAMBI does not rise by more than 0.02 at equal bitrate; the same
rule as the SVT-AV1 tuning. Correctness fixes cite the reference they follow and report the measurement either way.
VMAF and XPSNR disagree on most x265 psychovisual tools (AQ, SAO, psy-rdoq), so many candidates that look good on one
metric were rejected by this rule. Options whose only effect was time were judged on time: the planner's speed cost
and saving for each are now the measured ones, and the planner decides.

---

## The known issues

### `--hdr10-opt` on the 12-bit path

x265's PQ-aware block QP (`--hdr10-opt`) needs 10-bit 4:2:0 BT.2020 PQ ([x265 CLI](https://x265.readthedocs.io/en/master/cli.html#cmdoption-hdr10-opt)).
At 12-bit, 4:2:2 or 4:4:4, x265 4.3+1 logs an error, turns it off and still exits 0:

```
x265 [error]: Recommended Settings for HDR10-opt: colour primaries should be BT.2020,
                                            transfer characteristics should be SMPTE ST.2084,
                                            matrix coeffs should be BT.2020,
                                            the input video should be 10 bit 4:2:0
                                            Disabling hdr10-opt.
```

`encoders.json` still asks for it on every HDR10 encode; `EncodeRecipes.x265Args` now removes it unless the encode is
10-bit 4:2:0, so the 12-bit log is clean and the command line says what the encoder does. At 10-bit it stays.

Turning it off at 10-bit was also measured on the two PQ clips:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| HDR10 sky | -7.6% | -6.1% | -1.9% | +0.001 | +2% |
| HDR10 dark | -4.6% | -4.9% | -4.8% | +0.000 | -3% |
| **mean** | **-6.1%** | **-5.5%** | **-3.3%** | **+0.000** | **-0%** |

Both metrics prefer it off, but this is not adopted: VMAF v0.6.1 and XPSNR are SDR metrics applied here to PQ code
values; the one PQ-aware score, CAMBI with `eotf=pq`, did not change; and these clips are SDR pictures placed in PQ
(nothing above 203 cd/m²), while hdr10-opt's luma QP offsets follow each block's PQ level and these clips use only
the lower part of the PQ range. The x265
documentation recommends it for HDR10, and that stays the rule until real HDR footage and an HDR metric say otherwise.

### Grain and anime tunes against the planner's options

Lumora had two different x265 setups for the same content type. Without a plan, heavy grain, low light and old anime
got `--tune grain` and anime got `--tune animation`; with a plan, the tune was dropped and the recipe's options were
used instead, and those options (`--aq-mode 3`, `--psy-rd 2.0`, `--psy-rdoq`) would have overridden the tune anyway,
because x265 applies explicit options after the tune ([x265 presets](https://x265.readthedocs.io/en/master/presets.html)).

`--tune grain` (AQ off, cutree off, flat QP ratios, psy-rd 4, psy-rdoq 10) against the planner's grain set:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -13.3% | +9.5% | +11.4% | -0.000 | +40% |
| low light | +9.7% | +50.7% | +62.9% | +0.000 | +61% |
| **mean** | **-1.8%** | **+30.1%** | **+37.2%** | **+0.000** | **+51%** |

The same with the planner's other extras added after the tune (what a combined command line would have done):

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -7.6% | +13.3% | +10.8% | -0.000 | +48% |
| low light | +24.7% | +62.1% | +62.4% | +0.001 | +74% |
| **mean** | **+8.5%** | **+37.7%** | **+36.6%** | **+0.000** | **+61%** |

Grain energy at the same CRF:

| Clip | Setting | CRF 22 | CRF 26 |
|---|---|---|---|
| heavy grain | planner grain set (psy-rdoq 4.0) | 7723 kb/s, energy 0.96 | 2381 kb/s, 0.93 |
| heavy grain | `--tune grain` | 9714 kb/s, 1.06 | 3258 kb/s, 1.03 |
| heavy grain | live-action set (psy-rdoq 1.5) | 7708 kb/s, 0.94 | 2145 kb/s, 0.89 |
| heavy grain | planner grain set with SAO on | 8610 kb/s, 0.84 | 2682 kb/s, 0.78 |
| low light | planner grain set | 2258 kb/s, 0.89 | 787 kb/s, 0.91 |
| low light | `--tune grain` | 3421 kb/s, 1.01 | 1184 kb/s, 0.98 |
| low light | live-action set | 2042 kb/s, 0.86 | 700 kb/s, 0.87 |
| low light | planner grain set with SAO on | 2476 kb/s, 0.76 | 895 kb/s, 0.81 |

The grain tune keeps all of the grain, but it needs 26-50% more bits at the same CRF and 37% more at equal XPSNR,
and 40-60% more CPU time; the planner's set keeps 89-96% of the grain energy. `--tune animation` lost the same way on
the anime clips (see [anime](#anime)). Lumora now uses one setup per content type: `encoders.json` no longer maps any
content type to an x265 tune, and without a plan `EncodeRecipes.x265Args` appends the content type's base options,
the ones the planner always enables. `X265TuningTests.testNoPlanEncodesLikeThePlannerBaseSet` checks that the two
paths match for every content type and that no flag appears twice.

### psy-rdoq on the fast rungs

`--psy-rdoq` biases RDO quantization, so it does nothing when RDOQ is off ([x265 CLI](https://x265.readthedocs.io/en/master/cli.html#cmdoption-psy-rdoq)),
and x265's `fast` and `medium` presets set `--rdoq-level 0` ([x265 presets](https://x265.readthedocs.io/en/master/presets.html)).
Encoding the faces clip (720p, CRF 24) with and without `--psy-rdoq`:

| Preset | RDOQ in the preset | `--psy-rdoq 4.0` against none |
|---|---|---|
| fast | off | bit-identical (302,585 bytes) |
| medium | off | bit-identical (331,817 bytes) |
| slow | level 2 | different (458,974 against 401,255 bytes) |

(4.0 rather than Lumora's 1.0, because 1.0 is `slow`'s own default and would match there too.)

`EncodeRecipes.x265Args` now drops `--psy-rdoq` on presets up to `medium` unless the command line also sets
`--rdoq-level` 1 or 2, so the logged command line matches what x265 does.

### Probing `--fullhelp`

`EncodeRecipes.supportedFlags()` decides which optional flags are offered by reading the encoder's help. x265's
`--help` lists 183 flags and `--fullhelp` 230; the 47 missing from the short list include `--y4m`, `--tskip`, `--qcomp`,
`--ipratio`, `--zones`, `--hme` and `--scaling-list`. Lumora now asks x265 for `--fullhelp` and falls back to `--help`
when that prints fewer than 20 flags (an unknown option on another build). The parser also reads the `--[no-]name`
form as both `--name` and `--no-name`, and the `-b/--bframes` short/long pairs.

### HEVC in MP4: `hvc1` and the Dolby Vision record

When Lumora's FFmpeg paths stream-copy HEVC into MP4 or QuickTime (the join of x265 segments, the packager's final
mux, repaired-chunk splicing and HDR10+/Dolby Vision re-muxing), FFmpeg chooses the sample entry itself. For HEVC
copied from Matroska or a raw Annex B stream it writes `hev1`, which Apple devices refuse; Apple's HLS authoring
specification asks for `hvc1`. Without `-strict unofficial`, the MP4 muxer also leaves out the Dolby Vision
configuration record (`dvcC`), so a Dolby Vision file silently becomes plain HDR10 ([FFmpeg movenc](https://ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv)).
`Packager.quickTimeVideoArgs` probes the video stream and, for HEVC going into MP4/MOV/M4V, adds
`-tag:v hvc1 -strict unofficial` (`dvh1` stays `dvh1`). The tests check the tag with ffprobe on Matroska, raw and
`hev1` inputs, through the packager, and that a Dolby Vision 8.1 file made with MP4Box keeps its record.

---

## Tuning per content type

### Live action, CG and fast motion

The sweep started from the shipped live-action set and changed one thing at a time.

**psy-rd and psy-rdoq.** Both at 1.0 (x265's own psy-rdoq for `slow`, and inside the guides' working ranges of
0.8-2.0 and 0-2):

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -4.3% | -6.6% | -0.4% | +0.024 | -3% |
| bright sky | -0.6% | -3.3% | -1.3% | +0.000 | -0% |
| dark | -2.1% | -3.3% | -3.9% | -0.043 | +2% |
| action | -1.9% | -2.5% | -2.5% | +0.001 | +4% |
| CG | -2.2% | -4.1% | -1.6% | +0.000 | +8% |
| **mean** | **-2.2%** | **-4.0%** | **-1.9%** | **-0.003** | **+2%** |

Each half alone was weaker (psy-rdoq 1.0 only: -1.6% VMAF, -0.2% XPSNR; psy-rd 1.0 only: -0.3% VMAF, -1.7% XPSNR), so
both moved. Adopted for live action, CG, fast motion and screen content.

**B-frames, references and look-ahead.** The planner priced `--bframes 8` at +4% time for 2% saving, `--ref 6` at
+10% for 1% and `--rc-lookahead 60` at +3% for 1%. Measured, each removed from (or added to) the shipped set:

B-frames back to the preset's 4:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -5.5% | -5.2% | +3.0% | +0.011 | -18% |
| bright sky | -0.5% | +0.1% | +2.2% | -0.000 | -20% |
| dark | +0.4% | +0.3% | +0.2% | -0.042 | -18% |
| action | -0.6% | -0.3% | +0.1% | -0.000 | -9% |
| CG | -0.3% | -0.1% | -0.0% | +0.000 | -16% |
| **mean** | **-1.3%** | **-1.1%** | **+1.1%** | **-0.006** | **-16%** |

6 reference frames:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | +0.1% | +0.1% | -0.4% | -0.003 | +5% |
| bright sky | -0.2% | +0.0% | +0.1% | -0.000 | +4% |
| dark | +0.0% | +0.2% | -0.1% | +0.004 | +13% |
| action | +0.1% | +0.1% | +0.1% | -0.000 | +15% |
| CG | -0.2% | -0.4% | -0.1% | +0.000 | +20% |
| **mean** | **-0.0%** | **+0.0%** | **-0.1%** | **+0.000** | **+12%** |

Look-ahead back to the preset's 25:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -0.5% | -1.3% | +1.1% | -0.014 | -12% |
| bright sky | -2.1% | -0.9% | +1.9% | -0.000 | -12% |
| dark | -0.2% | -0.1% | -0.2% | +0.002 | -10% |
| action | +0.0% | +0.1% | +0.0% | -0.001 | -3% |
| CG | -1.3% | -0.7% | +1.8% | +0.001 | -8% |
| **mean** | **-0.8%** | **-0.6%** | **+0.9%** | **-0.002** | **-9%** |

8 B-frames cost 19% CPU time for no saving on average (VMAF prefers 4, XPSNR prefers 8), 6 references 12% for
nothing, and the 60-frame look-ahead 10% for nothing. The same held on the other content types (below), except that
the look-ahead saved about 2% on anime. The options stay in the recipe with these measured costs and savings, so the
planner no longer enables them; they can still be forced on.

**The adopted set** (`--aq-mode 3 --no-sao --deblock -2:-2 --no-strong-intra-smoothing --psy-rd 1.0 --psy-rdoq 1.0`)
against the shipped one, at 720p including the PQ clips:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -5.6% | -9.8% | +5.5% | +0.039 | -21% |
| bright sky | -2.2% | -4.2% | +1.7% | +0.000 | -18% |
| dark | -3.5% | -4.7% | -3.9% | +0.014 | -11% |
| action | -2.3% | -2.9% | -2.5% | +0.001 | -6% |
| CG | -0.9% | -3.3% | +0.6% | +0.001 | -16% |
| HDR10 sky | +1.1% | -3.1% | -2.3% | +0.002 | -21% |
| HDR10 dark | -2.3% | -4.3% | -3.7% | +0.000 | -22% |
| **mean** | **-2.2%** | **-4.6%** | **-0.7%** | **+0.008** | **-17%** |

At 12-bit (Lumora's default depth for this codec):

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -6.4% | -10.6% | +1.4% | +0.003 | -15% |
| dark | -4.4% | -5.9% | -5.1% | +0.016 | -15% |
| **mean** | **-5.4%** | **-8.3%** | **-1.9%** | **+0.009** | **-15%** |

At full size (1920x800 and 1920x1080):

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| faces | -15.2% | -16.2% | +7.2% | +0.039 | -9% |
| CG | -2.0% | -3.5% | -0.1% | +0.001 | -9% |
| **mean** | **-8.6%** | **-9.9%** | **+3.5%** | **+0.020** | **-9%** |

2.2% smaller on VMAF, 4.6% on VMAF NEG and 0.7% on XPSNR at 720p, for 10-22% less CPU time. XPSNR agrees on most clips, but the faces clip loses
5.5% XPSNR at 720p and 7.2% at full size, where the dropped B-frames were worth more than the psy change; VMAF moves
the other way on that clip by 6-15%. The banding change on faces (+0.04 CAMBI) stays far below Lumora's CAMBI limit
of 1.0.

### Heavy grain and low light

`--psy-rdoq 2.0` instead of 4.0:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -16.0% | -16.2% | +2.1% | -0.000 | -3% |
| low light | -7.5% | -9.1% | +4.8% | +0.002 | -4% |
| **mean** | **-11.7%** | **-12.7%** | **+3.4%** | **+0.001** | **-4%** |

It looks better to VMAF and worse to XPSNR, and keeps less grain (0.94 instead of 0.96 on
heavy grain at CRF 22, 0.87 instead of 0.89 on low light): rejected, psy-rdoq stays 4.0.

AQ mode 2 (x265's default) instead of 3:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -6.0% | -6.0% | +0.3% | -0.000 | -3% |
| low light | -3.1% | -3.2% | +2.8% | +0.003 | -10% |
| **mean** | **-4.6%** | **-4.6%** | **+1.6%** | **+0.002** | **-7%** |

SAO on:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | +37.2% | +13.1% | +15.8% | -0.000 | -3% |
| low light | +53.1% | +23.3% | +24.9% | -0.004 | -6% |
| **mean** | **+45.1%** | **+18.2%** | **+20.4%** | **-0.002** | **-4%** |

SAO smooths grain away (energy 0.78-0.84) and costs 20-45%: SAO stays off.

`--rd 6`:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -0.1% | -0.2% | -0.0% | -0.000 | +82% |
| low light | -2.1% | +1.5% | -5.7% | -0.004 | +64% |
| **mean** | **-1.1%** | **+0.7%** | **-2.9%** | **-0.002** | **+73%** |

`--rd 6` saved nothing on heavy grain for 82% more CPU time, and 4% on low light (mean of VMAF and XPSNR) for 64%
more. It is now offered for low light (and old anime) at its measured price instead of for heavy grain.

Without `--bframes 8` and `--rc-lookahead 60`:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| heavy grain | -8.9% | -5.5% | +0.1% | +0.000 | -17% |
| low light | -2.9% | -2.8% | +2.3% | -0.001 | -22% |
| **mean** | **-5.9%** | **-4.1%** | **+1.2%** | **-0.001** | **-20%** |

Without the 8 B-frames and 60-frame look-ahead: 20% less CPU time, VMAF 6% better, XPSNR 1% worse; no saving either
way, so the measured prices apply here too.

### Anime

`--tune animation` (psy-rd 0.4, AQ strength 0.4, deblock 1:1) against the planner's anime set:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -12.2% | -14.1% | +6.8% | +0.005 | +4% |

AQ strength 0.8:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -5.0% | -4.8% | -1.8% | +0.001 | -12% |

AQ strength 0.6:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -8.8% | -8.5% | -2.4% | +0.000 | -13% |

AQ strength 0.8 is adopted for anime. 0.6 measured better still on this clip, but it is below the 0.7-1.0 the anime
guides give for flat shows, and the clip is a filtered render; it needs real anime footage first.

psy-rd 1.0:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -1.2% | -1.6% | -0.7% | +0.002 | -12% |

psy-rd 1.0 (the anime guide's value) saved 1.0% on VMAF and 0.7% on XPSNR: just under the bar, not adopted.

Without `--rc-lookahead 60`:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | +0.3% | +0.4% | +4.2% | +0.001 | -10% |

16 B-frames:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -0.0% | -0.0% | -0.2% | -0.000 | +54% |

On anime the 60-frame look-ahead saved about 2% (mean of VMAF and XPSNR), for 11% more CPU time; it stays an option the
planner prices at that. 16 B-frames cost 54% more CPU time for nothing.

SAO off instead of limited:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | -3.2% | -1.0% | +1.5% | +0.005 | -12% |

Full SAO instead of limited:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | +3.8% | +2.2% | -0.3% | -0.001 | -10% |

Deblock 0:0 instead of -1:-1:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| anime* | +0.7% | +0.9% | +1.5% | -0.001 | -13% |

Limited SAO and deblock -1:-1 stay.

### Old anime

`--tune animation` against the planner's old-anime set:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| old anime* | -27.4% | -35.5% | +156.1% | +0.007 | -37% |

`--rd 6`:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| old anime* | -5.0% | -4.8% | -9.2% | -0.000 | +91% |

`--rd 6` saved 5-9% on the grainy animation, for 91% more CPU time; the planner offers it at that price.

AQ strength 0.8:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| old anime* | -8.1% | -7.6% | +2.3% | -0.000 | -14% |

psy-rd 1.0 and psy-rdoq 2.0 instead of 2.0 and 4.0:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| old anime* | -22.4% | -26.3% | +26.3% | +0.001 | -22% |

Without `--rc-lookahead 60`:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| old anime* | +0.8% | +1.9% | -0.0% | -0.000 | -12% |

Nothing else changed for old anime.

### Screen content

Transform skip (`--tskip`):

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| screen | -4.7% | -6.0% | -11.9% | -0.006 | -5% |

psy-rd 1.0 and psy-rdoq 1.0:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| screen | -1.0% | -1.7% | -2.0% | -0.095 | -9% |

SAO on:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| screen | -2.2% | -5.6% | -8.1% | +0.080 | -4% |

AQ mode 3:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| screen | +13.6% | +13.2% | +12.8% | -0.293 | -9% |

The adopted screen set (`--no-sao --deblock -2:-2 --no-strong-intra-smoothing --psy-rd 1.0 --psy-rdoq 1.0 --tskip`)
against the shipped one:

| Clip | VMAF | VMAF NEG | XPSNR | CAMBI | CPU time |
|---|---|---|---|---|---|
| screen | -2.4% | -3.7% | -8.4% | -0.128 | -30% |

Transform skip (`--tskip`, which the guide suggests for sharp synthetic edges such as text) is the biggest single win
of the whole sweep. SAO saved bits too but added banding (+0.08 CAMBI), so it stays off. Screen content keeps x265's AQ
mode 2: mode 3 and mode 1 cost 13-29%.

---

## Planner speed numbers

### Option costs

| Option | Was (speed cost, saving) | Now, measured | Measured on |
|---|---|---|---|
| `--bframes 8` | 1.04, 2% | 1.19, 0 | live action and CG (-16% CPU without it); grain and screen together with the look-ahead |
| `--bframes 16` (anime) | 1.08, 2% | 1.54, 0 | anime |
| `--ref 6` | 1.10, 1% | 1.12, 0 | live action and CG |
| `--rc-lookahead 60` | 1.03, 1% | 1.10, 0 (anime 2%) | live action, CG, anime, old anime, screen |
| `--rd 6` | 1.25, 1% (heavy grain, old anime) | 1.78, 4% low light / 7% old anime | grain, low light, old anime |
| `--tskip` (new, screen) | | 1.0, 8% | screen |

Savings here are the mean of the VMAF and XPSNR BD-rates. x265's `slower`, `veryslow` and `placebo` presets already use rd 6 and 8
B-frames, so on those rungs the two options change nothing; the planner still prices them per option, not per rung. The always-on extras (AQ, SAO, deblock, psy, intra
smoothing) are priced at 1.0 as before; their measured CPU-time differences were within the noise.

### Preset ladder on this Mac

The live-action set adopted above, full size (faces 1920x800, 96 frames; CG 1920x1080, 180 frames), CRF 18-30, every
preset from `veryfast` to `placebo` (`placebo` on faces only). "speed vs fast" is the ratio of CPU time per frame;
the BD-rates are against `fast`.

| Preset | Clip | CPU s/frame | wall fps (4 pools) | speed vs fast (CPU) | VMAF | XPSNR | mean |
|---|---|---|---|---|---|---|---|
| veryfast | faces | 0.079 | 49.8 | 1.989 | +16.1% | +0.3% | +8.2% |
| faster | faces | 0.089 | 40.2 | 1.765 | +16.0% | +0.4% | +8.2% |
| fast | faces | 0.157 | 20.9 | 1.000 | +0.0% | +0.0% | +0.0% |
| medium | faces | 0.129 | 29.7 | 1.216 | +5.0% | -7.7% | -1.3% |
| slow | faces | 0.414 | 9.3 | 0.380 | -29.3% | -8.2% | -18.8% |
| slower | faces | 1.784 | 2.1 | 0.088 | -28.9% | -17.1% | -23.0% |
| veryslow | faces | 3.062 | 1.3 | 0.051 | -30.3% | -17.8% | -24.0% |
| placebo | faces | 6.607 | 0.6 | 0.024 | -31.4% | -18.9% | -25.1% |
| veryfast | CG | 0.048 | 61.7 | 2.085 | +3.7% | +0.6% | +2.2% |
| faster | CG | 0.046 | 86.9 | 2.140 | +3.6% | +0.4% | +2.0% |
| fast | CG | 0.099 | 36.0 | 1.000 | +0.0% | +0.0% | +0.0% |
| medium | CG | 0.082 | 43.5 | 1.205 | -3.5% | -4.3% | -3.9% |
| slow | CG | 0.280 | 12.2 | 0.353 | -24.1% | -8.4% | -16.3% |
| slower | CG | 1.019 | 3.8 | 0.097 | -30.6% | -12.3% | -21.5% |
| veryslow | CG | 1.613 | 2.4 | 0.061 | -31.6% | -13.3% | -22.4% |

`fast` is slower than `medium` on this build (it turns off early skip, which `medium` keeps) and about 3% larger, so
it is off the ladder; `faster` replaces it as the quickest rung (`veryfast` was about as fast as `faster` and no smaller).
The seeds are now relative to `faster`, from the geometric mean of the two clips' CPU-time ratios, with the saving taken as the mean of the VMAF and XPSNR BD-rates:

| Rung | Was (speed, saving) | Now (speed, saving) |
|---|---|---|
| faster | (not on the ladder) | 1.0, 0 |
| fast | 1.0, 0 | (removed) |
| medium | 0.55, 3% | 0.62, 7.3% |
| slow | 0.25, 9% | 0.19, 21.5% |
| slower | 0.09, 12% | 0.048, 26.0% |
| veryslow | 0.045, 13.5% | 0.029, 26.9% |
| placebo | 0.012, 14% | 0.0124, 28.7% (faces only) |

**Whole-machine speed.** One x265 instance on the CG clip at full size with `--pools 14` (as Lumora runs it), CRF 22,
two runs each under a load average of 22-60: `fast` 66-67 fps, `medium` 60-65 fps, `slow` 24-26 fps, `slower` 5.5-6.3
fps. The faces clip costs about 2.1 times the CPU time per 1080p frame of the CG clip, so a typical 1080p source runs
`medium` at about 43 fps here and `faster` (1.6 times `medium` by CPU time) at about 69 fps. The planner's
`baseFps1080` is the fastest rung on an 8-core reference machine, scaled by cores / 8: 69 / (14 / 8) = 39 (it was 40).
"Measure on this Mac" replaces all of these with numbers from the film itself; it was not run for this work.

---

## Rejected

| Candidate | Content | VMAF | XPSNR | CAMBI | Why rejected |
|---|---|---|---|---|---|
| `--aq-mode 2` (x265 default) | live action, CG | -3.2% | +1.8% | -0.013 | metrics disagree (VMAF better, XPSNR worse) |
| `--aq-mode 4` | live action, CG | +9.6% | -1.4% | -0.013 | VMAF 10% worse |
| `--aq-strength 0.8` | live action, CG | -2.8% | +0.9% | -0.013 | XPSNR worse by 0.9% |
| `--psy-rdoq 1.0` alone | live action, CG | -1.6% | -0.2% | +0.004 | under 1% (mean); both together adopted |
| `--psy-rd 1.0` alone | live action, CG | -0.3% | -1.7% | +0.004 | under 1% (mean); both together adopted |
| `--deblock -1:-1` | live action, CG | -0.4% | -0.1% | -0.001 | no saving |
| `--deblock 0:0` | live action, CG | -0.9% | -0.1% | -0.005 | under 1% (mean) |
| SAO on | live action, CG | +8.4% | -0.7% | +0.032 | VMAF 8% worse |
| `--limit-sao` | live action, CG | +5.5% | -1.2% | +0.050 | VMAF 6% worse, more banding |
| strong intra smoothing on | live action, CG | +0.2% | +0.1% | -0.002 | no difference |
| `--no-hdr10-opt` | HDR10 | -6.1% | -3.3% | +0.000 | SDR metrics on PQ; x265 recommends it (see above) |
| `--tune grain` | heavy grain, low light | -1.8% | +37.2% | +0.000 | XPSNR 37% worse, +51% CPU |
| `--psy-rdoq 2.0` | heavy grain, low light | -11.7% | +3.4% | +0.001 | XPSNR worse, less grain kept |
| `--aq-mode 2` | heavy grain, low light | -4.6% | +1.6% | +0.002 | XPSNR worse |
| SAO on | heavy grain, low light | +45.1% | +20.4% | -0.002 | 20-45% worse, removes grain |
| `--tune animation` | anime | -12.2% | +6.8% | +0.005 | XPSNR 7% worse |
| `--psy-rd 1.0` | anime | -1.2% | -0.7% | +0.002 | 1.0% / 0.7%: under the bar |
| `--aq-strength 0.6` | anime | -8.8% | -2.4% | +0.000 | passes the rule, but is below the guides' 0.7-1.0 and the clip is an approximation |
| `--no-sao` | anime | -3.2% | +1.5% | +0.005 | XPSNR worse |
| SAO on | anime | +3.8% | -0.3% | -0.001 | VMAF worse |
| `--deblock 0:0` | anime | +0.7% | +1.5% | -0.001 | worse |
| `--bframes 8` | anime | -0.1% | -0.1% | +0.000 | no saving |
| `--tune animation` | old anime | -27.4% | +156.1% | +0.007 | XPSNR far worse |
| `--psy-rd 1.0 --psy-rdoq 2.0` | old anime | -22.4% | +26.3% | +0.001 | XPSNR 26% worse |
| `--aq-strength 0.8` | old anime | -8.1% | +2.3% | -0.000 | XPSNR worse |
| `--bframes 8` | old anime | -0.0% | -0.0% | -0.000 | no saving |
| `--aq-mode 3` | screen | +13.6% | +12.8% | -0.293 | 13% worse |
| `--aq-mode 1` | screen | +28.9% | +25.3% | -0.312 | 25-29% worse |
| `--deblock 0:0` | screen | +1.0% | +2.3% | -0.064 | worse |
| SAO on | screen | -2.2% | -8.1% | +0.080 | more banding (+0.08 CAMBI) |

---

## End-to-end check

`Tests/LumoraTests/X265TuningTests.swift` runs the real `ExportEngine` on 2-second 640x360 generated clips with the
tuned planner choice (or no plan), into MP4, and checks each file with ffprobe (HEVC, bit depth, 48 frames, `hvc1`
tag, PQ transfer for HDR10), the x265 command line Lumora logged, and Lumora's own metrics against a ProRes 4444 XQ
export of the same job:

| Test | Content, delivery, depth | Plan | Checked | VMAF | XPSNR | CAMBI |
|---|---|---|---|---|---|---|
| `testTunedLiveActionExportSDR12Bit` | live action, SDR, 12-bit | slow rung | `--psy-rd 1.0 --psy-rdoq 1.0`, no `--bframes`/`--rc-lookahead`, Main 12, `hvc1` | 99.55 | 45.51 | 0.000 |
| `testTunedHDR10ExportKeepsHDR10OptAt10Bit` | live action, HDR10, 10-bit | slow rung | `--hdr10-opt` kept, PQ in stream and container, `hvc1` | 97.77 | 45.06 | 0.042 |
| `testHDR10At12BitDropsHDR10Opt` | live action, HDR10, 12-bit | slow rung | `--hdr10` kept, `--hdr10-opt` removed, PQ | 97.81 | 44.96 | 0.000 |
| `testLowLightWithoutPlanMatchesPlannerAndMediumDropsPsyRDOQ` | low light (noisy), SDR, 10-bit | none | the planner's base set, `--psy-rdoq 4.0`, no `--tune` | 96.33 | 36.07 | 0.001 |
| same test | low light (noisy), SDR, 10-bit | medium rung | `--psy-rdoq` dropped at `medium` | 94.09 | 34.28 | 0.002 |

The unit tests in the same file pin the decisions above (per-type psy, AQ strength, `--tskip`, the options the planner
must not pick, the ladder order), the command-line rules, the help parsing against the installed x265, and the
`hvc1` and Dolby Vision container checks.

## Reproducing

The bench scripts are not part of the repository. Each point is: encode with the command above, decode with
`ffmpeg -i out.hevc -vf format=yuv420p10le -strict -1 -f yuv4mpegpipe dist.y4m`, run
`vmaf --reference clip.y4m --distorted dist.y4m --model version=vmaf_v0.6.1 --model version=vmaf_v0.6.1neg:name=vmaf_neg
--feature cambi=full_ref=true:eotf=bt1886 --json`, and run XPSNR in FFmpeg with
`[0:v]setparams=range=unknown:color_primaries=unknown:color_trc=unknown:colorspace=unknown,format=yuv420p10le[d];`
the same for the clip as `[r]`, then `[d][r]xpsnr`. BD-rates are PCHIP over log bitrate on the overlapping quality range.
