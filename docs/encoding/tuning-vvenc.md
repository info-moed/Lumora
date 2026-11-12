---
title: VVenC tuning results
parent: Encoding settings
nav_order: 22
---

# VVenC tuning results

What was measured to tune Lumora's VVenC (H.266 / VVC) settings, on which clips, and what changed. The options
themselves are described in the [VVenC reference](vvenc.md) and the [guide](index.md); this page is the evidence
behind the values Lumora now uses in `Lumora/Resources/encoders.json`, `Lumora/Core/Quality/EncodeRecipes.swift` and
`Lumora/Core/Export/ExportEngine.swift`.

## Summary

| Area | Before | Now | Why |
|---|---|---|---|
| HDR10 / HLG / SDR signaling | fixed by the test campaign | unchanged, verified | ffprobe on the exact command lines and on real exports: SDR bt709, HDR10 bt2020 / smpte2084 / bt2020nc with mastering display and content light level SEI, HLG bt2020 / arib-std-b67 |
| Intra period | vvencapp default, 1 s | `--refreshsec 5` | 19-21% smaller (mean of VMAF and XPSNR BD-rate, presets fast and medium) on a 20 s clip with two cuts; 5 s matches SVT-AV1's keyframe spacing |
| QPA on HDR10 (PQ) | on (default) | `--qpa 0` | smaller at equal VMAF and at equal XPSNR on both PQ clips; about 25% less CPU time |
| QPA on low light | on | `--qpa 0` | smaller at equal VMAF and XPSNR; about 20% less CPU time |
| QPA elsewhere | on | on | turning it off cost XPSNR (the metric QPA is built on) by more than the rule allows, although VMAF prefers it off everywhere |
| Preset ladder speeds and savings | published seeds | measured on this Mac | medium is 0.118 of faster's speed (seed 0.18), slow 0.037 (seed 0.07) |
| Default preset | medium | medium | slow costs 3.2x medium's CPU time for about 4% more saving |
| Threads per instance | about 4 per segment | unchanged | up to the resolution default the output is bit-identical; more threads switch on tiles and IFP (3% larger) |
| `MacOptimizer` benchmark values | `{vvenc_sdr}` and `{vvenc_additional}` unfilled | filled | vvencapp received the placeholder text and refused it, so "Measure on this Mac" could never time VVenC |

