---
title: AV2 vs HEVC, measured
parent: Encoding settings
nav_order: 24
---

# AV2 vs HEVC, measured

How much smaller is AV2 than HEVC today, as Lumora runs both? This page answers that with a measurement, not
the published claims. A second, independent pass recomputed every BD-rate and re-scored seven of the points from
scratch; all of them matched.

## The short answer

| AV2 (AVM, speed 6) compared with | Bits needed at equal quality | Encoding time |
|---|---|---|
| x265, Lumora's tuned settings (preset slow) | **about 20% fewer** (closer to 10% on real footage) | about 800× slower |
| Apple's hardware HEVC encoder | **about 44% fewer** | thousands of times slower |
| SVT-AV1 preset 4, Lumora's tuned settings | about 18% fewer | about 900× slower |

Decoding AV2 (with `avmdec`, the only decoder that reads it today) is about 12× slower than decoding HEVC in
software.

A side result: Apple's hardware HEVC encoder needs about **a third more bits** than tuned x265 for the same
quality (+20% by PSNR, +34% by VMAF, +52% by XPSNR). Lumora's planner text now says so; it used to say 15-25%.

## What was measured

- **Encoders:**
  - **AV2:** AVM research-v15.0.0 with Lumora's `encoders.json` settings (`--cpu-used=6`, constant QP, 10-bit).
  - **x265 4.3:** preset slow with Lumora's per-content options.
  - **Apple hardware HEVC:** VideoToolbox, through FFmpeg's `hevc_videotoolbox`. Lumora's own export uses the same
    hardware encoder through AVAssetWriter.
  - **SVT-AV1 4.3:** preset 4 with Lumora's tuned extras.
- **Clips:** four 16-frame 10-bit clips at 640×360:
  - live action from *Tears of Steel*
  - CG from *Big Buck Bunny*
  - an anime-like flat-shaded clip
  - an HDR10 (PQ) sky clip
- **Rate points:** four per encoder, between about 35 and 47 dB PSNR-Y. Every pair of curves overlaps by at least
  72%, so no BD-rate is extrapolated.
- **Metrics:**
  - PSNR-Y, XPSNR and VMAF 0.6.1 on the decoded 10-bit output.
  - Frames were matched by index, and the HDR clip was scored on PQ code values.
  - A YUV 6:1:1 PSNR check confirmed that AV2 is not saving bits by giving up chroma.
- **BD-rate:** PCHIP on log bitrate. Negative means the first encoder needs fewer bits.

## BD-rate per clip

Live action / CG / anime-like / HDR10, then the mean of all four:

| Pair | PSNR-Y | XPSNR | VMAF |
|---|---|---|---|
| AV2 vs x265 | -32 / -21 / -41 / -30, **-31** | -9 / -9 / -29 / -24, **-18** | -25 / -7 / -29 / -19, **-20** |
| AV2 vs hardware HEVC | -45 / -44 / -43 / -45, **-44** | -46 / -45 / -52 / -46, **-47** | -44 / -33 / -41 / -44, **-40** |
| AV2 vs SVT-AV1 p4 | -28 / -16 / -32 / -18, **-23** | -9 / -11 / -21 / -13, **-14** | -19 / -17 / -28 / -8, **-18** |
| x265 vs hardware HEVC | -19 / -29 / -1 / -20, **-17** | -40 / -40 / -29 / -29, **-34** | -26 / -28 / -18 / -30, **-25** |

PSNR favors AV2 more than the perceptual metrics do, because it penalizes x265's psychovisual tuning. The XPSNR and
VMAF columns are the better guide.

## Speed

| Encoder | CPU-seconds per 640×360 frame |
|---|---|
| AV2 (AVM speed 6, one thread) | 54 (27-128 depending on quality) |
| x265 slow | 0.07 |
| SVT-AV1 preset 4 | 0.06 |
| Apple hardware HEVC | not CPU-bound: about 240 frames per second at 720p |

The Mac was heavily loaded and every encode ran at low priority, so treat the speed ratios as good to about 2×.

## How sure is this?

- **Direction and rough size:** moderate confidence.
- **Exact percentages:** low confidence. The clips are short and small, one clip is synthetic, AVM was measured at
  speed 6 only, and VMAF saturates near 100 on the live-action clip (dropping any one rate point moves that cell
  between -1% and -32%).
- **Per-clip spread:** larger than the measurement noise, so the overall figure depends on the content mix.
- **Real footage:** the gains are at the low end (about 10% over x265 by XPSNR).

AV2's own speed work for Apple silicon is tracked separately; see [AV2 (AVM)](avm.md).
