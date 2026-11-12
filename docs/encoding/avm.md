---
title: AVM (AV2 reference encoder)
parent: Encoding settings
nav_order: 6
---

{% raw %}

# AVM (AV2 reference encoder)

**Documented version:** AVM v1.0.0 (GitHub tag v1.0.0, commit 966a7d7cd6fcf60360caf5dc413b2aeeb65e144d, 2026-05-26), matching the AV2 v1.0.0 specification. Option tables in av2/arg_defs.c and apps/avmenc.c are byte-identical to GitLab tag research-v15.0.0 (commit 917ddae7db6d340b96246cf337b319dbd9cf98a7). Not installed locally; documented from source, not from --help output. · **Codec:** AV2 · **License:** BSD 3-Clause Clear License plus the Alliance for Open Media Patent License 1.0 · **Homepage:** <https://github.com/AOMediaCodec/avm>

avmenc is the command-line encoder of AVM, the AOMedia Video Model that serves as the official reference software for the AV2 video standard. It exposes every AV2 coding tool as an on/off switch and reaches the highest compression of any AOMedia encoder (AOMedia cites roughly 30% savings over AV1), which makes it the right tool for archival experiments and for checking what AV2 can do. It is extremely slow (a reference implementation built for coding efficiency, not speed), has no two-pass mode, no container that ordinary players understand (raw OBU, IVF, or a provisional WebM 'V_AV2' track), cannot write HDR mastering-display or content-light metadata from the command line, and rejects 12-bit input in default builds.

**Bit depths:** 8, 10 · **Chroma:** 4:0:0, 4:2:0, 4:2:2, 4:4:4

