---
title: VVenC (Fraunhofer Versatile Video Encoder)
parent: Encoding settings
nav_order: 4
---

{% raw %}

# VVenC (Fraunhofer Versatile Video Encoder)

**Documented version:** vvencapp version 1.14.0 · **Codec:** VVC · **License:** BSD-3-Clause-Clear · **Homepage:** <https://www.hhi.fraunhofer.de/en/departments/vca/technologies-and-solutions/h266-vvc/fraunhofer-versatile-video-encoder-vvenc.html> · **Homebrew:** [`vvenc`](https://formulae.brew.sh/formula/vvenc)

VVenC is Fraunhofer HHI's open-source H.266/VVC encoder. vvencapp is its simple front end, and the full tool set lives in the expert app vvencFFapp. Its strengths are very high compression (the slower preset is about as efficient as the VTM reference encoder, and medium comes close, at a tiny fraction of VTM's runtime), perceptual QP adaptation tuned to the XPSNR model, well-scaling multithreading, and single- and two-pass VBR rate control. Its weaknesses: it is slow at its efficient presets, vvencapp only takes 8/10-bit 4:2:0 or 4:0:0 input, and there are no content tunes.

**Bit depths:** 8, 10 · **Chroma:** 4:2:0, 4:0:0

Machine-readable data: [`data/vvenc.json`](data/vvenc.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

Use --hdr pq_2020 (alias hdr10_2020) for HDR10 or --hdr hlg_2020 for HLG, with 10-bit input (a 10-bit .y4m, or -c yuv420_10 for raw input). The internal bit depth must stay at 10. Besides writing the VUI color fields, these modes change how the encoder codes the video: PQ and HLG modes each switch to their own chroma QP mapping tables, and when perceptual QPA is on, a QP offset that depends on brightness is added. PQ sets transfer smpte2084 in the VUI, plus BT.2020 primaries and matrix for the _2020 variant (BT.709 for plain 'pq'). HLG writes bt2020-10 (or bt709) as the VUI transfer and adds an alternative transfer characteristics SEI that names arib-std-b67 (HLG), which is the backward-compatible way to signal HLG. vvencapp writes no HDR10 static metadata on its own. Add the mastering display (ST 2086) and MaxCLL/MaxFALL SEI through --additional MasteringDisplayColourVolume=... and MaxContentLightLevel=..., separated by ':'.

**Flags involved:** `--hdr`, `--sdr`, `--range`, `--internal-bitdepth`, `--format`, `--vuiparameterspresent`, `MasteringDisplayColourVolume`, `MaxContentLightLevel`, `PreferredTransferCharacteristics`, `ColourPrimaries`, `TransferCharacteristics`, `MatrixCoefficients`, `ColourDescriptionPresent`, `ChromaLocInfoPresent`, `ChromaSampleLocType`, `--additional`

**Example (HDR10):**

```bash
vvencapp -i input_3840x2160_10bit.y4m --preset slow -q 26 --hdr pq_2020 --range limited --additional MasteringDisplayColourVolume=13250,34500,7500,3000,34000,16000,15635,16450,10000000,1:MaxContentLightLevel=1000,400 -o output.266
```

**Pitfalls:**

- '--hdr pq' (alias hdr10) signals BT.709 primaries and matrix with a PQ transfer. Real HDR10 is BT.2020, so use pq_2020 / hdr10_2020 unless you have unusual BT.709 PQ content.
- Neither --hdr mode writes mastering display or content light level SEI. Pass them explicitly through --additional, or the stream carries no HDR10 static metadata.
- MasteringDisplayColourVolume lists green, blue, red, then white point, then max and min luminance. Chromaticities are in units of 1/50000 and luminance in units of 1/10000 cd/m2 (1000 nits = 10000000). Getting the order wrong silently writes the wrong primaries.
- If you give MasteringDisplayColourVolume or MaxContentLightLevel while --hdr is off, the library turns on PQ mode for you. It picks BT.709 PQ unless ColourPrimaries=bt2020 is also set (vvencCfg.cpp v1.14.0; a local test wrote smpte2084 with bt709 primaries). Set --hdr pq_2020 yourself so you are not surprised.
- The help text says that setting ColourPrimaries/TransferCharacteristics/MatrixCoefficients through --additional corresponds to '--hdr pq_2020'. That is true only of the VUI fields. The encoder stays in SDR mode (its log says so in a local test), so the PQ chroma QP tables and the HDR-aware QPA offsets are not applied. Prefer --hdr.
- HDR modes require internal bit depth 10 and 4:2:0. --internal-bitdepth 8 together with --hdr fails the configuration check (confirmed locally).
- Feeding 8-bit input to an HDR mode is accepted (confirmed locally), but PQ content quantized to 8 bits is prone to banding (general experience). Give the encoder real 10-bit source.
- HLG modes leave VUI transfer_characteristics at bt2020-10 (or bt709) and carry HLG only in the alternative transfer characteristics SEI. Players that ignore that SEI will show the video as SDR BT.2020. To put arib-std-b67 directly in the VUI, add --additional TransferCharacteristics=arib-std-b67 (confirmed locally). PreferredTransferCharacteristics does not change the VUI, despite what the help says.
- --hdr and --sdr cannot be combined; the app rejects that (confirmed locally).
- --range defaults to 'unknown', which leaves the full-range flag at 0 (limited) once VUI is written, so HDR modes already signal limited range. --range limited makes that explicit; only --range full changes the output.
- The output is a raw .266 elementary stream. Container-level color info (MP4 colr/mdcv/clli boxes) must be written by the muxer (for example FFmpeg 7+ or GPAC); check that your muxer copies the SEI values into the container.
- Do not count on -vui 0 to strip signaling: in v1.14.0 the color fields force VUI back on.

## Presets

| Preset | Speed | Notes |
|---|---|---|
| faster | fastest; on the order of 380x faster than HM-17.0 at 8 threads in the project's v1.14.0 measurements | About 13% bitrate saving over HM. It uses 64x64 CTUs, no multi-type tree splits and most VVC tools off (no ALF/CCALF, LFNST, MIP, DMVR, BDOF). Use for previews, quick tests or when speed matters far more than size. |
| fast | very fast; about 2x slower than faster | About 26% saving over HM. Turns on most coding tools (ALF, CCALF, affine, DMVR, BDOF, LFNST, DepQuant) with 64x64 CTUs. A good quick-turnaround choice. |
| medium | moderate; about 3.5x slower than fast | Default. About 35% saving over HM, with 128x128 CTUs and a wider motion search. The project's own recommended speed/efficiency trade-off. |
| slow | slow; about 4x slower than medium | About 39% saving over HM, about 3 points short of slower (which the wiki calls similar to VTM CTC). Best value for archival or final encodes when time allows. |
| slower | very slow; roughly 4-5x slower than slow | About 42% saving over HM, using the most tools and least search shortcuts. Small gain for a lot of extra time. The wiki table prints its HM speedup as '03x'; the VTM ratios imply about 3x, not 0.3x. |
| medium_lowDecEnergy | not measured by the project; expected to be similar to medium (unverified) | A medium variant that avoids coding tools that are costly to decode, so playback uses less energy (useful for battery-powered playback devices). Research on decoding-energy-aware VVenC tool profiles (arXiv 2206.13483) reports over 25% lower decoder energy for under 5% more bitrate. Not covered on the Presets wiki page. |

## Rate control

| Mode | Flags | Notes |
|---|---|---|
| Constant QP (pure) | -q <0..63> --qpa 0 | Every frame uses the base QP plus fixed hierarchical GOP offsets. Predictable and the setup the project uses for its PSNR results; the project reports MS-SSIM gains with QPA on, so pure QP usually looks worse at the same size. |
| Constant quality (QP + perceptual QPA, default) | -q <0..63> | The default in vvencapp: QPA moves the QP up and down per block and frame using the XPSNR model, which behaves like a CRF. The wiki calls QP 21-47 the useful range; lower means higher quality and bigger files. If neither -q nor -b is given, QP 32 is used. |
| Capped constant quality (capped CQF) | -q <QP> -m <absolute rate> | Constant quality with a ceiling on the instantaneous bitrate (added in v1.12). Requires QPA on. The cap must be an absolute value; the 'x' multiplier is rejected without a target bitrate. |
| Two-pass VBR (default when -b is set) | -b <rate> [-m <rate or Nx>] | With a target bitrate, vvencapp runs two passes back to back by default. The frame rate must be correct for rate control to hit the target. The wiki suggests a max rate of at least 1.5x the target. Any -q given is ignored once -b is set. |
| Single-pass VBR with look-ahead | -b <rate> -p 1 | One pass with look-ahead analysis, which vvencapp turns on automatically. Required when reading from stdin, since two passes in one call cannot read from a pipe. Unverified: usually a little less accurate than two-pass. |
| Two-pass VBR, passes run separately | -b <rate> --pass 1 --rcstatsfile stats.json, then the same command with --pass 2 | For distributed or staged workflows. Both runs must use identical options, or the results are unpredictable (Usage wiki). Needs a build with JSON support. |

## Recipes

### HDR10 archive

**Goal:** High-quality HDR10 file with complete static metadata · **Content:** PQ BT.2020 live action or CGI, 10-bit

```bash
-i in_10bit.y4m --preset slow -q 24 --hdr pq_2020 --range limited --additional MasteringDisplayColourVolume=13250,34500,7500,3000,34000,16000,15635,16450,10000000,1:MaxContentLightLevel=1000,400 -o out.266
```

slow gets within about 3 points of slower at a quarter of its runtime. pq_2020 sets correct VUI and HDR-aware coding. QPA (default on) adds the brightness-dependent QP adjustment. Explicit SEI carries HDR10 metadata. Replace the metadata values with the source's own.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage), [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance), [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp)

### HLG broadcast-style

**Goal:** HLG with backward-compatible signaling · **Content:** HLG BT.2020 live action, 10-bit

```bash
-i in_hlg_10bit.y4m --preset medium -q 28 --hdr hlg_2020 --range limited -o out.266
```

hlg_2020 writes BT.2020 VUI with bt2020-10 transfer plus the arib-std-b67 alternative transfer SEI, so SDR-only displays still show a watchable picture. Add --additional TransferCharacteristics=arib-std-b67 if the target player needs HLG in the VUI.

Sources: [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp), [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)

### SDR constant quality

**Goal:** Good-looking SDR file at a reasonable size · **Content:** SDR BT.709 live action

```bash
-i in.y4m --preset medium -q 30 --sdr sdr_709 -o out.266
```

medium is the project's recommended trade-off. QP with QPA behaves like a CRF. Explicit BT.709 signaling avoids player guesswork.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance), [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)

### Capped constant quality

**Goal:** Constant quality that never exceeds a delivery ceiling · **Content:** Any; mixed-complexity sources

```bash
-i in.y4m --preset medium -q 27 --qpa 1 -m 5M -o out.266
```

Capped CQF keeps constant quality but limits bitrate spikes on hard scenes; QPA must be on.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage), [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/master/changelog.txt)

