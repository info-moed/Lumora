---
title: libaom AV1 (aomenc)
parent: Encoding settings
nav_order: 5
---

{% raw %}

# libaom AV1 (aomenc)

**Documented version:** AOMedia Project AV1 Encoder 3.15.3 · **Codec:** AV1 · **License:** BSD-2-Clause (plus the AOMedia Patent License 1.0) · **Homepage:** <https://aomedia.googlesource.com/aom> · **Homebrew:** [`aom`](https://formulae.brew.sh/formula/aom)

aomenc is the command-line front end of libaom, the AOMedia reference AV1 encoder. It supports every AV1 profile (8/10/12-bit; 4:0:0, 4:2:0, 4:2:2 and 4:4:4) and exposes nearly every coding tool as a switch. Codec Wiki notes that it makes poor use of many threads in one process, so chunked encoding (for example with Av1an) is the usual way to parallelize it. HDR support is thin: it signals CICP color values but has no flags for mastering-display or content-light metadata, so HDR10 static metadata must be added at mux time.

**Bit depths:** 8, 10, 12 · **Chroma:** 4:0:0, 4:2:0, 4:2:2, 4:4:4

Machine-readable data: [`data/aomenc.json`](data/aomenc.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

Encode at `--bit-depth=10` (or 12 with profile 2) and set the three CICP flags: `--color-primaries=bt2020`, `--transfer-characteristics=smpte2084` for HDR10/PQ or =hlg for HLG, and `--matrix-coefficients=bt2020ncl.` These are written into the AV1 sequence header. Color range is not a command-line flag: aomenc takes it from the Y4M header (XCOLORRANGE=FULL or LIMITED) and otherwise writes limited (studio) range. aomenc 3.15.3 has no options for mastering display color volume (MDCV) or MaxCLL/MaxFALL, and its WebM writer adds no Colour element, so for real HDR10 you have to add the static metadata when muxing, for example with mkvmerge `--max-content-light`, `--max-frame-light`, `--chromaticity-coordinates`, `--white-color-coordinates`, `--max-luminance` and `--min-luminance`. The CLI cannot carry HDR10+ dynamic metadata or Dolby Vision.

**Flags involved:** `--bit-depth`, `--input-bit-depth`, `--profile`, `--color-primaries`, `--transfer-characteristics`, `--matrix-coefficients`, `--chroma-sample-position`, `--validate-hbd-input`, `--deltaq-mode`

**Example (HDR10):**

```bash
ffmpeg -i master.mov -pix_fmt yuv420p10le -strict -1 -f yuv4mpegpipe - | aomenc - --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=20 --bit-depth=10 --input-bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --threads=8 --row-mt=1 --ivf -o video.ivf && mkvmerge -o video.mkv --color-primaries 0:9 --color-transfer-characteristics 0:16 --color-matrix-coefficients 0:9 --color-range 0:1 --max-content-light 0:1000 --max-frame-light 0:400 --chromaticity-coordinates 0:0.680,0.320,0.265,0.690,0.150,0.060 --white-color-coordinates 0:0.3127,0.3290 --max-luminance 0:1000 --min-luminance 0:0.0001 video.ivf
```

**Pitfalls:**

- HLG must be spelled `--transfer-characteristics=hlg.` The x265-style name arib-std-b67 is rejected and aomenc exits with its usage message (checked locally with 3.15.3). The numeric CICP code 18 also works because the parser accepts integers.
- No MDCV or MaxCLL/MaxFALL flags exist. Without a muxer step the file is tagged PQ/BT.2020 but carries no static HDR10 metadata, and some players and TVs then fall back to guessed tone mapping.
- The MaxCLL, MaxFALL and mastering values in the example are placeholders (P3-D65 primaries, 1000-nit mastering display). Copy the real values from the source with ffprobe or mediainfo; do not invent them.
- `--deltaq-mode=5` (HDR video) is mostly inert in 3.15.3: the per-block luma q offsets are compiled out (DISABLE_HDR_LUMA_DELTAQ is 1 in av1/encoder/encoder.h), so every block keeps the frame's base q. When the stream is exactly 10-bit with bt2020 primaries it still applies frame-level Cb/Cr delta-q offsets (av1/encoder/av1_quantize.c). Selecting it also replaces the default objective (TPL) delta-q mode 1.
- Piping Y4M through stdin requires `--passes=1.` aomenc defaults to two passes in good-quality mode and reopens the input for pass 2, so stdin input gives an output that holds only a 32-byte IVF header (checked locally).
- `--full-still-picture-hdr` refers to a full still-picture header, not high dynamic range. It has nothing to do with HDR.
- `--tune=butteraugli` only accepts 8-bit input and is not compiled into the Homebrew build, so it cannot be used for HDR.
- AV1 needs the Professional profile (2) for 12-bit or 4:2:2, and the High profile (1) for 4:4:4 at 8/10-bit. aomenc adjusts the profile to fit the input and prints a warning, in both directions (for example `--profile=2` with 10-bit 4:4:4 Y4M becomes profile 1). Hardware decoders generally handle only profile 0.
- Do not pass `--profile=2` with 12-bit 4:2:2 or 4:4:4 Y4M input: aomenc 3.15.3 then stops with 'Failed to set chroma subsampling x: Unspecified internal error'. Leave `--profile` out (or at 0) and aomenc raises it to 2 itself. 12-bit 4:2:0 with `--profile=2` works (all checked locally).
- `--chroma-sample-position` applies only to 4:2:0. Set it to match the source. Many UHD HDR masters use top-left siting (AV1 colocated), but check before you set it.

## Presets

| Preset | Speed | Notes |
|---|---|---|
| 0 | extremely slow (good mode) | Best compression libaom offers. Codec Wiki warns an encode at 0 could take weeks to finish. Use it only for tests or tiny clips. |
| 1 | very slow | Lumora's archival AV1 ladder ends its libaom rungs at 1 and 0. No source used here rates 1 against 0. |
| 2 | very slow | Codec Wiki: use if you have a lot of time. Good archival choice. |
| 3 | slow | Codec Wiki: worth it for more efficiency than 4. |
| 4 | moderate | Codec Wiki's recommended balance point. |
| 5 | faster | A step between Codec Wiki's balanced 4 and fast 6. Codec Wiki notes that SVT-AV1 handles only 4:2:0, so libaom is the AV1 option for 4:2:2/4:4:4 work. |
| 6 | fastest useful good-quality speed | Codec Wiki: choose 6 for speed. The help text lists 0..6 for good mode. |
| 7-9 (good mode) | about the same as 6 | The library accepts up to 9 outside realtime mode, but the good-quality speed-feature tables stop at 6. Codec Wiki says speeds above 6 have the worst efficiency. |
| 5-12 (--rt) | realtime | Realtime mode for low-latency or live encoding. From 7 up it uses non-RD mode, where delta-q modes 1-5 are silently ignored. |
| 0-9 (--allintra) | image/intra-only | All-intra mode for still images and intra-only masters. Non-RD mode starts at 8. |

## Rate control

| Mode | Flags | Notes |
|---|---|---|
| Constant quality (Q) | --end-usage=q --cq-level=N | Works like CRF in x264/x265. cq-level runs 0..63 and lower is better. Codec Wiki suggests 24 as a starting point. Lumora uses this mode with cq-level 14-40. |
| Constrained quality (CQ) | --end-usage=cq --cq-level=N --target-bitrate=K | Uses cq-level as the quality target and also takes `--target-bitrate`. aomcx.h only states that cq-level applies in cq and q modes; how strictly the bitrate acts as a cap is not documented in the sources used here (unverified). |
| VBR (default) | --end-usage=vbr --target-bitrate=K --passes=2 | Default mode. Two-pass VBR is how libaom expects to be used for bitrate targets. Tune with `--bias-pct`, `--minsection-pct` and `--maxsection-pct`. |
| CBR | --end-usage=cbr --target-bitrate=K --buf-sz --buf-initial-sz --buf-optimal-sz | Constant bitrate for live or realtime use, normally together with `--rt`. |
| Lossless | --lossless=1 | Mathematically lossless coding. Files are large. Valid at every bit depth and chroma format. |
| Quantizer clamps | --min-q / --max-q | Bound the per-frame quantizer (0..63) in any mode. |

## Recipes

### AV1 Pro: 12-bit 4:4:4 archival master (piped)

**Goal:** Near-transparent 12-bit full-chroma master from a 12-bit RGB/4:4:4 intermediate · **Content:** live action, CGI, graded masters

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=16 --bit-depth=12 --input-bit-depth=12 --tune=ssim --enable-qm=1 --enable-chroma-deltaq=1 --lag-in-frames=48 --threads=8 --row-mt=1 --color-primaries=bt709 --transfer-characteristics=bt709 --matrix-coefficients=bt709 --ivf -o master.ivf
```

12-bit needs profile 2, but do not pass `--profile=2` here: with 12-bit 4:4:4 Y4M that makes aomenc 3.15.3 fail with 'Failed to set chroma subsampling x' (checked locally), while leaving it out lets aomenc raise the profile to 2 itself. A single pass because the input is a stdin pipe. 48 is the largest lookahead 3.15.3 accepts. QM, chroma delta-q and tune=ssim are Codec Wiki's efficiency picks. Change the CICP flags to match the source.

Sources: [source](https://en.wikipedia.org/wiki/AV1), [source](https://codecs.wiki/docs/encoders/aomenc), [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/lookahead.h), [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/apps/aomenc.c)

### HDR10 PQ 10-bit 4:2:2 intermediate

**Goal:** HDR10 encode that keeps 4:2:2 chroma · **Content:** HDR live action

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=20 --bit-depth=10 --input-bit-depth=10 --profile=2 --tune=ssim --enable-qm=1 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --threads=8 --row-mt=1 --tile-columns=2 --tile-rows=1 --ivf -o hdr10.ivf
```

4:2:2 needs the Professional profile; an explicit `--profile=2` works here at 10-bit (checked locally). PQ/BT.2020 CICP is signaled in-stream. Tile settings follow Codec Wiki's 2160p advice. MaxCLL/MaxFALL and mastering display must be added afterwards with mkvmerge, because aomenc has no flags for them.

Sources: [source](https://en.wikipedia.org/wiki/AV1), [source](https://codecs.wiki/docs/encoders/aomenc), [source](https://mkvtoolnix.download/doc/mkvmerge.html), [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c)

### HLG 10-bit broadcast-style

**Goal:** HLG HDR that plays as SDR on non-HDR displays · **Content:** HLG live/broadcast

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=22 --bit-depth=10 --input-bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=hlg --matrix-coefficients=bt2020ncl --threads=8 --row-mt=1 --ivf -o hlg.ivf
```

aomenc's name for HLG is 'hlg'; 'arib-std-b67' is rejected. HLG does not need MDCV/CLL metadata to play correctly.

Sources: [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c)

### Heavy film grain with synthesis

**Goal:** Small files for grainy film without coding the grain · **Content:** heavy grain, old film, old anime

```bash
input.y4m --passes=2 --good --cpu-used=3 --end-usage=q --cq-level=24 --bit-depth=10 --tune=ssim --enable-qm=1 --deltaq-mode=0 --arnr-strength=4 --denoise-noise-level=8 --lag-in-frames=48 --threads=8 --row-mt=1 --ivf -o grain.ivf
```

Codec Wiki's grain level of 8, below its limit of 12. The default `--enable-dnl-denoising=1` denoises before coding. Codec Wiki instead turns that off (0), which codes the real grain and layers synthetic grain on top; the sources disagree. Two passes work here because the input is a file.

Sources: [source](https://codecs.wiki/docs/encoders/aomenc), [source](https://forum.doom9.org/archive/index.php/t-184143.html)

### Camera noise via photon-noise table (HDR)

**Goal:** Replace sensor noise with matching synthetic noise in a PQ encode · **Content:** low light, digital cinema, HDR

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=22 --bit-depth=10 --input-bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --film-grain-table=noise.tbl --ivf -o out.ivf
```

Make noise.tbl with libaom's photon_noise_table example (built from source; Homebrew does not ship it): photon_noise_table `--width=3840` `--height=2160` `--iso=<ISO>` `-t` smpte2084 `-o` noise.tbl. Feed a denoised source: the table adds synthetic noise but aomenc does not remove the existing noise unless `--denoise-noise-level` is set.

Sources: [source](https://aomedia.googlesource.com/aom/+/refs/heads/main/examples/photon_noise_table.c)

### Anime / 2D animation

**Goal:** Clean line art and flat colors · **Content:** anime, cartoons

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=24 --bit-depth=10 --tune=ssim --enable-qm=1 --deltaq-mode=0 --arnr-strength=1 --sb-size=dynamic --lag-in-frames=48 --ivf -o anime.ivf
```

Codec Wiki suggests arnr-strength 1 for animation, so the temporal filter does not smear lines. 10-bit prevents banding in flat gradients.

Sources: [source](https://codecs.wiki/docs/encoders/aomenc)

### Screen recording / UI

**Goal:** Sharp text and UI at small size · **Content:** screen content, game UI

```bash
- --passes=1 --good --cpu-used=4 --end-usage=q --cq-level=26 --tune-content=screen --enable-palette=1 --enable-intrabc=1 --ivf -o screen.ivf
```

tune-content=screen turns on palette and intra block copy for every frame instead of relying on detection.

Sources: [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.c)

### Codec Wiki chunked (Av1an) baseline

**Goal:** Efficient parallel encoding in chunks · **Content:** general

```bash
--bit-depth=10 --cpu-used=4 --end-usage=q --cq-level=24 --threads=2 --tile-columns=0 --tile-rows=0 --lag-in-frames=48 --tune=ssim --enable-keyframe-filtering=1 --disable-kf --kf-max-dist=9999 --enable-qm=1 --deltaq-mode=0 --aq-mode=0 --enable-fwd-kf=0 --arnr-strength=1 --sb-size=dynamic --enable-dnl-denoising=0 --denoise-noise-level=8
```

Codec Wiki's line for Av1an, with lag-in-frames lowered from its 64 to 48 because 3.15.3 rejects 64. Keyframe options assume Av1an places scene-cut keyframes.

Sources: [source](https://codecs.wiki/docs/encoders/aomenc), [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/lookahead.h)

## All options

197 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--help`](#help) | flag | not stated | Prints the option list and exits. |  | ✓ |
| [`--cfg`](#cfg) | file path | not stated | Reads encoder settings from a config file instead of, or in addition to, command-line flags. |  |  |
| [`--output`](#output) | file path | not stated | Output file. |  | ✓ |
| [`--codec`](#codec) | av1 (only encoder in this build) | av1 | Chooses the encoder. |  |  |
| [`--limit`](#limit) | frame count | not stated | Stops after encoding this many input frames. |  |  |
| [`--skip`](#skip) | frame count | not stated | Skips this many frames at the start of the input before encoding. |  |  |
| [`--webm`](#webm) | flag | WebM is the default when WebM IO is enabled | Writes a WebM container. | ✓ |  |
| [`--ivf`](#ivf) | flag | not stated | Writes an IVF container, a minimal AV1 frame wrapper that mkvmerge, MP4Box and ffmpeg can remux. |  | ✓ |
| [`--obu`](#obu) | flag | not stated | Writes a raw OBU (Section 5) stream with no container. |  |  |
| [`--nv12`](#nv12) | flag | not stated | Treats raw input as NV12 (interleaved 4:2:0 chroma). |  |  |
| [`--yv12`](#yv12) | flag | not stated | Treats raw input as YV12 (planar 4:2:0 with V before U). |  |  |
| [`--i420`](#i420) | flag | I420 is the default | Treats raw input as I420 (planar 4:2:0). |  |  |
| [`--i422`](#i422) | flag | not stated | Treats raw input as I422 (planar 4:2:2). | ✓ |  |
| [`--i444`](#i444) | flag | not stated | Treats raw input as I444 (planar 4:4:4). | ✓ |  |
| [`--width`](#width) | pixels | not stated | Frame width for raw input. |  |  |
| [`--height`](#height) | pixels | not stated | Frame height for raw input. |  |  |
| [`--forced_max_frame_width`](#forced-max-frame-width) | pixels | not stated | Writes a larger maximum frame width into the sequence header than the actual frames use, so the resolution can grow later in the stream. |  |  |
| [`--forced_max_frame_height`](#forced-max-frame-height) | pixels | not stated | Height counterpart of `--forced_max_frame_width`. |  |  |
| [`--stereo-mode`](#stereo-mode) | mono, left-right, bottom-top, top-bottom, right-left | not stated | Labels the WebM output as stereoscopic 3D with the given frame packing. |  |  |
| [`--timebase`](#timebase) | fraction, e.g. 1/1000 | 1/1000 | Sets the timestamp precision in the output. |  |  |
| [`--fps`](#fps) | rate/scale, e.g. 24000/1001 | not stated | Stream frame rate. |  |  |
| [`--input-bit-depth`](#input-bit-depth) | 8, 10, 12 | not stated | The actual bit depth of the input samples, which can differ from the coded depth (for example 8-bit input coded as 10-bit). | ✓ | ✓ |
| [`--annexb`](#annexb) | 0/1 | not stated | Writes the bitstream in Annex-B length-delimited format, normally together with `--obu`. |  |  |
| [`--input-chroma-subsampling-x`](#input-chroma-subsampling-x) | 0 or 1 | not stated | Horizontal chroma subsampling of raw input. | ✓ |  |
| [`--input-chroma-subsampling-y`](#input-chroma-subsampling-y) | 0 or 1 | not stated | Vertical chroma subsampling of raw input. | ✓ |  |

### Rate control

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--passes`](#passes) | 1/2/3 | not stated | Total number of encoding passes. |  | ✓ |
| [`--pass`](#pass) | 1/2/3 | not stated | Runs only one pass of a multi-pass encode, so passes can be split across separate invocations that share `--fpf`. |  |  |
| [`--fpf`](#fpf) | file path | not stated | Name of the first-pass statistics file that is written in pass 1 and read in pass 2. |  |  |
| [`--drop-frame`](#drop-frame) | buffer % threshold | not stated | Lets the encoder drop frames when the rate-control buffer falls below this fullness, to hold a bitrate. |  |  |
| [`--resize-mode`](#resize-mode) | 0: off (default), 1: fixed, 2: random, 3: dynamic | 0 | Encodes frames at a lower resolution, scaled back up after decoding (reference scaling). |  |  |
| [`--resize-denominator`](#resize-denominator) | 8..16 (8 means no scaling) | not stated | Scale factor for fixed resize mode. |  |  |
| [`--resize-kf-denominator`](#resize-kf-denominator) | 8..16 | not stated | Like `--resize-denominator`, but for keyframes. |  |  |
| [`--superres-mode`](#superres-mode) | 0: disabled (default), 1: fixed, 2: random, 3: qthresh, 4: auto | 0 | AV1 super-resolution. |  |  |
| [`--superres-denominator`](#superres-denominator) | 8..16 | not stated | Horizontal downscale factor (8 divided by this value) for fixed superres mode. |  |  |
| [`--superres-kf-denominator`](#superres-kf-denominator) | 8..16 | not stated | Superres denominator for keyframes. |  |  |
| [`--superres-qthresh`](#superres-qthresh) | qindex 1..63 | not stated | In qthresh superres mode, superres is used only for frames whose qindex is above this threshold. |  |  |
| [`--superres-kf-qthresh`](#superres-kf-qthresh) | qindex 1..63 | not stated | Keyframe version of `--superres-qthresh`. |  |  |
| [`--end-usage`](#end-usage) | vbr, cbr, cq, q | not stated | Rate-control mode. |  | ✓ |
| [`--target-bitrate`](#target-bitrate) | kbps | not stated | Target bitrate in kilobits per second for vbr, cbr and cq. |  |  |
| [`--min-q`](#min-q) | 0..63 | not stated | Best (lowest) quantizer that rate control may use. |  |  |
| [`--max-q`](#max-q) | 0..63 | not stated | Worst (highest) quantizer that rate control may use. |  |  |
| [`--undershoot-pct`](#undershoot-pct) | percent | not stated | How far below the target bitrate rate control may go before it reacts. |  |  |
| [`--overshoot-pct`](#overshoot-pct) | percent | not stated | How far above the target bitrate rate control may go. |  |  |
| [`--buf-sz`](#buf-sz) | milliseconds | not stated | Size of the decoder buffer model in milliseconds, used by CBR/VBR. |  |  |
| [`--buf-initial-sz`](#buf-initial-sz) | milliseconds | not stated | Buffer fullness the model assumes at the start. |  |  |
| [`--buf-optimal-sz`](#buf-optimal-sz) | milliseconds | not stated | Buffer level that rate control tries to stay near. |  |  |
| [`--bias-pct`](#bias-pct) | 0 (CBR-like) .. 100 (VBR-like) | not stated | In two-pass VBR, controls how far bits move from easy to hard sections. |  |  |
| [`--minsection-pct`](#minsection-pct) | percent of target | not stated | Lowest bitrate a GOP section may get in two-pass VBR, as a percentage of the target. |  |  |
| [`--maxsection-pct`](#maxsection-pct) | percent of target | not stated | Highest bitrate a GOP section may get in two-pass VBR. |  |  |
| [`--cq-level`](#cq-level) | 0..63 | not stated | Quality level for q and cq modes. |  | ✓ |
| [`--max-intra-rate`](#max-intra-rate) | percent of average frame | not stated | Caps keyframe size as a percentage of the average frame budget. |  |  |
| [`--max-inter-rate`](#max-inter-rate) | percent | not stated | Caps the size of inter frames as a percentage of the average. |  |  |
| [`--gf-cbr-boost`](#gf-cbr-boost) | percent | not stated | Extra bits for golden frames in CBR mode. |  |  |
| [`--lossless`](#lossless) | 0: false (default), 1: true | 0 | Mathematically lossless coding. | ✓ |  |
| [`--frame-boost`](#frame-boost) | 0: off (default), 1: on | 0 | Periodically lowers q on some frames to lift quality. |  |  |
| [`--min-cr`](#min-cr) | integer (value / 100 = minimum compression ratio) | 0 | Keeps each frame's compression ratio above a floor, mainly to satisfy level limits. |  |  |
| [`--vbr-corpus-complexity-lap`](#vbr-corpus-complexity-lap) | 0..10000 | 0 | Assumed average complexity per macroblock for single-pass VBR with lookahead, used to spread bits. |  |  |
| [`--enable-rate-guide-deltaq`](#enable-rate-guide-deltaq) | 0 (default off), 1 | 0 | Guides per-block delta-q from an external rate distribution map. |  |  |
| [`--rate-distribution-info`](#rate-distribution-info) | file path | not stated | Input file with the rate distribution map for `--enable-rate-guide-deltaq`. |  |  |
| [`--two-pass-output`](#two-pass-output) | file path | not stated | In three-pass encoding, where the output of the first two passes goes. |  |  |
| [`--second-pass-log`](#second-pass-log) | file path | not stated | Log file written by the second pass, used by the third pass. |  |  |
| [`--sb-qp-sweep`](#sb-qp-sweep) | 0/1 | not stated | Tries several qp values per superblock at a fixed lambda and keeps the cheapest in rate-distortion terms. |  |  |

### Speed and presets

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--good`](#good) | flag | not stated | Selects good-quality (offline) mode, the normal mode for file encoding. |  | ✓ |
| [`--rt`](#rt) | flag | not stated | Selects realtime mode for live or low-latency encoding. |  |  |
| [`--allintra`](#allintra) | flag | not stated | Selects all-intra mode, where every frame is a keyframe. |  |  |
| [`--usage`](#usage) | 0: good, 1: rt, 2: allintra | not stated | Chooses the usage profile by number. |  |  |
| [`--cpu-used`](#cpu-used) | 0..6 in good mode, 5..12 in realtime mode, 0..9 in all intra mode | not stated | Main speed/efficiency control. |  | ✓ |
| [`--coeff-cost-upd-freq`](#coeff-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off | not stated | How often coefficient cost tables are refreshed during the search. |  |  |
| [`--mode-cost-upd-freq`](#mode-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off | not stated | Update frequency for mode cost tables. |  |  |
| [`--mv-cost-upd-freq`](#mv-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off | not stated | Update frequency for motion-vector cost tables. |  |  |
| [`--dv-cost-upd-freq`](#dv-cost-upd-freq) | 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off | not stated | Update frequency for displacement-vector (intra block copy) cost tables. |  |  |
| [`--auto-intra-tools-off`](#auto-intra-tools-off) | 0/1 | not stated | In all-intra mode, automatically turns off some intra tools where they are unlikely to help. |  |  |

### GOP and keyframes

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--lag-in-frames`](#lag-in-frames) | 0..48 (library limit MAX_LAG_BUFFERS) | not stated | How many future frames the encoder buffers before deciding on the current one. |  |  |
| [`--enable-fwd-kf`](#enable-fwd-kf) | 0/1 | not stated | Allows forward keyframes. |  |  |
| [`--kf-min-dist`](#kf-min-dist) | frames | not stated | Minimum spacing between keyframes. |  |  |
| [`--kf-max-dist`](#kf-max-dist) | frames | not stated | Maximum spacing between keyframes, which limits how far a player may need to seek back. |  |  |
| [`--disable-kf`](#disable-kf) | flag | not stated | Turns off automatic keyframe placement. |  |  |
| [`--sframe-dist`](#sframe-dist) | frames | not stated | Interval for switch frames (S-frames), which let adaptive-streaming clients switch between renditions. |  |  |
| [`--sframe-mode`](#sframe-mode) | 1..2 | not stated | Chooses how S-frames are inserted. |  |  |
| [`--auto-alt-ref`](#auto-alt-ref) | 0/1 | not stated | Allows hidden alternate reference frames: filtered future frames that many frames predict from. |  |  |
| [`--enable-order-hint`](#enable-order-hint) | 0: false, 1: true (default) | 1 | Writes frame order hints so the decoder knows frame distances. |  |  |
| [`--enable-overlay`](#enable-overlay) | 0: false, 1: true (default) | 1 | Codes overlay frames, which show the real frame at an alt-ref's position after the filtered alt-ref. |  |  |
| [`--min-gf-interval`](#min-gf-interval) | frames (default 0 = built-in behavior) | 0 | Minimum golden-frame / alt-ref group length. |  |  |
| [`--max-gf-interval`](#max-gf-interval) | frames (default 0 = built-in behavior) | 0 | Maximum golden-frame / alt-ref group length. |  |  |
| [`--gf-min-pyr-height`](#gf-min-pyr-height) | 0 (default) to 5 | 0 | Minimum depth of the hierarchical frame pyramid within a GF group. |  |  |
| [`--gf-max-pyr-height`](#gf-max-pyr-height) | 0 to 5 (default) | 5 | Maximum depth of the hierarchical frame pyramid. |  |  |
| [`--fwd-kf-dist`](#fwd-kf-dist) | frames (-1 = no repetitive forward keyframes) | -1 | Places forward keyframes at a fixed interval. |  |  |
| [`--kf-max-pyr-height`](#kf-max-pyr-height) | -1 to 5 | -1 | Caps the pyramid depth for the GOP that starts at a keyframe. |  |  |

### Psychovisual and tuning

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--tune`](#tune) | psnr, ssim, vmaf_with_preprocessing, vmaf_without_preprocessing, vmaf, vmaf_neg, butteraugli, vmaf_saliency_map, iq, ssimulacra2 | not stated | Chooses which quality metric rate-distortion decisions optimize for. | ✓ | ✓ |
| [`--enable-chroma-deltaq`](#enable-chroma-deltaq) | 0: false (default), 1: true | 0 | Lets the encoder use a different quantizer offset for chroma than for luma, which usually gives chroma more bits. | ✓ | ✓ |
| [`--enable-qm`](#enable-qm) | 0: false (default), 1: true | 0 | Uses frequency-weighted quantization matrices, which spend fewer bits on high frequencies the eye notices less. | ✓ | ✓ |
| [`--qm-min`](#qm-min) | 0..15 | 5 (4 for all intra mode) | Lowest (steepest) QM flatness level the encoder may pick. |  |  |
| [`--qm-max`](#qm-max) | 0..15 | 9 (10 for all intra mode) | Highest (flattest) QM level the encoder may pick. |  |  |
| [`--aq-mode`](#aq-mode) | 0: off (default), 1: variance 2: complexity, 3: cyclic refresh | 0 | Segment-based adaptive quantization. |  |  |
| [`--deltaq-mode`](#deltaq-mode) | 0: off, 1: deltaq objective (default), 2: deltaq placeholder, 3: key frame visual quality, 4: user rating based visual quality optimization, 5: HDR video, 6: Variance Boost | 1 | Changes the quantizer per superblock. | ✓ | ✓ |
| [`--deltaq-strength`](#deltaq-strength) | percent (library allows 0..1000) | not stated | Scales how strong delta-q modulation is for modes 4 and 6. |  |  |
| [`--tune-content`](#tune-content) | default, screen, film | not stated | Tells the encoder what kind of content it has. |  | ✓ |
| [`--vmaf-model-path`](#vmaf-model-path) | file path | not stated | VMAF model file used by the vmaf tune modes. |  |  |
| [`--dist-metric`](#dist-metric) | psnr, qm-psnr | not stated | Distortion measure used inside block decisions. |  |  |
| [`--screen-detection-mode`](#screen-detection-mode) | 1: standard (default in good quality and realtime modes), 2: anti-aliased text and graphics aware (default in all intra mode) | 1 in good quality and realtime modes; 2 in all intra mode | Chooses how automatic screen-content detection works. |  |  |
| [`--sharpness`](#sharpness) | 0..7 | 0 | Pushes rate-distortion decisions toward keeping sharp coefficients. |  |  |
| [`--enable-adaptive-sharpness`](#enable-adaptive-sharpness) | 0: disabled (default), 1: enabled | 0 | Varies sharpness with frame quantizer to reduce blocking at low and medium quality. |  |  |

### Film grain and noise

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-keyframe-filtering`](#enable-keyframe-filtering) | 0: no filter, 1: filter without overlay (default), 2: filter with overlay - experimental, may break random access in players | 1 | Applies the temporal (ARNR) filter to keyframes, removing noise before coding them. |  |  |
| [`--arnr-maxframes`](#arnr-maxframes) | 0..15 | not stated | How many neighboring frames the alt-ref temporal filter averages. |  |  |
| [`--arnr-strength`](#arnr-strength) | 0..6 | not stated | Strength of the alt-ref temporal filter. |  | ✓ |
| [`--noise-sensitivity`](#noise-sensitivity) | frames to blur (library allows 0..6) | not stated | Turns on the temporal denoiser (luma only) used by realtime and SVC encoding. |  |  |
| [`--film-grain-test`](#film-grain-test) | 0: none (default), 1: test-1 2: test-2, ... 16: test-16 | 0 | Applies one of 16 built-in test grain parameter sets. |  |  |
| [`--film-grain-table`](#film-grain-table) | file path | not stated | Loads film grain parameters from a table file, from libaom's noise_model or photon_noise_table tools or another estimator, instead of estimating grain internally. | ✓ | ✓ |
| [`--denoise-noise-level`](#denoise-noise-level) | 0 (don't denoise) to 50 | not stated | Turns on libaom's internal noise model. | ✓ | ✓ |
| [`--denoise-block-size`](#denoise-block-size) | pixels | 32 | Block size the noise model uses to find flat areas and estimate grain. |  |  |
| [`--enable-dnl-denoising`](#enable-dnl-denoising) | 0: false, 1: true (default) | 1 | Controls whether the frame is actually denoised when denoise-noise-level is on. |  | ✓ |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--profile`](#profile) | 0 (Main), 1 (High), 2 (Professional) | not stated | AV1 bitstream profile. | ✓ | ✓ |
| [`--bit-depth`](#bit-depth) | 8, 10, 12 | not stated | Bit depth of the coded stream. | ✓ | ✓ |
| [`--monochrome`](#monochrome) | flag | not stated | Encodes luma only (4:0:0) and drops the chroma planes. |  |  |
| [`--color-primaries`](#color-primaries) | bt709, unspecified, bt601, bt470m, bt470bg, smpte240, film, bt2020, xyz, smpte431, smpte432, ebu3213 | not stated | CICP color primaries written to the sequence header. | ✓ | ✓ |
| [`--transfer-characteristics`](#transfer-characteristics) | unspecified, bt709, bt470m, bt470bg, bt601, smpte240, lin, log100, log100sq10, iec61966, bt1361, srgb, bt2020-10bit, bt2020-12bit, smpte2084, hlg, smpte428 | not stated | CICP transfer function written to the sequence header. | ✓ | ✓ |
| [`--matrix-coefficients`](#matrix-coefficients) | identity, bt709, unspecified, fcc73, bt470bg, bt601, smpte240, ycgco, bt2020ncl, bt2020cl, smpte2085, chromncl, chromcl, ictcp, ipt-c2, ycgco-re, ycgco-ro | not stated | CICP matrix coefficients (how Y'CbCr relates to R'G'B'), written to the sequence header. | ✓ | ✓ |
| [`--chroma-sample-position`](#chroma-sample-position) | unknown, vertical, colocated | not stated | Signals where 4:2:0 chroma samples sit. | ✓ |  |
| [`--validate-hbd-input`](#validate-hbd-input) | 0: disabled, 1: enabled (default) | 1 | For high-bit-depth encodes, checks that every input sample is valid for the chosen bit depth. | ✓ |  |

### Analysis and motion search

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--static-thresh`](#static-thresh) | threshold | not stated | Blocks whose motion error is below this threshold are skipped as static. |  |  |
| [`--enable-tpl-model`](#enable-tpl-model) | 0: off, 1: backward source based | not stated | Temporal dependency model. |  |  |
| [`--enable-dual-filter`](#enable-dual-filter) | 0: false, 1: true (default) | 1 | Allows separate horizontal and vertical interpolation filters for motion compensation. |  |  |
| [`--enable-intra-edge-filter`](#enable-intra-edge-filter) | 0: false, 1: true (default) | 1 | Smooths the neighboring edge pixels used for directional intra prediction. |  |  |
| [`--enable-dist-wtd-comp`](#enable-dist-wtd-comp) | 0: false, 1: true (default) | 1 | Distance-weighted compound prediction, which weights two references by their temporal distance. |  |  |
| [`--enable-masked-comp`](#enable-masked-comp) | 0: false, 1: true (default) | 1 | Master switch for masked compound prediction (wedge and difference-weighted). |  |  |
| [`--enable-onesided-comp`](#enable-onesided-comp) | 0: false, 1: true (default) | 1 | Allows compound prediction from two references on the same temporal side. |  |  |
| [`--enable-interintra-comp`](#enable-interintra-comp) | 0: false, 1: true (default) | 1 | Blends an inter prediction with an intra prediction inside one block. |  |  |
| [`--enable-smooth-interintra`](#enable-smooth-interintra) | 0: false, 1: true (default) | 1 | Smooth-blend variant of inter-intra prediction. |  |  |
| [`--enable-diff-wtd-comp`](#enable-diff-wtd-comp) | 0: false, 1: true (default) | 1 | Compound prediction weighted by the difference between the two predictors. |  |  |
| [`--enable-interinter-wedge`](#enable-interinter-wedge) | 0: false, 1: true (default) | 1 | Wedge-shaped masks that combine two inter predictions. |  |  |
| [`--enable-interintra-wedge`](#enable-interintra-wedge) | 0: false, 1: true (default) | 1 | Wedge masks for inter-intra blending. |  |  |
| [`--enable-global-motion`](#enable-global-motion) | 0: false, 1: true (default) | 1 | Frame-level global motion models (pans, zooms, rotations) for camera movement. |  |  |
| [`--enable-warped-motion`](#enable-warped-motion) | 0: false, 1: true (default) | 1 | Local warped motion, which fits affine motion per block from neighboring motion vectors. |  |  |
| [`--enable-filter-intra`](#enable-filter-intra) | 0: false, 1: true (default) | 1 | Recursive filter-based intra prediction modes for textured blocks. |  |  |
| [`--enable-smooth-intra`](#enable-smooth-intra) | 0: false, 1: true (default) | 1 | Smooth intra prediction modes for gradients. | ✓ |  |
| [`--enable-paeth-intra`](#enable-paeth-intra) | 0: false, 1: true (default) | 1 | Paeth intra predictor, which picks the closest of the top, left and top-left neighbors. |  |  |
| [`--enable-cfl-intra`](#enable-cfl-intra) | 0: false, 1: true (default) | 1 | Chroma-from-luma prediction, which predicts chroma from the reconstructed luma. | ✓ |  |
| [`--enable-diagonal-intra`](#enable-diagonal-intra) | 0: false, 1: true (default) | 1 | Diagonal directional intra modes (D45 to D203). |  |  |
| [`--enable-obmc`](#enable-obmc) | 0: false, 1: true (default) | 1 | Overlapped block motion compensation, which blends neighboring block motion to soften block edges. |  |  |
| [`--enable-palette`](#enable-palette) | 0: false, 1: true (default) | 1 | Palette prediction mode for blocks with few distinct colors, such as UI, text and flat animation. |  |  |
| [`--enable-intrabc`](#enable-intrabc) | 0: false, 1: true (default) | 1 | Intra block copy, which copies already-coded areas of the same frame. |  |  |
| [`--enable-angle-delta`](#enable-angle-delta) | 0: false, 1: true (default) | 1 | Fine angle steps for directional intra prediction. |  |  |
| [`--max-reference-frames`](#max-reference-frames) | 3 to 7 (default) | 7 | Maximum number of reference frames each frame may use. |  |  |
| [`--reduced-reference-set`](#reduced-reference-set) | 0: off (default), 1: on | 0 | Restricts the single and compound reference combinations the encoder searches. |  |  |
| [`--enable-ref-frame-mvs`](#enable-ref-frame-mvs) | 0/1 | 1 | Temporal motion-vector prediction from reference frames. |  |  |
| [`--enable-directional-intra`](#enable-directional-intra) | 0: false, 1: true (default) | 1 | Master switch for directional intra prediction modes. |  |  |

### Partitioning and transforms

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-rect-partitions`](#enable-rect-partitions) | 0: false, 1: true (default) | 1 | Allows rectangular block splits (horizontal and vertical halves). |  |  |
| [`--enable-ab-partitions`](#enable-ab-partitions) | 0: false, 1: true (default) | 1 | Allows AB partitions: three-way splits that combine a half with two quarters. |  |  |
| [`--enable-1to4-partitions`](#enable-1to4-partitions) | 0: false, 1: true (default) | 1 | Allows 1:4 and 4:1 strip partitions. |  |  |
| [`--min-partition-size`](#min-partition-size) | 4:4x4, 8:8x8, 16:16x16, 32:32x32, 64:64x64, 128:128x128 | not stated | Smallest block size the partition search may use. |  |  |
| [`--max-partition-size`](#max-partition-size) | 4:4x4, 8:8x8, 16:16x16, 32:32x32, 64:64x64, 128:128x128 | not stated | Largest block size the partition search may use. |  |  |
| [`--enable-tx64`](#enable-tx64) | 0: false, 1: true (default) | 1 | Allows 64-point transforms for large smooth areas. |  |  |
| [`--enable-flip-idtx`](#enable-flip-idtx) | 0: false, 1: true (default) | 1 | Allows the extended transform types: flipped ADST, identity and one-dimensional transforms. |  |  |
| [`--enable-rect-tx`](#enable-rect-tx) | 0: false, 1: true (default) | 1 | Allows rectangular transform sizes. |  |  |
| [`--disable-trellis-quant`](#disable-trellis-quant) | 0: false 1: true 2: true for rd search 3: true for estimate yrd search (default) | 3 | Controls where trellis (rate-distortion-optimized) coefficient quantization is skipped. |  |  |
| [`--reduced-tx-type-set`](#reduced-tx-type-set) | 0/1 | not stated | Uses a smaller set of transform types, signaled in the bitstream. |  |  |
| [`--use-intra-dct-only`](#use-intra-dct-only) | 0/1 | not stated | Restricts intra blocks to DCT transforms. |  |  |
| [`--use-inter-dct-only`](#use-inter-dct-only) | 0/1 | not stated | Restricts inter blocks to DCT transforms. |  |  |
| [`--use-intra-default-tx-only`](#use-intra-default-tx-only) | 0/1 | not stated | Uses only the default transform type for each intra mode, with no search. |  |  |
| [`--quant-b-adapt`](#quant-b-adapt) | 0/1 | not stated | Uses an adaptive variant of the block quantizer. |  |  |
| [`--sb-size`](#sb-size) | dynamic, 64, 128 | not stated | Superblock size. |  |  |
| [`--enable-tx-size-search`](#enable-tx-size-search) | 0: false, 1: true (default) | 1 | Searches for the best transform size per block. |  |  |

### In-loop filters

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--enable-cdef`](#enable-cdef) | 0: false, 1: true (default), 2: disable for non-reference frames, 3: enable adaptively based on frame qindex | 1 | Constrained Directional Enhancement Filter, an in-loop deringing filter that follows edge direction. |  |  |
| [`--enable-restoration`](#enable-restoration) | 0: false (default in realtime mode), 1: true (default in non-realtime mode) | 1 in non-realtime mode | Loop restoration (Wiener and self-guided filters) that restores detail after deblocking and CDEF. |  |  |
| [`--delta-lf-mode`](#delta-lf-mode) | 0: off (default), 1: on | 0 | Lets deblocking filter strength vary per superblock along with delta-q. |  |  |
| [`--loopfilter-control`](#loopfilter-control) | 0: Loopfilter disabled for all frames, 1: Enable loopfilter for all frames (default), 2: Disable loopfilter for non-reference frames, 3: Disable loopfilter for frames with low motion | 1 | Controls when the deblocking filter runs. |  |  |

### Threading and performance

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--threads`](#threads) | thread count | not stated | Caps the number of worker threads. |  | ✓ |
| [`--use-16bit-internal`](#use-16bit-internal) | flag | not stated | Forces the high-bit-depth (16-bit) internal pipeline even for 8-bit encodes. | ✓ |  |
| [`--row-mt`](#row-mt) | 0: off, 1: on (default) | 1 | Row-based multithreading inside each tile. |  | ✓ |
| [`--fp-mt`](#fp-mt) | 0: off (default), 1: on | 0 | Frame-parallel multithreading: encodes several frames of a GOP at once for more speed on many-core CPUs. |  |  |
| [`--tile-columns`](#tile-columns) | log2 count, 0..6 | not stated | Splits the frame into 2 to the power N tile columns, which can be encoded and decoded in parallel at a small efficiency cost. |  |  |
| [`--tile-rows`](#tile-rows) | log2 count, 0..6 | not stated | Splits the frame into 2 to the power N tile rows. |  |  |
| [`--num-tile-groups`](#num-tile-groups) | count | 1 | Maximum number of tile groups (OBU packets carrying tiles) per frame. |  |  |
| [`--mtu-size`](#mtu-size) | bytes (0 = no MTU targeting) | 0 | Sizes tile groups to fit a network MTU. |  |  |
| [`--auto-tiles`](#auto-tiles) | 0: false (default), 1: true | 0 | Lets the encoder pick the tile layout from resolution and thread count. |  |  |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--debug`](#debug) | flag | not stated | Debug mode. |  |  |
| [`--quiet`](#quiet) | flag | not stated | Stops aomenc printing per-frame progress. |  |  |
| [`--verbose`](#verbose) | flag | not stated | Prints the full encoder configuration before encoding. | ✓ |  |
| [`--psnr`](#psnr) | 0: disable, 1: PSNR at input bit-depth (default), 2: PSNR at stream bit-depth | 1 when given without a value | Shows PSNR in the status line. |  |  |
| [`--q-hist`](#q-hist) | n-buckets | not stated | Prints a histogram of the quantizers used, grouped into the given number of buckets. |  |  |
| [`--rate-hist`](#rate-hist) | n-buckets | not stated | Prints a histogram of per-frame bitrates. |  |  |
| [`--disable-warnings`](#disable-warnings) | flag | not stated | Hides the warnings about settings that may be wrong. |  |  |
| [`--disable-warning-prompt`](#disable-warning-prompt) | flag | not stated | Still prints warnings but does not stop to ask whether to continue. |  |  |
| [`--test-decode`](#test-decode) | off, fatal, warn | not stated | Decodes each frame while encoding and checks that it matches the encoder's own reconstruction. |  |  |

### Other

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--global-error-resilient`](#global-error-resilient) | 0/1 | not stated | Turns on error-resilience features for the whole stream, so decoding can recover after lost packets. |  |  |
| [`--large-scale-tile`](#large-scale-tile) | 0: off (default), 1: on (ivf output only) | 0 | Large-scale tile mode for special uses such as light-field or VR tile streaming, where single tiles are decoded independently. |  |  |
| [`--full-still-picture-hdr`](#full-still-picture-hdr) | flag | not stated | Writes the full sequence header rather than the reduced one for still pictures. |  |  |
| [`--force-video-mode`](#force-video-mode) | 0: false (default), 1: true | 0 | Uses video coding settings even when the input is a single frame. |  |  |
| [`--frame-parallel`](#frame-parallel) | 0: false (default), 1: true | 0 | Turns on bitstream features that let decoders work on frames in parallel, mainly by turning off backward context adaptation. |  |  |
| [`--error-resilient`](#error-resilient) | 0: false (default), 1: true | 0 | Per-frame error-resilience mode for lossy networks. |  |  |
| [`--cdf-update-mode`](#cdf-update-mode) | 0: no CDF update, 1: update CDF on all frames (default), 2: selectively update CDF on some frames | 1 | Controls whether the entropy coder's probability tables adapt from frame to frame. |  |  |
| [`--timing-info`](#timing-info) | unspecified, constant, model | not stated | Writes timing info, and optionally a decoder model, into the bitstream. |  |  |
| [`--target-seq-level-idx`](#target-seq-level-idx) | ABxy: AB = operating point index, xy = level index (e.g. 0 = level 2.0 for OP 0, 1019 = level 6.3 for OP 10) | not stated | Asks the encoder to stay within a given AV1 level for an operating point, which limits bitrate, tiles and picture size for device compatibility. |  |  |
| [`--set-tier-mask`](#set-tier-mask) | 32-bit mask; bit 0 = Main tier (default), 1 = High tier | 0 (Main tier) | Chooses Main or High tier for each of the 32 operating points. |  |  |
| [`--partition-info-path`](#partition-info-path) | path | not stated | Folder where partition decisions are read or written, for research and analysis tools. |  |  |
| [`--enable-low-complexity-decode`](#enable-low-complexity-decode) | 0: false (default), 1: true | 0 | Picks tools that are cheaper to decode, for weak playback devices. |  |  |
| [`--strict-level-conformance`](#strict-level-conformance) | 0/1 | not stated | With 1, the encoder stops instead of producing a stream that breaks the target level. |  |  |

## Options in detail

### Input and output

<a id="help"></a>

#### `--help`

**Type:** bool · **Values:** flag · **Default:** not stated

Prints the option list and exits.

**In Lumora:** Lumora's Packager runs aomenc `--help` to check that the tool is installed.

<a id="cfg"></a>

#### `--cfg` (also `-c`)

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Reads encoder settings from a config file instead of, or in addition to, command-line flags.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file path · **Default:** not stated

Output file. The container follows the extension: .ivf gives IVF, .obu gives raw OBUs, and anything else gives WebM unless another output flag overrides it.

**In Lumora:** Used as `-o` {out} with an .ivf extension.

<a id="codec"></a>

#### `--codec`

**Type:** string · **Values:** av1 (only encoder in this build) · **Default:** av1 · advanced

Chooses the encoder. This build contains only the AV1 encoder.

<a id="limit"></a>

#### `--limit`

**Type:** int · **Values:** frame count · **Default:** not stated

Stops after encoding this many input frames.

**Notes:** Handy for quick test encodes.

<a id="skip"></a>

#### `--skip`

**Type:** int · **Values:** frame count · **Default:** not stated

Skips this many frames at the start of the input before encoding.

<a id="webm"></a>

#### `--webm`

**Type:** bool · **Values:** flag · **Default:** WebM is the default when WebM IO is enabled · **HDR-relevant**

Writes a WebM container.

**Notes:** aomenc's WebM writer does not write a Colour element or HDR mastering metadata. The bitstream CICP is still present.

<a id="ivf"></a>

#### `--ivf`

**Type:** bool · **Values:** flag · **Default:** not stated

Writes an IVF container, a minimal AV1 frame wrapper that mkvmerge, MP4Box and ffmpeg can remux.

**In Lumora:** Always passed; Lumora remuxes the IVF afterwards.

<a id="obu"></a>

#### `--obu`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Writes a raw OBU (Section 5) stream with no container.

**Notes:** Combine with `--annexb=1` for Annex-B length-delimited output.

<a id="nv12"></a>

#### `--nv12`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Treats raw input as NV12 (interleaved 4:2:0 chroma).

**Notes:** Raw-input only; Y4M input carries its own format.

<a id="yv12"></a>

#### `--yv12`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Treats raw input as YV12 (planar 4:2:0 with V before U).

**Notes:** The 3.14.0 changelog deprecates the internal AOMYV12 image format; plain YV12 is still listed.

<a id="i420"></a>

#### `--i420`

**Type:** bool · **Values:** flag · **Default:** I420 is the default · advanced

Treats raw input as I420 (planar 4:2:0).

<a id="i422"></a>

#### `--i422`

**Type:** bool · **Values:** flag · **Default:** not stated · **HDR-relevant**

Treats raw input as I422 (planar 4:2:2). AV1 needs profile 2 for 4:2:2.

**Notes:** Raw-input only; Y4M 4:2:2 is detected automatically.

<a id="i444"></a>

#### `--i444`

**Type:** bool · **Values:** flag · **Default:** not stated · **HDR-relevant**

Treats raw input as I444 (planar 4:4:4). AV1 needs profile 1, or profile 2 at 12-bit.

<a id="width"></a>

#### `--width` (also `-w`)

**Type:** int · **Values:** pixels · **Default:** not stated

Frame width for raw input. Y4M input supplies this itself.

<a id="height"></a>

#### `--height` (also `-h`)

**Type:** int · **Values:** pixels · **Default:** not stated

Frame height for raw input.

**Notes:** The short form is `-h`, not help. Use `--help` to get help.

<a id="forced-max-frame-width"></a>

#### `--forced_max_frame_width`

**Type:** int · **Values:** pixels · **Default:** not stated · advanced

Writes a larger maximum frame width into the sequence header than the actual frames use, so the resolution can grow later in the stream.

**Effect:** quality none · speed none · size negligible

**Notes:** Spelled with underscores, unlike most flags.

<a id="forced-max-frame-height"></a>

#### `--forced_max_frame_height`

**Type:** int · **Values:** pixels · **Default:** not stated · advanced

Height counterpart of `--forced_max_frame_width`.

**Effect:** quality none · speed none · size negligible

<a id="stereo-mode"></a>

#### `--stereo-mode`

**Type:** enum · **Values:** mono, left-right, bottom-top, top-bottom, right-left · **Default:** not stated · advanced

Labels the WebM output as stereoscopic 3D with the given frame packing. Only affects WebM metadata.

<a id="timebase"></a>

#### `--timebase`

**Type:** string · **Values:** fraction, e.g. 1/1000 · **Default:** 1/1000 · advanced

Sets the timestamp precision in the output.

**Notes:** The help footer states the 1/1000 default.

<a id="fps"></a>

#### `--fps`

**Type:** string · **Values:** rate/scale, e.g. 24000/1001 · **Default:** not stated

Stream frame rate. Y4M input supplies it; raw input needs it.

**Effect:** quality slight (rate control uses it) · speed none · size affects bitrate-mode targets

<a id="input-bit-depth"></a>

#### `--input-bit-depth`

**Type:** int · **Values:** 8, 10, 12 · **Default:** not stated · **HDR-relevant**

The actual bit depth of the input samples, which can differ from the coded depth (for example 8-bit input coded as 10-bit).

**Effect:** quality none if correct · speed none · size none

**In Lumora:** Passed as `--input-bit-depth={bits}`, the same as `--bit-depth`. The Y4M Lumora pipes in must therefore be at that depth.

**Notes:** Y4M headers carry the depth. A mismatch can garble the picture or trip `--validate-hbd-input`.

<a id="annexb"></a>

#### `--annexb`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Writes the bitstream in Annex-B length-delimited format, normally together with `--obu`.

<a id="input-chroma-subsampling-x"></a>

#### `--input-chroma-subsampling-x`

**Type:** int · **Values:** 0 or 1 · **Default:** not stated · **HDR-relevant** · advanced

Horizontal chroma subsampling of raw input. Used to describe 12-bit raw input in profile 2.

**Notes:** For 12-bit Y4M input, aomenc takes subsampling from the Y4M header and ignores this.

<a id="input-chroma-subsampling-y"></a>

#### `--input-chroma-subsampling-y`

**Type:** int · **Values:** 0 or 1 · **Default:** not stated · **HDR-relevant** · advanced

Vertical chroma subsampling of raw input.

### Rate control

<a id="passes"></a>

#### `--passes` (also `-p`)

**Type:** int · **Values:** 1/2/3 · **Default:** not stated

Total number of encoding passes. Two passes collect first-pass statistics before the real encode. Three passes add an extra downscaled analysis pass.

**Effect:** quality + with 2 passes · speed - with more passes · size slightly smaller with 2 passes

| For | Value | Why | Source |
|---|---|---|---|
| piped/stdin input | `1` | Each pass reopens the input. Stdin cannot be rewound, so the second pass sees no frames and the output holds only an IVF header (reproduced locally on a synthetic clip). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/apps/aomenc.c) |
| archive | `2` | Codec Wiki says aomenc is designed around two passes to reach full efficiency. This needs a seekable input file. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Always `--passes=1` (once): Lumora pipes Y4M on stdin, and aomenc's default of two passes in good mode would reopen the input.

**Notes:** Listed twice in the help text (global and AV1 sections); it is one option. In aomenc.c the default is 2 for AV1 in good-quality mode. Realtime and all-intra modes force 1.

<a id="pass"></a>

#### `--pass`

**Type:** int · **Values:** 1/2/3 · **Default:** not stated · advanced

Runs only one pass of a multi-pass encode, so passes can be split across separate invocations that share `--fpf`.

<a id="fpf"></a>

#### `--fpf`

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Name of the first-pass statistics file that is written in pass 1 and read in pass 2.

**Notes:** Needed when running `--pass=1` and `--pass=2` as separate commands.

<a id="drop-frame"></a>

#### `--drop-frame`

**Type:** int · **Values:** buffer % threshold · **Default:** not stated · advanced

Lets the encoder drop frames when the rate-control buffer falls below this fullness, to hold a bitrate.

**Effect:** quality - (dropped frames) · speed none · size -

**Notes:** Realtime/CBR use. Library default is 0 (off).

<a id="resize-mode"></a>

#### `--resize-mode`

**Type:** int · **Values:** 0: off (default), 1: fixed, 2: random, 3: dynamic · **Default:** 0 · advanced

Encodes frames at a lower resolution, scaled back up after decoding (reference scaling). Dynamic mode reacts to bitrate pressure.

**Effect:** quality - detail · speed + · size -

**Notes:** Unverified: mode 2 (random) appears intended for testing.

<a id="resize-denominator"></a>

#### `--resize-denominator`

**Type:** int · **Values:** 8..16 (8 means no scaling) · **Default:** not stated · advanced

Scale factor for fixed resize mode. The frame is scaled by 8 divided by this value.

**Effect:** quality - · speed + · size -

**Notes:** The range comes from the library's scale numerator of 8; the help does not state it.

<a id="resize-kf-denominator"></a>

#### `--resize-kf-denominator`

**Type:** int · **Values:** 8..16 · **Default:** not stated · advanced

Like `--resize-denominator`, but for keyframes.

**Effect:** quality - · speed + · size -

<a id="superres-mode"></a>

#### `--superres-mode`

**Type:** int · **Values:** 0: disabled (default), 1: fixed, 2: random, 3: qthresh, 4: auto · **Default:** 0 · advanced

AV1 super-resolution. Frames are coded at reduced width, then upscaled horizontally and restored inside the loop. Can save bits at very low bitrates.

**Effect:** quality - at normal rates, ± at very low · speed ± · size -

**Notes:** Rarely worth it for high-quality encodes. Not supported with `--timing-info=model.`

<a id="superres-denominator"></a>

#### `--superres-denominator`

**Type:** int · **Values:** 8..16 · **Default:** not stated · advanced

Horizontal downscale factor (8 divided by this value) for fixed superres mode.

**Effect:** quality - · speed ± · size -

<a id="superres-kf-denominator"></a>

#### `--superres-kf-denominator`

**Type:** int · **Values:** 8..16 · **Default:** not stated · advanced

Superres denominator for keyframes.

**Effect:** quality - · speed ± · size -

<a id="superres-qthresh"></a>

#### `--superres-qthresh`

**Type:** int · **Values:** qindex 1..63 · **Default:** not stated · advanced

In qthresh superres mode, superres is used only for frames whose qindex is above this threshold.

**Effect:** quality ± · speed ± · size ±

**Notes:** Library default is 63.

<a id="superres-kf-qthresh"></a>

#### `--superres-kf-qthresh`

**Type:** int · **Values:** qindex 1..63 · **Default:** not stated · advanced

Keyframe version of `--superres-qthresh`.

**Effect:** quality ± · speed ± · size ±

**Notes:** Library default is 32.

<a id="end-usage"></a>

#### `--end-usage`

**Type:** enum · **Values:** vbr, cbr, cq, q · **Default:** not stated

Rate-control mode. q is constant quality (CRF-like), cq is quality-targeted under a bitrate cap, vbr targets an average bitrate and cbr a constant one.

**Effect:** quality depends on mode · speed none · size depends on mode

| For | Value | Why | Source |
|---|---|---|---|
| archive / general file encoding | `q` | Codec Wiki uses q with cq-level, which behaves like CRF in x264/x265. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| streaming/small size with a cap | `cq` | aomcx.h says cq-level is used in both cq and q modes. cq is the constrained-quality mode (aom_encoder.h) and also takes `--target-bitrate`; how hard that bitrate caps the result is not documented in the sources used here. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**In Lumora:** Always `--end-usage=q.`

**Notes:** Library default is vbr. The 3.15.0 changelog mentions a force-max-q option for VBR, which does not appear in this aomenc help.

<a id="target-bitrate"></a>

#### `--target-bitrate`

**Type:** int · **Values:** kbps · **Default:** not stated

Target bitrate in kilobits per second for vbr, cbr and cq.

**Effect:** quality + with higher · speed none · size sets size

**Notes:** Ignored in q mode. Library default is 256 kbps.

<a id="min-q"></a>

#### `--min-q`

**Type:** int · **Values:** 0..63 · **Default:** not stated · advanced

Best (lowest) quantizer that rate control may use.

**Effect:** quality caps the top quality · speed none · size caps the largest frames

**Notes:** Library default is 0.

<a id="max-q"></a>

#### `--max-q`

**Type:** int · **Values:** 0..63 · **Default:** not stated · advanced

Worst (highest) quantizer that rate control may use. Lowering it guards against ugly frames in hard scenes.

**Effect:** quality + floor · speed none · size + in hard scenes

**Notes:** Library default is 63.

<a id="undershoot-pct"></a>

#### `--undershoot-pct`

**Type:** int · **Values:** percent · **Default:** not stated · advanced

How far below the target bitrate rate control may go before it reacts.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 25.

<a id="overshoot-pct"></a>

#### `--overshoot-pct`

**Type:** int · **Values:** percent · **Default:** not stated · advanced

How far above the target bitrate rate control may go.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 25.

<a id="buf-sz"></a>

#### `--buf-sz`

**Type:** int · **Values:** milliseconds · **Default:** not stated · advanced

Size of the decoder buffer model in milliseconds, used by CBR/VBR.

**Effect:** quality + with larger · speed none · size ±

**Notes:** Library default is 6000.

<a id="buf-initial-sz"></a>

#### `--buf-initial-sz`

**Type:** int · **Values:** milliseconds · **Default:** not stated · advanced

Buffer fullness the model assumes at the start.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 4000.

<a id="buf-optimal-sz"></a>

#### `--buf-optimal-sz`

**Type:** int · **Values:** milliseconds · **Default:** not stated · advanced

Buffer level that rate control tries to stay near.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 5000.

<a id="bias-pct"></a>

#### `--bias-pct`

**Type:** int · **Values:** 0 (CBR-like) .. 100 (VBR-like) · **Default:** not stated · advanced

In two-pass VBR, controls how far bits move from easy to hard sections. 0 spreads bits evenly; 100 follows complexity fully.

**Effect:** quality ± consistency · speed none · size none (same average)

**Notes:** Library default is 50.

<a id="minsection-pct"></a>

#### `--minsection-pct`

**Type:** int · **Values:** percent of target · **Default:** not stated · advanced

Lowest bitrate a GOP section may get in two-pass VBR, as a percentage of the target.

**Effect:** quality + in easy scenes · speed none · size ±

**Notes:** Library default is 0.

<a id="maxsection-pct"></a>

#### `--maxsection-pct`

**Type:** int · **Values:** percent of target · **Default:** not stated · advanced

Highest bitrate a GOP section may get in two-pass VBR.

**Effect:** quality + in hard scenes when higher · speed none · size ±

**Notes:** Library default is 2000.

<a id="cq-level"></a>

#### `--cq-level`

**Type:** int · **Values:** 0..63 · **Default:** not stated

Quality level for q and cq modes. Lower values give higher quality and larger files.

**Effect:** quality + when lower · speed slightly slower when lower · size larger when lower

| For | Value | Why | Source |
|---|---|---|---|
| general starting point | `24` | Codec Wiki's example value. It behaves like CRF, so adjust by eye or by a target metric. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Passed as `--cq-level={quality}.` Lumora's target-quality search runs between 14 (best) and 40 (worst).

**Notes:** Library default is 10. It is ignored in vbr and cbr.

<a id="max-intra-rate"></a>

#### `--max-intra-rate`

**Type:** int · **Values:** percent of average frame · **Default:** not stated · advanced

Caps keyframe size as a percentage of the average frame budget. Mainly for CBR and streaming.

**Effect:** quality - on keyframes · speed none · size fewer spikes

**Notes:** Library default is 0 (no cap) in good mode.

<a id="max-inter-rate"></a>

#### `--max-inter-rate`

**Type:** int · **Values:** percent · **Default:** not stated · advanced

Caps the size of inter frames as a percentage of the average.

**Effect:** quality - · speed none · size fewer spikes

<a id="gf-cbr-boost"></a>

#### `--gf-cbr-boost`

**Type:** int · **Values:** percent · **Default:** not stated · advanced

Extra bits for golden frames in CBR mode.

**Effect:** quality ± · speed none · size ±

**Notes:** CBR only.

<a id="lossless"></a>

#### `--lossless`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · **HDR-relevant**

Mathematically lossless coding.

**Effect:** quality lossless · speed faster than low cq-levels · size very large

**Notes:** Works at 8/10/12-bit and every chroma format. Lossy settings such as cq-level and film grain do not apply.

<a id="frame-boost"></a>

#### `--frame-boost`

**Type:** int · **Values:** 0: off (default), 1: on · **Default:** 0 · advanced

Periodically lowers q on some frames to lift quality.

**Effect:** quality + on boosted frames · speed none · size larger

**Notes:** Unverified: mainly used in realtime encoding.

<a id="min-cr"></a>

#### `--min-cr`

**Type:** int · **Values:** integer (value / 100 = minimum compression ratio) · **Default:** 0 · advanced

Keeps each frame's compression ratio above a floor, mainly to satisfy level limits.

**Effect:** quality - if binding · speed none · size capped

<a id="vbr-corpus-complexity-lap"></a>

#### `--vbr-corpus-complexity-lap`

**Type:** int · **Values:** 0..10000 · **Default:** 0 · advanced

Assumed average complexity per macroblock for single-pass VBR with lookahead, used to spread bits.

**Effect:** quality ± · speed none · size ±

**Notes:** Only for one-pass VBR.

<a id="enable-rate-guide-deltaq"></a>

#### `--enable-rate-guide-deltaq`

**Type:** int · **Values:** 0 (default off), 1 · **Default:** 0 · advanced

Guides per-block delta-q from an external rate distribution map.

**Effect:** quality ± · speed none · size ±

**Notes:** Needs `--deltaq-mode=3` and `--rate-distribution-info`.

<a id="rate-distribution-info"></a>

#### `--rate-distribution-info`

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Input file with the rate distribution map for `--enable-rate-guide-deltaq`.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is ./rate_map.txt.

<a id="two-pass-output"></a>

#### `--two-pass-output`

**Type:** path · **Values:** file path · **Default:** not stated · advanced

In three-pass encoding, where the output of the first two passes goes.

**Notes:** Only for `--passes=3.` If it is not given, aomenc names the file <output>_pass2_<n>.ivf.

<a id="second-pass-log"></a>

#### `--second-pass-log` (also `-spf`)

**Type:** path · **Values:** file path · **Default:** not stated · advanced

Log file written by the second pass, used by the third pass.

<a id="sb-qp-sweep"></a>

#### `--sb-qp-sweep`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Tries several qp values per superblock at a fixed lambda and keeps the cheapest in rate-distortion terms.

**Effect:** quality + slight · speed much slower · size slightly smaller

**Notes:** Library default is 0.

### Speed and presets

<a id="good"></a>

#### `--good`

**Type:** bool · **Values:** flag · **Default:** not stated

Selects good-quality (offline) mode, the normal mode for file encoding. Same as `--usage=0.`

**Effect:** quality + · speed slower than --rt · size smaller

**In Lumora:** Not passed explicitly. Lumora relies on good mode being the default.

**Notes:** In the library source, good mode is usage 0, the default.

<a id="rt"></a>

#### `--rt`

**Type:** bool · **Values:** flag · **Default:** not stated

Selects realtime mode for live or low-latency encoding. Forces a single pass and opens cpu-used 5..12.

**Effect:** quality - · speed much faster · size larger

**Notes:** Turns off loop restoration and some other tools by default.

<a id="allintra"></a>

#### `--allintra`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Selects all-intra mode, where every frame is a keyframe. Meant for still images (AVIF) and intra-only masters.

**Effect:** quality ± (no inter prediction) · speed faster per frame · size much larger for video

| For | Value | Why | Source |
|---|---|---|---|
| still images | `--allintra with --tune=iq` | libaom documents tune iq and ssimulacra2 as tuning modes for still and layered AVIF images, which are encoded in all-intra mode. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**Notes:** Requires lag-in-frames 0 and kf-max-dist 0: the library rejects higher values in this mode. Several defaults change: QM min/max become 4/10 and screen detection mode 2.

<a id="usage"></a>

#### `--usage` (also `-u`)

**Type:** int · **Values:** 0: good, 1: rt, 2: allintra · **Default:** not stated

Chooses the usage profile by number. The same thing as `--good`, `--rt` or `--allintra`.

**Effect:** quality see --good/--rt/--allintra · speed see modes · size see modes

**Notes:** Library default is 0 (good).

<a id="cpu-used"></a>

#### `--cpu-used`

**Type:** int · **Values:** 0..6 in good mode, 5..12 in realtime mode, 0..9 in all intra mode · **Default:** not stated

Main speed/efficiency control. Lower numbers search more and compress better but take far longer.

**Effect:** quality + at lower values · speed much slower at lower values · size smaller at lower values

| For | Value | Why | Source |
|---|---|---|---|
| general / balanced | `4` | Codec Wiki's recommended value. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| archive | `2` | Codec Wiki suggests 2 if you have plenty of time, and 3 for a bit more efficiency than 4. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| speed | `6` | Codec Wiki suggests 6 for speed and warns that higher values have the worst efficiency. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| speed (good mode ceiling) | `6` | The good-quality speed-feature tables stop at 6, so 7-9 in good mode add little beyond 6 even though the library accepts them. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/speed_features.c) |

**In Lumora:** Passed as `--cpu-used={preset}.` The AV1 Pro ladder runs 6, 5, 4, 3, 2 (measured on an M3 Max, CPU time per frame relative to 6 / size saved against 6: 5 0.82 / 3%, 4 0.40 / 15%, 3 0.26 / 17%, 2 0.099 / 22%); the archival AV1 ladder adds libaom rungs 4, 3, 2, 1, 0 measured against SVT-AV1 (cpu-used 4 at 0.033 of preset 10's speed, about as small as preset 1). The encoders.json default is 4 (docs/encoding/tuning-aomenc.md).

**Notes:** Library default is 0 in good mode, which is extremely slow, so always set it.

<a id="coeff-cost-upd-freq"></a>

#### `--coeff-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off · **Default:** not stated · advanced

How often coefficient cost tables are refreshed during the search. Less often is faster but less accurate.

**Effect:** quality - with less frequent · speed + with less frequent · size slightly larger

**Notes:** Library default is 0 (per superblock).

<a id="mode-cost-upd-freq"></a>

#### `--mode-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off · **Default:** not stated · advanced

Update frequency for mode cost tables.

**Effect:** quality - with less frequent · speed + · size slightly larger

**Notes:** Library default is 0.

<a id="mv-cost-upd-freq"></a>

#### `--mv-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off · **Default:** not stated · advanced

Update frequency for motion-vector cost tables.

**Effect:** quality - with less frequent · speed + · size slightly larger

**Notes:** Library default is 0.

<a id="dv-cost-upd-freq"></a>

#### `--dv-cost-upd-freq`

**Type:** int · **Values:** 0: SB, 1: SB Row per Tile, 2: Tile, 3: Off · **Default:** not stated · advanced

Update frequency for displacement-vector (intra block copy) cost tables.

**Effect:** quality - with less frequent · speed + · size slight

**Notes:** Only matters when intra block copy is active.

<a id="auto-intra-tools-off"></a>

#### `--auto-intra-tools-off`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

In all-intra mode, automatically turns off some intra tools where they are unlikely to help.

**Effect:** quality slight - · speed + · size slight

**Notes:** Only active with `--deltaq-mode=3.` Library default is 0.

### GOP and keyframes

<a id="lag-in-frames"></a>

#### `--lag-in-frames`

**Type:** int · **Values:** 0..48 (library limit MAX_LAG_BUFFERS) · **Default:** not stated

How many future frames the encoder buffers before deciding on the current one. Longer lookahead helps alt-ref placement, temporal filtering and rate control.

**Effect:** quality + with more lag · speed slight - · size smaller with more lag

| For | Value | Why | Source |
|---|---|---|---|
| maximum efficiency (3.15.3) | `48` | 48 is the highest value 3.15.3 accepts. Anything above it is refused when the encoder starts (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/lookahead.h) |
| general (older guide) | `64` | Codec Wiki recommends 64 and says higher values bring little. On 3.15.3 that value fails with 'g_lag_in_frames out of range', so the two sources disagree. Use 48. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default in good mode is 35. All-intra mode forces 0.

<a id="enable-fwd-kf"></a>

#### `--enable-fwd-kf`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Allows forward keyframes. These are random-access points coded like alt-refs that can still reference earlier frames, which is cheaper than a full keyframe.

**Effect:** quality + · speed none · size -

| For | Value | Why | Source |
|---|---|---|---|
| chunked encoding (Av1an) | `0` | Codec Wiki turns it off when Av1an handles scene cuts and keyframes. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default is 0. (Unverified: some demuxers and players are reported to seek poorly to forward keyframes.)

<a id="kf-min-dist"></a>

#### `--kf-min-dist`

**Type:** int · **Values:** frames · **Default:** not stated

Minimum spacing between keyframes.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 0.

<a id="kf-max-dist"></a>

#### `--kf-max-dist`

**Type:** int · **Values:** frames · **Default:** not stated

Maximum spacing between keyframes, which limits how far a player may need to seek back.

**Effect:** quality + when longer · speed none · size smaller when longer

| For | Value | Why | Source |
|---|---|---|---|
| chunked encoding (Av1an) | `9999` | Codec Wiki leaves keyframe placement to Av1an's scene detection. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default is 9999. For standalone files that need quick seeking, about 10 seconds of frames is a common choice, but no source used here specifies a value.

<a id="disable-kf"></a>

#### `--disable-kf`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Turns off automatic keyframe placement. Only the first frame is a keyframe.

**Effect:** quality + slight · speed none · size -

| For | Value | Why | Source |
|---|---|---|---|
| chunked encoding (Av1an) | `set` | Codec Wiki uses it because every Av1an chunk already starts at a scene cut. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Never use it on a whole film encoded in one piece: the result would be almost unseekable.

<a id="sframe-dist"></a>

#### `--sframe-dist`

**Type:** int · **Values:** frames · **Default:** not stated · advanced

Interval for switch frames (S-frames), which let adaptive-streaming clients switch between renditions.

**Effect:** quality - · speed none · size +

**Notes:** Library default is 0 (off).

<a id="sframe-mode"></a>

#### `--sframe-mode`

**Type:** int · **Values:** 1..2 · **Default:** not stated · advanced

Chooses how S-frames are inserted.

**Effect:** quality - · speed none · size +

**Notes:** The 3.10.0 changelog says the sframe_mode field is not implemented, so it may have no effect.

<a id="auto-alt-ref"></a>

#### `--auto-alt-ref`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Allows hidden alternate reference frames: filtered future frames that many frames predict from. A core libaom efficiency tool.

**Effect:** quality + · speed slight - · size smaller

**Notes:** Library default is 1. Leave it on.

<a id="enable-order-hint"></a>

#### `--enable-order-hint`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Writes frame order hints so the decoder knows frame distances. Several compound and temporal-MV tools depend on it.

**Effect:** quality + · speed none · size smaller

**Notes:** Turning it off also turns off distance-weighted compound and ref-frame MVs.

<a id="enable-overlay"></a>

#### `--enable-overlay`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Codes overlay frames, which show the real frame at an alt-ref's position after the filtered alt-ref.

**Effect:** quality + · speed none · size ±

<a id="min-gf-interval"></a>

#### `--min-gf-interval`

**Type:** int · **Values:** frames (default 0 = built-in behavior) · **Default:** 0 · advanced

Minimum golden-frame / alt-ref group length.

**Effect:** quality ± · speed none · size ±

**Notes:** The library rejects values above 47 (MAX_LAG_BUFFERS minus 1).

<a id="max-gf-interval"></a>

#### `--max-gf-interval`

**Type:** int · **Values:** frames (default 0 = built-in behavior) · **Default:** 0 · advanced

Maximum golden-frame / alt-ref group length. Longer groups help static content.

**Effect:** quality ± · speed none · size smaller for static content when longer

**Notes:** The library rejects values above 47 (MAX_LAG_BUFFERS minus 1), and a non-zero value must be at least 2 and at least `--min-gf-interval`.

<a id="gf-min-pyr-height"></a>

#### `--gf-min-pyr-height`

**Type:** int · **Values:** 0 (default) to 5 · **Default:** 0 · advanced

Minimum depth of the hierarchical frame pyramid within a GF group.

**Effect:** quality ± · speed none · size ±

<a id="gf-max-pyr-height"></a>

#### `--gf-max-pyr-height`

**Type:** int · **Values:** 0 to 5 (default) · **Default:** 5 · advanced

Maximum depth of the hierarchical frame pyramid. Deeper pyramids compress better.

**Effect:** quality + when deeper · speed none · size smaller when deeper

<a id="fwd-kf-dist"></a>

#### `--fwd-kf-dist`

**Type:** int · **Values:** frames (-1 = no repetitive forward keyframes) · **Default:** -1 · advanced

Places forward keyframes at a fixed interval.

**Effect:** quality ± · speed none · size ±

**Notes:** Needs `--enable-fwd-kf=1.`

<a id="kf-max-pyr-height"></a>

#### `--kf-max-pyr-height`

**Type:** int · **Values:** -1 to 5 · **Default:** -1 · advanced

Caps the pyramid depth for the GOP that starts at a keyframe. -1 leaves it alone. The effective depth is the smaller of this and `--gf-max-pyr-height`.

**Effect:** quality ± · speed none · size ±

### Psychovisual and tuning

<a id="tune"></a>

#### `--tune`

**Type:** enum · **Values:** psnr, ssim, vmaf_with_preprocessing, vmaf_without_preprocessing, vmaf, vmaf_neg, butteraugli, vmaf_saliency_map, iq, ssimulacra2 · **Default:** not stated · **HDR-relevant**

Chooses which quality metric rate-distortion decisions optimize for. psnr is the library default. The vmaf modes need libvmaf and a model file. iq and ssimulacra2 are perceptual modes built for still images.

**Effect:** quality ± depends on metric · speed vmaf/butteraugli much slower · size ±

| For | Value | Why | Source |
|---|---|---|---|
| general video (live action, anime) | `ssim` | Codec Wiki recommends ssim, and suggests setting it explicitly in case defaults change. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| still images / AVIF | `iq` | aomcx.h describes tune=iq as an image-quality mode guided by SSIMULACRA 2 and subjective checks, meant for still or layered AVIF images. It turns on QM (qm-min 2, qm-max 10), sharpness 7, dist-metric qm-psnr, adaptive CDEF, chroma delta-q, Variance Boost, screen detection mode 2 and adaptive sharpness. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |
| video with iq/ssimulacra2 (disagreement) | `test before adopting` | The 3.15.3 header says iq and ssimulacra2 are not recommended for video, but the 3.14.0 changelog says both now work in good-quality and realtime modes. Supported is not the same as recommended. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |
| HDR / 10-12-bit | `avoid butteraugli` | tune=butteraugli rejects input above 8-bit. The Homebrew build also lacks it and errors out (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/av1_cx_iface.c) |

**In Lumora:** Not set (psnr). tune=ssim was 5-24% larger at equal VMAF though 1-10% smaller at equal XPSNR; tune=iq was 33-62% larger (docs/encoding/tuning-aomenc.md).

**Notes:** Lumora never sets `--tune` for aomenc, so it runs at psnr. vmaf* modes look for the model at /usr/local/share/model/vmaf_v0.6.1.json by default, which does not exist with Homebrew on Apple silicon; pass `--vmaf-model-path`. ssimulacra2 uses hand-made heuristics and does not call the metric itself.

<a id="enable-chroma-deltaq"></a>

#### `--enable-chroma-deltaq`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · **HDR-relevant** · advanced

Lets the encoder use a different quantizer offset for chroma than for luma, which usually gives chroma more bits.

**Effect:** quality + chroma · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| general / 4:4:4 / wide gamut | `1` | Codec Wiki lists it as a free efficiency gain from testing. tune=iq turns it on too. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Not set. It moved BD-rate by under 0.3% for 3-18% more time (docs/encoding/tuning-aomenc.md).

<a id="enable-qm"></a>

#### `--enable-qm`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · **HDR-relevant**

Uses frequency-weighted quantization matrices, which spend fewer bits on high frequencies the eye notices less.

**Effect:** quality + perceptual · speed none · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| all content | `1` | Codec Wiki lists it as a free efficiency gain from testing. tune=iq turns it on too. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Offered as the optional 'Quantization matrices' option (`--enable-qm=1`) on the AV1 Pro and archival libaom rungs, but no longer recommended for any content type: it was larger at equal XPSNR on every tuning clip (+0.8% to +5.8%) and 4-16% slower (docs/encoding/tuning-aomenc.md).

<a id="qm-min"></a>

#### `--qm-min`

**Type:** int · **Values:** 0..15 · **Default:** 5 (4 for all intra mode) · advanced

Lowest (steepest) QM flatness level the encoder may pick. Lower means more frequency weighting.

**Effect:** quality ± · speed none · size ±

**Notes:** Only matters with `--enable-qm=1.` tune=iq sets 2. The 3.12.0 changelog changed the all-intra defaults.

<a id="qm-max"></a>

#### `--qm-max`

**Type:** int · **Values:** 0..15 · **Default:** 9 (10 for all intra mode) · advanced

Highest (flattest) QM level the encoder may pick. 15 is flat, meaning no weighting.

**Effect:** quality ± · speed none · size ±

**Notes:** tune=iq sets 10.

<a id="aq-mode"></a>

#### `--aq-mode`

**Type:** int · **Values:** 0: off (default), 1: variance 2: complexity, 3: cyclic refresh · **Default:** 0 · advanced

Segment-based adaptive quantization. Variance mode gives flat areas more bits; cyclic refresh is meant for realtime.

**Effect:** quality ± perceptual · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| general | `0` | Codec Wiki says 0 is usually better but notes that this is debated and some users prefer 1. | [source](https://codecs.wiki/docs/encoders/aomenc) |

<a id="deltaq-mode"></a>

#### `--deltaq-mode`

**Type:** int · **Values:** 0: off, 1: deltaq objective (default), 2: deltaq placeholder, 3: key frame visual quality, 4: user rating based visual quality optimization, 5: HDR video, 6: Variance Boost · **Default:** 1 · **HDR-relevant** · advanced

Changes the quantizer per superblock. Mode 1 follows the TPL model for objective gains, modes 3 and 4 target perceptual quality, mode 5 is labeled HDR video, and mode 6 (Variance Boost) protects low-variance areas.

**Effect:** quality ± (mode-dependent) · speed slight · size ±

| For | Value | Why | Source |
|---|---|---|---|
| general (perceptual) | `0` | Codec Wiki found 0 more perceptually efficient. This disagrees with the library default of 1, which aims at objective metrics. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| HDR | `do not expect per-block HDR tuning from 5` | In 3.15.3 the per-block HDR luma offsets are compiled out (DISABLE_HDR_LUMA_DELTAQ 1), so mode 5 keeps every block at the base q. At exactly 10-bit with bt2020 primaries it still lowers chroma q through frame-level Cb/Cr offsets, and choosing it turns off the default mode 1. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.h) |
| still images / flat-area protection | `6` | Variance Boost was added for all-intra in 3.12 and extended to good-quality and realtime modes in 3.14. tune=iq turns it on. | [source](https://aomedia.googlesource.com/aom/+/refs/heads/main/CHANGELOG) |

**In Lumora:** Not set (default 1). 0, 5 (HDR, on PQ clips) and 6 (variance boost) were all larger, by 1-18% (docs/encoding/tuning-aomenc.md).

**Notes:** Modes 1-5 are silently ignored in non-RD mode (cpu-used 8 and up in all-intra, 7 and up in realtime). Mode 1 requires `--enable-tpl-model=1.`

<a id="deltaq-strength"></a>

#### `--deltaq-strength`

**Type:** int · **Values:** percent (library allows 0..1000) · **Default:** not stated · advanced

Scales how strong delta-q modulation is for modes 4 and 6.

**Effect:** quality ± · speed none · size ±

**Notes:** Library default is 100.

<a id="tune-content"></a>

#### `--tune-content`

**Type:** enum · **Values:** default, screen, film · **Default:** not stated

Tells the encoder what kind of content it has. screen turns on screen-content tools (palette, intra block copy) for every frame. film turns on film grain synthesis using a fixed built-in grain pattern.

**Effect:** quality screen: + on UI/text; film: adds synthetic grain · speed screen: slight - · size screen: smaller on UI

| For | Value | Why | Source |
|---|---|---|---|
| screen content | `screen` | Forces screen-content tools and intra block copy instead of leaving it to automatic detection. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.c) |
| live action / heavy grain (caution) | `avoid film unless you want generic grain` | In 3.15.3, film writes the same synthetic grain parameters into every frame (one luma scaling point, no measurement of the source) and enables film grain in the sequence header. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.c) |

**In Lumora:** The screen tune adds `--tune-content=screen.` On Lumora's screen clip it produced the same stream as automatic screen detection (docs/encoding/tuning-aomenc.md).

**Notes:** There is no 'animation' value in libaom. Library default is default.

<a id="vmaf-model-path"></a>

#### `--vmaf-model-path`

**Type:** path · **Values:** file path · **Default:** not stated · advanced

VMAF model file used by the vmaf tune modes.

**Effect:** quality none on its own · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| tune=vmaf on Homebrew/Apple silicon | `/opt/homebrew/share/libvmaf/model/vmaf_v0.6.1.json` | The built-in path /usr/local/share/model/vmaf_v0.6.1.json does not exist there, so vmaf tunes abort without this flag (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/av1_cx_iface.c) |

**Notes:** VMAF models are trained on SDR content, so vmaf tunes are a questionable target for HDR.

<a id="dist-metric"></a>

#### `--dist-metric`

**Type:** enum · **Values:** psnr, qm-psnr · **Default:** not stated · advanced

Distortion measure used inside block decisions. qm-psnr weights errors with the quantization matrix. It works at a lower level than `--tune`.

**Effect:** quality + perceptual with qm-psnr · speed none · size ±

**Notes:** Library default is psnr. tune=iq and ssimulacra2 switch to qm-psnr.

<a id="screen-detection-mode"></a>

#### `--screen-detection-mode`

**Type:** int · **Values:** 1: standard (default in good quality and realtime modes), 2: anti-aliased text and graphics aware (default in all intra mode) · **Default:** 1 in good quality and realtime modes; 2 in all intra mode · advanced

Chooses how automatic screen-content detection works. Mode 2 also recognizes anti-aliased text and graphics as screen content.

**Effect:** quality + on UI/text with 2 · speed slight · size smaller on UI with 2

| For | Value | Why | Source |
|---|---|---|---|
| screen content with smooth text | `2` | Mode 2 recognizes anti-aliased text and graphics, which standard detection can miss. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**Notes:** Added in 3.13.0. Has no effect when `--tune-content=screen` forces screen tools anyway.

<a id="sharpness"></a>

#### `--sharpness`

**Type:** int · **Values:** 0..7 · **Default:** 0

Pushes rate-distortion decisions toward keeping sharp coefficients. In all-intra mode it also weakens deblocking.

**Effect:** quality + detail / sharper lines, may add ringing · speed none · size larger

| For | Value | Why | Source |
|---|---|---|---|
| still images | `7 (set by tune=iq)` | libaom's tune=iq and ssimulacra2 set sharpness 7 as part of their image-quality bundle. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**Notes:** Since 3.12.0 it also sets the bitstream loop-filter sharpness in all-intra mode. No source used here tested it for video.

<a id="enable-adaptive-sharpness"></a>

#### `--enable-adaptive-sharpness`

**Type:** int · **Values:** 0: disabled (default), 1: enabled · **Default:** 0 · advanced

Varies sharpness with frame quantizer to reduce blocking at low and medium quality. `--sharpness` then acts as the maximum.

**Effect:** quality + at low-mid quality · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| low-to-medium quality images | `1 with sharpness above 0` | libaom says it reduces blocking at low and medium quality, and only does anything when sharpness is above 0. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**Notes:** Added in 3.13.0. tune=iq turns it on.

### Film grain and noise

<a id="enable-keyframe-filtering"></a>

#### `--enable-keyframe-filtering`

**Type:** int · **Values:** 0: no filter, 1: filter without overlay (default), 2: filter with overlay - experimental, may break random access in players · **Default:** 1 · advanced

Applies the temporal (ARNR) filter to keyframes, removing noise before coding them.

**Effect:** quality + objective, can soften grain · speed slight - · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| general / compatibility | `1` | Codec Wiki picks 1. Mode 2 is more efficient but has seeking problems and FFmpeg cannot read it. | [source](https://codecs.wiki/docs/encoders/aomenc) |

<a id="arnr-maxframes"></a>

#### `--arnr-maxframes`

**Type:** int · **Values:** 0..15 · **Default:** not stated · advanced

How many neighboring frames the alt-ref temporal filter averages.

**Effect:** quality ± (more frames means more denoising/smoothing) · speed - with more · size smaller with more

**Notes:** Library default is 7.

<a id="arnr-strength"></a>

#### `--arnr-strength`

**Type:** int · **Values:** 0..6 · **Default:** not stated

Strength of the alt-ref temporal filter. Higher values denoise more, which helps compression but can smear grain, texture and line art.

**Effect:** quality ± (detail vs. noise) · speed none · size smaller when higher

| For | Value | Why | Source |
|---|---|---|---|
| anime / 2D animation / CGI | `1` | Codec Wiki suggests 1 for 3D/CGI-like and 2D animation, where strong temporal filtering harms flat areas and lines. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| live action | `4` | Codec Wiki suggests 4 for live action, and possibly higher at low bitrates. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Not set (library default 5). 1 saved under 1% on CG and anime* and cost faces 3.4%; 3 saved under 0.7% (docs/encoding/tuning-aomenc.md).

**Notes:** Library default is 5 (av1_cx_iface.c). Codec Wiki describes 4 as the default, which does not match the 3.15.3 source.

<a id="noise-sensitivity"></a>

#### `--noise-sensitivity`

**Type:** int · **Values:** frames to blur (library allows 0..6) · **Default:** not stated · advanced

Turns on the temporal denoiser (luma only) used by realtime and SVC encoding. It is not part of film grain synthesis.

**Effect:** quality ± (removes noise) · speed slight - · size smaller on noisy input

**Notes:** Library default is 0. In 3.15.3 source it is only used in the realtime/SVC denoiser path, so it probably does little in good mode.

<a id="film-grain-test"></a>

#### `--film-grain-test`

**Type:** int · **Values:** 0: none (default), 1: test-1 2: test-2, ... 16: test-16 · **Default:** 0 · advanced

Applies one of 16 built-in test grain parameter sets. Meant for conformance testing, not for matching real footage.

**Effect:** quality adds fixed grain · speed none · size none

<a id="film-grain-table"></a>

#### `--film-grain-table`

**Type:** path · **Values:** file path · **Default:** not stated · **HDR-relevant**

Loads film grain parameters from a table file, from libaom's noise_model or photon_noise_table tools or another estimator, instead of estimating grain internally.

**Effect:** quality + perceived texture · speed none · size smaller if the source was denoised

| For | Value | Why | Source |
|---|---|---|---|
| digital camera noise / low light | `table from photon_noise_table (with -t smpte2084 or hlg for HDR)` | The tool models sensor shot noise from an ISO value and resolution and supports PQ and HLG transfers, so grain scales correctly in HDR. photon_noise_table is a libaom example program; the Homebrew aom package installs only aomenc and aomdec (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/heads/main/examples/photon_noise_table.c) |
| heavy film grain / old anime | `table from noise_model (noisy source vs. denoised source)` | On Doom9, a user built a table from the difference between the source and an externally denoised copy, then encoded the denoised copy. Another poster said this has real advantages over coding the grain, but the user noticed the grain pattern repeating when the video was paused. | [source](https://forum.doom9.org/archive/index.php/t-184143.html) |

**In Lumora:** Offered as 'Grain measured from this film (libaom)' on the archival ladder: `--film-grain-table={grain_table}`, with a table Lumora measures itself.

**Notes:** A grain table does not denoise anything by itself: denoising only runs when `--denoise-noise-level` is above 0, which defaults to 0. Feed an already denoised source, or the real grain is coded and the synthetic grain is added on top. Large-scale-tile mode ignores the table.

<a id="denoise-noise-level"></a>

#### `--denoise-noise-level`

**Type:** int · **Values:** 0 (don't denoise) to 50 · **Default:** not stated · **HDR-relevant**

Turns on libaom's internal noise model. It estimates the grain, writes AV1 film grain parameters, and (by default) denoises the frame before coding so the decoder adds the grain back.

**Effect:** quality ± (grain looks synthetic at high levels) · speed slight - · size much smaller on grainy content

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain / live action | `8` | Codec Wiki uses 8 and warns that above 12 the grain starts to look patterned. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| heavy grain (caution) | `test by eye` | A Doom9 user found that raising it gave artificial-looking noise and that the built-in denoiser was heavy-handed. | [source](https://forum.doom9.org/archive/index.php/t-184143.html) |

**In Lumora:** Offered as 'Film grain synthesis' on both libaom ladders at level 4, but no longer recommended, and the encoders.json grain tune no longer adds it: on heavy grain, low light and old anime* it was 3-26% larger at equal VMAF and XPSNR than coding the grain, against both the de-grained master and the noise-free original, at every level from 4 to 16, and 15-35% slower. When used, ExportEngine now scores it with the synthetic grain stripped (docs/encoding/tuning-aomenc.md).

**Notes:** Library default is 0 (off). Lumora's 10 is inside Codec Wiki's limit of 12 but above its suggested 8.

<a id="denoise-block-size"></a>

#### `--denoise-block-size`

**Type:** int · **Values:** pixels · **Default:** 32 · advanced

Block size the noise model uses to find flat areas and estimate grain.

**Effect:** quality ± · speed ± · size ±

**Notes:** No public tuning guidance found.

<a id="enable-dnl-denoising"></a>

#### `--enable-dnl-denoising`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Controls whether the frame is actually denoised when denoise-noise-level is on. With 0, grain is still estimated and synthesized, but the source grain is coded as well.

**Effect:** quality 0 keeps more real texture but adds synthetic grain on top · speed + with 0 · size larger with 0

| For | Value | Why | Source |
|---|---|---|---|
| grain synthesis (Codec Wiki default) | `0` | Codec Wiki turns off the built-in denoiser when using grain synthesis because it removes too much. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| very noisy sources | `1` | Codec Wiki suggests keeping denoising on for very noisy sources. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Not set (default 1).

**Notes:** Lumora leaves it at the default (1), so its denoise-noise-level option both denoises and synthesizes.

### Color and HDR

<a id="profile"></a>

#### `--profile`

**Type:** int · **Values:** 0 (Main), 1 (High), 2 (Professional) · **Default:** not stated · **HDR-relevant**

AV1 bitstream profile. Main covers 8/10-bit 4:2:0 and mono. High adds 4:4:4 at 8/10-bit. Professional covers 12-bit and 4:2:2.

| For | Value | Why | Source |
|---|---|---|---|
| 4:4:4 at 8 or 10-bit | `1` | The High profile is the lowest one that allows 4:4:4 below 12-bit. | [source](https://en.wikipedia.org/wiki/AV1) |
| 4:2:2 at 8 or 10-bit | `2` | Only the Professional profile allows 4:2:2. An explicit `--profile=2` with 10-bit 4:2:2 Y4M encodes fine in 3.15.3 (checked locally). | [source](https://en.wikipedia.org/wiki/AV1) |
| 12-bit input (Y4M) | `leave unset (or 0)` | aomenc raises the profile to 2 by itself for 12-bit input. An explicit `--profile=2` with 12-bit 4:2:2 or 4:4:4 Y4M takes a different code path that fails in 3.15.3 with 'Failed to set chroma subsampling x' (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/apps/aomenc.c) |

**In Lumora:** Passed as `--profile={aom_profile}` from EncodeRecipes.aomProfile: 0 for 10-bit 4:2:0, 1 for 10-bit 4:4:4, 2 for 10-bit 4:2:2 and 12-bit 4:2:0, and 0 for 12-bit 4:2:2 and 4:4:4, which aomenc raises to 2 itself (an explicit 2 makes aomenc 3.15.3 exit with 'Failed to set chroma subsampling x'). Lumora therefore exports 12-bit 4:2:2 and 4:4:4 (docs/encoding/tuning-aomenc.md).

**Notes:** aomenc adjusts the profile to fit the input format and bit depth and prints a warning (hidden by `--quiet`). It can lower it too: `--profile=2` with 10-bit 4:2:0 input becomes 0, and with 10-bit 4:4:4 becomes 1. Library default is 0.

<a id="bit-depth"></a>

#### `--bit-depth` (also `-b`)

**Type:** enum · **Values:** 8, 10, 12 · **Default:** not stated · **HDR-relevant**

Bit depth of the coded stream. 10-bit is the minimum for HDR. 12-bit requires profile 2.

**Effect:** quality + at 10-bit (less banding) · speed - slower than 8-bit · size often smaller at 10-bit for the same quality

| For | Value | Why | Source |
|---|---|---|---|
| all content, including 8-bit sources | `10` | Codec Wiki recommends 10-bit for everything: less banding and usually smaller files, even from 8-bit sources. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| 12-bit masters / intermediates | `12` | 12-bit keeps the master's full precision. It needs the Professional profile, which few hardware decoders support. | [source](https://en.wikipedia.org/wiki/AV1) |

**In Lumora:** Passed as `--bit-depth={bits}` (10 or 12 on the AV1 Pro path).

**Notes:** If `--input-bit-depth` is higher, aomenc raises `--bit-depth` to match and warns. Library default is 8.

<a id="monochrome"></a>

#### `--monochrome`

**Type:** bool · **Values:** flag · **Default:** not stated

Encodes luma only (4:0:0) and drops the chroma planes. Good for black-and-white material.

**Effect:** quality none for grayscale content · speed + · size smaller

**Notes:** Allowed in every profile.

<a id="color-primaries"></a>

#### `--color-primaries`

**Type:** enum · **Values:** bt709, unspecified, bt601, bt470m, bt470bg, smpte240, film, bt2020, xyz, smpte431, smpte432, ebu3213 · **Default:** not stated · **HDR-relevant**

CICP color primaries written to the sequence header. It labels the stream and does not convert pixels.

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR10 / HLG | `bt2020` | HDR10 and HLG both use BT.2020 container primaries. bt2020 is the spelling aomenc accepts. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c) |

**In Lumora:** Passed as `--color-primaries={cp_name}`, from encoders.json colorNames: bt2020 for pq/hlg and bt709 for sdr.

**Notes:** Library default is unspecified. smpte432 is P3-D65 and smpte431 is DCI-P3.

<a id="transfer-characteristics"></a>

#### `--transfer-characteristics`

**Type:** enum · **Values:** unspecified, bt709, bt470m, bt470bg, bt601, smpte240, lin, log100, log100sq10, iec61966, bt1361, srgb, bt2020-10bit, bt2020-12bit, smpte2084, hlg, smpte428 · **Default:** not stated · **HDR-relevant**

CICP transfer function written to the sequence header. smpte2084 marks PQ (HDR10) and hlg marks Hybrid Log-Gamma.

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR10 / PQ | `smpte2084` | The CICP name for the PQ curve in aomenc's list. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c) |
| HLG | `hlg` | aomenc spells HLG 'hlg'. 'arib-std-b67' is not in its list and makes aomenc exit (checked locally). | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c) |

**In Lumora:** Passed as `--transfer-characteristics={tc_name}:` smpte2084 for HDR10, hlg for HLG (checked: tagged arib-std-b67 in the stream), bt709 for SDR.

**Notes:** Library default is unspecified. Integer CICP codes are also accepted (16 = PQ, 18 = HLG).

<a id="matrix-coefficients"></a>

#### `--matrix-coefficients`

**Type:** enum · **Values:** identity, bt709, unspecified, fcc73, bt470bg, bt601, smpte240, ycgco, bt2020ncl, bt2020cl, smpte2085, chromncl, chromcl, ictcp, ipt-c2, ycgco-re, ycgco-ro · **Default:** not stated · **HDR-relevant**

CICP matrix coefficients (how Y'CbCr relates to R'G'B'), written to the sequence header.

**Effect:** quality none (signaling) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR10 / HLG | `bt2020ncl` | BT.2020 non-constant luminance is the matrix used by HDR10 and HLG. bt2020ncl is aomenc's name for it. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c) |

**In Lumora:** Passed as `--matrix-coefficients={mc_name}:` bt2020ncl for pq/hlg and bt709 for sdr.

**Notes:** identity means RGB coding, which needs 4:4:4. ictcp is for ICtCp sources.

<a id="chroma-sample-position"></a>

#### `--chroma-sample-position`

**Type:** enum · **Values:** unknown, vertical, colocated · **Default:** not stated · **HDR-relevant** · advanced

Signals where 4:2:0 chroma samples sit. vertical means left-sited (MPEG-2 style); colocated means top-left, co-sited with luma.

**Effect:** quality none (signaling; wrong value shifts chroma by half a pixel on display) · speed none · size none

**Notes:** Only applies to 4:2:0. Library default is unknown. Set it to the source's siting.

<a id="validate-hbd-input"></a>

#### `--validate-hbd-input`

**Type:** int · **Values:** 0: disabled, 1: enabled (default) · **Default:** 1 · **HDR-relevant** · advanced

For high-bit-depth encodes, checks that every input sample is valid for the chosen bit depth. Catches 10-bit data that is really 16-bit or 12-bit.

**Effect:** quality none · speed slight - · size none

**Notes:** Added in 3.14.0. Keep it on: it turns a silent garbled-output bug into an error.

### Analysis and motion search

<a id="static-thresh"></a>

#### `--static-thresh`

**Type:** int · **Values:** threshold · **Default:** not stated · advanced

Blocks whose motion error is below this threshold are skipped as static. Faster but can freeze fine changes.

**Effect:** quality - if raised · speed + if raised · size -

**Notes:** Library default is 0.

<a id="enable-tpl-model"></a>

#### `--enable-tpl-model`

**Type:** int · **Values:** 0: off, 1: backward source based · **Default:** not stated · advanced

Temporal dependency model. Estimates how much each block is referenced later and gives heavily used areas more bits.

**Effect:** quality + · speed slight - · size smaller

| For | Value | Why | Source |
|---|---|---|---|
| all good-mode encodes | `1` | It is the default and `--deltaq-mode=1` requires it, according to the help text and the codec control docs. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h) |

**Notes:** aomcx.h gives the default as 1 and says the control is left out of realtime-only builds.

<a id="enable-dual-filter"></a>

#### `--enable-dual-filter`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows separate horizontal and vertical interpolation filters for motion compensation.

**Effect:** quality + slight · speed slight - · size slightly smaller

<a id="enable-intra-edge-filter"></a>

#### `--enable-intra-edge-filter`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Smooths the neighboring edge pixels used for directional intra prediction.

**Effect:** quality + · speed none · size smaller

<a id="enable-dist-wtd-comp"></a>

#### `--enable-dist-wtd-comp`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Distance-weighted compound prediction, which weights two references by their temporal distance.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-masked-comp"></a>

#### `--enable-masked-comp`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Master switch for masked compound prediction (wedge and difference-weighted).

**Effect:** quality + · speed - · size smaller

<a id="enable-onesided-comp"></a>

#### `--enable-onesided-comp`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows compound prediction from two references on the same temporal side.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-interintra-comp"></a>

#### `--enable-interintra-comp`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Blends an inter prediction with an intra prediction inside one block.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-smooth-interintra"></a>

#### `--enable-smooth-interintra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Smooth-blend variant of inter-intra prediction.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-diff-wtd-comp"></a>

#### `--enable-diff-wtd-comp`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Compound prediction weighted by the difference between the two predictors.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-interinter-wedge"></a>

#### `--enable-interinter-wedge`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Wedge-shaped masks that combine two inter predictions.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-interintra-wedge"></a>

#### `--enable-interintra-wedge`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Wedge masks for inter-intra blending.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-global-motion"></a>

#### `--enable-global-motion`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Frame-level global motion models (pans, zooms, rotations) for camera movement.

**Effect:** quality + on camera motion · speed - · size smaller

<a id="enable-warped-motion"></a>

#### `--enable-warped-motion`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Local warped motion, which fits affine motion per block from neighboring motion vectors.

**Effect:** quality + · speed - · size smaller

<a id="enable-filter-intra"></a>

#### `--enable-filter-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Recursive filter-based intra prediction modes for textured blocks.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-smooth-intra"></a>

#### `--enable-smooth-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · **HDR-relevant** · advanced

Smooth intra prediction modes for gradients.

**Effect:** quality + on gradients · speed slight - · size smaller

**Notes:** Matters for banding-prone gradients such as HDR skies.

<a id="enable-paeth-intra"></a>

#### `--enable-paeth-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Paeth intra predictor, which picks the closest of the top, left and top-left neighbors.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-cfl-intra"></a>

#### `--enable-cfl-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · **HDR-relevant** · advanced

Chroma-from-luma prediction, which predicts chroma from the reconstructed luma. Especially useful at 4:4:4.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-diagonal-intra"></a>

#### `--enable-diagonal-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Diagonal directional intra modes (D45 to D203). Has no effect when directional intra is off.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-obmc"></a>

#### `--enable-obmc`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Overlapped block motion compensation, which blends neighboring block motion to soften block edges.

**Effect:** quality + · speed - · size smaller

<a id="enable-palette"></a>

#### `--enable-palette`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Palette prediction mode for blocks with few distinct colors, such as UI, text and flat animation.

**Effect:** quality + on screen content · speed slight - · size much smaller on screen content

**Notes:** Allowed by default, but the encoder only tries screen tools when its screen detector or `--tune-content=screen` says so.

<a id="enable-intrabc"></a>

#### `--enable-intrabc`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Intra block copy, which copies already-coded areas of the same frame. Very effective on repeated text and UI.

**Effect:** quality + on screen content · speed - · size smaller on screen content

**Notes:** Only used when screen content tools are active. It turns off in-loop filters for that frame.

<a id="enable-angle-delta"></a>

#### `--enable-angle-delta`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Fine angle steps for directional intra prediction.

**Effect:** quality + · speed slight - · size smaller

<a id="max-reference-frames"></a>

#### `--max-reference-frames`

**Type:** int · **Values:** 3 to 7 (default) · **Default:** 7 · advanced

Maximum number of reference frames each frame may use.

**Effect:** quality - with fewer · speed + with fewer · size larger with fewer

<a id="reduced-reference-set"></a>

#### `--reduced-reference-set`

**Type:** int · **Values:** 0: off (default), 1: on · **Default:** 0 · advanced

Restricts the single and compound reference combinations the encoder searches.

**Effect:** quality - · speed + · size larger

<a id="enable-ref-frame-mvs"></a>

#### `--enable-ref-frame-mvs`

**Type:** int · **Values:** 0/1 · **Default:** 1 · advanced

Temporal motion-vector prediction from reference frames.

**Effect:** quality + · speed slight - · size smaller

**Notes:** Needs order hints.

<a id="enable-directional-intra"></a>

#### `--enable-directional-intra`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Master switch for directional intra prediction modes.

**Effect:** quality + · speed slight - · size smaller

**Notes:** Turning it off also makes `--enable-diagonal-intra` irrelevant.

### Partitioning and transforms

<a id="enable-rect-partitions"></a>

#### `--enable-rect-partitions`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows rectangular block splits (horizontal and vertical halves).

**Effect:** quality + · speed - when on · size smaller when on

<a id="enable-ab-partitions"></a>

#### `--enable-ab-partitions`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows AB partitions: three-way splits that combine a half with two quarters.

**Effect:** quality + · speed - when on · size smaller when on

<a id="enable-1to4-partitions"></a>

#### `--enable-1to4-partitions`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows 1:4 and 4:1 strip partitions.

**Effect:** quality + · speed - when on · size smaller when on

<a id="min-partition-size"></a>

#### `--min-partition-size`

**Type:** enum · **Values:** 4:4x4, 8:8x8, 16:16x16, 32:32x32, 64:64x64, 128:128x128 · **Default:** not stated · advanced

Smallest block size the partition search may use. Raising it speeds up encoding but loses fine detail.

**Effect:** quality - if raised · speed + if raised · size ±

**Notes:** The help says 4K and above, or faster speeds, force a minimum of 8. Library default is 4.

<a id="max-partition-size"></a>

#### `--max-partition-size`

**Type:** enum · **Values:** 4:4x4, 8:8x8, 16:16x16, 32:32x32, 64:64x64, 128:128x128 · **Default:** not stated · advanced

Largest block size the partition search may use.

**Effect:** quality - if lowered (flat areas) · speed ± · size larger if lowered

**Notes:** Library default is 128.

<a id="enable-tx64"></a>

#### `--enable-tx64`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows 64-point transforms for large smooth areas.

**Effect:** quality + on smooth areas · speed slight - · size smaller

<a id="enable-flip-idtx"></a>

#### `--enable-flip-idtx`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows the extended transform types: flipped ADST, identity and one-dimensional transforms. Identity transforms help with sharp synthetic edges.

**Effect:** quality + · speed slight - · size smaller

<a id="enable-rect-tx"></a>

#### `--enable-rect-tx`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Allows rectangular transform sizes.

**Effect:** quality + · speed slight - · size smaller

<a id="disable-trellis-quant"></a>

#### `--disable-trellis-quant`

**Type:** int · **Values:** 0: false 1: true 2: true for rd search 3: true for estimate yrd search (default) · **Default:** 3 · advanced

Controls where trellis (rate-distortion-optimized) coefficient quantization is skipped. The default skips it only in an estimation step.

**Effect:** quality - if fully disabled · speed + if disabled · size larger if disabled

**Notes:** The logic is inverted: 0 means trellis is used everywhere.

<a id="reduced-tx-type-set"></a>

#### `--reduced-tx-type-set`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Uses a smaller set of transform types, signaled in the bitstream. Faster encode and simpler decode, at some efficiency cost.

**Effect:** quality - · speed + · size larger

**Notes:** Library default is 0.

<a id="use-intra-dct-only"></a>

#### `--use-intra-dct-only`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Restricts intra blocks to DCT transforms.

**Effect:** quality - · speed + · size larger

**Notes:** Library default is 0.

<a id="use-inter-dct-only"></a>

#### `--use-inter-dct-only`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Restricts inter blocks to DCT transforms.

**Effect:** quality - · speed + · size larger

**Notes:** Library default is 0.

<a id="use-intra-default-tx-only"></a>

#### `--use-intra-default-tx-only`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Uses only the default transform type for each intra mode, with no search.

**Effect:** quality - · speed + · size larger

**Notes:** Library default is 0.

<a id="quant-b-adapt"></a>

#### `--quant-b-adapt`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Uses an adaptive variant of the block quantizer.

**Effect:** quality ± · speed ± · size ±

**Notes:** Library default is 0. Little public guidance.

<a id="sb-size"></a>

#### `--sb-size`

**Type:** enum · **Values:** dynamic, 64, 128 · **Default:** not stated · advanced

Superblock size. dynamic lets the encoder choose 64x64 or 128x128 depending on resolution and speed.

**Effect:** quality ± · speed ± · size ±

| For | Value | Why | Source |
|---|---|---|---|
| general | `dynamic` | Codec Wiki recommends dynamic so both 128x128 and 64x64 are available. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default is dynamic.

<a id="enable-tx-size-search"></a>

#### `--enable-tx-size-search`

**Type:** int · **Values:** 0: false, 1: true (default) · **Default:** 1 · advanced

Searches for the best transform size per block. When off, the largest transform that fits is always used.

**Effect:** quality + · speed - · size smaller

**Notes:** Ignored in realtime non-RD mode.

### In-loop filters

<a id="enable-cdef"></a>

#### `--enable-cdef`

**Type:** int · **Values:** 0: false, 1: true (default), 2: disable for non-reference frames, 3: enable adaptively based on frame qindex · **Default:** 1 · advanced

Constrained Directional Enhancement Filter, an in-loop deringing filter that follows edge direction.

**Effect:** quality + usually, can soften fine texture · speed slight - · size smaller

**Notes:** tune=iq and tune=ssimulacra2 switch to 3 (adaptive).

<a id="enable-restoration"></a>

#### `--enable-restoration`

**Type:** int · **Values:** 0: false (default in realtime mode), 1: true (default in non-realtime mode) · **Default:** 1 in non-realtime mode · advanced

Loop restoration (Wiener and self-guided filters) that restores detail after deblocking and CDEF.

**Effect:** quality + · speed - · size smaller

<a id="delta-lf-mode"></a>

#### `--delta-lf-mode`

**Type:** int · **Values:** 0: off (default), 1: on · **Default:** 0 · advanced

Lets deblocking filter strength vary per superblock along with delta-q.

**Effect:** quality ± slight · speed none · size ±

**Notes:** Has no effect when deltaq-mode is 0.

<a id="loopfilter-control"></a>

#### `--loopfilter-control`

**Type:** int · **Values:** 0: Loopfilter disabled for all frames, 1: Enable loopfilter for all frames (default), 2: Disable loopfilter for non-reference frames, 3: Disable loopfilter for frames with low motion · **Default:** 1 · advanced

Controls when the deblocking filter runs.

**Effect:** quality - if disabled · speed + if disabled · size ±

**Notes:** Options 2 and 3 are speed features, mostly for realtime.

### Threading and performance

<a id="threads"></a>

#### `--threads` (also `-t`)

**Type:** int · **Values:** thread count · **Default:** not stated

Caps the number of worker threads. Effective use of threads needs row-mt, tiles or fp-mt.

**Effect:** quality none (slight - with tiles) · speed + up to a point · size none

| For | Value | Why | Source |
|---|---|---|---|
| chunked parallel encoding (Av1an) | `2` | Codec Wiki says aomenc largely lacks good multithreading and recommends Av1an for parallelism; its Av1an parameter set uses `--threads=2` per chunk. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**In Lumora:** Passed as `--threads={threads}:` the cores one instance fills (cpuCores / instances for segments, cpuCores for a single encode). Measured at 1920x800, cpu-used 4: 2 threads kept 1.75 cores busy, 4 threads 2.36 and 8 threads 2.55, with the same output; more instances of fewer threads would use the CPU better, which 'Measure on this Mac' can find (docs/encoding/tuning-aomenc.md).

**Notes:** Codec Wiki warns that above about 12 threads, still-image (AVIF) encodes can get slower.

<a id="use-16bit-internal"></a>

#### `--use-16bit-internal`

**Type:** bool · **Values:** flag · **Default:** not stated · **HDR-relevant** · advanced

Forces the high-bit-depth (16-bit) internal pipeline even for 8-bit encodes.

**Effect:** quality none · speed - for 8-bit · size none

**Notes:** Turned on automatically whenever `--bit-depth` is above 8.

<a id="row-mt"></a>

#### `--row-mt`

**Type:** int · **Values:** 0: off, 1: on (default) · **Default:** 1

Row-based multithreading inside each tile. The main way libaom uses more cores without tiles.

**Effect:** quality none · speed + · size none

| For | Value | Why | Source |
|---|---|---|---|
| all | `1` | It is the library default and is needed for good thread use without tiles. | [source](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/av1_cx_iface.c) |

**In Lumora:** Always `--row-mt=1.`

<a id="fp-mt"></a>

#### `--fp-mt`

**Type:** int · **Values:** 0: off (default), 1: on · **Default:** 0 · advanced

Frame-parallel multithreading: encodes several frames of a GOP at once for more speed on many-core CPUs.

**Effect:** quality slight - · speed + on many cores · size slightly larger

**Notes:** Unverified: the library is said to fall back to normal threading for configurations it cannot run frame-parallel, and output can differ from fp-mt=0.

<a id="tile-columns"></a>

#### `--tile-columns`

**Type:** int · **Values:** log2 count, 0..6 · **Default:** not stated

Splits the frame into 2 to the power N tile columns, which can be encoded and decoded in parallel at a small efficiency cost.

**Effect:** quality slight - · speed + · size slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| 1080p and below | `0` | Codec Wiki advises no tiles at 1080p or lower. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| 1440p | `1` | Codec Wiki suggests one level of tile columns at 1440p. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| 2160p / 4K HDR | `2` | Codec Wiki suggests 2 tile columns and 1 tile row at 2160p for decode and encode parallelism. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default is 0. The value is log2: 2 means 4 columns.

<a id="tile-rows"></a>

#### `--tile-rows`

**Type:** int · **Values:** log2 count, 0..6 · **Default:** not stated

Splits the frame into 2 to the power N tile rows.

**Effect:** quality slight - · speed + · size slightly larger

| For | Value | Why | Source |
|---|---|---|---|
| 2160p | `1` | Codec Wiki's 4K suggestion, used with tile-columns=2. | [source](https://codecs.wiki/docs/encoders/aomenc) |
| 1080p and below | `0` | Codec Wiki advises no tiles at these sizes. | [source](https://codecs.wiki/docs/encoders/aomenc) |

**Notes:** Library default is 0.

<a id="num-tile-groups"></a>

#### `--num-tile-groups`

**Type:** int · **Values:** count · **Default:** 1 · advanced

Maximum number of tile groups (OBU packets carrying tiles) per frame.

**Effect:** quality none · speed none · size slight overhead

**Notes:** For packetized network delivery.

<a id="mtu-size"></a>

#### `--mtu-size`

**Type:** int · **Values:** bytes (0 = no MTU targeting) · **Default:** 0 · advanced

Sizes tile groups to fit a network MTU. Overrides `--num-tile-groups`.

**Effect:** quality none · speed none · size slight overhead

<a id="auto-tiles"></a>

#### `--auto-tiles`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0

Lets the encoder pick the tile layout from resolution and thread count.

**Effect:** quality slight - (tiles) · speed + · size slightly larger

**Notes:** Added in 3.10.0. An alternative to setting tile-columns and tile-rows by hand.

### Logging and statistics

<a id="debug"></a>

#### `--debug` (also `-D`)

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Debug mode. Makes output deterministic so runs can be compared byte for byte.

<a id="quiet"></a>

#### `--quiet` (also `-q`)

**Type:** bool · **Values:** flag · **Default:** not stated

Stops aomenc printing per-frame progress.

**Notes:** Also hides the profile/bit-depth auto-upgrade warnings.

<a id="verbose"></a>

#### `--verbose` (also `-v`)

**Type:** bool · **Values:** flag · **Default:** not stated · **HDR-relevant**

Prints the full encoder configuration before encoding. Useful for confirming which profile, bit depth and settings were actually used.

<a id="psnr"></a>

#### `--psnr`

**Type:** int · **Values:** 0: disable, 1: PSNR at input bit-depth (default), 2: PSNR at stream bit-depth · **Default:** 1 when given without a value · advanced

Shows PSNR in the status line. Mode 2 measures at the coded bit depth, which only differs from mode 1 when input and stream depths differ.

**Effect:** quality none · speed slightly slower · size none

**Notes:** Off unless the flag is given.

<a id="q-hist"></a>

#### `--q-hist`

**Type:** int · **Values:** n-buckets · **Default:** not stated · advanced

Prints a histogram of the quantizers used, grouped into the given number of buckets.

<a id="rate-hist"></a>

#### `--rate-hist`

**Type:** int · **Values:** n-buckets · **Default:** not stated · advanced

Prints a histogram of per-frame bitrates.

<a id="disable-warnings"></a>

#### `--disable-warnings`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Hides the warnings about settings that may be wrong.

<a id="disable-warning-prompt"></a>

#### `--disable-warning-prompt` (also `-y`)

**Type:** bool · **Values:** flag · **Default:** not stated

Still prints warnings but does not stop to ask whether to continue. Use it in scripts so a warning cannot hang the job.

<a id="test-decode"></a>

#### `--test-decode`

**Type:** enum · **Values:** off, fatal, warn · **Default:** not stated · advanced

Decodes each frame while encoding and checks that it matches the encoder's own reconstruction. Catches encoder/decoder mismatch bugs.

**Effect:** quality none · speed slower · size none

### Other

<a id="global-error-resilient"></a>

#### `--global-error-resilient`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

Turns on error-resilience features for the whole stream, so decoding can recover after lost packets.

**Effect:** quality - · speed none · size + (larger)

**Notes:** Pointless for file-based delivery.

<a id="large-scale-tile"></a>

#### `--large-scale-tile`

**Type:** int · **Values:** 0: off (default), 1: on (ivf output only) · **Default:** 0 · advanced

Large-scale tile mode for special uses such as light-field or VR tile streaming, where single tiles are decoded independently.

**Effect:** quality - · speed none · size +

**Notes:** Turns off film grain options. Ordinary players cannot use it.

<a id="full-still-picture-hdr"></a>

#### `--full-still-picture-hdr`

**Type:** bool · **Values:** flag · **Default:** not stated · advanced

Writes the full sequence header rather than the reduced one for still pictures. HDR here means header, not high dynamic range.

**Effect:** quality none · speed none · size a few bytes

**Notes:** Often mistaken for an HDR option. It is not one.

<a id="force-video-mode"></a>

#### `--force-video-mode`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · advanced

Uses video coding settings even when the input is a single frame.

<a id="frame-parallel"></a>

#### `--frame-parallel`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · advanced

Turns on bitstream features that let decoders work on frames in parallel, mainly by turning off backward context adaptation.

**Effect:** quality slight - · speed none (decoder benefit) · size slightly larger

**Notes:** Not the same as `--fp-mt`, which is encoder threading.

<a id="error-resilient"></a>

#### `--error-resilient`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · advanced

Per-frame error-resilience mode for lossy networks.

**Effect:** quality - · speed none · size larger

<a id="cdf-update-mode"></a>

#### `--cdf-update-mode`

**Type:** int · **Values:** 0: no CDF update, 1: update CDF on all frames (default), 2: selectively update CDF on some frames · **Default:** 1 · advanced

Controls whether the entropy coder's probability tables adapt from frame to frame.

**Effect:** quality none · speed + with 0/2 (decoder too) · size larger with 0

<a id="timing-info"></a>

#### `--timing-info`

**Type:** enum · **Values:** unspecified, constant, model · **Default:** not stated · advanced

Writes timing info, and optionally a decoder model, into the bitstream.

**Effect:** quality none · speed none · size negligible

**Notes:** The help says model only works with no hidden frames and no superres. Library default is unspecified.

<a id="target-seq-level-idx"></a>

#### `--target-seq-level-idx`

**Type:** string · **Values:** ABxy: AB = operating point index, xy = level index (e.g. 0 = level 2.0 for OP 0, 1019 = level 6.3 for OP 10) · **Default:** not stated · advanced

Asks the encoder to stay within a given AV1 level for an operating point, which limits bitrate, tiles and picture size for device compatibility.

**Effect:** quality - if the level is tight · speed none · size capped

**Notes:** Pair with `--strict-level-conformance=1` to make violations fatal.

<a id="set-tier-mask"></a>

#### `--set-tier-mask`

**Type:** int · **Values:** 32-bit mask; bit 0 = Main tier (default), 1 = High tier · **Default:** 0 (Main tier) · advanced

Chooses Main or High tier for each of the 32 operating points. High tier allows higher bitrates per level.

**Effect:** quality none · speed none · size allows larger

<a id="partition-info-path"></a>

#### `--partition-info-path`

**Type:** path · **Values:** path · **Default:** not stated · advanced

Folder where partition decisions are read or written, for research and analysis tools.

**Notes:** Library default is '.'.

<a id="enable-low-complexity-decode"></a>

#### `--enable-low-complexity-decode`

**Type:** int · **Values:** 0: false (default), 1: true · **Default:** 0 · advanced

Picks tools that are cheaper to decode, for weak playback devices. Supported for good-quality speeds 1-3 at 608p-1080p vertical and 720p-1080p horizontal.

**Effect:** quality slight - · speed ± · size slightly larger

**Notes:** Development was marked complete for VOD in 3.15.0. Not meant for 4K.

<a id="strict-level-conformance"></a>

#### `--strict-level-conformance`

**Type:** int · **Values:** 0/1 · **Default:** not stated · advanced

With 1, the encoder stops instead of producing a stream that breaks the target level.

**Notes:** Library default is 0.

## Sources

- [Codec Wiki: aomenc](https://codecs.wiki/docs/encoders/aomenc)
- [libaom CHANGELOG](https://aomedia.googlesource.com/aom/+/refs/heads/main/CHANGELOG)
- [libaom v3.15.3 aom/aomcx.h (encoder controls)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aomcx.h)
- [libaom v3.15.3 av1/av1_cx_iface.c (defaults and range checks)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/av1_cx_iface.c)
- [libaom v3.15.3 apps/aomenc.c (pass handling, profile auto-upgrade)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/apps/aomenc.c)
- [libaom v3.15.3 av1/arg_defs.c (enum spellings)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c)
- [libaom v3.15.3 av1/encoder/encoder.h (DISABLE_HDR_LUMA_DELTAQ)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.h)
- [libaom v3.15.3 av1/encoder/encodeframe_utils.c (HDR delta-q)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encodeframe_utils.c)
- [libaom v3.15.3 av1/encoder/encoder.c (screen content, tune-content film)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.c)
- [libaom v3.15.3 av1/encoder/encoder_utils.c (film grain presence)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder_utils.c)
- [libaom v3.15.3 av1/encoder/speed_features.c](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/speed_features.c)
- [libaom v3.15.3 av1/encoder/lookahead.h (MAX_LAG_BUFFERS)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/lookahead.h)
- [libaom v3.15.3 common/webmenc.cc](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/common/webmenc.cc)
- [libaom v3.15.3 common/y4minput.c (color range from Y4M)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/common/y4minput.c)
- [libaom examples/photon_noise_table.c](https://aomedia.googlesource.com/aom/+/refs/heads/main/examples/photon_noise_table.c)
- [AOMedia: Libaom 3.12.0 now available (tune=iq)](https://aomedia.org/blog%20posts/Libaom-3_12_0-Now-Available-from-Codec-Working-Group/)
- [Doom9 forum: aomenc film grain table workflow](https://forum.doom9.org/archive/index.php/t-184143.html)
- [Wikipedia: AV1 (profiles)](https://en.wikipedia.org/wiki/AV1)
- [MKVToolNix mkvmerge documentation (HDR color metadata options)](https://mkvtoolnix.download/doc/mkvmerge.html)
- [libaom v3.15.3 av1/encoder/av1_quantize.c (HDR chroma delta-q)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/av1_quantize.c)
- [libaom v3.15.3 aom/aom_encoder.h (rate-control modes)](https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/aom/aom_encoder.h)

{% endraw %}
