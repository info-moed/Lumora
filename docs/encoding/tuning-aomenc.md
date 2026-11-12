---
title: libaom tuning results
parent: Encoding settings
nav_order: 23
---

# libaom tuning results

What was measured to tune Lumora's libaom (aomenc) settings, on which clips, and what changed. libaom is the encoder
behind **AV1 Pro** (10 and 12-bit, 4:2:0, 4:2:2 and 4:4:4) and the slowest rungs of the archival **AV1** ladder. The
options themselves are described in the [libaom reference](aomenc.md) and the [guide](index.md); this page is the
evidence behind the values Lumora now uses in `Lumora/Resources/encoders.json`,
`Lumora/Core/Quality/EncodeRecipes.swift` and `Lumora/Core/Export/ExportEngine.swift`.

## Summary

| Area | Before | Now | Why |
|---|---|---|---|
| 12-bit 4:2:2 and 4:4:4 | refused by Lumora | exported | aomenc only fails when `--profile=2` is passed explicitly; Lumora now passes 0 and aomenc raises it to the Professional profile itself |
| Grain synthesis scoring | libaom grain was not recognized | recognized | `--denoise-noise-level` (planner option or grain tune) is now scored against the de-grained master with the synthetic grain stripped, like SVT-AV1's |
| AV1 Pro ladder | published seeds | measured on this Mac | cpu-used 5 is only 3% smaller than 6 (seed 3%, but 0.82 of its speed, not 0.5); cpu-used 4 is 15% smaller (seed 6%) |
| libaom rungs of the AV1 ladder | seeded at 0.020 of preset 10's speed and 1% smaller than preset 4 | 0.033 of preset 10's speed, about as small as preset 1 | measured against SVT-AV1 presets 10 and 4 on the same clips |
| Quantization matrices (`--enable-qm=1`) | recommended for every type, scored at 1.5% saving | off unless the user turns it on | larger at equal XPSNR on every clip (+0.8% to +5.8%) and 4-16% slower |
| `--passes=1` | in the command line twice | once | tidy-up; stdin input needs exactly one pass |
| Film grain synthesis (`--denoise-noise-level`) | recommended for heavy grain, old anime and low light (level 10 or 12/8/4), and in the grain tune | off unless the user turns it on (level 4); grain tune empty | 3-26% larger than coding the grain at every level, against both the de-grained master and the noise-free original, and 15-35% slower |
| `--tune`, `--deltaq-mode`, chroma delta-q, arnr strength | defaults | defaults | every alternative failed the rule on the tuning clips ([rejected](#rejected)) |

---

## How it was measured

**Machine and tools.** Apple M3 Max (14-core CPU: 10 performance, 4 efficiency; 36 GB), macOS 27.3. aomenc 3.15.3,
SVT-AV1 v4.3.0 for the cross-encoder anchors, FFmpeg 9.0.2 with libdav1d for decoding, libvmaf 3.2.1. The Mac was shared
with other work the whole time (load average 14-24 on 14 cores); every encode ran at `nice -n 15` with `--threads=4`
unless stated, and only one encoder ran at a time.

**Clips.** The shared tuning clips described in the [SVT-AV1 results](tuning-svtav1.md#how-it-was-measured) and the
[VVenC results](tuning-vvenc.md#how-it-was-measured): faces, dark, action (Tears of Steel, 1280x534, 96 frames), CG
(Big Buck Bunny, 1280x720, 180 frames at 60 fps), anime* (a filtered approximation of flat-color animation), screen,
HDR10 sky and HDR10 dark (live action graded to PQ BT.2020), and for grain the heavy-grain, low-light and old-anime*
clips with their noise-free originals and Lumora-style de-grained masters. 10-bit 4:2:0 Y4M, never committed.

**Encodes.** `aomenc <clip>.y4m --ivf --passes=1 --cpu-used=<n> --end-usage=q --cq-level=<q> --bit-depth=10
--input-bit-depth=10 --profile=0 --threads=4 --row-mt=1` with BT.709 or PQ CICP flags and the setting under test, as
Lumora renders it from `encoders.json`. Four cq-levels per curve: 20, 28, 36, 44 (screen 16-46), so VMAF spans roughly
88-98. Tool sweeps ran at cpu-used 4, the `encoders.json` default.

**Metrics, BD-rate and adoption rule** are the same as for [SVT-AV1](tuning-svtav1.md#how-it-was-measured): 10-bit
4:2:0 code values with color tags cleared (`VMAFRunner.untagged`), VMAF v0.6.1, VMAF NEG, CAMBI (full reference) and
XPSNR; PCHIP BD-rate; a candidate is adopted when the VMAF and XPSNR BD-rates average a saving of at least 1%, neither
is worse by more than 0.5%, and CAMBI does not rise by more than 0.02.

**Grain is scored the way Lumora scores it**: encodes with `--denoise-noise-level` are decoded with
`-export_side_data film_grain` (libdav1d exports the grain parameters instead of applying them) and compared with the
de-grained master; because the grainy clips were made by adding noise to clean footage, they were also compared with
the noise-free original.

---

## 12-bit 4:2:2 and 4:4:4

Lumora refused 12-bit 4:2:2 and 4:4:4 AV1 Pro exports because aomenc 3.15.3 stopped with `Failed to set chroma
subsampling x: Unspecified internal error`. That only happens when `--profile=2` is passed explicitly, which Lumora did
for every 12-bit job. Every combination, 3 frames, stdin and file input:

| Input | `--profile` omitted | `=0` | `=1` | `=2` |
|---|---|---|---|---|
| 10-bit 4:2:0 | Main | Main | | |
| 10-bit 4:2:2 | Professional (raised) | Professional (raised) | Professional (raised) | Professional |
| 10-bit 4:4:4 | High (raised) | High (raised) | High | High (lowered) |
| 12-bit 4:2:0 | Professional (raised) | Professional (raised) | Professional (raised) | Professional |
| 12-bit 4:2:2 | Professional (raised) | Professional (raised) | Professional (raised) | **fails** |
| 12-bit 4:4:4 | Professional (raised) | Professional (raised) | Professional (raised) | **fails** |

"Raised" and "lowered" mean aomenc printed `Warning: automatically updating to profile N to match input format.` The
12-bit streams decode with libdav1d to `yuv422p12le` / `yuv444p12le` and code as efficiently as 12-bit 4:2:0 and 10-bit
4:4:4 at the same cq-level (8 frames, luma PSNR against the source):

| cq-level | 10-bit 4:4:4 | 12-bit 4:4:4 (profile 0, raised) | 12-bit 4:2:0 |
|---|---|---|---|
| 8 | 256.5 KB, 48.54 dB | 266.0 KB, 48.71 dB | 236.0 KB, 48.71 dB |
| 16 | 96.5 KB, 45.34 dB | 91.4 KB, 45.19 dB | 81.9 KB, 45.18 dB |
| 24 | 65.0 KB, 44.08 dB | 60.0 KB, 43.81 dB | 54.1 KB, 43.80 dB |
| 32 | 41.4 KB, 42.54 dB | 38.2 KB, 42.13 dB | 35.0 KB, 42.12 dB |

(A first check reported the 12-bit 4:4:4 stream 6 dB worse. That was the instrument: FFmpeg's PSNR compared a
BT.709-tagged decode with an untagged source and converted one side's matrix first, the trap `VMAFRunner.untagged`
exists for. With both sides untagged the numbers above agree.)

**Adopted (correctness fix):** `EncodeRecipes.aomProfile` passes `--profile=0` for 12-bit 4:2:2 and 4:4:4 and lets
aomenc raise it, keeps 2 for 12-bit 4:2:0 and 10-bit 4:2:2 and 1 for 10-bit 4:4:4 (no warning for those), and
`Codec.supports` no longer refuses the two combinations. AV1's Professional profile is defined for 12-bit 4:2:0, 4:2:2
and 4:4:4 ([aomenc reference](aomenc.md#profile)). `CampaignCodecTests`' codec matrix now exports and probes them.

---

## Grain synthesis is now scored fairly

`ExportEngine.planGrain` decides whether quality checks strip synthetic grain and compare against a de-grained master.
It recognized SVT-AV1's grain only: the planner option ids `grain` and `aomgrain`, and the `--film-grain` flag in a
content tune. libaom grain reached the encoder two other ways that it missed: the archival AV1 ladder's libaom option
(`aomgrain10`) and the libaom `grain` tune in `encoders.json` (`--denoise-noise-level=…`, used whenever an AV1 Pro
export of a grainy content type runs without a plan). Those exports were scored with the synthetic grain applied,
against the grainy master, which punishes grain synthesis exactly the way the de-grained comparison exists to avoid.
Now any `--film-grain N` or `--denoise-noise-level=N` with N > 0 counts (`EncodeRecipes.synthesizesGrain`).

---

## Speed ladders on this Mac

**AV1 Pro** (cpu-used 6 to 2). CPU time per frame and BD-rate against cpu-used 6, 720p, `--threads=4`:

| cpu-used | CPU s per frame: faces / action / CG / anime* | Speed vs 6 (geometric mean) | Old seed | Smaller than 6 at equal VMAF | at equal XPSNR | Old seed saving | New seed saving |
|---|---|---|---|---|---|---|---|
| 6 | 0.177 / 0.347 / 0.083 / 0.139 | 1.00 | 1.0 | 0 | 0 | 0 | 0 |
| 5 | 0.245 / 0.398 / 0.105 / 0.153 | 0.82 | 0.5 | 3.2% | 2.7% | 0.03 | 0.029 |
| 4 | 0.415 / 0.854 / 0.217 / 0.346 | 0.40 | 0.25 | 19.9% | 10.3% | 0.06 | 0.151 |
| 3 | 0.662 / 1.344 / 0.341 / 0.535 | 0.26 | 0.12 | 22.2% | 12.6% | 0.09 | 0.174 |
| 2 | 1.793 / 3.557 / 0.820 / 1.404 | 0.099 | 0.05 | 26.5% | 16.8% | 0.11 | 0.216 |

Per clip (VMAF / VMAF NEG / XPSNR BD-rate against cpu-used 6):

| cpu-used | faces | action | CG | anime* |
|---|---|---|---|---|
| 5 | -6.4 / -4.9 / -4.3% | -3.7 / -3.3 / -4.3% | -1.2 / -1.5 / -0.9% | -1.4 / -1.5 / -1.4% |
| 4 | -15.8 / -11.2 / -5.6% | -25.8 / -20.6 / -12.0% | -17.0 / -12.6 / -8.5% | -21.1 / -18.5 / -14.9% |
| 3 | -16.6 / -12.6 / -7.4% | -28.7 / -23.8 / -14.8% | -19.6 / -14.8 / -10.3% | -23.8 / -20.8 / -17.7% |
| 2 | -21.4 / -17.0 / -12.5% | -34.4 / -28.9 / -19.3% | -22.1 / -17.6 / -12.9% | -28.0 / -25.2 / -22.3% |

CAMBI moved by less than 0.007 everywhere. The big step is from 5 to 4: libaom's speed features for 5 and 6 cut most of
the search ([aom-speed]), so 5 buys only 3% over 6, while 4 buys 15% for 2.5x the time.

**Adopted:** the measured speeds and savings (mean of VMAF and XPSNR) as the AV1 Pro seeds. The planner previously
believed cpu-used 5 cost half of 6's speed for 3% and 4 a quarter for 6%; now 5 is nearly free and 4 is the obvious
next step. `baseFps1080` stays 8: cpu-used 6 took 0.16 CPU s per frame at about 0.75 Mpx, 0.45 s at 1080p, and a
4-thread libaom instance kept only 2-3 cores busy (see [threads](#threads-per-instance)).

**The libaom rungs of the AV1 archival ladder.** That ladder is ordered on SVT-AV1 preset 10's scale, so libaom was
measured against SVT-AV1 presets 10 and 4 (bare settings, `--lp 3`) on the same four clips:

| Encoder | CPU s per frame (faces / action / CG / anime*) | Speed vs SVT-AV1 preset 10 | vs preset 10 at equal VMAF / XPSNR | vs preset 4 at equal VMAF / XPSNR | Old seed | New seed |
|---|---|---|---|---|---|---|
| SVT-AV1 preset 10 | 0.011 / 0.021 / 0.010 / 0.013 | 1.00 | 0 | | 1.0 / 0 | |
| SVT-AV1 preset 4 | 0.062 / 0.096 / 0.075 / 0.118 | 0.155 | -53.2% / -48.6% | 0 | 0.16 / 0.204 | |
| libaom cpu-used 6 | | 0.081 | -45.7% / -44.3% | +3.9% / +0.8% | (not a rung) | |
| libaom cpu-used 5 | | 0.066 | -46.9% / -45.8% | +0.4% / -2.0% | (not a rung) | |
| libaom cpu-used 4 | | 0.033 | -58.8% / -50.6% | -17.3% / -11.2% | 0.020 / 0.214 | 0.033 / 0.227 |
| libaom cpu-used 3 | | 0.021 | -60.2% / -52.0% | -19.7% / -13.4% | 0.011 / 0.224 | 0.021 / 0.229 |
| libaom cpu-used 2 | | 0.008 | -62.8% / -54.6% | -24.3% / -17.6% | 0.005 / 0.231 | 0.008 / 0.233 |

The SVT-AV1 seed savings on that ladder are deliberately kept at about half of what the SVT-AV1 tuning measured
([SVT-AV1 ladder](tuning-svtav1.md#preset-ladder-on-this-mac)), so the libaom savings were placed on the same seed
scale: each libaom rung's saving against preset 4 was applied to the measured preset 4 figure (47.5% / 42.6% against
preset 10), and the result mapped onto the seeds through SVT-AV1's own measured-to-seed pairs. cpu-used 4 then lands
next to preset 1 (measured 52.9% against 54.1%/50.5%; seeds 0.227 and 0.226) at a slightly higher speed (0.033 against
0.026), which matches the direct comparison above: cpu-used 4 is 14% smaller than preset 4 (mean of VMAF and XPSNR),
preset 1 13%. cpu-used 1 and 0 were not measured; their speeds keep the old step from cpu-used 2 and their savings the
old seeds. `RecommenderTests` now checks that the libaom rungs are slower than SVT-AV1 preset 2 rather than below a
fixed 0.03.

---

## Tunes and per-block tools

All at cpu-used 4 against Lumora's command line without the option (VMAF / VMAF NEG / XPSNR BD-rate, mean of VMAF and
XPSNR, CAMBI change, CPU time):

| Candidate | Clip | VMAF | NEG | XPSNR | Mean | CAMBI | CPU |
|---|---|---|---|---|---|---|---|
| `--tune=ssim` | faces | +17.31% | +18.63% | -10.34% | +3.49% | -0.005 | +1% |
| | dark | +13.07% | +13.45% | -4.60% | +4.23% | +0.000 | -6% |
| | CG | +8.30% | +9.80% | -1.33% | +3.48% | +0.000 | -3% |
| | anime* | +24.13% | +25.78% | -6.00% | +9.06% | -0.000 | -3% |
| | HDR10 sky | +5.32% | +5.49% | -2.79% | +1.26% | +0.001 | -4% |
| `--enable-qm=1` | faces | -1.44% | -1.32% | +2.97% | +0.76% | +0.002 | +7% |
| | dark | -0.39% | -0.39% | +0.82% | +0.21% | +0.000 | +4% |
| | CG | -1.60% | -0.60% | +5.83% | +2.11% | +0.000 | +9% |
| | anime* | +0.23% | +0.73% | +1.65% | +0.94% | +0.000 | +4% |
| | HDR10 sky | +0.07% | -0.17% | +1.73% | +0.90% | +0.004 | +16% |
| `--deltaq-mode=0` | faces | +0.39% | -0.15% | +10.58% | +5.48% | +0.008 | +11% |
| | dark | +2.10% | +1.95% | +7.50% | +4.80% | +0.000 | +21% |
| | CG | -0.76% | +0.19% | +2.65% | +0.94% | +0.000 | +20% |
| | anime* | +0.30% | +0.65% | +18.34% | +9.32% | +0.000 | +17% |
| | HDR10 sky | +2.63% | +3.59% | +9.47% | +6.05% | +0.009 | +2% |
| `--deltaq-mode=6` (variance boost) | faces | +10.82% | +9.05% | +5.65% | +8.23% | +0.004 | +35% |
| | dark | +6.84% | +5.92% | +2.70% | +4.77% | +0.000 | +28% |
| | CG | +2.26% | +2.44% | +1.86% | +2.06% | +0.000 | +22% |
| | anime* | +2.52% | +2.78% | +8.54% | +5.53% | +0.000 | +38% |
| | HDR10 sky | +6.38% | +6.18% | +9.83% | +8.10% | +0.004 | +38% |
| `--deltaq-mode=5` (HDR) | HDR10 sky | +2.78% | +3.84% | +9.96% | +6.37% | +0.013 | +16% |
| | HDR10 dark | +1.33% | +1.61% | +5.14% | +3.24% | +0.000 | +21% |
| `--enable-chroma-deltaq=1` | faces | +0.22% | -0.09% | +0.07% | +0.15% | +0.004 | +18% |
| | CG | +0.25% | -0.11% | -0.22% | +0.02% | +0.000 | +11% |
| | anime* | -0.30% | -0.02% | +0.09% | -0.10% | +0.000 | +3% |
| | HDR10 sky | +0.23% | +0.11% | +0.05% | +0.14% | +0.000 | +10% |
| `--arnr-strength=1` | CG | -0.13% | -1.01% | -0.62% | -0.38% | +0.000 | +7% |
| | anime* | -0.08% | +0.04% | -0.81% | -0.45% | +0.000 | +6% |
| | faces | +3.12% | +1.10% | +3.60% | +3.36% | +0.007 | +17% |
| `--arnr-strength=3` | CG | -1.06% | -0.82% | -0.28% | -0.67% | +0.000 | +21% |
| | anime* | +0.08% | -0.12% | -0.23% | -0.08% | +0.000 | +5% |
| | faces | -0.94% | -1.05% | -0.17% | -0.56% | +0.004 | +15% |
| `--tune=iq` | CG | +54.72% | +56.42% | +19.94% | +37.33% | +0.000 | +13% |
| | anime* | +42.72% | +43.61% | +23.14% | +32.93% | +0.000 | +86% |
| | faces | +102.80% | +107.99% | +22.03% | +62.42% | -0.013 | -16% |
| `--tune-content=screen` (shipped screen tune) | screen | 0.00% | 0.00% | 0.00% | 0.00% | +0.000 | +13% |

Notes:

- **`--tune=ssim`**, Codec Wiki's recommendation, trades VMAF for XPSNR: 5-24% larger at equal VMAF, 1-10% smaller at
  equal XPSNR. The rule needs both, so it stays at the default (psnr). The `vmaf` tunes need a model file path and
  libvmaf at encode time, and optimize the metric used to judge them, so they were not tried; `butteraugli` is not in
  this build.
- **`--deltaq-mode`**: the default (1, the TPL-driven objective mode) beat off (0), variance boost (6) and the HDR mode
  (5) on every clip. Mode 5 on PQ: in 3.15.3 its per-block luma offsets are compiled out, so at exactly 10-bit with
  BT.2020 primaries it only lowers the chroma quantizer through frame-level offsets, and choosing it turns off the
  default mode 1 ([aomenc reference](aomenc.md#deltaq-mode)); the loss of mode 1 outweighs the chroma offsets. At
  12-bit it would not even apply those offsets.
- **Quantization matrices** were offered on every rung of both libaom ladders as a 1.5% saving. Measured, they were
  larger at equal XPSNR on all five clips and only up to 1.6% smaller at equal VMAF, for 4-16% more CPU time. The
  option stays available (`aomqm`, `aomqm10`) but is no longer recommended for any content type, and is priced at its
  measured +7% time.
- **Chroma delta-q** changed nothing measurable (within ±0.3%) for 3-18% more time.
- **`--arnr-strength`** (default 5 in 3.15.3): Codec Wiki's 1 for CG and animation saved 0.4-0.5%, under the 1%
  threshold, and cost faces 3.4%; 3 saved under 0.7% everywhere. Left at the default.
- **`--tune=iq`** is built for still images (its header says so): 33-62% larger on video. Not offered.
- **`--tune-content=screen`**, which Lumora's screen tune passes, produced the same stream as without it on the screen
  clip: libaom's automatic screen-content detection already switched the same tools on. It stays, since it forces the
  tools on every frame of a recording that the detector might miss ([aomenc reference](aomenc.md#tune-content)).

---

## Film grain synthesis

Lumora offered libaom's noise model (`--denoise-noise-level`, which estimates the grain, denoises the frame and
writes AV1 grain parameters) for heavy grain, old anime and low light: level 10 on AV1 Pro, 12 / 8 / 4 on the archival
ladder, and level 10 in the `encoders.json` grain tune used without a plan. Each level against no grain synthesis,
cpu-used 4 (BD-rate; positive means larger):

| Clip | Level | vs de-grained master: VMAF | XPSNR | vs noise-free original: VMAF | XPSNR | CPU time |
|---|---|---|---|---|---|---|
| heavy grain | 4 | +4.14% | +4.98% | +4.48% | +4.85% | +25% |
| | 8 | +3.18% | +7.54% | +3.44% | +5.50% | +15% |
| | 12 | +3.24% | +14.13% | +4.03% | +10.08% | +20% |
| | 16 | +3.58% | +22.13% | +4.98% | +17.37% | +17% |
| low light | 4 | +6.67% | +6.66% | +6.91% | +6.88% | +34% |
| | 8 | +7.65% | +9.23% | +8.65% | +10.88% | +22% |
| | 12 | +12.15% | +16.10% | +13.83% | +19.48% | +22% |
| | 16 | +18.09% | +26.22% | +20.71% | +31.62% | +28% |
| old anime* | 4 | +2.14% | +3.79% | +2.23% | +4.79% | +35% |
| | 8 | +2.80% | +9.45% | +3.06% | +12.26% | +31% |
| | 12 | +3.64% | +21.71% | +4.46% | +26.46% | +33% |
| | 16 | +3.72% | +36.20% | +4.68% | +43.52% | +60% |

CAMBI moved by less than 0.008 in every case. Why: libaom's denoiser removed little, so the bitrate at a given
cq-level hardly fell (heavy grain at cq 20: 1891 kb/s without, 1861 / 1762 / 1715 kb/s at levels 4 / 8 / 12), while the
pictures it codes are a little softer than the source and the synthetic grain is then laid on top of grain that is
still coded. SVT-AV1's denoising grain synthesis, by contrast, cut the bitrate at
a given CRF by about 30% on the heavy-grain clip (2009 kb/s with the grain kept, 1385 kb/s at its level 12, CRF 34;
[SVT-AV1 grain](tuning-svtav1.md#film-grain-one-setting-per-content-type)).

The instrument was checked first: a level-8 encode carries AV1 film grain parameters (ffprobe), and decoding it with
`-export_side_data film_grain` gives a different picture from the normal decode and the same one as libdav1d's
`-filmgrain 0`, 0.4 dB closer to the noise-free original; the noisy source itself is 4.5 dB further away.

**Adopted:** libaom grain synthesis is no longer recommended for any content type on either ladder (`aomgrain`,
`aomgrain10`), the `encoders.json` libaom grain tune is empty, and when a user turns the option on it uses level 4, the
least harmful level measured, priced at +30% time. For grainy films on AV1, SVT-AV1 (the default AV1 encoder) does
the grain synthesis that pays off; AV1 Pro keeps the grain as coded detail. Lumora's own measured grain table
(`aomtable10`) was not part of this test and is unchanged.

---

## Threads per instance

Lumora runs `cpuCores / 4` libaom instances for exports over 480 frames (three on this Mac), each with about four
threads; shorter exports run one instance with all cores. faces at 1920x800, cpu-used 4, cq-levels 28 and 36:

| `--threads` | Wall time (two encodes) | CPU time | Cores kept busy | Output |
|---|---|---|---|---|
| 1 | 197 s | 196 s | 1.00 | 1149 / 619 kb/s |
| 2 | 110 s | 193 s | 1.75 | 1149 / 617 kb/s |
| 4 | 86 s | 203 s | 2.36 | identical to 2 |
| 8 | 83 s | 212 s | 2.55 | identical to 2 |

libaom with row-mt scales poorly past two threads in one instance, as Codec Wiki warns ([aomenc
reference](aomenc.md#threads)). So three 4-thread instances keep only about 7 of 14 cores busy, and seven 2-thread
instances would in principle keep about 12 busy, close to twice the throughput, for one more keyframe per segment.

**Not adopted:** changing the instance count. It was measured one instance at a time (the bench never runs two
encoders at once), so whether seven parallel instances really scale on this Mac (memory bandwidth, efficiency cores)
is unmeasured. "Measure on this Mac" (`MacOptimizer`) already times 1 to N instances per encoder and stores the best
count in `MacProfile.cliInstances`, which overrides the `cpuCores / 4` default; with its VVenC benchmark values
fixed (see the [VVenC results](tuning-vvenc.md#signaling-the-campaigns-fix)), it covers both encoders. The owner has
deferred running it on this Mac, so it was not run.

---

## End-to-end check

`VVenCLibaomTuningTests` runs the real `ExportEngine` on a 2 s 640x360 test pattern and checks the files with ffprobe
and Lumora's own metrics against a ProRes 4444 XQ export of the same job:

| Export | Command line Lumora logged (excerpt) | ffprobe | VMAF / XPSNR / CAMBI |
|---|---|---|---|
| AV1 Pro 12-bit 4:4:4 HDR10, cpu-used 6 | `--cpu-used=6 --end-usage=q --cq-level=27 --bit-depth=12 --input-bit-depth=12 --profile=0 --threads=14 --row-mt=1 --color-primaries=bt2020 --transfer-characteristics=smpte2084 …` | Professional, yuv444p12le, smpte2084, 48 frames | 94.92 / 41.03 dB / 0.278 |
| AV1 Pro 12-bit 4:2:2 SDR, cpu-used 6 | `… --bit-depth=12 --profile=0 …` | Professional, yuv422p12le | 98.19 / 43.19 dB / 0.240 |
| AV1 Pro 10-bit heavy grain SDR, cpu-used 4, planner's recommended extras | `--cpu-used=4 … --bit-depth=10 --profile=0 …` with no `--denoise-noise-level` and no `--enable-qm` | Main, yuv420p10le | 92.44 / 27.06 dB / 0.805 (darkened source with added noise) |

Before this change both 12-bit exports were refused at validation. `CampaignCodecTests` (whose codec matrix now
exports and probes 12-bit 4:2:2 and 4:4:4 AV1 Pro), `PlannerTests`, `EndToEndTests`, `RecommenderTests` and
`SVTAV1TuningTests` pass with the new settings.

---

## Rejected

| Candidate | Content | Result | Reason |
|---|---|---|---|
| `--tune=ssim` | faces, dark, CG, anime*, HDR10 | VMAF +5% to +24%, XPSNR -1% to -10% | VMAF much worse |
| `--enable-qm=1` (recommended before) | faces, dark, CG, anime*, HDR10 | XPSNR +0.8% to +5.8%, VMAF -1.6% to +0.2% | XPSNR worse, slower |
| `--deltaq-mode=0` | same | XPSNR +2.7% to +18% | worse |
| `--deltaq-mode=6` | same | +2% to +11% on both | worse and 22-38% slower |
| `--deltaq-mode=5` | HDR10 sky, HDR10 dark | +1% to +10% on both | worse; replaces the default mode 1 |
| `--enable-chroma-deltaq=1` | faces, CG, anime*, HDR10 | within ±0.3% | no gain, 3-18% slower |
| `--arnr-strength=1` | CG, anime* | -0.4% / -0.5% | under the 1% threshold; faces +3.4% |
| `--arnr-strength=3` | CG, anime*, faces | -0.1% to -0.7% | under the 1% threshold |
| `--tune=iq` | CG, anime*, faces | +33% to +62% | a still-image mode |

---

## Reproducing

The bench scripts are outside the repository (they read clips that are not committed): `bench.py` encodes, scores and
caches every point, `queue*.sh` hold the sweeps above and `report.py` prints the tables.

[aom-speed]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/speed_features.c