### Two-pass target bitrate

**Goal:** Hit a file-size or bandwidth target · **Content:** Streaming/small size

```bash
-i in.y4m --preset medium -b 2M -m 2x -o out.266
```

Two-pass is the default when -b is set; a max rate of at least 1.5x the target is advised.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)

### DASH ladder rung

**Goal:** Segmentable stream for adaptive streaming with resolution switching · **Content:** Streaming

```bash
-i input_1920x1080.y4m -b 2M -m 4M -rt cra_cre -rs 4 --additional MaxPicSize=3840x2160 -o str_1920x1080.266
```

The project's own DASH example. cra_cre keeps segments independently decodable, 4-second refresh matches the segment length, and MaxPicSize allows switching between renditions.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)

### Fast preview

**Goal:** Quick look at a VVC encode · **Content:** Any

```bash
-i in.y4m --preset faster -q 32 -o preview.266
```

faster is about 7x quicker than medium while still beating HEVC-era efficiency.

Sources: [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance)

### Piped input from FFmpeg

**Goal:** Encode any source format without an intermediate file · **Content:** Any

```bash
ffmpeg -i src.mkv -pix_fmt yuv420p10le -f yuv4mpegpipe -strict -1 - | vvencapp -i - --y4m --preset medium -q 30 -o out.266
```

--y4m is required for piped Y4M. 10-bit input matches the encoder's default 10-bit internal depth. FFmpeg still needs -strict -1 to write 10-bit Y4M (checked with FFmpeg 9.0.2). For -b with piped input, add -p 1, since two-pass in one call cannot read from stdin.