Everything else that was tried is listed under [Rejected](#rejected).

---

## How it was measured

**Machine and tools.** Apple M3 Max (14-core CPU: 10 performance, 4 efficiency; 36 GB), macOS 27.3. vvencapp 1.14.0,
FFmpeg 9.0.2 (native VVC decoder), libvmaf 3.2.1 (`vmaf` command line). The Mac was shared with other work the whole
time (load average 14-24 on 14 cores); every encode ran at `nice -n 15` with `--threads 4` unless stated, and only one
encoder ran at a time. CPU-time differences under about 10% are noise from that load.

**Clips.** The shared tuning clips (the same ones as the [SVT-AV1 results](tuning-svtav1.md#how-it-was-measured)):
short cuts from Tears of Steel (live action, CC-BY Blender Foundation) and Big Buck Bunny (CG animation), 10-bit 4:2:0
Y4M, kept locally and never committed.

| Clip | Stands in for | Size | Frames |
|---|---|---|---|
| faces, dark, bright sky | live action | 1280x534 (faces also 1920x800) | 96 at 24 fps |
| action | fast motion | 1280x534 | 96 |
| heavy grain (bright sky + added noise) | heavy grain | 1280x534 | 96 |
| low light (darkened, with sensor-like noise) | low light, noisy | 1280x534 | 96 |
| CG (BBB) | 3D animation / CGI | 1280x720 | 180 at 60 fps |
| anime* (BBB held on twos, flattened, posterized, edge lines) | anime (approximation) | 1280x720 | 96 |
| screen (Lumora's source as a scrolling editor page with a video panel) | screen content | 1280x720 | 120 at 30 fps |
| HDR10 sky / HDR10 dark (graded to PQ BT.2020, SDR white at 203 cd/m²) | live action on HDR10 | 1280x534 | 96 |
| 20 s live action, two hard cuts | intra period | 1280x534 | 480 |

*An approximation: real cel animation has cleaner lines and flatter fills than a filtered render. VVenC has no
grain synthesis that players apply (its `--fga` only writes an SEI), so the grainy clips are scored against
themselves.

**Encodes.** `vvencapp -i <clip>.y4m --y4m --preset <p> -q <QP> --threads 4` with `--sdr sdr_709` (or
`--hdr pq_2020` for the PQ clips) and the setting under test. Four QP points per curve: 22, 27, 32, 37 (action 20-32,
screen 22-40), so VMAF spans roughly 85-98 around Lumora's targets (93-96).

**Metrics, scored the way Lumora scores.** Reference and encode are compared as 10-bit 4:2:0 code values: the `vmaf`
tool reads both as Y4M (VMAF v0.6.1, VMAF NEG v0.6.1 and CAMBI with `full_ref=true`, `eotf=bt1886` or `pq`), and
XPSNR runs in FFmpeg with every color tag cleared on both inputs first (`VMAFRunner.untagged` in
`Lumora/Core/Quality/VMAF.swift`), distorted first and reference second as in `MetricSuite`.

**BD-rate.** Bjontegaard delta rate with piecewise-cubic (PCHIP) interpolation of log bitrate over the overlapping
quality range of the two curves: negative means smaller files at equal quality. "CAMBI change" is the mean CAMBI
difference at equal bitrate; positive means more banding.

**Adoption rule** (the same as for SVT-AV1). A candidate is adopted for a content type when the VMAF and XPSNR
BD-rates average a saving of at least 1%, neither is worse by more than 0.5%, and CAMBI does not rise by more than
0.02 at equal bitrate. Correctness fixes cite the reference they follow.

**Search and confirmation.** Per-content candidates were searched at `--preset fast` (a quarter of medium's time)
and the decisive ones confirmed at medium, the default.

---

## Signaling (the campaign's fix)

The test campaign changed `encoders.json` so that SDR gets `--sdr sdr_709`, HDR10 `--hdr pq_2020` plus the static
metadata through `--additional`, and HLG `--hdr hlg_2020 --additional TransferCharacteristics=18`. Checked here with
the exact argument forms Lumora renders (stdin Y4M, 8 frames) and ffprobe:

| Command line | Stream tags (primaries / transfer / matrix / range) | First-frame side data |
|---|---|---|
| `--sdr sdr_709 --hdr off --additional ""` | bt709 / bt709 / bt709 / tv | none |
| `--sdr off --hdr pq_2020 --additional "MasteringDisplayColourVolume=… MaxContentLightLevel=203,100"` | bt2020 / smpte2084 / bt2020nc / tv | mastering display (G, B, R, white point, 1000 / 0.0001 cd/m²), content light level 203 / 100 |
| the same with `:` between the two entries | identical | identical |
| `--sdr off --hdr hlg_2020 --additional TransferCharacteristics=18` | bt2020 / arib-std-b67 / bt2020nc / tv | none |
| `--hdr hlg_2020` without the `--additional` | bt2020 / **bt2020-10** / bt2020nc / tv | none |
| no `--sdr` / `--hdr` (Lumora before the campaign) | unknown / unknown / unknown / tv | none |

So the fix holds: an empty `--additional ""` is accepted, the space-separated metadata pair reaches the stream, and
HLG needs the explicit transfer characteristics (without it only an alternative-transfer SEI names HLG, and ffprobe
reports BT.2020 10-bit). Chroma siting is reported as unspecified in all three. The same checks now run on real
exports through `ExportEngine` (see [end-to-end check](#end-to-end-check)).

One related defect was found and fixed: `MacOptimizer`'s benchmark encode filled only `{vvenc_hdr}`, so vvencapp
received `--sdr {vvenc_sdr}` and `--additional {vvenc_additional}` verbatim and exited, and "Measure on this Mac" could
never time VVenC. The benchmark values now cover every placeholder in `encoders.json` (checked by a unit test for all
encoders). The optimizer itself was not run.

---

## Preset ladder on this Mac

CPU time per frame (what a preset costs in throughput, since Lumora runs several instances side by side) and
BD-rate against `faster`, at `--threads 4`, 720p:

| Preset | CPU s per frame: faces / action / CG / anime* | Speed vs faster (geometric mean) | Shipped seed | Smaller than faster at equal VMAF | at equal XPSNR | Old seed saving | New seed saving |
|---|---|---|---|---|---|---|---|
| faster | 0.100 / 0.237 / 0.079 / 0.206 | 1.00 | 1.0 | 0 | 0 | 0 | 0 |
| fast | 0.251 / 0.551 / 0.202 / 0.559 | 0.40 | 0.45 | 11.6% | 8.8% | 0.06 | 0.102 |
| medium | 0.882 / 1.924 / 0.644 / 1.792 | 0.118 | 0.18 | 21.0% | 12.6% | 0.11 | 0.168 |
| slow | 2.622 / 7.192 / 1.928 / 5.670 | 0.037 | 0.07 | 24.1% | 16.7% | 0.14 | 0.204 |
| slower | 11.456 (faces only) | 0.0085 | 0.03 | 33.2% (faces) | 20.0% (faces) | 0.15 | 0.232 |

Per clip:

| Preset | Clip | VMAF | VMAF NEG | XPSNR | CAMBI change |
|---|---|---|---|---|---|
| fast | faces | -15.39% | -12.97% | -8.77% | +0.001 |
| fast | action | -9.08% | -10.45% | -9.71% | +0.000 |
| fast | CG | -11.92% | -10.48% | -8.06% | +0.000 |
| fast | anime* | -9.98% | -10.32% | -8.57% | +0.000 |
| medium | faces | -27.13% | -24.81% | -14.76% | +0.002 |
| medium | action | -15.46% | -17.85% | -14.84% | +0.000 |
| medium | CG | -19.08% | -17.15% | -8.70% | +0.000 |
| medium | anime* | -22.20% | -22.63% | -12.14% | +0.000 |
| slow | faces | -29.91% | -27.88% | -18.01% | +0.002 |
| slow | action | -18.51% | -20.94% | -18.77% | +0.000 |
| slow | CG | -20.25% | -19.10% | -11.56% | +0.000 |
| slow | anime* | -27.70% | -28.19% | -18.54% | +0.000 |
| slower | faces | -33.15% | -31.18% | -20.04% | +0.003 |

`slower` against `slow` on faces: -4.5% VMAF, -2.6% XPSNR for 4.4x the CPU time. The new seed saving for slower is
slow's mean saving combined with that step.

**Adopted:** the measured speeds and savings (mean of the VMAF and XPSNR BD-rates) as the seeds of the VVC ladder.
The relative steps agree with the project's published performance figures ([vvenc-perf]): fast about 2x slower than
faster (2.5x measured), medium about 3.5x slower than fast (3.4x), slow about 4x slower than medium (3.2x), slower 4-5x
slower than slow (4.4x). The planner now reaches slow sooner within a budget, because its saving over medium is
4 points here instead of the 3 seeded and it costs 3.2x rather than 2.6x. "Measure on this Mac" still replaces the
seeds with the user's own measurements. `baseFps1080` stays 14: faster took 0.14 CPU s per frame at about 0.75 Mpx,
about 0.39 s at 1080p, which is 15-20 fps on eight cores depending on thread efficiency.

**Kept:** medium as the default preset (`encoders.json`). slow saves about 4% more for 3.2x the time; the planner
picks slow and slower when the time budget allows.

---

## QPA per content type

QPA (perceptual QP adaptation, on by default in vvencapp) raises the QP where the XPSNR visual model says errors are
hard to see. VMAF does not reward that, so the decision rests on XPSNR, the metric QPA itself is built on.
`--qpa 0` against the default, searched at `--preset fast`:

| Clip | VMAF | VMAF NEG | XPSNR | Mean | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| faces | -20.90% | -20.37% | -1.13% | -11.01% | +0.017 | -25% |
| dark | -23.20% | -22.87% | +0.91% | -11.15% | +0.000 | -27% |
| bright sky | -19.66% | -19.25% | +5.54% | -7.06% | +0.001 | -23% |
| action | +2.61% | +1.96% | +1.22% | +1.92% | +0.000 | +6% |
| heavy grain | -5.42% | -5.14% | +6.82% | +0.70% | +0.000 | -20% |
| **low light** | -5.12% | -4.98% | **-0.79%** | -2.96% | +0.004 | -20% |
| CG | -7.16% | -6.01% | +7.26% | +0.05% | +0.000 | -26% |
| anime* | -34.88% | -34.16% | +9.27% | -12.81% | +0.000 | -30% |
| screen | -12.72% | -12.82% | +2.05% | -5.34% | -0.138 | 0% |
| **HDR10 sky** | -17.50% | -17.53% | **-1.71%** | -9.60% | +0.008 | -26% |
| **HDR10 dark** | -22.06% | -21.72% | **-3.58%** | -12.82% | +0.000 | -30% |

Confirmed at `--preset medium`:

| Clip | VMAF | VMAF NEG | XPSNR | Mean | CAMBI change | CPU time |
|---|---|---|---|---|---|---|
| faces | -15.80% | -15.86% | +1.07% | -7.36% | +0.015 | -30% |
| anime* | -29.94% | -29.34% | +5.53% | -12.20% | +0.000 | -36% |
| HDR10 sky | -12.93% | -12.89% | +0.43% | -6.25% | +0.007 | -27% |
| HDR10 dark | -17.43% | -16.99% | -3.01% | -10.22% | +0.000 | -34% |
| low light | -4.27% | -3.96% | -0.45% | -2.36% | -0.001 | -24% |

**Adopted:** `--qpa 0` for HDR10 (PQ) exports and for the low-light content type (`EncodeRecipes.vvencQPA`, filled
into `--qpa {vvenc_qpa}` on every VVenC command line, with or without a plan). On both PQ clips and on low light it
was smaller at equal VMAF and at equal XPSNR, and it saves about a quarter of the CPU time. In PQ the QPA model reads
code values that are not perceptually spaced the way its SDR-trained thresholds assume (inference; the reference only
says the `--hdr` modes add a brightness-dependent offset, [vvenc-bitalloc]).

**Kept on:** every other content type. Turning QPA off saves a lot at equal VMAF, but costs XPSNR on most clips
(+0.9% to +9.3%), which the rule does not allow; live action splits (faces gains at fast, loses at medium, dark and
bright sky lose), so it stays on for live action. HLG was not measured and keeps QPA.

---

## Intra period

vvencapp's default intra period is one second (`--refreshsec 1`, rounded to a multiple of 8 frames). On the 20 s
live-action clip with two hard cuts, at `--preset fast`:

| Intra period | VMAF | VMAF NEG | XPSNR | CAMBI change | CPU time |
|---|---|---|---|---|---|
| 2 s vs 1 s | -15.21% | -15.17% | -10.83% | +0.000 | -12% |
| 5 s vs 1 s | -23.68% | -23.40% | -18.51% | +0.000 | -14% |
| 5 s vs 2 s | -10.37% | -10.07% | -9.00% | -0.000 | -2% |
| 5 s vs 1 s, at `--preset medium` | -21.80% | -21.38% | -15.81% | -0.000 | -19% |

**Adopted:** `--refreshsec 5` in the base command line. That is close to SVT-AV1's default keyframe spacing (about
5 s), which Lumora keeps; the SVT-AV1 results found nothing worth taking beyond it ([keyframe
interval](tuning-svtav1.md#look-ahead-keyframe-interval-and-screen-content-mode)). Seeking stays fine at 5 s, Lumora's
segments and target-quality chunks start their own intra pictures, and VVenC's default slice-type adaptation still
codes an intra picture after a scene cut ([vvenc-cfg]). Longer periods were not tried.

---

## Threads, tiles and segments

Lumora runs `cpuCores / 4` VVenC instances for exports over 480 frames (three on this Mac), each with
`cpuCores / instances` threads (four here); shorter exports run one instance with all cores. faces at 1920x800,
`--preset medium`, four QPs:

| Setting | Size vs 4 threads (VMAF / XPSNR BD-rate) | Wall time | CPU time | Cores used (CPU / wall) |
|---|---|---|---|---|
| `--threads 4` | (reference) | (reference) | (reference) | 3.65 |
| `--threads 8` | bit-identical | -20% | +12% | 5.13 |
| `--threads 14` | +3.3% / +2.8% | -49% | +11% | 7.87 |
| `--threads 4 --tiles 2x2` | +2.1% / +1.9% | -10% | -6% | 3.85 |
| `--threads 14 --mtprofile 0` | bit-identical | -16% | +18% | 5.14 |
| `--threads 14 --mtprofile 1` | +2.1% / +1.9% | -39% | +13% | 6.78 |

Up to the resolution default (8 threads at 720p and above) VVenC adds threads without changing a bit; above it,
`--mtprofile` (auto) switches on tiles and inter-frame parallelism, which costs about 3% at equal quality.

**Kept:** the segment split. Three instances of four threads keep the output identical to a single-threaded encode
and use the cores more efficiently than one wide instance (3.65 cores per 4-thread instance against 7.9 for one
14-thread instance), so the parallel throughput of the long-export path is close to the best available.
**Not adopted:** explicit tiles (larger for little speed), and turning the automatic profile off for a single wide
instance (`--mtprofile 0`). That keeps the stream bit-identical but gives up most of the speed: one 14-thread
instance ran 1.95x faster than 4 threads with the automatic profile and only 1.19x with it off. Lumora uses a single
instance only for exports of 480 frames or fewer, where the 3% matters less than finishing in half the time; long
exports already run as 4-thread segments with no size cost.

---

## End-to-end check

`VVenCLibaomTuningTests` runs the real `ExportEngine` on a 2 s 640x360 test pattern with the planner's medium rung and
checks the files with ffprobe and Lumora's own metrics against a ProRes 4444 XQ export of the same job:

| Export | Command line Lumora logged (excerpt) | ffprobe | VMAF / XPSNR / CAMBI |
|---|---|---|---|
| SDR, live action | `--preset medium -q 30 --threads 14 --refreshsec 5 --qpa 1 --sdr sdr_709 --hdr off --additional ""` | bt709 / bt709 / bt709, tv, 10-bit, 48 frames | 96.17 / 40.14 dB / 0.055 |
| HDR10, live action | `… --refreshsec 5 --qpa 0 --sdr off --hdr pq_2020 --additional MasteringDisplayColourVolume=… MaxContentLightLevel=1000,787` | bt2020 / smpte2084 / bt2020nc; mastering display and content light level side data | 89.48 / 37.14 dB / 0.431 |
| HLG, live action | `… --refreshsec 5 --qpa 1 --sdr off --hdr hlg_2020 --additional TransferCharacteristics=18` | bt2020 / arib-std-b67 | 94.26 / 38.74 dB / 0.000 |

(The reference is the same job exported as ProRes 4444 XQ; quality 0.5 maps to QP 30. A single 48-frame segment gets
all 14 cores, as in a short real export.) `CampaignCodecTests`, `PlannerTests`, `EndToEndTests`, `RecommenderTests` and
`SVTAV1TuningTests` pass with the new settings.

---

## Rejected

| Candidate | Content | Result | Reason |
|---|---|---|---|
| `--qpa 0` | live action (faces, dark, bright sky) | VMAF -16% to -23%, XPSNR -1.1% to +5.5% (+1.1% on faces at medium) | XPSNR worse on two of three clips and at medium |
| `--qpa 0` | heavy grain, CG, anime*, screen | XPSNR +0.7% to +9.3% | XPSNR worse |
| `--qpa 0` | fast motion | VMAF +2.6%, XPSNR +1.2% | worse on both |
| `--threads 14` (mtprofile tiles + IFP) | faces 1920x800 | +3% | larger; kept only where Lumora already does it (short single-segment exports) |
| `--tiles 2x2` | faces 1920x800 | +2% | larger for 10% less wall time |
| `--preset slow` as the default | ladder | -4% more than medium for 3.2x the time | left to the planner |

---

## Reproducing

The bench scripts are outside the repository (they read clips that are not committed): `bench.py` encodes, scores and
caches every point, `queue*.sh` hold the sweeps above and `report.py` prints the tables. Clips are cut and graded as
described in the [SVT-AV1 results](tuning-svtav1.md#how-it-was-measured).

[vvenc-perf]: https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance
[vvenc-cfg]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp
[vvenc-bitalloc]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/BitAllocation.cpp
