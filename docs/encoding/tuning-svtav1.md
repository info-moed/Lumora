---
title: SVT-AV1 tuning results
parent: Encoding settings
nav_order: 20
---

# SVT-AV1 tuning results

What was measured to tune Lumora's SVT-AV1 settings, on which clips, and what changed. The settings themselves are
described in the [SVT-AV1 reference](svtav1.md) and the [guide](index.md); this page is the evidence behind the
values Lumora now uses in `Lumora/Resources/encoders.json`, `Lumora/Core/Quality/EncodeRecipes.swift` and the
planner (`Lumora/Core/Quality/EncodePlanner.swift`).

## Summary

| Area | Before | Now | Why |
|---|---|---|---|
| `--lp` | the core count (or cores per segment), clamped by the encoder to 6 | a 1-6 level from the cores one instance fills | `--lp` is a level, not a thread count; see [parallelism](#--lp-parallelism-level) |
| `--luminance-qp-bias 25` on HDR10 | passed for PQ like for SDR | dropped for PQ | Codec Wiki: SDR and HLG only; cost 1.6-1.9% XPSNR BD-rate on the PQ clips |
| Quantization matrices on HDR10 | `--qm-min` from the content type (4) | `--qm-min 8` for PQ | -1.0 to -1.8% (mean of VMAF and XPSNR) on the PQ clips |
| Grain tune (no plan) | `--film-grain 10 --film-grain-denoise 0` | `--film-grain {level} --film-grain-denoise 1`, same level as the planner | denoise 0 cost 22-30% VMAF BD-rate on heavy grain and stacks synthetic grain on coded grain; Lumora scores against a de-grained master |
| Grain level | 12 heavy grain, 8 low light, 4 old anime | 12 heavy grain, **4** low light, **8** old anime | measured per content type, below |
| Grain at fast presets | offered on every rung, priced at +4% time | preset 6 and slower only, priced per rung from measurements (+12% to +142% CPU time) | SVT-AV1 warns against grain above preset 6; its grain analysis costs a fixed time per frame |
| Temporal filter with grain synthesis | `--enable-tf 0` for heavy grain, old anime, low light | `--tf-strength 1` | 15-46% smaller against the noise-free truth |
| Quantization matrix minimum | 4 everywhere | 6 live action and old anime, 8 anime, CG and low light, 4 elsewhere | 0 lost 3-8% XPSNR everywhere; the flatter minimums saved 1.1-2.8% (mean of VMAF and XPSNR) |
| Anime tune | `--tune 0` only without a plan | `--tune 0` in the planner too | -1.1% VMAF, -2.0% XPSNR BD-rate |
| Variance boost | default curve and strength | `--variance-boost-curve 1` for low light, `--variance-boost-strength 1` for fast motion | low light -0.6% VMAF, -1.8% XPSNR; fast motion -4.9% VMAF, -0.4% XPSNR |
| AC bias | not set | `--ac-bias 1.0` for live action, CG, heavy grain and low light | -1.4% to -8.7% (mean of VMAF and XPSNR); about +7% CPU time, priced in the planner |
| `--lookahead 120` extra | always on, priced at +3% time for 0.5% saving | removed | bit-identical output with and without it at preset 4 |
| Fastest rung | preset 10 | preset 9 | SVT-AV1 warns that non-RTC presets 10+ may show artifacts; preset 9 was 23% smaller for 32% more CPU time |
| Ladder speeds | published seeds | measured on this Mac | preset 4 runs at 0.16 of preset 10's speed, not 0.085; see [presets](#preset-ladder-on-this-mac) |

Everything else that was tried is listed under [Rejected](#rejected).

---

## How it was measured

**Machine and tools.** Apple M3 Max (14-core CPU: 10 performance, 4 efficiency; 36 GB), macOS 27.3. SVT-AV1 v4.3.0
(release), FFmpeg 9.0.2 with libdav1d 1.5.4 for decoding, libvmaf 3.2.0 (`vmaf` command line). The Mac was shared
with other work the whole time (load average 17-37 on 14 cores), every encode ran at `nice -n 15` with `--lp 3`, and only one
encoder ran at a time. CPU-time differences under about 10% in the sweep tables are noise from that load; speed
decisions use the dedicated measurements in [grain cost](#grain-cost-per-preset), [parallelism](#--lp-parallelism-level)
and [presets](#preset-ladder-on-this-mac).

**Clips.** Short clips cut with FFmpeg from Tears of Steel (live action, CC-BY Blender Foundation) and Big Buck Bunny
(CG animation), searched at about 720p and confirmed at full size, all as 10-bit 4:2:0 Y4M. Kept locally, never
committed.

| Clip | Made from | Stands in for | Search / confirm size | Frames |
|---|---|---|---|---|
| faces | Tears of Steel 404.6 s: close-up face, robot hand, out-of-focus street | live action | 1280x534 / 1920x800 | 96 at 24 fps |
| bright sky | 28 s: two people on a bridge under an overcast sky | live action | same | 96 |
| dark | 106 s: dark scope view over the city | live action | same | 96 |
| action | 469.6 s: whip pans and robots in the dome battle | fast motion | same | 96 |
| heavy grain | bright sky + `noise=alls=12:allf=t+u` (8-bit, before the 10-bit conversion) | heavy grain | same | 96 |
| low light | 512 s, darkened (luma code values x0.32, chroma x0.5) + luma noise `c0s=6:c0f=t+u` | low light, noisy | same | 96 |
| CG (BBB) | Big Buck Bunny 136 s: rodents on the log, soft shadows | 3D animation / CGI | 1280x720 / 1920x1080 | 180 at 60 fps |
| anime* | BBB 109 s held on twos (12 drawings/s at 24 fps), flattened (two bilateral passes), posterized to 6 levels per channel, dark edge lines multiplied on top | anime (approximation) | same | 96 |
| old anime* | anime* + `noise=alls=8:allf=t+u` | old anime (approximation) | same | 96 |
| screen | Lumora's own source rendered as an editor page that scrolls in steps, with a sidebar, a `testsrc2` video panel and a moving pointer | screen content | same | 120 at 30 fps |
| HDR10 sky / HDR10 dark | bright sky / dark, converted to PQ BT.2020 (below) | live action on HDR10 | 1280x534 / 1920x800 | 96 |
| 20 s live action | 25-45 s, two hard cuts | keyframe interval, look-ahead | 1280x534 | 480 |

*Approximations: real cel animation has cleaner lines and flatter fills than a filtered render.

**HDR10 clips without zscale.** FFmpeg's scaler decodes the SDR BT.709 picture to RGB, a 65-point 3D LUT
(tetrahedral) applies BT.1886 (gamma 2.4) to get display light, places SDR reference white at 203 cd/m² as ITU-R
BT.2408 does for SDR content in an HDR container, converts BT.709 to BT.2020 primaries with the BT.2087 matrix and
encodes with the ST 2084 (PQ) inverse EOTF; the scaler then writes limited-range BT.2020 non-constant-luminance
10-bit Y'CbCr. The encodes carry PQ signaling, a 1000-nit mastering display and content light level 203,100. This
is the display-referred mapping, so the picture has no highlights above 203 cd/m²; it exercises PQ code values, which
is what the transfer-dependent options react to.

**Encodes.** `SvtAv1EncApp --preset 4 --crf <q> --input-depth 10` with BT.709 or PQ signaling and the settings under
test. Four CRF points per curve: 22, 28, 34, 40 (action 30-52, CG 30-54, screen 28-52), chosen so VMAF spans roughly
88-98 around Lumora's targets (93-96). "Shipped" means Lumora's planner base set for that content type before this
work, the extras the planner always enables at a slow rung:

| Content type | Shipped SVT-AV1 extras |
|---|---|
| live action | `--enable-variance-boost 1 --enable-qm 1 --qm-min 4 --lookahead 120 --sharpness 1 --tf-strength 1 --luminance-qp-bias 25` |
| fast motion, CG | the same without `--luminance-qp-bias` |
| anime | `--enable-variance-boost 1 --enable-qm 1 --qm-min 4 --lookahead 120 --sharpness 2 --enable-tf 0` |
| screen | `--enable-variance-boost 1 --lookahead 120 --sharpness 1 --tf-strength 1 --scm 1` |
| heavy grain | live action with `--enable-tf 0 --film-grain 12 --film-grain-denoise 1` |
| low light | live action with `--enable-tf 0 --film-grain 8 --film-grain-denoise 1` |
| old anime | anime with `--luminance-qp-bias 25 --film-grain 4 --film-grain-denoise 1` |

The sweeps after the grain and temporal-filter decisions started from those adopted values, so later candidates were
judged on top of earlier changes.

**Metrics, scored the way Lumora scores.** Reference and encode are compared as 10-bit 4:2:0 code values: the `vmaf`
tool reads both as Y4M (VMAF v0.6.1, VMAF NEG v0.6.1 and CAMBI with `full_ref=true`, `eotf=bt1886` or `pq`), and
XPSNR runs in FFmpeg with every color tag cleared on both inputs first (`VMAFRunner.untagged` in
`Lumora/Core/Quality/VMAF.swift`), distorted first and reference second as in `MetricSuite`.

**Grain synthesis is scored the way Lumora scores it.** Synthetic grain is random, so pixel metrics punish it even
when it looks right. As in `ExportEngine.planGrain`, encodes with `--film-grain` are decoded with
`-export_side_data film_grain` (the decoder exports the grain parameters instead of applying them; checked: the
decoded frames differ) and compared against a de-grained master: a NumPy reimplementation of
`GrainProcessor.measure` and `GrainProcessor.denoise` (bilateral, radius 3, spatial sigma 1.6, range sigma 2.5x the
measured grain). Because these clips were made by adding noise to clean footage, the noise-free original also exists,
so every grain decision was checked against that truth too. On these clips Lumora's master is a weak de-grain (its
measured sigma, 0.010 on heavy grain, is well below the added noise), which makes the truth the better judge.
"Grain energy" compares the grain a viewer sees (decoded with grain applied) with the source:
σ(decoded − truth) / σ(source − truth) on high-passed luma; 1.00 means the same amount of grain as the source.

**BD-rate.** Bjontegaard delta rate with piecewise-cubic (PCHIP) interpolation of log bitrate over the overlapping
quality range of the two curves: negative means smaller files at equal quality. "CAMBI change" is the mean CAMBI
difference at equal bitrate (PCHIP over log bitrate); positive means more banding.

**Adoption rule.** A candidate was adopted for a content type when the VMAF and XPSNR BD-rates average a saving of at
least 1%, neither is worse by more than 0.5%, and CAMBI does not rise by more than 0.02 at equal bitrate. Correctness
fixes cite the reference they follow and report the measurement either way. VMAF and XPSNR disagree on most
psychovisual tools (variance boost, quantization matrices, luminance bias, tunes), so many candidates that look good
on one metric were rejected by this rule.

---

## The known issues

### `--lp` (parallelism level)

`--lp` is a level of parallelism from 0 to 6, not a thread count. SVT-AV1 v4.3.0 says so when given more:

```
Svt[warn]: Level of parallelism supports levels [0-6]. Setting maximum parallelism level.
Svt[warn]: Level of parallelism does not correspond to a target number of processors to use. See Docs/Parameters.md for info.
```

Lumora passed the core count (14 here) or the cores per segment, so every instance ran at level 6.

One encoder instance per level, full size, 96 frames, CRF 30, presets 4 and 9: speed, CPU cores actually used
(CPU time / wall time) and peak memory. The machine was under heavy outside load during this run (load average 31-37 on
14 cores), so no niced encoder could get more than about 5 cores; the ceiling above level 4 says more about the load than
about SVT-AV1.

| Clip | Preset | lp 1 | lp 2 | lp 3 | lp 4 | lp 5 | lp 6 |
|---|---|---|---|---|---|---|---|
| faces 1920x800 | 4 | 4.4 fps, 0.6 cores, 773 MB | 13.6 fps, 2.1, 833 MB | 16.7 fps, 2.8, 1145 MB | 25.4 fps, 4.1, 1376 MB | 23.7 fps, 3.8, 1538 MB | 23.8 fps, 4.0, 1728 MB |
| faces 1920x800 | 9 | 37.0 fps, 1.0, 361 MB | 64.7 fps, 2.3, 457 MB | 98.7 fps, 3.4, 674 MB | 125.8 fps, 4.2, 852 MB | 143.9 fps, 4.8, 988 MB | 134.2 fps, 4.5, 1127 MB |
| CG 1920x1080 | 4 | 5.6 fps, 0.8, 992 MB | 15.6 fps, 2.7, 1188 MB | 22.9 fps, 4.1, 1493 MB | 22.7 fps, 4.2, 1842 MB | 24.6 fps, 4.4, 1960 MB | 26.5 fps, 4.8, 2148 MB |
| CG 1920x1080 | 9 | 37.2 fps, 1.0, 466 MB | 74.8 fps, 2.5, 582 MB | 76.6 fps, 2.7, 825 MB | 84.6 fps, 3.0, 1029 MB | 94.2 fps, 3.3, 1114 MB | 69.5 fps, 2.8, 1198 MB |

What the numbers show: a level is roughly how many cores an instance can keep busy (level 1 one core, level 2 two
to three, level 3 three to four), memory grows with every level (+10-15% per step above 3, about 2.2x from level 1 to
6 at preset 4), and level 6 was never faster than level 5 here while using 6-12% more memory. Shipped Lumora passed
14 (one segment) or 7 (two target-quality chunks at a time), which the encoder clamps to 6 with a warning, so every
instance ran at the most memory-hungry level whatever its share of the CPU.

**Adopted:** `encoders.json` passes `--lp {svt_lp}`, and `EncoderSpec.render` fills it from the cores the instance is
meant to fill with `EncodeRecipes.svtParallelism`: 1 core → 1, 2 → 2, 3-5 → 3, 6-11 → 4, 12-23 → 5, 24 and more → 6.
That is the table SVT-AV1 v4.3.0's automatic level (`--lp 0`) applies to the whole machine's core count ([enc_handle.c](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_handle.c)), applied instead to
each instance's share; levels 1-4 match what was measured, and 5 for 12-23 cores avoids level 6, which bought nothing
here. On this 14-core Mac a single export now runs at level 5 and two concurrent target-quality chunks at level 4 each
(300-350 MB less memory per instance at preset 4 than level 6). Other encoders still get `{threads}`.

The absolute speeds above are too load-dependent to recalibrate `baseFps1080`; "Measure on this Mac" measures the
instance count and speed on an idle machine.

### `--luminance-qp-bias` on HDR10

Shipped Lumora offered `--luminance-qp-bias 25` for live action, heavy grain, low light and old anime whatever the
output transfer. The bias reads a frame's mean code value as SDR brightness; Codec Wiki says to use it on SDR and HLG
only ([cw-svt-p2](https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2)). On the PQ clips, dropping it saved 1.6%
and 1.9% XPSNR BD-rate; VMAF (trained on SDR viewing, and not calibrated for PQ code values, as Lumora's own HDR note
says) preferred keeping it by 1.4% and 0.5%. **Adopted** as a correctness fix: `EncodeRecipes.svtArgs` drops it
whenever the export is HDR10, on every path (plan, target-quality trials, calibration).

On SDR it stays: removing it saved XPSNR (-1.7% mean) but cost VMAF (+1.4%) and VMAF NEG (+1.5%); levels 10 and 50
moved both metrics less than 1%; adding it to action, CG and anime was mixed (action +10% VMAF).

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| no lumabias | HDR10 sky | +1.44% | +1.38% | -1.56% | -0.001 | -3% |
| no lumabias | HDR10 dark | +0.46% | +0.45% | -1.86% | +0.000 | +1% |
| no lumabias | faces | +0.37% | +0.94% | -4.18% | -0.003 | -1% |
| no lumabias | bright sky | +2.52% | +2.25% | -1.58% | +0.000 | -9% |
| no lumabias | dark | +1.25% | +1.24% | -1.09% | +0.000 | -5% |
| no lumabias | low light | +0.60% | +1.23% | -0.76% | -0.000 | +4% |
| no lumabias | heavy grain | +3.01% | +3.18% | -0.48% | -0.001 | +4% |
| **no lumabias** | **mean of 7** | **+1.38%** | **+1.52%** | **-1.65%** | -0.001 | -1% |
| lumabias 10 | HDR10 sky | +0.43% | +0.37% | -0.78% | -0.001 | +13% |
| lumabias 10 | HDR10 dark | -0.00% | +0.03% | -0.62% | +0.000 | +5% |
| lumabias 10 | dark | +0.02% | +0.07% | -0.39% | +0.000 | -0% |
| lumabias 10 | low light | +0.24% | +0.37% | -0.48% | -0.000 | +6% |
| **lumabias 10** | **mean of 4** | **+0.17%** | **+0.21%** | **-0.57%** | -0.000 | +6% |
| lumabias 50 | HDR10 sky | -0.54% | -0.34% | +0.88% | +0.002 | +13% |
| lumabias 50 | HDR10 dark | -0.08% | -0.09% | +0.88% | +0.000 | +7% |
| lumabias 50 | dark | -0.19% | -0.34% | +0.95% | +0.000 | +0% |
| lumabias 50 | low light | -1.08% | -0.55% | +0.45% | +0.001 | +8% |
| **lumabias 50** | **mean of 4** | **-0.47%** | **-0.33%** | **+0.79%** | +0.001 | +7% |
| add lumabias 25 | action | +10.22% | +7.98% | -0.06% | +0.000 | +1% |
| add lumabias 25 | CG (BBB) | -2.89% | -2.51% | +0.96% | +0.000 | -13% |
| add lumabias 25 | anime* | -1.31% | -1.15% | +0.27% | -0.000 | +8% |
| **add lumabias 25** | **mean of 3** | **+2.01%** | **+1.44%** | **+0.39%** | -0.000 | -2% |

### Film grain: one setting per content type

Two paths described grain differently: without a plan, the `grain` tune in `encoders.json` used
`--film-grain 10 --film-grain-denoise 0`; with a plan, the recipe used 12, 8 or 4 with `--film-grain-denoise 1`.

**Denoise.** With `--film-grain-denoise 0` the encoder codes the real grain and signals synthetic grain on top. On
heavy grain it cost 22-30% VMAF BD-rate against the denoised setting (the file was as large as keeping the grain, at
every level), and Lumora's scoring, which compares against a de-grained master, then sees the coded grain as error.
The SVT-AV1 FAQ also warns that a high level with denoise off stacks synthetic noise on the real noise. On low light,
denoise 0 scored better against the truth (-10% VMAF, -14% XPSNR) but worse against Lumora's master (+4% XPSNR), the
reference the export actually uses. **Adopted:** both paths denoise (`--film-grain-denoise 1`); the tune now takes
its level from `EncodeRecipes.svtGrainLevel` through the `{svt_grain}` placeholder, so plan and tune agree, and
`ExportEngine.planGrain` now also strips synthetic grain when scoring an export that uses the tune.

**Level.** Each grain clip was encoded at levels 4, 8, 12 and 16 (denoise 1) and 8, 10 and 12 (denoise 0),
against the shipped level:

| Clip | Setting | Lumora master: VMAF | XPSNR | Truth: VMAF | VMAF NEG | XPSNR | Grain energy | kbps at CRF 34 |
|---|---|---|---|---|---|---|---|---|
| heavy grain | 4, denoise 1 | +21.8% | -12.8% | +14.5% | +27.2% | -7.7% | 0.72 | 1858 |
| heavy grain | 8, denoise 1 | +8.5% | -10.4% | +3.9% | +11.2% | -6.4% | 0.73 | 1588 |
| heavy grain | **12, denoise 1 (shipped, kept)** | 0 | 0 | 0 | 0 | 0 | 0.77 | 1385 |
| heavy grain | 16, denoise 1 | +1.8% | +14.3% | +8.1% | +0.5% | +14.4% | 0.84 | 1262 |
| heavy grain | 8 / 10 / 12, denoise 0 | +30.0% | -15.6% | +22.3% | +38.7% | -11.1% | 0.75 / 0.77 / 0.80 | 2028 |
| heavy grain | grain kept (no synthesis) | | | | | | 0.73 | 2009 |
| low light | **4, denoise 1 (adopted)** | -6.2% | -0.6% | -9.6% | -3.9% | -8.6% | 0.80 | 775 |
| low light | 8, denoise 1 (shipped) | 0 | 0 | 0 | 0 | 0 | 0.92 | 711 |
| low light | 12, denoise 1 | +19.7% | +11.1% | +26.1% | +17.3% | +22.4% | 1.09 | 672 |
| low light | 16, denoise 1 | +54.8% | +34.2% | +73.8% | +49.6% | +62.0% | 1.25 | 635 |
| low light | 8 / 10 / 12, denoise 0 | -6.0% | +4.1% | -10.2% | -1.2% | -13.9% | 0.91 / 0.98 / 1.06 | 836 |
| low light | grain kept (no synthesis) | | | | | | 0.79 | 817 |
| old anime* | 4, denoise 1 (shipped) | 0 | 0 | 0 | 0 | 0 | 0.66 | 1983 |
| old anime* | **8, denoise 1 (adopted)** | -3.5% | -5.2% | -2.6% | -6.3% | -1.5% | 0.71 | 1801 |
| old anime* | 12, denoise 1 | -2.3% | -1.1% | +0.2% | -7.9% | +7.6% | 0.84 | 1671 |
| old anime* | 16, denoise 1 | +4.0% | +15.2% | +8.6% | -4.0% | +33.6% | 0.99 | 1546 |
| old anime* | 8 / 10 / 12, denoise 0 | +5.2% | +1.6% | +6.1% | +7.9% | +1.5% | 0.73 / 0.79 / 0.86 | 2106 |
| old anime* | grain kept (no synthesis) | | | | | | 0.65 | 2087 |

BD-rates are against the shipped level of the same clip; the Lumora-master and truth columns differ only in the
reference. CAMBI rose by at most 0.016 in any grain comparison. Keeping the real grain (no synthesis) gives a grain
energy of only 0.65-0.79 at CRF 34: at that rate the encoder loses part of the grain either way.

Low light keeps less synthetic grain at level 4 (energy 0.80, the same as keeping the real noise) and is smaller on
all four measures; level 8 was close to the source's grain energy (0.92) but larger. Heavy grain stays at 12: 8 kept
more detail on XPSNR but lost on VMAF and VMAF NEG, and 16 lost everywhere except grain energy. Old anime moves to 8,
ahead on every measure. The level is roughly the strength of the noise: the low-light clip has the weakest noise, the
heavy grain clip the strongest.

### Grain cost per preset

SVT-AV1's grain analysis (estimation plus denoising) costs about the same CPU time per frame at every preset,
roughly 15 s of CPU for 96 frames at 1920x800 here, so its relative cost grows as presets get faster. Heavy grain clip,
full size, CRF 30, `--film-grain 8`:

| Preset | CPU time without grain | with grain (denoise 1) | change | with grain (denoise 0) | wall time without / with |
|---|---|---|---|---|---|
| 1 | 153.8 s | 150.1 s | -2% | 171.0 s (+11%) | 23.1 / 20.7 s |
| 2 | 70.9 s | 79.6 s | +12% | 86.8 s (+22%) | 12.3 / 12.1 s |
| 3 | 27.9 s | 42.0 s | +50% | 43.6 s (+56%) | 5.0 / 6.1 s |
| 4 | 14.0 s | 29.0 s | +107% | 29.6 s (+111%) | 2.7 / 4.3 s |
| 5 | 11.0 s | 26.3 s | +140% | 27.0 s (+146%) | 1.9 / 3.3 s |
| 6 | 10.6 s | 25.6 s | +142% | 26.5 s (+151%) | 2.1 / 3.5 s |
| 8 | 6.6 s | 21.4 s | +227% | 21.8 s (+232%) | 1.8 / 3.4 s |
| 9 | 4.4 s | 19.5 s | +339% | 19.7 s (+343%) | 0.9 / 2.6 s |
| 10 | 3.4 s | 18.6 s | +444% | 18.6 s (+445%) | 1.1 / 3.7 s |

Preset 0 was not measured; the planner takes it as preset 1 (no extra cost). Denoise off costs the same: the analysis
runs either way.

Shipped Lumora priced grain at +4% on every rung and offered it with presets 8 and 10, where it more than triples the
CPU time. SVT-AV1 v4.3.0 itself warns at preset 8:

```
Svt[warn]: It is recommended to not use Film Grain for presets greater than 6 as it produces a significant compute overhead. This combination should only be used for debug purposes.
```

**Adopted:** the `grain` extra is offered on presets 6 and slower only (`EncodeOption.rungs`), with the measured
CPU-time multiplier per rung (`EncodeOption.rungSpeedCost`), so the time-budget planner weighs it at its real price.
Lumora's own measured grain table (`--fgs-table`) is unaffected: it costs the encoder nothing and stays available on
every rung. A user who forces grain on at a fast rung gets a plan note instead of a silently slow encode.

### Temporal filter with grain synthesis

Shipped Lumora turned the temporal filter off (`--enable-tf 0`) for heavy grain, old anime and low light, to avoid
smearing grain. With grain synthesis, the encoder codes a denoised picture and the player adds the grain back, so
there is no coded grain to smear. Against the noise-free truth, `--tf-strength 1` was 15-46% smaller:

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| tf default (3) | heavy grain | -41.79% | -36.40% | -30.83% | +0.001 | +5% |
| tf default (3) | low light | -18.43% | -15.47% | -12.55% | +0.000 | +9% |
| tf default (3) | old anime* | -25.50% | -25.77% | -41.17% | +0.000 | -2% |
| **tf default (3)** | **mean of 3** | **-28.57%** | **-25.88%** | **-28.18%** | +0.000 | +4% |
| tf-strength 1 | heavy grain | -46.26% | -40.53% | -32.09% | +0.001 | +6% |
| tf-strength 1 | low light | -21.35% | -18.57% | -15.06% | +0.000 | +10% |
| tf-strength 1 | old anime* | -29.69% | -30.23% | -46.07% | -0.000 | -2% |
| **tf-strength 1** | **mean of 3** | **-32.43%** | **-29.77%** | **-31.07%** | +0.000 | +4% |

**Adopted:** `--tf-strength 1` for every content type except anime, the same as live action. If grain synthesis is
switched off for a grainy film the trade-off changes: keeping the real grain, strength 1 was 6-11% smaller on XPSNR for
low light and old anime but 8.7% larger on heavy grain, and low light banded more (CAMBI +0.084). So when the encoder
codes the real grain (presets 8 and 9, where grain synthesis is not offered, grain synthesis turned off, or a film-texture
table in place of it), heavy grain and low light get `--enable-tf 0` instead; old animation keeps strength 1. A measured
grain table (Lumora removes the grain, then hands SVT-AV1 the table in place of its own synthesis) was not measured
with either filter, so it keeps the earlier `--enable-tf 0` too: strength 1 goes only with SVT-AV1's own grain
synthesis. One rule, `EncodeRecipes.svtTemporalFilter`, decides it for the planner and the export:

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| keep grain: tf-strength 1 | heavy grain | -45.37% | -39.85% | +8.66% | +0.001 | -8% |
| keep grain: tf-strength 1 | low light | -28.42% | -24.32% | -11.21% | +0.084 | +13% |
| keep grain: tf-strength 1 | old anime* | -29.96% | -29.18% | -6.37% | +0.005 | +12% |
| **keep grain: tf-strength 1** | **mean of 3** | **-34.58%** | **-31.12%** | **-2.97%** | +0.030 | +6% |

---

## Tuning per content type

### Temporal filter strength

Live action, CG, screen and action keep `--tf-strength 1`: the default (3), 0 and off were larger at equal VMAF on every
one of these clips and on average at equal XPSNR (0 and off saved up to 1.2% XPSNR on the dark and screen clips).
Anime keeps `--enable-tf 0`: strengths 0 and 1 saved VMAF but cost XPSNR. The grainy kinds are covered above.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| tf default (3) | faces | +0.76% | +1.59% | +1.57% | +0.000 | +13% |
| tf default (3) | bright sky | +1.30% | +2.17% | +2.09% | -0.000 | -0% |
| tf default (3) | dark | +1.68% | +1.73% | +1.85% | +0.000 | -1% |
| tf default (3) | action | +0.36% | +0.23% | +0.21% | +0.000 | -5% |
| tf default (3) | CG (BBB) | +1.76% | +0.97% | +0.72% | +0.000 | -13% |
| tf default (3) | anime* | -0.19% | -0.17% | +7.08% | -0.000 | +11% |
| tf default (3) | screen | +4.31% | +2.11% | +2.90% | -0.042 | -5% |
| tf default (3) | low light | -15.93% | -10.62% | -10.45% | +0.033 | +9% |
| tf default (3) | heavy grain | -29.43% | -23.14% | -5.37% | +0.002 | +5% |
| tf default (3) | old anime* | -23.16% | -22.54% | -28.52% | +0.004 | -2% |
| **tf default (3)** | **mean of 10** | **-5.85%** | **-4.76%** | **-2.79%** | -0.000 | +1% |
| tf-strength 0 | faces | +4.63% | +3.46% | +2.26% | -0.001 | +13% |
| tf-strength 0 | bright sky | +3.50% | +2.06% | +0.38% | -0.000 | +3% |
| tf-strength 0 | dark | +0.18% | +0.01% | -1.15% | +0.000 | +2% |
| tf-strength 0 | action | +0.15% | +0.06% | -0.01% | +0.000 | -5% |
| tf-strength 0 | CG (BBB) | +1.25% | +0.75% | +1.37% | +0.000 | -14% |
| tf-strength 0 | anime* | -1.65% | -1.07% | +0.98% | -0.000 | +19% |
| tf-strength 0 | screen | +1.42% | -0.46% | -0.28% | -0.005 | -3% |
| tf-strength 0 | low light | -15.12% | -11.58% | -11.13% | +0.026 | +10% |
| tf-strength 0 | heavy grain | -22.56% | -18.89% | -2.57% | +0.001 | +7% |
| tf-strength 0 | old anime* | -13.53% | -13.46% | -18.06% | +0.003 | -0% |
| **tf-strength 0** | **mean of 10** | **-4.17%** | **-3.91%** | **-2.82%** | +0.002 | +3% |
| tf-strength 1 | anime* | -1.32% | -1.24% | +1.46% | -0.001 | +10% |
| tf-strength 1 | low light | -19.14% | -14.19% | -13.31% | +0.033 | +10% |
| tf-strength 1 | heavy grain | -33.15% | -26.81% | -6.68% | +0.002 | +6% |
| tf-strength 1 | old anime* | -27.08% | -26.70% | -34.14% | +0.004 | -2% |
| **tf-strength 1** | **mean of 4** | **-20.17%** | **-17.24%** | **-13.17%** | +0.010 | +6% |
| enable-tf 0 | faces | +15.16% | +10.49% | +11.13% | -0.005 | +2% |
| enable-tf 0 | bright sky | +7.02% | +4.76% | +3.67% | -0.001 | -4% |
| enable-tf 0 | dark | +2.34% | +1.57% | -0.50% | +0.000 | -8% |
| enable-tf 0 | action | +2.18% | +1.09% | +0.53% | +0.000 | -5% |
| enable-tf 0 | CG (BBB) | +4.76% | +3.41% | +2.46% | +0.000 | -17% |
| enable-tf 0 | screen | +1.99% | -0.59% | -0.72% | -0.005 | -11% |
| **enable-tf 0** | **mean of 6** | **+5.58%** | **+3.46%** | **+2.76%** | -0.002 | -7% |

### Variance boost

Variance boost splits VMAF and XPSNR: turning it off saved 3.7% VMAF on average and cost 7.0% XPSNR, which matches
the deep dive's finding that it helps nearly every metric except VMAF. It stays on. Two changes passed the adoption
rule for their content type and are **adopted**: the low-medium contrast curve (`--variance-boost-curve 1`) on low
light (-0.6% VMAF, -1.7% VMAF NEG, -1.8% XPSNR) and the mild strength (`--variance-boost-strength 1`) on fast motion
(-4.9% VMAF, -4.4% VMAF NEG, -0.4% XPSNR; confirmed at full size below). Everywhere else strength, octile and curve
changes split the two metrics or moved them less than 1%.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| variance boost off | faces | -10.35% | -9.79% | +7.90% | +0.006 | -4% |
| variance boost off | bright sky | -2.47% | -2.10% | +7.86% | +0.000 | -5% |
| variance boost off | dark | -5.69% | -5.16% | +7.57% | +0.000 | -11% |
| variance boost off | action | -6.91% | -5.46% | +2.31% | +0.000 | -6% |
| variance boost off | CG (BBB) | +1.15% | +0.70% | +2.84% | +0.000 | -20% |
| variance boost off | anime* | -6.69% | -6.06% | +9.81% | +0.001 | -6% |
| variance boost off | screen | +1.51% | -0.65% | +2.52% | +0.001 | -11% |
| variance boost off | low light | +0.67% | +0.72% | +4.82% | -0.006 | -7% |
| variance boost off | heavy grain | -4.98% | -5.78% | +16.71% | -0.000 | -4% |
| variance boost off | old anime* | -2.52% | -2.19% | +16.85% | -0.002 | -7% |
| variance boost off | HDR10 sky | -1.38% | -1.40% | +2.20% | +0.001 | -9% |
| variance boost off | HDR10 dark | -6.64% | -5.77% | +2.79% | +0.000 | -19% |
| **variance boost off** | **mean of 12** | **-3.69%** | **-3.58%** | **+7.02%** | +0.000 | -9% |
| vb strength 1 | faces | -4.15% | -4.22% | +1.90% | +0.002 | -2% |
| vb strength 1 | bright sky | -1.75% | -1.36% | +2.62% | -0.000 | -7% |
| vb strength 1 | dark | -2.42% | -2.18% | +1.71% | +0.000 | -6% |
| vb strength 1 | action | -4.92% | -4.41% | -0.38% | +0.000 | +3% |
| vb strength 1 | CG (BBB) | -0.59% | -0.49% | +0.70% | +0.000 | -10% |
| vb strength 1 | anime* | -3.38% | -2.85% | +2.33% | -0.000 | +14% |
| vb strength 1 | screen | +2.76% | +0.28% | +1.04% | +0.009 | -11% |
| vb strength 1 | low light | +1.39% | +1.08% | +2.14% | -0.002 | -1% |
| vb strength 1 | heavy grain | -2.89% | -3.53% | +5.48% | +0.000 | -1% |
| vb strength 1 | old anime* | -2.26% | -2.42% | +3.42% | +0.000 | -3% |
| **vb strength 1** | **mean of 10** | **-1.82%** | **-2.01%** | **+2.10%** | +0.001 | -3% |
| vb strength 3 | faces | +3.55% | +3.32% | -1.49% | -0.001 | -0% |
| vb strength 3 | bright sky | +1.17% | +1.34% | -1.69% | -0.000 | -8% |
| vb strength 3 | dark | +2.51% | +2.07% | -0.94% | +0.000 | -5% |
| vb strength 3 | action | +7.99% | +7.40% | +2.08% | +0.000 | -6% |
| vb strength 3 | CG (BBB) | -0.04% | +0.00% | -0.51% | +0.000 | -17% |
| vb strength 3 | anime* | +2.11% | +2.15% | -1.41% | +0.000 | +2% |
| vb strength 3 | screen | +4.74% | +1.57% | +0.23% | +0.013 | -10% |
| vb strength 3 | low light | +1.10% | -0.26% | -1.56% | +0.002 | -4% |
| vb strength 3 | heavy grain | +6.47% | +6.23% | -3.65% | -0.000 | +0% |
| vb strength 3 | old anime* | +4.45% | +3.54% | -1.40% | +0.001 | +1% |
| vb strength 3 | HDR10 sky | -0.12% | -0.14% | -0.31% | -0.001 | +5% |
| vb strength 3 | HDR10 dark | +1.95% | +1.62% | +0.02% | +0.000 | +0% |
| **vb strength 3** | **mean of 12** | **+2.99%** | **+2.40%** | **-0.89%** | +0.001 | -3% |
| vb octile 6 | faces | -1.86% | -1.78% | -0.86% | +0.001 | +2% |
| vb octile 6 | bright sky | -1.08% | -0.97% | +1.01% | -0.000 | -5% |
| vb octile 6 | dark | -0.34% | -0.21% | +0.78% | +0.000 | -5% |
| vb octile 6 | action | -3.47% | -2.81% | +0.03% | +0.000 | -10% |
| vb octile 6 | CG (BBB) | +1.86% | +1.50% | +0.39% | +0.000 | -23% |
| vb octile 6 | anime* | -0.45% | -0.43% | +1.65% | +0.000 | -2% |
| vb octile 6 | screen | +2.57% | +0.85% | +2.57% | -0.013 | -15% |
| vb octile 6 | low light | +1.76% | +1.58% | +1.53% | +0.006 | -5% |
| vb octile 6 | heavy grain | -1.56% | -2.38% | +2.29% | -0.001 | -1% |
| vb octile 6 | old anime* | +1.00% | +1.15% | +2.85% | +0.001 | +2% |
| **vb octile 6** | **mean of 10** | **-0.16%** | **-0.35%** | **+1.23%** | -0.001 | -6% |
| vb curve 1 | faces | +3.20% | +3.05% | -0.11% | +0.001 | +14% |
| vb curve 1 | dark | +1.03% | +0.87% | -0.68% | +0.000 | +6% |
| vb curve 1 | CG (BBB) | +0.03% | +0.19% | +0.16% | +0.000 | -14% |
| vb curve 1 | anime* | +0.86% | +0.81% | -1.14% | +0.000 | +5% |
| vb curve 1 | low light | -0.55% | -1.66% | -1.84% | +0.010 | -3% |
| vb curve 1 | HDR10 sky | -0.91% | -1.24% | -0.02% | -0.001 | +1% |
| vb curve 1 | HDR10 dark | -0.89% | -1.16% | +0.18% | +0.000 | -3% |
| **vb curve 1** | **mean of 7** | **+0.40%** | **+0.12%** | **-0.49%** | +0.001 | +1% |

### Quantization matrices

`--qm-min 0`, the community suggestion for live action, lost 3-8% XPSNR BD-rate on every clip with VMAF flat. Flatter
minimums went the other way. **Adopted:** 8 (the encoder default) for anime, CG and low light; 6 for live action and old
anime; 8 for every HDR10 export (turning quantization matrices off on PQ measured about the same, -0.1% VMAF and
-3.3% XPSNR against -0.1% and -2.7% for 8; 8 keeps one code path for SDR and PQ). Heavy grain and action stay at 4 (8 cost 3.8% VMAF on heavy grain; action moved less
than 0.2%). Turning QM off, or on for screen content, was rejected.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| qm off | faces | +1.67% | +2.18% | -5.45% | -0.001 | +2% |
| qm off | bright sky | +2.73% | +2.62% | -4.53% | +0.000 | -1% |
| qm off | dark | +1.08% | +1.00% | -3.14% | +0.000 | -7% |
| qm off | action | +0.21% | +0.18% | +0.09% | +0.000 | -4% |
| qm off | CG (BBB) | +1.20% | +0.85% | -5.59% | +0.000 | -19% |
| qm off | anime* | +1.96% | +1.56% | -0.52% | +0.001 | +2% |
| qm off | low light | +3.06% | +1.51% | -4.22% | +0.001 | -3% |
| qm off | heavy grain | +8.33% | +8.37% | +4.84% | +0.001 | -1% |
| qm off | old anime* | +5.52% | +3.56% | -1.05% | +0.001 | +1% |
| qm off | HDR10 sky | -0.25% | +0.19% | -3.94% | -0.000 | +5% |
| qm off | HDR10 dark | -0.02% | -0.15% | -2.74% | +0.000 | -1% |
| **qm off** | **mean of 11** | **+2.32%** | **+1.99%** | **-2.39%** | +0.000 | -2% |
| qm-min 0 | faces | -0.11% | +0.07% | +7.47% | +0.001 | +2% |
| qm-min 0 | bright sky | -0.10% | +0.38% | +7.85% | -0.000 | -5% |
| qm-min 0 | dark | +0.79% | +1.19% | +6.06% | +0.000 | -5% |
| qm-min 0 | action | +0.43% | +0.28% | +0.62% | +0.000 | -6% |
| qm-min 0 | CG (BBB) | +0.61% | +1.10% | +8.00% | +0.000 | -18% |
| qm-min 0 | anime* | +0.98% | +1.70% | +3.43% | -0.000 | +3% |
| qm-min 0 | low light | +1.48% | +1.79% | +6.67% | -0.001 | -3% |
| qm-min 0 | heavy grain | -0.67% | -0.37% | +5.61% | -0.000 | -1% |
| qm-min 0 | old anime* | +3.20% | +3.73% | +5.93% | -0.000 | -1% |
| qm-min 0 | HDR10 sky | +0.64% | +0.88% | +5.24% | +0.000 | +1% |
| qm-min 0 | HDR10 dark | +1.30% | +1.54% | +5.58% | +0.000 | -3% |
| **qm-min 0** | **mean of 11** | **+0.78%** | **+1.12%** | **+5.68%** | -0.000 | -3% |
| qm-min 8 | faces | +0.54% | +0.96% | -4.46% | -0.002 | +2% |
| qm-min 8 | bright sky | +0.86% | +0.90% | -4.54% | -0.000 | -5% |
| qm-min 8 | dark | +0.48% | +0.29% | -2.98% | +0.000 | -4% |
| qm-min 8 | action | -0.15% | -0.05% | -0.14% | +0.000 | -5% |
| qm-min 8 | CG (BBB) | -0.33% | -0.38% | -5.17% | +0.000 | -18% |
| qm-min 8 | anime* | -1.52% | -1.50% | -2.45% | +0.000 | +4% |
| qm-min 8 | low light | +0.18% | -0.11% | -4.01% | -0.000 | -0% |
| qm-min 8 | heavy grain | +3.77% | +3.63% | -0.14% | +0.000 | +2% |
| qm-min 8 | old anime* | +0.86% | -0.93% | -3.36% | +0.001 | +2% |
| **qm-min 8** | **mean of 9** | **+0.52%** | **+0.31%** | **-3.03%** | -0.000 | -2% |
| qm on (min 4) for screen | screen | +3.38% | +1.61% | +1.51% | +0.011 | -9% |

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| qm-min 6 | faces | -0.12% | +0.03% | -2.74% | -0.001 | +5% |
| qm-min 6 | bright sky | +0.04% | +0.34% | -2.68% | -0.000 | -3% |
| qm-min 6 | dark | -0.22% | -0.24% | -1.97% | +0.000 | -2% |
| qm-min 6 | action | +0.13% | -0.05% | -0.13% | +0.000 | -5% |
| qm-min 6 | heavy grain | +1.37% | +1.17% | -0.83% | -0.000 | +4% |
| qm-min 6 | old anime* | -0.21% | -1.00% | -1.88% | +0.001 | -1% |
| qm-min 6 | HDR10 sky | +0.40% | -0.25% | -1.91% | +0.002 | +4% |
| qm-min 6 | HDR10 dark | -0.02% | -0.02% | -1.43% | +0.000 | +4% |
| **qm-min 6** | **mean of 8** | **+0.17%** | **-0.00%** | **-1.70%** | +0.000 | +1% |
| qm-min 8 (PQ) | HDR10 sky | -0.23% | -0.27% | -3.33% | +0.002 | +6% |
| qm-min 8 (PQ) | HDR10 dark | +0.08% | -0.05% | -2.09% | +0.000 | +2% |
| **qm-min 8 (PQ)** | **mean of 2** | **-0.07%** | **-0.16%** | **-2.71%** | +0.001 | +4% |

### Sharpness

Every sharpness change moved both metrics by less than 1%; the option stays as it was (1, and 2 for animation). It is
marked as visual-only in the planner, which is what these numbers show: metrics do not see it.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| sharpness 0 | faces | -0.80% | -0.53% | +0.27% | +0.000 | +13% |
| sharpness 0 | bright sky | -0.66% | -0.33% | +0.15% | -0.000 | +3% |
| sharpness 0 | dark | +0.03% | -0.09% | +0.09% | +0.000 | +1% |
| sharpness 0 | action | -0.08% | -0.05% | -0.24% | +0.000 | -3% |
| sharpness 0 | CG (BBB) | -0.38% | -0.03% | -0.06% | +0.000 | -16% |
| sharpness 0 | anime* | -0.11% | -0.08% | +0.19% | -0.000 | +5% |
| sharpness 0 | screen | +0.78% | +0.43% | +0.61% | -0.002 | -8% |
| sharpness 0 | low light | +0.32% | -0.01% | +0.25% | +0.003 | +2% |
| sharpness 0 | heavy grain | +0.44% | +0.04% | +0.42% | -0.000 | +1% |
| sharpness 0 | old anime* | +1.23% | +0.49% | +0.44% | -0.000 | +2% |
| sharpness 0 | HDR10 sky | -0.37% | -0.20% | -0.10% | +0.004 | +3% |
| sharpness 0 | HDR10 dark | +0.52% | +0.33% | +0.25% | +0.000 | -1% |
| **sharpness 0** | **mean of 12** | **+0.08%** | **-0.00%** | **+0.19%** | +0.000 | +0% |
| sharpness 2 | faces | +0.04% | -0.09% | +0.28% | +0.001 | +4% |
| sharpness 2 | bright sky | -0.70% | -0.24% | -0.02% | -0.000 | -6% |
| sharpness 2 | dark | -0.12% | +0.06% | -0.27% | +0.000 | -6% |
| sharpness 2 | action | +0.14% | +0.10% | +0.05% | +0.000 | -8% |
| sharpness 2 | CG (BBB) | +0.03% | -0.23% | -0.17% | +0.000 | -19% |
| sharpness 2 | screen | +0.57% | +0.20% | +0.26% | +0.000 | -11% |
| sharpness 2 | low light | +0.53% | -0.17% | +0.19% | +0.002 | -1% |
| sharpness 2 | heavy grain | +0.94% | +0.68% | -0.21% | -0.001 | +1% |
| **sharpness 2** | **mean of 8** | **+0.18%** | **+0.04%** | **+0.02%** | +0.000 | -6% |
| sharpness 1 | anime* | -0.05% | +0.03% | -0.01% | -0.000 | +1% |
| sharpness 1 | old anime* | +0.12% | +0.11% | +0.06% | +0.001 | -0% |
| **sharpness 1** | **mean of 2** | **+0.03%** | **+0.07%** | **+0.02%** | +0.000 | +0% |
| sharpness 3 | anime* | -0.90% | -0.53% | -0.78% | -0.001 | +2% |
| sharpness 3 | old anime* | +1.53% | +1.34% | -0.10% | -0.001 | -1% |
| **sharpness 3** | **mean of 2** | **+0.32%** | **+0.40%** | **-0.44%** | -0.001 | +1% |

### Tune

`--tune 0` (visual quality) was ahead on both metrics only for anime (-1.1% VMAF, -2.0% XPSNR), where it is **adopted**
in the planner; the `anime` tune in `encoders.json` already used it, so plan and tune now agree. On screen content it
was also slightly ahead (-1.5% VMAF, -0.8% XPSNR) but CAMBI rose by 0.032, over the banding limit. Elsewhere tune 0
needed 8-41% more bits at equal VMAF. Tune 2 (SSIM) needed 6-25% more at equal VMAF on every clip; tune 4 (MS-SSIM)
needed 13-60% more at equal VMAF while saving XPSNR on seven clips. Tune 3 (IQ) is refused by the encoder in video mode
(`Tune IQ only supports all-intra and low delay (experimental) prediction structures`); Lumora never sets it.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| tune 0 | faces | +23.51% | +18.48% | -4.83% | -0.016 | -2% |
| tune 0 | bright sky | +13.52% | +11.96% | -5.40% | -0.002 | -10% |
| tune 0 | dark | +8.08% | +8.30% | +0.15% | +0.000 | -6% |
| tune 0 | action | +9.95% | +8.63% | +1.32% | +0.000 | -4% |
| tune 0 | CG (BBB) | +11.45% | +8.01% | +2.04% | +0.000 | -23% |
| tune 0 | anime* | -1.06% | -0.28% | -2.03% | -0.001 | -1% |
| tune 0 | screen | -1.49% | -0.89% | -0.83% | +0.032 | -11% |
| tune 0 | low light | +41.48% | +29.55% | +19.32% | -0.058 | -5% |
| tune 0 | heavy grain | +38.25% | +37.89% | -24.55% | -0.002 | -3% |
| tune 0 | old anime* | +37.35% | +39.03% | +36.41% | +0.001 | -2% |
| tune 0 | HDR10 sky | +14.60% | +12.04% | +7.09% | -0.011 | -7% |
| tune 0 | HDR10 dark | +8.41% | +8.64% | +1.97% | +0.000 | -4% |
| **tune 0** | **mean of 12** | **+17.01%** | **+15.11%** | **+2.56%** | -0.005 | -7% |
| tune 2 | faces | +24.50% | +25.21% | -3.11% | -0.007 | +1% |
| tune 2 | bright sky | +8.15% | +9.46% | -2.90% | -0.001 | -6% |
| tune 2 | dark | +12.27% | +12.42% | +1.22% | +0.000 | -10% |
| tune 2 | action | +6.58% | +7.15% | +4.94% | +0.000 | -2% |
| tune 2 | CG (BBB) | +8.87% | +8.95% | +1.29% | +0.000 | -16% |
| tune 2 | anime* | +10.56% | +12.70% | +3.22% | +0.000 | +2% |
| tune 2 | screen | +13.50% | +6.76% | +8.11% | -0.000 | -12% |
| tune 2 | low light | +6.63% | +6.56% | +1.13% | -0.005 | -2% |
| tune 2 | heavy grain | +20.92% | +20.93% | -6.74% | -0.002 | -1% |
| tune 2 | old anime* | +12.66% | +15.27% | +4.21% | -0.001 | -2% |
| tune 2 | HDR10 sky | +7.32% | +7.51% | +0.06% | -0.003 | +2% |
| tune 2 | HDR10 dark | +6.12% | +6.70% | -0.34% | +0.000 | -6% |
| **tune 2** | **mean of 12** | **+11.51%** | **+11.64%** | **+0.93%** | -0.002 | -4% |
| tune 4 | faces | +45.50% | +49.05% | -9.37% | -0.012 | +8% |
| tune 4 | bright sky | +32.71% | +33.34% | -10.74% | -0.001 | +6% |
| tune 4 | dark | +31.73% | +31.79% | -0.01% | +0.000 | -4% |
| tune 4 | action | +18.90% | +18.48% | +9.32% | +0.000 | -0% |
| tune 4 | CG (BBB) | +16.63% | +13.97% | -3.90% | +0.000 | -14% |
| tune 4 | anime* | +13.37% | +12.88% | -1.11% | -0.001 | +6% |
| tune 4 | screen | -1.40% | +0.58% | +5.04% | +0.001 | -2% |
| tune 4 | low light | +17.61% | +15.84% | -8.56% | -0.002 | +4% |
| tune 4 | heavy grain | +60.20% | +58.37% | -17.95% | -0.003 | +4% |
| tune 4 | old anime* | +25.56% | +24.47% | +0.09% | -0.003 | +4% |
| tune 4 | HDR10 sky | +23.07% | +22.26% | -3.37% | -0.002 | +7% |
| tune 4 | HDR10 dark | +22.53% | +22.13% | +1.69% | +0.000 | -5% |
| **tune 4** | **mean of 12** | **+25.53%** | **+25.26%** | **-3.24%** | -0.002 | +1% |

### AC bias

AC bias weights rate-distortion decisions toward keeping texture energy instead of smoothing it. The references name
1.0-1.5 for fast motion and 4.0-6.0 to keep real grain. Here `--ac-bias 1.0` was smaller at equal VMAF and XPSNR on
live action (-3.6% VMAF, -2.9% XPSNR, -0.8% VMAF NEG over the three clips), CG (-2.0%, -0.8%) and live action on
HDR10 (-2.5%, -1.0%), and, against the noise-free truth, on heavy grain (-4.0%, -6.1%) and low light (-14.8%, -2.7%).
It is **adopted** for those content types as the planner extra "Keep texture energy". It did not reach 1% on action
(-0.6% on both metrics), and it was mixed or larger on anime, old anime and screen content. 0.5 gained less; 2.0 raised
VMAF NEG on most clips.

Its cost, measured separately at full size with two runs each (the minimum counts): +5% (faces, preset 4), +20%
(faces, preset 6), -5% (CG, preset 4) and +8% (CG, preset 6) CPU time, so the planner prices it at +7%.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| ac-bias 0.5 | faces | -4.96% | -2.20% | -3.92% | -0.007 | +15% |
| ac-bias 0.5 | bright sky | -2.30% | -0.69% | -1.95% | -0.001 | +3% |
| ac-bias 0.5 | dark | -0.75% | -0.06% | -0.83% | +0.000 | +1% |
| ac-bias 0.5 | action | -0.04% | +0.04% | -0.43% | +0.000 | -1% |
| ac-bias 0.5 | CG (BBB) | -1.65% | -0.55% | -0.56% | +0.000 | -12% |
| ac-bias 0.5 | anime* | +0.78% | +0.72% | -1.17% | +0.000 | +12% |
| ac-bias 0.5 | screen | +1.08% | +0.08% | +0.16% | +0.016 | -2% |
| ac-bias 0.5 | low light | -8.99% | -0.72% | -0.75% | -0.023 | +2% |
| ac-bias 0.5 | heavy grain | -1.40% | +0.83% | -6.29% | -0.001 | +6% |
| ac-bias 0.5 | old anime* | +1.22% | +1.27% | -1.21% | +0.000 | +3% |
| ac-bias 0.5 | HDR10 sky | -2.94% | -1.25% | -1.15% | -0.002 | +8% |
| ac-bias 0.5 | HDR10 dark | -0.99% | -0.24% | -0.78% | +0.000 | +3% |
| **ac-bias 0.5** | **mean of 12** | **-1.75%** | **-0.23%** | **-1.57%** | -0.001 | +3% |
| ac-bias 1.0 | faces | -6.51% | -1.65% | -4.51% | -0.011 | +11% |
| ac-bias 1.0 | bright sky | -2.98% | -0.72% | -2.49% | -0.001 | +0% |
| ac-bias 1.0 | dark | -1.16% | -0.16% | -1.58% | +0.000 | +3% |
| ac-bias 1.0 | action | -0.56% | -0.31% | -0.55% | +0.000 | +0% |
| ac-bias 1.0 | CG (BBB) | -1.99% | -0.31% | -0.80% | +0.000 | +0% |
| ac-bias 1.0 | anime* | +0.45% | +0.77% | -1.23% | -0.001 | +13% |
| ac-bias 1.0 | screen | +1.95% | +0.28% | +0.10% | -0.020 | +1% |
| ac-bias 1.0 | low light | -12.26% | +0.20% | -0.81% | -0.034 | +2% |
| ac-bias 1.0 | heavy grain | -2.47% | +1.68% | -9.17% | -0.002 | +4% |
| ac-bias 1.0 | old anime* | +2.26% | +2.72% | -1.97% | -0.002 | +6% |
| ac-bias 1.0 | HDR10 sky | -3.85% | -1.24% | -1.18% | -0.006 | +12% |
| ac-bias 1.0 | HDR10 dark | -1.15% | +0.18% | -0.86% | +0.000 | +6% |
| **ac-bias 1.0** | **mean of 12** | **-2.36%** | **+0.12%** | **-2.09%** | -0.006 | +5% |
| ac-bias 2.0 | faces | -7.20% | -0.46% | -3.99% | -0.012 | +14% |
| ac-bias 2.0 | bright sky | -3.57% | -0.20% | -2.69% | -0.001 | +6% |
| ac-bias 2.0 | dark | -0.60% | +0.73% | -1.09% | +0.000 | +3% |
| ac-bias 2.0 | action | -0.38% | -0.02% | -0.34% | +0.000 | +2% |
| ac-bias 2.0 | CG (BBB) | -1.63% | +0.74% | +0.40% | +0.000 | -5% |
| ac-bias 2.0 | anime* | +1.00% | +2.25% | -0.59% | -0.001 | +17% |
| ac-bias 2.0 | screen | +0.33% | +0.13% | +0.57% | -0.028 | +10% |
| ac-bias 2.0 | low light | -14.72% | +2.54% | +0.56% | -0.046 | +7% |
| ac-bias 2.0 | heavy grain | -1.66% | +4.42% | -11.51% | -0.002 | +8% |
| ac-bias 2.0 | old anime* | +4.61% | +5.66% | -0.79% | -0.001 | +7% |
| ac-bias 2.0 | HDR10 sky | -3.35% | +0.53% | +0.35% | -0.001 | +11% |
| ac-bias 2.0 | HDR10 dark | -0.68% | +0.96% | -0.29% | +0.000 | +3% |
| **ac-bias 2.0** | **mean of 12** | **-2.32%** | **+1.44%** | **-1.62%** | -0.008 | +7% |

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| ac-bias 0.5 (truth) | heavy grain | -1.94% | +0.32% | -4.77% | -0.001 | +6% |
| ac-bias 0.5 (truth) | low light | -10.85% | -4.53% | -2.62% | +0.000 | +2% |
| ac-bias 0.5 (truth) | old anime* | +0.74% | +1.11% | -0.69% | -0.000 | +3% |
| **ac-bias 0.5 (truth)** | **mean of 3** | **-4.01%** | **-1.03%** | **-2.69%** | -0.000 | +4% |
| ac-bias 1.0 (truth) | heavy grain | -3.95% | +0.90% | -6.06% | -0.001 | +4% |
| ac-bias 1.0 (truth) | low light | -14.81% | -4.86% | -2.69% | +0.000 | +2% |
| ac-bias 1.0 (truth) | old anime* | +1.96% | +2.73% | -0.37% | -0.000 | +6% |
| **ac-bias 1.0 (truth)** | **mean of 3** | **-5.60%** | **-0.41%** | **-3.04%** | -0.000 | +4% |

### Look-ahead, keyframe interval and screen-content mode

**Look-ahead.** The planner's "Deeper look-ahead" extra (`--lookahead 120`, priced at +3% time for a 0.5% saving) changed
nothing: on every 4 s clip and on the 20 s clip, encodes with and without it were bit-identical at preset 4. The extra
is **removed**, so the planner no longer charges time for it or credits a saving.

**Keyframe interval** (20 s live-action clip with two cuts; the encoder default is about 5 s): 10 s (`--keyint 240`, or
`10s`) moved both metrics by less than 1% (VMAF -0.8%, XPSNR +0.2% and +0.7%). 20 s saved 3.8% VMAF and 3.3% XPSNR,
but on this clip that means one keyframe instead of four, which makes seeking coarse, and the result depends on where
the dropped keyframes fall. Lumora's segments and target-quality chunks already start new GOPs. Not adopted: the
default stays.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| keyint 240 (10 s) | 20 s live action | -0.84% | -0.89% | +0.17% | +0.000 | -3% |
| keyint 10s | 20 s live action | -0.86% | -1.00% | +0.65% | +0.000 | -4% |
| keyint 480 (20 s) | 20 s live action | -3.83% | -3.74% | -3.33% | +0.000 | -5% |
| lookahead default (20 s clip) | 20 s live action | +0.00% | +0.00% | +0.00% | +0.000 | -10% |

`--scm 2` and `--scm 3` gave bit-identical results to `--scm 1` on the screen clip (the detector finds the screen
content), and `--scm 0` was 27-30% larger, so screen content keeps `--scm 1`. On anime, turning screen-content tools
off (`--scm 0`) was larger too. At presets 9 and above SVT-AV1 turns screen-content tools off itself.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| lookahead default | faces | +0.00% | +0.00% | +0.00% | +0.000 | +7% |
| lookahead default | bright sky | +0.00% | +0.00% | +0.00% | +0.000 | -1% |
| lookahead default | dark | +0.00% | +0.00% | +0.00% | +0.000 | +1% |
| lookahead default | action | +0.00% | +0.00% | +0.00% | +0.000 | +1% |
| lookahead default | CG (BBB) | +0.00% | +0.00% | +0.00% | +0.000 | -11% |
| lookahead default | anime* | +0.00% | +0.00% | +0.00% | +0.000 | +10% |
| lookahead default | screen | +0.00% | +0.00% | +0.00% | +0.000 | -3% |
| lookahead default | low light | +0.00% | +0.00% | +0.00% | +0.000 | +3% |
| lookahead default | heavy grain | +0.00% | +0.00% | +0.00% | +0.000 | +3% |
| lookahead default | old anime* | +0.00% | +0.00% | +0.00% | +0.000 | +2% |
| **lookahead default** | **mean of 10** | **+0.00%** | **+0.00%** | **+0.00%** | +0.000 | +1% |
| ac-bias 1.0 | action | -0.56% | -0.31% | -0.55% | +0.000 | +0% |
| ac-bias 1.0 | faces | -6.51% | -1.65% | -4.51% | -0.011 | +11% |
| ac-bias 1.0 | heavy grain | -2.47% | +1.68% | -9.17% | -0.002 | +4% |
| **ac-bias 1.0** | **mean of 3** | **-3.18%** | **-0.09%** | **-4.74%** | -0.004 | +5% |
| scm 2 (auto) | screen | +0.00% | +0.00% | +0.00% | +0.000 | -8% |
| scm 3 | screen | +0.00% | +0.00% | +0.00% | +0.000 | -7% |
| scm 0 | screen | +27.13% | +29.93% | +28.01% | -0.069 | -20% |
| scm 0 | anime* | +1.72% | +1.86% | +6.08% | -0.002 | -19% |
| **scm 0** | **mean of 2** | **+14.42%** | **+15.90%** | **+17.04%** | -0.035 | -19% |

---

## Preset ladder on this Mac

Speed per preset as CPU time per frame: Lumora runs as many encoder instances as fill the CPU, so CPU time is what a
preset costs in throughput. Measured with the shipped live-action extras and `--lp 3` on faces, CG and anime* (720p,
first 48 frames) and on the 20 s live-action clip (480 frames). Savings are BD-rates against preset 10 over the four
CRF points (faces has no VMAF overlap with preset 10 at presets 0-2, so those averages use three clips).

| Preset | CPU s per frame: faces / CG / anime* / 20 s | Speed vs preset 10 (geometric mean) | Shipped seed | New seed | Smaller than preset 10 at equal VMAF | at equal XPSNR | Seed saving (kept) |
|---|---|---|---|---|---|---|---|
| 10 | 0.013 / 0.013 / 0.014 / 0.016 | 1.00 | 1.0 | removed | 0 | 0 | 0 |
| 9 | 0.019 / 0.016 / 0.018 / 0.020 | 0.76 | (not offered) | 0.76 | 23.3% | 19.4% | 0.071 (new) |
| 8 | 0.024 / 0.022 / 0.032 / 0.025 | 0.54 | 0.55 | 0.54 | 30.4% | 24.3% | 0.093 |
| 6 | 0.061 / 0.049 / 0.055 / 0.050 | 0.26 | 0.20 | 0.26 | 42.3% | 35.6% | 0.167 |
| 5 | 0.078 / 0.069 / 0.076 / 0.064 | 0.19 | 0.13 | 0.19 | 45.3% | 40.6% | 0.185 |
| 4 | 0.084 / 0.080 / 0.102 / 0.079 | 0.16 | 0.085 | 0.16 | 47.5% | 42.6% | 0.204 |
| 3 | 0.165 / 0.140 / 0.196 / 0.133 | 0.088 | 0.058 | 0.088 | 51.1% | 45.1% | 0.213 |
| 2 | 0.315 / 0.285 / 0.257 / 0.266 | 0.049 | 0.040 | 0.049 | 52.1% | 47.7% | 0.222 |
| 1 | 0.604 / 0.509 / 0.479 / 0.529 | 0.026 | 0.020 | 0.026 | 54.1% | 50.5% | 0.226 |
| 0 | 1.449 / 1.378 / 1.174 / 1.289 | 0.010 | 0.009 | 0.010 | 55.8% | 52.9% | 0.229 |

**Adopted:**

- **Speeds** (`seedSpeed`) are now the measured ones. Presets 3-6 run 1.3-1.9x faster relative to the top of the
  ladder than the published seeds assumed, so the time-budget planner now reaches slower presets within the same
  budget. "Measure on this Mac" still replaces these with measurements of the user's own Mac.
- **Preset 10 is no longer a rung; preset 9 is the fastest.** SVT-AV1 v4.3.0 prints
  `Non-RTC M10+ are meant for automation tooling usage. Visual artifacts may occur otherwise.` for preset 10, and
  preset 9 was 23% smaller at equal VMAF for 32% more CPU time. (Lumora at 4K already got 9: random-access presets above
  9 are capped there.)

**Kept, for now:** the seed savings. The measured savings are about twice the seeds all the way down the ladder, in
the same order (preset 6 against 8: 17% measured, 8% seeded; 4 against 6: 9% against 4%). The libaom rungs at the slow
end of the same ladder are seeded against these numbers (libaom cpu-used 0 about 1.4% smaller than preset 0), so
rescaling the SVT-AV1 side alone would make libaom look far worse than it is; both should move together when the
libaom rungs are measured. Until then the planner underrates what slower SVT-AV1 presets save, which errs toward
faster encodes. Preset 9's seed saving, 0.071, sits where its
measured saving falls between presets 10 and 8. `baseFps1080` (55, the preset-10 anchor that both encoders' speeds
multiply) is unchanged for the same reason; the absolute speed measured here is in [parallelism](#--lp-parallelism-level).

---

## Full-size confirmation

Every clip at full size (1920x800 or 1920x1080), preset 4, shipped extras against everything adopted above (for the
HDR10 clips, the PQ rules included). Scored as Lumora scores; the grain clips also against the noise-free truth.

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| shipped -> adopted | faces | -5.43% | -0.52% | -5.65% | +0.000 | +4% |
| shipped -> adopted | bright sky | -3.08% | -0.47% | -4.65% | +0.000 | +4% |
| shipped -> adopted | dark | -1.45% | +0.01% | -0.70% | +0.000 | +2% |
| shipped -> adopted | action | +0.00% | +0.00% | +0.00% | +0.000 | +9% |
| shipped -> adopted | CG (BBB) | -4.64% | -1.11% | -4.49% | +0.000 | +13% |
| shipped -> adopted | anime* | -2.06% | -0.92% | -5.67% | -0.001 | +10% |
| shipped -> adopted | screen | +0.00% | +0.00% | +0.00% | +0.000 | -7% |
| shipped -> adopted | low light | -44.62% | -22.89% | -21.36% | -0.035 | +5% |
| shipped -> adopted | heavy grain | -31.80% | -23.66% | -9.76% | +0.000 | +8% |
| shipped -> adopted | old anime* | -26.40% | -28.92% | -31.92% | -0.002 | +8% |
| shipped -> adopted | HDR10 sky | -4.10% | -0.46% | -5.26% | +0.000 | +2% |
| shipped -> adopted | HDR10 dark | -1.78% | -0.10% | -2.55% | +0.000 | -1% |
| **shipped -> adopted** | **mean of 12** | **-10.45%** | **-6.59%** | **-7.67%** | -0.003 | +5% |

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| shipped -> adopted (truth) | heavy grain | -46.27% | -39.13% | -27.24% | +0.000 | +8% |
| shipped -> adopted (truth) | low light | n/a | -38.02% | -31.22% | +0.000 | +5% |
| shipped -> adopted (truth) | old anime* | -28.02% | -31.03% | -36.95% | -0.002 | +8% |
| **shipped -> adopted (truth)** | **mean of 3** | **-37.15%** | **-36.06%** | **-31.80%** | -0.001 | +7% |

Screen content, and action in this run, are bit-identical before and after: the only change for them here, dropping
`--lookahead 120`, has no effect, which doubles as a check that the comparison is fair. The fast-motion variance-boost
change was adopted after this run and confirmed on its own:

| Candidate | Clip | BD-rate VMAF | BD-rate VMAF NEG | BD-rate XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| shipped -> adopted | action | -8.47% | -7.69% | -1.15% | +0.000 | +7% |

For low light against the truth the two VMAF curves do not overlap: the adopted settings at their lowest rate
(1026 kbps, VMAF 91.6) score above the shipped ones at their highest (2070 kbps, VMAF 91.5), so they are at least 50%
smaller there. Most of the grain-type gain comes from turning the temporal filter back on under grain synthesis; on
live action and CG it comes from AC bias and the flatter quantization matrices. CPU time rose by about 5% on average,
in line with the AC bias measurement.

---

## End-to-end check

`Tests/LumoraTests/SVTAV1TuningTests.swift` pins every decision above and runs Lumora's real export path
(`ExportEngine.run`) on short generated clips with the tuned planner choice at preset 4 (and preset 8 for grain): live
action to SDR, live action to HDR10 and noisy low light to SDR. Each output is checked with ffprobe (AV1, 10-bit, frame
count, PQ transfer for HDR10), the SVT-AV1 command line Lumora logged (`--lp` level, no luminance bias on PQ, grain
level and denoise, no grain at preset 8), the AV1 film-grain side data, and Lumora's own metrics (VMAF, XPSNR and
CAMBI through `MetricSuite`) against a ProRes 4444 XQ export of the same job.

Results of the export tests on this Mac (640x360, 48 frames, quality 0.5, i.e. CRF 28; metrics against the ProRes
reference, so the grade is the same on both sides):

| Export | Command line Lumora logged (extras) | VMAF | XPSNR | CAMBI |
|---|---|---|---|---|
| live action, SDR, preset 4 | `--lp 5 --enable-variance-boost 1 --enable-qm 1 --qm-min 6 --ac-bias 1.0 --sharpness 1 --tf-strength 1 --luminance-qp-bias 25` | 99.37 | 45.14 dB | 0.028 |
| live action, HDR10, preset 4 | `--lp 5 ... --enable-qm 1 --qm-min 8 --ac-bias 1.0 --sharpness 1 --tf-strength 1` (no luminance bias) | 96.85 | 43.24 dB | 0.142 |
| low light, SDR, preset 4 | `--lp 5 --enable-variance-boost 1 --variance-boost-curve 1 --enable-qm 1 --qm-min 8 --ac-bias 1.0 --sharpness 1 --tf-strength 1 --luminance-qp-bias 25 --film-grain 4 --film-grain-denoise 1` | 96.68 | 34.48 dB | 0.000 |
| low light, SDR, preset 8 | the same without `--film-grain` | 96.90 | 35.57 dB | 0.464 |

The low-light rows are scored with the synthetic grain applied, against a reference that has the real noise, so they
only show that the file is sound; the grain comparison that matters is the one above. The AV1 frames of the preset-4
low-light export carry film-grain parameters.

---

## Rejected

Means are over the clips the candidate was tried on; per-clip numbers are in the tables above. "Mixed" means VMAF and
XPSNR pointed in opposite directions by more than the 0.5% tolerance.

| Candidate | Tried on | Result (BD-rate, negative = smaller) | Why not adopted |
|---|---|---|---|
| `--luminance-qp-bias` off for SDR | live action, low light, heavy grain | VMAF +0.4% to +3.0%, XPSNR -0.5% to -4.2% | mixed |
| `--luminance-qp-bias 10` / `50` | HDR10, dark, low light | under 1% on both metrics | below 1% |
| adding `--luminance-qp-bias 25` | action, CG, anime | action VMAF +10.2%; CG and anime VMAF -2.9% and -1.3%, XPSNR +1.0% and +0.3% | larger or mixed |
| `--tf-strength 3` (default), `0`, or `--enable-tf 0` | live action, action, CG, screen | +0.2% to +15% on VMAF | larger |
| any temporal filter on anime | anime | VMAF -0.2% to -1.7%, XPSNR +1.0% to +7.1% | mixed |
| variance boost off | all 12 clips | VMAF -3.7%, XPSNR +7.0% | mixed |
| `--variance-boost-strength 1` outside fast motion, `3` | all | 1: VMAF -1.8%, XPSNR +2.1%; 3: VMAF +3.0%, XPSNR -0.9% | mixed |
| `--variance-octile 6` | all | VMAF -0.2%, XPSNR +1.2%; on action -3.5% / +0.0%, behind strength 1 | mixed; strength 1 adopted for fast motion |
| `--variance-boost-curve 1` outside low light | live action, CG, anime, HDR10 | under 1% | below 1% |
| quantization matrices off | all | VMAF +2.3%, XPSNR -2.4% | mixed |
| `--qm-min 0` | all | VMAF +0.8%, XPSNR +5.7% | larger |
| `--qm-min 8` for live action, heavy grain, old anime | those | live action VMAF +0.6% (XPSNR -4.0%); heavy grain VMAF +3.8% | VMAF worse; 6 adopted for live action and old anime |
| quantization matrices on for screen | screen | VMAF +3.4%, XPSNR +1.5% | larger |
| `--sharpness 0`, `2`, `3`; `1` for anime | all | under 1% everywhere | below 1% |
| `--tune 0` outside anime | all | VMAF +8% to +41% on live action, CG, grain | larger |
| `--tune 0` on screen | screen | VMAF -1.5%, XPSNR -0.8%, CAMBI +0.032 | more banding |
| `--tune 2` (SSIM) | all | VMAF +6% to +25% | larger |
| `--tune 4` (MS-SSIM) | all | VMAF +13% to +60%; XPSNR smaller on seven clips | mixed |
| `--ac-bias 0.5` / `2.0` | all | 0.5 saved less than 1.0; 2.0 raised VMAF NEG | 1.0 better |
| `--ac-bias 1.0` on action, anime, old anime, screen | those | action -0.6%; anime and old anime VMAF +0.5% and +2.3%; screen VMAF +2.0% | below 1% or larger |
| `--scm 2` / `3` / `0` | screen (and 0 on anime) | 2 and 3 identical to 1; 0 +27% to +30% on screen, +1.7% VMAF and +6.1% XPSNR on anime | no gain |
| `--keyint 240`, `10s`, `480` | 20 s live action | 10 s under 1%; 20 s -3.8% VMAF, -3.3% XPSNR | below 1%; 20 s means one keyframe per 20 s |
| other grain levels and `--film-grain-denoise 0` | heavy grain, low light, old anime | see the grain table | larger or inconsistent with Lumora's scoring |

---

## Reproducing

The clips and the measuring scripts are not part of the repository (the footage is large and local). To repeat a
comparison: cut the clips as in the table above with FFmpeg, encode each setting at the four CRF points with
`SvtAv1EncApp`, decode with FFmpeg to 10-bit Y4M (adding `-export_side_data film_grain` for grain synthesis), score
with `vmaf --model version=vmaf_v0.6.1 --model version=vmaf_v0.6.1neg:name=vmaf_neg --feature cambi=full_ref=true` and
FFmpeg's `xpsnr` filter after `setparams` clears the color tags on both inputs, and compute the PCHIP Bjontegaard
delta of log bitrate over the overlapping quality range.