Machine-readable data: [`data/avm.json`](data/avm.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

AVM signals HDR only through the CICP fields in the sequence header: set --color-primaries=bt2020, --transfer-characteristics=smpte2084 (HDR10/PQ) or =hlg (HLG), and --matrix-coefficients=bt2020ncl, encode at --bit-depth=10, and set --chroma-sample-position=topleft as the AV2 common test conditions do for HDR. Full-range video is detected only from a Y4M header tag (COLORRANGE=FULL); there is no command-line range switch. avmenc has no flags for SMPTE ST 2086 mastering-display or MaxCLL/MaxFALL content-light metadata. The library defines metadata OBU types for them, but the application never inserts them, so HDR10 static metadata has to be added by a later tool or left out.

**Flags involved:** `--bit-depth`, `--input-bit-depth`, `--color-primaries`, `--transfer-characteristics`, `--matrix-coefficients`, `--chroma-sample-position`, `--icc`, `--enable-banding-metadata`

**Example (HDR10):**

```bash
avmenc --cpu-used=3 --end-usage=q --qp=135 --bit-depth=10 --threads=8 --row-mt=1 --tile-columns=2 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --chroma-sample-position=topleft --obu -o out.obu in_3840x2160_10bit_pq.y4m
```

**Pitfalls:**

- HLG is spelled 'hlg' in AVM's transfer enum. 'arib-std-b67' (the ffmpeg/x265 name) is rejected with a fatal 'Failed to set codec option' error.
- Default builds accept only 8-bit and 10-bit (CONFIG_TESTONLY_12BIT_SUPPORT=0). 12-bit needs a test-only build and produces a non-standard profile.
- There are no mastering-display or content-light-level options, so PQ output carries only CICP. Players fall back to their default tone-mapping assumptions.
- The input bit depth comes from the Y4M header when one is present, and --input-bit-depth applies only to raw YUV. If the source is deeper than --bit-depth, the codec bit depth is raised to match, with a warning on stderr unless --quiet is set.
- Without --obu or --ivf, and with an output name that does not end in .obu or .ivf, avmenc writes WebM with the provisional codec ID 'V_AV2', which most tools do not recognize.
- The --qp scale is the 8-bit qindex scale and is shifted internally for 10-bit (24 per extra bit), so the same --qp gives similar quality at 8 and 10 bit. 10-bit also accepts negative values down to -48.
- Leaving --chroma-sample-position at 'unspecified' is legal, but the CTC assumes co-located (top-left, Type 2) siting for HDR. Older CTC versions spelled this 'colocated', and that name is not in the v1.0.0 enum.

## Presets

| Preset | Speed | Notes |
|---|---|---|
| 0 | slowest; the default (source default cpu_used=0) | Speed 0 is the best-efficiency setting, and all AV2 common-test-condition and verification encodes use it. Expect minutes per frame at 1080p and above on one thread. |
| 1 | very slow | Prunes a little search compared with 0. Speed features are enabled in steps at 1, 2, 3, 4, 5 and 6. |
| 2 | very slow | Above speed 1 with no resize, the dynamic superblock size picks 128x128 instead of 256x256 for content larger than 480 lines, which also changes efficiency. |
| 3 | slow | A reasonable compromise for archival tests on short clips. |
| 4 | slow | Speed features keep stepping in. |
| 5 | moderate for a reference encoder, still far slower than libaom or SVT-AV1 | Lumora's default preset. |
| 6 | fastest effective setting | This is the last level with its own speed features. |
| 7 | same as 6 | The good-quality usage treats 7, 8 and 9 as 6 (avmcx.h). |
| 8 | same as 6 | Treated as 6. |
| 9 | same as 6 | Treated as 6. |

## Rate control

| Mode | Flags | Notes |
|---|---|---|
| Constant QP (Q) | --end-usage=q --qp=<M..255> | Fixed-quality mode used by the AV2 common test conditions (--qp gives the qindex directly). Add --use-fixed-qp-offsets=1 --deltaq-mode=0 --enable-tpl-model=0 for strictly fixed per-level QPs, as the CTC does. Left at defaults, the encoder adapts the QP per pyramid level and per block. M is 0, -48 or -96 for 8, 10 or 12 bit. |
| Constrained quality (CQ) | --end-usage=cq --qp=<level> --target-bitrate=<kbps> | Targets the --qp quality level but caps the bitrate at --target-bitrate. The upstream test suites rarely exercise it. |
| VBR (default) | --end-usage=vbr --target-bitrate=<kbps> | One-pass variable bitrate with lookahead (--lag-in-frames). Two-pass is not available: --passes must be 1, and --minsection-pct/--maxsection-pct are ignored. The default target is 256 kbps. |
| CBR | --end-usage=cbr --target-bitrate=<kbps> --buf-sz --buf-initial-sz --buf-optimal-sz --undershoot-pct --overshoot-pct | Buffer-constrained constant bitrate. The buffer flags take effect only here, because VBR uses fixed large internal buffers. Usage is still good quality (there is no real-time usage in v1.0.0), so it is not a fast mode. |
| Lossless | --lossless=1 (or --min-qp=0 --max-qp=0 at 8-bit) | Forces qindex 0. The encoder also switches to lossless when the best and worst allowed q both resolve to 0, and TCQ is disabled automatically. |

## Recipes

### Best-efficiency random access (CTC-style)

**Goal:** archive · **Content:** live action

```bash
--cpu-used=0 --passes=1 --lag-in-frames=19 --auto-alt-ref=1 --min-gf-interval=16 --max-gf-interval=16 --gf-min-pyr-height=4 --gf-max-pyr-height=4 --kf-min-dist=65 --kf-max-dist=65 --use-fixed-qp-offsets=1 --deltaq-mode=0 --enable-tpl-model=0 --end-usage=q --qp=135 --enable-keyframe-filtering=0 --threads=1 --tile-rows=0 --tile-columns=0 --row-mt=0 --obu -o out.obu in.y4m
```

This is the official AV2 random-access test configuration with the verification-test simplifications removed (speed 0, single tile). It shows the codec's full coding gain at an exactly controlled QP. Expect extremely long encode times.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### HDR10 (PQ) 10-bit

**Goal:** HDR · **Content:** HDR

```bash
--cpu-used=3 --end-usage=q --qp=135 --bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --chroma-sample-position=topleft --threads=8 --row-mt=1 --tile-columns=2 --obu -o out.obu in_pq_10bit.y4m
```

This uses the CTC's HDR signaling with a 10-bit pipeline. The speed and tile choices trade some efficiency for a usable runtime. Mastering-display and MaxCLL metadata cannot be added by avmenc.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf), [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/arg_defs.c)

### HLG 10-bit

**Goal:** HDR · **Content:** HDR

```bash
--cpu-used=3 --end-usage=q --qp=135 --bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=hlg --matrix-coefficients=bt2020ncl --chroma-sample-position=topleft --threads=8 --row-mt=1 --tile-columns=2 --obu -o out.obu in_hlg_10bit.y4m
```

This is the HLG variant. The transfer name must be 'hlg', the spelling in AVM's enum. The chroma siting follows the CTC's HDR convention, which the CTC defines for PQ. Applying it to HLG is an assumption.

Sources: [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/arg_defs.c), [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### Screen content / UI capture

**Goal:** streaming/small size · **Content:** screen content

```bash
--cpu-used=3 --end-usage=q --qp=160 --tune-content=screen --enable-intrabc-ext=1 --obu -o out.obu screen.y4m
```

These are the CTC settings for its screen-sharing class. Screen tuning forces palette and intra-block-copy decisions on every frame.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### All-intra / still image

**Goal:** archive · **Content:** still or intra-only

```bash
--cpu-used=0 --passes=1 --end-usage=q --qp=110 --kf-min-dist=0 --kf-max-dist=0 --use-fixed-qp-offsets=1 --deltaq-mode=0 --enable-tpl-model=0 --enable-keyframe-filtering=0 --limit=1 --obu -o out.obu still.y4m
```

This is the CTC all-intra configuration. Use --limit=1 for single images so the encoder uses the reduced still-picture header.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### Low delay

**Goal:** streaming/small size · **Content:** live action

```bash
--cpu-used=3 --passes=1 --lag-in-frames=0 --min-gf-interval=16 --max-gf-interval=16 --gf-min-pyr-height=4 --gf-max-pyr-height=4 --kf-min-dist=9999 --kf-max-dist=9999 --end-usage=q --qp=160 --subgop-config-str=ld --obu -o out.obu in.y4m
```

This adapts the CTC low-delay structure (no lookahead, forward-only references) for conferencing-style or latency-sensitive encodes. The speed is raised from the CTC's 0.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### Parallel closed-GOP chunks

**Goal:** speed · **Content:** any

```bash
chunk A: --limit=65 ...; chunk B: --skip=65 --limit=65 ... (same settings, --enable-fwd-kf=0), then cat A.obu B.obu > full.obu
```

The CTC states that, for its test sequences, two closed-GOP chunks encoded separately and then concatenated give the same bitstream as one encode. This is the safe way to use many cores with a slow reference encoder, and it matches Lumora's segment-and-concatenate approach.

Sources: [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf), [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/VideoEncoder.py)

### Film grain via table

**Goal:** streaming/small size · **Content:** heavy grain

```bash
--cpu-used=3 --end-usage=q --qp=160 --film-grain-table=grain.tbl --obu -o out.obu denoised.y4m
```

Code a denoised source and let the decoder re-synthesize grain from a parametric table. The table must use AVM's 'filmgrn2' text format, not AV1's 'filmgrn1'.

Sources: [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm_dsp/grain_table.c), [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md)

### Faster practical encode

**Goal:** speed · **Content:** live action

```bash
--cpu-used=6 --end-usage=q --qp=150 --threads=8 --row-mt=1 --tile-columns=2 --tile-rows=1 --obu -o out.obu in.y4m
```

Speed 6 is the fastest distinct level (7-9 behave the same). Tiles plus row multithreading give the threads work to do. Still far slower than libaom.

Sources: [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm/avmcx.h), [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)

### Lossless

**Goal:** archive · **Content:** any

```bash
--lossless=1 --cpu-used=3 --obu -o out.obu in.y4m
```

Forces qindex 0 for bit-exact reconstruction. TCQ is disabled automatically.

Sources: [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/av2_cx_iface.c)

## All options

250 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--output`](#output) | file name, or '-' for stdout | not stated (required) | Names the output file. |  | ✓ |
| [`--limit`](#limit) | n frames | not stated (0 = whole input) | Stops after n input frames. |  |  |
| [`--skip`](#skip) | n frames | not stated (0) | Discards the first n input frames before encoding. |  |  |
| [`--step`](#step) | n >= 1 | not stated (1) | Encodes only every n-th frame after the skipped frames. |  |  |
| [`--webm`](#webm) | none | WebM is the default output when WebM IO is enabled (CONFIG_WEBM_IO=1 by default) | Forces WebM output even when the output name ends in .ivf or .obu. |  |  |
| [`--ivf`](#ivf) | none | not stated | Writes an IVF file (simple frame-indexed container, FourCC AV02). |  |  |
| [`--obu`](#obu) | none | not stated | Writes a raw AV2 OBU stream with no container. |  | ✓ |
| [`--yv12`](#yv12) | none | not stated | Declares raw input as YV12 (4:2:0 with V before U). |  |  |
| [`--i420`](#i420) | none | I420 (default) | Declares raw input as planar 4:2:0 YUV. |  |  |
| [`--i422`](#i422) | none | not stated | Declares raw input as planar 4:2:2. |  |  |
| [`--i444`](#i444) | none | not stated | Declares raw input as planar 4:4:4. |  |  |
| [`--width`](#width) | 1..65535 | not stated (taken from Y4M) | Frame width. |  |  |
| [`--height`](#height) | 1..65535 | not stated (taken from Y4M) | Frame height. |  |  |
| [`--forced_max_frame_width`](#forced-max-frame-width) | pixels | not stated (0 = use frame width) | Writes a larger maximum frame width into the sequence header, so that a stream can later switch to bigger frames without a new sequence header. |  |  |
| [`--forced_max_frame_height`](#forced-max-frame-height) | pixels | not stated (0 = use frame height) | The height counterpart of --forced_max_frame_width. |  |  |
| [`--stereo-mode`](#stereo-mode) | mono, left-right, bottom-top, top-bottom, right-left | not stated (mono) | Tags WebM output with a stereoscopic 3D layout. |  |  |
| [`--timebase`](#timebase) | rational num/den | 1/fps in practice (the help footer says 1/1000) | Sets the precision of output timestamps in fractional seconds. |  |  |
| [`--fps`](#fps) | rational rate/scale | not stated (taken from Y4M) | Overrides the stream frame rate. |  |  |
| [`--input-bit-depth`](#input-bit-depth) | 8, 10 (12 only in test builds) | not stated (same as --bit-depth) | Declares the bit depth of raw YUV input. | ✓ | ✓ |
| [`--full-still-picture-hdr`](#full-still-picture-hdr) | none | not stated (off) | Uses the full sequence header instead of the reduced still-picture header for single-image encodes. |  |  |
| [`--crop-win-bottom-offset`](#crop-win-bottom-offset) | 0..65535 | not stated (0) | Bottom offset of the conformance cropping window, used when --enable-cropping-window=1. |  |  |
| [`--crop-win-left-offset`](#crop-win-left-offset) | 0..65535 | not stated (0) | Left offset of the cropping window. |  |  |
| [`--crop-win-right-offset`](#crop-win-right-offset) | 0..65535 | not stated (0) | Right offset of the cropping window. |  |  |
| [`--crop-win-top-offset`](#crop-win-top-offset) | 0..65535 | not stated (0) | Top offset of the cropping window. |  |  |
| [`--enable-cropping-window`](#enable-cropping-window) | 0: false, 1: true | 0 (false) | Signals a conformance cropping window, so the decoder outputs a smaller picture than the coded one (for example 1080 lines from a 1088-line coded frame). |  |  |
| [`--force-video-mode`](#force-video-mode) | 0: false, 1: true | 0 (false) | Uses the video sequence header even when only one frame is encoded, instead of the still-picture form. |  |  |
| [`--input-chroma-subsampling-x`](#input-chroma-subsampling-x) | 0..1 | not stated (0) | Declares horizontal chroma subsampling for the input. |  |  |
| [`--input-chroma-subsampling-y`](#input-chroma-subsampling-y) | 0..1 | not stated (0) | Declares vertical chroma subsampling for the input. |  |  |

### Rate control

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--passes`](#passes) | must be 1 | 1 | Number of encoding passes. |  |  |
| [`--pass`](#pass) | 0/1 | 0 (all passes) | Chooses which pass to run. |  |  |
| [`--fpf`](#fpf) | file name | not stated | Names the first-pass statistics file. |  |  |
| [`--enable-tcq`](#enable-tcq) | 0 off, 1 on for every frame, 2 on for key and altref frames | 1 (library default in encoder_usage_cfg; the help text says 2) | Turns on trellis-coded quantization, which picks quantized values along a state trellis so that the coefficients cost fewer bits. |  |  |
| [`--drop-frame`](#drop-frame) | 0-100 (buffer %) | not stated (0 = never drop) | In buffer-constrained modes, lets the encoder skip frames when the buffer falls below this percentage. |  |  |
| [`--resize-mode`](#resize-mode) | 0 none, 1 fixed, 2 random, 3 dynamic, 4 CTC pattern, 5 bridge-frame test pattern | not stated (0) | Allows coding frames at reduced resolution and scaling them back up after decoding, either at a fixed scale or decided by rate control. |  |  |
| [`--resize-denominator`](#resize-denominator) | 8-16 (scale = 8/denominator) | not stated (8 = no scaling) | Scale factor for non-key frames when --resize-mode=1. |  |  |
| [`--resize-kf-denominator`](#resize-kf-denominator) | 8-16 | not stated (8) | Scale factor for key frames when --resize-mode=1. |  |  |
| [`--end-usage`](#end-usage) | vbr, cbr, cq, q | not stated (vbr) | Selects the rate control mode: one-pass VBR, CBR, constrained quality (quality level with a bitrate cap), or constant QP. |  | ✓ |
| [`--target-bitrate`](#target-bitrate) | kbps | not stated (256) | Target bitrate for VBR and CBR, and the bitrate cap in CQ mode. |  |  |
| [`--min-q`](#min-q) | [0, 63] (DEPRECATED) | not stated | Lowest allowed quantizer on the old 0-63 scale. |  |  |
| [`--max-q`](#max-q) | [0, 63] (DEPRECATED) | not stated | Highest allowed quantizer on the old 0-63 scale, mapped to a qindex with a deprecation warning. |  |  |
| [`--min-qp`](#min-qp) | [M, 255], where M = 0/-48/-96 for 8/10/12 bit | not stated (0) | Lowest (best-quality) qindex that rate control may use. |  |  |
| [`--max-qp`](#max-qp) | [M, 255], where M = 0/-48/-96 for 8/10/12 bit | not stated (255) | Highest (worst-quality) qindex that rate control may use. |  |  |
| [`--undershoot-pct`](#undershoot-pct) | 0-100 (%) | not stated (25) | How far below the target bitrate rate control may fall before correcting. |  |  |
| [`--overshoot-pct`](#overshoot-pct) | 0-100 (%) | not stated (25) | How far above the target bitrate rate control may go before correcting. |  |  |
| [`--buf-sz`](#buf-sz) | ms | not stated (6000) | Decoder buffer size, in milliseconds of data, assumed by CBR rate control. |  |  |
| [`--buf-initial-sz`](#buf-initial-sz) | ms | not stated (4000) | Buffer fullness assumed at the start of playback, for CBR. |  |  |
| [`--buf-optimal-sz`](#buf-optimal-sz) | ms | not stated (5000) | Buffer level that CBR rate control tries to maintain. |  |  |
| [`--minsection-pct`](#minsection-pct) | % of target | not stated (0) | Two-pass VBR floor on per-GOP bitrate. |  |  |
| [`--maxsection-pct`](#maxsection-pct) | % of target | not stated (2000) | Two-pass VBR ceiling on per-GOP bitrate. |  |  |
| [`--enable-trellis-quant`](#enable-trellis-quant) | 0: no trellis, 1: all encoding stages, 2: only last encoding pass, 3: disable trellis in estimate_yrd_for_sb | 3 | Controls rate-distortion optimization of quantized coefficients and when it runs. |  |  |
| [`--frame-boost`](#frame-boost) | 0: off, 1: on | 0 (off) | Periodically gives selected frames extra quality. |  |  |
| [`--gf-cbr-boost`](#gf-cbr-boost) | pct | not stated (0) | Extra bit share for golden frames in CBR mode. |  |  |
| [`--lossless`](#lossless) | 0: false, 1: true | 0 (false) | Encodes mathematically lossless output by forcing quantizer index 0. |  |  |
| [`--max-inter-rate`](#max-inter-rate) | pct | not stated (0 = no cap) | Caps the size of inter frames as a percentage of the average frame budget. |  |  |
| [`--max-intra-rate`](#max-intra-rate) | pct | not stated (0 = no cap) | Caps the size of intra frames as a percentage of the average frame budget. |  |  |
| [`--qp`](#qp) | [M, 255], where M = 0/-48/-96 for 8/10/12 bit | not stated (source default 40) | Quality level for Q and CQ modes, given directly as a qindex. | ✓ | ✓ |
| [`--quant-b-adapt`](#quant-b-adapt) | 0/1 | not stated (0) | Uses an adaptive variant of the quantizer that adjusts rounding per block. |  |  |
| [`--min-cr`](#min-cr) | integer (ratio x 100) | 0 | Asks the encoder to keep each frame's compression ratio above this value divided by 100, as required by level limits. |  |  |
| [`--vbr-corpus-complexity-lap`](#vbr-corpus-complexity-lap) | 0..10000 | 0 | Gives one-pass VBR an assumed average complexity per macroblock, to help it spread bits when it has only lookahead. |  |  |
| [`--cq-level`](#cq-level) | [0, 63] (DEPRECATED) | not stated | Old-scale quality level, mapped to a qindex (for example 63 maps to 255) with a deprecation warning. |  |  |
| [`--use-fixed-qp-offsets`](#use-fixed-qp-offsets) | 0..2 | not stated (0 = adaptive offsets) | Uses fixed QP offsets for each pyramid level, derived from --qp, instead of letting the encoder adapt them. |  |  |
| [`--fixed-qp-offsets`](#fixed-qp-offsets) | comma-separated offsets: keyframe, ALTREF, then internal alt-ref levels (at least 2 values) | not stated (adaptive) | Sets the QP offsets for each pyramid level by hand. |  |  |

### Speed and presets

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--good`](#good) | none | not stated (good quality is already the only usage) | Selects the good-quality usage profile. |  |  |
| [`--usage`](#usage) | usage profile number | not stated (0 = good quality) | Selects the encoder usage profile. |  |  |
| [`--cpu-used`](#cpu-used) | 0..9 | not stated (source default 0) | Main speed/efficiency trade-off. |  | ✓ |
| [`--disable-ml-partition-speed-features`](#disable-ml-partition-speed-features) | 0: false, 1: true | 1 (library default; the v1.0.0 help text says 0) | Turns off the machine-learning models that prune partition searches. |  |  |
| [`--disable-ml-transform-speed-features`](#disable-ml-transform-speed-features) | 0: false, 1: true | 0 (false) | Turns off the machine-learning models that prune transform searches. |  |  |
| [`--erp-pruning-level`](#erp-pruning-level) | 0: off, 1: reuse co-located decision, 2 to 6: increasing aggressiveness | 5 | How aggressively the extended rectangular partition search is pruned. |  |  |
| [`--reduced-reference-set`](#reduced-reference-set) | 0: off, 1: on | 0 (off) | Limits the set of single and compound reference combinations searched and signaled. |  |  |
| [`--reduced-tx-part-set`](#reduced-tx-part-set) | 0: false, 1: true | 0 (false) | Uses a smaller set of transform partition patterns. |  |  |
| [`--reduced-tx-type-set`](#reduced-tx-type-set) | 0..3 | not stated (0) | Restricts which transform types are searched. |  |  |
| [`--use-inter-dct-only`](#use-inter-dct-only) | 0/1 | not stated (0) | Restricts inter blocks to the DCT. |  |  |
| [`--use-intra-dct-only`](#use-intra-dct-only) | 0/1 | not stated (0) | Restricts intra blocks to the DCT. |  |  |
| [`--use-intra-default-tx-only`](#use-intra-default-tx-only) | 0/1 | not stated (0) | Uses only the mode-implied default transform for intra blocks, skipping the transform search. |  |  |
| [`--use-ml-erp-pruning`](#use-ml-erp-pruning) | 0: off, 1: prune rect, 2: prune split, 3: prune rect + split | 2 (prune split) | Uses a machine-learning model to prune extended rectangular partition choices. |  |  |

### GOP and keyframes

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--global-error-resilient`](#global-error-resilient) | 0/1 | not stated (0) | Turns on error-resilient coding for all frames, limiting dependencies on earlier state so that a decoder can recover after packet loss. |  |  |
| [`--lag-in-frames`](#lag-in-frames) | frames | not stated (source default 19) | How many future frames the encoder may buffer for look-ahead decisions such as alt-ref placement, temporal filtering and the pyramid structure. |  |  |
| [`--enable-fwd-kf`](#enable-fwd-kf) | 0/1 | not stated (0) | Enables forward keyframes, which give an open-GOP structure where frames before a keyframe in display order may reference it. |  |  |
| [`--kf-min-dist`](#kf-min-dist) | frames | not stated (0) | Minimum spacing between automatically placed keyframes. |  |  |
| [`--kf-max-dist`](#kf-max-dist) | frames | not stated (9999) | Maximum spacing between keyframes. |  |  |
| [`--disable-kf`](#disable-kf) | none | not stated | Turns off automatic keyframe placement, so only the first frame is a keyframe. |  |  |
| [`--enable-sframe`](#enable-sframe) | 0/1 | not stated (0) | Enables switch frames, which let a decoder switch between streams of different bitrate at that point without a full keyframe. |  |  |
| [`--sframe-dist`](#sframe-dist) | frames | not stated (0) | Interval between switch frames. |  |  |
| [`--sframe-mode`](#sframe-mode) | 0..2 | not stated (source default 1) | Controls how switch frames are inserted relative to the regular frame structure. |  |  |
| [`--sframe-type`](#sframe-type) | 0: Regular S-Frame, 1: RAS frame | 0 (Regular S-Frame) | Chooses a regular switch frame or a random-access switch (RAS) frame. |  |  |
| [`--auto-alt-ref`](#auto-alt-ref) | 0/1 | not stated (1) | Lets the encoder create hidden alternate reference frames (temporally filtered future frames) that later frames predict from. |  |  |
| [`--subgop-config-str`](#subgop-config-str) | built-in name (def, enh, asym, ts, ld) or a custom sub-GOP description string | not stated (encoder's built-in algorithm) | Defines the reference structure and frame order inside each sub-GOP, either by naming a built-in preset or by spelling out a custom structure. |  |  |
| [`--subgop-config-path`](#subgop-config-path) | file path | not stated (encoder's built-in algorithm) | Same as --subgop-config-str, but reads the sub-GOP structure definitions from a file. |  |  |
| [`--dpb-size`](#dpb-size) | 1-16 | 8 | Number of decoded picture buffer slots the stream may use for references. |  |  |
| [`--enable-bru`](#enable-bru) | 0: false, 1: true with regular decoder, 2: true with optimized decoder | 0 (false) | Enables backward reference update, which lets a reference buffer be refreshed using later decoded content. |  |  |
| [`--enable-overlay`](#enable-overlay) | 0: false, 1: true | 0 (false) | Allows coding overlay frames that correct filtered alt-ref frames back toward the source when they are shown. |  |  |
| [`--explicit-ref-frame-map`](#explicit-ref-frame-map) | 0: off, 1: on | 0 (off) | Signals the reference-buffer mapping explicitly instead of letting the decoder derive it. |  |  |
| [`--gf-max-pyr-height`](#gf-max-pyr-height) | 0 to 5 | 5 | Maximum depth of the hierarchical reference pyramid in a golden-frame group. |  |  |
| [`--gf-min-pyr-height`](#gf-min-pyr-height) | 0 to 5 | 0 | Minimum pyramid depth in a golden-frame group. |  |  |
| [`--max-gf-interval`](#max-gf-interval) | frames; 0 = in-built behavior | 0 (in-built behavior) | Longest allowed golden/alt-ref group. |  |  |
| [`--min-gf-interval`](#min-gf-interval) | frames; 0 = in-built behavior | 0 (in-built behavior) | Shortest allowed golden/alt-ref group. |  |  |
| [`--monotonic-output-order`](#monotonic-output-order) | 0: off, 1: on | 0 (off) | Sets a sequence-header flag that requires AV1-style output, where hidden frames are shown through show-existing-frame headers. |  |  |

### Psychovisual and tuning

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--vmaf-model-path`](#vmaf-model-path) | VMAF model file | not stated (source default /usr/local/share/model/vmaf_v0.6.1.json) | Path to the VMAF model used by the VMAF tuning modes. |  |  |
| [`--aq-mode`](#aq-mode) | 0: off, 1: variance, 2: complexity, 3: cyclic refresh | 0 (off) | Adaptive quantization by segment: adjusts the quantizer per region based on variance or complexity, or refreshes regions cyclically for real-time use. |  |  |
| [`--deltaq-mode`](#deltaq-mode) | 0: off, 1: deltaq objective, 2: deltaq perceptual | 1 (deltaq objective) | Varies the quantizer per superblock, guided by the temporal dependency (TPL) model, toward better objective or perceptual quality. |  |  |
| [`--enable-chroma-deltaq`](#enable-chroma-deltaq) | 0: false, 1: true | 0 (false) | Lets the encoder signal separate quantizer offsets for the chroma planes. | ✓ |  |
| [`--enable-ext-seg`](#enable-ext-seg) | 0: false, 1: true | 0 (false) | Allows more segmentation segments than the base count, for finer per-region parameter control. |  |  |
| [`--enable-qm`](#enable-qm) | 0: false, 1: true | 0 (false) | Enables quantization matrices, which quantize high frequencies more coarsely than low ones. |  |  |
| [`--enable-tpl-model`](#enable-tpl-model) | 0: off, 1: backward source based | not stated (source default 1) | Runs a temporal dependency model over the lookahead to find which blocks are referenced most, then spends more bits on them. |  |  |
| [`--qm-max`](#qm-max) | 0..15 | 9 (library default DEFAULT_QM_LAST; the help text says 15) | Flattest quantization matrix level the encoder may use (15 is effectively flat). |  |  |
| [`--qm-min`](#qm-min) | 0..15 | 5 (library default DEFAULT_QM_FIRST; the help text says 8) | Steepest quantization matrix level the encoder may use. |  |  |
| [`--tune-content`](#tune-content) | default, screen | not stated (default) | Tells the encoder the content type. |  | ✓ |
| [`--tune`](#tune) | psnr, ssim, vmaf_with_preprocessing, vmaf_without_preprocessing, vmaf, vmaf_neg | not stated (psnr) | Chooses which distortion metric the RD decisions optimize. |  |  |

### Film grain and noise

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--film-grain-table`](#film-grain-table) | path to an AVM grain table | not stated | Loads film grain synthesis parameters from a text table instead of estimating them. |  | ✓ |
| [`--film-grain-block-size`](#film-grain-block-size) | 0: 16x16, 1: 32x32 | 0 (16x16) | Sets the block size the decoder uses when laying synthesized grain over the picture. |  |  |
| [`--arnr-maxframes`](#arnr-maxframes) | 0..15 | not stated (7) | Number of frames blended by the temporal filter when building alt-ref frames. |  |  |
| [`--arnr-strength`](#arnr-strength) | 0..6 | not stated (5) | Strength of the temporal filter applied to alt-ref frames. |  |  |
| [`--denoise-block-size`](#denoise-block-size) | block size in pixels | 32 | Block size used by the noise estimator and denoiser that feed film grain synthesis. |  |  |
| [`--denoise-noise-level`](#denoise-noise-level) | 0 = don't denoise, up to 50 | not stated (0) | Denoises the source before encoding and estimates film grain parameters from the removed noise. |  |  |
| [`--enable-keyframe-filtering`](#enable-keyframe-filtering) | 0: no filter, 1: filter without overlay, 2: filter with overlay | 2 (filter with overlay) | Applies the temporal denoising filter to key frames, optionally followed by an overlay frame that restores the exact source. |  |  |
| [`--film-grain-test`](#film-grain-test) | 0: none, 1..16: test vectors | 0 (none) | Applies one of 16 built-in film grain parameter sets. |  |  |
| [`--noise-sensitivity`](#noise-sensitivity) | 0..6 (frames to blur) | not stated (0) | Legacy temporal denoiser strength inherited from libvpx and libaom. |  |  |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--profile`](#profile) | bitstream profile number (v1.0.0: 0-2 = 4:2:0 10-bit interop points, 3 = 4:2:2 10-bit, 4 = 4:4:4 10-bit) | not stated (0) | Sets the AV2 bitstream profile. | ✓ |  |
| [`--bit-depth`](#bit-depth) | 8, 10, 12 | not stated (8) | Sets the internal coding bit depth. | ✓ | ✓ |
| [`--monochrome`](#monochrome) | none | not stated (off) | Encodes luma only and drops the chroma planes. |  |  |
| [`--icc`](#icc) | ICC profile file | not stated | Reads an ICC color profile and attaches it to the first frame as an ICC metadata OBU, for content whose color space CICP cannot describe. | ✓ |  |
| [`--enable-banding-metadata`](#enable-banding-metadata) | 0: false, 1: true | 0 (false) | Writes banding hint metadata so that a decoder or display can apply debanding where the encoder detected banding risk. | ✓ |  |
| [`--chroma-sample-position`](#chroma-sample-position) | unspecified, left, center, topleft, top, bottomleft, bottom | not stated (unspecified) | Signals where chroma samples sit relative to luma for 4:2:0 and 4:2:2. | ✓ | ✓ |
| [`--color-primaries`](#color-primaries) | bt709, unspecified, bt601, bt470m, bt470bg, smpte240, film, bt2020, xyz, smpte431, smpte432, ebu3213 | not stated (unspecified) | Writes the CICP color primaries of the content into the sequence header. | ✓ | ✓ |
| [`--matrix-coefficients`](#matrix-coefficients) | identity, bt709, unspecified, fcc73, bt470bg, bt601, smpte240, ycgco, bt2020ncl, bt2020cl, smpte2085, chromncl, chromcl, ictcp, ipt-c2, ycgco-re, ycgco-ro | not stated (unspecified) | Writes the CICP matrix coefficients (YUV conversion) into the sequence header. | ✓ | ✓ |
| [`--transfer-characteristics`](#transfer-characteristics) | unspecified, bt709, bt470m, bt470bg, bt601, smpte240, lin, log100, log100sq10, iec61966, bt1361, srgb, bt2020-10bit, bt2020-12bit, smpte2084, hlg, smpte428 | not stated (unspecified) | Writes the CICP transfer function into the sequence header. | ✓ | ✓ |

### Analysis and motion search

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-adaptive-mvd`](#enable-adaptive-mvd) | 0: false, 1: true | 1 (true) | Enables adaptive motion-vector-difference resolution, which codes MV differences at a precision that adapts to the block. |  |  |
| [`--enable-bawp`](#enable-bawp) | 0: false, 1: true | 1 (true) | Enables block adaptive weighted prediction, which corrects brightness changes between reference and current blocks, as in fades and flicker. |  |  |
| [`--enable-cwp`](#enable-cwp) | 0: false, 1: true | 1 (true) | Enables compound weighted prediction, which mixes two references with signaled, unequal weights. |  |  |
| [`--enable-diff-wtd-comp`](#enable-diff-wtd-comp) | 0: false, 1: true | 1 (true) | Enables difference-weighted compound prediction, which blends two references with a mask derived from their difference. |  |  |
| [`--enable-drl-reorder`](#enable-drl-reorder) | 0: no reorder, 1: reorder with constraints, 2: always reorder | 1 (reorder with constraints) | Controls reordering of the dynamic reference MV candidate list so that likely candidates get cheaper indices. |  |  |
| [`--enable-flex-mvres`](#enable-flex-mvres) | 0: false, 1: true | 1 (true) | Enables flexible motion vector resolution, choosing MV precision per block. |  |  |
| [`--enable-global-motion`](#enable-global-motion) | 0: false, 1: true | 0 (false) | Searches for frame-wide camera motion models such as pan, zoom and rotation, and uses them as prediction. |  |  |
| [`--enable-high-motion`](#enable-high-motion) | 0: false, 1: true | 0 (false) | Uses a much larger motion search window so that very fast motion can be found. |  |  |
| [`--enable-imp-msk-bld`](#enable-imp-msk-bld) | 0: false, 1: true | 1 (true) | Enables implicit masked blending of compound predictions near picture boundaries and out-of-frame references. |  |  |
| [`--enable-interinter-wedge`](#enable-interinter-wedge) | 0: false, 1: true | 1 (true) | Enables wedge-shaped masks that blend two inter predictions along a straight edge. |  |  |
| [`--enable-interintra-comp`](#enable-interintra-comp) | 0: false, 1: true | 1 (true) | Enables blending an inter prediction with an intra prediction in one block. |  |  |
| [`--enable-interintra-wedge`](#enable-interintra-wedge) | 0: false, 1: true | 1 (true) | Allows wedge masks for inter-intra blending. |  |  |
| [`--enable-intrabc`](#enable-intrabc) | 0: false, 1: true | 1 (true) | Enables intra block copy, which predicts a block from an already coded area of the same frame. |  |  |
| [`--enable-intrabc-ext`](#enable-intrabc-ext) | 0: disable, 1: extend search to the local area, 2: only use the local search range | 1 | Controls the search range extension for intra block copy. |  |  |
| [`--enable-joint-mvd`](#enable-joint-mvd) | 0: false, 1: true | 1 (true) | Enables joint coding of the two motion-vector differences in compound prediction. |  |  |
| [`--enable-masked-comp`](#enable-masked-comp) | 0: false, 1: true | 1 (true) | Master switch for masked compound modes (wedge and difference-weighted). |  |  |
| [`--enable-mvd-sign-derive`](#enable-mvd-sign-derive) | 0: false, 1: true | 1 (true) | Derives the sign of some MV differences instead of coding it. |  |  |
| [`--enable-mv-traj`](#enable-mv-traj) | 0: disable, 1: enable MV trajectory tracking | 1 (enable) | Tracks motion trajectories across frames to build better temporal MV candidates. |  |  |
| [`--enable-onesided-comp`](#enable-onesided-comp) | 0: false, 1: true | 1 (true) | Allows compound prediction from two references on the same temporal side, both past or both future. |  |  |
| [`--enable-opfl-refine`](#enable-opfl-refine) | 0: off, 1: switchable per block, 2: all blocks with simple compound average, 3: auto (switchable per frame by the encoder) | 1 (switchable per block) | Enables optical-flow refinement of compound motion vectors at sub-block level, done by both encoder and decoder. |  |  |
| [`--enable-ref-frame-mvs`](#enable-ref-frame-mvs) | 0/1 | 1 (default is 1) | Enables temporal motion vector prediction from the motion stored in reference frames. |  |  |
| [`--enable-refinemv`](#enable-refinemv) | 0: false, 1: true | 1 (true) | Enables decoder-side motion vector refinement, where the decoder improves signaled MVs with a local search. |  |  |
| [`--enable-refmvbank`](#enable-refmvbank) | 0: false, 1: true | not stated (source default 1) | Keeps a bank of recently used motion vectors as extra MV candidates. |  |  |
| [`--enable-six-param-warp-delta`](#enable-six-param-warp-delta) | 0: false, 1: true | 1 (true) | Allows explicitly signaled warp models with all six affine parameters. |  |  |
| [`--enable-skip-mode`](#enable-skip-mode) | 0: false, 1: true | 1 (true) | Enables skip mode, a cheap compound mode with no residual and inferred references. |  |  |
| [`--enable-smooth-interintra`](#enable-smooth-interintra) | 0: false, 1: true | 1 (true) | Enables smooth (gradient) blending for inter-intra prediction. |  |  |
| [`--enable-tip`](#enable-tip) | 0: disable, 1: TIP frame used as reference or direct output, 2: TIP frame only used as reference | 1 | Enables temporal interpolated prediction, which builds an interpolated frame from two references along motion trajectories. |  |  |
| [`--enable-tip-refinemv`](#enable-tip-refinemv) | 0: false, 1: true | 1 (true) | Applies MV refinement and optical flow when building TIP frames. |  |  |
| [`--enable-warp-causal`](#enable-warp-causal) | 0: false, 1: true | 1 (true) | Enables warp prediction that derives its model from neighboring blocks' motion. |  |  |
| [`--enable-warp-delta`](#enable-warp-delta) | 0: false, 1: true | 1 (true) | Allows explicitly signaled warp model adjustments. |  |  |
| [`--enable-warped-motion`](#enable-warped-motion) | 0: false, 1: true | 1 (true) | Master switch for local warped (affine) motion prediction. |  |  |
| [`--enable-warp-extend`](#enable-warp-extend) | 0: false, 1: true | 1 (true) | Lets a block extend a neighbor's warp model. |  |  |
| [`--max-drl-refbvs`](#max-drl-refbvs) | 0 (auto), 2-4 (fixed) | 0 (auto) | Size of the block-vector candidate list for intra block copy. |  |  |
| [`--max-drl-refmvs`](#max-drl-refmvs) | 0 (auto), 2-8 (fixed) | 0 (auto) | Size of the dynamic reference MV candidate list per reference frame. |  |  |
| [`--max-reference-frames`](#max-reference-frames) | 1 to 7 | 7 | Maximum number of reference frames one frame may use. |  |  |
| [`--reduced-ref-frame-mvs-mode`](#reduced-ref-frame-mvs-mode) | 0: all allowed reference combinations, 1: one reference combination | 0 | Limits temporal MV projection to a single reference combination. |  |  |
| [`--static-thresh`](#static-thresh) | threshold | not stated (0) | Threshold under which blocks are treated as static and skipped early. |  |  |

### Partitioning and transforms

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-angle-delta`](#enable-angle-delta) | 0: false, 1: true | 1 (true) | Allows fine angle offsets on directional intra prediction modes. |  |  |
| [`--enable-cctx`](#enable-cctx) | 0: false, 1: true | 1 (true) | Enables a cross-chroma transform that decorrelates the Cb and Cr residuals before coding. |  |  |
| [`--enable-cfl-intra`](#enable-cfl-intra) | 0: false, 1: true | 1 (true) | Enables chroma-from-luma intra prediction, which predicts chroma from the reconstructed luma texture. |  |  |
| [`--enable-chroma-dctonly`](#enable-chroma-dctonly) | 0: false, 1: true | 0 (false) | Restricts chroma to the DCT only, skipping the other transform types. |  |  |
| [`--enable-extended-sdp`](#enable-extended-sdp) | 0: false, 1: true | 1 (true) | Allows separate luma and chroma partition trees (semi-decoupled partitioning) on inter frames too. |  |  |
| [`--enable-ext-partitions`](#enable-ext-partitions) | 0: false, 1: true | 1 (true) | Enables AV2's extended partition shapes beyond quad, binary and the basic rectangles. |  |  |
| [`--enable-flip-idtx`](#enable-flip-idtx) | 0: false, 1: true | 1 (true) | Enables the flipped ADST, identity and 1-D transform types in addition to plain DCT/ADST. |  |  |
| [`--enable-fsc`](#enable-fsc) | 0: false, 1: true | 1 (true) | Enables forward skip coding, a residual mode that codes coefficients without a transform. |  |  |
| [`--enable-ibp`](#enable-ibp) | 0: false, 1: true | 1 (true) | Enables intra bi-prediction, which combines predictions from two directions. |  |  |
| [`--enable-idtx-intra`](#enable-idtx-intra) | 0: disabled, 1: enabled | 1 (enabled) | When forward skip coding is off, still allows the identity transform for intra blocks. |  |  |
| [`--enable-inter-ddt`](#enable-inter-ddt) | 0: false, 1: true | 1 (true) | Enables data-driven (trained) transforms for inter residuals. |  |  |
| [`--enable-inter-ist`](#enable-inter-ist) | 0: false, 1: true | 1 (true) | Enables a secondary transform applied after the primary transform on inter blocks. |  |  |
| [`--enable-intra-dip`](#enable-intra-dip) | 0: false, 1: true | 1 (true) | Enables a data-driven (trained) intra prediction mode. |  |  |
| [`--enable-intra-edge-filter`](#enable-intra-edge-filter) | 0: false, 1: true | 1 (true) | Smooths the reference edge pixels before directional intra prediction. |  |  |
| [`--enable-ist`](#enable-ist) | 0: false, 1: true | 1 (true) | Enables the intra secondary transform. |  |  |
| [`--enable-mhccp`](#enable-mhccp) | 0: false, 1: true | 1 (true) | Enables multi-hypothesis cross-component prediction, an extension of chroma-from-luma. |  |  |
| [`--enable-mrls`](#enable-mrls) | 0: false, 1: true | 1 (true) | Lets intra prediction use reference lines further from the block edge, not only the adjacent row and column. |  |  |
| [`--enable-paeth-intra`](#enable-paeth-intra) | 0: false, 1: true | 1 (true) | Enables the Paeth intra predictor. |  |  |
| [`--enable-palette`](#enable-palette) | 0: false, 1: true | 1 (true) | Enables palette mode, which codes blocks with a few distinct colors as indices into a small palette. |  |  |
| [`--enable-parity-hiding`](#enable-parity-hiding) | 0: false, 1: true | 1 (true) | Hides one coefficient sign or parity bit in the sum of the other coefficients, which saves bits. |  |  |
| [`--enable-rect-partitions`](#enable-rect-partitions) | 0: false, 1: true | 1 (true) | Allows rectangular (non-square) block partitions. |  |  |
| [`--enable-sdp`](#enable-sdp) | 0: false, 1: true | 1 (true) | Allows semi-decoupled luma and chroma partition trees on key frames. |  |  |
| [`--enable-smooth-intra`](#enable-smooth-intra) | 0: false, 1: true | 1 (true) | Enables the smooth intra predictors that interpolate gently across the block. | ✓ |  |
| [`--enable-tx-partition`](#enable-tx-partition) | 0: false, 1: true | 1 (true) | Allows splitting a block's residual into several transform blocks. |  |  |
| [`--enable-uneven-4way-partitions`](#enable-uneven-4way-partitions) | 0: false, 1: true | 1 (true) | Enables 1:2:4:1 and 1:4:2:1 four-way splits. |  |  |
| [`--max-pb-aspect-ratio`](#max-pb-aspect-ratio) | 2, 4, or 8 | 8 | Limits how elongated prediction blocks may be. |  |  |
| [`--max-partition-size`](#max-partition-size) | 4, 8, 16, 32, 64, 128, 256 | not stated (source default 256) | Largest block size the partition search may use. |  |  |
| [`--min-partition-size`](#min-partition-size) | 4, 8, 16, 32, 64, 128 | not stated (source default 4) | Smallest block size the partition search may use. |  |  |
| [`--select-adaptive-ds`](#select-adaptive-ds) | 0: filter 0, 1: filter 1, 2: filter 2, 3: adaptive | 3 (adaptive) | Picks the luma downsampling filter used by chroma-from-luma prediction, or lets the encoder choose adaptively. |  |  |
| [`--sb-size`](#sb-size) | dynamic, 64, 128, 256 | not stated (dynamic) | Superblock size. |  |  |

### In-loop filters

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--ccso-unit-matches-sb`](#ccso-unit-matches-sb) | 0: false, 1: true | 0 (false) | Ties the CCSO filter signaling unit to the superblock size. |  |  |
| [`--disable-loopfilters-across-tiles`](#disable-loopfilters-across-tiles) | 0: false, 1: true | 0 (false) | Stops the in-loop filters at tile edges, which makes tiles fully independent at a small quality cost. |  |  |
| [`--enable-ccso`](#enable-ccso) | 0: false, 1: true | not stated (source default 1) | Enables cross-component sample offset, an in-loop filter that uses luma to correct chroma (and other component) errors. | ✓ |  |
| [`--enable-cdef`](#enable-cdef) | 0: false, 1: true | 1 (true) | Enables the constrained directional enhancement filter, which removes ringing around edges. |  |  |
| [`--enable-cdef-on-skip-txfm`](#enable-cdef-on-skip-txfm) | 0: always off, 1: always on, 2: adaptive per frame | 1 (always on) | Controls whether CDEF also filters blocks that have no coded residual. |  |  |
| [`--enable-deblocking`](#enable-deblocking) | 0: false, 1: true | 1 (true) | Enables the deblocking filter that smooths block edges. |  |  |
| [`--enable-gdf`](#enable-gdf) | 0: false, 1: true | 1 (true) | Enables the guided detail filter, an AV2 in-loop filter that restores detail lost to quantization. |  |  |
| [`--enable-lf-sub-pu`](#enable-lf-sub-pu) | 0: false, 1: true | 1 (true) | Also deblocks edges inside prediction blocks that are split into sub-blocks, for example by optical flow refinement. |  |  |
| [`--enable-pc-wiener`](#enable-pc-wiener) | 0: false, 1: true | 1 (true) | Enables the pixel-classified Wiener mode of loop restoration. |  |  |
| [`--enable-restoration`](#enable-restoration) | 0: false, 1: true | 1 (true) | Enables the loop restoration filter stage (Wiener variants). |  |  |
| [`--enable-wiener-nonsep`](#enable-wiener-nonsep) | 0: false, 1: true | 1 (true) | Enables the non-separable Wiener mode of loop restoration. |  |  |
| [`--gdf-unit-matches-sb`](#gdf-unit-matches-sb) | 0: false, 1: true | 0 (false) | Ties the guided detail filter's signaling unit to the superblock size. |  |  |
| [`--sharpness`](#sharpness) | 0..7 | not stated (0) | Biases the deblocking filter toward preserving sharp edges. |  |  |

### Threading and performance

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--threads`](#threads) | max threads | not stated (0) | Caps the number of worker threads. |  | ✓ |
| [`--coeff-cost-upd-freq`](#coeff-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile | not stated (0 = SB) | How often the encoder refreshes its coefficient bit-cost estimates during the RD search. |  |  |
| [`--frame-parallel`](#frame-parallel) | 0: false, 1: true | 0 (false) | Turns on features that allow frames to be decoded in parallel, by disabling backward entropy adaptation between frames. |  |  |
| [`--mode-cost-upd-freq`](#mode-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile | not stated (0 = SB) | How often mode-cost estimates are refreshed during encoding. |  |  |
| [`--mv-cost-upd-freq`](#mv-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off | not stated (0 = SB) | How often motion-vector cost estimates are refreshed. |  |  |
| [`--row-mt`](#row-mt) | 0: off, 1: on | 1 (on) | Multithreads the encoder across superblock rows inside a tile. |  |  |
| [`--tile-columns`](#tile-columns) | log2 count, 0..6 | not stated (0) | Splits each frame into 2^n tile columns, which can be encoded and decoded in parallel. |  |  |
| [`--tile-rows`](#tile-rows) | log2 count, 0..6 | not stated (0) | Splits each frame into 2^n tile rows. |  |  |
| [`--tile-width`](#tile-width) | comma-separated tile widths | not stated | Gives explicit, possibly uneven, tile column widths instead of an even log2 split. |  |  |
| [`--tile-height`](#tile-height) | comma-separated tile heights | not stated | Gives explicit tile row heights. |  |  |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--debug`](#debug) | none | not stated | Turns on debug mode, which makes the output bitstream deterministic so that repeated runs can be compared byte for byte. |  |  |
| [`--recon`](#recon) | file name | not stated | Writes the encoder's reconstructed (decoded) frames to a raw file so they can be compared with the source without running a decoder. |  |  |
| [`--quiet`](#quiet) | none | not stated | Suppresses the per-frame progress line and the automatic profile or bit-depth upgrade notices. |  |  |
| [`--verbose`](#verbose) | none | not stated | Prints the full encoder configuration (tools, QP, speed, partition sizes) before encoding starts. |  |  |
| [`--psnr`](#psnr) | optional: 0 disable, 1 PSNR at input bit depth, 2 PSNR at stream bit depth | 2 when given without a value; off when absent | Adds PSNR to the status output. |  |  |
| [`--q-hist`](#q-hist) | n buckets | not stated | Prints a histogram of the quantizers chosen across the encode. |  |  |
| [`--rate-hist`](#rate-hist) | n buckets | not stated | Prints a histogram of per-frame bitrates. |  |  |
| [`--disable-warnings`](#disable-warnings) | none | not stated | Hides the warnings that avmenc prints about settings it considers risky. |  |  |
| [`--disable-warning-prompt`](#disable-warning-prompt) | none | not stated | Still prints configuration warnings but does not stop to ask whether to continue. |  | ✓ |
| [`--test-decode`](#test-decode) | off, fatal, warn | not stated (off) | Decodes each frame inside the encoder and compares it with the encoder's reconstruction. |  |  |
| [`--frame-hash`](#frame-hash) | off, raw, filmgrain, both | not stated (off) | Writes decoded-frame hash metadata OBUs so that a decoder can check its output. |  |  |
| [`--use-per-plane-frame-hash`](#use-per-plane-frame-hash) | 0: false, 1: true | 0 (false) | Writes separate hashes for Y, U and V instead of one per frame. |  |  |

### Other

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--help`](#help) | none | not stated | Prints the full option list grouped into Options, Encoder Global, Rate Control, Keyframe Placement and AV2 Specific sections, then exits. |  |  |
| [`--cfg`](#cfg) | config file path | not stated | Reads encoder tool settings from a key = value text file (see Sample.cfg in the repo) before the command-line options are applied. |  |  |
| [`--codec`](#codec) | short codec name; only 'av2' in AVM builds | av2 (last registered encoder) | Selects the encoder interface. |  |  |
| [`--enable-lcr`](#enable-lcr) | 0 off, 1 on | 0 | Emits a layer configuration record OBU describing the stream's layer structure, which matters for multi-layer and multi-stream AV2 streams. |  |  |
| [`--enable-operating-point-sets`](#enable-operating-point-sets) | 0 off, 1 on | 0 | Emits operating point set OBUs, which describe the decodable subsets of a layered stream. |  |  |
| [`--num-operating-point-sets`](#num-operating-point-sets) | 1-16 | 1 | How many operating point sets to write when they are enabled. |  |  |
| [`--enable-atlas`](#enable-atlas) | 0 off, 1 on | 0 | Emits an atlas segment OBU, which describes how several sub-pictures or streams are arranged into one composite picture. |  |  |
| [`--target-seq-level-idx`](#target-seq-level-idx) | 'ABxy': AB = operating point index, xy = level index (e.g. '0', '1021') | not stated (no target) | Asks the encoder to keep each operating point within a given AV2 level, constraining parameters such as bitrate and tile counts. |  |  |
| [`--add-sef-for-output`](#add-sef-for-output) | 0: off, 1: on | 0 (off) | Adds show-existing-frame headers without order hints so that hidden frames are explicitly output. |  |  |
| [`--avg-cdf-type`](#avg-cdf-type) | 0 (frame based), 1 (tile based) | adaptively chosen based on number of tiles | Chooses whether entropy-model averaging is done per frame or per tile. |  |  |
| [`--cdf-update-mode`](#cdf-update-mode) | 0: no CDF update, 1: update on all frames, 2: selectively update | 1 (all frames) | Controls how often the entropy coder adapts its probability tables between frames. |  |  |
| [`--cross-frame-cdf-init-mode`](#cross-frame-cdf-init-mode) | 0: disable, 1: enable cross frame CDF init | 1 (enable) | Lets a frame start its entropy model from an earlier frame's adapted probabilities instead of the defaults. |  |  |
| [`--enable-avg-cdf`](#enable-avg-cdf) | 0: false, 1: true | 1 (true) | Initializes entropy models from an average of frame or tile statistics rather than a single source. |  |  |
| [`--enable-mfh-obu-signaling`](#enable-mfh-obu-signaling) | 0: false, 1: true | 0 (false) | Signals a multi-frame header OBU, which shares header information across several frames. |  |  |
| [`--enable-short-refresh-frame-flags`](#enable-short-refresh-frame-flags) | 0: N = 8, 1: N = 3 | not stated (source default 1) | Signals the reference refresh flags with 3 bits instead of 8 bits. |  |  |
| [`--mtu-size`](#mtu-size) | bytes; 0 = no MTU targeting | 0 (no MTU targeting) | Sizes tile groups to fit a network packet. |  |  |
| [`--num-tile-groups`](#num-tile-groups) | count | 1 | Maximum number of tile groups per frame, which allows a frame to be split across several OBUs. |  |  |
| [`--operating-points-count`](#operating-points-count) | 1-31 | not stated (source default 1) | Number of operating points signaled in the sequence header for layered streams. |  |  |
| [`--scan-type-info`](#scan-type-info) | 0/1 | not stated (0) | Signals a flag saying whether scan-type (progressive or interlaced source) information is present. |  |  |
| [`--set-tier-mask`](#set-tier-mask) | 32-bit mask; bit 0 = Main tier, 1 = High tier | 0 (Main tier) | Chooses Main or High tier for each of up to 32 operating points. |  |  |
| [`--timing-info`](#timing-info) | unspecified, constant, model | not stated (unspecified) | Writes timing information into the bitstream: none, a constant frame rate, or a decoder model. |  |  |
| [`--use-short-metadata`](#use-short-metadata) | 0: GROUP format, 1: SHORT format | 0 (GROUP format) | Chooses between the grouped and the short metadata OBU syntax. |  |  |

## Options in detail

### Input and output

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file name, or '-' for stdout · **Default:** not stated (required)

Names the output file. The extension picks the container when no format flag forces one: .ivf writes IVF, .obu writes a raw OBU stream, and anything else writes WebM in builds with WebM support.

**In Lumora:** Lumora passes '-o {out}' with an .obu file in a temp folder, then concatenates the segment OBU files for AV2.

**Notes:** Encoding fails if no output is given.

<a id="limit"></a>

#### `--limit`

**Type:** int · **Values:** n frames · **Default:** not stated (0 = whole input)

Stops after n input frames.

**Effect:** quality none · speed shorter run · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `GOP length (e.g. 65) together with --skip` | The CTC describes encoding the two closed GOPs of a random-access test in parallel, with --limit for the first and --skip for the second, then concatenating the two OBU files. For its test sequences this gives the same bitstream as a single encode. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** The CTC warns that encoding a still image with a larger --limit makes the encoder use a full sequence header. Use --limit=1 for stills.

<a id="skip"></a>

#### `--skip`

**Type:** int · **Values:** n frames · **Default:** not stated (0)

Discards the first n input frames before encoding.

| For | Value | Why | Source |
|---|---|---|---|
| speed | `start frame of the chunk` | Used with --limit to split one source into independently encoded closed-GOP chunks (CTC section 4.8). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="step"></a>

#### `--step`

**Type:** int · **Values:** n >= 1 · **Default:** not stated (1) · advanced

Encodes only every n-th frame after the skipped frames. This is mainly for quick tests.

**Effect:** quality none · speed faster · size smaller

**Notes:** 0 is rejected.

<a id="webm"></a>

#### `--webm`

**Type:** bool · **Values:** none · **Default:** WebM is the default output when WebM IO is enabled (CONFIG_WEBM_IO=1 by default) · advanced

Forces WebM output even when the output name ends in .ivf or .obu.

**Notes:** The track uses codec ID 'V_AV2'. Treat this as provisional: few demuxers or players recognize it. Fatal error if the build lacks WebM support.

<a id="ivf"></a>

#### `--ivf`

**Type:** bool · **Values:** none · **Default:** not stated

Writes an IVF file (simple frame-indexed container, FourCC AV02).

**Effect:** quality none · speed none · size tiny container overhead

**Notes:** avmdec and analysis tools read IVF.

<a id="obu"></a>

#### `--obu`

**Type:** bool · **Values:** none · **Default:** not stated

Writes a raw AV2 OBU stream with no container.

**Effect:** quality none · speed none · size smallest overhead

| For | Value | Why | Source |
|---|---|---|---|
| archive | `set` | The CTC requires .obu output and computes bitrate from the .obu file size. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Always passed. Lumora writes .obu segments and joins them by byte concatenation, since AV2 has no MP4 or Matroska binding yet.

**Notes:** Concatenating closed-GOP OBU streams is the same method the CTC uses for parallel GOP encodes.

<a id="yv12"></a>

#### `--yv12`

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Declares raw input as YV12 (4:2:0 with V before U).

**Notes:** Raw input only. Y4M headers override it.

<a id="i420"></a>

#### `--i420`

**Type:** bool · **Values:** none · **Default:** I420 (default) · advanced

Declares raw input as planar 4:2:0 YUV.

**Notes:** Raw input only.

<a id="i422"></a>

#### `--i422`

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Declares raw input as planar 4:2:2. The profile is raised to the 4:2:2 profile automatically.

**Effect:** quality none · speed none · size larger than 4:2:0

**Notes:** Raw input only.

<a id="i444"></a>

#### `--i444`

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Declares raw input as planar 4:4:4. The profile is raised to the 4:4:4 profile automatically unless --monochrome is set.

**Effect:** quality none · speed slower · size larger than 4:2:0

**Notes:** Raw input only.

<a id="width"></a>

#### `--width` (also `-w`)

**Type:** int · **Values:** 1..65535 · **Default:** not stated (taken from Y4M)

Frame width. Needed for raw YUV input. Y4M input supplies it.

<a id="height"></a>

#### `--height` (also `-h`)

**Type:** int · **Values:** 1..65535 · **Default:** not stated (taken from Y4M)

Frame height. Needed for raw YUV input.

**Notes:** -h means height, not help. Use --help for help.

<a id="forced-max-frame-width"></a>

#### `--forced_max_frame_width`

**Type:** int · **Values:** pixels · **Default:** not stated (0 = use frame width) · advanced

Writes a larger maximum frame width into the sequence header, so that a stream can later switch to bigger frames without a new sequence header.

**Effect:** quality none · speed none · size negligible

**Notes:** Spelled with underscores, unlike almost every other flag.

<a id="forced-max-frame-height"></a>

#### `--forced_max_frame_height`

**Type:** int · **Values:** pixels · **Default:** not stated (0 = use frame height) · advanced

The height counterpart of --forced_max_frame_width.

**Effect:** quality none · speed none · size negligible

**Notes:** Spelled with underscores.

<a id="stereo-mode"></a>

#### `--stereo-mode`

**Type:** enum · **Values:** mono, left-right, bottom-top, top-bottom, right-left · **Default:** not stated (mono) · advanced

Tags WebM output with a stereoscopic 3D layout. The coded video is not changed.

**Notes:** Only present in builds with WebM IO, and only affects WebM output.

<a id="timebase"></a>

#### `--timebase`

**Type:** string · **Values:** rational num/den · **Default:** 1/fps in practice (the help footer says 1/1000) · advanced

Sets the precision of output timestamps in fractional seconds.

**Notes:** Validation requires den between 1 and 1e9 and num no greater than den. In v1.0.0, avmenc sets the timebase to 1/1000 before parsing, then replaces it with the inverse frame rate (from --fps or the input file) after all options are parsed, so a value given with --timebase appears to be overwritten. This comes from reading apps/avmenc.c and has not been tested.

<a id="fps"></a>

#### `--fps`

**Type:** string · **Values:** rational rate/scale · **Default:** not stated (taken from Y4M)

Overrides the stream frame rate. Rate control and timing info use it.

**Effect:** quality affects rate control in bitrate modes · speed none · size none in Q mode

**Notes:** Must be positive.

<a id="input-bit-depth"></a>

#### `--input-bit-depth`

**Type:** int · **Values:** 8, 10 (12 only in test builds) · **Default:** not stated (same as --bit-depth) · **HDR-relevant**

Declares the bit depth of raw YUV input. With Y4M input, the header's depth wins and this flag is ignored.

**In Lumora:** Passed as --input-bit-depth={bits}. Lumora feeds Y4M, so the Y4M header takes priority and the flag is harmless.

<a id="full-still-picture-hdr"></a>

#### `--full-still-picture-hdr`

**Type:** bool · **Values:** none · **Default:** not stated (off) · advanced

Uses the full sequence header instead of the reduced still-picture header for single-image encodes. 'hdr' here means header, not high dynamic range.

**Effect:** quality none · speed none · size slightly larger

**Notes:** Not an HDR option despite the name.

<a id="crop-win-bottom-offset"></a>

#### `--crop-win-bottom-offset`

**Type:** int · **Values:** 0..65535 · **Default:** not stated (0) · advanced

Bottom offset of the conformance cropping window, used when --enable-cropping-window=1.

<a id="crop-win-left-offset"></a>

#### `--crop-win-left-offset`

**Type:** int · **Values:** 0..65535 · **Default:** not stated (0) · advanced

Left offset of the cropping window.

<a id="crop-win-right-offset"></a>

#### `--crop-win-right-offset`

**Type:** int · **Values:** 0..65535 · **Default:** not stated (0) · advanced

Right offset of the cropping window.

<a id="crop-win-top-offset"></a>

#### `--crop-win-top-offset`

**Type:** int · **Values:** 0..65535 · **Default:** not stated (0) · advanced

Top offset of the cropping window.

<a id="enable-cropping-window"></a>

#### `--enable-cropping-window`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Signals a conformance cropping window, so the decoder outputs a smaller picture than the coded one (for example 1080 lines from a 1088-line coded frame).

**Notes:** Set the four --crop-win-*-offset values with it.

<a id="force-video-mode"></a>

#### `--force-video-mode`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Uses the video sequence header even when only one frame is encoded, instead of the still-picture form.

**Effect:** quality none · speed none · size slightly larger for stills

<a id="input-chroma-subsampling-x"></a>

#### `--input-chroma-subsampling-x`

**Type:** int · **Values:** 0..1 · **Default:** not stated (0) · advanced

Declares horizontal chroma subsampling for the input.

**Notes:** Normally inferred from Y4M or the --i42x flags.

<a id="input-chroma-subsampling-y"></a>

#### `--input-chroma-subsampling-y`

**Type:** int · **Values:** 0..1 · **Default:** not stated (0) · advanced

Declares vertical chroma subsampling for the input.

### Rate control

<a id="passes"></a>

#### `--passes` (also `-p`)

**Type:** int · **Values:** must be 1 · **Default:** 1 · advanced

Number of encoding passes. AVM has dropped two-pass encoding, so any value other than 1 is a fatal error.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1` | The CTC specifies single-pass encoding for all comparisons. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="pass"></a>

#### `--pass`

**Type:** int · **Values:** 0/1 · **Default:** 0 (all passes) · advanced

Chooses which pass to run. With one-pass encoding, 0 and 1 behave the same.

**Notes:** Kept for compatibility with aomenc.

<a id="fpf"></a>

#### `--fpf`

**Type:** path · **Values:** file name · **Default:** not stated · advanced

Names the first-pass statistics file. It is inherited from aomenc and has no practical use while only one pass is allowed.

**Notes:** Vestigial in v1.0.0.

<a id="enable-tcq"></a>

#### `--enable-tcq`

**Type:** int · **Values:** 0 off, 1 on for every frame, 2 on for key and altref frames · **Default:** 1 (library default in encoder_usage_cfg; the help text says 2) · advanced

Turns on trellis-coded quantization, which picks quantized values along a state trellis so that the coefficients cost fewer bits.

**Effect:** quality + (better rate-distortion) · speed slower · size smaller

**Notes:** Sources disagree on the default: the help text says 2, but encoder_usage_cfg in av2_cx_iface.c initializes it to 1. TCQ is forced off when --enable-trellis-quant=0 or in lossless mode.

<a id="drop-frame"></a>

#### `--drop-frame`

**Type:** int · **Values:** 0-100 (buffer %) · **Default:** not stated (0 = never drop) · advanced

In buffer-constrained modes, lets the encoder skip frames when the buffer falls below this percentage.

**Effect:** quality - (dropped frames) · speed none · size smaller

**Notes:** Not useful for file encodes.

<a id="resize-mode"></a>

#### `--resize-mode`

**Type:** int · **Values:** 0 none, 1 fixed, 2 random, 3 dynamic, 4 CTC pattern, 5 bridge-frame test pattern · **Default:** not stated (0) · advanced

Allows coding frames at reduced resolution and scaling them back up after decoding, either at a fixed scale or decided by rate control.

**Effect:** quality - detail, but can help at very low bitrates · speed faster when downscaled · size smaller

**Notes:** Modes 2, 4 and 5 exist for testing. The values come from the RESIZE_MODE enum in encoder.h because the help gives none.

<a id="resize-denominator"></a>

#### `--resize-denominator`

**Type:** int · **Values:** 8-16 (scale = 8/denominator) · **Default:** not stated (8 = no scaling) · advanced

Scale factor for non-key frames when --resize-mode=1.

**Effect:** quality - as it grows · speed faster · size smaller

<a id="resize-kf-denominator"></a>

#### `--resize-kf-denominator`

**Type:** int · **Values:** 8-16 · **Default:** not stated (8) · advanced

Scale factor for key frames when --resize-mode=1.

**Effect:** quality - as it grows · speed faster · size smaller

<a id="end-usage"></a>

#### `--end-usage`

**Type:** enum · **Values:** vbr, cbr, cq, q · **Default:** not stated (vbr)

Selects the rate control mode: one-pass VBR, CBR, constrained quality (quality level with a bitrate cap), or constant QP.

**Effect:** quality mode-dependent · speed none · size mode-dependent

| For | Value | Why | Source |
|---|---|---|---|
| archive | `q` | All CTC configurations use --end-usage=q with an explicit --qp. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Lumora always passes --end-usage=q and steers quality through --qp.

<a id="target-bitrate"></a>

#### `--target-bitrate`

**Type:** int · **Values:** kbps · **Default:** not stated (256)

Target bitrate for VBR and CBR, and the bitrate cap in CQ mode.

**Effect:** quality + with more bits · speed none · size sets size

**Notes:** Ignored in Q mode.

<a id="min-q"></a>

#### `--min-q`

**Type:** int · **Values:** [0, 63] (DEPRECATED) · **Default:** not stated · advanced

Lowest allowed quantizer on the old 0-63 scale. It is mapped to a qindex and prints a deprecation warning.

**Effect:** quality caps best quality · speed none · size floor on size

**Notes:** Use --min-qp instead.

<a id="max-q"></a>

#### `--max-q`

**Type:** int · **Values:** [0, 63] (DEPRECATED) · **Default:** not stated · advanced

Highest allowed quantizer on the old 0-63 scale, mapped to a qindex with a deprecation warning.

**Effect:** quality floor on worst quality · speed none · size cap on savings

**Notes:** Use --max-qp instead.

<a id="min-qp"></a>

#### `--min-qp`

**Type:** int · **Values:** [M, 255], where M = 0/-48/-96 for 8/10/12 bit · **Default:** not stated (0) · advanced

Lowest (best-quality) qindex that rate control may use.

**Effect:** quality caps best quality · speed none · size floor on size

**Notes:** If min-qp and max-qp both resolve to 0, the encoder switches to lossless.

<a id="max-qp"></a>

#### `--max-qp`

**Type:** int · **Values:** [M, 255], where M = 0/-48/-96 for 8/10/12 bit · **Default:** not stated (255) · advanced

Highest (worst-quality) qindex that rate control may use.

**Effect:** quality protects against very bad frames · speed none · size may overshoot targets

**Notes:** Also clamps --qp in Q mode.

<a id="undershoot-pct"></a>

#### `--undershoot-pct`

**Type:** int · **Values:** 0-100 (%) · **Default:** not stated (25) · advanced

How far below the target bitrate rate control may fall before correcting.

**Effect:** quality ± · speed none · size ±

**Notes:** Bitrate modes only.

<a id="overshoot-pct"></a>

#### `--overshoot-pct`

**Type:** int · **Values:** 0-100 (%) · **Default:** not stated (25) · advanced

How far above the target bitrate rate control may go before correcting.

**Effect:** quality ± · speed none · size ±

**Notes:** Bitrate modes only.

<a id="buf-sz"></a>

#### `--buf-sz`

**Type:** int · **Values:** ms · **Default:** not stated (6000) · advanced

Decoder buffer size, in milliseconds of data, assumed by CBR rate control.

**Effect:** quality + when larger · speed none · size steadier with smaller

**Notes:** VBR overrides it internally with 240000 ms.

<a id="buf-initial-sz"></a>

#### `--buf-initial-sz`

**Type:** int · **Values:** ms · **Default:** not stated (4000) · advanced

Buffer fullness assumed at the start of playback, for CBR.

**Effect:** quality ± · speed none · size ±

**Notes:** VBR uses 60000 ms internally.

<a id="buf-optimal-sz"></a>

#### `--buf-optimal-sz`

**Type:** int · **Values:** ms · **Default:** not stated (5000) · advanced

Buffer level that CBR rate control tries to maintain.

**Effect:** quality ± · speed none · size ±

**Notes:** VBR uses 60000 ms internally.

<a id="minsection-pct"></a>

#### `--minsection-pct`

**Type:** int · **Values:** % of target · **Default:** not stated (0) · advanced

Two-pass VBR floor on per-GOP bitrate.

**Notes:** Always ignored, because passes must be 1. avmenc warns that the option is ignored in one-pass mode.

<a id="maxsection-pct"></a>

#### `--maxsection-pct`

**Type:** int · **Values:** % of target · **Default:** not stated (2000) · advanced

Two-pass VBR ceiling on per-GOP bitrate.

**Notes:** Always ignored, for the same reason as --minsection-pct.

<a id="enable-trellis-quant"></a>

#### `--enable-trellis-quant`

**Type:** int · **Values:** 0: no trellis, 1: all encoding stages, 2: only last encoding pass, 3: disable trellis in estimate_yrd_for_sb · **Default:** 3 · advanced

Controls rate-distortion optimization of quantized coefficients and when it runs.

**Effect:** quality + · speed slower with 1 · size smaller

**Notes:** Setting 0 forces --enable-tcq off to avoid an encoder/decoder mismatch.

<a id="frame-boost"></a>

#### `--frame-boost`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 0 (off) · advanced

Periodically gives selected frames extra quality.

**Effect:** quality ± periodic · speed none · size larger

**Notes:** Mainly a real-time rate-control option.

<a id="gf-cbr-boost"></a>

#### `--gf-cbr-boost`

**Type:** int · **Values:** pct · **Default:** not stated (0) · advanced

Extra bit share for golden frames in CBR mode.

**Effect:** quality ± · speed none · size ±

**Notes:** CBR only.

<a id="lossless"></a>

#### `--lossless`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Encodes mathematically lossless output by forcing quantizer index 0.

**Effect:** quality lossless · speed slower · size much larger

**Notes:** Also disables TCQ.

<a id="max-inter-rate"></a>

#### `--max-inter-rate`

**Type:** int · **Values:** pct · **Default:** not stated (0 = no cap) · advanced

Caps the size of inter frames as a percentage of the average frame budget.

**Effect:** quality - on complex frames · speed none · size steadier

**Notes:** Bitrate modes.

<a id="max-intra-rate"></a>

#### `--max-intra-rate`

**Type:** int · **Values:** pct · **Default:** not stated (0 = no cap) · advanced

Caps the size of intra frames as a percentage of the average frame budget.

**Effect:** quality - on keyframes · speed none · size steadier

**Notes:** Bitrate modes.

<a id="qp"></a>

#### `--qp`

**Type:** int · **Values:** [M, 255], where M = 0/-48/-96 for 8/10/12 bit · **Default:** not stated (source default 40) · **HDR-relevant**

Quality level for Q and CQ modes, given directly as a qindex. Lower means higher quality. The value is on the 8-bit scale and shifted internally for higher bit depths.

**Effect:** quality + as it falls · speed slower at low qp · size larger as it falls

| For | Value | Why | Source |
|---|---|---|---|
| archive | `110-135` | The lowest CTC random-access operating points are qindex 110 and 135. All-intra starts at 85 and stills at 60. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| streaming/small size | `185-235` | These are the upper CTC random-access operating points, the low-bitrate end of the tested range. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Passed as --qp={quality}. Lumora interpolates between qualityBest=80 and qualityWorst=200.

**Notes:** In Q mode the value is clamped to [--min-qp, --max-qp]. With default adaptive offsets (no --use-fixed-qp-offsets), frames in the pyramid get different effective QPs around this anchor.

<a id="quant-b-adapt"></a>

#### `--quant-b-adapt`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Uses an adaptive variant of the quantizer that adjusts rounding per block.

**Effect:** quality ± · speed slight · size ±

<a id="min-cr"></a>

#### `--min-cr`

**Type:** int · **Values:** integer (ratio x 100) · **Default:** 0 · advanced

Asks the encoder to keep each frame's compression ratio above this value divided by 100, as required by level limits.

**Effect:** quality - if binding · speed none · size cap

<a id="vbr-corpus-complexity-lap"></a>

#### `--vbr-corpus-complexity-lap`

**Type:** int · **Values:** 0..10000 · **Default:** 0 · advanced

Gives one-pass VBR an assumed average complexity per macroblock, to help it spread bits when it has only lookahead.

**Effect:** quality ± · speed none · size ±

**Notes:** VBR only.

<a id="cq-level"></a>

#### `--cq-level`

**Type:** int · **Values:** [0, 63] (DEPRECATED) · **Default:** not stated · advanced

Old-scale quality level, mapped to a qindex (for example 63 maps to 255) with a deprecation warning.

**Effect:** quality + as it falls · speed none · size larger as it falls

**Notes:** Parsed by avmenc but not printed by --help. Use --qp instead.

<a id="use-fixed-qp-offsets"></a>

#### `--use-fixed-qp-offsets`

**Type:** int · **Values:** 0..2 · **Default:** not stated (0 = adaptive offsets) · advanced

Uses fixed QP offsets for each pyramid level, derived from --qp, instead of letting the encoder adapt them.

**Effect:** quality ± (predictable, not optimal) · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1 (research comparisons only)` | Every CTC configuration sets --use-fixed-qp-offsets=1 so that QP per frame level is reproducible. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Parsed but not listed by --help. The arg_defs help text for this flag talks about comma-separated values, which really belong to --fixed-qp-offsets.

<a id="fixed-qp-offsets"></a>

#### `--fixed-qp-offsets`

**Type:** list · **Values:** comma-separated offsets: keyframe, ALTREF, then internal alt-ref levels (at least 2 values) · **Default:** not stated (adaptive) · advanced

Sets the QP offsets for each pyramid level by hand. Missing trailing values are filled in by halving.

**Effect:** quality ± · speed none · size ±

**Notes:** Parsed but not listed by --help. Implies --use-fixed-qp-offsets=1. The help text says 5 offsets, while the code stores FIXED_QP_OFFSET_COUNT values.

### Speed and presets

<a id="good"></a>

#### `--good`

**Type:** bool · **Values:** none · **Default:** not stated (good quality is already the only usage) · advanced

Selects the good-quality usage profile. It is the only usage AVM v1.0.0 defines, so the flag changes nothing.

**Notes:** After v1.0.0, GitHub main added a separate --rt (realtime deadline) flag. It is not in v1.0.0.

<a id="usage"></a>

#### `--usage` (also `-u`)

**Type:** int · **Values:** usage profile number · **Default:** not stated (0 = good quality) · advanced

Selects the encoder usage profile. v1.0.0 defines only good quality (0).

**Notes:** Validation allows 0..1, but only one usage configuration table exists, so 1 most likely fails at initialization. Untested here.

<a id="cpu-used"></a>

#### `--cpu-used`

**Type:** int · **Values:** 0..9 · **Default:** not stated (source default 0)

Main speed/efficiency trade-off. Higher values prune more of the search. The good-quality usage treats 7-9 like 6.

**Effect:** quality - as it rises · speed + as it rises · size larger as it rises

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | The CTC requires the best-performing setting (--cpu-used=0) for all configurations and comparisons. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| speed | `6` | 6 is the fastest distinct level. 7-9 behave like 6 in good-quality usage. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm/avmcx.h) |

**In Lumora:** Passed as --cpu-used={preset}. Lumora's default preset for AVM is 5.

**Notes:** Even at 6, AVM is a reference encoder and remains very slow. A public test with the simple_encoder example took about 31 s per 320x180 frame at its defaults.

<a id="disable-ml-partition-speed-features"></a>

#### `--disable-ml-partition-speed-features`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (library default; the v1.0.0 help text says 0) · advanced

Turns off the machine-learning models that prune partition searches.

**Effect:** quality + slight when disabled · speed slower when disabled · size slightly smaller when disabled

**Notes:** Sources disagree. The v1.0.0 help says the default is 0, but default_extra_cfg in av2_cx_iface.c sets 1, and GitHub main has since changed the help text to say 1 is the default.

<a id="disable-ml-transform-speed-features"></a>

#### `--disable-ml-transform-speed-features`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Turns off the machine-learning models that prune transform searches.

**Effect:** quality + slight when disabled · speed slower when disabled · size slightly smaller

<a id="erp-pruning-level"></a>

#### `--erp-pruning-level`

**Type:** int · **Values:** 0: off, 1: reuse co-located decision, 2 to 6: increasing aggressiveness · **Default:** 5 · advanced

How aggressively the extended rectangular partition search is pruned.

**Effect:** quality - slight as it rises · speed faster as it rises · size slightly larger

<a id="reduced-reference-set"></a>

#### `--reduced-reference-set`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 0 (off) · advanced

Limits the set of single and compound reference combinations searched and signaled.

**Effect:** quality - · speed faster · size larger

<a id="reduced-tx-part-set"></a>

#### `--reduced-tx-part-set`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Uses a smaller set of transform partition patterns.

**Effect:** quality - slight · speed faster · size slightly larger

<a id="reduced-tx-type-set"></a>

#### `--reduced-tx-type-set`

**Type:** int · **Values:** 0..3 · **Default:** not stated (0) · advanced

Restricts which transform types are searched. Higher values allow fewer types.

**Effect:** quality - as it rises · speed faster · size larger

**Notes:** The help gives no values. The 0..3 range is from the validation check.

<a id="use-inter-dct-only"></a>

#### `--use-inter-dct-only`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Restricts inter blocks to the DCT.

**Effect:** quality - · speed faster · size larger

<a id="use-intra-dct-only"></a>

#### `--use-intra-dct-only`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Restricts intra blocks to the DCT.

**Effect:** quality - · speed faster · size larger

<a id="use-intra-default-tx-only"></a>

#### `--use-intra-default-tx-only`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Uses only the mode-implied default transform for intra blocks, skipping the transform search.

**Effect:** quality - · speed faster · size larger

<a id="use-ml-erp-pruning"></a>

#### `--use-ml-erp-pruning`

**Type:** int · **Values:** 0: off, 1: prune rect, 2: prune split, 3: prune rect + split · **Default:** 2 (prune split) · advanced

Uses a machine-learning model to prune extended rectangular partition choices.

**Effect:** quality - slight with more pruning · speed faster · size slightly larger

**Notes:** The encoder_usage_cfg table lists 0 for this field, but default_extra_cfg, which command-line runs use, has 2.

### GOP and keyframes

<a id="global-error-resilient"></a>

#### `--global-error-resilient`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Turns on error-resilient coding for all frames, limiting dependencies on earlier state so that a decoder can recover after packet loss.

**Effect:** quality - · speed none · size larger

**Notes:** Not useful for file-based encodes.

<a id="lag-in-frames"></a>

#### `--lag-in-frames`

**Type:** int · **Values:** frames · **Default:** not stated (source default 19)

How many future frames the encoder may buffer for look-ahead decisions such as alt-ref placement, temporal filtering and the pyramid structure.

**Effect:** quality + with more lookahead · speed slight cost, more memory · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `19` | The CTC random-access configuration uses --lag-in-frames=19. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** 0 gives a low-delay structure, as in the CTC LD configuration.

<a id="enable-fwd-kf"></a>

#### `--enable-fwd-kf`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Enables forward keyframes, which give an open-GOP structure where frames before a keyframe in display order may reference it.

**Effect:** quality + slight · speed none · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | The CTC scripts default to closed GOPs (enable_open_gop: false in config.yaml, which VideoEncoder.py turns into --enable-fwd-kf=0). Closed GOPs keep chunks independently decodable and safe to concatenate. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/config.yaml) |

**Notes:** Keep it at 0 when encoding segments that will be concatenated.

<a id="kf-min-dist"></a>

#### `--kf-min-dist`

**Type:** int · **Values:** frames · **Default:** not stated (0)

Minimum spacing between automatically placed keyframes.

**Effect:** quality ± · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| archive | `same as --kf-max-dist (e.g. 65)` | The CTC random-access configuration uses fixed 65-frame GOPs (min = max = 65). All-intra uses 0 and 0. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** 65 is a test-harness choice. Longer intervals save bits on real content.

<a id="kf-max-dist"></a>

#### `--kf-max-dist`

**Type:** int · **Values:** frames · **Default:** not stated (9999)

Maximum spacing between keyframes. 0 makes every frame a keyframe (all-intra).

**Effect:** quality ± · speed none · size smaller with longer intervals

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 for all-intra/still; 9999 for low-delay` | These are the CTC all-intra and low-delay settings. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Lumora relies on the default. Every segment starts with a keyframe anyway.

<a id="disable-kf"></a>

#### `--disable-kf`

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Turns off automatic keyframe placement, so only the first frame is a keyframe.

**Effect:** quality ± · speed none · size smaller

**Notes:** Hurts seeking.

<a id="enable-sframe"></a>

#### `--enable-sframe`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Enables switch frames, which let a decoder switch between streams of different bitrate at that point without a full keyframe.

**Effect:** quality - · speed none · size larger

**Notes:** Meant for adaptive-streaming ladders.

<a id="sframe-dist"></a>

#### `--sframe-dist`

**Type:** int · **Values:** frames · **Default:** not stated (0) · advanced

Interval between switch frames.

**Effect:** quality - · speed none · size larger

<a id="sframe-mode"></a>

#### `--sframe-mode`

**Type:** int · **Values:** 0..2 · **Default:** not stated (source default 1) · advanced

Controls how switch frames are inserted relative to the regular frame structure.

**Effect:** quality ± · speed none · size ±

**Notes:** The exact semantics of each mode are not documented in the help.

<a id="sframe-type"></a>

#### `--sframe-type`

**Type:** int · **Values:** 0: Regular S-Frame, 1: RAS frame · **Default:** 0 (Regular S-Frame) · advanced

Chooses a regular switch frame or a random-access switch (RAS) frame.

**Effect:** quality ± · speed none · size ±

**Notes:** After v1.0.0, GitHub main added --sframe-conformance-option. It is not in v1.0.0.

<a id="auto-alt-ref"></a>

#### `--auto-alt-ref`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (1)

Lets the encoder create hidden alternate reference frames (temporally filtered future frames) that later frames predict from.

**Effect:** quality + · speed slower · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1` | The CTC random-access configuration sets --auto-alt-ref=1. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="subgop-config-str"></a>

#### `--subgop-config-str`

**Type:** string · **Values:** built-in name (def, enh, asym, ts, ld) or a custom sub-GOP description string · **Default:** not stated (encoder's built-in algorithm) · advanced

Defines the reference structure and frame order inside each sub-GOP, either by naming a built-in preset or by spelling out a custom structure.

**Effect:** quality ± · speed ± · size ±

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `ld (only for zero-delay use)` | The CTC low-delay configuration uses --subgop-config-str=ld with --lag-in-frames=0. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** The preset names come from subgop_config_str_preset_map in av2_cx_iface.c.

<a id="subgop-config-path"></a>

#### `--subgop-config-path`

**Type:** path · **Values:** file path · **Default:** not stated (encoder's built-in algorithm) · advanced

Same as --subgop-config-str, but reads the sub-GOP structure definitions from a file.

**Effect:** quality ± · speed ± · size ±

<a id="dpb-size"></a>

#### `--dpb-size`

**Type:** int · **Values:** 1-16 · **Default:** 8 · advanced

Number of decoded picture buffer slots the stream may use for references.

**Effect:** quality + with more · speed slower with more · size smaller with more

<a id="enable-bru"></a>

#### `--enable-bru`

**Type:** int · **Values:** 0: false, 1: true with regular decoder, 2: true with optimized decoder · **Default:** 0 (false) · advanced

Enables backward reference update, which lets a reference buffer be refreshed using later decoded content.

**Effect:** quality ± · speed ± · size ±

**Notes:** Experimental option, off by default.

<a id="enable-overlay"></a>

#### `--enable-overlay`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Allows coding overlay frames that correct filtered alt-ref frames back toward the source when they are shown.

**Effect:** quality + fidelity · speed slower · size larger

<a id="explicit-ref-frame-map"></a>

#### `--explicit-ref-frame-map`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 0 (off) · advanced

Signals the reference-buffer mapping explicitly instead of letting the decoder derive it.

**Effect:** quality none · speed none · size slightly larger

<a id="gf-max-pyr-height"></a>

#### `--gf-max-pyr-height`

**Type:** int · **Values:** 0 to 5 · **Default:** 5 · advanced

Maximum depth of the hierarchical reference pyramid in a golden-frame group.

**Effect:** quality + with deeper pyramid · speed slight · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `4` | The CTC random-access and low-delay configurations fix the pyramid at height 4 for a 16-frame sub-GOP. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="gf-min-pyr-height"></a>

#### `--gf-min-pyr-height`

**Type:** int · **Values:** 0 to 5 · **Default:** 0 · advanced

Minimum pyramid depth in a golden-frame group.

**Effect:** quality ± · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| archive | `4` | The CTC sets min and max pyramid height to 4. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="max-gf-interval"></a>

#### `--max-gf-interval`

**Type:** int · **Values:** frames; 0 = in-built behavior · **Default:** 0 (in-built behavior) · advanced

Longest allowed golden/alt-ref group.

**Effect:** quality ± · speed ± · size smaller with longer groups on static content

| For | Value | Why | Source |
|---|---|---|---|
| archive | `16` | The CTC fixes min and max GF interval at 16 (the sub-GOP size). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Must not exceed the lookahead.

<a id="min-gf-interval"></a>

#### `--min-gf-interval`

**Type:** int · **Values:** frames; 0 = in-built behavior · **Default:** 0 (in-built behavior) · advanced

Shortest allowed golden/alt-ref group.

**Effect:** quality ± · speed ± · size ±

| For | Value | Why | Source |
|---|---|---|---|
| archive | `16` | CTC value. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="monotonic-output-order"></a>

#### `--monotonic-output-order`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 0 (off) · advanced

Sets a sequence-header flag that requires AV1-style output, where hidden frames are shown through show-existing-frame headers.

**Effect:** quality none · speed none · size negligible

### Psychovisual and tuning

<a id="vmaf-model-path"></a>

#### `--vmaf-model-path`

**Type:** path · **Values:** VMAF model file · **Default:** not stated (source default /usr/local/share/model/vmaf_v0.6.1.json) · advanced

Path to the VMAF model used by the VMAF tuning modes.

**Effect:** quality metric-driven · speed none · size none

**Notes:** Only exists in builds configured with -DCONFIG_TUNE_VMAF=1, which defaults to 0. The README describes this build option.

<a id="aq-mode"></a>

#### `--aq-mode`

**Type:** int · **Values:** 0: off, 1: variance, 2: complexity, 3: cyclic refresh · **Default:** 0 (off) · advanced

Adaptive quantization by segment: adjusts the quantizer per region based on variance or complexity, or refreshes regions cyclically for real-time use.

**Effect:** quality ± (can help flat areas, can lower PSNR) · speed slight · size ±

**Notes:** --deltaq-mode is the main block-level QP modulation in AVM. aq-mode is an older segment-based method.

<a id="deltaq-mode"></a>

#### `--deltaq-mode`

**Type:** int · **Values:** 0: off, 1: deltaq objective, 2: deltaq perceptual · **Default:** 1 (deltaq objective) · advanced

Varies the quantizer per superblock, guided by the temporal dependency (TPL) model, toward better objective or perceptual quality.

**Effect:** quality + objective with 1; 2 aims at perceptual · speed slight cost · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (only for fixed-QP comparisons)` | Every CTC configuration sets --deltaq-mode=0, together with fixed per-level QPs (--use-fixed-qp-offsets=1), so results are comparable across tests. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Requires --enable-tpl-model. For normal use the default (1) is probably better, but that is an inference, not a measured claim.

<a id="enable-chroma-deltaq"></a>

#### `--enable-chroma-deltaq`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · **HDR-relevant** · advanced

Lets the encoder signal separate quantizer offsets for the chroma planes.

**Effect:** quality ± chroma vs luma balance · speed none · size ±

**Notes:** Can help keep wide-gamut chroma clean, but no upstream guidance was found.

<a id="enable-ext-seg"></a>

#### `--enable-ext-seg`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Allows more segmentation segments than the base count, for finer per-region parameter control.

**Effect:** quality ± · speed none · size ±

<a id="enable-qm"></a>

#### `--enable-qm`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Enables quantization matrices, which quantize high frequencies more coarsely than low ones.

**Effect:** quality ± (perceptual gain possible, PSNR may drop) · speed none · size smaller

**Notes:** Use with --qm-min/--qm-max.

<a id="enable-tpl-model"></a>

#### `--enable-tpl-model`

**Type:** bool · **Values:** 0: off, 1: backward source based · **Default:** not stated (source default 1) · advanced

Runs a temporal dependency model over the lookahead to find which blocks are referenced most, then spends more bits on them. Required for --deltaq-mode.

**Effect:** quality + · speed slower · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (only for fixed-QP research)` | The CTC sets --enable-tpl-model=0 with --use-fixed-qp-offsets=1 and --deltaq-mode=0, so the coded QPs are exactly as specified. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Lumora leaves it at the default (on), which suits non-research encodes.

<a id="qm-max"></a>

#### `--qm-max`

**Type:** int · **Values:** 0..15 · **Default:** 9 (library default DEFAULT_QM_LAST; the help text says 15) · advanced

Flattest quantization matrix level the encoder may use (15 is effectively flat).

**Effect:** quality ± · speed none · size ±

**Notes:** Needs --enable-qm=1. The help text claims a default of 15, but default_extra_cfg in av2_cx_iface.c initializes qm_max to DEFAULT_QM_LAST, which quant_common.h defines as 9.

<a id="qm-min"></a>

#### `--qm-min`

**Type:** int · **Values:** 0..15 · **Default:** 5 (library default DEFAULT_QM_FIRST; the help text says 8) · advanced

Steepest quantization matrix level the encoder may use. Lower values weight high frequencies more strongly.

**Effect:** quality ± · speed none · size smaller with lower

**Notes:** Needs --enable-qm=1. The help text claims a default of 8, but default_extra_cfg in av2_cx_iface.c initializes qm_min to DEFAULT_QM_FIRST, which quant_common.h defines as 5.

<a id="tune-content"></a>

#### `--tune-content`

**Type:** enum · **Values:** default, screen · **Default:** not stated (default)

Tells the encoder the content type. 'screen' turns on screen-content tools such as palette and intra block copy decisions for every frame.

**Effect:** quality + on screen content · speed slower · size much smaller on UI and text

| For | Value | Why | Source |
|---|---|---|---|
| screen content | `screen` | The CTC applies --tune-content=screen to the screen-sharing class (B2). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| CGI | `default (screen optional)` | Gaming and animation (class B1) are encoded with default tuning in mandatory CTC runs. 'screen' is only an optional extra test for them. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Not used. Lumora's encoders.json 'tunes' entries for avm (default, grain, anime, screen) are all empty, so even the screen profile passes nothing.

**Notes:** Without this flag the encoder still runs a per-frame screen-content detector.

<a id="tune"></a>

#### `--tune`

**Type:** enum · **Values:** psnr, ssim, vmaf_with_preprocessing, vmaf_without_preprocessing, vmaf, vmaf_neg · **Default:** not stated (psnr) · advanced

Chooses which distortion metric the RD decisions optimize.

**Effect:** quality metric-dependent · speed slower for vmaf/ssim · size ±

**Notes:** Builds without CONFIG_TUNE_VMAF (the default) accept only psnr and ssim. The vmaf names are listed but fail validation.

### Film grain and noise

<a id="film-grain-table"></a>

#### `--film-grain-table`

**Type:** path · **Values:** path to an AVM grain table · **Default:** not stated

Loads film grain synthesis parameters from a text table instead of estimating them. The decoder adds the described grain back on playback, so the encoder does not spend bits coding real grain.

**Effect:** quality + perceived texture on grainy sources · speed none · size much smaller on grainy content when the source is denoised

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `a measured filmgrn2 table, with a denoised source` | Grain synthesis encodes a compact parametric model and re-synthesizes it at the decoder instead of coding the noise itself. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md) |

**In Lumora:** Not wired correctly for AV2. ExportEngine passes '--fgs-table <path>' for every non-libaom codec, which avmenc rejects with 'Unrecognized option'. The correct form is --film-grain-table=<path>. Lumora's GrainTable also writes the AV1 'filmgrn1' format, but AVM requires the 'filmgrn2' format, whose 'p' line has extra fields.

**Notes:** The table format is defined in avm_dsp/grain_table.c (magic 'filmgrn2'). AV1 tables from libaom or SVT-AV1 will not parse.

<a id="film-grain-block-size"></a>

#### `--film-grain-block-size`

**Type:** int · **Values:** 0: 16x16, 1: 32x32 · **Default:** 0 (16x16) · advanced

Sets the block size the decoder uses when laying synthesized grain over the picture.

**Effect:** quality ± · speed none · size none

**Notes:** This is new in AV2. AV1 synthesis uses fixed 32x32 luma blocks.

<a id="arnr-maxframes"></a>

#### `--arnr-maxframes`

**Type:** int · **Values:** 0..15 · **Default:** not stated (7) · advanced

Number of frames blended by the temporal filter when building alt-ref frames.

**Effect:** quality + denoised references; too high can smear motion · speed slower with more · size smaller

<a id="arnr-strength"></a>

#### `--arnr-strength`

**Type:** int · **Values:** 0..6 · **Default:** not stated (5) · advanced

Strength of the temporal filter applied to alt-ref frames.

**Effect:** quality ± (stronger removes noise and fine detail) · speed none · size smaller when stronger

**Notes:** Lower values keep more grain in the references.

<a id="denoise-block-size"></a>

#### `--denoise-block-size`

**Type:** int · **Values:** block size in pixels · **Default:** 32 · advanced

Block size used by the noise estimator and denoiser that feed film grain synthesis.

**Effect:** quality ± · speed ± · size none

**Notes:** Present when CONFIG_DENOISE=1, which is the default.

<a id="denoise-noise-level"></a>

#### `--denoise-noise-level`

**Type:** int · **Values:** 0 = don't denoise, up to 50 · **Default:** not stated (0)

Denoises the source before encoding and estimates film grain parameters from the removed noise. The decoder then re-adds synthetic grain of that strength.

**Effect:** quality + perceived on grainy content; - fidelity to exact grain · speed slower (denoiser) · size much smaller on grainy sources

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `non-zero; tune per clip` | Denoise-and-synthesize avoids spending bits on random grain. The same model underlies AV1 grain synthesis. | [source](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md) |

**Notes:** Internally the value is divided by 10 before use. No upstream AVM guidance on specific strengths was found, so treat any number as a starting point. Present when CONFIG_DENOISE=1 (default).

<a id="enable-keyframe-filtering"></a>

#### `--enable-keyframe-filtering`

**Type:** int · **Values:** 0: no filter, 1: filter without overlay, 2: filter with overlay · **Default:** 2 (filter with overlay) · advanced

Applies the temporal denoising filter to key frames, optionally followed by an overlay frame that restores the exact source.

**Effect:** quality + on noisy sources · speed slower · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0 (only for CTC-comparable results)` | The CTC disables encoder-only pre-filtering, including key-frame filtering, in every configuration. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** For ordinary encodes the default is likely fine. The CTC value exists for comparability.

<a id="film-grain-test"></a>

#### `--film-grain-test`

**Type:** int · **Values:** 0: none, 1..16: test vectors · **Default:** 0 (none) · advanced

Applies one of 16 built-in film grain parameter sets. It exists for conformance testing.

**Effect:** quality adds fixed synthetic grain · speed none · size none

**Notes:** Not intended for real content.

<a id="noise-sensitivity"></a>

#### `--noise-sensitivity`

**Type:** int · **Values:** 0..6 (frames to blur) · **Default:** not stated (0) · advanced

Legacy temporal denoiser strength inherited from libvpx and libaom. AVM v1.0.0 accepts it but does not use it.

**Notes:** In v1.0.0 the value is range-checked (0..6) and stored in the encoder's extra config, but nothing in av2/encoder reads it, so it has no effect.

### Color and HDR

<a id="profile"></a>

#### `--profile`

**Type:** int · **Values:** bitstream profile number (v1.0.0: 0-2 = 4:2:0 10-bit interop points, 3 = 4:2:2 10-bit, 4 = 4:4:4 10-bit) · **Default:** not stated (0) · **HDR-relevant** · advanced

Sets the AV2 bitstream profile. avmenc raises it automatically when the input is 4:2:2 or 4:4:4, so it rarely needs setting by hand.

**Notes:** The profile values come from the enum in av2/common/enums.h. A comment in avmenc.c calls profile 4 the 4:2:2 profile, which contradicts that enum. All defined profiles are 10-bit maximum.

<a id="bit-depth"></a>

#### `--bit-depth` (also `-b`)

**Type:** enum · **Values:** 8, 10, 12 · **Default:** not stated (8) · **HDR-relevant**

Sets the internal coding bit depth. 10-bit improves gradients and is required for HDR. 12 is listed but rejected unless the build enables the test-only 12-bit profile.

**Effect:** quality + for 10-bit (less banding) · speed slower at higher depth · size about the same at equal --qp

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `10` | The CTC HDR class (BT.2100 PQ) is 10-bit, and 10 is the highest depth any defined AV2 profile supports. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| anime | `10` | The CTC encodes the synthetic gaming and animation class (B1) at 10-bit even when the source is 8-bit. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Passed as --bit-depth={bits} from the job's output depth. A 12-bit job will fail on a standard AVM build.

**Notes:** The help says '8 for version <=1, 10 or 12 for version 2', which is inherited wording. If the input is deeper than this value, avmenc raises it to the input depth with a warning. 12-bit needs CONFIG_TESTONLY_12BIT_SUPPORT=1, which defaults to 0.

<a id="monochrome"></a>

#### `--monochrome`

**Type:** bool · **Values:** none · **Default:** not stated (off) · advanced

Encodes luma only and drops the chroma planes.

**Effect:** quality drops color · speed faster · size smaller

**Notes:** With 4:4:4 input it stops the automatic 4:4:4 profile upgrade.

<a id="icc"></a>

#### `--icc`

**Type:** path · **Values:** ICC profile file · **Default:** not stated · **HDR-relevant** · advanced

Reads an ICC color profile and attaches it to the first frame as an ICC metadata OBU, for content whose color space CICP cannot describe.

**Effect:** quality none · speed none · size adds profile size once

**Notes:** This is the only color-metadata attachment avmenc offers. There is no equivalent for HDR10 mastering or light-level metadata.

<a id="enable-banding-metadata"></a>

#### `--enable-banding-metadata`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · **HDR-relevant** · advanced

Writes banding hint metadata so that a decoder or display can apply debanding where the encoder detected banding risk.

**Effect:** quality + potential on displays that honor it · speed slight · size negligible

**Notes:** Most valuable for smooth gradients in HDR and 8-bit content, but player support is unknown.

<a id="chroma-sample-position"></a>

#### `--chroma-sample-position`

**Type:** enum · **Values:** unspecified, left, center, topleft, top, bottomleft, bottom · **Default:** not stated (unspecified) · **HDR-relevant**

Signals where chroma samples sit relative to luma for 4:2:0 and 4:2:2. It also tells the Y4M reader how to interpret the input.

**Effect:** quality + correct siting avoids chroma shift · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `topleft` | The CTC adds --chroma-sample-position=topleft for HDR sequences, which assume co-located (Type 2) chroma. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| live action | `left` | The CTC states that BT.709 and other non-HDR video uses vertical chroma siting (Type 0, left). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Not passed. Lumora's HDR10 and HLG AVM encodes leave chroma siting unspecified. Adding --chroma-sample-position=topleft for PQ/HLG would match the CTC.

**Notes:** Parsed both as a global and as a stream option. AVM's enum is richer than AV1's (adds center, top, bottomleft, bottom). CTC v7 and earlier used 'colocated', which is not a valid v1.0.0 value.

<a id="color-primaries"></a>

#### `--color-primaries`

**Type:** enum · **Values:** bt709, unspecified, bt601, bt470m, bt470bg, smpte240, film, bt2020, xyz, smpte431, smpte432, ebu3213 · **Default:** not stated (unspecified) · **HDR-relevant**

Writes the CICP color primaries of the content into the sequence header. The pixels are not converted.

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020` | This is the CTC HDR signaling for BT.2100 content. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Passed as --color-primaries={cp_name}: bt2020 for PQ and HLG, bt709 for SDR. Both names are valid AVM enum values.

**Notes:** Use smpte432 for Display P3 content.

<a id="matrix-coefficients"></a>

#### `--matrix-coefficients`

**Type:** enum · **Values:** identity, bt709, unspecified, fcc73, bt470bg, bt601, smpte240, ycgco, bt2020ncl, bt2020cl, smpte2085, chromncl, chromcl, ictcp, ipt-c2, ycgco-re, ycgco-ro · **Default:** not stated (unspecified) · **HDR-relevant**

Writes the CICP matrix coefficients (YUV conversion) into the sequence header.

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020ncl` | This is the CTC HDR signaling. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Passed as --matrix-coefficients={mc_name}: bt2020ncl for PQ and HLG, bt709 for SDR. Both are valid.

**Notes:** AVM adds ipt-c2, ycgco-re and ycgco-ro to the AV1 list. 'identity' is used for RGB (4:4:4) coding.

<a id="transfer-characteristics"></a>

#### `--transfer-characteristics`

**Type:** enum · **Values:** unspecified, bt709, bt470m, bt470bg, bt601, smpte240, lin, log100, log100sq10, iec61966, bt1361, srgb, bt2020-10bit, bt2020-12bit, smpte2084, hlg, smpte428 · **Default:** not stated (unspecified) · **HDR-relevant**

Writes the CICP transfer function into the sequence header. This is the field that marks a stream as PQ (smpte2084) or HLG (hlg).

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `smpte2084 (HDR10/PQ) or hlg (HLG)` | The CTC HDR class uses smpte2084. 'hlg' is the spelling in AVM's transfer enum. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/arg_defs.c) |

**In Lumora:** Passed as --transfer-characteristics={tc_name}. PQ maps to smpte2084, which is valid. HLG maps to 'arib-std-b67', which is NOT in AVM's enum, so every Lumora HLG AV2 encode fails at option parsing. encoders.json avm.colorNames.hlg.tc should be 'hlg'.

**Notes:** Enum matching is exact and case-sensitive.

### Analysis and motion search

<a id="enable-adaptive-mvd"></a>

#### `--enable-adaptive-mvd`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables adaptive motion-vector-difference resolution, which codes MV differences at a precision that adapts to the block.

**Effect:** quality + · speed slight cost · size smaller

**Notes:** New AV2 tool.

<a id="enable-bawp"></a>

#### `--enable-bawp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables block adaptive weighted prediction, which corrects brightness changes between reference and current blocks, as in fades and flicker.

**Effect:** quality + on fades · speed slight cost · size smaller

<a id="enable-cwp"></a>

#### `--enable-cwp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables compound weighted prediction, which mixes two references with signaled, unequal weights.

**Effect:** quality + · speed slight cost · size smaller

<a id="enable-diff-wtd-comp"></a>

#### `--enable-diff-wtd-comp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables difference-weighted compound prediction, which blends two references with a mask derived from their difference.

**Effect:** quality + · speed slower · size smaller

<a id="enable-drl-reorder"></a>

#### `--enable-drl-reorder`

**Type:** int · **Values:** 0: no reorder, 1: reorder with constraints, 2: always reorder · **Default:** 1 (reorder with constraints) · advanced

Controls reordering of the dynamic reference MV candidate list so that likely candidates get cheaper indices.

**Effect:** quality none · speed ± · size smaller with reorder

<a id="enable-flex-mvres"></a>

#### `--enable-flex-mvres`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables flexible motion vector resolution, choosing MV precision per block.

**Effect:** quality + · speed slight cost · size smaller

<a id="enable-global-motion"></a>

#### `--enable-global-motion`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Searches for frame-wide camera motion models such as pan, zoom and rotation, and uses them as prediction.

**Effect:** quality + on camera motion · speed slower · size smaller on pans and zooms

**Notes:** Off by default in v1.0.0, unlike libaom AV1. Sample.cfg in the repo turns it on.

<a id="enable-high-motion"></a>

#### `--enable-high-motion`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Uses a much larger motion search window so that very fast motion can be found.

**Effect:** quality + on fast motion · speed slower · size smaller on fast motion

**Notes:** A plausible choice for sports or fast action, but not tested upstream in CTC.

<a id="enable-imp-msk-bld"></a>

#### `--enable-imp-msk-bld`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables implicit masked blending of compound predictions near picture boundaries and out-of-frame references.

**Effect:** quality + · speed slight · size smaller

<a id="enable-interinter-wedge"></a>

#### `--enable-interinter-wedge`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables wedge-shaped masks that blend two inter predictions along a straight edge.

**Effect:** quality + at object edges · speed slower · size smaller

<a id="enable-interintra-comp"></a>

#### `--enable-interintra-comp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables blending an inter prediction with an intra prediction in one block.

**Effect:** quality + · speed slower · size smaller

<a id="enable-interintra-wedge"></a>

#### `--enable-interintra-wedge`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows wedge masks for inter-intra blending.

**Effect:** quality + · speed slower · size smaller

<a id="enable-intrabc"></a>

#### `--enable-intrabc`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables intra block copy, which predicts a block from an already coded area of the same frame. Very effective for text and UI.

**Effect:** quality + on screen content · speed slower · size much smaller on screen content

**Notes:** On by default unless the build sets CONFIG_SHARP_SETTINGS.

<a id="enable-intrabc-ext"></a>

#### `--enable-intrabc-ext`

**Type:** int · **Values:** 0: disable, 1: extend search to the local area, 2: only use the local search range · **Default:** 1 · advanced

Controls the search range extension for intra block copy.

**Effect:** quality + on screen content · speed slower with larger range · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| screen content | `1` | The CTC uses --tune-content=screen --enable-intrabc-ext=1 for the screen-sharing class (B2). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| live action | `1 (2 for 360p and smaller)` | The CTC uses 1 for most classes and 2 for the 640x360 and 480x270 classes (A4, A5). | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="enable-joint-mvd"></a>

#### `--enable-joint-mvd`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables joint coding of the two motion-vector differences in compound prediction.

**Effect:** quality + · speed slight · size smaller

<a id="enable-masked-comp"></a>

#### `--enable-masked-comp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Master switch for masked compound modes (wedge and difference-weighted).

**Effect:** quality + · speed slower · size smaller

<a id="enable-mvd-sign-derive"></a>

#### `--enable-mvd-sign-derive`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Derives the sign of some MV differences instead of coding it.

**Effect:** quality none · speed none · size smaller

<a id="enable-mv-traj"></a>

#### `--enable-mv-traj`

**Type:** bool · **Values:** 0: disable, 1: enable MV trajectory tracking · **Default:** 1 (enable) · advanced

Tracks motion trajectories across frames to build better temporal MV candidates.

**Effect:** quality + · speed slight · size smaller

<a id="enable-onesided-comp"></a>

#### `--enable-onesided-comp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows compound prediction from two references on the same temporal side, both past or both future.

**Effect:** quality + · speed slower · size smaller

<a id="enable-opfl-refine"></a>

#### `--enable-opfl-refine`

**Type:** int · **Values:** 0: off, 1: switchable per block, 2: all blocks with simple compound average, 3: auto (switchable per frame by the encoder) · **Default:** 1 (switchable per block) · advanced

Enables optical-flow refinement of compound motion vectors at sub-block level, done by both encoder and decoder.

**Effect:** quality + · speed slower (decoder too) · size smaller

<a id="enable-ref-frame-mvs"></a>

#### `--enable-ref-frame-mvs`

**Type:** bool · **Values:** 0/1 · **Default:** 1 (default is 1) · advanced

Enables temporal motion vector prediction from the motion stored in reference frames.

**Effect:** quality + · speed slight · size smaller

<a id="enable-refinemv"></a>

#### `--enable-refinemv`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables decoder-side motion vector refinement, where the decoder improves signaled MVs with a local search.

**Effect:** quality + · speed slower (decoder too) · size smaller

<a id="enable-refmvbank"></a>

#### `--enable-refmvbank`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** not stated (source default 1) · advanced

Keeps a bank of recently used motion vectors as extra MV candidates.

**Effect:** quality + · speed slight · size smaller

**Notes:** GitHub main later ties this to switch-frame conformance.

<a id="enable-six-param-warp-delta"></a>

#### `--enable-six-param-warp-delta`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows explicitly signaled warp models with all six affine parameters.

**Effect:** quality + on complex motion · speed slower · size smaller

<a id="enable-skip-mode"></a>

#### `--enable-skip-mode`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables skip mode, a cheap compound mode with no residual and inferred references.

**Effect:** quality + · speed faster · size smaller

<a id="enable-smooth-interintra"></a>

#### `--enable-smooth-interintra`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables smooth (gradient) blending for inter-intra prediction.

**Effect:** quality + · speed slight · size smaller

<a id="enable-tip"></a>

#### `--enable-tip`

**Type:** int · **Values:** 0: disable, 1: TIP frame used as reference or direct output, 2: TIP frame only used as reference · **Default:** 1 · advanced

Enables temporal interpolated prediction, which builds an interpolated frame from two references along motion trajectories. That frame can serve as a reference or be output directly with almost no bits.

**Effect:** quality + · speed slower · size smaller, especially on smooth motion

**Notes:** One of AV2's headline tools.

<a id="enable-tip-refinemv"></a>

#### `--enable-tip-refinemv`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Applies MV refinement and optical flow when building TIP frames.

**Effect:** quality + · speed slower · size smaller

**Notes:** Only matters with TIP enabled.

<a id="enable-warp-causal"></a>

#### `--enable-warp-causal`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables warp prediction that derives its model from neighboring blocks' motion.

**Effect:** quality + · speed slower · size smaller

<a id="enable-warp-delta"></a>

#### `--enable-warp-delta`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows explicitly signaled warp model adjustments.

**Effect:** quality + · speed slower · size smaller

<a id="enable-warped-motion"></a>

#### `--enable-warped-motion`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Master switch for local warped (affine) motion prediction.

**Effect:** quality + on rotation and zoom · speed slower · size smaller

<a id="enable-warp-extend"></a>

#### `--enable-warp-extend`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Lets a block extend a neighbor's warp model.

**Effect:** quality + · speed slight · size smaller

<a id="max-drl-refbvs"></a>

#### `--max-drl-refbvs`

**Type:** int · **Values:** 0 (auto), 2-4 (fixed) · **Default:** 0 (auto) · advanced

Size of the block-vector candidate list for intra block copy.

**Effect:** quality + with more · speed slower with more · size ±

<a id="max-drl-refmvs"></a>

#### `--max-drl-refmvs`

**Type:** int · **Values:** 0 (auto), 2-8 (fixed) · **Default:** 0 (auto) · advanced

Size of the dynamic reference MV candidate list per reference frame.

**Effect:** quality + with more · speed slower with more · size ±

**Notes:** GitHub main's help now says 2-6. Treat values above 6 as possibly invalid.

<a id="max-reference-frames"></a>

#### `--max-reference-frames`

**Type:** int · **Values:** 1 to 7 · **Default:** 7 · advanced

Maximum number of reference frames one frame may use.

**Effect:** quality + with more · speed slower with more · size smaller with more

<a id="reduced-ref-frame-mvs-mode"></a>

#### `--reduced-ref-frame-mvs-mode`

**Type:** bool · **Values:** 0: all allowed reference combinations, 1: one reference combination · **Default:** 0 · advanced

Limits temporal MV projection to a single reference combination.

**Effect:** quality - slight · speed faster (decoder too) · size slightly larger

<a id="static-thresh"></a>

#### `--static-thresh`

**Type:** int · **Values:** threshold · **Default:** not stated (0) · advanced

Threshold under which blocks are treated as static and skipped early.

**Effect:** quality - if high · speed faster if high · size ±

**Notes:** Legacy option. Leave at 0.

### Partitioning and transforms

<a id="enable-angle-delta"></a>

#### `--enable-angle-delta`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows fine angle offsets on directional intra prediction modes.

**Effect:** quality + · speed slower · size smaller

<a id="enable-cctx"></a>

#### `--enable-cctx`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables a cross-chroma transform that decorrelates the Cb and Cr residuals before coding.

**Effect:** quality + · speed slight cost · size smaller

<a id="enable-cfl-intra"></a>

#### `--enable-cfl-intra`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables chroma-from-luma intra prediction, which predicts chroma from the reconstructed luma texture.

**Effect:** quality + · speed slight cost · size smaller

<a id="enable-chroma-dctonly"></a>

#### `--enable-chroma-dctonly`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Restricts chroma to the DCT only, skipping the other transform types.

**Effect:** quality - slight · speed faster · size larger

<a id="enable-extended-sdp"></a>

#### `--enable-extended-sdp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows separate luma and chroma partition trees (semi-decoupled partitioning) on inter frames too.

**Effect:** quality + · speed slower · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| screen content | `0 (only in CTC ECF-6 screen RGB tests)` | The CTC extended-chroma-format screen content class turns it off alongside --tune-content=screen. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/VideoEncoder.py) |

<a id="enable-ext-partitions"></a>

#### `--enable-ext-partitions`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables AV2's extended partition shapes beyond quad, binary and the basic rectangles.

**Effect:** quality + · speed slower · size smaller

<a id="enable-flip-idtx"></a>

#### `--enable-flip-idtx`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the flipped ADST, identity and 1-D transform types in addition to plain DCT/ADST.

**Effect:** quality + (identity helps sharp synthetic edges) · speed slower · size smaller

<a id="enable-fsc"></a>

#### `--enable-fsc`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables forward skip coding, a residual mode that codes coefficients without a transform. It suits screen and synthetic content.

**Effect:** quality + on synthetic content · speed slight cost · size smaller

<a id="enable-ibp"></a>

#### `--enable-ibp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables intra bi-prediction, which combines predictions from two directions.

**Effect:** quality + · speed slight cost · size smaller

<a id="enable-idtx-intra"></a>

#### `--enable-idtx-intra`

**Type:** bool · **Values:** 0: disabled, 1: enabled · **Default:** 1 (enabled) · advanced

When forward skip coding is off, still allows the identity transform for intra blocks.

**Effect:** quality + on synthetic content · speed slight · size smaller

**Notes:** Only matters with --enable-fsc=0.

<a id="enable-inter-ddt"></a>

#### `--enable-inter-ddt`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables data-driven (trained) transforms for inter residuals.

**Effect:** quality + · speed slower · size smaller

<a id="enable-inter-ist"></a>

#### `--enable-inter-ist`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables a secondary transform applied after the primary transform on inter blocks.

**Effect:** quality + · speed slower · size smaller

<a id="enable-intra-dip"></a>

#### `--enable-intra-dip`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables a data-driven (trained) intra prediction mode.

**Effect:** quality + · speed slower · size smaller

<a id="enable-intra-edge-filter"></a>

#### `--enable-intra-edge-filter`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Smooths the reference edge pixels before directional intra prediction.

**Effect:** quality + · speed slight · size smaller

<a id="enable-ist"></a>

#### `--enable-ist`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the intra secondary transform.

**Effect:** quality + · speed slower · size smaller

<a id="enable-mhccp"></a>

#### `--enable-mhccp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables multi-hypothesis cross-component prediction, an extension of chroma-from-luma.

**Effect:** quality + chroma · speed slower · size smaller

<a id="enable-mrls"></a>

#### `--enable-mrls`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Lets intra prediction use reference lines further from the block edge, not only the adjacent row and column.

**Effect:** quality + · speed slower · size smaller

<a id="enable-paeth-intra"></a>

#### `--enable-paeth-intra`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the Paeth intra predictor.

**Effect:** quality + · speed slight · size smaller

<a id="enable-palette"></a>

#### `--enable-palette`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables palette mode, which codes blocks with a few distinct colors as indices into a small palette. Strong for screen content and flat cartoons.

**Effect:** quality + on screen/anime · speed slower · size smaller on flat colors

<a id="enable-parity-hiding"></a>

#### `--enable-parity-hiding`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Hides one coefficient sign or parity bit in the sum of the other coefficients, which saves bits.

**Effect:** quality none · speed slight · size smaller

<a id="enable-rect-partitions"></a>

#### `--enable-rect-partitions`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows rectangular (non-square) block partitions.

**Effect:** quality + · speed slower · size smaller

<a id="enable-sdp"></a>

#### `--enable-sdp`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows semi-decoupled luma and chroma partition trees on key frames.

**Effect:** quality + · speed slower · size smaller

<a id="enable-smooth-intra"></a>

#### `--enable-smooth-intra`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · **HDR-relevant** · advanced

Enables the smooth intra predictors that interpolate gently across the block.

**Effect:** quality + on gradients · speed slight · size smaller

**Notes:** Gradient-friendly modes matter for skies in HDR. Leave on.

<a id="enable-tx-partition"></a>

#### `--enable-tx-partition`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Allows splitting a block's residual into several transform blocks.

**Effect:** quality + · speed slower · size smaller

<a id="enable-uneven-4way-partitions"></a>

#### `--enable-uneven-4way-partitions`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables 1:2:4:1 and 1:4:2:1 four-way splits.

**Effect:** quality + · speed slower · size smaller

<a id="max-pb-aspect-ratio"></a>

#### `--max-pb-aspect-ratio`

**Type:** int · **Values:** 2, 4, or 8 · **Default:** 8 · advanced

Limits how elongated prediction blocks may be.

**Effect:** quality - slight when lower · speed faster when lower · size slightly larger when lower

<a id="max-partition-size"></a>

#### `--max-partition-size`

**Type:** int · **Values:** 4, 8, 16, 32, 64, 128, 256 · **Default:** not stated (source default 256) · advanced

Largest block size the partition search may use.

**Effect:** quality + larger helps flat areas · speed ± · size smaller with larger blocks

**Notes:** Cannot be below --min-partition-size.

<a id="min-partition-size"></a>

#### `--min-partition-size`

**Type:** int · **Values:** 4, 8, 16, 32, 64, 128 · **Default:** not stated (source default 4) · advanced

Smallest block size the partition search may use. At 4K and above, or at higher speed settings, the floor is raised to 8 automatically.

**Effect:** quality - when raised · speed faster when raised · size larger when raised

<a id="select-adaptive-ds"></a>

#### `--select-adaptive-ds`

**Type:** int · **Values:** 0: filter 0, 1: filter 1, 2: filter 2, 3: adaptive · **Default:** 3 (adaptive) · advanced

Picks the luma downsampling filter used by chroma-from-luma prediction, or lets the encoder choose adaptively.

**Effect:** quality + with adaptive · speed slight · size smaller

<a id="sb-size"></a>

#### `--sb-size`

**Type:** enum · **Values:** dynamic, 64, 128, 256 · **Default:** not stated (dynamic) · advanced

Superblock size. Dynamic picks 256x256 for content of 720 lines or more at speeds 0-1, and smaller sizes at lower resolutions or higher speeds.

**Effect:** quality + larger for high resolution · speed ± · size smaller with larger SB on high-res

**Notes:** The dynamic rules are in encoder_utils.c. Above speed 1, dynamic uses at most 128x128.

### In-loop filters

<a id="ccso-unit-matches-sb"></a>

#### `--ccso-unit-matches-sb`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Ties the CCSO filter signaling unit to the superblock size.

**Effect:** quality ± · speed ± · size ±

<a id="disable-loopfilters-across-tiles"></a>

#### `--disable-loopfilters-across-tiles`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Stops the in-loop filters at tile edges, which makes tiles fully independent at a small quality cost.

**Effect:** quality - (possible seams) · speed better parallel decode · size slightly larger

<a id="enable-ccso"></a>

#### `--enable-ccso`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** not stated (source default 1) · **HDR-relevant** · advanced

Enables cross-component sample offset, an in-loop filter that uses luma to correct chroma (and other component) errors.

**Effect:** quality + chroma · speed slower · size smaller

**Notes:** Wide-gamut content tends to show chroma errors more, so leave it on.

<a id="enable-cdef"></a>

#### `--enable-cdef`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the constrained directional enhancement filter, which removes ringing around edges.

**Effect:** quality + (can soften fine grain) · speed slower · size smaller

<a id="enable-cdef-on-skip-txfm"></a>

#### `--enable-cdef-on-skip-txfm`

**Type:** int · **Values:** 0: always off, 1: always on, 2: adaptive per frame · **Default:** 1 (always on) · advanced

Controls whether CDEF also filters blocks that have no coded residual.

**Effect:** quality ± · speed faster with 0 · size ±

<a id="enable-deblocking"></a>

#### `--enable-deblocking`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the deblocking filter that smooths block edges.

**Effect:** quality + (disable only for testing) · speed slower · size smaller

<a id="enable-gdf"></a>

#### `--enable-gdf`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the guided detail filter, an AV2 in-loop filter that restores detail lost to quantization.

**Effect:** quality + · speed slower · size smaller

<a id="enable-lf-sub-pu"></a>

#### `--enable-lf-sub-pu`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Also deblocks edges inside prediction blocks that are split into sub-blocks, for example by optical flow refinement.

**Effect:** quality + · speed slight · size smaller

<a id="enable-pc-wiener"></a>

#### `--enable-pc-wiener`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the pixel-classified Wiener mode of loop restoration.

**Effect:** quality + · speed slower · size smaller

**Notes:** Needs --enable-restoration=1.

<a id="enable-restoration"></a>

#### `--enable-restoration`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the loop restoration filter stage (Wiener variants).

**Effect:** quality + · speed slower · size smaller

<a id="enable-wiener-nonsep"></a>

#### `--enable-wiener-nonsep`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Enables the non-separable Wiener mode of loop restoration.

**Effect:** quality + · speed slower · size smaller

<a id="gdf-unit-matches-sb"></a>

#### `--gdf-unit-matches-sb`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Ties the guided detail filter's signaling unit to the superblock size.

**Effect:** quality ± · speed ± · size ±

<a id="sharpness"></a>

#### `--sharpness`

**Type:** int · **Values:** 0..7 · **Default:** not stated (0) · advanced

Biases the deblocking filter toward preserving sharp edges. Higher values filter less.

**Effect:** quality ± (sharper, but more blocking) · speed none · size slightly larger

### Threading and performance

<a id="threads"></a>

#### `--threads` (also `-t`)

**Type:** int · **Values:** max threads · **Default:** not stated (0)

Caps the number of worker threads. Threads only help when there are several tiles or row-based multithreading is on.

**Effect:** quality none by itself · speed faster with tiles or row-mt · size none

| For | Value | Why | Source |
|---|---|---|---|
| archive | `1 (with one tile)` | The CTC verification configuration uses one thread and one tile to measure the best possible coding gain. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| speed | `match the tile count (e.g. 4 for 4 column tiles)` | For speed, the CTC pairs threads with tiles: two threads for two tiles and four for four. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**In Lumora:** Passed as --threads={threads} from Lumora's per-segment thread budget.

**Notes:** Fatal error above 1 in builds without CONFIG_MULTITHREAD.

<a id="coeff-cost-upd-freq"></a>

#### `--coeff-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile · **Default:** not stated (0 = SB) · advanced

How often the encoder refreshes its coefficient bit-cost estimates during the RD search.

**Effect:** quality + with frequent updates · speed faster with less frequent · size slightly smaller with frequent

**Notes:** Affects the encoder only, not the bitstream syntax.

<a id="frame-parallel"></a>

#### `--frame-parallel`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Turns on features that allow frames to be decoded in parallel, by disabling backward entropy adaptation between frames.

**Effect:** quality - · speed faster decode · size larger

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | The CTC encode scripts pass --frame-parallel=0. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/VideoEncoder.py) |

<a id="mode-cost-upd-freq"></a>

#### `--mode-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile · **Default:** not stated (0 = SB) · advanced

How often mode-cost estimates are refreshed during encoding.

**Effect:** quality + with frequent · speed faster with rare · size ±

**Notes:** Encoder only.

<a id="mv-cost-upd-freq"></a>

#### `--mv-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off · **Default:** not stated (0 = SB) · advanced

How often motion-vector cost estimates are refreshed.

**Effect:** quality + with frequent · speed faster with rare · size ±

**Notes:** Encoder only.

<a id="row-mt"></a>

#### `--row-mt`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 1 (on)

Multithreads the encoder across superblock rows inside a tile.

**Effect:** quality none (tiny changes possible) · speed faster with threads · size none

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | Every CTC tile and thread configuration passes --row-mt=0. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** GitHub main has since changed the default to 0 (off). On those builds, pass --row-mt=1 explicitly to keep the speedup.

<a id="tile-columns"></a>

#### `--tile-columns`

**Type:** int · **Values:** log2 count, 0..6 · **Default:** not stated (0)

Splits each frame into 2^n tile columns, which can be encoded and decoded in parallel.

**Effect:** quality - slight · speed faster with threads · size slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| speed | `2 at 4K (4 columns), 1 at 1080p` | The CTC uses four column tiles at 4K and two at 1080p to cut test time. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |
| archive | `0` | The CTC verification configuration uses a single tile for the best coding gain. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

**Notes:** Lumora sets --threads but not tiles. Without tiles or --row-mt, extra threads do little.

<a id="tile-rows"></a>

#### `--tile-rows`

**Type:** int · **Values:** log2 count, 0..6 · **Default:** not stated (0) · advanced

Splits each frame into 2^n tile rows.

**Effect:** quality - slight · speed faster with threads · size slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| speed | `1 (with --tile-columns=2 for 8 tiles)` | The CTC low-delay configuration uses 2 rows x 4 columns with 8 threads for 1080p-class content. | [source](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf) |

<a id="tile-width"></a>

#### `--tile-width`

**Type:** list · **Values:** comma-separated tile widths · **Default:** not stated · advanced

Gives explicit, possibly uneven, tile column widths instead of an even log2 split.

**Effect:** quality - slight · speed faster with threads · size slightly larger

**Notes:** Parsed but not listed by --help. The units are not documented and are presumably superblocks.

<a id="tile-height"></a>

#### `--tile-height`

**Type:** list · **Values:** comma-separated tile heights · **Default:** not stated · advanced

Gives explicit tile row heights.

**Effect:** quality - slight · speed faster with threads · size slightly larger

**Notes:** Parsed but not listed by --help.

### Logging and statistics

<a id="debug"></a>

#### `--debug` (also `-D`)

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Turns on debug mode, which makes the output bitstream deterministic so that repeated runs can be compared byte for byte.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `set` | The upstream CI encode checks use --debug so that md5 comparisons between builds are meaningful. | [source](https://gitlab.com/AOMediaCodec/avm/-/blob/research-v15.0.0/.gitlab-ci.yml) |

<a id="recon"></a>

#### `--recon`

**Type:** path · **Values:** file name · **Default:** not stated · advanced

Writes the encoder's reconstructed (decoded) frames to a raw file so they can be compared with the source without running a decoder.

**Effect:** quality none · speed slightly slower (extra I/O) · size none

<a id="quiet"></a>

#### `--quiet` (also `-q`)

**Type:** bool · **Values:** none · **Default:** not stated

Suppresses the per-frame progress line and the automatic profile or bit-depth upgrade notices.

**Notes:** Note that -q is quiet here, not quantizer.

<a id="verbose"></a>

#### `--verbose` (also `-v`)

**Type:** bool · **Values:** none · **Default:** not stated

Prints the full encoder configuration (tools, QP, speed, partition sizes) before encoding starts.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `set` | The CTC encode script always logs the configuration with --verbose so that runs are reproducible. | [source](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/VideoEncoder.py) |

**Notes:** Useful for confirming that CICP values were accepted.

<a id="psnr"></a>

#### `--psnr`

**Type:** int · **Values:** optional: 0 disable, 1 PSNR at input bit depth, 2 PSNR at stream bit depth · **Default:** 2 when given without a value; off when absent

Adds PSNR to the status output. The optional value chooses whether PSNR is measured at the input or at the coded bit depth.

**Effect:** quality none · speed slightly slower · size none

<a id="q-hist"></a>

#### `--q-hist`

**Type:** int · **Values:** n buckets · **Default:** not stated · advanced

Prints a histogram of the quantizers chosen across the encode.

<a id="rate-hist"></a>

#### `--rate-hist`

**Type:** int · **Values:** n buckets · **Default:** not stated · advanced

Prints a histogram of per-frame bitrates.

<a id="disable-warnings"></a>

#### `--disable-warnings`

**Type:** bool · **Values:** none · **Default:** not stated · advanced

Hides the warnings that avmenc prints about settings it considers risky.

<a id="disable-warning-prompt"></a>

#### `--disable-warning-prompt` (also `-y`)

**Type:** bool · **Values:** none · **Default:** not stated

Still prints configuration warnings but does not stop to ask whether to continue. Use it for unattended runs.

**In Lumora:** Not passed. Lumora pipes Y4M on stdin, so an interactive warning prompt could stall an encode. Adding -y would be safer.

<a id="test-decode"></a>

#### `--test-decode`

**Type:** enum · **Values:** off, fatal, warn · **Default:** not stated (off) · advanced

Decodes each frame inside the encoder and compares it with the encoder's reconstruction. 'fatal' stops on the first mismatch and 'warn' only reports it.

**Effect:** quality none · speed slower · size none

**Notes:** Useful when experimenting with unusual tool combinations.

<a id="frame-hash"></a>

#### `--frame-hash`

**Type:** enum · **Values:** off, raw, filmgrain, both · **Default:** not stated (off) · advanced

Writes decoded-frame hash metadata OBUs so that a decoder can check its output. The hash covers the raw frame, the frame after film grain, or both.

**Effect:** quality none · speed slight · size tiny

**Notes:** Parsed but not listed by --help.

<a id="use-per-plane-frame-hash"></a>

#### `--use-per-plane-frame-hash`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Writes separate hashes for Y, U and V instead of one per frame.

**Effect:** quality none · speed none · size tiny

**Notes:** Parsed but not listed by --help.

### Other

<a id="help"></a>

#### `--help`

**Type:** bool · **Values:** none · **Default:** not stated

Prints the full option list grouped into Options, Encoder Global, Rate Control, Keyframe Placement and AV2 Specific sections, then exits.

**Notes:** Several flags that the encoder parses are not printed by --help: --cq-level, --tile-width, --tile-height, --use-fixed-qp-offsets, --fixed-qp-offsets, --frame-hash and --use-per-plane-frame-hash.

<a id="cfg"></a>

#### `--cfg` (also `-c`)

**Type:** path · **Values:** config file path · **Default:** not stated · advanced

Reads encoder tool settings from a key = value text file (see Sample.cfg in the repo) before the command-line options are applied.

**Effect:** quality depends on file · speed depends on file · size depends on file

**Notes:** Only the first --cfg is honored. Keys use underscore names such as superblock_size and enable_cdef, which are not the dashed CLI names.

<a id="codec"></a>

#### `--codec`

**Type:** string · **Values:** short codec name; only 'av2' in AVM builds · **Default:** av2 (last registered encoder) · advanced

Selects the encoder interface. AVM ships a single encoder, so this is effectively fixed to av2.

**Notes:** The CTC scripts pass --codec=av2 explicitly.

<a id="enable-lcr"></a>

#### `--enable-lcr`

**Type:** bool · **Values:** 0 off, 1 on · **Default:** 0 · advanced

Emits a layer configuration record OBU describing the stream's layer structure, which matters for multi-layer and multi-stream AV2 streams.

**Effect:** quality none · speed none · size negligible

<a id="enable-operating-point-sets"></a>

#### `--enable-operating-point-sets`

**Type:** bool · **Values:** 0 off, 1 on · **Default:** 0 · advanced

Emits operating point set OBUs, which describe the decodable subsets of a layered stream.

**Effect:** quality none · speed none · size negligible

<a id="num-operating-point-sets"></a>

#### `--num-operating-point-sets`

**Type:** int · **Values:** 1-16 · **Default:** 1 · advanced

How many operating point sets to write when they are enabled.

**Effect:** quality none · speed none · size negligible

<a id="enable-atlas"></a>

#### `--enable-atlas`

**Type:** bool · **Values:** 0 off, 1 on · **Default:** 0 · advanced

Emits an atlas segment OBU, which describes how several sub-pictures or streams are arranged into one composite picture.

**Effect:** quality none · speed none · size negligible

**Notes:** Part of AV2's multi-stream and composite video support.

<a id="target-seq-level-idx"></a>

#### `--target-seq-level-idx`

**Type:** string · **Values:** 'ABxy': AB = operating point index, xy = level index (e.g. '0', '1021') · **Default:** not stated (no target) · advanced

Asks the encoder to keep each operating point within a given AV2 level, constraining parameters such as bitrate and tile counts.

**Effect:** quality - if constraining · speed none · size may cap

<a id="add-sef-for-output"></a>

#### `--add-sef-for-output`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 0 (off) · advanced

Adds show-existing-frame headers without order hints so that hidden frames are explicitly output.

**Effect:** quality none · speed none · size negligible

**Notes:** Bitstream-structure research option.

<a id="avg-cdf-type"></a>

#### `--avg-cdf-type`

**Type:** int · **Values:** 0 (frame based), 1 (tile based) · **Default:** adaptively chosen based on number of tiles · advanced

Chooses whether entropy-model averaging is done per frame or per tile.

**Effect:** quality none · speed none · size ±

**Notes:** Only matters with --enable-avg-cdf=1.

<a id="cdf-update-mode"></a>

#### `--cdf-update-mode`

**Type:** int · **Values:** 0: no CDF update, 1: update on all frames, 2: selectively update · **Default:** 1 (all frames) · advanced

Controls how often the entropy coder adapts its probability tables between frames.

**Effect:** quality none · speed faster decode with 0 · size smaller with 1

<a id="cross-frame-cdf-init-mode"></a>

#### `--cross-frame-cdf-init-mode`

**Type:** int · **Values:** 0: disable, 1: enable cross frame CDF init · **Default:** 1 (enable) · advanced

Lets a frame start its entropy model from an earlier frame's adapted probabilities instead of the defaults.

**Effect:** quality none · speed none · size smaller with 1

<a id="enable-avg-cdf"></a>

#### `--enable-avg-cdf`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 1 (true) · advanced

Initializes entropy models from an average of frame or tile statistics rather than a single source.

**Effect:** quality none · speed none · size smaller

<a id="enable-mfh-obu-signaling"></a>

#### `--enable-mfh-obu-signaling`

**Type:** bool · **Values:** 0: false, 1: true · **Default:** 0 (false) · advanced

Signals a multi-frame header OBU, which shares header information across several frames.

**Effect:** quality none · speed none · size slightly smaller

<a id="enable-short-refresh-frame-flags"></a>

#### `--enable-short-refresh-frame-flags`

**Type:** bool · **Values:** 0: N = 8, 1: N = 3 · **Default:** not stated (source default 1) · advanced

Signals the reference refresh flags with 3 bits instead of 8 bits.

**Effect:** quality none · speed none · size slightly smaller with 1

<a id="mtu-size"></a>

#### `--mtu-size`

**Type:** int · **Values:** bytes; 0 = no MTU targeting · **Default:** 0 (no MTU targeting) · advanced

Sizes tile groups to fit a network packet. It overrides --num-tile-groups.

**Effect:** quality - · speed none · size larger

**Notes:** For packetized streaming only.

<a id="num-tile-groups"></a>

#### `--num-tile-groups`

**Type:** int · **Values:** count · **Default:** 1 · advanced

Maximum number of tile groups per frame, which allows a frame to be split across several OBUs.

**Effect:** quality none · speed none · size slightly larger

<a id="operating-points-count"></a>

#### `--operating-points-count`

**Type:** int · **Values:** 1-31 · **Default:** not stated (source default 1) · advanced

Number of operating points signaled in the sequence header for layered streams.

**Effect:** quality none · speed none · size negligible

**Notes:** GitHub main has narrowed the help range to 1-7.

<a id="scan-type-info"></a>

#### `--scan-type-info`

**Type:** bool · **Values:** 0/1 · **Default:** not stated (0) · advanced

Signals a flag saying whether scan-type (progressive or interlaced source) information is present.

**Effect:** quality none · speed none · size negligible

<a id="set-tier-mask"></a>

#### `--set-tier-mask`

**Type:** int · **Values:** 32-bit mask; bit 0 = Main tier, 1 = High tier · **Default:** 0 (Main tier) · advanced

Chooses Main or High tier for each of up to 32 operating points.

<a id="timing-info"></a>

#### `--timing-info`

**Type:** enum · **Values:** unspecified, constant, model · **Default:** not stated (unspecified) · advanced

Writes timing information into the bitstream: none, a constant frame rate, or a decoder model.

**Effect:** quality none · speed none · size negligible

**Notes:** The help notes that 'model' only works without hidden frames and super-resolution.

<a id="use-short-metadata"></a>

#### `--use-short-metadata`

**Type:** bool · **Values:** 0: GROUP format, 1: SHORT format · **Default:** 0 (GROUP format) · advanced

Chooses between the grouped and the short metadata OBU syntax.

**Effect:** quality none · speed none · size slightly smaller with short

## Sources

- [AVM repository (GitHub, primary since v1.0.0)](https://github.com/AOMediaCodec/avm)
- [AVM repository (GitLab mirror, research tags)](https://gitlab.com/AOMediaCodec/avm)
- [AVM v1.0.0 av2/arg_defs.c (option definitions, ground truth)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/arg_defs.c)
- [AVM v1.0.0 apps/avmenc.c (help tables and parsing)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/apps/avmenc.c)
- [AVM v1.0.0 av2/av2_cx_iface.c (defaults and validation)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/av2_cx_iface.c)
- [AVM v1.0.0 avm/avmcx.h (cpu-used semantics)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm/avmcx.h)
- [AVM v1.0.0 cmake/avm_config_defaults.cmake (build flags: 12-bit, VMAF, WebM, denoise)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/cmake/avm_config_defaults.cmake)
- [AVM v1.0.0 avm_dsp/grain_table.c (filmgrn2 grain table format)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm_dsp/grain_table.c)
- [AVM v1.0.0 av2/common/enums.h (profiles)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/common/enums.h)
- [AVM v1.0.0 av2/encoder/encoder_utils.c (dynamic superblock size)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/encoder/encoder_utils.c)
- [AVM v1.0.0 common/y4minput.c (COLORRANGE parsing)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/common/y4minput.c)
- [AVM v1.0.0 README](https://github.com/AOMediaCodec/avm/blob/v1.0.0/README.md)
- [AVM CTC encode script (convexhull_framework VideoEncoder.py)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/VideoEncoder.py)
- [AVM CTC config.yaml (QP lists, GOP sizes)](https://github.com/AOMediaCodec/avm/blob/v1.0.0/tools/convexhull_framework/src/config.yaml)
- [AVM GitLab CI encoder runs (research-v15.0.0)](https://gitlab.com/AOMediaCodec/avm/-/blob/research-v15.0.0/.gitlab-ci.yml)
- [AOM Common Test Conditions v9.0 (CWG-G082)](https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf)
- [AV2 Specification site (v1.0.0, 28 May 2026)](https://av2.aomedia.org/)
- [AOMedia: AV2, what the final specification means for implementers](https://aomedia.org/blog%20posts/AV2-What-the-Final-Specification-Means-for-Implementers/)
- [CNX Software: AV2 draft spec and a quick try at the reference implementation](https://www.cnx-software.com/2026/02/03/aomedia-av2-video-codec-draft-specification-release-and-a-quick-try-at-the-reference-implementation/)
- [SVT-AV1 film grain synthesis appendix (shared AV1/AV2 grain model background)](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md)
- [AVM main branch arg_defs.c (post-1.0 changes: --rt, --sframe-conformance-option, --enable-low-complexity-decode)](https://github.com/AOMediaCodec/avm/blob/main/av2/arg_defs.c)

{% endraw %}