Sources: [source](https://codecs.wiki/docs/encoders/VVenC), [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)

## All options

62 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--input`](#input) | file name or '-' for stdin |  | Source video: raw YUV, or Y4M when the file name ends in .y4m. |  | ✓ |
| [`--size`](#size) | WidthxHeight | 1920x1080 | Picture size of raw YUV input. |  |  |
| [`--format`](#format) | yuv420, yuv420_10, yuv420_10_packed, yuv400 (gray), yuv400_10 (gray10) | yuv420 | Pixel format and bit depth of raw input. | ✓ |  |
| [`--framerate`](#framerate) | frame rate numerator, e.g. 25, 30, 30000, 50, 60, 60000 | 60 | Frame rate numerator for raw input; pair it with --framescale for NTSC rates. |  |  |
| [`--framescale`](#framescale) | frame rate denominator, e.g. 1, 1001 | 1 | Frame rate denominator, so 30000/1001 gives 29.97 fps. |  |  |
| [`--fps`](#fps) | integer or fraction num/denom | 60/1 | Sets the frame rate in one value, as an integer or a fraction such as 24000/1001. |  |  |
| [`--tickspersec`](#tickspersec) | 1..27000000, -1: ticks per frame = 1 | 27000000 | Time base used to generate decode timestamps. |  |  |
| [`--frames`](#frames) | number of frames, 0 = all | 0 | Stops after encoding this many frames. |  |  |
| [`--frameskip`](#frameskip) | number of frames | 0 | Skips this many frames at the start of the input before encoding. |  |  |
| [`--y4m`](#y4m) | 0/1 | 0 | Forces Y4M parsing. |  | ✓ |
| [`--output`](#output) | file name |  | Writes the raw H.266 Annex-B bitstream (conventionally .266 or .vvc). |  | ✓ |
| [`--accessunitdelimiter`](#accessunitdelimiter) | -1: auto, 0: off, 1: on | auto | Writes access unit delimiter NAL units before each picture. |  |  |

### Rate control

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--bitrate`](#bitrate) | 0 = constant QP without rate control; otherwise bits/s, e.g. 1.5M, 1.5Mbps, 1500k, 1500kbps, 1500000bps, 1500000 | 0 | Target average bitrate. |  |  |
| [`--maxrate`](#maxrate) | 0 = no cap; bits/s such as 3.5M, 3500k; or a multiple of the target with suffix 'x' (e.g. 2x) | 0 | Approximate cap on the instantaneous bitrate. |  |  |
| [`--passes`](#passes) | 1: single-pass; -1 or 2: two-pass rate control | -1 | Single- or two-pass rate control. |  |  |
| [`--pass`](#pass) | -1: both, 1: first, 2: second pass | -1 | Runs just one half of a two-pass encode, so the passes can be run separately with --rcstatsfile. |  |  |
| [`--rcstatsfile`](#rcstatsfile) | JSON file name |  | Where the first pass writes its statistics and where the second pass reads them. |  |  |
| [`--qp`](#qp) | 0, 1, .. 63 | -1 | Base quantizer for constant-QP or constant-quality encoding. |  | ✓ |
| [`--hrdparameterspresent`](#hrdparameterspresent) | 0: off, 1: on | 1 | Writes HRD (decoder buffer model) parameters in the VUI. |  |  |

### Speed and presets

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--preset`](#preset) | faster, fast, medium, slow, slower, medium_lowDecEnergy | medium | Chooses the whole tool and search configuration. |  | ✓ |

### GOP and keyframes

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--segment`](#segment) | off, first, mid, last | off | Tells the encoder where a chunk sits when a long video is encoded in separate parts that will be joined, so the chunk boundaries can be concatenated cleanly. |  |  |
| [`--refreshtype`](#refreshtype) | idr, cra, cra_cre (CRA, constrained RASL picture encoding), none, rpsei (Recovery Point SEI), idr_no_radl (IDR without leading pictures, for DASH) | cra | Type of random-access picture inserted at each intra period. |  |  |
| [`--refreshsec`](#refreshsec) | seconds | 1 | Intra period in seconds; used when --intraperiod is 0. |  |  |
| [`--intraperiod`](#intraperiod) | frames; 0 = use --refreshsec | 0 | Intra period as a frame count, overriding the seconds-based setting. |  |  |
| [`PicReordering`](#picreordering) | 0: off, 1: on | 1 | Set through --additional. |  |  |

### Psychovisual and tuning

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--qpa`](#qpa) | 0: off, 1: on | on | Perceptual QP adaptation: raises the QP where the XPSNR visual model says errors are hard to see (busy texture, motion) and lowers it in flat or still areas. | ✓ | ✓ |

### Film grain and noise

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--fga`](#fga) | 0/1 | 0 | Experimental: analyzes the source's film grain and writes a film grain characteristics (FGC) SEI so a decoder can add matching grain back. |  |  |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--internal-bitdepth`](#internal-bitdepth) | 8, 10 | 10 | Bit depth the encoder works at. | ✓ |  |
| [`--vuiparameterspresent`](#vuiparameterspresent) | -1: auto, 0: off, 1: on | auto | Whether to write VUI (color description, aspect ratio, timing). | ✓ |  |
| [`--sdr`](#sdr) | off, sdr\|sdr_709, sdr_2020, sdr_470bg | off | Writes SDR color signaling in one step: BT.709, BT.2020 (with bt2020-10 transfer) or BT.470BG primaries, transfer and matrix in the VUI. | ✓ | ✓ |
| [`--hdr`](#hdr) | off, pq\|hdr10, pq_2020\|hdr10_2020, hlg, hlg_2020 | off | Switches the encoder into HDR mode. | ✓ | ✓ |
| [`--range`](#range) | unknown, limited \| mpeg \| tv, full \| jpeg \| pc | unknown | Signals whether samples use limited (16-235 scaled) or full range. | ✓ |  |
| [`AspectRatioIdc`](#aspectratioidc) | 0-16, 255 (0=undef, 1=1:1, 2=12:11, 3=10:11, 4=16:11, 5=40:33, 6=24:11, 7=20:11, 8=32:11, 9=80:33, 10=18:11, 11=15:11, 12=64:33, 13=160:99, 14=4:3, 15=3:2, 16=2:1) | 1 | Set through --additional. |  |  |
| [`Sar`](#sar) | WidthxHeight | 0x0 | Set through --additional. |  |  |
| [`ColourDescriptionPresent`](#colourdescriptionpresent) | 0/1 | 0 | Set through --additional. | ✓ |  |
| [`ColourPrimaries`](#colourprimaries) | 0-13: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, film, bt2020, smpte428, smpte431, smpte432 | unknown | Set through --additional. | ✓ |  |
| [`TransferCharacteristics`](#transfercharacteristics) | 0-18: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67 | unknown | Set through --additional. | ✓ |  |
| [`MatrixCoefficients`](#matrixcoefficients) | 0-14: gbr, bt709, unknown, empty, fcc, bt470bg, smpte170m, smpte240m, ycgco, bt2020nc, bt2020c, smpte2085, chroma-derived-nc, chroma-derived-c, ictcp | unknown | Set through --additional. | ✓ |  |
| [`ChromaLocInfoPresent`](#chromalocinfopresent) | -1: auto, 0: off, 1: on | auto | Set through --additional. | ✓ |  |
| [`ChromaSampleLocType`](#chromasampleloctype) | -1 auto, 0-5 (Chroma420LocType) | -1 | Set through --additional. | ✓ |  |
| [`OverscanAppropriate`](#overscanappropriate) | 0/1 | 0 | Set through --additional. |  |  |
| [`MasteringDisplayColourVolume`](#masteringdisplaycolourvolume) | 10 unsigned ints: G(x,y),B(x,y),R(x,y),WP(x,y),L(max,min); 0 <= GBR,WP <= 50000 (1/50000 units); luminance in 1/10000 cd/m2 | [] | Set through --additional. | ✓ |  |
| [`MaxContentLightLevel`](#maxcontentlightlevel) | "cll,fall", 1 <= cll,fall <= 65535 | [] | Set through --additional. | ✓ |  |
| [`PreferredTransferCharacteristics`](#preferredtransfercharacteristics) | 0-18: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67 | auto | Set through --additional. | ✓ |  |

### Threading and performance

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--threads`](#threads) | -1: resolution < 720p: 4, < 5K 2880p: 8, >= 5K 2880p: 12 threads | -1 | Number of worker threads. |  | ✓ |
| [`--mtprofile`](#mtprofile) | -1: auto, 0: off, 1, 2, 3: on (enables tiles, IFP and WPP automatically depending on the number of threads) | auto | Decides how hard to push parallelism. |  |  |
| [`--ifp`](#ifp) | -1: auto, 0: off, 1: on, with sync. offset of two CTU lines | auto | Inter-frame parallelism: lets a frame start encoding while its reference frame is still a couple of CTU rows ahead. |  |  |
| [`--tiles`](#tiles) | number of tile columns and rows, ColumnsxRows (e.g. 2x2); -1x-1 = auto | -1x-1 | Number of tile columns and rows. |  |  |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--verbosity`](#verbosity) | 0: silent, 1: error, 2: warning, 3: info, 4: notice, 5: verbose, 6: debug | info | Sets how much the encoder prints. |  |  |
| [`--stats`](#stats) | 0: off, 1: on | 1 | Turns the running summary (fps, bitrate, estimated time remaining) on or off. |  |  |
| [`--decodedpicturehash`](#decodedpicturehash) | 0: off, 1: md5, 2: crc, 3: checksum | off | Adds a per-picture hash SEI so a decoder can verify it reconstructed each frame exactly. |  |  |
| [`--tracechannellist`](#tracechannellist) | 0/1 | 0 | Lists the debug trace channels compiled into the encoder. |  |  |
| [`--tracerule`](#tracerule) | rule such as "D_CABAC:poc==8" | '' | Selects which trace channels and pictures to log. |  |  |
| [`--tracefile`](#tracefile) | file name | '' | File that receives trace output. |  |  |

### Other

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--help`](#help) | 0/1 | 0 | Prints the standard option list and exits. |  |  |
| [`--fullhelp`](#fullhelp) | 0/1 | 0 | Prints the full option list. |  |  |
| [`--version`](#version) | 0/1 | 0 | Prints the encoder version and exits. |  | ✓ |
| [`--additional`](#additional) | '(long)optionname=value' pairs concatenated with ':' (e.g. "bitrate=1000000 passes=1") |  | Passes extra options, including any expert option of the full library, as one string. | ✓ |  |
| [`--logofile`](#logofile) | JSON logo descriptor file |  | Burns a logo overlay, described in a JSON file, into the encoded pictures. |  |  |
| [`--profile`](#profile) | auto, main_10, main_10_still_picture | auto | VVC profile written in the stream. |  |  |
| [`--level`](#level) | auto, 1.0, 2.0, 2.1, 3.0, 3.1, 4.0, 4.1, 5.0, 5.1, 5.2, 6.0, 6.1, 6.2, 6.3, 15.5 | auto | Level limit written in the stream, which tells decoders the maximum resolution, frame rate and bitrate to expect. |  |  |
| [`--tier`](#tier) | main, high | main | Tier for interpreting the level; High allows higher bitrates at the same level. |  |  |

## Options in detail

### Input and output

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** file name or '-' for stdin · **Default:** 

Source video: raw YUV, or Y4M when the file name ends in .y4m. '-' reads from standard input.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `a 10-bit .y4m file` | Y4M carries resolution, frame rate and bit depth, so -s, --fps and -c are not needed and cannot be set wrong. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**In Lumora:** Passed as '-i {in}', where {in} is a FIFO named '<fifo>.y4m', so Y4M is detected from the extension.

**Notes:** Y4M is detected only by the .y4m extension: a Y4M file renamed to .yuv was read as raw 1920x1080 video and encoded 0 frames (local test). Piping Y4M through '-i -' without --y4m likewise encodes zero frames (codecs.wiki, confirmed locally). Two-pass rate control in one call cannot read from stdin; vvencapp exits with an error, so use -p 1 or a file (VVEncAppCfg.h, confirmed locally).

<a id="size"></a>

#### `--size` (also `-s`)

**Type:** string · **Values:** WidthxHeight · **Default:** 1920x1080

Picture size of raw YUV input. Ignored for Y4M, which carries its own size.

**Effect:** quality none (a wrong value garbles the encode) · speed none · size none

<a id="format"></a>

#### `--format` (also `-c`)

**Type:** enum · **Values:** yuv420, yuv420_10, yuv420_10_packed, yuv400 (gray), yuv400_10 (gray10) · **Default:** yuv420 · **HDR-relevant**

Pixel format and bit depth of raw input. yuv420_10 is 10-bit in 16-bit little-endian containers; the _packed form is 10-bit packed samples.

**Effect:** quality 10-bit input avoids banding · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `yuv420_10` | HDR10/HLG need 10-bit samples; the default yuv420 is 8-bit. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Only 4:2:0 and 4:0:0 input is accepted by vvencapp (the source rejects other formats); 4:2:2 and 4:4:4 are not available in the simple app (codecs.wiki).

<a id="framerate"></a>

#### `--framerate` (also `-r`)

**Type:** int · **Values:** frame rate numerator, e.g. 25, 30, 30000, 50, 60, 60000 · **Default:** 60

Frame rate numerator for raw input; pair it with --framescale for NTSC rates. Rate control, QPA and the seconds-based intra period all depend on it.

**Effect:** quality a wrong value misleads QPA and rate control · speed none · size a wrong value breaks bitrate targets

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `the true source rate` | The wiki stresses that rate control needs the correct frame rate to reach the target bitrate, and that QPA also uses it. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Y4M input supplies this automatically.

<a id="framescale"></a>

#### `--framescale`

**Type:** int · **Values:** frame rate denominator, e.g. 1, 1001 · **Default:** 1

Frame rate denominator, so 30000/1001 gives 29.97 fps.

**Effect:** quality none · speed none · size affects rate control accuracy

<a id="fps"></a>

#### `--fps`

**Type:** string · **Values:** integer or fraction num/denom · **Default:** 60/1

Sets the frame rate in one value, as an integer or a fraction such as 24000/1001. A shorthand for --framerate plus --framescale.

**Effect:** quality none · speed none · size affects rate control accuracy

<a id="tickspersec"></a>

#### `--tickspersec`

**Type:** int · **Values:** 1..27000000, -1: ticks per frame = 1 · **Default:** 27000000 · advanced

Time base used to generate decode timestamps.

**Notes:** The default moved from 90000 to 27000000 in v1.7.0 so that every NTSC rate is exact. The Usage wiki still lists 90000, which is outdated.

<a id="frames"></a>

#### `--frames` (also `-f`)

**Type:** int · **Values:** number of frames, 0 = all · **Default:** 0

Stops after encoding this many frames.

<a id="frameskip"></a>

#### `--frameskip` (also `-fs`)

**Type:** int · **Values:** number of frames · **Default:** 0

Skips this many frames at the start of the input before encoding.

<a id="y4m"></a>

#### `--y4m`

**Type:** bool · **Values:** 0/1 · **Default:** 0

Forces Y4M parsing. Needed when Y4M arrives on a pipe; files are recognized only by their .y4m extension.

| For | Value | Why | Source |
|---|---|---|---|
| speed | `1 when piping from ffmpeg with -i -` | Without it, piped Y4M is not recognized and nothing is encoded. | [source](https://codecs.wiki/docs/encoders/VVenC) |

**In Lumora:** Not passed; Lumora names its FIFO with a .y4m extension, so detection by extension applies.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file name · **Default:** 

Writes the raw H.266 Annex-B bitstream (conventionally .266 or .vvc). Mux it into MP4/MKV with another tool.

**In Lumora:** Passed as '-o {out}' with extension .266.

**Notes:** codecs.wiki: muxing raw .266 into MP4 with FFmpeg needs FFmpeg 7.0 or newer.

<a id="accessunitdelimiter"></a>

#### `--accessunitdelimiter` (also `-aud`)

**Type:** enum · **Values:** -1: auto, 0: off, 1: on · **Default:** auto · advanced

Writes access unit delimiter NAL units before each picture. In the v1.14.0 source, auto resolves to off for single-layer streams.

**Effect:** quality none · speed none · size + a few bytes per frame

**Notes:** Unverified: some MPEG-TS and broadcast delivery specs expect AUDs, so turn them on for that kind of delivery.

### Rate control

<a id="bitrate"></a>

#### `--bitrate` (also `-b`)

**Type:** string · **Values:** 0 = constant QP without rate control; otherwise bits/s, e.g. 1.5M, 1.5Mbps, 1500k, 1500kbps, 1500000bps, 1500000 · **Default:** 0

Target average bitrate. Any non-zero value turns on rate control (two-pass by default in vvencapp) and overrides -q.

**Effect:** quality set by the budget · speed two-pass costs extra time for the first pass · size hits the target

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `about 4M at 2160p, 2M at 1080p, 1M at 720p (with -m 2x)` | These are the values used in the project's DASH example ladder. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Rate control allows at most 4 parallel frames (configuration check in vvencCfg.cpp). With -b set, a -q value is ignored with a warning (confirmed locally).

<a id="maxrate"></a>

#### `--maxrate` (also `-m`)

**Type:** string · **Values:** 0 = no cap; bits/s such as 3.5M, 3500k; or a multiple of the target with suffix 'x' (e.g. 2x) · **Default:** 0

Approximate cap on the instantaneous bitrate. With -b it gives constrained VBR; with -q (and QPA on) it gives capped constant quality.

**Effect:** quality - in peaks when the cap binds · speed none · size limits peaks

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `at least 1.5x the target, e.g. 2x` | The wiki and changelog both say the cap should be at least 1.5x the target rate. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |
| archive | `-q 27 --qpa 1 -m 5M` | Constant quality with a safety ceiling, shown in the wiki as the capped CQF mode. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** The 'x' suffix added in v1.11; capped CQF added in v1.12. Without -b, the cap must be absolute and QPA must be on, or the configuration is rejected.

<a id="passes"></a>

#### `--passes` (also `-p`)

**Type:** enum · **Values:** 1: single-pass; -1 or 2: two-pass rate control · **Default:** -1

Single- or two-pass rate control. Only matters when -b is set; constant QP is always one pass.

**Effect:** quality + with two passes · speed - with two passes · size two-pass hits targets more accurately

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `-1 (default, two-pass) or 2` | The wiki treats back-to-back two-pass as the standard rate control mode. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Single-pass rate control switches on look-ahead analysis automatically (vvencCfg.cpp). Two passes in one call cannot read from stdin, so piped input with -b needs -p 1 (VVEncAppCfg.h, confirmed locally).

<a id="pass"></a>

#### `--pass`

**Type:** enum · **Values:** -1: both, 1: first, 2: second pass · **Default:** -1 · advanced

Runs just one half of a two-pass encode, so the passes can be run separately with --rcstatsfile.

**Effect:** quality same as two-pass · speed none · size none

**Notes:** The wiki warns that changing options between pass 1 and pass 2 can give unpredictable results or errors.

<a id="rcstatsfile"></a>

#### `--rcstatsfile`

**Type:** path · **Values:** JSON file name · **Default:**  · advanced

Where the first pass writes its statistics and where the second pass reads them.

**Notes:** Added in v1.2.0 alongside --pass. Required when --pass is set, rejected for single-pass (-p 1), and only available in builds with JSON support (VVEncAppCfg.h).

<a id="qp"></a>

#### `--qp` (also `-q`)

**Type:** int · **Values:** 0, 1, .. 63 · **Default:** -1

Base quantizer for constant-QP or constant-quality encoding. Lower is higher quality and larger files. -1 means automatic, which resolves to 32 without rate control.

**Effect:** quality + as QP drops · speed slightly slower at low QP · size + as QP drops (about doubles every ~6 QP)

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `32-37` | The wiki calls QP 21-47 the useful range. The library default of 32 sits toward the efficient end, so 32-37 is a reasonable zone for small files (inference from that range, not an explicit project recommendation). | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |
| archive | `21-27` | The low end of the wiki's 21-47 range gives near-transparent results; the capped CQF example uses 27. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**In Lumora:** Passed as '-q {quality}', mapped from Lumora's quality slider between qualityBest 20 and qualityWorst 40.

**Notes:** The wiki lists the default as 32; the help shows -1 (auto), which resolves to 32 without rate control (confirmed locally). With QPA on and a base QP above 42, QPA switches from block-level to frame-level adaptation for pictures above temporal layer 0 (BitAllocation.cpp).

<a id="hrdparameterspresent"></a>

#### `--hrdparameterspresent` (also `-hrd`)

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 1 · advanced

Writes HRD (decoder buffer model) parameters in the VUI.

**Effect:** quality none · speed none · size negligible

**Notes:** Buffering-period and picture-timing SEI, which use these parameters, require rate control (source check). Unsure whether HRD data is meaningful in constant-QP mode.

### Speed and presets

<a id="preset"></a>

#### `--preset`

**Type:** enum · **Values:** faster, fast, medium, slow, slower, medium_lowDecEnergy · **Default:** medium

Chooses the whole tool and search configuration. Slower presets enable more VVC tools and search harder, so they compress better at a steep speed cost.

**Effect:** quality + at same size with slower presets · speed large: each step is roughly 2-5x · size - with slower presets

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `medium` | The project names medium with multithreading as the recommended trade-off, about 35% saving over HM. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance) |
| archive | `slow` | About 39% saving over HM; slower adds only about 3 more points (and is the preset the wiki calls similar to VTM) at roughly 4-5x the runtime. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance) |
| speed | `faster` | About 7x faster than medium in the v1.14.0 performance table; the Presets wiki shows most coding tools off and a shallow partition search. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance) |
| low-power playback | `medium_lowDecEnergy` | Cuts decoder energy by avoiding expensive tools, for a few percent more bitrate. | [source](https://arxiv.org/abs/2206.13483) |

**In Lumora:** Passed as '--preset {preset}'. EncodeRecipes offers rungs faster/fast/medium/slow/slower (summary: 'slow is the efficient choice'); encoders.json default is medium.

**Notes:** The source also accepts 0-4 for faster..slower, 'medium_lowdecenergy' in lower case, and the internal values 'none', 'firstpass' and 'tooltest', which are not meant for normal use (VVEncAppCfg.h). The Presets wiki notes LMCS (reshaper) is deprecated and off in 1.14.0.

### GOP and keyframes

<a id="segment"></a>

#### `--segment`

**Type:** enum · **Values:** off, first, mid, last · **Default:** off · advanced

Tells the encoder where a chunk sits when a long video is encoded in separate parts that will be joined, so the chunk boundaries can be concatenated cleanly.

**Effect:** quality none · speed allows parallel chunked encoding · size none

**Notes:** Segment mode is rejected when rate control (-b) or capped CQF (-q with -m) is on (vvencCfg.cpp v1.14.0). The expert options LeadFrames/TrailFrames add overlapping context frames for chunked encoding (reach them through --additional).

<a id="refreshtype"></a>

#### `--refreshtype` (also `-rt`)

**Type:** enum · **Values:** idr, cra, cra_cre (CRA, constrained RASL picture encoding), none, rpsei (Recovery Point SEI), idr_no_radl (IDR without leading pictures, for DASH) · **Default:** cra

Type of random-access picture inserted at each intra period. CRA is open-GOP (most efficient). IDR is closed-GOP. cra_cre and idr_no_radl constrain leading pictures so segments can be switched or spliced cleanly.

**Effect:** quality none · speed none · size idr/cra_cre slightly larger than cra

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `cra_cre` | The project's DASH ladder examples use cra_cre with 4-second segments. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |
| archive | `cra (default)` | codecs.wiki describes cra as the default open-GOP mode and idr as the closed-GOP choice; keep cra unless segments must be spliced or switched. | [source](https://codecs.wiki/docs/encoders/VVenC) |

**Notes:** In v1.14.0 'none' is only accepted with PicReordering=0 (low delay), and low delay accepts only 'none'. 'rpsei' is rejected both with and without reordering (configuration checks, confirmed locally). cra_cre and idr_no_radl also enable reference picture resampling for resolution switching. idr_no_radl was added in v1.13.0.

<a id="refreshsec"></a>

#### `--refreshsec` (also `-rs`)

**Type:** int · **Values:** seconds · **Default:** 1

Intra period in seconds; used when --intraperiod is 0.

**Effect:** quality none · speed none · size - with longer periods

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `4` | The DASH examples use 4-second segments. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Sources disagree on scene cuts. codecs.wiki says VVenC does not detect them. The 1.14.0 source enables slice type adaptation (STA) by default for GOP 32, which turns a temporal-layer-0 B picture into an I picture after a scene cut; in that default mode the intra period is not restarted (STA=2 through --additional restarts it).

<a id="intraperiod"></a>

#### `--intraperiod` (also `-ip`)

**Type:** int · **Values:** frames; 0 = use --refreshsec · **Default:** 0

Intra period as a frame count, overriding the seconds-based setting.

**Effect:** quality none · speed none · size - with longer periods

**Notes:** When the period comes from --refreshsec, it is rounded to a multiple of 8 frames (the smaller of GOP size and 8). An explicit value just above a multiple of the 32-frame GOP (N*32+1 to N*32+4) triggers a warning about degraded results; the source suggests multiples of the GOP size. Film grain analysis (--fga) needs an intra period of at least 2.

<a id="picreordering"></a>

#### `PicReordering`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 1 · advanced

Set through --additional. Allows pictures to be coded out of display order (B-frame style hierarchical GOP). Turning it off gives low-delay coding for real-time use.

**Effect:** quality - when off · speed ± · size + noticeably when off

| For | Value | Why | Source |
|---|---|---|---|
| low latency | `0 (with -rt none and --additional PicReordering=0:POC0IDR=1:GOPSize=8)` | The help says to disable it for low-delay needs. v1.14.0 accepts only refresh type 'none' without reordering, and needs POC0IDR=1 and an 8-frame GOP; this combination encoded in a local test. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** Not useful for file-based encodes. Turning it off alone fails the configuration check; low delay also needs POC0IDR=1 and GOPSize=8 (local test).

### Psychovisual and tuning

<a id="qpa"></a>

#### `--qpa`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** on · **HDR-relevant**

Perceptual QP adaptation: raises the QP where the XPSNR visual model says errors are hard to see (busy texture, motion) and lowers it in flat or still areas. With an --hdr (or --sdr) mode set, it also adds a QP offset that depends on brightness.

**Effect:** quality + subjectively; - in PSNR · speed small cost · size ± depends on content

| For | Value | Why | Source |
|---|---|---|---|
| live action | `1 (default)` | Designed to improve subjective quality; the project lists it as a headline feature. | [source](https://github.com/fraunhoferhhi/vvenc) |
| HDR | `1` | With --hdr set, QPA adds a brightness-dependent QP offset that suits PQ/HLG signals; turning it off loses that adaptation (source reading). | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/BitAllocation.cpp) |
| benchmarking (PSNR) | `0` | The project's own PSNR results are measured without QPA, and QPA results are reported in MS-SSIM instead, because QPA targets perceived quality rather than PSNR. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance) |

**In Lumora:** Not passed; Lumora relies on the vvencapp default (on). Its target metric is VMAF, which differs from XPSNR, so measured scores may not reflect what QPA optimizes for.

**Notes:** On by default in vvencapp. vvencFFapp defaults to off (Usage wiki), and in the library vvenc_config_default leaves it off while vvenc_init_default turns it on. Required for capped CQF (-q with -m). Set the true frame rate when it is on. In the v1.14.0 source the brightness offset runs for any --hdr or --sdr mode, not only HDR (BitAllocation.cpp).

### Film grain and noise

<a id="fga"></a>

#### `--fga`

**Type:** bool · **Values:** 0/1 · **Default:** 0 · advanced

Experimental: analyzes the source's film grain and writes a film grain characteristics (FGC) SEI so a decoder can add matching grain back. It describes the grain; it does not itself remove it.

**Effect:** quality ± depends on decoder support for FGC SEI · speed - slightly · size none directly (smaller only if grain is also filtered out)

| For | Value | Why | Source |
|---|---|---|---|
| heavy grain | `1 (experimental)` | Writes a film grain SEI so a decoder that supports it can add grain back (experimental since v1.13.0). It needs MCTF, which every preset enables per the Presets wiki. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/master/changelog.txt) |

**Notes:** Added in v1.13.0 and marked experimental. Needs MCTF on and an intra period of at least 2. Few VVC decoders apply FGC SEI, so the effect on playback is uncertain.

### Color and HDR

<a id="internal-bitdepth"></a>

#### `--internal-bitdepth`

**Type:** enum · **Values:** 8, 10 · **Default:** 10 · **HDR-relevant** · advanced

Bit depth the encoder works at. 10 is the default and is required for HDR.

**Effect:** quality + at 10 (unverified for 8-bit sources) · speed 8 may be a little faster (unverified) · size - at 10 for the same quality (unverified)

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `10` | The configuration check rejects HDR modes below 10-bit internal. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** VVC Main 10 covers both; vvencapp offers no 12-bit option. Unverified (common encoder experience, not stated by the project): 10-bit internal coding is usually more efficient even for 8-bit sources.

<a id="vuiparameterspresent"></a>

#### `--vuiparameterspresent` (also `-vui`)

**Type:** enum · **Values:** -1: auto, 0: off, 1: on · **Default:** auto · **HDR-relevant** · advanced

Whether to write VUI (color description, aspect ratio, timing). Auto turns it on when --hdr, --sdr, --range or color options need it.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `auto (or 1)` | Setting --hdr or --sdr turns VUI on automatically, and in v1.14.0 the color fields force it back on even if 0 is given, so auto is all you need. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** In v1.14.0, -vui 0 is overridden whenever ColourPrimaries or MatrixCoefficients are set, so --hdr pq_2020 -vui 0 still wrote full color signaling in a local test. There is no reason to set 0 for HDR output.

<a id="sdr"></a>

#### `--sdr`

**Type:** enum · **Values:** off, sdr\|sdr_709, sdr_2020, sdr_470bg · **Default:** off · **HDR-relevant**

Writes SDR color signaling in one step: BT.709, BT.2020 (with bt2020-10 transfer) or BT.470BG primaries, transfer and matrix in the VUI.

| For | Value | Why | Source |
|---|---|---|---|
| live action | `sdr_709` | Most SDR sources are BT.709; explicit signaling keeps players from guessing. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**In Lumora:** Not passed. Lumora appends its hdrArgs only for HDR10 targets, so SDR encodes get neither --sdr nor --hdr and carry no color description.

**Notes:** Added in v1.7.0. Cannot be combined with --hdr (the app rejects it). sdr_2020 also switches to top-left chroma siting. In the v1.14.0 source an --sdr mode also enables the brightness-dependent QPA offset used for HDR (BitAllocation.cpp, source reading).

<a id="hdr"></a>

#### `--hdr`

**Type:** enum · **Values:** off, pq\|hdr10, pq_2020\|hdr10_2020, hlg, hlg_2020 · **Default:** off · **HDR-relevant**

Switches the encoder into HDR mode. It writes VUI color signaling and tunes coding for the signal (PQ or HLG chroma QP tables, HDR-aware QPA). The pq modes set transfer smpte2084; the hlg modes add an alternative transfer characteristics SEI naming HLG. The _2020 variants use BT.2020 primaries and matrix; the others use BT.709.

**Effect:** quality + for HDR content (correct tuning) · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `pq_2020` | HDR10 means PQ with BT.2020 primaries; plain 'pq' signals BT.709. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |
| HDR | `hlg_2020` | Broadcast HLG uses BT.2020. This mode adds the HLG transfer SEI for backward-compatible signaling. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**In Lumora:** Lumora's encoders.json maps PQ to 'pq_2020' and HLG to 'hlg_2020', but ExportEngine appends hdrArgs only when the target is HDR10. HLG exports therefore get no --hdr flag and no HLG signaling, and Lumora adds no MasteringDisplayColourVolume or MaxContentLightLevel, so its HDR10 output has no static metadata SEI.

**Notes:** Fixed color fields only fill values left at 'unknown', so explicit ColourPrimaries/MatrixCoefficients given in --additional take priority (PQ always forces smpte2084). Requires 10-bit internal and 4:2:0. The source also has a 'user defined' HDR mode that is not reachable through this flag.

<a id="range"></a>

#### `--range`

**Type:** enum · **Values:** unknown, limited \| mpeg \| tv, full \| jpeg \| pc · **Default:** unknown · **HDR-relevant**

Signals whether samples use limited (16-235 scaled) or full range.

**Effect:** quality none (wrong value shifts black and white levels on playback) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `limited` | HDR10 and HLG masters are normally limited range (general mastering practice). With an HDR mode the flag is already 0, so 'limited' only makes the choice explicit. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/apputils/VVEncAppCfg.h) |

**Notes:** Added in v1.14.0. 'unknown' leaves the VUI full-range flag at 0 (limited) and does not force VUI on; 'limited' writes the same flag but also forces VUI and the color description on; only 'full' changes the flag (VVEncAppCfg.h). The source also accepts 'unspecified'. Older builds need --additional VideoFullRange instead.

<a id="aspectratioidc"></a>

#### `AspectRatioIdc`

**Type:** enum · **Values:** 0-16, 255 (0=undef, 1=1:1, 2=12:11, 3=10:11, 4=16:11, 5=40:33, 6=24:11, 7=20:11, 8=32:11, 9=80:33, 10=18:11, 11=15:11, 12=64:33, 13=160:99, 14=4:3, 15=3:2, 16=2:1) · **Default:** 1 · advanced

Set through --additional. Signals the sample (pixel) aspect ratio with a table index, for anamorphic content.

**Notes:** Value 255 means use Sar. Values above 1 force VUI on.

<a id="sar"></a>

#### `Sar`

**Type:** string · **Values:** WidthxHeight · **Default:** 0x0 · advanced

Set through --additional. Gives an explicit sample aspect ratio, for anamorphic sources not covered by AspectRatioIdc.

<a id="colourdescriptionpresent"></a>

#### `ColourDescriptionPresent`

**Type:** bool · **Values:** 0/1 · **Default:** 0 · **HDR-relevant** · advanced

Set through --additional. Says whether primaries, transfer, matrix and range flags are written in the VUI.

**Notes:** Turned on automatically by --hdr, --sdr, --range, or by a non-unknown ColourPrimaries or MatrixCoefficients while VUI is on auto. TransferCharacteristics alone does not turn it on in the v1.14.0 source.

<a id="colourprimaries"></a>

#### `ColourPrimaries`

**Type:** enum · **Values:** 0-13: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, film, bt2020, smpte428, smpte431, smpte432 · **Default:** unknown · **HDR-relevant** · advanced

Set through --additional. Color primaries code in the VUI.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020` | HDR10/HLG deliverables use BT.2020 containers; --hdr *_2020 sets this for you. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** Only overrides when you set it explicitly; --hdr fills it only if it is left unknown.

<a id="transfercharacteristics"></a>

#### `TransferCharacteristics`

**Type:** enum · **Values:** 0-18: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67 · **Default:** unknown · **HDR-relevant** · advanced

Set through --additional. Transfer function code in the VUI: smpte2084 is PQ, arib-std-b67 is HLG.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `arib-std-b67 (with --hdr hlg_2020)` | Puts HLG directly in the VUI for players that ignore the alternative transfer SEI; hlg modes only fill this field when it is left unknown (source reading). | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** PQ modes always force smpte2084, whatever is given here. Setting this alone does not enable the encoder's HDR mode.

<a id="matrixcoefficients"></a>

#### `MatrixCoefficients`

**Type:** enum · **Values:** 0-14: gbr, bt709, unknown, empty, fcc, bt470bg, smpte170m, smpte240m, ycgco, bt2020nc, bt2020c, smpte2085, chroma-derived-nc, chroma-derived-c, ictcp · **Default:** unknown · **HDR-relevant** · advanced

Set through --additional. Matrix used to derive Y'CbCr from RGB.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020nc` | The standard matrix for HDR10/HLG; set automatically by the _2020 HDR modes. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

<a id="chromalocinfopresent"></a>

#### `ChromaLocInfoPresent`

**Type:** enum · **Values:** -1: auto, 0: off, 1: on · **Default:** auto · **HDR-relevant** · advanced

Set through --additional. Whether the chroma sample location is signaled.

**Notes:** Since v1.12.1, chroma location signaling follows the HDR/SDR mode (BT.2020 modes use top-left/collocated siting).

<a id="chromasampleloctype"></a>

#### `ChromaSampleLocType`

**Type:** int · **Values:** -1 auto, 0-5 (Chroma420LocType) · **Default:** -1 · **HDR-relevant** · advanced

Set through --additional. Chroma siting code for 4:2:0 (0 = left, 2 = top-left, etc.).

**Effect:** quality none (a wrong value shifts chroma slightly on display) · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `-1 (auto)` | HDR modes already set vertically collocated (top-left) siting, which matches typical BT.2020 masters. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** Match the source's real siting if it differs.

<a id="overscanappropriate"></a>

#### `OverscanAppropriate`

**Type:** bool · **Values:** 0/1 · **Default:** 0 · advanced

Set through --additional. Flags whether the picture can be shown with overscan cropping.

**Notes:** Setting it forces VUI on.

<a id="masteringdisplaycolourvolume"></a>

#### `MasteringDisplayColourVolume`

**Type:** list · **Values:** 10 unsigned ints: G(x,y),B(x,y),R(x,y),WP(x,y),L(max,min); 0 <= GBR,WP <= 50000 (1/50000 units); luminance in 1/10000 cd/m2 · **Default:** [] · **HDR-relevant**

Set through --additional. Writes the SMPTE ST 2086 mastering display SEI (primaries, white point and luminance range of the grading monitor), which is part of HDR10 metadata.

**Effect:** quality none (affects tone mapping on playback) · speed none · size negligible

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `13250,34500,7500,3000,34000,16000,15635,16450,10000000,1` | The help/wiki example for a P3-D65 1000-nit mastering monitor. Copy the source master's real values when known. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Written in every access unit when set (EncGOP.cpp). With --hdr off it switches the library to PQ mode, BT.709 unless ColourPrimaries=bt2020.

<a id="maxcontentlightlevel"></a>

#### `MaxContentLightLevel`

**Type:** list · **Values:** "cll,fall", 1 <= cll,fall <= 65535 · **Default:** [] · **HDR-relevant**

Set through --additional. Writes the content light level SEI: brightest pixel (MaxCLL) and brightest frame average (MaxFALL) in nits.

**Effect:** quality none (affects tone mapping on playback) · speed none · size negligible

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `the source's measured values, e.g. 1000,400` | Players use these to tone-map. The wiki example is 1000,400; real values come from the master or a measurement pass. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Both values must be non-zero or the SEI is skipped (EncGOP.cpp). The help says up to 65535, but the 1.14.0 source rejects values above 10000 (confirmed locally).

<a id="preferredtransfercharacteristics"></a>

#### `PreferredTransferCharacteristics`

**Type:** enum · **Values:** 0-18: reserved, bt709, unknown, empty, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67 · **Default:** auto · **HDR-relevant** · advanced

Set through --additional. Writes the alternative (preferred) transfer characteristics SEI, telling capable displays to use a different transfer than the VUI value. HLG modes set it to arib-std-b67 automatically.

**Effect:** quality none · speed none · size negligible

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `arib-std-b67 (auto with --hdr hlg/hlg_2020)` | This is the backward-compatible HLG signal; the wiki example pairs it with HLG mode. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** The help says it also overwrites the VUI transfer entry, but in v1.14.0 the VUI is written from TransferCharacteristics and this value only as a separate SEI (EncGOP.cpp). A local test with sdr_2020 plus PreferredTransferCharacteristics=arib-std-b67 kept bt2020-10 in the VUI.

### Threading and performance

<a id="threads"></a>

#### `--threads` (also `-t`)

**Type:** int · **Values:** -1: resolution < 720p: 4, < 5K 2880p: 8, >= 5K 2880p: 12 threads · **Default:** -1

Number of worker threads. Auto uses 4 below 720p, 8 from 720p and 12 from 2880p (based on the shorter picture side), capped at the number of CPU cores.

**Effect:** quality - very slightly when it triggers WPP/tiles/IFP · speed + · size + very slightly with more parallel tools

| For | Value | Why | Source |
|---|---|---|---|
| speed | `-1 (auto) or a bit above it` | Raising threads above the auto default makes mtprofile turn on extra parallel tools (WPP, tiles, IFP) automatically. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**In Lumora:** Passed as '--threads {threads}'. For clips over 480 frames ChipProfile runs about cpuCores/4 VVenC instances side by side (unless a measured profile overrides it), and each gets cpuCores divided by the instance count, about 4 threads.

**Notes:** 0 turns worker threads off; the allowed range is -1 to 256 (vvencCfg.cpp). The 12-thread step for 5K and up was added in v1.11.0.

<a id="mtprofile"></a>

#### `--mtprofile`

**Type:** enum · **Values:** -1: auto, 0: off, 1, 2, 3: on (enables tiles, IFP and WPP automatically depending on the number of threads) · **Default:** auto · advanced

Decides how hard to push parallelism. Auto compares --threads with the resolution default: at or below it nothing extra is enabled; above it, profiles 1-3 progressively add WPP, 2x2 (or 2x1) tiles and inter-frame parallelism.

**Effect:** quality - slightly at higher profiles · speed + on many-core machines · size + slightly

| For | Value | Why | Source |
|---|---|---|---|
| speed | `auto` | Picks a profile from the thread count so you do not have to tune tiles, WPP and IFP by hand. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Added in v1.12.0. Explicit --tiles or --ifp values override what the profile would choose.

<a id="ifp"></a>

#### `--ifp`

**Type:** enum · **Values:** -1: auto, 0: off, 1: on, with sync. offset of two CTU lines · **Default:** auto · advanced

Inter-frame parallelism: lets a frame start encoding while its reference frame is still a couple of CTU rows ahead. Gains speed on many cores.

**Effect:** quality - slightly (disables ALF temporal prediction) · speed + · size + slightly

**Notes:** Added in v1.11; auto follows --mtprofile since v1.12. IFP supports a single tile row only, and turning it on disables ALF temporal prediction (vvencCfg.cpp).

<a id="tiles"></a>

#### `--tiles`

**Type:** string · **Values:** number of tile columns and rows, ColumnsxRows (e.g. 2x2); -1x-1 = auto · **Default:** -1x-1 · advanced

Number of tile columns and rows. Tiles split the picture into independent regions that can be encoded and decoded in parallel, at a small efficiency cost.

**Effect:** quality - slightly · speed + for encoding and decoding · size + slightly

| For | Value | Why | Source |
|---|---|---|---|
| speed | `-1x-1 (auto)` | When mtprofile is on at 720p and above, auto picks 2x2 tiles (2x1 with IFP), which is enough for most machines. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp) |

**Notes:** The Usage wiki's option-mapping table still lists --tiles with a default of 1x1; since v1.12.0 the default is -1x-1 (auto, decided by --mtprofile), as the installed help shows. The option itself was added in v1.3.0.

### Logging and statistics

<a id="verbosity"></a>

#### `--verbosity` (also `-v`)

**Type:** enum · **Values:** 0: silent, 1: error, 2: warning, 3: info, 4: notice, 5: verbose, 6: debug · **Default:** info

Sets how much the encoder prints. From notice (4) upward it prints a line for every picture, which floods the terminal on long encodes.

**Effect:** quality none · speed none (very high levels add slight I/O cost) · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `2` | Warning level keeps logs short in batch or GUI-driven encodes while still reporting configuration problems; per-picture output only starts at notice. | [source](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/EncGOP.cpp) |

**Notes:** The v1.14.0 source also accepts the names silent, error, warning, info, notice, verbose and details (level 6 is called 'details' there, not 'debug'). Per-picture lines are printed at notice (4) and above (EncGOP.cpp).

<a id="stats"></a>

#### `--stats`

**Type:** bool · **Values:** 0: off, 1: on · **Default:** 1

Turns the running summary (fps, bitrate, estimated time remaining) on or off.

<a id="decodedpicturehash"></a>

#### `--decodedpicturehash` (also `-dph`)

**Type:** enum · **Values:** 0: off, 1: md5, 2: crc, 3: checksum · **Default:** off · advanced

Adds a per-picture hash SEI so a decoder can verify it reconstructed each frame exactly.

**Effect:** quality none · speed - slightly · size + tiny

**Notes:** The source also accepts log_md5/log_crc/log_checksum (11-13), which print the hashes.

<a id="tracechannellist"></a>

#### `--tracechannellist`

**Type:** bool · **Values:** 0/1 · **Default:** 0 · advanced

Lists the debug trace channels compiled into the encoder.

**Notes:** Developer tool; tracing generally only works in builds compiled with tracing support (not verified for the Homebrew build).

<a id="tracerule"></a>

#### `--tracerule`

**Type:** string · **Values:** rule such as "D_CABAC:poc==8" · **Default:** '' · advanced

Selects which trace channels and pictures to log.

**Effect:** quality none · speed - heavily when tracing · size none

**Notes:** Tracing cannot be combined with frame-parallel multithreading (source check).

<a id="tracefile"></a>

#### `--tracefile`

**Type:** path · **Values:** file name · **Default:** '' · advanced

File that receives trace output.

### Other

<a id="help"></a>

#### `--help` (also `-h`)

**Type:** bool · **Values:** 0/1 · **Default:** 0

Prints the standard option list and exits.

<a id="fullhelp"></a>

#### `--fullhelp`

**Type:** bool · **Values:** 0/1 · **Default:** 0 · advanced

Prints the full option list. In the installed 1.14.0 build it prints the same list as --help; expert options are reached through --additional (or vvencFFapp).

**Notes:** On this build, --fullhelp output was identical to --help (checked locally).

<a id="version"></a>

#### `--version`

**Type:** bool · **Values:** 0/1 · **Default:** 0

Prints the encoder version and exits.

**In Lumora:** Lumora's Packager runs 'vvencapp --version' to record the tool version.

<a id="additional"></a>

#### `--additional`

**Type:** string · **Values:** '(long)optionname=value' pairs concatenated with ':' (e.g. "bitrate=1000000 passes=1") · **Default:**  · **HDR-relevant** · advanced

Passes extra options, including any expert option of the full library, as one string. This is the only way to reach VUI color fields, HDR metadata SEI, PicReordering and other expert settings from vvencapp. It is parsed after all other options, so its values win.

**Effect:** quality depends on contents · speed depends on contents · size depends on contents

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `MasteringDisplayColourVolume=G(x,y),B(x,y),R(x,y),WP(x,y),Lmax,Lmin:MaxContentLightLevel=cll,fall` | This is how vvencapp gets HDR10 static metadata; --hdr itself does not add it. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |
| streaming/small size | `MaxPicSize=3840x2160` | The DASH examples set the largest picture size so every rendition can switch resolution (RPR) at segment borders. | [source](https://github.com/fraunhoferhhi/vvenc/wiki/Usage) |

**Notes:** Pairs can be separated with ':' or with spaces; the v1.14.0 parser treats both as separators (VVEncAppCfg.h, and a space-separated test worked). The Usage wiki writes examples such as 'hdr=pq:Name=value'. Any long option of vvencFFapp can be used here; this entry only documents the ones the help lists. The help claims that setting ColourPrimaries/TransferCharacteristics/MatrixCoefficients this way corresponds to '--hdr pq_2020', but a local test shows the encoder stays in SDR mode (only the VUI fields change).

<a id="logofile"></a>

#### `--logofile`

**Type:** path · **Values:** JSON logo descriptor file · **Default:**  · advanced

Burns a logo overlay, described in a JSON file, into the encoded pictures.

**Effect:** quality adds an overlay · speed minor · size minor

**Notes:** Added in v1.7.0. Only works in builds compiled with JSON support; otherwise vvencapp reports an error (VVEncAppCfg.h).

<a id="profile"></a>

#### `--profile`

**Type:** enum · **Values:** auto, main_10, main_10_still_picture · **Default:** auto · advanced

VVC profile written in the stream. Auto selects Main 10 for normal video.

**Notes:** The source also knows 4:4:4 and multilayer profiles, but vvencapp's input formats only allow 4:2:0/4:0:0.

<a id="level"></a>

#### `--level`

**Type:** enum · **Values:** auto, 1.0, 2.0, 2.1, 3.0, 3.1, 4.0, 4.1, 5.0, 5.1, 5.2, 6.0, 6.1, 6.2, 6.3, 15.5 · **Default:** auto · advanced

Level limit written in the stream, which tells decoders the maximum resolution, frame rate and bitrate to expect. Auto derives it from the settings.

**Notes:** 15.5 is the 'unconstrained' level.

<a id="tier"></a>

#### `--tier`

**Type:** enum · **Values:** main, high · **Default:** main · advanced

Tier for interpreting the level; High allows higher bitrates at the same level.

## Sources

- [VVenC GitHub repository (README)](https://github.com/fraunhoferhhi/vvenc)
- [VVenC wiki: Usage](https://github.com/fraunhoferhhi/vvenc/wiki/Usage)
- [VVenC wiki: Presets](https://github.com/fraunhoferhhi/vvenc/wiki/Presets)
- [VVenC wiki: Encoder Performance (v1.14.0)](https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance)
- [VVenC changelog](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/master/changelog.txt)
- [VVenC v1.14.0 source: vvencCfg.cpp (HDR modes, threading, rate control checks)](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp)
- [VVenC v1.14.0 source: VVEncAppCfg.h (vvencapp option maps)](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/apputils/VVEncAppCfg.h)
- [VVenC v1.14.0 source: EncGOP.cpp (SEI emission)](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/EncGOP.cpp)
- [VVenC v1.14.0 source: BitAllocation.cpp (QPA, HDR luma offsets)](https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/BitAllocation.cpp)
- [Fraunhofer HHI: VVenC product page](https://www.hhi.fraunhofer.de/en/departments/vca/technologies-and-solutions/h266-vvc/fraunhofer-versatile-video-encoder-vvenc.html)
- [Codec Wiki: VVenC](https://codecs.wiki/docs/encoders/VVenC)
- [Optimized Decoding-Energy-Aware Encoding in Practical VVC Implementations (arXiv 2206.13483)](https://arxiv.org/abs/2206.13483)

{% endraw %}
