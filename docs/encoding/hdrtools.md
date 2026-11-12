---
title: HDR metadata and muxing tools (dovi_tool, hdr10plus_tool, MP4Box, mkvmerge, FFmpeg color/HDR)
parent: Encoding settings
nav_order: 8
---

{% raw %}

# HDR metadata and muxing tools (dovi_tool, hdr10plus_tool, MP4Box, mkvmerge, FFmpeg color/HDR)

**Documented version:** dovi_tool 2.3.4; hdr10plus_tool 1.7.2; MP4Box - GPAC version 26.07-revrelease; mkvmerge v103.0 ('The Darkness') 64-bit; ffmpeg version 9.0.2 · **Codec:** metadata · **License:** dovi_tool MIT; hdr10plus_tool MIT; GPAC/MP4Box LGPL-2.1-or-later; MKVToolNix GPL-2.0-or-later; FFmpeg GPL-3.0-or-later (this Homebrew build) · **Homepage:** <https://github.com/quietvoid/dovi_tool> · **Homebrew:** [`dovi_tool`](https://formulae.brew.sh/formula/dovi_tool)

These tools handle HDR signaling and dynamic metadata around an encoder rather than compressing video. dovi_tool and hdr10plus_tool extract, convert, edit, generate and inject Dolby Vision RPUs and HDR10+ SEI in raw HEVC; MP4Box and mkvmerge put the result in MP4 or MKV with the right DV configuration and color boxes; FFmpeg tags, retags and filters color properties and moves streams in and out of Annex B. Strengths: lossless metadata work, no re-encode, scriptable. Weaknesses: they work frame by frame, so frame counts must match exactly, the dynamic-metadata tools only read raw HEVC/MKV, and each tool numbers color values slightly differently.

**Bit depths:** 8, 10, 12 · **Chroma:** 4:2:0, 4:2:2, 4:4:4

Machine-readable data: [`data/hdrtools.json`](data/hdrtools.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

HDR10 needs four things to agree: 10-bit 4:2:0 pixels; VUI tags primaries 9 (BT.2020), transfer 16 (PQ), matrix 9 (BT.2020 NCL), limited range; SEI mastering display (ST 2086) and MaxCLL/MaxFALL; and the same values in the container (MP4 colr nclx + mdcv + clli, or Matroska Colour/MasteringMetadata). HLG uses transfer 18 and usually no mastering SEI. The encoder writes VUI and SEI; FFmpeg frame tags (set with the setparams filter) plus -mastering_display/-content_light side data feed both the encoder and the MP4/MKV muxer; MP4Box (colr, -hdr) and mkvmerge (--color-*, --max-*) can add or fix container values without re-encoding; hevc_metadata/av1_metadata bitstream filters fix VUI tags. HDR10+ and Dolby Vision are layered on afterwards with hdr10plus_tool inject and dovi_tool inject-rpu, then muxed with MP4Box :dvp=8.1 or mkvmerge.

**Flags involved:** `setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv`, `-pix_fmt yuv420p10le`, `-mastering_display`, `-content_light`, `-tag:v hvc1`, `-strict unofficial`, `-bsf:v hevc_mp4toannexb`, `-bsf:v hevc_metadata`, `MP4Box :dvp=8.1`, `MP4Box :colr=nclx,...`, `MP4Box -hdr`, `mkvmerge --color-primaries/--color-transfer-characteristics/--color-matrix-coefficients/--color-range`, `mkvmerge --max-content-light/--max-frame-light/--chromaticity-coordinates/--white-color-coordinates/--max-luminance/--min-luminance`, `dovi_tool -m 2`, `dovi_tool inject-rpu`, `hdr10plus_tool inject`

**Example (HDR10):**

```bash
ffmpeg -mastering_display "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)" -content_light 1000,400 -i master.mov -map 0:v:0 -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v libx265 -pix_fmt yuv420p10le -x265-params "hdr10-opt=1" -tag:v hvc1 out.mp4
```

**Pitfalls:**

- FFmpeg 9.0.2 (tested): output -color_primaries/-color_trc on a libx265 encode from an untagged source are overwritten by the frames' unspecified values, so the MP4 gets no colr box and MKV no primaries/transfer, even though x265-params can still write a correct VUI. Tag frames with setparams, and pass -mastering_display/-content_light before -i so mdcv/clli (MP4) or MasteringMetadata (MKV) are written too.
- FFmpeg's MP4/MOV muxer writes the colr box only when primaries, transfer and matrix are ALL specified; one missing tag means no container color at all.
- FFmpeg drops the dvcC/dvvC box in MP4 unless -strict unofficial is given, so the file silently plays as HDR10.
- HEVC in MP4 for Apple should use hvc1 (or dvh1); Apple's HLS spec marks hev1/dvhe as not recommended (rule 1.10). Pass -tag:v hvc1 to FFmpeg.
- Raw .hevc has no timing: MP4Box assumes 25 fps without :fps=, mkvmerge needs --default-duration.
- RPU and HDR10+ entries map to frames by order. Any trim, frame-rate change or interpolation needs the metadata retimed (dovi_tool editor / hdr10plus_tool editor) or regenerated.
- Cropping letterbox bars invalidates DV L5 offsets; use dovi_tool --crop or editor active_area.
- MP4Box :nosei strips HDR10 and HDR10+ SEI.
- Range numbering differs: FFmpeg color_range 1=tv 2=pc; H.273/bsf 0=limited 1=full; mkvmerge 1=broadcast 2=full 3=derived.
- Chroma location numbering differs: FFmpeg = H.273 type + 1.
- mkvmerge color coordinates are decimal R,G,B; x265/FFmpeg/HEVC SEI use integers in 0.00002 units ordered G,B,R.
- The FFmpeg colorspace filter cannot handle PQ/HLG, and this FFmpeg build has no zscale or libplacebo, so tonemap has no ready linearization step.
- Dolby Vision profile 5 has no HDR10 fallback; never strip its RPU expecting a usable HDR10 file.
- x265 --repeat-headers puts parameter sets into the samples; it is meant for raw streams without a container, so leave it off for hvc1 MP4 output (x265 docs; Apple HLS rule 1.10).

## Presets

None.

## Rate control

None.

## Recipes

### Inject HDR10+ JSON into an HEVC encode

**Goal:** Add HDR10+ dynamic metadata to an existing HDR10 HEVC encode · **Content:** HDR10 HEVC (MP4/MKV) + HDR10+ JSON with one entry per frame

```bash
ffmpeg -i encode.mkv -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc video.hevc && hdr10plus_tool inject -i video.hevc -j hdr10plus.json -o video_hdr10p.hevc && hdr10plus_tool --verify extract video_hdr10p.hevc && mkvmerge -o out.mkv --default-duration 0:24000/1001fps video_hdr10p.hevc -D encode.mkv
```

hdr10plus_tool only reads Annex B HEVC, so the video is copied out losslessly, injected, verified, then remuxed with the original audio/subtitles. Frame counts of JSON and video must agree; use hdr10plus_tool editor to fix them after trims or frame-rate changes.

Sources: [source](https://github.com/quietvoid/hdr10plus_tool), [source](https://mkvtoolnix.download/doc/mkvmerge.html)

### Carry HDR10+ from source to a new x265 encode

**Goal:** Keep the source's HDR10+ when re-encoding at the same frame rate · **Content:** HDR10+ HEVC source

```bash
ffmpeg -i src.mkv -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | hdr10plus_tool extract -o hdr10plus.json -   (then encode with x265 --dhdr10-info hdr10plus.json, or inject afterwards)
```

Extraction reorders metadata to presentation order; only add --skip-reorder if the README's misauthoring signs appear.

Sources: [source](https://github.com/quietvoid/hdr10plus_tool), [source](https://x265.readthedocs.io/en/master/cli.html)

### Convert Dolby Vision profile 7 to 8.1

**Goal:** Single-layer, HDR10-compatible DV from a UHD Blu-ray dual-layer stream · **Content:** DV profile 7 (FEL or MEL) HEVC, e.g. an MKV remux

```bash
ffmpeg -i input.mkv -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool -m 2 convert --discard - -o BL_RPU.hevc && dovi_tool extract-rpu BL_RPU.hevc -o RPU.bin && dovi_tool info -i RPU.bin -s
```

-m 2 rewrites each RPU as profile 8.1 and drops the reconstruction mapping; --discard removes the EL, leaving the HDR10 base layer plus RPU. FEL titles lose the enhancement-layer detail (usually small), MEL titles lose nothing visible. The summary check confirms profile 8 and the frame count.

Sources: [source](https://github.com/quietvoid/dovi_tool), [source](https://github.com/gacopl/dvmkv2mp4), [source](https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html)

### Mux DV 8.1 HEVC into MP4

**Goal:** MP4 that Apple TV / LG / Sony see as Dolby Vision and others as HDR10 · **Content:** Annex B HEVC with 8.1 RPU (from inject-rpu or convert)

```bash
MP4Box -add BL_RPU.hevc:dvp=8.1:fps=24000/1001 -add source.mp4#audio -new out.mp4 && MP4Box -infox out.mp4
```

Raw HEVC needs an explicit frame rate (MP4Box assumes 25 otherwise), and dvp writes the Dolby Vision configuration box. MP4Box keeps parameter sets out of band (hvc1), which Apple asks for (HLS rule 1.10). FFmpeg alternative: ffmpeg -i in.mkv -map 0 -c copy -tag:v hvc1 -strict unofficial out.mp4 (movenc.c writes dvcC/dvvC only with -strict unofficial).

Sources: [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/), [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c), [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices), [source](https://github.com/gacopl/dvmkv2mp4)

### Mux DV into MKV

**Goal:** Matroska with Dolby Vision · **Content:** Annex B HEVC with RPU, or MP4 with dvh1/dvcC

```bash
mkvmerge -o out.mkv --default-duration 0:24000/1001fps BL_RPU.hevc -D source.mkv
```

mkvmerge reads single-layer DV from Annex B elementary streams (v58), reads DV from MP4 files (v57) and combines Blu-ray two-track DV into one track (v81), per NEWS. Raw streams need --default-duration; -D takes only audio/subtitles from the second file.

Sources: [source](https://mkvtoolnix.download/doc/NEWS.md), [source](https://mkvtoolnix.download/doc/mkvmerge.html)

### Generate DV 8.1 from HDR10+ metadata

**Goal:** Add a DV layer to an HDR10+ title · **Content:** HDR10+ HEVC

```bash
ffmpeg -i in.mkv -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc BL.hevc && hdr10plus_tool extract BL.hevc -o hdr10plus.json && dovi_tool generate -j gen.json --hdr10plus-json hdr10plus.json -o RPU.bin && dovi_tool inject-rpu -i BL.hevc --rpu-in RPU.bin -o BL_RPU.hevc
```

gen.json (start from assets/generator_examples/default_cmv40.json) supplies profile, length and L6; the HDR10+ data becomes L1. Check frame counts match before injecting.

Sources: [source](https://github.com/quietvoid/dovi_tool), [source](https://github.com/gacopl/dvmkv2mp4)

### Encode HDR10 with correct signaling (FFmpeg + libx265)

**Goal:** HDR10 file with VUI, SEI and container metadata all consistent · **Content:** 10-bit PQ BT.2020 master

```bash
ffmpeg -mastering_display "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)" -content_light 1000,400 -i master.mov -map 0:v:0 -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v libx265 -pix_fmt yuv420p10le -x265-params "hdr10-opt=1" -tag:v hvc1 out.mp4
```

Tested with FFmpeg 9.0.2 and x265 4.3: setparams tags the frames, so libx265 writes BT.2020/PQ/BT.2020nc limited-range VUI and the muxer writes colr; -mastering_display/-content_light (input options) attach HDR10 side data, which libx265 turns into mastering-display and content-light SEI and the MP4 muxer into mdcv/clli (MKV: Colour and MasteringMetadata). Use the grade's real mastering display and measured MaxCLL/MaxFALL. The older form with only output -color_* options and x265-params master-display/max-cll gives correct SEI and VUI but no container colr/mdcv/clli in this build.

Sources: [source](https://x265.readthedocs.io/en/master/cli.html), [source](https://github.com/FFmpeg/FFmpeg/blob/master/Changelog), [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c), [source](https://ffmpeg.org/ffmpeg.html), [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)

### Fix wrong color tags without re-encoding

**Goal:** Retag an HDR HEVC/AV1 stream that was marked BT.709 · **Content:** Mis-tagged HDR file

```bash
ffmpeg -i in.mkv -map 0 -c copy -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9:video_full_range_flag=0 out.mkv   (AV1: -bsf:v av1_metadata=color_primaries=9:transfer_characteristics=16:matrix_coefficients=9:color_range=tv)
```

Bitstream filters rewrite header fields only, so quality is untouched. They cannot add HDR10 mastering/CLL SEI; add those via -mastering_display/-content_light on re-encode, MP4Box -hdr, or mkvmerge --max-luminance etc. Tested with 9.0.2 (hevc_metadata form, stream copy into MKV).

Sources: [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html)

### Verify an HDR file

**Goal:** Confirm HDR10 / HLG / HDR10+ / DV signaling end to end · **Content:** Any finished HDR deliverable

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string,pix_fmt,color_range,color_space,color_transfer,color_primaries,chroma_location:stream_side_data_list -of json out.mp4 ; ffprobe -v error -select_streams v:0 -read_intervals %+#1 -show_frames -show_entries frame=side_data_list -of json out.mp4 ; ffmpeg -i out.mp4 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | hdr10plus_tool --verify extract - ; ffmpeg -i out.mp4 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool extract-rpu -l 200 - -o rpu.bin && dovi_tool info -i rpu.bin -s ; MP4Box -infox out.mp4 ; MP4Box -diso out.mp4 -out boxes.xml (or mkvmerge -J out.mkv)
```

Stream fields show VUI/container tags (expect bt2020 / smpte2084 or arib-std-b67 / bt2020nc / tv, hvc1 or dvh1 tag); stream side data shows DOVI configuration; the first frame's side data shows mastering display, content light and HDR10+; the tools confirm dynamic metadata; MP4Box -infox shows the DV configuration, and the -diso box dump shows colr, mdcv and clli.

Sources: [source](https://github.com/quietvoid/hdr10plus_tool), [source](https://github.com/quietvoid/dovi_tool), [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c), [source](https://mkvtoolnix.download/doc/NEWS.md), [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)

### Strip Dolby Vision to plain HDR10

**Goal:** Fallback file for players that mis-handle DV · **Content:** DV profile 7 or 8.1

```bash
ffmpeg -i in.mkv -map 0 -c copy -bsf:v dovi_rpu=strip=1 out.mkv   (or: dovi_tool remove in.hevc -o BL.hevc)
```

Removes RPU and DV configuration; the HDR10 base and its static SEI remain. Not valid for profile 5, whose base is IPT rather than HDR10.

Sources: [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html), [source](https://github.com/quietvoid/dovi_tool)

## Tools

| binary | version | license | homepage | homebrew |
|---|---|---|---|---|
| dovi_tool | dovi_tool 2.3.4 | MIT | https://github.com/quietvoid/dovi_tool | dovi_tool |
| hdr10plus_tool | hdr10plus_tool 1.7.2 | MIT | https://github.com/quietvoid/hdr10plus_tool | hdr10plus_tool |
| MP4Box | MP4Box - GPAC version 26.07-revrelease | LGPL-2.1-or-later | https://gpac.io/ | gpac |
| mkvmerge | mkvmerge v103.0 ('The Darkness') 64-bit | GPL-2.0-or-later | https://mkvtoolnix.download/ | mkvtoolnix |
| ffmpeg | ffmpeg version 9.0.2 | GPL-3.0-or-later (Homebrew build) | https://ffmpeg.org/ | ffmpeg |

## Code tables

### standard

ITU-T H.273 (CICP), same numbers as ISO/IEC 23091-2, HEVC/AVC VUI tables E-3/E-4/E-5, AV1 section 6.4.2 and Matroska Colour

### colorPrimaries

| code | name | mp4box | ffmpeg |
|---|---|---|---|
| 0 | Reserved | reserved0 | - |
| 1 | BT.709 / sRGB / BT.1361 / IEC 61966-2-4 | BT709 | bt709 |
| 2 | Unspecified | undef | unknown/unspecified |
| 3 | Reserved | reserved3 | - |
| 4 | BT.470 System M (FCC 1953) | BT470M | bt470m |
| 5 | BT.470 System B/G, BT.601 625-line (PAL/SECAM) | BT470G | bt470bg |
| 6 | SMPTE 170M, BT.601 525-line (NTSC) | SMPTE170 | smpte170m |
| 7 | SMPTE 240M (same primaries as 6) | SMPTE240 | smpte240m |
| 8 | Generic film (Illuminant C) | FILM | film |
| 9 | BT.2020 / BT.2100 | BT2020 | bt2020 |
| 10 | SMPTE ST 428-1 (CIE 1931 XYZ) | SMPTE428 | smpte428 |
| 11 | SMPTE RP 431-2 (DCI-P3, DCI white) | SMPTE431 | smpte431 |
| 12 | SMPTE EG 432-1 (P3-D65 / Display P3) | SMPTE432 | smpte432 |
| 22 | EBU Tech 3213-E / JEDEC P22 | EBU3213 | ebu3213/jedec-p22 |

### transferCharacteristics

| code | name | mp4box | ffmpeg |
|---|---|---|---|
| 0 | Reserved | reserved0 | - |
| 1 | BT.709 | BT709 | bt709 |
| 2 | Unspecified | undef | unknown |
| 3 | Reserved | reserved3 | - |
| 4 | BT.470 M (gamma 2.2) | BT470M | gamma22/bt470m |
| 5 | BT.470 B/G (gamma 2.8) | BT470BG | gamma28/bt470bg |
| 6 | SMPTE 170M / BT.601 | SMPTE170 | smpte170m |
| 7 | SMPTE 240M | SMPTE249 (sic, in MP4Box -h cicp) | smpte240m |
| 8 | Linear | Linear | linear |
| 9 | Logarithmic 100:1 | Log100 | log/log100 |
| 10 | Logarithmic 100*sqrt(10):1 | Log316 | log_sqrt/log316 |
| 11 | IEC 61966-2-4 (xvYCC) | IEC61966 | iec61966-2-4 |
| 12 | BT.1361 extended gamut | BT1361 | bt1361e |
| 13 | IEC 61966-2-1 (sRGB/sYCC) | sRGB | iec61966-2-1 |
| 14 | BT.2020 10-bit (same curve as BT.709) | BT2020_10 | bt2020-10 |
| 15 | BT.2020 12-bit (same curve as BT.709) | BT2020_12 | bt2020-12 |
| 16 | SMPTE ST 2084 PQ (HDR10, DV) | SMPTE2084 | smpte2084 |
| 17 | SMPTE ST 428-1 | SMPTE428 | smpte428 |
| 18 | ARIB STD-B67 HLG | STDB67 | arib-std-b67 |

### matrixCoefficients

| code | name | mp4box | ffmpeg |
|---|---|---|---|
| 0 | Identity / GBR (RGB) | GBR | rgb |
| 1 | BT.709 | BT709 | bt709 |
| 2 | Unspecified | undef | unknown |
| 3 | Reserved | unknown | - |
| 4 | FCC 73.682 | FCC | fcc |
| 5 | BT.470 B/G, BT.601 625 | BT601 | bt470bg |
| 6 | SMPTE 170M, BT.601 525 | SMPTE170 | smpte170m |
| 7 | SMPTE 240M | SMPTE240 | smpte240m |
| 8 | YCgCo | YCgCo | ycgco |
| 9 | BT.2020 non-constant luminance (HDR10/HLG) | BT2020 | bt2020nc |
| 10 | BT.2020 constant luminance | BT2020cl | bt2020c |
| 11 | SMPTE ST 2085 (Y'D'zD'x) | YDzDx | smpte2085 |
| 12 | Chromaticity-derived non-constant luminance | (not listed) | chroma-derived-nc |
| 13 | Chromaticity-derived constant luminance | (not listed) | chroma-derived-c |
| 14 | ICtCp (BT.2100) | (not listed) | ictcp |
| 15 | IPT-C2 (SMPTE ST 2128, Dolby Vision profile 5 style) | (not listed) | ipt-c2 |
| 16 | YCgCo-R even (H.273 v3) | (not listed) | ycgco-re |
| 17 | YCgCo-R odd (H.273 v3) | (not listed) | ycgco-ro |

### videoFullRange

| h273 | meaning | ffmpeg_color_range | mkvmerge | bsf |
|---|---|---|---|---|
| 0 | limited/narrow (video) range | 1 (tv) | 1 | tv (0) |
| 1 | full range | 2 (pc) | 2 | pc (1) |

### chromaSampleLocation

| h273_type | name | ffmpeg_value |
|---|---|---|
| 0 | left | 1 |
| 1 | center | 2 |
| 2 | topleft | 3 |
| 3 | top | 4 |
| 4 | bottomleft | 5 |
| 5 | bottom | 6 |

### commonCombos

| name | primaries | transfer | matrix | range |
|---|---|---|---|---|
| SDR BT.709 | 1 | 1 | 1 | limited |
| HDR10 / DV 8.1 base | 9 | 16 | 9 | limited |
| HLG / DV 8.4 base | 9 | 18 | 9 | limited |
| Display P3 SDR (Apple stills) | 12 | 13 | 1 | full or limited |
| DV profile 5 (IPTPQc2; tags vary by encoder) | 9 | 16 | 2 or 15 | full |

### notes

Values verified against FFmpeg's pixfmt.h enums and `MP4Box -h cicp`; MP4Box's cicp list stops at matrix 11 and lacks 12-17 names. MP4Box prints 'SMPTE249' for transfer 7, a typo for SMPTE 240. DV profile 5 tagging is from general knowledge and differs between sources; treat as unverified.

### sources

- https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/pixfmt.h
- https://en.wikipedia.org/wiki/Coding-independent_code_points
- https://www.itu.int/rec/T-REC-H.273

## Subcommands

### dovi_tool

- convert
- demux
- editor
- export
- extract-rpu
- inject-rpu
- generate
- info
- mux
- plot
- remove
- help

### hdr10plus_tool

- extract
- inject
- remove
- plot
- editor
- help

## Lumora integration

### summary

Lumora uses these tools only for dynamic metadata after the encode: ffmpeg -c:v copy -bsf:v hevc_mp4toannexb dumps Annex B; for DV 8.1 it either retimes the source RPU (dovi_tool -m 2 extract-rpu, two editor passes, info -s frame-count check) or generates new metadata (dovi_tool generate -j), then dovi_tool inject-rpu; for HDR10+ it writes its own JSON and runs hdr10plus_tool inject. It remuxes with MP4Box (-add ...:fps=...[:dvp=8.1] -add file#audio -new) for MP4/MOV, mkvmerge (-o, --default-duration 0:num/denfps, -D) otherwise, or FFmpeg -c copy as a last resort. Static HDR10 signaling comes from the CLI encoders' own flags in encoders.json (x265 --master-display/--max-cll/--hdr10/--hdr10-opt, SVT-AV1 --mastering-display, etc.).

### gaps

- FFmpeg fallback remux to MP4/MOV (ExportEngine) passes neither -tag:v hvc1 nor -strict unofficial: HEVC may be tagged hev1 (Apple playback issue) and any DV loses dvcC. Not verified by running the app.
- MP4Box fps is passed as a decimal; 24000/1001 would be exact.
- DolbyVisionRetimer reads the frame count as the first integer > 1 in `dovi_tool info -s` output, which depends on the summary layout.
- No mkvmerge color/mastering flags are passed; Lumora relies on the bitstream VUI/SEI. Checked with mkvmerge v103: muxing a raw HEVC elementary stream leaves the Matroska Colour fields empty (mkvmerge -J shows no color properties), so MKV players that read only container metadata see no HDR tags.

## Notes

Scope: every option and subcommand option of dovi_tool 2.3.4 and hdr10plus_tool 1.7.2, and every option in the captured MP4Box (general and import) and mkvmerge help, is listed. For FFmpeg, the options matching color, side data, mastering, HDR, Dolby Vision and the video bitstream filters are listed; audio-only and unrelated bitstream filters (opus_metadata, pcm_rechunk, noise, dv_error_marker, eia608_to_smpte436m, hapqa_extract) are left out, as is the rest of the ~14,000-line help. dovi_tool demux/export/mux/plot/remove help was read by running `dovi_tool <cmd> --help` because the captured help file lacked those sections; MP4Box -info comes from `MP4Box -h dump`. The MP4Box -hdr XML format comes from GPAC source code because no doc describes it. FFmpeg 9.1 adds a side_data bitstream filter that this 9.0.2 build does not have (Changelog). Fact-check 2026-11-12: the HDR10 example, the DV/HDR10+ tool syntax, MP4Box colr/dvp/hdr and mkvmerge -J were run against the installed binaries.

## All options

571 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--start-code`](#start-code) | four, annex-b | four | Picks the NAL start-code length written to HEVC output: always 4 bytes, or the variable length the Annex B spec allows (close to what x265 writes). |  |  |
| [`[input_pos]`](#input-pos) | HEVC file or - for stdin | not stated | Positional form of the input HEVC file; '-' reads an Annex B stream piped from another program (typically ffmpeg). | ✓ |  |
| [`--input`](#input) | HEVC file or - | not stated | Input HEVC (Annex B) file to convert. | ✓ |  |
| [`--output`](#output) | file | not stated | Where the converted single-layer HEVC is written. | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC file or - | not stated | Positional input: a single-track dual-layer (profile 7) HEVC stream. | ✓ |  |
| [`--input`](#input) | HEVC file or - | not stated | Dual-layer HEVC input to split. | ✓ |  |
| [`--bl-out`](#bl-out) | file | not stated (README: base layer output matches the remove subcommand, which writes BL.hevc) | Output path for the base layer. | ✓ |  |
| [`--el-out`](#el-out) | file | not stated | Output path for the enhancement layer (which also carries the RPU). | ✓ |  |
| [`--el-only`](#el-only) | flag | off | Writes only the enhancement-layer file and skips the base layer. | ✓ |  |
| [`[input_pos]`](#input-pos) | RPU .bin | not stated | Positional input RPU file. | ✓ |  |
| [`--input`](#input) | RPU .bin | not stated | Binary RPU to edit. | ✓ | ✓ |
| [`--rpu-out`](#rpu-out) | file | not stated | Where the edited RPU is written. | ✓ |  |
| [`[input_pos]`](#input-pos) | RPU .bin | not stated | Positional input RPU file. | ✓ |  |
| [`--input`](#input) | RPU .bin | not stated | Binary RPU to export. | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC/MKV file or - | not stated | Positional input video. | ✓ |  |
| [`--input`](#input) | HEVC file, Matroska file, or - | not stated | Video to pull the RPU from. | ✓ | ✓ |
| [`--rpu-out`](#rpu-out) | file | not stated (README examples write RPU.bin) | Where the extracted binary RPU goes. | ✓ |  |
| [`--limit`](#limit) | N frames | not stated (whole file) | Stops after N frames; handy for a quick probe. | ✓ |  |
| [`--track-number`](#track-number) | track number | not stated | Which video track to read when the input is Matroska. | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC file | not stated | Positional input HEVC. | ✓ |  |
| [`--input`](#input) | HEVC file | not stated | Encoded HEVC (Annex B) that will receive the RPU. | ✓ | ✓ |
| [`--output`](#output) | file | not stated (README example: injected_output.hevc) | Output HEVC with RPU NAL units. | ✓ |  |
| [`--rpu-out`](#rpu-out) | file | not stated | Where the generated RPU is written. | ✓ |  |
| [`[input_pos]`](#input-pos) | RPU .bin | not stated | Positional input RPU file. | ✓ |  |
| [`--input`](#input) | RPU .bin | not stated | RPU file to inspect. | ✓ |  |
| [`--bl`](#bl) | HEVC file or - | not stated (required) | Base-layer HEVC to interleave into. | ✓ |  |
| [`--el`](#el) | HEVC file | not stated (required) | Enhancement-layer HEVC (with RPU) to interleave. | ✓ |  |
| [`--output`](#output) | file | not stated | Output BL+EL+RPU HEVC. | ✓ |  |
| [`[input_pos]`](#input-pos) | RPU .bin | not stated | Positional input RPU file. | ✓ |  |
| [`--input`](#input) | RPU .bin | not stated | RPU to plot. | ✓ |  |
| [`--output`](#output) | PNG file | not stated | Where the PNG chart is written. | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC file or - | not stated | Positional input HEVC. | ✓ |  |
| [`--input`](#input) | HEVC file or - | not stated | HEVC whose EL and RPU should be stripped. | ✓ |  |
| [`--output`](#output) | file | not stated (README: BL.hevc) | Output: plain base layer (HDR10/SDR/HLG depending on profile). | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC file, Matroska file, or - (stdin) | not stated | Positional form of the input video. | ✓ |  |
| [`--input`](#input) | HEVC file, Matroska file, or - (stdin) | not stated | Input video bitstream. | ✓ |  |
| [`[input_pos]`](#input-pos) | HEVC file | not stated | Positional form of the input video. | ✓ |  |
| [`--input`](#input) | HEVC file | not stated | Input video bitstream. | ✓ | ✓ |
| [`[input_pos]`](#input-pos) | HEVC file or - | not stated | Positional form of the input video. | ✓ |  |
| [`--input`](#input) | HEVC file or - | not stated | Input video bitstream. | ✓ |  |
| [`--output`](#output) | JSON file | not stated (without it, only a partial parse/check is done) | Where the extracted HDR10+ JSON is written. | ✓ |  |
| [`--limit`](#limit) | N frames | not stated (whole file) | Stops after N frames. | ✓ |  |
| [`--output`](#output) | HEVC file | not stated | Output HEVC with HDR10+ SEI messages. | ✓ |  |
| [`--output`](#output) | HEVC file | not stated | Output HEVC with HDR10+ SEI removed. | ✓ |  |
| [`[input_pos]`](#input-pos) | HDR10+ JSON | not stated | Positional input JSON. | ✓ |  |
| [`--input`](#input) | HDR10+ JSON | not stated | HDR10+ JSON to edit. | ✓ |  |
| [`--json-out`](#json-out) | JSON file | not stated | Where the edited JSON is written. | ✓ |  |
| [`[input_pos]`](#input-pos) | HDR10+ JSON | not stated | Positional input JSON. | ✓ |  |
| [`--input`](#input) | HDR10+ JSON | not stated | JSON to plot. | ✓ |  |
| [`--output`](#output) | PNG file | not stated | PNG output path. | ✓ |  |
| [`-add`](#add) | URL[#FRAGMENT][:opt1...:optN=val]; several inputs joined with + | not stated | Imports tracks from a file into the destination MP4, creating it if needed. | ✓ | ✓ |
| [`-cat`](#cat) | URL[+URL...] | not stated | Appends samples of another file to matching tracks (concatenation). |  |  |
| [`-out`](#out) | file | input file is overwritten | Output file name; without it MP4Box rewrites the input in place. |  |  |
| [`-new`](#new) | flag | off | Forces creation of a fresh destination file instead of adding to an existing one. |  | ✓ |
| [`-newfs`](#newfs) | flag | off | Creates a new file without a temporary file while still interleaving (less precise interleave). |  |  |
| [`-flat`](#flat) | flag | off | Writes all media first with no interleaving; faster to write, worse for progressive playback. |  |  |
| [`-inter`](#inter) | duration | 0.5 | Interleave chunk duration (help says ms, the general text says 0.5 s by default; 0 disables). |  |  |
| [`-frag`](#frag) | duration in ms | not stated | Writes a fragmented MP4 with fragments of the given duration (disables interleaving). |  |  |
| [`-brand`](#brand) | ABCD or ABCD:v | not stated | Sets the file's major brand. | ✓ |  |
| [`-ab`](#ab) | 4CC | not stated | Adds a compatible brand (for example dby1 for Dolby content). | ✓ |  |
| [`-rb`](#rb) | 4CC | not stated | Removes a compatible brand. |  |  |
| [`-rem`](#rem) | track ID | not stated | Removes a track from the file. |  |  |
| [`fps`](#fps) | number, TS-inc or TS/inc | 25 for raw video other than H.263 (which defaults to 15) | Frame rate assigned to raw elementary streams on import. |  | ✓ |
| [`xps_inband`](#xps-inband) | flag | off | Keeps parameter sets in the samples (hev1/avc3 style) instead of only in the sample description. |  |  |
| [`xps_inbandx`](#xps-inbandx) | flag | off | Like xps_inband but also keeps the first parameter sets in the sample description. |  |  |
| [`max_lid`](#max-lid) | N | all layers | Highest HEVC layer ID to import (layered HEVC). |  |  |
| [`max_tid`](#max-tid) | N | all sublayers | Highest temporal sublayer to import. |  |  |
| [`stype`](#stype) | 4CC | not stated | Forces the sample description type code; the help warns this can easily break the file. | ✓ |  |
| [`rescale`](#rescale) | TS or fraction | not stated | Forces a media timescale and rescales the duration. |  |  |
| [`sampdur`](#sampdur) | D or D/TS | not stated | Forces all sample durations, to repair constant-frame-rate files with broken timing. |  |  |
| [`negctts`](#negctts) | flag | off | Uses negative composition offsets (iso4 brand) instead of edit lists for B-frame delay. |  |  |
| [`noedit`](#noedit) | flag | off | Do not write an edit list for B-frame video. |  |  |
| [`fmt`](#fmt) | format | not stated | Overrides format probing for the source. |  |  |
| [`ext`](#ext) | extension | not stated | Overrides the file extension used for format detection. |  |  |
| [`--output`](#output) | file | not stated (required) | Destination Matroska file. |  | ✓ |
| [`--video-tracks`](#video-tracks) | n,m,... | all video tracks | Copies only the listed video tracks from the next source file. |  |  |
| [`--no-video`](#no-video) | flag | off | Copies no video from the next source file. |  | ✓ |
| [`--no-audio`](#no-audio) | flag | off | Copies no audio from the next source file. |  |  |
| [`--default-duration`](#default-duration) | TID:Xs\|ms\|us\|ns\|fps | derived from container/bitstream where possible | Forces the frame duration (frame rate) of a track; required for raw elementary streams that carry no timing. |  | ✓ |
| [`--track-name`](#track-name) | TID:name | not stated | Sets a track title. |  |  |
| [`--language`](#language) | TID:lang (BCP 47) | not stated | Sets the track language. |  |  |
| [`-tag`](#tag) | fourcc/tag | not stated | Forces the codec tag (sample entry 4CC). | ✓ | ✓ |
| [`-c`](#c) | encoder name or copy | not stated | Selects the encoder, or 'copy' to pass the bitstream through untouched (keeps in-band SEI and RPU). | ✓ | ✓ |
| [`-bsf`](#bsf) | comma-separated bitstream filters with =opt=val | not stated | Applies bitstream filters to packets (input or output since FFmpeg 7.0). | ✓ | ✓ |
| [`-movflags`](#movflags) | includes write_colr, prefer_icc, write_gama, faststart, frag_keyframe, cmaf, dash, ... | 0 | MOV/MP4 muxer flags. | ✓ |  |
| [`(no options)`](#no-options) | filter name | auto-inserted for raw HEVC/mpegts output | Converts length-prefixed HEVC (MP4/MKV style) to start-code Annex B, the format dovi_tool and hdr10plus_tool read. | ✓ | ✓ |
| [`-old-inter`](#old-inter) | duration (ms) | not stated | Interleaving like -inter but without drift correction. |  |  |
| [`-tight`](#tight) | flag | off | Sample-level interleaving: fewer disk seeks on playback at the cost of a slightly larger file. |  |  |
| [`-co64`](#co64) | flag | off | Forces 64-bit chunk offsets (co64) in the output. |  |  |
| [`-no-sys`](#no-sys) | flag | on when creating regular AV content (per help) | Removes MPEG-4 Systems information except the IOD. |  |  |
| [`-no-iod`](#no-iod) | flag | off | Removes the MPEG-4 InitialObjectDescriptor. |  |  |
| [`-mfra`](#mfra) | flag | off | Adds a movie fragment random access (mfra) index when fragmenting; ignored in DASH mode. |  |  |
| [`-isma`](#isma) | flag | off | Rewrites the file as ISMA 1.0. |  |  |
| [`-ismax`](#ismax) | flag | off | Like -isma and also removes all clock references. |  |  |
| [`-3gp`](#3gp) | flag | off (always on for .3gp/.3g2/.3gpp output) | Rewrites the file as 3GPP/3GPP2 without MPEG-4 Systems info; some tracks may be dropped. |  |  |
| [`-ipod`](#ipod) | flag | off | Rewrites the file for iPods and old iTunes. |  |  |
| [`-psp`](#psp) | flag | off | Rewrites the file for Sony PSP devices. |  |  |
| [`-cprt`](#cprt) | text | not stated | Adds a copyright string to the file. |  |  |
| [`-chap`](#chap) | chapter text file (ZoomPlayer, h:m:s time codes, SMPTE codes or CHAPTERX= syntax; formats cannot be mixed) | not stated | Sets chapters from a text file. |  |  |
| [`-chapqt`](#chapqt) | chapter text file | not stated | Sets chapters from a file using QuickTime text-track signaling. |  |  |
| [`-set-track-id`](#set-track-id) | tkID:id2 | not stated | Changes a track's ID to id2. |  |  |
| [`-swap-track-id`](#swap-track-id) | tkID1:tkID2 | not stated | Swaps the IDs of two tracks. |  |  |
| [`-rap`](#rap) | track ID | not stated | Keeps only random access (sync) samples in the given track. |  |  |
| [`-refonly`](#refonly) | track ID | not stated | Removes all non-reference pictures from the given track. |  |  |
| [`-enable`](#enable) | track ID | not stated | Marks the given track as enabled. |  |  |
| [`-disable`](#disable) | track ID | not stated | Marks the given track as disabled. |  |  |
| [`-timescale`](#timescale) | ticks per second | 600 | Sets the movie timescale. |  |  |
| [`-set-vexu`](#set-vexu) | flag | off | Adds a vexu box to an MV-HEVC (stereo) MP4. |  |  |
| [`-hero-eye`](#hero-eye) | 0 none, 1 left, 2 right | 0 | Sets hero_eye_indicator in the HeroStereoEyeDescriptionBox for stereo video. |  |  |
| [`-lang`](#lang) | [tkID=]LAN (BCP-47 code) | all tracks when no track ID is given | Sets the language of one track or of all tracks. |  |  |
| [`-delay`](#delay) | tkID=TIME (ms or N/D seconds; >0 delay, <0 skip) | not stated | Sets a start delay or initial skip for a track. |  |  |
| [`-mx`](#mx) | tkID=M1:...:M9 (16.16 fixed point or hex) | not stated | Sets the track transformation matrix. |  |  |
| [`-kind`](#kind) | tkID=schemeURI=value or all=schemeURI=value | not stated | Adds a kind (role) to one track or all tracks. |  |  |
| [`-kind-rem`](#kind-rem) | tkID=schemeURI=value or all=schemeURI=value | not stated | Removes a kind from one track or all tracks. |  |  |
| [`-name`](#name) | tkID=NAME (UTF-8) | not stated | Sets the track handler name. |  |  |
| [`-tags`](#tags) | tag list (see MP4Box -h tags) | not stated | Writes iTunes-style metadata tags. |  |  |
| [`-group-add`](#group-add) | colon-separated refTrack=, switchID=, criteria=, trackID= (order matters) | not stated | Creates alternate/switch group information. |  |  |
| [`-group-rem-track`](#group-rem-track) | track ID | not stated | Removes a track from its group. |  |  |
| [`-group-rem`](#group-rem) | track ID | not stated | Removes the group the track belongs to. |  |  |
| [`-group-clean`](#group-clean) | flag | off | Removes all grouping information from all tracks. |  |  |
| [`-ref`](#ref) | tkID:R4CC:refID (refID 0 removes) | not stated | Adds or removes a track reference of type R4CC. |  |  |
| [`-keep-utc`](#keep-utc) | flag | off | Keeps UTC timing information after editing. |  |  |
| [`-udta`](#udta) | tkID:type=CODE:box=\|src=\|str=... (tkID 0 = movie) | not stated | Sets or removes user data (udta) for a track or the movie. |  |  |
| [`-patch`](#patch) | [tkID=]FILE | not stated | Applies a box patch file, optionally to one track. |  |  |
| [`-bo`](#bo) | flag | off | Keeps the box order of the input file. |  |  |
| [`-init-seg`](#init-seg) | file | not stated | Uses the given init segment for dumping or encryption. |  |  |
| [`-zmov`](#zmov) | flag | off | Compresses the moov box (ISOBMFF box compression, or QuickTime style for .mov). |  |  |
| [`-xmov`](#xmov) | flag | off | Like -zmov and also wraps ftyp in otyp. |  |  |
| [`-edits`](#edits) | tkID=EDITS (r, eSTART[-DUR], eSTART,MEDIA[,RATE]) | not stated | Rewrites a track's edit list. |  |  |
| [`-moovpad`](#moovpad) | bytes (0 disables) | not stated | Reserves padding after moov for later in-place edits. |  |  |
| [`-no-inplace`](#no-inplace) | flag | off | Disables in-place rewriting. |  |  |
| [`-time`](#time) | [tkID=]DAY/MONTH/YEAR-H:M:S | not stated | Sets the movie or track creation time. |  |  |
| [`-mtime`](#mtime) | tkID=DAY/MONTH/YEAR-H:M:S | not stated | Sets the media creation time. |  |  |
| [`dur`](#dur) | seconds, NUM/DEN, or negative frame count | not stated | Imports only the given duration of the source. |  |  |
| [`start`](#start) | seconds | not stated | Start time in the source (not supported by every source). |  |  |
| [`lang`](#lang) | language code | not stated | Sets the imported track's language. |  |  |
| [`delay`](#delay) | ms or N/D seconds (>0 delay, <0 skip) | not stated | Sets the imported track's initial delay or skip. |  |  |
| [`mx`](#mx) | same as -mx | not stated | Sets the track matrix on import. |  |  |
| [`name`](#name) | text | not stated | Sets the track handler name on import. |  |  |
| [`hdlr`](#hdlr) | 4CC | not stated | Sets the track handler type. |  |  |
| [`tkhd`](#tkhd) | hex flags or enable, movie, preview, size_ar (+= / -= to add or remove) | not stated | Sets track header flags. |  |  |
| [`disable`](#disable) | flag (disable=no forces enabling) | off | Imports the track as disabled. |  |  |
| [`group`](#group) | G (0 = first free group) | not stated | Puts the track in alternate group G. |  |  |
| [`rap`](#rap) | flag | off | Imports only random access samples. |  |  |
| [`refs`](#refs) | flag | off | Imports only reference pictures. |  |  |
| [`trailing`](#trailing) | flag | off | Keeps trailing zero bytes in AVC/HEVC samples. |  |  |
| [`agg`](#agg) | N | not stated | Same as -agg: aggregates N audio frames per sample (3GP only). |  |  |
| [`dref`](#dref) | flag | off | Same as -dref: references media in the source file instead of copying it. |  |  |
| [`keep_refs`](#keep-refs) | flag | off | Keeps track references when importing a single track. |  |  |
| [`nodrop`](#nodrop) | flag | off | Same as -no-drop (constant frame rate for AVI). |  |  |
| [`packed`](#packed) | flag | off | Same as -packed. |  |  |
| [`sbr`](#sbr) | flag | off | Same as -sbr. |  |  |
| [`sbrx`](#sbrx) | flag | off | Same as -sbrx. |  |  |
| [`ovsbr`](#ovsbr) | flag | off | Same as -ovsbr. |  |  |
| [`ps`](#ps) | flag | off | Same as -ps. |  |  |
| [`psx`](#psx) | flag | off | Same as -psx. |  |  |
| [`asemode`](#asemode) | v0-s, v0-2, v0-bs, v1, v1-qt | v0-s | Chooses how the audio sample entry is written (MPEG v0/v1 or QuickTime v1) and how the channel count is taken. |  |  |
| [`audio_roll`](#audio-roll) | N | not stated | Adds a roll sample group with distance N to audio tracks. |  |  |
| [`roll`](#roll) | N | not stated | Adds a roll sample group with distance N. |  |  |
| [`proll`](#proll) | N | not stated | Adds a pre-roll sample group with distance N. |  |  |
| [`mpeg4`](#mpeg4) | flag | off | Same as -mpeg4. |  |  |
| [`svc`](#svc) | flag | off | Imports SVC/LHVC with explicit signaling (no AVC base compatibility). |  |  |
| [`nosvc`](#nosvc) | flag | off | Drops SVC/LHVC data on import. |  |  |
| [`svcmode`](#svcmode) | split, merge, splitbase, splitnox, splitnoxib | not stated | Chooses how SVC/LHVC layers are split into tracks. |  |  |
| [`temporal`](#temporal) | split, splitbase, splitnox | not stated | Chooses how HEVC/LHVC temporal sublayers are split into tracks. |  |  |
| [`subsamples`](#subsamples) | flag | off | Adds sub-sample information for AVC+SVC. |  |  |
| [`deps`](#deps) | flag | off | Imports sample dependency information for AVC and HEVC. |  |  |
| [`ccst`](#ccst) | flag | off | Adds a default HEIF ccst box to the visual sample entry. |  |  |
| [`tiles`](#tiles) | flag | off | Adds HEVC tile signaling and NALU maps without splitting tiles into tracks. |  |  |
| [`split_tiles`](#split-tiles) | flag | off | Splits HEVC tiles into separate tile tracks. |  |  |
| [`chap`](#chap) | flag | off | Marks the imported track as a chapter track. |  |  |
| [`chapter`](#chapter) | name | not stated | Adds one Nero-style chapter covering the whole file. |  |  |
| [`chapfile`](#chapfile) | file | not stated | Adds a Nero-style chapter file. |  |  |
| [`layout`](#layout) | WxH[xXxY][xLAYER] (0 = max of existing tracks) | not stated | Sets the track layout. |  |  |
| [`timescale`](#timescale) | TS | not stated | Sets the imported media timescale. |  |  |
| [`moovts`](#moovts) | TS (negative = timescale of the first imported track) | not stated | Sets the movie timescale. |  |  |
| [`rvc`](#rvc) | RVC configuration | not stated | Sets an RVC configuration for the media. |  |  |
| [`profile`](#profile) | integer or high444, high, extended, main, baseline | not stated | Overrides the AVC profile. |  |  |
| [`level`](#level) | integer (< 6 read as decimal) | not stated | Overrides the AVC level. |  |  |
| [`compat`](#compat) | flags | not stated | Forces the H.264 profile compatibility flags. |  |  |
| [`keepav1t`](#keepav1t) | flag | off | Keeps AV1 temporal delimiter OBUs in the samples. |  |  |
| [`dlba`](#dlba) | no, auto, N | not stated | Controls Dolby Atmos signaling for E-AC-3. |  |  |
| [`font`](#font) | font name | Serif | Font name for text import. |  |  |
| [`size`](#size) | points | 18 | Font size for text import. |  |  |
| [`text_layout`](#text-layout) | WxHxXxY (Y=-1 = bottom) | not stated | Text track layout. |  |  |
| [`swf-global`](#swf-global) | flag | off | SWF import: puts all SWF defines in the first scene replace. |  |  |
| [`swf-no-ctrl`](#swf-no-ctrl) | flag | off | SWF import: uses one stream for movie control and dictionary (disables ActionScript). |  |  |
| [`swf-no-text`](#swf-no-text) | flag | off | SWF import: removes all SWF text. |  |  |
| [`swf-no-font`](#swf-no-font) | flag | off | SWF import: removes embedded SWF fonts. |  |  |
| [`swf-no-line`](#swf-no-line) | flag | off | SWF import: removes lines from SWF shapes. |  |  |
| [`swf-no-grad`](#swf-no-grad) | flag | off | SWF import: removes gradients from SWF shapes. |  |  |
| [`swf-quad`](#swf-quad) | flag | off | SWF import: uses quadratic instead of cubic Bezier curves. |  |  |
| [`swf-xlp`](#swf-xlp) | flag | off | SWF import: supports line transparency and scalability. |  |  |
| [`swf-ic2d`](#swf-ic2d) | flag | off | SWF import: uses the indexed curve 2D hardcoded proto. |  |  |
| [`swf-same-app`](#swf-same-app) | flag | off | SWF import: reuses appearance nodes. |  |  |
| [`swf-flatten`](#swf-flatten) | angle (0 = no flattening) | not stated | SWF import: merges lines whose complementary angle is below the value. |  |  |
| [`kind`](#kind) | schemeURI=value | not stated | Sets the kind (role) of the imported track. |  |  |
| [`txtflags`](#txtflags) | hex (+= / -= to add or remove) | not stated | Sets text track display flags. |  |  |
| [`rate`](#rate) | bps (0 removes btrt) | not stated | Sets average and max bitrate in the btrt box. |  |  |
| [`stz2`](#stz2) | flag | off | Uses the compact sample size table. |  |  |
| [`tc`](#tc) | [d]FPS[/den],h,m,s,f[,framespertick] | not stated | Injects a single QuickTime timecode. |  |  |
| [`edits`](#edits) | same syntax as -edits | not stated | Overrides the edit list. |  |  |
| [`lastsampdur`](#lastsampdur) | empty (previous duration), ms, or N/D seconds | not stated | Sets the duration of the last sample. |  |  |
| [`ID`](#id) | 0 keep source ID, -1 ignore source ID, other = requested ID | 0 | Sets the target track ID. |  |  |
| [`tkgp`](#tkgp) | TYPE,N (negative N removes) | not stated | Assigns the track to a track group. |  |  |
| [`tkidx`](#tkidx) | position (1 = first) | not stated | Sets the track's position in the track list. |  |  |
| [`extk`](#extk) | flag | off | Adds the track as an external track. |  |  |
| [`times`](#times) | timestamp file (cts or dts cts per line, # timescale=V) | not stated | Rewrites timestamps from a file. |  |  |
| [`-catx`](#catx) | URL[+ADD_COMMAND] | not stated | Like -cat but new tracks can be added before concatenation. |  |  |
| [`-catpl`](#catpl) | playlist file (one file per line, # comments) | not stated | Concatenates every file in a playlist as if each were passed to -cat. |  |  |
| [`-unalign-cat`](#unalign-cat) | flag | off | Does not align sample timestamps between tracks when concatenating. |  |  |
| [`-force-cat`](#force-cat) | flag | off | Skips the media configuration check when concatenating; the help warns this may break the result. |  |  |
| [`-keep-sys`](#keep-sys) | flag | off | Keeps MPEG-4 Systems info when adding or concatenating ISOBMFF files. |  |  |
| [`-dref`](#dref) | flag | off | References media data in the original file instead of copying it (not usable for AVC/HEVC). |  |  |
| [`-no-drop`](#no-drop) | flag | off | Forces constant frame rate when importing AVI video. |  |  |
| [`-packed`](#packed) | flag | off | Forces packed bitstream for raw MPEG-4 Part 2 ASP import. |  |  |
| [`-sbr`](#sbr) | flag | off | Backward-compatible AAC-SBR signaling. |  |  |
| [`-sbrx`](#sbrx) | flag | off | Non-backward-compatible AAC-SBR signaling. |  |  |
| [`-ps`](#ps) | flag | off | Backward-compatible AAC-PS signaling. |  |  |
| [`-psx`](#psx) | flag | off | Non-backward-compatible AAC-PS signaling. |  |  |
| [`-ovsbr`](#ovsbr) | flag | off | Oversampled SBR import. |  |  |
| [`-mpeg4`](#mpeg4) | flag | off | Forces MPEG-4 sample descriptions where possible (MPEG-4 AAC signaling even for MPEG-2 AAC). |  |  |
| [`-agg`](#agg) | N (max 15) | not stated | Aggregates N audio frames per sample (3GP media only). |  |  |
| [`--webm`](#webm) | flag | off | Writes a WebM-compliant file. |  |  |
| [`--title`](#title) | title | not stated | Sets the segment title. |  |  |
| [`--global-tags`](#global-tags) | XML file | not stated | Reads global tags from an XML file. |  |  |
| [`--chapters`](#chapters) | file | not stated | Reads chapters from a file. |  |  |
| [`--chapter-language`](#chapter-language) | language | not stated | Sets the language element of chapter entries. |  |  |
| [`--chapter-charset`](#chapter-charset) | charset | not stated | Charset of a simple chapter file. |  |  |
| [`--chapter-sync`](#chapter-sync) | d[,o[/p]] | not stated | Shifts chapter timestamps by d ms and optionally scales them by o/p to fix drift. |  |  |
| [`--cue-chapter-name-format`](#cue-chapter-name-format) | pattern | not stated | Pattern for chapter names created from cue sheets. |  |  |
| [`--default-language`](#default-language) | language | not stated | Language for all tracks not set with --language. |  |  |
| [`--generate-chapters`](#generate-chapters) | when-appending or interval:<duration> | not stated | Generates chapters automatically. |  |  |
| [`--generate-chapters-name-template`](#generate-chapters-name-template) | template | Chapter <NUM:2> | Name template for generated chapters. |  |  |
| [`--segmentinfo`](#segmentinfo) | file | not stated | Reads segment information from a file. |  |  |
| [`--segment-uid`](#segment-uid) | SID1[,SID2...] | not stated | Sets the segment UIDs. |  |  |
| [`--track-order`](#track-order) | FileID1:TID1,FileID2:TID2,... | sorted by type (video, audio, subtitles, others) | Sets the track order in the output. |  |  |
| [`--cluster-length`](#cluster-length) | n or n ms | not stated | Limits each cluster to n blocks or n milliseconds. |  |  |
| [`--clusters-in-meta-seek`](#clusters-in-meta-seek) | flag | off | Writes meta seek entries for clusters. |  |  |
| [`--timestamp-scale`](#timestamp-scale) | n | not stated | Forces the timestamp scale factor. |  |  |
| [`--enable-durations`](#enable-durations) | flag | off | Writes block durations for all blocks. |  |  |
| [`--no-cues`](#no-cues) | flag | off | Does not write the cue index. |  |  |
| [`--no-date`](#no-date) | flag | off | Does not write the date field in segment info. |  |  |
| [`--date`](#date) | timestamp (UTC or with offset, e.g. 2017-03-28T17:28:00Z) | not stated | Sets the date field. |  |  |
| [`--disable-lacing`](#disable-lacing) | flag | off | Turns off lacing. |  |  |
| [`--disable-track-statistics-tags`](#disable-track-statistics-tags) | flag | off | Does not write track statistics tags. |  |  |
| [`--disable-language-ietf`](#disable-language-ietf) | flag | off | Does not write IETF BCP 47 language elements. |  |  |
| [`--normalize-language-ietf`](#normalize-language-ietf) | canonical, extlang, off | canonical | Normalizes BCP 47 language tags. |  |  |
| [`--stop-after-video-ends`](#stop-after-video-ends) | flag | off | Stops when the primary video track ends and drops the rest of the other tracks. |  |  |
| [`--split`](#split) | d[K,M,G] \| HH:MM:SS \| s \| timestamps:A[,B...] \| parts:start1-end1[,[+]start2-end2...] \| parts-frames:... \| frames:A[,B...] \| chapters:all\|A[,B...] | not stated | Splits the output by size, duration, timestamps, kept parts, frames or chapters. |  |  |
| [`--split-max-files`](#split-max-files) | n | not stated | Creates at most n files when splitting. |  |  |
| [`--link`](#link) | flag | off | Links split files. |  |  |
| [`--link-to-previous`](#link-to-previous) | SID | not stated | Links the first file to the given segment UID. |  |  |
| [`--link-to-next`](#link-to-next) | SID | not stated | Links the last file to the given segment UID. |  |  |
| [`--append-to`](#append-to) | SFID1:STID1:DFID1:DTID1,... | not stated | Controls which track is appended to which track of the preceding file. |  |  |
| [`--append-mode`](#append-mode) | file, track | not stated | How timestamps are computed when appending. |  |  |
| [`+`](#option) | <file1> + <file2> | not stated | Appends file2 to file1. |  |  |
| [`=`](#option) | = <file> | not stated | Stops mkvmerge from looking for and concatenating files with the same base name and a different trailing number. |  |  |
| [`( )`](#option) | ( <file1> <file2> ) | not stated | Treats the listed files as one concatenated file. |  |  |
| [`--attachment-description`](#attachment-description) | text | not stated | Description for the next attachment. |  |  |
| [`--attachment-mime-type`](#attachment-mime-type) | MIME type | not stated | MIME type for the next attachment. |  |  |
| [`--attachment-name`](#attachment-name) | name | not stated | Stored name for the next attachment. |  |  |
| [`--attach-file`](#attach-file) | file | not stated | Attaches a file to the output. |  |  |
| [`--attach-file-once`](#attach-file-once) | file | not stated | Attaches a file to the first output file only. |  |  |
| [`--enable-legacy-font-mime-types`](#enable-legacy-font-mime-types) | flag | off | Uses legacy font MIME types for new and existing attachments. |  |  |
| [`--audio-tracks`](#audio-tracks) | n,m,... | all audio tracks | Copies only the listed audio tracks. |  |  |
| [`--subtitle-tracks`](#subtitle-tracks) | n,m,... | all subtitle tracks | Copies only the listed subtitle tracks. |  |  |
| [`--no-subtitles`](#no-subtitles) | flag | off | Copies no subtitle tracks from this file. |  |  |
| [`--button-tracks`](#button-tracks) | n,m,... | all button tracks | Copies only the listed button tracks. |  |  |
| [`--no-buttons`](#no-buttons) | flag | off | Copies no button tracks. |  |  |
| [`--attachments`](#attachments) | n[:all\|first],m[:all\|first],... | all attachments to all output files | Copies the listed attachments to all or only the first output file. |  |  |
| [`--no-attachments`](#no-attachments) | flag | off | Copies no attachments from this file. |  |  |
| [`--tags`](#tags) | TID:file | not stated | Reads tags for a track from an XML file. |  |  |
| [`--track-tags`](#track-tags) | n,m,... | tags of all tracks | Copies tags only for the listed tracks. |  |  |
| [`--no-track-tags`](#no-track-tags) | flag | off | Copies no track tags. |  |  |
| [`--no-global-tags`](#no-global-tags) | flag | off | Drops the source's global tags. |  |  |
| [`--no-chapters`](#no-chapters) | flag | off | Drops the source's chapters. |  |  |
| [`--regenerate-track-uids`](#regenerate-track-uids) | flag | off | Generates new random track UIDs. |  |  |
| [`--sync`](#sync) | TID:d[,o[/p]] | not stated | Shifts a track's timestamps by d ms and optionally scales them by o/p to fix drift. |  |  |
| [`--default-track-flag`](#default-track-flag) | TID[:bool] | not stated | Sets the default-track flag (0 removes it). |  |  |
| [`--forced-display-flag`](#forced-display-flag) | TID[:bool] | not stated | Sets the forced-display flag (0 removes it). |  |  |
| [`--track-enabled-flag`](#track-enabled-flag) | TID[:bool] | not stated | Sets the track-enabled flag (0 removes it). |  |  |
| [`--hearing-impaired-flag`](#hearing-impaired-flag) | TID[:bool] | not stated | Sets the hearing-impaired flag (0 removes it). |  |  |
| [`--visual-impaired-flag`](#visual-impaired-flag) | TID[:bool] | not stated | Sets the visually-impaired flag (0 removes it). |  |  |
| [`--text-descriptions-flag`](#text-descriptions-flag) | TID[:bool] | not stated | Sets the text-descriptions flag (0 removes it). |  |  |
| [`--original-flag`](#original-flag) | TID[:bool] | not stated | Sets the original-language flag (0 removes it). |  |  |
| [`--commentary-flag`](#commentary-flag) | TID[:bool] | not stated | Sets the commentary flag (0 removes it). |  |  |
| [`--cues`](#cues) | TID:none\|iframes\|all | not stated in help (docs: iframes for video and subtitles, none for audio) | Chooses which frames get cue (index) entries. |  |  |
| [`--timestamps`](#timestamps) | TID:file | not stated | Reads the timestamps for a track from a file. |  |  |
| [`--aac-is-sbr`](#aac-is-sbr) | TID[:0\|1] | not stated | Declares whether an AAC track is HE-AAC/SBR. |  |  |
| [`--reduce-to-core`](#reduce-to-core) | TID | not stated | Keeps only the core of audio with HD extensions. |  |  |
| [`--remove-dialog-normalization-gain`](#remove-dialog-normalization-gain) | TID | not stated | Removes or minimizes dialog normalization gain in the frame headers. |  |  |
| [`--audio-emphasis`](#audio-emphasis) | TID:n\|keyword (see --list-audio-emphasis) | not stated | Sets the audio emphasis header value. |  |  |
| [`--fourcc`](#fourcc) | FOURCC | not stated | Forces the FourCC (video tracks only). |  |  |
| [`--aspect-ratio`](#aspect-ratio) | TID:f\|a/b | not stated | Sets display dimensions from an aspect ratio. |  |  |
| [`--aspect-ratio-factor`](#aspect-ratio-factor) | TID:f\|a/b | not stated | Multiplies the original aspect ratio by a factor and sets display dimensions from it. |  |  |
| [`--field-order`](#field-order) | TID:n (see documentation) | not stated | Sets the field order (docs: 0 progressive, 2 undetermined, 1/6/9/14 interlaced variants). |  |  |
| [`--stereo-mode`](#stereo-mode) | TID:n\|keyword (0-14, see --list-stereo-modes) | not stated | Sets the stereo 3D mode. |  |  |
| [`--projection-type`](#projection-type) | TID:method (0-3) | not stated | Sets the 360-degree projection type (docs: 0 rectangular, 1 equirectangular, 2 cubemap, 3 mesh). |  |  |
| [`--projection-private`](#projection-private) | TID:hex data | not stated | Projection-specific private data. |  |  |
| [`--projection-pose-yaw`](#projection-pose-yaw) | TID:float | not stated | Yaw rotation of the projection. |  |  |
| [`--projection-pose-pitch`](#projection-pose-pitch) | TID:float | not stated | Pitch rotation of the projection. |  |  |
| [`--projection-pose-roll`](#projection-pose-roll) | TID:float | not stated | Roll rotation of the projection. |  |  |
| [`--sub-charset`](#sub-charset) | TID:charset | not stated | Charset used to read text subtitles for conversion to UTF-8. |  |  |
| [`--compression`](#compression) | TID:none\|zlib | not stated | Compression method for VobSub tracks. |  |  |
| [`field_mode`](#field-mode) | auto, bff, tff, prog | auto | Relabels the frames' field order without changing pixels. |  |  |
| [`aud`](#aud) | pass(0), insert(1), remove(2) | pass | Inserts or removes access unit delimiters. |  |  |
| [`sample_aspect_ratio`](#sample-aspect-ratio) | rational 0 to 65535 (table E-1) | 0/1 | Rewrites the VUI sample aspect ratio. |  |  |
| [`overscan_appropriate_flag`](#overscan-appropriate-flag) | -1 to 1 | -1 | Rewrites the VUI overscan flag. |  |  |
| [`tick_rate`](#tick-rate) | rational 0 to UINT32_MAX | 0/1 | Sets the VUI tick rate (time_scale / num_units_in_tick). |  |  |
| [`fixed_frame_rate_flag`](#fixed-frame-rate-flag) | -1 to 1 | -1 | Rewrites the VUI fixed frame rate flag. |  |  |
| [`zero_new_constraint_set_flags`](#zero-new-constraint-set-flags) | true/false | false | Clears constraint_set4_flag and constraint_set5_flag. |  |  |
| [`crop_left`](#crop-left) | -1 to 16880 | -1 | Sets the left frame-cropping offset. |  |  |
| [`crop_right`](#crop-right) | -1 to 16880 | -1 | Sets the right frame-cropping offset. |  |  |
| [`crop_top`](#crop-top) | -1 to 16880 | -1 | Sets the top frame-cropping offset. |  |  |
| [`crop_bottom`](#crop-bottom) | -1 to 16880 | -1 | Sets the bottom frame-cropping offset. |  |  |
| [`delete_filler`](#delete-filler) | 0 to 1 | 0 | Deletes filler data (NAL and SEI). |  |  |
| [`display_orientation`](#display-orientation) | pass(0), insert(1), remove(2), extract(3) | pass | Handles the display orientation SEI. |  |  |
| [`rotate`](#rotate) | -360 to 360 (degrees, anticlockwise) | nan | Rotation written to the display orientation SEI. |  |  |
| [`flip`](#flip) | horizontal, vertical | 0 | Flip written to the display orientation SEI. |  |  |
| [`level`](#level) | auto, 1, 1b, 1.1 ... 6.2 (or level_idc) | -2 (unchanged) | Rewrites the SPS level. |  |  |
| [`overscan_appropriate_flag`](#overscan-appropriate-flag) | bool | auto | Rewrites the LCEVC VUI overscan flag. |  |  |
| [`delete_filler`](#delete-filler) | true/false | false | Deletes filler data from the LCEVC stream. |  |  |
| [`display_aspect_ratio`](#display-aspect-ratio) | rational 0 to 65535 (table 6-3) | 0/1 | Rewrites the MPEG-2 display aspect ratio. |  |  |
| [`frame_rate`](#frame-rate) | rational 0 to UINT32_MAX | 0/1 | Rewrites the MPEG-2 frame rate. |  |  |
| [`ts`](#ts) | expression | TS | Expression for packet PTS and DTS. |  |  |
| [`pts`](#pts) | expression | not stated | Expression for packet PTS. |  |  |
| [`dts`](#dts) | expression | not stated | Expression for packet DTS. |  |  |
| [`duration`](#duration) | expression | DURATION | Expression for packet duration. |  |  |
| [`time_base`](#time-base) | rational 0 to INT_MAX | 0/1 | Output time base. |  |  |
| [`prescale`](#prescale) | true/false | false | Converts to the output time base before evaluating. |  |  |
| [`freq`](#freq) | k/keyframe(0), e/all(1) | k | When to repeat extradata (parameter sets) in packets. |  |  |
| [`remove`](#remove) | 0 to 1 | 0 | Removes the extradata from the bitstream after extracting it. |  |  |
| [`freq`](#freq) | keyframe(0), e/all(1), k(2) | keyframe | When to strip extradata from packets. |  |  |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--mode`](#mode) | 0, 1, 2, 3, 4, 5 | not stated (README: without a mode the RPU is copied untouched) | Chooses how each RPU is rewritten as it passes through convert, demux, mux, extract-rpu or editor. | ✓ | ✓ |
| [`--crop`](#crop) | flag | off | Zeroes the L5 active-area offsets in every RPU, telling Dolby Vision displays there are no letterbox bars. | ✓ | ✓ |
| [`--drop-hdr10plus`](#drop-hdr10plus) | flag | off | When writing HEVC output, skips any HDR10+ SEI messages found in the input so the result carries Dolby Vision only. | ✓ |  |
| [`--edit-config`](#edit-config) | JSON file | not stated | Applies an editor JSON (same format as the editor subcommand) while processing an HEVC file instead of a bare RPU. | ✓ |  |
| [`--discard`](#discard) | flag | off | Throws away the enhancement-layer NAL units so only the base layer plus (converted) RPU remain. | ✓ |  |
| [`--json`](#json) | JSON file | not stated (required) | Edit recipe. | ✓ | ✓ |
| [`--rpu-in`](#rpu-in) | RPU .bin | not stated (required) | RPU file whose entries are inserted, one per frame, after each frame's slices. | ✓ | ✓ |
| [`--json`](#json) | generator config JSON | not stated | Generator config describing the target profile, length, static (L6) values, shots and per-shot L1/L2 data. | ✓ | ✓ |
| [`--hdr10plus-json`](#hdr10plus-json) | HDR10+ JSON | not stated | Builds DV L1 metadata from an HDR10+ JSON (as made by hdr10plus_tool extract), so an HDR10+ title can also carry Dolby Vision. | ✓ |  |
| [`--hdr10plus-peak-source`](#hdr10plus-peak-source) | histogram, histogram99, max-scl, max-scl-luminance | histogram | Chooses which HDR10+ field becomes the per-frame peak brightness when converting HDR10+ to DV. | ✓ |  |
| [`--xml`](#xml) | Dolby CMv2.9/CMv4.0 XML | not stated | Generates the RPU from a Dolby Vision metadata XML exported by a grading tool. | ✓ |  |
| [`--canvas-width`](#canvas-width) | pixels | not stated | Picture width used to compute L5 offsets when the XML is the source. | ✓ |  |
| [`--canvas-height`](#canvas-height) | pixels | not stated | Picture height used to compute L5 offsets when the XML is the source. | ✓ |  |
| [`--madvr-file`](#madvr-file) | madVR measurement file | not stated | Generates L1 metadata from a madVR HDR measurement file. | ✓ |  |
| [`--use-custom-targets`](#use-custom-targets) | flag | off | With a madVR file, uses its per-frame custom target nits if present. | ✓ |  |
| [`--profile`](#profile) | 5, 8.1, 8.4 | not stated | Dolby Vision profile to produce (overrides the JSON). | ✓ |  |
| [`--long-play-mode`](#long-play-mode) | true, false | not stated | Marks every frame as a scene cut (scene refresh) in the generated RPU. | ✓ |  |
| [`--discard`](#discard) | flag | off | Drops the EL video NAL units while muxing, keeping only its RPU (so the output is single-layer). | ✓ |  |
| [`--skip-validation`](#skip-validation) | flag | off | Skips the profile conformance check; nonconforming metadata is labeled profile N/A instead of stopping the tool. | ✓ |  |
| [`--skip-reorder`](#skip-reorder) | flag | off | Keeps metadata in decode order instead of reordering it to presentation order. | ✓ |  |
| [`--json`](#json) | HDR10+ JSON | not stated (required) | HDR10+ metadata to insert before each frame's slices. | ✓ | ✓ |
| [`--json`](#json) | edits JSON | not stated (required) | Edit recipe with `remove` (frames or inclusive ranges) and `duplicate` ({source, offset, length}) lists; removals run first. | ✓ | ✓ |
| [`-par`](#par) | tkID=N:D \| wN:D \| none \| auto \| force | not stated | Sets or clears the pixel aspect ratio, optionally rewriting it in the bitstream (w prefix). |  |  |
| [`-clap`](#clap) | tkID=Wn,Wd,Hn,Hd,HOn,HOd,VOn,VOd or none | not stated | Sets the clean aperture (container-level crop). |  |  |
| [`-hdr`](#hdr) | XML file or none | not stated | Writes HDR10 static metadata boxes (mdcv mastering display and clli light level) into the video track(s) from an XML file; 'none' removes them. | ✓ |  |
| [`dvp`](#dvp) | integer profile, none, optional .compat suffix (none, hdr10, bt709, hlg709, hlg2100, bt2020, brd or integer), optional f prefix | not stated (no DV signaling) | Marks the imported track as Dolby Vision: writes the dvcC/dvvC configuration and DV sample entry for the given profile and base-layer compatibility; 'none' strips DV signaling. | ✓ | ✓ |
| [`dvmdc`](#dvmdc) | 0, 1, 3 | 0 | Sets the Dolby Vision metadata compression field in the DV configuration. | ✓ |  |
| [`hdr`](#hdr) | XML file or none | not stated | Per-track version of -hdr (mdcv/clli from XML). | ✓ |  |
| [`colr`](#colr) | nclc,p,t,m \| nclx,p,t,m,r \| prof,path \| rICC,path \| none | not stated | Writes a container colr box: CICP primaries/transfer/matrix (nclx adds the full-range flag) or an ICC profile; none removes color info. | ✓ |  |
| [`colorprim`](#colorprim) | int or CICP name (MP4Box -h cicp) | not stated | Rewrites colour_primaries in the AVC/HEVC VUI during import. | ✓ |  |
| [`colortfc`](#colortfc) | int or CICP name | not stated | Rewrites transfer_characteristics in the AVC/HEVC VUI. | ✓ |  |
| [`colormx`](#colormx) | int or CICP name | not stated | Rewrites matrix_coefficients in the AVC/HEVC VUI. | ✓ |  |
| [`fullrange`](#fullrange) | yes, on, no, off | not stated | Forces the full-range flag in the VUI (help says AVC/H.264 only). | ✓ |  |
| [`videofmt`](#videofmt) | component, pal, ntsc, secam, mac, undef | not stated | Forces video_format in the AVC/HEVC VUI. |  |  |
| [`bitdepth`](#bitdepth) | VAL | 24 | Sets the bit-depth field of the visual sample entry (24 = 8-bit RGB convention). |  |  |
| [`nosei`](#nosei) | flag | off | Discards every SEI message during import. | ✓ |  |
| [`--cropping`](#cropping) | TID:left,top,right,bottom | not stated | Stores container-level crop values (pixels). |  |  |
| [`--display-dimensions`](#display-dimensions) | TID:widthxheight | not stated | Sets the display size explicitly. |  |  |
| [`--color-matrix-coefficients`](#color-matrix-coefficients) | TID:n (0-10 per docs; H.273 numbering) | not stated | Stores the matrix coefficients in the Matroska Colour element. | ✓ |  |
| [`--color-bits-per-channel`](#color-bits-per-channel) | TID:n (0 = unspecified) | not stated | Stores coded bits per channel. | ✓ |  |
| [`--chroma-subsample`](#chroma-subsample) | TID:hori,vert | not stated | Stores how many chroma samples are dropped per kept sample (4:2:0 = 1,1). | ✓ |  |
| [`--cb-subsample`](#cb-subsample) | TID:hori,vert | not stated | Extra Cb-only subsampling, added to --chroma-subsample (rare formats such as 4:2:1). |  |  |
| [`--chroma-siting`](#chroma-siting) | TID:hori,vert (0 unspecified, 1 top collocated, 2 half) | not stated | Stores where chroma samples sit relative to luma, per axis. | ✓ |  |
| [`--color-range`](#color-range) | TID:n (0 unspecified, 1 broadcast/limited, 2 full, 3 derived from matrix and transfer) | not stated | Stores the color range. | ✓ |  |
| [`--color-transfer-characteristics`](#color-transfer-characteristics) | TID:n (0-18; H.273 numbering) | not stated | Stores the transfer function. | ✓ |  |
| [`--color-primaries`](#color-primaries) | TID:n (H.273 numbering; 1 BT.709, 9 BT.2020, 22 JEDEC P22) | not stated | Stores the color primaries. | ✓ |  |
| [`--max-content-light`](#max-content-light) | TID:n cd/m2 | not stated | Stores MaxCLL (brightest single pixel). | ✓ |  |
| [`--max-frame-light`](#max-frame-light) | TID:n cd/m2 | not stated | Stores MaxFALL (brightest frame average). | ✓ |  |
| [`--chromaticity-coordinates`](#chromaticity-coordinates) | TID:red-x,red-y,green-x,green-y,blue-x,blue-y (CIE 1931, decimal) | not stated | Stores the mastering display primaries. | ✓ |  |
| [`--white-color-coordinates`](#white-color-coordinates) | TID:x,y | not stated | Stores the mastering display white point. | ✓ |  |
| [`--max-luminance`](#max-luminance) | TID:float cd/m2 (below 9999.99) | not stated | Stores the mastering display peak luminance. | ✓ |  |
| [`--min-luminance`](#min-luminance) | TID:float cd/m2 (below 999.9999) | not stated | Stores the mastering display minimum luminance. | ✓ |  |
| [`-mastering_display`](#mastering-display) | G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min) (unsigned ints; xy in 0.00002, L in 0.0001 cd/m2) | not stated | Input, per-stream option that replaces the stream's mastering display metadata with the given values. | ✓ |  |
| [`-content_light`](#content-light) | MaxCLL,MaxFALL (cd/m2) | not stated | Input, per-stream option that overrides MaxCLL/MaxFALL content light metadata. | ✓ |  |
| [`-pix_fmt`](#pix-fmt) | pixel format name (ffmpeg -pix_fmts) | encoder's best match (with a warning) | Chooses the pixel format handed to the encoder; for HDR this must be a 10-bit (or higher) format. | ✓ | ✓ |
| [`-color_primaries`](#color-primaries) | bt709(1) unknown/unspecified(2) bt470m(4) bt470bg(5) smpte170m(6) smpte240m(7) film(8) bt2020(9) smpte428/smpte428_1(10) smpte431(11) smpte432(12) jedec-p22/ebu3213(22) | unknown | Codec-level tag for color primaries. | ✓ | ✓ |
| [`-color_trc`](#color-trc) | bt709(1) unknown(2) gamma22/bt470m(4) gamma28/bt470bg(5) smpte170m(6) smpte240m(7) linear(8) log/log100(9) log_sqrt/log316(10) iec61966-2-4(11) bt1361e(12) iec61966-2-1(13) bt2020-10(14) bt2020-12(15) smpte2084(16) smpte428(17) arib-std-b67(18) | unknown | Tags the transfer characteristic; this is what makes a player treat a stream as PQ (HDR10) or HLG. | ✓ | ✓ |
| [`-colorspace`](#colorspace) | rgb(0) bt709(1) unknown(2) fcc(4) bt470bg(5) smpte170m(6) smpte240m(7) ycgco/ycocg(8) bt2020nc/bt2020_ncl(9) bt2020c/bt2020_cl(10) smpte2085(11) chroma-derived-nc(12) chroma-derived-c(13) ictcp(14) ipt-c2(15) ycgco-re(16) ycgco-ro(17) | unknown | Tags the Y'CbCr matrix coefficients. | ✓ | ✓ |
| [`-color_range`](#color-range) | unknown/unspecified(0) tv/mpeg/limited(1) pc/jpeg/full(2) | unknown | Tags limited vs full range; as an input option it is a hint to the decoder. | ✓ |  |
| [`-chroma_sample_location`](#chroma-sample-location) | unknown/unspecified(0) left(1) center(2) topleft(3) top(4) bottomleft(5) bottom(6) | unknown | Tags where chroma samples sit for subsampled formats. | ✓ |  |
| [`-side_data_prefer_packet`](#side-data-prefer-packet) | replaygain, displaymatrix, spherical, stereo3d, audio_service_type, mastering_display_metadata, content_light_level, icc_profile, exif | not stated | When container (packet) side data and in-bitstream data disagree, prefer the container copy for the listed types. | ✓ |  |
| [`-apply_cropping`](#apply-cropping) | none (0), all (1), codec (2), container (3) | all (ffmpeg man page) | Whether decoded frames are cropped by bitstream conformance window and/or container crop. |  |  |
| [`-dolbyvision`](#dolbyvision) | auto, true/false | auto | Lets the encoder write Dolby Vision RPUs (and configuration) from DV metadata attached to input frames, for example when transcoding a DV source. | ✓ |  |
| [`strip`](#strip) | true/false | false | Removes all Dolby Vision metadata (configuration record and RPU data) from an HEVC or AV1 stream. | ✓ |  |
| [`compression`](#compression) | none(0) limited(1) extended(3) | limited | Recompresses RPU metadata at the chosen level. | ✓ |  |
| [`mode`](#mode) | bl(0) bl_rpu(1) el(2) el_rpu(3) | bl | Splits profile 7 dual-layer HEVC: base layer only, base plus RPU, enhancement layer only, or EL plus RPU. | ✓ |  |
| [`sample_aspect_ratio`](#sample-aspect-ratio) | rational (table E-1) | 0/1 | Rewrites the VUI sample aspect ratio. |  |  |
| [`video_full_range_flag`](#video-full-range-flag) | -1 to 1 (0 limited, 1 full) | -1 | Rewrites the VUI full-range flag. | ✓ |  |
| [`colour_primaries`](#colour-primaries) | -1 to 255 (table E-3 = H.273) | -1 | Rewrites VUI color primaries without re-encoding. | ✓ |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 (table E-4 = H.273) | -1 | Rewrites VUI transfer characteristics. | ✓ |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 (table E-5 = H.273) | -1 | Rewrites VUI matrix coefficients. | ✓ |  |
| [`chroma_sample_loc_type`](#chroma-sample-loc-type) | -1 to 5 (figure E-1) | -1 | Rewrites the VUI chroma sample location (raw H.273 type, 0 = left). | ✓ |  |
| [`crop_left`](#crop-left) | -1 to 16888 | -1 | Sets the conformance-window left crop. |  |  |
| [`crop_right`](#crop-right) | -1 to 16888 | -1 | Sets the conformance-window right crop. |  |  |
| [`crop_top`](#crop-top) | -1 to 16888 | -1 | Sets the conformance-window top crop. |  |  |
| [`crop_bottom`](#crop-bottom) | -1 to 16888 | -1 | Sets the conformance-window bottom crop. |  |  |
| [`width`](#width) | -1 to 16888 | -1 | Width after crop (alternative to crop_right). |  |  |
| [`height`](#height) | -1 to 16888 | -1 | Height after crop (alternative to crop_bottom). |  |  |
| [`video_format`](#video-format) | -1 to 7 (table E-2) | -1 | Rewrites the matching H.264 VUI field without re-encoding. |  |  |
| [`video_full_range_flag`](#video-full-range-flag) | -1 to 1 | -1 | Rewrites the matching H.264 VUI field without re-encoding. | ✓ |  |
| [`colour_primaries`](#colour-primaries) | -1 to 255 (table E-3) | -1 | Rewrites the matching H.264 VUI field without re-encoding. | ✓ |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 (table E-4) | -1 | Rewrites the matching H.264 VUI field without re-encoding. | ✓ |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 (table E-5) | -1 | Rewrites the matching H.264 VUI field without re-encoding. | ✓ |  |
| [`chroma_sample_loc_type`](#chroma-sample-loc-type) | -1 to 5 (figure E-1) | -1 | Rewrites the matching H.264 VUI field without re-encoding. | ✓ |  |
| [`color_primaries`](#color-primaries) | -1 to 255 (section 6.4.2) | -1 | Rewrites AV1 sequence-header color primaries. | ✓ |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 | -1 | Rewrites AV1 transfer characteristics (16 PQ, 18 HLG). | ✓ |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 | -1 | Rewrites AV1 matrix coefficients. | ✓ |  |
| [`color_range`](#color-range) | tv(0) pc(1) | -1 | Rewrites the AV1 color range flag (cannot be set for sRGB/RGB-matrix streams). | ✓ |  |
| [`chroma_sample_position`](#chroma-sample-position) | unknown(0) vertical(1, = left) colocated(2, = top-left) | -1 | Rewrites AV1 chroma sample position (4:2:0 only). | ✓ |  |
| [`color_space`](#color-space) | unknown(0) bt601(1) bt709(2) smpte170(3) smpte240(4) bt2020(5) rgb(7) | -1 | Rewrites the VP9 color space field. | ✓ |  |
| [`color_range`](#color-range) | tv(0) pc(1) | -1 | Rewrites the VP9 range flag (RGB implies full range). | ✓ |  |
| [`color_primaries`](#color-primaries) | auto(-1) unknown(0) bt709(1) bt470bg(5) smpte170m(6) bt2020(9) smpte431(11) smpte432(12) | auto | Rewrites the ProRes frame-header color field. | ✓ |  |
| [`color_trc`](#color-trc) | auto(-1) unknown(0) bt709(1) smpte2084(16) arib-std-b67(18) | auto | Rewrites the ProRes frame-header color field. | ✓ |  |
| [`colorspace`](#colorspace) | auto(-1) unknown(0) bt709(1) smpte170m(6) bt2020nc(9) | auto | Rewrites the ProRes frame-header color field. | ✓ |  |
| [`color_primaries`](#color-primaries) | -1 to 255 (section 5.3.5) | -1 | Rewrites the matching APV color field. | ✓ |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 | -1 | Rewrites the matching APV color field. | ✓ |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 | -1 | Rewrites the matching APV color field. | ✓ |  |
| [`full_range_flag`](#full-range-flag) | tv(0) pc(1) | -1 | Rewrites the matching APV color field. | ✓ |  |
| [`colour_primaries`](#colour-primaries) | -1 to 255 (table 6-7) | -1 | Rewrites the MPEG-2 sequence display extension color field. |  |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 (table 6-8) | -1 | Rewrites the MPEG-2 sequence display extension color field. |  |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 (table 6-9) | -1 | Rewrites the MPEG-2 sequence display extension color field. |  |  |
| [`video_full_range_flag`](#video-full-range-flag) | bool (auto) | auto | Rewrites the LCEVC enhancement stream's VUI color field. | ✓ |  |
| [`colour_primaries`](#colour-primaries) | -1 to 255 | -1 | Rewrites the LCEVC enhancement stream's VUI color field. | ✓ |  |
| [`transfer_characteristics`](#transfer-characteristics) | -1 to 255 | -1 | Rewrites the LCEVC enhancement stream's VUI color field. | ✓ |  |
| [`matrix_coefficients`](#matrix-coefficients) | -1 to 255 | -1 | Rewrites the LCEVC enhancement stream's VUI color field. | ✓ |  |
| [`chroma_sample_loc_type`](#chroma-sample-loc-type) | -1 to 5 | -1 | Rewrites the LCEVC enhancement stream's VUI color field. | ✓ |  |
| [`all`](#all) | bt470m, bt470bg, bt601-6-525, bt601-6-625, bt709, smpte170m, smpte240m, bt2020 | 0 | Sets output matrix, primaries and transfer together. |  |  |
| [`space`](#space) | bt709, fcc, bt470bg, smpte170m, smpte240m, ycgco, gbr, bt2020nc/bt2020ncl | 2 | Output matrix. | ✓ |  |
| [`range`](#range) | tv/mpeg, pc/jpeg | 0 | Output range. | ✓ |  |
| [`primaries`](#primaries) | bt709, bt470m, bt470bg, smpte170m, smpte240m, smpte428, film, smpte431, smpte432, bt2020, jedec-p22/ebu3213, vgamut | 2 | Output primaries (with gamut conversion). | ✓ |  |
| [`trc`](#trc) | bt709, bt470m/gamma22, bt470bg/gamma28, smpte170m, smpte240m, linear, srgb/iec61966-2-1, xvycc/iec61966-2-4, bt2020-10, bt2020-12, vlog | 2 | Output transfer. | ✓ |  |
| [`format`](#format) | yuv420p, yuv420p10, yuv420p12, yuv422p(10/12), yuv444p(10/12) | -1 | Output pixel format. | ✓ |  |
| [`fast`](#fast) | bool | false | Skips gamma and primaries correction (matrix only); faster but mathematically wrong. |  |  |
| [`dither`](#dither) | none, fsb | none | Floyd-Steinberg dithering when reducing bit depth. |  |  |
| [`wpadapt`](#wpadapt) | bradford, vonkries, identity | bradford | White point adaptation method. |  |  |
| [`clipgamut`](#clipgamut) | none, rgb | none | How out-of-gamut values are clipped. | ✓ |  |
| [`iall`](#iall) | same as all | 0 | Overrides all input properties. |  |  |
| [`ispace`](#ispace) | same as space | 2 | Overrides input matrix. | ✓ |  |
| [`irange`](#irange) | same as range | 0 | Overrides input range. | ✓ |  |
| [`iprimaries`](#iprimaries) | same as primaries | 2 | Overrides input primaries. | ✓ |  |
| [`itrc`](#itrc) | same as trc | 2 | Overrides input transfer. | ✓ |  |
| [`in_color_matrix`](#in-color-matrix) | auto, bt601/bt470/smpte170m/bt470bg, bt709, fcc, smpte240m, bt2020/bt2020nc | auto | libswscale color setting for the scale filter: input/output Y'CbCr matrix. | ✓ |  |
| [`out_color_matrix`](#out-color-matrix) | auto, bt601/bt470/smpte170m/bt470bg, bt709, fcc, smpte240m, bt2020/bt2020nc (0-17) | 2 (help prints the number; 2 is not one of the named values) | libswscale color setting for the scale filter: input/output Y'CbCr matrix. | ✓ |  |
| [`in_range`](#in-range) | auto, unknown, full, limited, jpeg, mpeg, tv, pc (0-2) | auto | libswscale color setting for the scale filter: input/output range. | ✓ |  |
| [`out_range`](#out-range) | auto, unknown, full, limited, jpeg, mpeg, tv, pc (0-2) | auto | libswscale color setting for the scale filter: input/output range. | ✓ |  |
| [`in_chroma_loc`](#in-chroma-loc) | auto, unknown, left, center, topleft, top, bottomleft, bottom | auto | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`out_chroma_loc`](#out-chroma-loc) | auto, unknown, left, center, topleft, top, bottomleft, bottom | auto | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`in_primaries`](#in-primaries) | -1 to 22 (auto, bt709 ... jedec-p22/ebu3213) | auto | libswscale color setting for the scale filter: input/output primaries. | ✓ |  |
| [`out_primaries`](#out-primaries) | same as in_primaries | auto | libswscale color setting for the scale filter: input/output primaries. | ✓ |  |
| [`in_transfer`](#in-transfer) | -1 to 18 (auto, bt709 ... smpte2084, smpte428, arib-std-b67) | auto | libswscale color setting for the scale filter: input/output transfer (help text mislabels in_transfer as 'output'). | ✓ |  |
| [`out_transfer`](#out-transfer) | same as in_transfer | auto | libswscale color setting for the scale filter: input/output transfer (help text mislabels in_transfer as 'output'). | ✓ |  |
| [`in_v_chr_pos`](#in-v-chr-pos) | -513 to 512 (luma grid/256) | -513 | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`in_h_chr_pos`](#in-h-chr-pos) | -513 to 512 | -513 | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`out_v_chr_pos`](#out-v-chr-pos) | -513 to 512 | -513 | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`out_h_chr_pos`](#out-h-chr-pos) | -513 to 512 | -513 | libswscale color setting for the scale filter: input/output chroma siting. | ✓ |  |
| [`range`](#range) | auto, unspecified/unknown, limited/tv/mpeg, full/pc/jpeg | auto | Relabels the frame's range without touching pixel values. | ✓ |  |
| [`color_primaries`](#color-primaries) | auto, bt709, unknown, bt470m, bt470bg, smpte170m, smpte240m, film, bt2020, smpte428, smpte431, smpte432, jedec-p22/ebu3213, vgamut | auto | Relabels the frame's color primaries without touching pixel values. | ✓ |  |
| [`color_trc`](#color-trc) | auto, bt709, unknown, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67, vlog | auto | Relabels the frame's color trc without touching pixel values. | ✓ |  |
| [`colorspace`](#colorspace) | auto, gbr, bt709, unknown, fcc, bt470bg, smpte170m, smpte240m, ycgco, ycgco-re, ycgco-ro, bt2020nc, bt2020c, smpte2085, chroma-derived-nc, chroma-derived-c, ictcp, ipt-c2 | auto | Relabels the frame's colorspace without touching pixel values. | ✓ |  |
| [`chroma_location`](#chroma-location) | auto, unspecified/unknown, left, center, topleft, top, bottomleft, bottom | auto | Relabels the frame's chroma location without touching pixel values. | ✓ |  |
| [`range`](#range) | auto, unspecified/unknown, limited/tv/mpeg, full/pc/jpeg | auto | Relabels the frame's range only (no conversion). | ✓ |  |
| [`src/dst`](#src-dst) | bt709, fcc, bt601/bt470/bt470bg/smpte170m, smpte240m, bt2020 | -1 | Legacy 8-bit matrix-only conversion between Y'CbCr standards. |  |  |
| [`mode`](#mode) | color_range, alpha_mode, all | color_range+alpha_mode+all | Analyzes frames to detect whether Y'CbCr values actually use full or limited range. | ✓ |  |
| [`tonemap`](#tonemap) | none, linear, gamma, clip, reinhard, hable, mobius | none | Tone-mapping curve. | ✓ |  |
| [`param`](#param) | double | nan | Curve tuning value (meaning depends on the curve). | ✓ |  |
| [`desat`](#desat) | 0 to DBL_MAX | 2 | Desaturation strength for overbright colors. | ✓ |  |
| [`peak`](#peak) | 0 to DBL_MAX | 0 | Overrides the signal peak (0 = from metadata/auto). | ✓ |  |
| [`mode/type`](#mode-type) | mode: select, delete; type: PANSCAN ... MASTERING_DISPLAY_METADATA, CONTENT_LIGHT_LEVEL, ICC_PROFILE, DYNAMIC_HDR_PLUS, DOVI_RPU_BUFFER, DOVI_METADATA, DYNAMIC_HDR_VIVID, AMBIENT_VIEWING_ENVIRONMENT, ... | mode select, type -1 | Selects frames having, or deletes, a given frame side data type, e.g. | ✓ |  |
| [`color_matrix/color_primaries/color_transfer`](#color-matrix-color-primaries-color-transfer) | names | not stated | VideoToolbox scaler output color settings (macOS hardware path). | ✓ |  |
| [`par`](#par) | same as -par | not stated | Sets the pixel aspect ratio on import. |  |  |
| [`clap`](#clap) | same as -clap | not stated | Sets the clean aperture on import. |  |  |
| [`-alpha_mode`](#alpha-mode) | unknown/unspecified(0), premultiplied(1), straight(2) | unknown | Tags whether alpha is premultiplied or straight. | ✓ |  |
| [`-mov_gamma`](#mov-gamma) | 0 to 10 | 0 | Gamma value written to the gama atom (used with -movflags write_gama, MOV only). | ✓ |  |
| [`-apply_defdispwin`](#apply-defdispwin) | true/false | false | Applies the VUI default display window when decoding HEVC. | ✓ |  |
| [`-strict-displaywin`](#strict-displaywin) | true/false | false | Applies the default display window size strictly. | ✓ |  |
| [`alpha_mode`](#alpha-mode) | auto, unspecified/unknown, premultiplied, straight | auto | Relabels the frames' alpha mode. | ✓ |  |
| [`color_spaces`](#color-spaces) | '\|'-separated color spaces | not stated | Limits the color spaces the format filter lets through during negotiation. | ✓ |  |
| [`color_ranges`](#color-ranges) | '\|'-separated color ranges | not stated | Limits the color ranges the format filter lets through during negotiation. | ✓ |  |
| [`video_format`](#video-format) | -1 to 5 (table E-2) | -1 | Rewrites the LCEVC VUI video format. | ✓ |  |
| [`video_format`](#video-format) | -1 to 7 (table 6-6) | -1 | Rewrites the MPEG-2 video format. | ✓ |  |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--data`](#data) | all, scenes, level5 as key=output; repeatable or comma-separated | not stated | Selects what to dump: the whole RPU list as JSON (all), the frame numbers where scene_refresh_flag is set (scenes), or the L5 active area as a ready-to-use editor JSON (level5). | ✓ |  |
| [`--levels-format`](#levels-format) | csv, json | csv | File format used for --levels exports. | ✓ |  |
| [`--levels`](#levels) | level1, level2, level3, level4, level5, level6, level8, level9, level10, level11 as key=output | not stated | Writes the chosen metadata levels (for example L1 per-frame min/avg/max) to files for analysis. | ✓ |  |
| [`--frame`](#frame) | 0-based frame index | not stated | Prints one frame's RPU as JSON. | ✓ |  |
| [`--summary`](#summary) | flag | off | Prints a summary: frame count, profile, CM version, scene count, levels present. | ✓ | ✓ |
| [`--title`](#title) | text | not stated | Chart title. |  |  |
| [`--start`](#start) | frame | not stated | First frame to plot. |  |  |
| [`--end`](#end) | frame (inclusive) | not stated | Last frame to plot. |  |  |
| [`--plot-type`](#plot-type) | l1, l2, l8, l8-saturation, l8-hue | l1 | Which metadata level to graph; L8 types need CM v4.0 RPUs. | ✓ |  |
| [`--target-nits`](#target-nits) | 100, 300, 600, 1000, 2000, 4000 | 100 | Target display level used for L2/L8 trim plots. | ✓ |  |
| [`--trims`](#trims) | slope, offset, power, chroma, saturation, ms, mid, clip | all included | Limits L2/L8 plots to the named trim parameters. | ✓ |  |
| [`--verify`](#verify) | flag | off | Only checks whether the input holds HDR10+ dynamic metadata and reports it; no effect on inject or remove. | ✓ |  |
| [`--title`](#title) | text | not stated | Chart title. |  |  |
| [`--peak-source`](#peak-source) | histogram, histogram99, max-scl, max-scl-luminance | histogram | Which field is plotted as the frame peak. | ✓ |  |
| [`--start`](#start) | frame | not stated | First frame to plot. |  |  |
| [`--end`](#end) | frame (inclusive) | not stated | Last frame to plot. |  |  |
| [`-info`](#info) | none (movie) or track ID; -infon takes a track number; -infox prints all tracks | not stated | Prints movie or track information, including codec string, DV configuration and color/HDR boxes. | ✓ |  |
| [`--identify`](#identify) | file | not stated | Prints what mkvmerge detects in a file. | ✓ |  |
| [`-J`](#j) | file | not stated | Shorthand for --identification-format json --identify; since v68 the JSON includes color, mastering and projection properties. | ✓ |  |
| [`--identification-format`](#identification-format) | text, json | text | Output format for --identify. |  |  |
| [`-export_side_data`](#export-side-data) | mvs, prft, venc_params, film_grain, enhancements | 0 | Asks decoders/encoders to attach extra data (motion vectors, film grain parameters, encoder params, enhancement layers) to frames or packets. |  | ✓ |
| [`stats`](#stats) | flag | off | Prints filter session statistics after import. |  |  |
| [`graph`](#graph) | flag | off | Prints the filter session graph after import. |  |  |
| [`--verbose`](#verbose) | flag | off | Prints more detail. |  |  |
| [`--quiet`](#quiet) | flag | off | Suppresses status output. |  |  |
| [`--list-types`](#list-types) | flag | off | Lists supported source file types. |  |  |
| [`--list-audio-emphasis`](#list-audio-emphasis) | flag | off | Lists values for --audio-emphasis. |  |  |
| [`--list-languages`](#list-languages) | flag | off | Lists ISO 639 languages and codes. |  |  |
| [`--list-stereo-modes`](#list-stereo-modes) | flag | off | Lists values for --stereo-mode. |  |  |
| [`--capabilities`](#capabilities) | flag | off | Lists optional features compiled in. |  |  |
| [`--redirect-output`](#redirect-output) | file | not stated | Writes all messages to a file. |  |  |
| [`--debug`](#debug) | topic | not stated | Turns on debug output for a topic. |  |  |

### Other

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`--help`](#help) | flag | not stated | Prints help; -h gives the short form and --help the long form. |  |  |
| [`--version`](#version) | flag | not stated | Prints the tool version. |  | ✓ |
| [`--no-add-aud`](#no-add-aud) | flag | off (AUDs are added) | Stops the tool from inserting access unit delimiters between frames. |  |  |
| [`--no-add-aud`](#no-add-aud) | flag | off (AUDs are added) | Do not insert access unit delimiters between frames. |  |  |
| [`--remove-eos`](#remove-eos) | flag | off | Strips end-of-sequence/end-of-bitstream NAL units from both layers. |  |  |
| [`--eos-before-el`](#eos-before-el) | flag | on (deprecated flag) | Deprecated; the behavior is always on now. |  |  |
| [`--help`](#help) | flag | not stated | Prints help for the tool or a subcommand. |  |  |
| [`--version`](#version) | flag | not stated | Prints the tool version. |  |  |
| [`au_delim`](#au-delim) | flag | off | Keeps access unit delimiter NAL units in the imported samples. |  |  |
| [`novpsext`](#novpsext) | flag | off | Removes VPS extensions from HEVC. |  |  |
| [`forcesync`](#forcesync) | flag | off | Marks non-IDR I-frames (open GOP/GDR) as sync points; help warns the result is not spec compliant. |  |  |
| [`--fix-bitstream-timing-information`](#fix-bitstream-timing-information) | TID[:bool] | off | Rewrites frame-rate info inside the bitstream to match the container. |  |  |
| [`--engage`](#engage) | feature (see --engage list) | not stated | Turns on experimental features; not for normal use. |  |  |
| [`--deterministic`](#deterministic) | seed | not stated | Produces byte-identical output for identical inputs, options and seed. |  |  |
| [`--abort-on-warnings`](#abort-on-warnings) | flag | off | Stops at the first warning. |  |  |
| [`-strict`](#strict) | very(2) strict(1) normal(0) unofficial(-1) experimental(-2) | normal | How strictly to follow specs. | ✓ | ✓ |
| [`aud`](#aud) | pass(0) insert(1) remove(2) | pass | Inserts or removes access unit delimiters. |  |  |
| [`video_format`](#video-format) | -1 to 7 (table E-2) | -1 | Rewrites VUI video_format. |  |  |
| [`tick_rate`](#tick-rate) | rational | 0/1 | Sets VPS/VUI timing tick rate (containers usually override it). |  |  |
| [`num_ticks_poc_diff_one`](#num-ticks-poc-diff-one) | -1 to INT_MAX | -1 | Sets VPS/VUI ticks per POC step. |  |  |
| [`level`](#level) | auto, 1 ... 6.2, 8.5 (or level_idc) | -2 (unchanged) | Rewrites the VPS/SPS level. |  |  |
| [`tick_rate`](#tick-rate) | rational | 0/1 | Sets display tick rate in the timing info. |  |  |
| [`num_ticks_per_picture`](#num-ticks-per-picture) | -1 to INT_MAX | -1 | Ticks per picture for CFR (needs tick_rate). |  |  |
| [`td`](#td) | pass(0) insert(1) remove(2) | pass | Inserts or removes temporal delimiter OBUs. |  |  |
| [`delete_padding`](#delete-padding) | true/false | false | Removes padding OBUs. |  |  |
| [`aud`](#aud) | pass(0) insert(1) remove(2) | pass | Inserts or removes AUDs in VVC; the only option (no color fields). |  |  |
| [`-p`](#p) | profile name, file path, or 0 | not stated | Picks a GPAC configuration profile (created if missing); a path loads one from a file and 0 means a temporary profile that is not saved. |  |  |
| [`sopt`](#sopt) | filter arguments | not stated | Passes extra arguments to the source filter; must come after all other per-file options. |  |  |
| [`dopt`](#dopt) | filter arguments | not stated | Passes extra arguments to the destination filter; must come after all other per-file options. |  |  |
| [`@f1[:args][@fN:args]`](#f1-args-fn-args) | filter chain (@@ starts a new chain) | not stated | Inserts a filter chain before the multiplexer; must come after all other per-file options. |  |  |
| [`--probe-range-percentage`](#probe-range-percentage) | percent | 0.3 | Maximum share of the file size probed for tracks in some file types. |  |  |
| [`--priority`](#priority) | priority | not stated | Process priority. |  |  |
| [`--ui-language`](#ui-language) | code | not stated | Forces the UI translation. |  |  |
| [`--command-line-charset`](#command-line-charset) | charset | not stated | Charset of strings on the command line. |  |  |
| [`--output-charset`](#output-charset) | charset | not stated | Charset of output messages. |  |  |
| [`--no-bom`](#no-bom) | flag | off | Does not write byte order marks to text files. |  |  |
| [`--flush-on-close`](#flush-on-close) | flag | off | Flushes cached data to storage when closing output files. |  |  |
| [`@option-file.json`](#option-file-json) | JSON file | not stated | Reads more command-line options from a JSON file (see the man page). |  |  |
| [`--help`](#help) | flag | off | Shows help. |  |  |
| [`--version`](#version) | flag | off | Shows version information. |  |  |
| [`sei_user_data`](#sei-user-data) | UUID+string | not stated | Inserts a user-data-unregistered SEI message. |  |  |
| [`pass_types`](#pass-types) | list of unit types | not stated | Passes only the listed NAL/OBU unit types. |  |  |
| [`remove_types`](#remove-types) | list of unit types | not stated | Removes the listed NAL/OBU unit types. |  |  |
| [`discard`](#discard) | none(-16), default(0), nonref(8), bidir(16), nonintra(24), nonkey(32), all(48) | none | Drops whole frames of the selected kind. |  |  |
| [`discard_flags`](#discard-flags) | keep_non_vcl | 0 | Keeps non-VCL units of dropped pictures. |  |  |

## Options in detail

### Input and output

<a id="start-code"></a>

#### `--start-code`

**Type:** enum · **Values:** four, annex-b · **Default:** four · advanced

Picks the NAL start-code length written to HEVC output: always 4 bytes, or the variable length the Annex B spec allows (close to what x265 writes).

**Notes:** Purely cosmetic for most muxers; both forms are valid Annex B.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file or - for stdin · **Default:** not stated · **HDR-relevant**

Positional form of the input HEVC file; '-' reads an Annex B stream piped from another program (typically ffmpeg).

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Input HEVC (Annex B) file to convert.

**Notes:** Input must be a raw Annex B HEVC elementary stream; extract it with ffmpeg -c:v copy -bsf:v hevc_mp4toannexb -f hevc.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Where the converted single-layer HEVC is written.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Positional input: a single-track dual-layer (profile 7) HEVC stream.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Dual-layer HEVC input to split.

<a id="bl-out"></a>

#### `--bl-out` (also `-b`)

**Type:** path · **Values:** file · **Default:** not stated (README: base layer output matches the remove subcommand, which writes BL.hevc) · **HDR-relevant**

Output path for the base layer.

<a id="el-out"></a>

#### `--el-out` (also `-e`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Output path for the enhancement layer (which also carries the RPU).

<a id="el-only"></a>

#### `--el-only`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Writes only the enhancement-layer file and skips the base layer.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant**

Positional input RPU file.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant**

Binary RPU to edit.

**In Lumora:** Used in DolbyVisionRetimer (two passes: remove, then duplicate).

<a id="rpu-out"></a>

#### `--rpu-out` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Where the edited RPU is written.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant** · advanced

Positional input RPU file.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant** · advanced

Binary RPU to export.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC/MKV file or - · **Default:** not stated · **HDR-relevant**

Positional input video.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file, Matroska file, or - · **Default:** not stated · **HDR-relevant**

Video to pull the RPU from. Raw HEVC and Matroska are read directly; MP4 needs to be converted to Annex B with ffmpeg first.

**In Lumora:** Used on an Annex B dump made with ffmpeg -bsf:v hevc_mp4toannexb.

<a id="rpu-out"></a>

#### `--rpu-out` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated (README examples write RPU.bin) · **HDR-relevant**

Where the extracted binary RPU goes.

<a id="limit"></a>

#### `--limit` (also `-l`)

**Type:** int · **Values:** N frames · **Default:** not stated (whole file) · **HDR-relevant** · advanced

Stops after N frames; handy for a quick probe.

| For | Value | Why | Source |
|---|---|---|---|
| speed | `e.g. 100 when only checking which profile a file uses` | Avoids reading a whole film just to run `info --summary`. | [source](https://github.com/quietvoid/dovi_tool) |

<a id="track-number"></a>

#### `--track-number` (also `-t`)

**Type:** int · **Values:** track number · **Default:** not stated · **HDR-relevant** · advanced

Which video track to read when the input is Matroska.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Positional input HEVC.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Encoded HEVC (Annex B) that will receive the RPU.

**In Lumora:** Used in ExportEngine.injectDynamicMetadata for both retimed and generated DV metadata.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated (README example: injected_output.hevc) · **HDR-relevant**

Output HEVC with RPU NAL units.

<a id="rpu-out"></a>

#### `--rpu-out` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Where the generated RPU is written.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant**

Positional input RPU file.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant**

RPU file to inspect.

<a id="bl"></a>

#### `--bl` (also `-b`)

**Type:** path · **Values:** HEVC file or - · **Default:** not stated (required) · **HDR-relevant** · advanced

Base-layer HEVC to interleave into.

**Notes:** README shows piped input with --bl - (verified 2026-11-12).

<a id="el"></a>

#### `--el` (also `-e`)

**Type:** path · **Values:** HEVC file · **Default:** not stated (required) · **HDR-relevant** · advanced

Enhancement-layer HEVC (with RPU) to interleave.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant** · advanced

Output BL+EL+RPU HEVC.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant** · advanced

Positional input RPU file.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** RPU .bin · **Default:** not stated · **HDR-relevant** · advanced

RPU to plot.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** PNG file · **Default:** not stated · **HDR-relevant** · advanced

Where the PNG chart is written.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Positional input HEVC.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

HEVC whose EL and RPU should be stripped.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated (README: BL.hevc) · **HDR-relevant**

Output: plain base layer (HDR10/SDR/HLG depending on profile).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `use to make a clean HDR10 file from DV 7/8.1` | Some players show wrong colors on DV they cannot decode; removing RPU leaves a standard HDR10 stream. Not valid for profile 5, whose base is not HDR10. | [source](https://github.com/quietvoid/dovi_tool) |

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file, Matroska file, or - (stdin) · **Default:** not stated · **HDR-relevant**

Positional form of the input video.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file, Matroska file, or - (stdin) · **Default:** not stated · **HDR-relevant**

Input video bitstream.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Positional form of the input video.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Input video bitstream.

**In Lumora:** Used: `hdr10plus_tool inject -i video.hevc -j hdr10plus.json -o video_dyn.hevc` in ExportEngine.injectDynamicMetadata.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Positional form of the input video.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HEVC file or - · **Default:** not stated · **HDR-relevant**

Input video bitstream.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** JSON file · **Default:** not stated (without it, only a partial parse/check is done) · **HDR-relevant**

Where the extracted HDR10+ JSON is written.

<a id="limit"></a>

#### `--limit` (also `-l`)

**Type:** int · **Values:** N frames · **Default:** not stated (whole file) · **HDR-relevant** · advanced

Stops after N frames.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Output HEVC with HDR10+ SEI messages.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** HEVC file · **Default:** not stated · **HDR-relevant**

Output HEVC with HDR10+ SEI removed.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated · **HDR-relevant** · advanced

Positional input JSON.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated · **HDR-relevant** · advanced

HDR10+ JSON to edit.

<a id="json-out"></a>

#### `--json-out` (also `-o`)

**Type:** path · **Values:** JSON file · **Default:** not stated · **HDR-relevant** · advanced

Where the edited JSON is written.

<a id="input-pos"></a>

#### `[input_pos]`

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated · **HDR-relevant** · advanced

Positional input JSON.

<a id="input"></a>

#### `--input` (also `-i`)

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated · **HDR-relevant** · advanced

JSON to plot.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** PNG file · **Default:** not stated · **HDR-relevant** · advanced

PNG output path.

<a id="add"></a>

#### `-add`

**Type:** string · **Values:** URL[#FRAGMENT][:opt1...:optN=val]; several inputs joined with + · **Default:** not stated · **HDR-relevant**

Imports tracks from a file into the destination MP4, creating it if needed. Per-file import options (dvp, fps, colr, hdr, ...) are appended after colons.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `-add video.hevc:dvp=8.1:fps=24000/1001` | Raw HEVC carries no timing, and DV signaling (dvcC + dvh1) is only written when dvp is given. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

**In Lumora:** ExportEngine: `MP4Box -add video_dyn.hevc:fps=<rate>[:dvp=8.1] -add file#audio -new final.mp4`, run inside the job folder with relative names because ':' and '#' are parsed inside -add.

**Notes:** Fragments: #video, #audio, #trackID=N select tracks. sopt/dopt/@filter must come after all other per-file options.

<a id="cat"></a>

#### `-cat`

**Type:** string · **Values:** URL[+URL...] · **Default:** not stated · advanced

Appends samples of another file to matching tracks (concatenation).

**Notes:** Concatenating DV/HDR10+ segments works only when all segments share identical decoder configuration.

<a id="out"></a>

#### `-out`

**Type:** path · **Values:** file · **Default:** input file is overwritten

Output file name; without it MP4Box rewrites the input in place.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `always give -out (or -new with a target)` | Default behavior overwrites the source file. | [source](https://wiki.gpac.io/MP4Box/mp4box-gen-opts/) |

<a id="new"></a>

#### `-new`

**Type:** bool · **Values:** flag · **Default:** off

Forces creation of a fresh destination file instead of adding to an existing one.

**In Lumora:** Used: Lumora always creates a new final.mp4.

<a id="newfs"></a>

#### `-newfs`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Creates a new file without a temporary file while still interleaving (less precise interleave).

<a id="flat"></a>

#### `-flat`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Writes all media first with no interleaving; faster to write, worse for progressive playback.

<a id="inter"></a>

#### `-inter`

**Type:** float · **Values:** duration · **Default:** 0.5 · advanced

Interleave chunk duration (help says ms, the general text says 0.5 s by default; 0 disables).

**Notes:** Help text is ambiguous about the unit (ms vs s); the wiki has the same ambiguity.

<a id="frag"></a>

#### `-frag`

**Type:** float · **Values:** duration in ms · **Default:** not stated · advanced

Writes a fragmented MP4 with fragments of the given duration (disables interleaving).

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `e.g. 2000 for HLS/DASH-style fMP4` | Apple requires fragmented MP4 for HEVC in HLS. | [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) |

<a id="brand"></a>

#### `-brand`

**Type:** string · **Values:** ABCD or ABCD:v · **Default:** not stated · **HDR-relevant** · advanced

Sets the file's major brand.

<a id="ab"></a>

#### `-ab`

**Type:** string · **Values:** 4CC · **Default:** not stated · **HDR-relevant** · advanced

Adds a compatible brand (for example dby1 for Dolby content).

**Notes:** Unverified: many community DV workflows add the dby1 brand; whether GPAC adds it automatically with dvp was not checked.

<a id="rb"></a>

#### `-rb`

**Type:** string · **Values:** 4CC · **Default:** not stated · advanced

Removes a compatible brand.

<a id="rem"></a>

#### `-rem`

**Type:** int · **Values:** track ID · **Default:** not stated · advanced

Removes a track from the file.

<a id="fps"></a>

#### `fps` (also `:fps=`, `-fps`)

**Type:** string · **Values:** number, TS-inc or TS/inc · **Default:** 25 for raw video other than H.263 (which defaults to 15)

Frame rate assigned to raw elementary streams on import.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `the encode's exact rate, e.g. 24000/1001` | Raw .hevc has no container timing; without fps MP4Box assumes 25 fps and the film plays too fast with drifting audio. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

**In Lumora:** Lumora passes fps as a decimal (Double(num)/Double(den)), e.g. 23.976023976; the fractional form 24000/1001 is exact and avoids rounding.

**Notes:** Both a per-file option (:fps=) and a global -fps exist; the help notes that for ISOBMFF sources :rescale is preferred. Tested: :fps=24000/1001 gives exactly 23.976 CFR.

<a id="xps-inband"></a>

#### `xps_inband` (also `:xps_inband`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps parameter sets in the samples (hev1/avc3 style) instead of only in the sample description.

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `leave off for Apple targets` | Apple wants hvc1/dvh1 entries with parameter sets out of band; hev1/dvhe are not recommended. | [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) |

<a id="xps-inbandx"></a>

#### `xps_inbandx` (also `:xps_inbandx`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Like xps_inband but also keeps the first parameter sets in the sample description.

<a id="max-lid"></a>

#### `max_lid` (also `:max_lid=`)

**Type:** int · **Values:** N · **Default:** all layers · advanced

Highest HEVC layer ID to import (layered HEVC).

**Notes:** Not the way to drop a DV enhancement layer; DV profile 7 EL is a separate NAL type stream handled by dovi_tool.

<a id="max-tid"></a>

#### `max_tid` (also `:max_tid=`)

**Type:** int · **Values:** N · **Default:** all sublayers · advanced

Highest temporal sublayer to import.

<a id="stype"></a>

#### `stype` (also `:stype=`)

**Type:** string · **Values:** 4CC · **Default:** not stated · **HDR-relevant** · advanced

Forces the sample description type code; the help warns this can easily break the file.

**Notes:** Do not use to fake dvh1/hvc1; use dvp (with or without f prefix) instead.

<a id="rescale"></a>

#### `rescale` (also `:rescale=`)

**Type:** int · **Values:** TS or fraction · **Default:** not stated · advanced

Forces a media timescale and rescales the duration.

<a id="sampdur"></a>

#### `sampdur` (also `:sampdur=`)

**Type:** int · **Values:** D or D/TS · **Default:** not stated · advanced

Forces all sample durations, to repair constant-frame-rate files with broken timing.

<a id="negctts"></a>

#### `negctts` (also `:negctts`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Uses negative composition offsets (iso4 brand) instead of edit lists for B-frame delay.

<a id="noedit"></a>

#### `noedit` (also `:noedit`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Do not write an edit list for B-frame video.

<a id="fmt"></a>

#### `fmt` (also `:fmt=`)

**Type:** string · **Values:** format · **Default:** not stated · advanced

Overrides format probing for the source.

<a id="ext"></a>

#### `ext` (also `:ext=`)

**Type:** string · **Values:** extension · **Default:** not stated · advanced

Overrides the file extension used for format detection.

<a id="output"></a>

#### `--output` (also `-o`)

**Type:** path · **Values:** file · **Default:** not stated (required)

Destination Matroska file.

**In Lumora:** Used: `mkvmerge -o final.mkv --default-duration 0:<num>/<den>fps video_dyn.hevc -D file`.

<a id="video-tracks"></a>

#### `--video-tracks` (also `-d`)

**Type:** list · **Values:** n,m,... · **Default:** all video tracks

Copies only the listed video tracks from the next source file.

<a id="no-video"></a>

#### `--no-video` (also `-D`)

**Type:** bool · **Values:** flag · **Default:** off

Copies no video from the next source file.

**In Lumora:** Used to take only audio/subtitles from the intermediate file when remuxing the injected HEVC.

<a id="no-audio"></a>

#### `--no-audio` (also `-A`)

**Type:** bool · **Values:** flag · **Default:** off

Copies no audio from the next source file.

<a id="default-duration"></a>

#### `--default-duration`

**Type:** string · **Values:** TID:Xs\|ms\|us\|ns\|fps · **Default:** derived from container/bitstream where possible

Forces the frame duration (frame rate) of a track; required for raw elementary streams that carry no timing.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:24000/1001fps for raw .hevc` | Raw HEVC has no reliable timing; give the exact rational rate. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

**In Lumora:** Lumora passes `0:<num>/<den>fps` from the encode's rational rate.

**Notes:** The online docs also accept the suffixes p and i (progressive/interlaced frames per second); the help lists s, ms, us, ns and fps.

<a id="track-name"></a>

#### `--track-name`

**Type:** string · **Values:** TID:name · **Default:** not stated

Sets a track title.

<a id="language"></a>

#### `--language`

**Type:** string · **Values:** TID:lang (BCP 47) · **Default:** not stated

Sets the track language.

<a id="tag"></a>

#### `-tag` (also `-tag:v`, `-vtag`)

**Type:** string · **Values:** fourcc/tag · **Default:** not stated · **HDR-relevant**

Forces the codec tag (sample entry 4CC).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `-tag:v hvc1 (or dvh1 for DV)` | Apple's HLS rule 1.10 asks for hvc1/dvh1 (parameter sets in the sample description); hev1/dvhe are marked not recommended. | [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) |

**In Lumora:** Only end-to-end tests pass `-tag:v hvc1`; ExportEngine's ffmpeg remux path does not, so HEVC MP4/MOV from that path may get hev1 (not verified in the app).

<a id="c"></a>

#### `-c` (also `-codec`, `-c:v copy`)

**Type:** string · **Values:** encoder name or copy · **Default:** not stated · **HDR-relevant**

Selects the encoder, or 'copy' to pass the bitstream through untouched (keeps in-band SEI and RPU).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `copy for any metadata surgery` | Stream copy preserves HDR10 SEI, HDR10+ and DV RPU NAL units exactly; re-encoding drops what the encoder does not regenerate. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** Used with -bsf:v hevc_mp4toannexb to dump Annex B for dovi_tool/hdr10plus_tool.

<a id="bsf"></a>

#### `-bsf` (also `-bsf:v`)

**Type:** list · **Values:** comma-separated bitstream filters with =opt=val · **Default:** not stated · **HDR-relevant**

Applies bitstream filters to packets (input or output since FFmpeg 7.0). Used for Annex B conversion and for rewriting VUI/DV metadata without re-encoding.

**In Lumora:** `-bsf:v hevc_mp4toannexb` before every dovi_tool/hdr10plus_tool step.

<a id="movflags"></a>

#### `-movflags`

**Type:** flags · **Values:** includes write_colr, prefer_icc, write_gama, faststart, frag_keyframe, cmaf, dash, ... · **Default:** 0 · **HDR-relevant** · advanced

MOV/MP4 muxer flags. write_colr forces a colr box even with unspecified color; prefer_icc uses an ICC profile from side data for colr; write_gama writes the deprecated gama atom.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `+faststart (leave write_colr off)` | colr is written automatically when all three color tags are set; write_colr is marked experimental in the help. | [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c) |

**Notes:** movenc.c writes mdcv/clli whenever mastering/light side data is on the stream (MOV and MP4), and colr only when primaries, transfer and matrix are all specified, unless write_colr or an ICC profile is present (verified in source and by test).

<a id="no-options"></a>

#### `(no options)` (also `-bsf:v hevc_mp4toannexb`)

**Type:** bool · **Values:** filter name · **Default:** auto-inserted for raw HEVC/mpegts output · **HDR-relevant**

Converts length-prefixed HEVC (MP4/MKV style) to start-code Annex B, the format dovi_tool and hdr10plus_tool read.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `always specify when piping to dovi_tool/hdr10plus_tool` | Explicit is harmless and the tools' READMEs use it. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** Used in DolbyVisionRetimer and ExportEngine.

<a id="old-inter"></a>

#### `-old-inter`

**Type:** float · **Values:** duration (ms) · **Default:** not stated · advanced

Interleaving like -inter but without drift correction.

<a id="tight"></a>

#### `-tight`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Sample-level interleaving: fewer disk seeks on playback at the cost of a slightly larger file.

<a id="co64"></a>

#### `-co64`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Forces 64-bit chunk offsets (co64) in the output.

<a id="no-sys"></a>

#### `-no-sys` (also `-nosys`)

**Type:** bool · **Values:** flag · **Default:** on when creating regular AV content (per help) · advanced

Removes MPEG-4 Systems information except the IOD.

<a id="no-iod"></a>

#### `-no-iod`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Removes the MPEG-4 InitialObjectDescriptor.

<a id="mfra"></a>

#### `-mfra`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds a movie fragment random access (mfra) index when fragmenting; ignored in DASH mode.

<a id="isma"></a>

#### `-isma`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Rewrites the file as ISMA 1.0.

<a id="ismax"></a>

#### `-ismax`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Like -isma and also removes all clock references.

<a id="3gp"></a>

#### `-3gp`

**Type:** bool · **Values:** flag · **Default:** off (always on for .3gp/.3g2/.3gpp output) · advanced

Rewrites the file as 3GPP/3GPP2 without MPEG-4 Systems info; some tracks may be dropped.

<a id="ipod"></a>

#### `-ipod`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Rewrites the file for iPods and old iTunes.

<a id="psp"></a>

#### `-psp`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Rewrites the file for Sony PSP devices.

<a id="cprt"></a>

#### `-cprt`

**Type:** string · **Values:** text · **Default:** not stated

Adds a copyright string to the file.

<a id="chap"></a>

#### `-chap`

**Type:** path · **Values:** chapter text file (ZoomPlayer, h:m:s time codes, SMPTE codes or CHAPTERX= syntax; formats cannot be mixed) · **Default:** not stated

Sets chapters from a text file.

<a id="chapqt"></a>

#### `-chapqt`

**Type:** path · **Values:** chapter text file · **Default:** not stated

Sets chapters from a file using QuickTime text-track signaling.

<a id="set-track-id"></a>

#### `-set-track-id`

**Type:** string · **Values:** tkID:id2 · **Default:** not stated · advanced

Changes a track's ID to id2.

<a id="swap-track-id"></a>

#### `-swap-track-id`

**Type:** string · **Values:** tkID1:tkID2 · **Default:** not stated · advanced

Swaps the IDs of two tracks.

<a id="rap"></a>

#### `-rap`

**Type:** int · **Values:** track ID · **Default:** not stated · advanced

Keeps only random access (sync) samples in the given track.

<a id="refonly"></a>

#### `-refonly`

**Type:** int · **Values:** track ID · **Default:** not stated · advanced

Removes all non-reference pictures from the given track.

<a id="enable"></a>

#### `-enable`

**Type:** int · **Values:** track ID · **Default:** not stated

Marks the given track as enabled.

<a id="disable"></a>

#### `-disable`

**Type:** int · **Values:** track ID · **Default:** not stated

Marks the given track as disabled.

<a id="timescale"></a>

#### `-timescale`

**Type:** int · **Values:** ticks per second · **Default:** 600 · advanced

Sets the movie timescale.

<a id="set-vexu"></a>

#### `-set-vexu`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds a vexu box to an MV-HEVC (stereo) MP4.

<a id="hero-eye"></a>

#### `-hero-eye`

**Type:** int · **Values:** 0 none, 1 left, 2 right · **Default:** 0 · advanced

Sets hero_eye_indicator in the HeroStereoEyeDescriptionBox for stereo video.

<a id="lang"></a>

#### `-lang`

**Type:** string · **Values:** [tkID=]LAN (BCP-47 code) · **Default:** all tracks when no track ID is given

Sets the language of one track or of all tracks.

<a id="delay"></a>

#### `-delay`

**Type:** string · **Values:** tkID=TIME (ms or N/D seconds; >0 delay, <0 skip) · **Default:** not stated

Sets a start delay or initial skip for a track.

<a id="mx"></a>

#### `-mx`

**Type:** string · **Values:** tkID=M1:...:M9 (16.16 fixed point or hex) · **Default:** not stated · advanced

Sets the track transformation matrix.

<a id="kind"></a>

#### `-kind`

**Type:** string · **Values:** tkID=schemeURI=value or all=schemeURI=value · **Default:** not stated · advanced

Adds a kind (role) to one track or all tracks.

<a id="kind-rem"></a>

#### `-kind-rem`

**Type:** string · **Values:** tkID=schemeURI=value or all=schemeURI=value · **Default:** not stated · advanced

Removes a kind from one track or all tracks.

<a id="name"></a>

#### `-name`

**Type:** string · **Values:** tkID=NAME (UTF-8) · **Default:** not stated

Sets the track handler name.

<a id="tags"></a>

#### `-tags` (also `-itags`)

**Type:** string · **Values:** tag list (see MP4Box -h tags) · **Default:** not stated

Writes iTunes-style metadata tags.

<a id="group-add"></a>

#### `-group-add`

**Type:** string · **Values:** colon-separated refTrack=, switchID=, criteria=, trackID= (order matters) · **Default:** not stated · advanced

Creates alternate/switch group information.

<a id="group-rem-track"></a>

#### `-group-rem-track`

**Type:** int · **Values:** track ID · **Default:** not stated · advanced

Removes a track from its group.

<a id="group-rem"></a>

#### `-group-rem`

**Type:** int · **Values:** track ID · **Default:** not stated · advanced

Removes the group the track belongs to.

<a id="group-clean"></a>

#### `-group-clean`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Removes all grouping information from all tracks.

<a id="ref"></a>

#### `-ref`

**Type:** string · **Values:** tkID:R4CC:refID (refID 0 removes) · **Default:** not stated · advanced

Adds or removes a track reference of type R4CC.

<a id="keep-utc"></a>

#### `-keep-utc`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps UTC timing information after editing.

<a id="udta"></a>

#### `-udta`

**Type:** string · **Values:** tkID:type=CODE:box=\|src=\|str=... (tkID 0 = movie) · **Default:** not stated · advanced

Sets or removes user data (udta) for a track or the movie.

<a id="patch"></a>

#### `-patch`

**Type:** path · **Values:** [tkID=]FILE · **Default:** not stated · advanced

Applies a box patch file, optionally to one track.

<a id="bo"></a>

#### `-bo`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps the box order of the input file.

<a id="init-seg"></a>

#### `-init-seg`

**Type:** path · **Values:** file · **Default:** not stated · advanced

Uses the given init segment for dumping or encryption.

<a id="zmov"></a>

#### `-zmov`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Compresses the moov box (ISOBMFF box compression, or QuickTime style for .mov).

<a id="xmov"></a>

#### `-xmov`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Like -zmov and also wraps ftyp in otyp.

<a id="edits"></a>

#### `-edits`

**Type:** string · **Values:** tkID=EDITS (r, eSTART[-DUR], eSTART,MEDIA[,RATE]) · **Default:** not stated · advanced

Rewrites a track's edit list.

<a id="moovpad"></a>

#### `-moovpad`

**Type:** int · **Values:** bytes (0 disables) · **Default:** not stated · advanced

Reserves padding after moov for later in-place edits.

<a id="no-inplace"></a>

#### `-no-inplace`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Disables in-place rewriting.

<a id="time"></a>

#### `-time`

**Type:** string · **Values:** [tkID=]DAY/MONTH/YEAR-H:M:S · **Default:** not stated · advanced

Sets the movie or track creation time.

<a id="mtime"></a>

#### `-mtime`

**Type:** string · **Values:** tkID=DAY/MONTH/YEAR-H:M:S · **Default:** not stated · advanced

Sets the media creation time.

<a id="dur"></a>

#### `dur` (also `:dur=`)

**Type:** string · **Values:** seconds, NUM/DEN, or negative frame count · **Default:** not stated

Imports only the given duration of the source.

<a id="start"></a>

#### `start` (also `:start=`)

**Type:** float · **Values:** seconds · **Default:** not stated · advanced

Start time in the source (not supported by every source).

<a id="lang"></a>

#### `lang` (also `:lang=`)

**Type:** string · **Values:** language code · **Default:** not stated

Sets the imported track's language.

<a id="delay"></a>

#### `delay` (also `:delay=`)

**Type:** string · **Values:** ms or N/D seconds (>0 delay, <0 skip) · **Default:** not stated · advanced

Sets the imported track's initial delay or skip.

<a id="mx"></a>

#### `mx` (also `:mx=`)

**Type:** string · **Values:** same as -mx · **Default:** not stated · advanced

Sets the track matrix on import.

<a id="name"></a>

#### `name` (also `:name=`)

**Type:** string · **Values:** text · **Default:** not stated

Sets the track handler name on import.

<a id="hdlr"></a>

#### `hdlr` (also `:hdlr=`)

**Type:** string · **Values:** 4CC · **Default:** not stated · advanced

Sets the track handler type.

<a id="tkhd"></a>

#### `tkhd` (also `:tkhd=`)

**Type:** string · **Values:** hex flags or enable, movie, preview, size_ar (+= / -= to add or remove) · **Default:** not stated · advanced

Sets track header flags.

<a id="disable"></a>

#### `disable` (also `:disable`)

**Type:** bool · **Values:** flag (disable=no forces enabling) · **Default:** off · advanced

Imports the track as disabled.

<a id="group"></a>

#### `group` (also `:group=`)

**Type:** int · **Values:** G (0 = first free group) · **Default:** not stated · advanced

Puts the track in alternate group G.

<a id="rap"></a>

#### `rap` (also `:rap`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Imports only random access samples.

<a id="refs"></a>

#### `refs` (also `:refs`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Imports only reference pictures.

<a id="trailing"></a>

#### `trailing` (also `:trailing`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps trailing zero bytes in AVC/HEVC samples.

<a id="agg"></a>

#### `agg` (also `:agg=`)

**Type:** int · **Values:** N · **Default:** not stated · advanced

Same as -agg: aggregates N audio frames per sample (3GP only).

<a id="dref"></a>

#### `dref` (also `:dref`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -dref: references media in the source file instead of copying it.

<a id="keep-refs"></a>

#### `keep_refs` (also `:keep_refs`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps track references when importing a single track.

<a id="nodrop"></a>

#### `nodrop` (also `:nodrop`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -no-drop (constant frame rate for AVI).

<a id="packed"></a>

#### `packed` (also `:packed`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -packed.

<a id="sbr"></a>

#### `sbr` (also `:sbr`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -sbr.

<a id="sbrx"></a>

#### `sbrx` (also `:sbrx`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -sbrx.

<a id="ovsbr"></a>

#### `ovsbr` (also `:ovsbr`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -ovsbr.

<a id="ps"></a>

#### `ps` (also `:ps`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -ps.

<a id="psx"></a>

#### `psx` (also `:psx`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -psx.

<a id="asemode"></a>

#### `asemode` (also `:asemode=`)

**Type:** enum · **Values:** v0-s, v0-2, v0-bs, v1, v1-qt · **Default:** v0-s · advanced

Chooses how the audio sample entry is written (MPEG v0/v1 or QuickTime v1) and how the channel count is taken.

<a id="audio-roll"></a>

#### `audio_roll` (also `:audio_roll=`)

**Type:** int · **Values:** N · **Default:** not stated · advanced

Adds a roll sample group with distance N to audio tracks.

<a id="roll"></a>

#### `roll` (also `:roll=`)

**Type:** int · **Values:** N · **Default:** not stated · advanced

Adds a roll sample group with distance N.

<a id="proll"></a>

#### `proll` (also `:proll=`)

**Type:** int · **Values:** N · **Default:** not stated · advanced

Adds a pre-roll sample group with distance N.

<a id="mpeg4"></a>

#### `mpeg4` (also `:mpeg4`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Same as -mpeg4.

<a id="svc"></a>

#### `svc` (also `:svc`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Imports SVC/LHVC with explicit signaling (no AVC base compatibility).

<a id="nosvc"></a>

#### `nosvc` (also `:nosvc`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Drops SVC/LHVC data on import.

<a id="svcmode"></a>

#### `svcmode` (also `:svcmode=`)

**Type:** enum · **Values:** split, merge, splitbase, splitnox, splitnoxib · **Default:** not stated · advanced

Chooses how SVC/LHVC layers are split into tracks.

<a id="temporal"></a>

#### `temporal` (also `:temporal=`)

**Type:** enum · **Values:** split, splitbase, splitnox · **Default:** not stated · advanced

Chooses how HEVC/LHVC temporal sublayers are split into tracks.

<a id="subsamples"></a>

#### `subsamples` (also `:subsamples`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds sub-sample information for AVC+SVC.

<a id="deps"></a>

#### `deps` (also `:deps`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Imports sample dependency information for AVC and HEVC.

<a id="ccst"></a>

#### `ccst` (also `:ccst`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds a default HEIF ccst box to the visual sample entry.

<a id="tiles"></a>

#### `tiles` (also `:tiles`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds HEVC tile signaling and NALU maps without splitting tiles into tracks.

<a id="split-tiles"></a>

#### `split_tiles` (also `:split_tiles`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Splits HEVC tiles into separate tile tracks.

<a id="chap"></a>

#### `chap` (also `:chap`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Marks the imported track as a chapter track.

<a id="chapter"></a>

#### `chapter` (also `:chapter=`)

**Type:** string · **Values:** name · **Default:** not stated · advanced

Adds one Nero-style chapter covering the whole file.

<a id="chapfile"></a>

#### `chapfile` (also `:chapfile=`)

**Type:** path · **Values:** file · **Default:** not stated · advanced

Adds a Nero-style chapter file.

<a id="layout"></a>

#### `layout` (also `:layout=`)

**Type:** string · **Values:** WxH[xXxY][xLAYER] (0 = max of existing tracks) · **Default:** not stated · advanced

Sets the track layout.

<a id="timescale"></a>

#### `timescale` (also `:timescale=`)

**Type:** int · **Values:** TS · **Default:** not stated · advanced

Sets the imported media timescale.

<a id="moovts"></a>

#### `moovts` (also `:moovts=`)

**Type:** int · **Values:** TS (negative = timescale of the first imported track) · **Default:** not stated · advanced

Sets the movie timescale.

<a id="rvc"></a>

#### `rvc` (also `:rvc=`)

**Type:** string · **Values:** RVC configuration · **Default:** not stated · advanced

Sets an RVC configuration for the media.

<a id="profile"></a>

#### `profile` (also `:profile=`)

**Type:** string · **Values:** integer or high444, high, extended, main, baseline · **Default:** not stated · advanced

Overrides the AVC profile.

<a id="level"></a>

#### `level` (also `:level=`)

**Type:** string · **Values:** integer (< 6 read as decimal) · **Default:** not stated · advanced

Overrides the AVC level.

<a id="compat"></a>

#### `compat` (also `:compat=`)

**Type:** int · **Values:** flags · **Default:** not stated · advanced

Forces the H.264 profile compatibility flags.

<a id="keepav1t"></a>

#### `keepav1t` (also `:keepav1t`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps AV1 temporal delimiter OBUs in the samples.

<a id="dlba"></a>

#### `dlba` (also `:dlba=`)

**Type:** enum · **Values:** no, auto, N · **Default:** not stated · advanced

Controls Dolby Atmos signaling for E-AC-3.

<a id="font"></a>

#### `font` (also `:font=`)

**Type:** string · **Values:** font name · **Default:** Serif · advanced

Font name for text import.

<a id="size"></a>

#### `size` (also `:size=`)

**Type:** int · **Values:** points · **Default:** 18 · advanced

Font size for text import.

<a id="text-layout"></a>

#### `text_layout` (also `:text_layout=`)

**Type:** string · **Values:** WxHxXxY (Y=-1 = bottom) · **Default:** not stated · advanced

Text track layout.

<a id="swf-global"></a>

#### `swf-global` (also `:swf-global`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: puts all SWF defines in the first scene replace.

<a id="swf-no-ctrl"></a>

#### `swf-no-ctrl` (also `:swf-no-ctrl`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: uses one stream for movie control and dictionary (disables ActionScript).

<a id="swf-no-text"></a>

#### `swf-no-text` (also `:swf-no-text`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: removes all SWF text.

<a id="swf-no-font"></a>

#### `swf-no-font` (also `:swf-no-font`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: removes embedded SWF fonts.

<a id="swf-no-line"></a>

#### `swf-no-line` (also `:swf-no-line`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: removes lines from SWF shapes.

<a id="swf-no-grad"></a>

#### `swf-no-grad` (also `:swf-no-grad`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: removes gradients from SWF shapes.

<a id="swf-quad"></a>

#### `swf-quad` (also `:swf-quad`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: uses quadratic instead of cubic Bezier curves.

<a id="swf-xlp"></a>

#### `swf-xlp` (also `:swf-xlp`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: supports line transparency and scalability.

<a id="swf-ic2d"></a>

#### `swf-ic2d` (also `:swf-ic2d`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: uses the indexed curve 2D hardcoded proto.

<a id="swf-same-app"></a>

#### `swf-same-app` (also `:swf-same-app`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

SWF import: reuses appearance nodes.

<a id="swf-flatten"></a>

#### `swf-flatten` (also `:swf-flatten=`)

**Type:** float · **Values:** angle (0 = no flattening) · **Default:** not stated · advanced

SWF import: merges lines whose complementary angle is below the value.

<a id="kind"></a>

#### `kind` (also `:kind=`)

**Type:** string · **Values:** schemeURI=value · **Default:** not stated · advanced

Sets the kind (role) of the imported track.

<a id="txtflags"></a>

#### `txtflags` (also `:txtflags=`)

**Type:** string · **Values:** hex (+= / -= to add or remove) · **Default:** not stated · advanced

Sets text track display flags.

<a id="rate"></a>

#### `rate` (also `:rate=`)

**Type:** int · **Values:** bps (0 removes btrt) · **Default:** not stated · advanced

Sets average and max bitrate in the btrt box.

<a id="stz2"></a>

#### `stz2` (also `:stz2`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Uses the compact sample size table.

<a id="tc"></a>

#### `tc` (also `:tc=`)

**Type:** string · **Values:** [d]FPS[/den],h,m,s,f[,framespertick] · **Default:** not stated · advanced

Injects a single QuickTime timecode.

<a id="edits"></a>

#### `edits` (also `:edits=`)

**Type:** string · **Values:** same syntax as -edits · **Default:** not stated · advanced

Overrides the edit list.

<a id="lastsampdur"></a>

#### `lastsampdur` (also `:lastsampdur=`)

**Type:** string · **Values:** empty (previous duration), ms, or N/D seconds · **Default:** not stated · advanced

Sets the duration of the last sample.

<a id="id"></a>

#### `ID` (also `:ID=`)

**Type:** int · **Values:** 0 keep source ID, -1 ignore source ID, other = requested ID · **Default:** 0 · advanced

Sets the target track ID.

<a id="tkgp"></a>

#### `tkgp` (also `:tkgp=`)

**Type:** string · **Values:** TYPE,N (negative N removes) · **Default:** not stated · advanced

Assigns the track to a track group.

<a id="tkidx"></a>

#### `tkidx` (also `:tkidx=`)

**Type:** int · **Values:** position (1 = first) · **Default:** not stated · advanced

Sets the track's position in the track list.

<a id="extk"></a>

#### `extk` (also `:extk`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Adds the track as an external track.

<a id="times"></a>

#### `times` (also `:times=`)

**Type:** path · **Values:** timestamp file (cts or dts cts per line, # timescale=V) · **Default:** not stated · advanced

Rewrites timestamps from a file.

<a id="catx"></a>

#### `-catx`

**Type:** string · **Values:** URL[+ADD_COMMAND] · **Default:** not stated · advanced

Like -cat but new tracks can be added before concatenation.

<a id="catpl"></a>

#### `-catpl`

**Type:** path · **Values:** playlist file (one file per line, # comments) · **Default:** not stated · advanced

Concatenates every file in a playlist as if each were passed to -cat.

<a id="unalign-cat"></a>

#### `-unalign-cat`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not align sample timestamps between tracks when concatenating.

<a id="force-cat"></a>

#### `-force-cat`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Skips the media configuration check when concatenating; the help warns this may break the result.

<a id="keep-sys"></a>

#### `-keep-sys`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps MPEG-4 Systems info when adding or concatenating ISOBMFF files.

<a id="dref"></a>

#### `-dref`

**Type:** bool · **Values:** flag · **Default:** off · advanced

References media data in the original file instead of copying it (not usable for AVC/HEVC).

<a id="no-drop"></a>

#### `-no-drop` (also `-nodrop`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Forces constant frame rate when importing AVI video.

<a id="packed"></a>

#### `-packed`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Forces packed bitstream for raw MPEG-4 Part 2 ASP import.

<a id="sbr"></a>

#### `-sbr`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Backward-compatible AAC-SBR signaling.

<a id="sbrx"></a>

#### `-sbrx`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Non-backward-compatible AAC-SBR signaling.

<a id="ps"></a>

#### `-ps`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Backward-compatible AAC-PS signaling.

<a id="psx"></a>

#### `-psx`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Non-backward-compatible AAC-PS signaling.

<a id="ovsbr"></a>

#### `-ovsbr`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Oversampled SBR import.

<a id="mpeg4"></a>

#### `-mpeg4`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Forces MPEG-4 sample descriptions where possible (MPEG-4 AAC signaling even for MPEG-2 AAC).

<a id="agg"></a>

#### `-agg`

**Type:** int · **Values:** N (max 15) · **Default:** not stated · advanced

Aggregates N audio frames per sample (3GP media only).

<a id="webm"></a>

#### `--webm` (also `-w`)

**Type:** bool · **Values:** flag · **Default:** off

Writes a WebM-compliant file.

<a id="title"></a>

#### `--title`

**Type:** string · **Values:** title · **Default:** not stated

Sets the segment title.

<a id="global-tags"></a>

#### `--global-tags`

**Type:** path · **Values:** XML file · **Default:** not stated · advanced

Reads global tags from an XML file.

<a id="chapters"></a>

#### `--chapters`

**Type:** path · **Values:** file · **Default:** not stated

Reads chapters from a file.

<a id="chapter-language"></a>

#### `--chapter-language`

**Type:** string · **Values:** language · **Default:** not stated · advanced

Sets the language element of chapter entries.

<a id="chapter-charset"></a>

#### `--chapter-charset`

**Type:** string · **Values:** charset · **Default:** not stated · advanced

Charset of a simple chapter file.

<a id="chapter-sync"></a>

#### `--chapter-sync`

**Type:** string · **Values:** d[,o[/p]] · **Default:** not stated · advanced

Shifts chapter timestamps by d ms and optionally scales them by o/p to fix drift.

<a id="cue-chapter-name-format"></a>

#### `--cue-chapter-name-format`

**Type:** string · **Values:** pattern · **Default:** not stated · advanced

Pattern for chapter names created from cue sheets.

<a id="default-language"></a>

#### `--default-language`

**Type:** string · **Values:** language · **Default:** not stated

Language for all tracks not set with --language.

<a id="generate-chapters"></a>

#### `--generate-chapters`

**Type:** string · **Values:** when-appending or interval:<duration> · **Default:** not stated

Generates chapters automatically.

<a id="generate-chapters-name-template"></a>

#### `--generate-chapters-name-template`

**Type:** string · **Values:** template · **Default:** Chapter <NUM:2> · advanced

Name template for generated chapters.

<a id="segmentinfo"></a>

#### `--segmentinfo`

**Type:** path · **Values:** file · **Default:** not stated · advanced

Reads segment information from a file.

<a id="segment-uid"></a>

#### `--segment-uid`

**Type:** string · **Values:** SID1[,SID2...] · **Default:** not stated · advanced

Sets the segment UIDs.

<a id="track-order"></a>

#### `--track-order`

**Type:** string · **Values:** FileID1:TID1,FileID2:TID2,... · **Default:** sorted by type (video, audio, subtitles, others)

Sets the track order in the output.

<a id="cluster-length"></a>

#### `--cluster-length`

**Type:** string · **Values:** n or n ms · **Default:** not stated · advanced

Limits each cluster to n blocks or n milliseconds.

<a id="clusters-in-meta-seek"></a>

#### `--clusters-in-meta-seek`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Writes meta seek entries for clusters.

<a id="timestamp-scale"></a>

#### `--timestamp-scale`

**Type:** int · **Values:** n · **Default:** not stated · advanced

Forces the timestamp scale factor.

<a id="enable-durations"></a>

#### `--enable-durations`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Writes block durations for all blocks.

<a id="no-cues"></a>

#### `--no-cues`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not write the cue index.

<a id="no-date"></a>

#### `--no-date`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not write the date field in segment info.

<a id="date"></a>

#### `--date`

**Type:** string · **Values:** timestamp (UTC or with offset, e.g. 2017-03-28T17:28:00Z) · **Default:** not stated · advanced

Sets the date field.

<a id="disable-lacing"></a>

#### `--disable-lacing`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Turns off lacing.

<a id="disable-track-statistics-tags"></a>

#### `--disable-track-statistics-tags`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not write track statistics tags.

<a id="disable-language-ietf"></a>

#### `--disable-language-ietf`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not write IETF BCP 47 language elements.

<a id="normalize-language-ietf"></a>

#### `--normalize-language-ietf`

**Type:** enum · **Values:** canonical, extlang, off · **Default:** canonical · advanced

Normalizes BCP 47 language tags.

<a id="stop-after-video-ends"></a>

#### `--stop-after-video-ends`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Stops when the primary video track ends and drops the rest of the other tracks.

<a id="split"></a>

#### `--split`

**Type:** string · **Values:** d[K,M,G] \| HH:MM:SS \| s \| timestamps:A[,B...] \| parts:start1-end1[,[+]start2-end2...] \| parts-frames:... \| frames:A[,B...] \| chapters:all\|A[,B...] · **Default:** not stated

Splits the output by size, duration, timestamps, kept parts, frames or chapters.

<a id="split-max-files"></a>

#### `--split-max-files`

**Type:** int · **Values:** n · **Default:** not stated · advanced

Creates at most n files when splitting.

<a id="link"></a>

#### `--link`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Links split files.

<a id="link-to-previous"></a>

#### `--link-to-previous`

**Type:** string · **Values:** SID · **Default:** not stated · advanced

Links the first file to the given segment UID.

<a id="link-to-next"></a>

#### `--link-to-next`

**Type:** string · **Values:** SID · **Default:** not stated · advanced

Links the last file to the given segment UID.

<a id="append-to"></a>

#### `--append-to`

**Type:** string · **Values:** SFID1:STID1:DFID1:DTID1,... · **Default:** not stated · advanced

Controls which track is appended to which track of the preceding file.

<a id="append-mode"></a>

#### `--append-mode`

**Type:** enum · **Values:** file, track · **Default:** not stated · advanced

How timestamps are computed when appending.

<a id="option"></a>

#### `+` (also `+<file>`, `[ <file1> <file2> ]`)

**Type:** string · **Values:** <file1> + <file2> · **Default:** not stated

Appends file2 to file1.

<a id="option"></a>

#### `=` (also `=<file>`)

**Type:** string · **Values:** = <file> · **Default:** not stated · advanced

Stops mkvmerge from looking for and concatenating files with the same base name and a different trailing number.

<a id="option"></a>

#### `( )`

**Type:** string · **Values:** ( <file1> <file2> ) · **Default:** not stated · advanced

Treats the listed files as one concatenated file.

<a id="attachment-description"></a>

#### `--attachment-description`

**Type:** string · **Values:** text · **Default:** not stated · advanced

Description for the next attachment.

<a id="attachment-mime-type"></a>

#### `--attachment-mime-type`

**Type:** string · **Values:** MIME type · **Default:** not stated · advanced

MIME type for the next attachment.

<a id="attachment-name"></a>

#### `--attachment-name`

**Type:** string · **Values:** name · **Default:** not stated · advanced

Stored name for the next attachment.

<a id="attach-file"></a>

#### `--attach-file`

**Type:** path · **Values:** file · **Default:** not stated

Attaches a file to the output.

<a id="attach-file-once"></a>

#### `--attach-file-once`

**Type:** path · **Values:** file · **Default:** not stated · advanced

Attaches a file to the first output file only.

<a id="enable-legacy-font-mime-types"></a>

#### `--enable-legacy-font-mime-types`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Uses legacy font MIME types for new and existing attachments.

<a id="audio-tracks"></a>

#### `--audio-tracks` (also `-a`)

**Type:** list · **Values:** n,m,... · **Default:** all audio tracks

Copies only the listed audio tracks.

<a id="subtitle-tracks"></a>

#### `--subtitle-tracks` (also `-s`)

**Type:** list · **Values:** n,m,... · **Default:** all subtitle tracks

Copies only the listed subtitle tracks.

<a id="no-subtitles"></a>

#### `--no-subtitles` (also `-S`)

**Type:** bool · **Values:** flag · **Default:** off

Copies no subtitle tracks from this file.

<a id="button-tracks"></a>

#### `--button-tracks` (also `-b`)

**Type:** list · **Values:** n,m,... · **Default:** all button tracks · advanced

Copies only the listed button tracks.

<a id="no-buttons"></a>

#### `--no-buttons` (also `-B`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Copies no button tracks.

<a id="attachments"></a>

#### `--attachments` (also `-m`)

**Type:** list · **Values:** n[:all\|first],m[:all\|first],... · **Default:** all attachments to all output files · advanced

Copies the listed attachments to all or only the first output file.

<a id="no-attachments"></a>

#### `--no-attachments` (also `-M`)

**Type:** bool · **Values:** flag · **Default:** off

Copies no attachments from this file.

<a id="tags"></a>

#### `--tags` (also `-t`)

**Type:** string · **Values:** TID:file · **Default:** not stated · advanced

Reads tags for a track from an XML file.

<a id="track-tags"></a>

#### `--track-tags`

**Type:** list · **Values:** n,m,... · **Default:** tags of all tracks · advanced

Copies tags only for the listed tracks.

<a id="no-track-tags"></a>

#### `--no-track-tags` (also `-T`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Copies no track tags.

<a id="no-global-tags"></a>

#### `--no-global-tags`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Drops the source's global tags.

<a id="no-chapters"></a>

#### `--no-chapters`

**Type:** bool · **Values:** flag · **Default:** off

Drops the source's chapters.

<a id="regenerate-track-uids"></a>

#### `--regenerate-track-uids`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Generates new random track UIDs.

<a id="sync"></a>

#### `--sync` (also `-y`)

**Type:** string · **Values:** TID:d[,o[/p]] · **Default:** not stated

Shifts a track's timestamps by d ms and optionally scales them by o/p to fix drift.

<a id="default-track-flag"></a>

#### `--default-track-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated

Sets the default-track flag (0 removes it).

<a id="forced-display-flag"></a>

#### `--forced-display-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated

Sets the forced-display flag (0 removes it).

<a id="track-enabled-flag"></a>

#### `--track-enabled-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the track-enabled flag (0 removes it).

<a id="hearing-impaired-flag"></a>

#### `--hearing-impaired-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the hearing-impaired flag (0 removes it).

<a id="visual-impaired-flag"></a>

#### `--visual-impaired-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the visually-impaired flag (0 removes it).

<a id="text-descriptions-flag"></a>

#### `--text-descriptions-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the text-descriptions flag (0 removes it).

<a id="original-flag"></a>

#### `--original-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the original-language flag (0 removes it).

<a id="commentary-flag"></a>

#### `--commentary-flag`

**Type:** string · **Values:** TID[:bool] · **Default:** not stated · advanced

Sets the commentary flag (0 removes it).

<a id="cues"></a>

#### `--cues`

**Type:** enum · **Values:** TID:none\|iframes\|all · **Default:** not stated in help (docs: iframes for video and subtitles, none for audio) · advanced

Chooses which frames get cue (index) entries.

<a id="timestamps"></a>

#### `--timestamps`

**Type:** string · **Values:** TID:file · **Default:** not stated · advanced

Reads the timestamps for a track from a file.

<a id="aac-is-sbr"></a>

#### `--aac-is-sbr`

**Type:** string · **Values:** TID[:0\|1] · **Default:** not stated · advanced

Declares whether an AAC track is HE-AAC/SBR.

<a id="reduce-to-core"></a>

#### `--reduce-to-core`

**Type:** string · **Values:** TID · **Default:** not stated · advanced

Keeps only the core of audio with HD extensions.

<a id="remove-dialog-normalization-gain"></a>

#### `--remove-dialog-normalization-gain`

**Type:** string · **Values:** TID · **Default:** not stated · advanced

Removes or minimizes dialog normalization gain in the frame headers.

<a id="audio-emphasis"></a>

#### `--audio-emphasis`

**Type:** string · **Values:** TID:n\|keyword (see --list-audio-emphasis) · **Default:** not stated · advanced

Sets the audio emphasis header value.

<a id="fourcc"></a>

#### `--fourcc` (also `-f`)

**Type:** string · **Values:** FOURCC · **Default:** not stated · advanced

Forces the FourCC (video tracks only).

<a id="aspect-ratio"></a>

#### `--aspect-ratio`

**Type:** string · **Values:** TID:f\|a/b · **Default:** not stated

Sets display dimensions from an aspect ratio.

<a id="aspect-ratio-factor"></a>

#### `--aspect-ratio-factor`

**Type:** string · **Values:** TID:f\|a/b · **Default:** not stated · advanced

Multiplies the original aspect ratio by a factor and sets display dimensions from it.

<a id="field-order"></a>

#### `--field-order`

**Type:** int · **Values:** TID:n (see documentation) · **Default:** not stated · advanced

Sets the field order (docs: 0 progressive, 2 undetermined, 1/6/9/14 interlaced variants).

<a id="stereo-mode"></a>

#### `--stereo-mode`

**Type:** string · **Values:** TID:n\|keyword (0-14, see --list-stereo-modes) · **Default:** not stated · advanced

Sets the stereo 3D mode.

<a id="projection-type"></a>

#### `--projection-type`

**Type:** int · **Values:** TID:method (0-3) · **Default:** not stated · advanced

Sets the 360-degree projection type (docs: 0 rectangular, 1 equirectangular, 2 cubemap, 3 mesh).

<a id="projection-private"></a>

#### `--projection-private`

**Type:** string · **Values:** TID:hex data · **Default:** not stated · advanced

Projection-specific private data.

<a id="projection-pose-yaw"></a>

#### `--projection-pose-yaw`

**Type:** float · **Values:** TID:float · **Default:** not stated · advanced

Yaw rotation of the projection.

<a id="projection-pose-pitch"></a>

#### `--projection-pose-pitch`

**Type:** float · **Values:** TID:float · **Default:** not stated · advanced

Pitch rotation of the projection.

<a id="projection-pose-roll"></a>

#### `--projection-pose-roll`

**Type:** float · **Values:** TID:float · **Default:** not stated · advanced

Roll rotation of the projection.

<a id="sub-charset"></a>

#### `--sub-charset`

**Type:** string · **Values:** TID:charset · **Default:** not stated

Charset used to read text subtitles for conversion to UTF-8.

<a id="compression"></a>

#### `--compression`

**Type:** enum · **Values:** TID:none\|zlib · **Default:** not stated · advanced

Compression method for VobSub tracks.

<a id="field-mode"></a>

#### `field_mode`

**Type:** enum · **Values:** auto, bff, tff, prog · **Default:** auto · advanced

Relabels the frames' field order without changing pixels.

<a id="aud"></a>

#### `aud`

**Type:** enum · **Values:** pass(0), insert(1), remove(2) · **Default:** pass · advanced

Inserts or removes access unit delimiters.

<a id="sample-aspect-ratio"></a>

#### `sample_aspect_ratio`

**Type:** string · **Values:** rational 0 to 65535 (table E-1) · **Default:** 0/1 · advanced

Rewrites the VUI sample aspect ratio.

<a id="overscan-appropriate-flag"></a>

#### `overscan_appropriate_flag`

**Type:** int · **Values:** -1 to 1 · **Default:** -1 · advanced

Rewrites the VUI overscan flag.

<a id="tick-rate"></a>

#### `tick_rate`

**Type:** string · **Values:** rational 0 to UINT32_MAX · **Default:** 0/1 · advanced

Sets the VUI tick rate (time_scale / num_units_in_tick).

<a id="fixed-frame-rate-flag"></a>

#### `fixed_frame_rate_flag`

**Type:** int · **Values:** -1 to 1 · **Default:** -1 · advanced

Rewrites the VUI fixed frame rate flag.

<a id="zero-new-constraint-set-flags"></a>

#### `zero_new_constraint_set_flags`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Clears constraint_set4_flag and constraint_set5_flag.

<a id="crop-left"></a>

#### `crop_left`

**Type:** int · **Values:** -1 to 16880 · **Default:** -1 · advanced

Sets the left frame-cropping offset.

<a id="crop-right"></a>

#### `crop_right`

**Type:** int · **Values:** -1 to 16880 · **Default:** -1 · advanced

Sets the right frame-cropping offset.

<a id="crop-top"></a>

#### `crop_top`

**Type:** int · **Values:** -1 to 16880 · **Default:** -1 · advanced

Sets the top frame-cropping offset.

<a id="crop-bottom"></a>

#### `crop_bottom`

**Type:** int · **Values:** -1 to 16880 · **Default:** -1 · advanced

Sets the bottom frame-cropping offset.

<a id="delete-filler"></a>

#### `delete_filler`

**Type:** int · **Values:** 0 to 1 · **Default:** 0 · advanced

Deletes filler data (NAL and SEI).

<a id="display-orientation"></a>

#### `display_orientation`

**Type:** enum · **Values:** pass(0), insert(1), remove(2), extract(3) · **Default:** pass · advanced

Handles the display orientation SEI.

<a id="rotate"></a>

#### `rotate`

**Type:** float · **Values:** -360 to 360 (degrees, anticlockwise) · **Default:** nan · advanced

Rotation written to the display orientation SEI.

<a id="flip"></a>

#### `flip`

**Type:** flags · **Values:** horizontal, vertical · **Default:** 0 · advanced

Flip written to the display orientation SEI.

<a id="level"></a>

#### `level`

**Type:** enum · **Values:** auto, 1, 1b, 1.1 ... 6.2 (or level_idc) · **Default:** -2 (unchanged) · advanced

Rewrites the SPS level.

<a id="overscan-appropriate-flag"></a>

#### `overscan_appropriate_flag`

**Type:** bool · **Values:** bool · **Default:** auto · advanced

Rewrites the LCEVC VUI overscan flag.

<a id="delete-filler"></a>

#### `delete_filler`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Deletes filler data from the LCEVC stream.

<a id="display-aspect-ratio"></a>

#### `display_aspect_ratio`

**Type:** string · **Values:** rational 0 to 65535 (table 6-3) · **Default:** 0/1 · advanced

Rewrites the MPEG-2 display aspect ratio.

<a id="frame-rate"></a>

#### `frame_rate`

**Type:** string · **Values:** rational 0 to UINT32_MAX · **Default:** 0/1 · advanced

Rewrites the MPEG-2 frame rate.

<a id="ts"></a>

#### `ts`

**Type:** string · **Values:** expression · **Default:** TS · advanced

Expression for packet PTS and DTS.

<a id="pts"></a>

#### `pts`

**Type:** string · **Values:** expression · **Default:** not stated · advanced

Expression for packet PTS.

<a id="dts"></a>

#### `dts`

**Type:** string · **Values:** expression · **Default:** not stated · advanced

Expression for packet DTS.

<a id="duration"></a>

#### `duration`

**Type:** string · **Values:** expression · **Default:** DURATION · advanced

Expression for packet duration.

<a id="time-base"></a>

#### `time_base`

**Type:** string · **Values:** rational 0 to INT_MAX · **Default:** 0/1 · advanced

Output time base.

<a id="prescale"></a>

#### `prescale`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Converts to the output time base before evaluating.

<a id="freq"></a>

#### `freq`

**Type:** enum · **Values:** k/keyframe(0), e/all(1) · **Default:** k · advanced

When to repeat extradata (parameter sets) in packets.

<a id="remove"></a>

#### `remove`

**Type:** int · **Values:** 0 to 1 · **Default:** 0 · advanced

Removes the extradata from the bitstream after extracting it.

<a id="freq"></a>

#### `freq`

**Type:** enum · **Values:** keyframe(0), e/all(1), k(2) · **Default:** keyframe · advanced

When to strip extradata from packets.

**Notes:** The help lists k as 2 and keyframe as 0, which looks inconsistent; recorded verbatim.

### Color and HDR

<a id="mode"></a>

#### `--mode` (also `-m`)

**Type:** enum · **Values:** 0, 1, 2, 3, 4, 5 · **Default:** not stated (README: without a mode the RPU is copied untouched) · **HDR-relevant**

Chooses how each RPU is rewritten as it passes through convert, demux, mux, extract-rpu or editor. 0 re-serializes as is, 1 makes it MEL-compatible, 2 makes it profile 8.1 and drops the luma/chroma mapping, 3 turns profile 5 into 8.1, 4 makes profile 8.4, 5 makes 8.1 but keeps the mapping.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `2` | Standard choice for turning a UHD Blu-ray profile 7 (FEL or MEL) stream into a single-layer, HDR10-compatible profile 8.1 stream; with FEL the mapping is removed because the enhancement layer it depended on is discarded. | [source](https://github.com/quietvoid/dovi_tool) |
| HDR | `5` | Use only when you want 8.1 signaling but must keep the original luma/chroma mapping; the README labels mode 5 as the old mode 2 behavior. If unsure, prefer 2. | [source](https://github.com/quietvoid/dovi_tool) |
| HDR | `3` | Converts a profile 5 RPU to profile 8.1 signaling (README). Treat as advanced. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** DolbyVisionRetimer.retime runs `dovi_tool -m 2 extract-rpu` so the retimed RPU is always profile 8.1 before it is edited and injected.

**Notes:** Global option: it goes BEFORE the subcommand (dovi_tool -m 2 convert ...). Mode 2 changed meaning in an older release; the former mode 2 is now mode 5 (README). Unverified (no source found): a profile 5 base layer is not HDR10 video, so mode 3 alone may not give a usable HDR10 fallback; community opinions differ on whether mode 5 helps over mode 2.

<a id="crop"></a>

#### `--crop` (also `-c`)

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Zeroes the L5 active-area offsets in every RPU, telling Dolby Vision displays there are no letterbox bars.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `set when the black bars were cropped away in the encode` | After cropping, the original L5 offsets would point at bars that no longer exist and can cause wrong scaling/placement on some displays. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** Not used directly; Lumora resets the active area through the editor JSON (`active_area: {crop: true}`) when the source was cropped.

**Notes:** Equivalent editor setting: active_area.crop in the --edit-config/editor JSON.

<a id="drop-hdr10plus"></a>

#### `--drop-hdr10plus`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

When writing HEVC output, skips any HDR10+ SEI messages found in the input so the result carries Dolby Vision only.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `set when a player chokes on files carrying both DV and HDR10+` | Some devices misbehave with both dynamic formats present; dropping HDR10+ keeps DV plus the static HDR10 fallback. | [source](https://github.com/quietvoid/dovi_tool) |

<a id="edit-config"></a>

#### `--edit-config`

**Type:** path · **Values:** JSON file · **Default:** not stated · **HDR-relevant** · advanced

Applies an editor JSON (same format as the editor subcommand) while processing an HEVC file instead of a bare RPU.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `prefer `editor` on an extracted RPU` | The standalone editor supports every key; the HEVC path supports only part of it. | [source](https://github.com/quietvoid/dovi_tool) |

**Notes:** README says editing during HEVC processing is limited compared with the editor subcommand; edit a standalone RPU when possible.

<a id="discard"></a>

#### `--discard` (also `-d`)

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant**

Throws away the enhancement-layer NAL units so only the base layer plus (converted) RPU remain.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `set together with -m 2` | This is the README's one-step profile 7 to 8.1 conversion: keep BL + RPU, drop EL. | [source](https://github.com/quietvoid/dovi_tool) |

<a id="json"></a>

#### `--json` (also `-j`)

**Type:** path · **Values:** JSON file · **Default:** not stated (required) · **HDR-relevant**

Edit recipe. Top-level keys include mode, remove, duplicate, active_area, scene_cuts, min_pq/max_pq, level6 (static HDR10 fallback values), level9, level11, source_rpu + rpu_levels, remove_cmv4, remove_mapping.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `remove first, then duplicate (frame indices are 0-based, ranges inclusive)` | The editor applies removals before duplications, so build duplicate offsets against the post-removal numbering. | [source](https://github.com/quietvoid/dovi_tool/blob/main/docs/editor.md) |
| HDR | `level6 matching the encode's mastering display and MaxCLL/MaxFALL` | L6 is the HDR10 fallback inside the RPU; it should agree with the stream's static SEI. | [source](https://github.com/quietvoid/dovi_tool/blob/main/docs/editor.md) |

**In Lumora:** Lumora writes JSON with `remove`, `active_area.crop` and `duplicate` to retime DV metadata to interpolated frame counts.

**Notes:** Duplicate entries take {source, offset, length}; offset is the insertion index (inclusive).

<a id="rpu-in"></a>

#### `--rpu-in` (also `-r`)

**Type:** path · **Values:** RPU .bin · **Default:** not stated (required) · **HDR-relevant**

RPU file whose entries are inserted, one per frame, after each frame's slices.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `an RPU with exactly as many entries as the video has frames` | RPUs are matched to frames in order; a count mismatch shifts or truncates metadata. Check with `dovi_tool info -s` first. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** Lumora verifies the retimed RPU's frame count with `info -s` before injecting.

<a id="json"></a>

#### `--json` (also `-j`)

**Type:** path · **Values:** generator config JSON · **Default:** not stated · **HDR-relevant**

Generator config describing the target profile, length, static (L6) values, shots and per-shot L1/L2 data.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `start from the repo's assets/generator_examples (default_cmv40.json)` | These are known-good templates; edit length, L6 and shots rather than writing from scratch. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** Lumora builds its own generator JSON (HDRMetadata.doviGeneratorJSON) with per-shot max/avg nits and runs `generate -j ... -o rpu.bin`.

<a id="hdr10plus-json"></a>

#### `--hdr10plus-json`

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated · **HDR-relevant** · advanced

Builds DV L1 metadata from an HDR10+ JSON (as made by hdr10plus_tool extract), so an HDR10+ title can also carry Dolby Vision.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `use with -j holding a profile 8.1 config` | Common route to give HDR10+ releases a DV 8.1 layer for DV-only displays. | [source](https://github.com/gacopl/dvmkv2mp4) |

<a id="hdr10plus-peak-source"></a>

#### `--hdr10plus-peak-source`

**Type:** enum · **Values:** histogram, histogram99, max-scl, max-scl-luminance · **Default:** histogram · **HDR-relevant** · advanced

Chooses which HDR10+ field becomes the per-frame peak brightness when converting HDR10+ to DV.

**Notes:** histogram99 ignores the brightest 0.02% or so, which gives less conservative (brighter) tone mapping; which looks better is content dependent and sources do not agree on a single best value.

<a id="xml"></a>

#### `--xml` (also `-x`)

**Type:** path · **Values:** Dolby CMv2.9/CMv4.0 XML · **Default:** not stated · **HDR-relevant** · advanced

Generates the RPU from a Dolby Vision metadata XML exported by a grading tool.

<a id="canvas-width"></a>

#### `--canvas-width`

**Type:** int · **Values:** pixels · **Default:** not stated · **HDR-relevant** · advanced

Picture width used to compute L5 offsets when the XML is the source.

<a id="canvas-height"></a>

#### `--canvas-height`

**Type:** int · **Values:** pixels · **Default:** not stated · **HDR-relevant** · advanced

Picture height used to compute L5 offsets when the XML is the source.

<a id="madvr-file"></a>

#### `--madvr-file`

**Type:** path · **Values:** madVR measurement file · **Default:** not stated · **HDR-relevant** · advanced

Generates L1 metadata from a madVR HDR measurement file.

<a id="use-custom-targets"></a>

#### `--use-custom-targets`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

With a madVR file, uses its per-frame custom target nits if present.

<a id="profile"></a>

#### `--profile` (also `-p`)

**Type:** enum · **Values:** 5, 8.1, 8.4 · **Default:** not stated · **HDR-relevant**

Dolby Vision profile to produce (overrides the JSON).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `8.1` | For PQ/HDR10 encodes: DV devices get dynamic metadata, everything else plays the HDR10 base. | [source](https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html) |
| HDR | `8.4` | For HLG encodes: DV devices use DV, others fall back to HLG. | [source](https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html) |

<a id="long-play-mode"></a>

#### `--long-play-mode`

**Type:** enum · **Values:** true, false · **Default:** not stated · **HDR-relevant** · advanced

Marks every frame as a scene cut (scene refresh) in the generated RPU.

**Notes:** Not explained further in the README; leave unset unless a device specifically needs it.

<a id="discard"></a>

#### `--discard` (also `-d`)

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Drops the EL video NAL units while muxing, keeping only its RPU (so the output is single-layer).

<a id="skip-validation"></a>

#### `--skip-validation`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Skips the profile conformance check; nonconforming metadata is labeled profile N/A instead of stopping the tool.

**Notes:** Use only to salvage odd sources; invalid metadata may confuse TVs.

<a id="skip-reorder"></a>

#### `--skip-reorder`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Keeps metadata in decode order instead of reordering it to presentation order. A workaround for discs that were authored with metadata in the wrong order.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `only if SceneFrameNumbers shows many 1-3 frame scenes` | That pattern is the README's sign of misordered source metadata; otherwise reordering is correct when B-frames exist. | [source](https://github.com/quietvoid/hdr10plus_tool) |

<a id="json"></a>

#### `--json` (also `-j`)

**Type:** path · **Values:** HDR10+ JSON · **Default:** not stated (required) · **HDR-relevant**

HDR10+ metadata to insert before each frame's slices.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `JSON with one entry per frame of the target stream` | Metadata is applied frame by frame; after changing frame rate or trimming, rebuild or edit the JSON (hdr10plus_tool editor) so counts match. | [source](https://github.com/quietvoid/hdr10plus_tool) |

**In Lumora:** Lumora writes the JSON itself from per-shot measured light levels (HDRMetadata.hdr10PlusJSON).

<a id="json"></a>

#### `--json` (also `-j`)

**Type:** path · **Values:** edits JSON · **Default:** not stated (required) · **HDR-relevant** · advanced

Edit recipe with `remove` (frames or inclusive ranges) and `duplicate` ({source, offset, length}) lists; removals run first.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `use to match metadata to a trimmed or frame-rate-converted encode` | Same remove/duplicate model as dovi_tool editor, applied to HDR10+. | [source](https://github.com/quietvoid/hdr10plus_tool) |

**In Lumora:** Not used; Lumora regenerates HDR10+ JSON from measurements instead of retiming the source's metadata.

<a id="par"></a>

#### `-par`

**Type:** string · **Values:** tkID=N:D \| wN:D \| none \| auto \| force · **Default:** not stated · advanced

Sets or clears the pixel aspect ratio, optionally rewriting it in the bitstream (w prefix).

<a id="clap"></a>

#### `-clap`

**Type:** string · **Values:** tkID=Wn,Wd,Hn,Hd,HOn,HOd,VOn,VOd or none · **Default:** not stated · advanced

Sets the clean aperture (container-level crop).

<a id="hdr"></a>

#### `-hdr`

**Type:** path · **Values:** XML file or none · **Default:** not stated · **HDR-relevant** · advanced

Writes HDR10 static metadata boxes (mdcv mastering display and clli light level) into the video track(s) from an XML file; 'none' removes them.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `<HDR><Track id="1"><mdcv display_primaries_0_x="13250" display_primaries_0_y="34500" display_primaries_1_x="7500" display_primaries_1_y="3000" display_primaries_2_x="34000" display_primaries_2_y="16000" white_point_x="15635" white_point_y="16450" max_display_mastering_luminance="10000000" min_display_mastering_luminance="1"/><clli max_content_light_level="1000" max_pic_average_light_level="400"/></Track></HDR>` | The parser expects root <HDR>, <Track id> children and mdcv/clli elements with these exact attribute names (read from GPAC source). Units follow the HEVC SEI: 0.00002 for chromaticity, 0.0001 cd/m2 for luminance. Index 0/1/2 = G/B/R, confirmed by test: ffprobe read index 2 back as red. | [source](https://github.com/gpac/gpac/blob/master/applications/mp4box/fileimport.c) |

**Notes:** Format undocumented in help and wiki; element and attribute names verified in applications/mp4box/fileimport.c (apply_high_dynamc_range_xml_desc). Observed with GPAC 26.07: `MP4Box -hdr hdr.xml file.mp4` (in place) worked, while adding -out new.mp4 wrote no file; the per-file :hdr= import option also worked.

<a id="dvp"></a>

#### `dvp` (also `dv-profile`, `:dvp=`, `:dv-profile=`)

**Type:** string · **Values:** integer profile, none, optional .compat suffix (none, hdr10, bt709, hlg709, hlg2100, bt2020, brd or integer), optional f prefix · **Default:** not stated (no DV signaling) · **HDR-relevant**

Marks the imported track as Dolby Vision: writes the dvcC/dvvC configuration and DV sample entry for the given profile and base-layer compatibility; 'none' strips DV signaling.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `8.1` | Profile 8 with HDR10-compatible base (compatibility ID 1); non-DV players show HDR10. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |
| HDR | `8.4` | HLG-compatible base layer; non-DV players fall back to HLG. | [source](https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html) |
| HDR | `5` | Profile 5 has no HDR10 fallback; only for DV-only targets. Apple HLS rule 1.9 requires Profile 5 (level 7 or lower) for HEVC Dolby Vision variants; 8.1/8.4 appear there only as supplemental codecs. | [source](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices) |

**In Lumora:** Lumora adds `:dvp=8.1` for the Dolby Vision 8.1 delivery; no dvp for HDR10+.

**Notes:** Help shows 'dvp,-dv-profile'. The f prefix forces the DV codec type (e.g. dvh1) instead of the backward-compatible hvc1 entry with dvcC; behavior per GPAC help, players differ in which form they accept. Tested with GPAC 26.07: -add v.hevc:dvp=8.1:fps=24000/1001 produced an hvc1 entry with a DV profile 8 configuration (compatibility 1).

<a id="dvmdc"></a>

#### `dvmdc` (also `:dvmdc=`)

**Type:** int · **Values:** 0, 1, 3 · **Default:** 0 · **HDR-relevant** · advanced

Sets the Dolby Vision metadata compression field in the DV configuration.

**Notes:** Matches FFmpeg dovi_rpu compression none/limited/extended (0/1/3). Leave 0 unless the RPU was written compressed.

<a id="hdr"></a>

#### `hdr` (also `:hdr=`)

**Type:** path · **Values:** XML file or none · **Default:** not stated · **HDR-relevant** · advanced

Per-track version of -hdr (mdcv/clli from XML).

<a id="colr"></a>

#### `colr` (also `:colr=`)

**Type:** string · **Values:** nclc,p,t,m \| nclx,p,t,m,r \| prof,path \| rICC,path \| none · **Default:** not stated · **HDR-relevant**

Writes a container colr box: CICP primaries/transfer/matrix (nclx adds the full-range flag) or an ICC profile; none removes color info.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `nclx,bt2020,smpte2084,bt2020,no` | Container color for HDR10 (PQ, BT.2020, limited range), matching the bitstream VUI. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |
| HDR | `nclx,BT2020,STDB67,BT2020,no` | HLG equivalent. MP4Box only accepts its own CICP names (MP4Box -h cicp) or numbers (nclx,9,18,9,no); tested: 'arib-std-b67' is rejected with 'Unknown CICP color transfer type'. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

**Notes:** Help text says 'nclx: same as nclx with r'; it means same as nclc plus range. CICP names/ints come from `MP4Box -h cicp`. The colr box does not change the bitstream VUI; use colorprim/colortfc/colormx for that.

<a id="colorprim"></a>

#### `colorprim` (also `:colorprim=`)

**Type:** string · **Values:** int or CICP name (MP4Box -h cicp) · **Default:** not stated · **HDR-relevant** · advanced

Rewrites colour_primaries in the AVC/HEVC VUI during import.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9 (BT2020)` | Fixes HDR streams that were encoded without VUI color description, without re-encoding. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

<a id="colortfc"></a>

#### `colortfc` (also `:colortfc=`)

**Type:** string · **Values:** int or CICP name · **Default:** not stated · **HDR-relevant** · advanced

Rewrites transfer_characteristics in the AVC/HEVC VUI.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `16 (SMPTE2084) for HDR10, 18 (STDB67) for HLG` | Transfer is what tells players a stream is PQ or HLG. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

<a id="colormx"></a>

#### `colormx` (also `:colormx=`)

**Type:** string · **Values:** int or CICP name · **Default:** not stated · **HDR-relevant** · advanced

Rewrites matrix_coefficients in the AVC/HEVC VUI.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9 (BT2020 non-constant)` | Standard matrix for HDR10/HLG Y'CbCr. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

<a id="fullrange"></a>

#### `fullrange` (also `:fullrange=`)

**Type:** string · **Values:** yes, on, no, off · **Default:** not stated · **HDR-relevant** · advanced

Forces the full-range flag in the VUI (help says AVC/H.264 only).

<a id="videofmt"></a>

#### `videofmt` (also `:videofmt=`)

**Type:** string · **Values:** component, pal, ntsc, secam, mac, undef · **Default:** not stated · advanced

Forces video_format in the AVC/HEVC VUI.

<a id="bitdepth"></a>

#### `bitdepth` (also `:bitdepth=`)

**Type:** int · **Values:** VAL · **Default:** 24 · advanced

Sets the bit-depth field of the visual sample entry (24 = 8-bit RGB convention).

**Notes:** This is the sample-entry 'depth' field, not the codec bit depth; it does not make a stream 10-bit.

<a id="nosei"></a>

#### `nosei` (also `:nosei`)

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant** · advanced

Discards every SEI message during import.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `never use on HDR10/HDR10+ sources` | HDR10 mastering display/light level and HDR10+ metadata are SEI messages; this would strip them. | [source](https://wiki.gpac.io/MP4Box/mp4box-import-opts/) |

<a id="cropping"></a>

#### `--cropping`

**Type:** string · **Values:** TID:left,top,right,bottom · **Default:** not stated · advanced

Stores container-level crop values (pixels).

<a id="display-dimensions"></a>

#### `--display-dimensions`

**Type:** string · **Values:** TID:widthxheight · **Default:** not stated · advanced

Sets the display size explicitly.

<a id="color-matrix-coefficients"></a>

#### `--color-matrix-coefficients`

**Type:** int · **Values:** TID:n (0-10 per docs; H.273 numbering) · **Default:** not stated · **HDR-relevant** · advanced

Stores the matrix coefficients in the Matroska Colour element.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:9` | BT.2020 non-constant luminance, the HDR10/HLG matrix. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

**Notes:** Help limits to n; the docs list 0-10 with 9 = BT.2020 NCL, 10 = BT.2020 CL, 2 = unspecified.

<a id="color-bits-per-channel"></a>

#### `--color-bits-per-channel`

**Type:** int · **Values:** TID:n (0 = unspecified) · **Default:** not stated · **HDR-relevant** · advanced

Stores coded bits per channel.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:10` | Documents 10-bit HDR10 content for players that read it. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="chroma-subsample"></a>

#### `--chroma-subsample`

**Type:** string · **Values:** TID:hori,vert · **Default:** not stated · **HDR-relevant** · advanced

Stores how many chroma samples are dropped per kept sample (4:2:0 = 1,1).

<a id="cb-subsample"></a>

#### `--cb-subsample`

**Type:** string · **Values:** TID:hori,vert · **Default:** not stated · advanced

Extra Cb-only subsampling, added to --chroma-subsample (rare formats such as 4:2:1).

<a id="chroma-siting"></a>

#### `--chroma-siting`

**Type:** string · **Values:** TID:hori,vert (0 unspecified, 1 top collocated, 2 half) · **Default:** not stated · **HDR-relevant** · advanced

Stores where chroma samples sit relative to luma, per axis.

**Notes:** H.273 chroma_sample_loc_type 0 (left) = horizontal 1 (collocated), vertical 2 (half); type 2 (top-left) = 1,1. My mapping from the definitions, not stated by mkvmerge docs.

<a id="color-range"></a>

#### `--color-range`

**Type:** int · **Values:** TID:n (0 unspecified, 1 broadcast/limited, 2 full, 3 derived from matrix and transfer) · **Default:** not stated · **HDR-relevant** · advanced

Stores the color range.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:1` | HDR10 and HLG delivery is limited (broadcast) range. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="color-transfer-characteristics"></a>

#### `--color-transfer-characteristics`

**Type:** int · **Values:** TID:n (0-18; H.273 numbering) · **Default:** not stated · **HDR-relevant** · advanced

Stores the transfer function.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:16` | SMPTE ST 2084 (PQ) for HDR10. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |
| HDR | `0:18` | ARIB STD-B67 (HLG). | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="color-primaries"></a>

#### `--color-primaries`

**Type:** int · **Values:** TID:n (H.273 numbering; 1 BT.709, 9 BT.2020, 22 JEDEC P22) · **Default:** not stated · **HDR-relevant** · advanced

Stores the color primaries.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:9` | BT.2020 container primaries for HDR10/HLG. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="max-content-light"></a>

#### `--max-content-light`

**Type:** int · **Values:** TID:n cd/m2 · **Default:** not stated · **HDR-relevant** · advanced

Stores MaxCLL (brightest single pixel).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `measured MaxCLL, e.g. 0:1000` | Should equal the value in the HEVC SEI; 0 means unknown. | [source](https://x265.readthedocs.io/en/master/cli.html) |

<a id="max-frame-light"></a>

#### `--max-frame-light`

**Type:** int · **Values:** TID:n cd/m2 · **Default:** not stated · **HDR-relevant** · advanced

Stores MaxFALL (brightest frame average).

<a id="chromaticity-coordinates"></a>

#### `--chromaticity-coordinates`

**Type:** string · **Values:** TID:red-x,red-y,green-x,green-y,blue-x,blue-y (CIE 1931, decimal) · **Default:** not stated · **HDR-relevant** · advanced

Stores the mastering display primaries.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:0.680,0.320,0.265,0.690,0.150,0.060` | P3-D65 mastering display, the most common HDR10 grade. Note: decimal xy and R,G,B order, unlike the HEVC SEI / x265 G,B,R integer form. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="white-color-coordinates"></a>

#### `--white-color-coordinates`

**Type:** string · **Values:** TID:x,y · **Default:** not stated · **HDR-relevant** · advanced

Stores the mastering display white point.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:0.3127,0.3290` | D65 white point. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="max-luminance"></a>

#### `--max-luminance`

**Type:** float · **Values:** TID:float cd/m2 (below 9999.99) · **Default:** not stated · **HDR-relevant** · advanced

Stores the mastering display peak luminance.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:1000` | Typical 1000-nit mastering monitor; use the grade's real value. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="min-luminance"></a>

#### `--min-luminance`

**Type:** float · **Values:** TID:float cd/m2 (below 999.9999) · **Default:** not stated · **HDR-relevant** · advanced

Stores the mastering display minimum luminance.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `0:0.0001` | Equals L(...,1) in x265 units of 0.0001 cd/m2. | [source](https://x265.readthedocs.io/en/master/cli.html) |

<a id="mastering-display"></a>

#### `-mastering_display` (also `-mastering_display:v:0`)

**Type:** string · **Values:** G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min) (unsigned ints; xy in 0.00002, L in 0.0001 cd/m2) · **Default:** not stated · **HDR-relevant**

Input, per-stream option that replaces the stream's mastering display metadata with the given values. On stream copy to MP4/MOV the muxer then writes an mdcv box; on re-encode, encoders that pass HDR10 side data through (libx264, libx265 and libsvtav1 since FFmpeg 7.0, hevc_nvenc since 7.1) write the SEI/OBU.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)` | P3-D65 1000-nit mastering display; identical string format to x265 --master-display. | [source](https://x265.readthedocs.io/en/master/cli.html) |

**Notes:** Placed before -i (the man page marks it input,per-stream). Tested with 9.0.2: `-mastering_display ... -content_light ... -i in.mp4 -c copy out.mp4` added mdcv and clli boxes without touching the bitstream; with libx265 the same input options also produced the HEVC SEI.

<a id="content-light"></a>

#### `-content_light` (also `-content_light:v:0`)

**Type:** string · **Values:** MaxCLL,MaxFALL (cd/m2) · **Default:** not stated · **HDR-relevant**

Input, per-stream option that overrides MaxCLL/MaxFALL content light metadata.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `1000,400 (use measured values)` | Matches x265 --max-cll semantics; 0 means not indicated. | [source](https://x265.readthedocs.io/en/master/cli.html) |

**Notes:** Input option (man page). Format MaxCLL,MaxFALL as unsigned integers. Tested with 9.0.2 together with -mastering_display (see that entry).

<a id="pix-fmt"></a>

#### `-pix_fmt`

**Type:** enum · **Values:** pixel format name (ffmpeg -pix_fmts) · **Default:** encoder's best match (with a warning) · **HDR-relevant**

Chooses the pixel format handed to the encoder; for HDR this must be a 10-bit (or higher) format.

**Effect:** quality + with 10-bit for HDR · speed none · size ±

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `yuv420p10le` | PQ in 8 bits bands badly; HDR10 is defined as 10-bit 4:2:0. | [source](https://x265.readthedocs.io/en/master/cli.html) |

**In Lumora:** Lumora feeds encoders 10/12-bit Y4M itself; ffmpeg -pix_fmt yuv444p10le is used for AVIF stills.

**Notes:** Prefix with + to make ffmpeg fail instead of silently picking another format.

<a id="color-primaries"></a>

#### `-color_primaries`

**Type:** enum · **Values:** bt709(1) unknown/unspecified(2) bt470m(4) bt470bg(5) smpte170m(6) smpte240m(7) film(8) bt2020(9) smpte428/smpte428_1(10) smpte431(11) smpte432(12) jedec-p22/ebu3213(22) · **Default:** unknown · **HDR-relevant**

Codec-level tag for color primaries. On input it overrides the decoder's guess; on output it is meant to reach the bitstream VUI and the container, but see the notes. It never converts pixels.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020` | HDR10 and HLG use BT.2020 container primaries. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |
| HDR | `set all three tags (primaries, trc, colorspace)` | The MP4/MOV muxer writes the colr box only if all three are specified. | [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c) |

**In Lumora:** Used for AVIF stills (bt2020) and in end-to-end tests; video encodes set color in the CLI encoders' own flags instead.

**Notes:** Help says 'from 1 to INT_MAX' but lists 2 as unspecified; value 0 is reserved. Observed with 9.0.2 (2026-11-12): as an output option during a libx265 encode from an untagged source, this value was replaced by the frames' unspecified value, so neither the VUI nor the MP4 colr box got it (-colorspace and -color_range survived). Tag the frames with the setparams filter instead; that worked.

<a id="color-trc"></a>

#### `-color_trc`

**Type:** enum · **Values:** bt709(1) unknown(2) gamma22/bt470m(4) gamma28/bt470bg(5) smpte170m(6) smpte240m(7) linear(8) log/log100(9) log_sqrt/log316(10) iec61966-2-4(11) bt1361e(12) iec61966-2-1(13) bt2020-10(14) bt2020-12(15) smpte2084(16) smpte428(17) arib-std-b67(18) · **Default:** unknown · **HDR-relevant**

Tags the transfer characteristic; this is what makes a player treat a stream as PQ (HDR10) or HLG.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `smpte2084` | HDR10 / Dolby Vision 8.1 base. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |
| HDR | `arib-std-b67` | HLG / Dolby Vision 8.4 base. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |

**In Lumora:** AVIF stills use smpte2084 or arib-std-b67 depending on target.

**Notes:** Observed with 9.0.2 (2026-11-12): as an output option during a libx265 encode from an untagged source, this value was replaced by the frames' unspecified value, so neither the VUI nor the MP4 colr box got it (-colorspace and -color_range survived). Tag the frames with the setparams filter instead; that worked.

<a id="colorspace"></a>

#### `-colorspace`

**Type:** enum · **Values:** rgb(0) bt709(1) unknown(2) fcc(4) bt470bg(5) smpte170m(6) smpte240m(7) ycgco/ycocg(8) bt2020nc/bt2020_ncl(9) bt2020c/bt2020_cl(10) smpte2085(11) chroma-derived-nc(12) chroma-derived-c(13) ictcp(14) ipt-c2(15) ycgco-re(16) ycgco-ro(17) · **Default:** unknown · **HDR-relevant**

Tags the Y'CbCr matrix coefficients.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020nc` | Standard matrix for HDR10 and HLG. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |

**In Lumora:** AVIF stills use bt2020nc.

<a id="color-range"></a>

#### `-color_range`

**Type:** enum · **Values:** unknown/unspecified(0) tv/mpeg/limited(1) pc/jpeg/full(2) · **Default:** unknown · **HDR-relevant**

Tags limited vs full range; as an input option it is a hint to the decoder.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `tv` | HDR10/HLG distribution is limited range; full-range HDR is rare and poorly supported. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |

**Notes:** FFmpeg numbering (1=tv, 2=pc) differs from the H.273 VideoFullRangeFlag (0=limited, 1=full) and from bitstream filters (tv=0, pc=1).

<a id="chroma-sample-location"></a>

#### `-chroma_sample_location`

**Type:** enum · **Values:** unknown/unspecified(0) left(1) center(2) topleft(3) top(4) bottomleft(5) bottom(6) · **Default:** unknown · **HDR-relevant** · advanced

Tags where chroma samples sit for subsampled formats.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `left (most video) or topleft (some UHD/BT.2020 masters); keep the source's value` | Wrong siting shifts color edges by half a pixel; preserve rather than guess. | [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/pixfmt.h) |

**Notes:** FFmpeg value = H.273 chroma_sample_loc_type + 1 (left 1 = type 0, topleft 3 = type 2). The hevc_metadata/h264_metadata bsfs use the raw H.273 type (0-5). Sources disagree on what UHD HDR typically uses; verify per title.

<a id="side-data-prefer-packet"></a>

#### `-side_data_prefer_packet`

**Type:** list · **Values:** replaygain, displaymatrix, spherical, stereo3d, audio_service_type, mastering_display_metadata, content_light_level, icc_profile, exif · **Default:** not stated · **HDR-relevant** · advanced

When container (packet) side data and in-bitstream data disagree, prefer the container copy for the listed types.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `mastering_display_metadata,content_light_level when a remux fixed the container values but the SEI is wrong` | Lets the corrected container metadata win when re-encoding. | [source](https://ffmpeg.org/ffmpeg-codecs.html) |

**Notes:** Decoder option; by default the coded bitstream wins.

<a id="apply-cropping"></a>

#### `-apply_cropping`

**Type:** enum · **Values:** none (0), all (1), codec (2), container (3) · **Default:** all (ffmpeg man page) · advanced

Whether decoded frames are cropped by bitstream conformance window and/or container crop.

**Notes:** Values and default are from the installed ffmpeg(1) man page; the -h full listing only names the option. Separately, the decoder AVOption apply_cropping is a boolean with default true.

<a id="dolbyvision"></a>

#### `-dolbyvision`

**Type:** bool · **Values:** auto, true/false · **Default:** auto · **HDR-relevant** · advanced

Lets the encoder write Dolby Vision RPUs (and configuration) from DV metadata attached to input frames, for example when transcoding a DV source.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `auto (default) when transcoding DV and keeping the same frame timing/geometry` | FFmpeg regenerates RPUs from the decoded DV side data; libx265 sets the x265 DV profile from it. | [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/libx265.c) |

**Notes:** Unverified: how well RPU geometry (L5) and frame-rate changes are handled; for retiming or cropping, edit with dovi_tool instead. HDR10 static metadata passthrough for libx264/libx265/libsvtav1 was added in FFmpeg 7.0 (Changelog).

<a id="strip"></a>

#### `strip` (also `-bsf:v dovi_rpu=strip=1`)

**Type:** bool · **Values:** true/false · **Default:** false · **HDR-relevant** · advanced

Removes all Dolby Vision metadata (configuration record and RPU data) from an HEVC or AV1 stream.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `1 to produce a clean HDR10 copy without dovi_tool` | One-pass alternative to `dovi_tool remove` for single-layer DV. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

<a id="compression"></a>

#### `compression`

**Type:** enum · **Values:** none(0) limited(1) extended(3) · **Default:** limited · **HDR-relevant** · advanced

Recompresses RPU metadata at the chosen level.

**Notes:** Docs: extended is not required on devices and currently acts like limited in libavcodec.

<a id="mode"></a>

#### `mode`

**Type:** enum · **Values:** bl(0) bl_rpu(1) el(2) el_rpu(3) · **Default:** bl · **HDR-relevant** · advanced

Splits profile 7 dual-layer HEVC: base layer only, base plus RPU, enhancement layer only, or EL plus RPU.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bl_rpu, then dovi_tool -m 2 on the result if 8.1 signaling is needed` | bsf keeps the RPU as profile 7; it does not convert the profile. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

**Notes:** New in FFmpeg 9.0.

<a id="sample-aspect-ratio"></a>

#### `sample_aspect_ratio`

**Type:** string · **Values:** rational (table E-1) · **Default:** 0/1 · advanced

Rewrites the VUI sample aspect ratio.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="video-full-range-flag"></a>

#### `video_full_range_flag`

**Type:** int · **Values:** -1 to 1 (0 limited, 1 full) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the VUI full-range flag.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="colour-primaries"></a>

#### `colour_primaries`

**Type:** int · **Values:** -1 to 255 (table E-3 = H.273) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites VUI color primaries without re-encoding.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9` | BT.2020 primaries for HDR10/HLG. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 (table E-4 = H.273) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites VUI transfer characteristics.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `16 (PQ) or 18 (HLG)` | Repairs an HDR stream tagged as BT.709 without re-encoding; the help shows it under 'h265_metadata_bsf'. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 (table E-5 = H.273) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites VUI matrix coefficients.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `9` | BT.2020 non-constant luminance. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="chroma-sample-loc-type"></a>

#### `chroma_sample_loc_type`

**Type:** int · **Values:** -1 to 5 (figure E-1) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the VUI chroma sample location (raw H.273 type, 0 = left).

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="crop-left"></a>

#### `crop_left`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Sets the conformance-window left crop.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="crop-right"></a>

#### `crop_right`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Sets the conformance-window right crop.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="crop-top"></a>

#### `crop_top`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Sets the conformance-window top crop.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="crop-bottom"></a>

#### `crop_bottom`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Sets the conformance-window bottom crop.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="width"></a>

#### `width`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Width after crop (alternative to crop_right).

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="height"></a>

#### `height`

**Type:** int · **Values:** -1 to 16888 · **Default:** -1 · advanced

Height after crop (alternative to crop_bottom).

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="video-format"></a>

#### `video_format`

**Type:** int · **Values:** -1 to 7 (table E-2) · **Default:** -1 · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="video-full-range-flag"></a>

#### `video_full_range_flag`

**Type:** int · **Values:** -1 to 1 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="colour-primaries"></a>

#### `colour_primaries`

**Type:** int · **Values:** -1 to 255 (table E-3) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 (table E-4) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 (table E-5) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="chroma-sample-loc-type"></a>

#### `chroma_sample_loc_type`

**Type:** int · **Values:** -1 to 5 (figure E-1) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching H.264 VUI field without re-encoding.

**Notes:** H.264 HDR is uncommon; same semantics as hevc_metadata.

<a id="color-primaries"></a>

#### `color_primaries`

**Type:** int · **Values:** -1 to 255 (section 6.4.2) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites AV1 sequence-header color primaries.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites AV1 transfer characteristics (16 PQ, 18 HLG).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `16` | Fixes an AV1 HDR10 file mis-tagged as SDR without re-encoding. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites AV1 matrix coefficients.

<a id="color-range"></a>

#### `color_range`

**Type:** enum · **Values:** tv(0) pc(1) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the AV1 color range flag (cannot be set for sRGB/RGB-matrix streams).

<a id="chroma-sample-position"></a>

#### `chroma_sample_position`

**Type:** enum · **Values:** unknown(0) vertical(1, = left) colocated(2, = top-left) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites AV1 chroma sample position (4:2:0 only).

<a id="color-space"></a>

#### `color_space`

**Type:** enum · **Values:** unknown(0) bt601(1) bt709(2) smpte170(3) smpte240(4) bt2020(5) rgb(7) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the VP9 color space field.

**Notes:** VP9 has no transfer field in the bitstream; HDR VP9 relies on container (WebM Colour) metadata.

<a id="color-range"></a>

#### `color_range`

**Type:** enum · **Values:** tv(0) pc(1) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the VP9 range flag (RGB implies full range).

<a id="color-primaries"></a>

#### `color_primaries`

**Type:** enum · **Values:** auto(-1) unknown(0) bt709(1) bt470bg(5) smpte170m(6) bt2020(9) smpte431(11) smpte432(12) · **Default:** auto · **HDR-relevant** · advanced

Rewrites the ProRes frame-header color field.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020` | Tags an HDR ProRes intermediate correctly without re-encoding. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

<a id="color-trc"></a>

#### `color_trc`

**Type:** enum · **Values:** auto(-1) unknown(0) bt709(1) smpte2084(16) arib-std-b67(18) · **Default:** auto · **HDR-relevant** · advanced

Rewrites the ProRes frame-header color field.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `smpte2084 or arib-std-b67` | Tags an HDR ProRes intermediate correctly without re-encoding. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

<a id="colorspace"></a>

#### `colorspace`

**Type:** enum · **Values:** auto(-1) unknown(0) bt709(1) smpte170m(6) bt2020nc(9) · **Default:** auto · **HDR-relevant** · advanced

Rewrites the ProRes frame-header color field.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020nc` | Tags an HDR ProRes intermediate correctly without re-encoding. | [source](https://ffmpeg.org/ffmpeg-bitstream-filters.html) |

<a id="color-primaries"></a>

#### `color_primaries`

**Type:** int · **Values:** -1 to 255 (section 5.3.5) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching APV color field.

**Notes:** APV metadata filter is not covered by the online bsf docs page I read.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching APV color field.

**Notes:** APV metadata filter is not covered by the online bsf docs page I read.

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching APV color field.

**Notes:** APV metadata filter is not covered by the online bsf docs page I read.

<a id="full-range-flag"></a>

#### `full_range_flag`

**Type:** int · **Values:** tv(0) pc(1) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the matching APV color field.

**Notes:** APV metadata filter is not covered by the online bsf docs page I read.

<a id="colour-primaries"></a>

#### `colour_primaries`

**Type:** int · **Values:** -1 to 255 (table 6-7) · **Default:** -1 · advanced

Rewrites the MPEG-2 sequence display extension color field.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 (table 6-8) · **Default:** -1 · advanced

Rewrites the MPEG-2 sequence display extension color field.

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 (table 6-9) · **Default:** -1 · advanced

Rewrites the MPEG-2 sequence display extension color field.

<a id="video-full-range-flag"></a>

#### `video_full_range_flag`

**Type:** bool · **Values:** bool (auto) · **Default:** auto · **HDR-relevant** · advanced

Rewrites the LCEVC enhancement stream's VUI color field.

<a id="colour-primaries"></a>

#### `colour_primaries`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the LCEVC enhancement stream's VUI color field.

<a id="transfer-characteristics"></a>

#### `transfer_characteristics`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the LCEVC enhancement stream's VUI color field.

<a id="matrix-coefficients"></a>

#### `matrix_coefficients`

**Type:** int · **Values:** -1 to 255 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the LCEVC enhancement stream's VUI color field.

<a id="chroma-sample-loc-type"></a>

#### `chroma_sample_loc_type`

**Type:** int · **Values:** -1 to 5 · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the LCEVC enhancement stream's VUI color field.

<a id="all"></a>

#### `all`

**Type:** enum · **Values:** bt470m, bt470bg, bt601-6-525, bt601-6-625, bt709, smpte170m, smpte240m, bt2020 · **Default:** 0 · advanced

Sets output matrix, primaries and transfer together.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="space"></a>

#### `space`

**Type:** enum · **Values:** bt709, fcc, bt470bg, smpte170m, smpte240m, ycgco, gbr, bt2020nc/bt2020ncl · **Default:** 2 · **HDR-relevant** · advanced

Output matrix.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="range"></a>

#### `range`

**Type:** enum · **Values:** tv/mpeg, pc/jpeg · **Default:** 0 · **HDR-relevant** · advanced

Output range.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="primaries"></a>

#### `primaries`

**Type:** enum · **Values:** bt709, bt470m, bt470bg, smpte170m, smpte240m, smpte428, film, smpte431, smpte432, bt2020, jedec-p22/ebu3213, vgamut · **Default:** 2 · **HDR-relevant** · advanced

Output primaries (with gamut conversion).

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="trc"></a>

#### `trc`

**Type:** enum · **Values:** bt709, bt470m/gamma22, bt470bg/gamma28, smpte170m, smpte240m, linear, srgb/iec61966-2-1, xvycc/iec61966-2-4, bt2020-10, bt2020-12, vlog · **Default:** 2 · **HDR-relevant** · advanced

Output transfer. No smpte2084 or arib-std-b67.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `do not use for PQ/HLG` | Its transfer list has no smpte2084 or arib-std-b67, so it cannot convert HDR; use it for SDR gamut/matrix conversions only. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

**Notes:** Input size must be even.

<a id="format"></a>

#### `format`

**Type:** enum · **Values:** yuv420p, yuv420p10, yuv420p12, yuv422p(10/12), yuv444p(10/12) · **Default:** -1 · **HDR-relevant** · advanced

Output pixel format.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="fast"></a>

#### `fast`

**Type:** bool · **Values:** bool · **Default:** false · advanced

Skips gamma and primaries correction (matrix only); faster but mathematically wrong.

**Effect:** quality ± (correct conversion if tags are right) · speed + · size none

**Notes:** Input size must be even.

<a id="dither"></a>

#### `dither`

**Type:** enum · **Values:** none, fsb · **Default:** none · advanced

Floyd-Steinberg dithering when reducing bit depth.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="wpadapt"></a>

#### `wpadapt`

**Type:** enum · **Values:** bradford, vonkries, identity · **Default:** bradford · advanced

White point adaptation method.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="clipgamut"></a>

#### `clipgamut`

**Type:** enum · **Values:** none, rgb · **Default:** none · **HDR-relevant** · advanced

How out-of-gamut values are clipped.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="iall"></a>

#### `iall`

**Type:** enum · **Values:** same as all · **Default:** 0 · advanced

Overrides all input properties.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="ispace"></a>

#### `ispace`

**Type:** enum · **Values:** same as space · **Default:** 2 · **HDR-relevant** · advanced

Overrides input matrix.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="irange"></a>

#### `irange`

**Type:** enum · **Values:** same as range · **Default:** 0 · **HDR-relevant** · advanced

Overrides input range.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="iprimaries"></a>

#### `iprimaries`

**Type:** enum · **Values:** same as primaries · **Default:** 2 · **HDR-relevant** · advanced

Overrides input primaries.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="itrc"></a>

#### `itrc`

**Type:** enum · **Values:** same as trc · **Default:** 2 · **HDR-relevant** · advanced

Overrides input transfer.

**Effect:** quality ± (correct conversion if tags are right) · speed - · size none

**Notes:** Input size must be even.

<a id="in-color-matrix"></a>

#### `in_color_matrix`

**Type:** enum · **Values:** auto, bt601/bt470/smpte170m/bt470bg, bt709, fcc, smpte240m, bt2020/bt2020nc · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output Y'CbCr matrix.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-color-matrix"></a>

#### `out_color_matrix`

**Type:** enum · **Values:** auto, bt601/bt470/smpte170m/bt470bg, bt709, fcc, smpte240m, bt2020/bt2020nc (0-17) · **Default:** 2 (help prints the number; 2 is not one of the named values) · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output Y'CbCr matrix.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `out_color_matrix=bt2020 (and out_range=tv) when scaling HDR` | Otherwise swscale may assume BT.601/709 coefficients when it converts formats, shifting colors. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-range"></a>

#### `in_range`

**Type:** enum · **Values:** auto, unknown, full, limited, jpeg, mpeg, tv, pc (0-2) · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output range.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-range"></a>

#### `out_range`

**Type:** enum · **Values:** auto, unknown, full, limited, jpeg, mpeg, tv, pc (0-2) · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output range.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-chroma-loc"></a>

#### `in_chroma_loc`

**Type:** enum · **Values:** auto, unknown, left, center, topleft, top, bottomleft, bottom · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-chroma-loc"></a>

#### `out_chroma_loc`

**Type:** enum · **Values:** auto, unknown, left, center, topleft, top, bottomleft, bottom · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-primaries"></a>

#### `in_primaries`

**Type:** enum · **Values:** -1 to 22 (auto, bt709 ... jedec-p22/ebu3213) · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output primaries.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-primaries"></a>

#### `out_primaries`

**Type:** enum · **Values:** same as in_primaries · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output primaries.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-transfer"></a>

#### `in_transfer`

**Type:** enum · **Values:** -1 to 18 (auto, bt709 ... smpte2084, smpte428, arib-std-b67) · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output transfer (help text mislabels in_transfer as 'output').

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-transfer"></a>

#### `out_transfer`

**Type:** enum · **Values:** same as in_transfer · **Default:** auto · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output transfer (help text mislabels in_transfer as 'output').

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-v-chr-pos"></a>

#### `in_v_chr_pos`

**Type:** int · **Values:** -513 to 512 (luma grid/256) · **Default:** -513 · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="in-h-chr-pos"></a>

#### `in_h_chr_pos`

**Type:** int · **Values:** -513 to 512 · **Default:** -513 · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-v-chr-pos"></a>

#### `out_v_chr_pos`

**Type:** int · **Values:** -513 to 512 · **Default:** -513 · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="out-h-chr-pos"></a>

#### `out_h_chr_pos`

**Type:** int · **Values:** -513 to 512 · **Default:** -513 · **HDR-relevant** · advanced

libswscale color setting for the scale filter: input/output chroma siting.

**Notes:** Whether this swscale build actually performs PQ/HLG tone or gamut conversion with in/out_transfer and primaries is not verified; treat as tagging/matrix control unless tested.

<a id="range"></a>

#### `range`

**Type:** enum · **Values:** auto, unspecified/unknown, limited/tv/mpeg, full/pc/jpeg · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's range without touching pixel values.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `tv` | Marks untagged HDR frames before encoding so the encoder writes the right VUI and the muxer the right container tags; it relabels, it does not convert. Tested with 9.0.2 + libx265: setparams produced correct VUI and an MP4 colr box where output -color_* options did not. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="color-primaries"></a>

#### `color_primaries`

**Type:** enum · **Values:** auto, bt709, unknown, bt470m, bt470bg, smpte170m, smpte240m, film, bt2020, smpte428, smpte431, smpte432, jedec-p22/ebu3213, vgamut · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's color primaries without touching pixel values.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020` | Marks untagged HDR frames before encoding so the encoder writes the right VUI and the muxer the right container tags; it relabels, it does not convert. Tested with 9.0.2 + libx265: setparams produced correct VUI and an MP4 colr box where output -color_* options did not. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="color-trc"></a>

#### `color_trc`

**Type:** enum · **Values:** auto, bt709, unknown, bt470m, bt470bg, smpte170m, smpte240m, linear, log100, log316, iec61966-2-4, bt1361e, iec61966-2-1, bt2020-10, bt2020-12, smpte2084, smpte428, arib-std-b67, vlog · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's color trc without touching pixel values.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `smpte2084` | Marks untagged HDR frames before encoding so the encoder writes the right VUI and the muxer the right container tags; it relabels, it does not convert. Tested with 9.0.2 + libx265: setparams produced correct VUI and an MP4 colr box where output -color_* options did not. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="colorspace"></a>

#### `colorspace`

**Type:** enum · **Values:** auto, gbr, bt709, unknown, fcc, bt470bg, smpte170m, smpte240m, ycgco, ycgco-re, ycgco-ro, bt2020nc, bt2020c, smpte2085, chroma-derived-nc, chroma-derived-c, ictcp, ipt-c2 · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's colorspace without touching pixel values.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `bt2020nc` | Marks untagged HDR frames before encoding so the encoder writes the right VUI and the muxer the right container tags; it relabels, it does not convert. Tested with 9.0.2 + libx265: setparams produced correct VUI and an MP4 colr box where output -color_* options did not. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="chroma-location"></a>

#### `chroma_location`

**Type:** enum · **Values:** auto, unspecified/unknown, left, center, topleft, top, bottomleft, bottom · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's chroma location without touching pixel values.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `keep source` | Fixes an untagged HDR source before encoding so the encoder writes correct VUI; it marks, it does not convert. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="range"></a>

#### `range`

**Type:** enum · **Values:** auto, unspecified/unknown, limited/tv/mpeg, full/pc/jpeg · **Default:** auto · **HDR-relevant** · advanced

Relabels the frame's range only (no conversion).

<a id="src-dst"></a>

#### `src/dst`

**Type:** enum · **Values:** bt709, fcc, bt601/bt470/bt470bg/smpte170m, smpte240m, bt2020 · **Default:** -1 · advanced

Legacy 8-bit matrix-only conversion between Y'CbCr standards.

**Notes:** Matrix only; no transfer/primaries. colorspace fast=1 gives equivalent output.

<a id="mode"></a>

#### `mode`

**Type:** flags · **Values:** color_range, alpha_mode, all · **Default:** color_range+alpha_mode+all · **HDR-relevant** · advanced

Analyzes frames to detect whether Y'CbCr values actually use full or limited range.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `color_range` | Detects sources whose range tag is wrong before you trust it. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

**Notes:** Option list only verified from help; docs read via the installed ffmpeg-filters man page.

<a id="tonemap"></a>

#### `tonemap`

**Type:** enum · **Values:** none, linear, gamma, clip, reinhard, hable, mobius · **Default:** none · **HDR-relevant** · advanced

Tone-mapping curve.

**Effect:** quality ± (HDR to SDR conversion) · speed - · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `hable or mobius` | hable keeps highlight and shadow detail; mobius keeps in-range colors more accurate. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

**Notes:** Needs linear-light float input. The docs' pipeline uses zscale, which is NOT in this FFmpeg build (no zscale/libplacebo in the help), so practical HDR-to-SDR here needs another route.

<a id="param"></a>

#### `param`

**Type:** float · **Values:** double · **Default:** nan · **HDR-relevant** · advanced

Curve tuning value (meaning depends on the curve).

**Effect:** quality ± (HDR to SDR conversion) · speed - · size none

**Notes:** Needs linear-light float input. The docs' pipeline uses zscale, which is NOT in this FFmpeg build (no zscale/libplacebo in the help), so practical HDR-to-SDR here needs another route.

<a id="desat"></a>

#### `desat`

**Type:** float · **Values:** 0 to DBL_MAX · **Default:** 2 · **HDR-relevant** · advanced

Desaturation strength for overbright colors.

**Effect:** quality ± (HDR to SDR conversion) · speed - · size none

**Notes:** Needs linear-light float input. The docs' pipeline uses zscale, which is NOT in this FFmpeg build (no zscale/libplacebo in the help), so practical HDR-to-SDR here needs another route.

<a id="peak"></a>

#### `peak`

**Type:** float · **Values:** 0 to DBL_MAX · **Default:** 0 · **HDR-relevant** · advanced

Overrides the signal peak (0 = from metadata/auto).

**Effect:** quality ± (HDR to SDR conversion) · speed - · size none

**Notes:** Needs linear-light float input. The docs' pipeline uses zscale, which is NOT in this FFmpeg build (no zscale/libplacebo in the help), so practical HDR-to-SDR here needs another route.

<a id="mode-type"></a>

#### `mode/type`

**Type:** enum · **Values:** mode: select, delete; type: PANSCAN ... MASTERING_DISPLAY_METADATA, CONTENT_LIGHT_LEVEL, ICC_PROFILE, DYNAMIC_HDR_PLUS, DOVI_RPU_BUFFER, DOVI_METADATA, DYNAMIC_HDR_VIVID, AMBIENT_VIEWING_ENVIRONMENT, ... · **Default:** mode select, type -1 · **HDR-relevant** · advanced

Selects frames having, or deletes, a given frame side data type, e.g. to stop DV or HDR10+ being passed to the encoder.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `sidedata=mode=delete:type=DOVI_METADATA (and DOVI_RPU_BUFFER)` | Prevents libx265/libsvtav1 from re-emitting stale DV metadata after a regrade or crop. | [source](https://ffmpeg.org/ffmpeg-filters.html) |

<a id="color-matrix-color-primaries-color-transfer"></a>

#### `color_matrix/color_primaries/color_transfer`

**Type:** string · **Values:** names · **Default:** not stated · **HDR-relevant** · advanced

VideoToolbox scaler output color settings (macOS hardware path).

<a id="par"></a>

#### `par` (also `:par=`)

**Type:** string · **Values:** same as -par · **Default:** not stated · advanced

Sets the pixel aspect ratio on import.

<a id="clap"></a>

#### `clap` (also `:clap=`)

**Type:** string · **Values:** same as -clap · **Default:** not stated · advanced

Sets the clean aperture on import.

<a id="alpha-mode"></a>

#### `-alpha_mode`

**Type:** enum · **Values:** unknown/unspecified(0), premultiplied(1), straight(2) · **Default:** unknown · **HDR-relevant** · advanced

Tags whether alpha is premultiplied or straight.

<a id="mov-gamma"></a>

#### `-mov_gamma`

**Type:** float · **Values:** 0 to 10 · **Default:** 0 · **HDR-relevant** · advanced

Gamma value written to the gama atom (used with -movflags write_gama, MOV only).

<a id="apply-defdispwin"></a>

#### `-apply_defdispwin`

**Type:** bool · **Values:** true/false · **Default:** false · **HDR-relevant** · advanced

Applies the VUI default display window when decoding HEVC.

<a id="strict-displaywin"></a>

#### `-strict-displaywin`

**Type:** bool · **Values:** true/false · **Default:** false · **HDR-relevant** · advanced

Applies the default display window size strictly.

<a id="alpha-mode"></a>

#### `alpha_mode`

**Type:** enum · **Values:** auto, unspecified/unknown, premultiplied, straight · **Default:** auto · **HDR-relevant** · advanced

Relabels the frames' alpha mode.

<a id="color-spaces"></a>

#### `color_spaces`

**Type:** string · **Values:** '\|'-separated color spaces · **Default:** not stated · **HDR-relevant** · advanced

Limits the color spaces the format filter lets through during negotiation.

**Notes:** Same options exist on the noformat filter.

<a id="color-ranges"></a>

#### `color_ranges`

**Type:** string · **Values:** '\|'-separated color ranges · **Default:** not stated · **HDR-relevant** · advanced

Limits the color ranges the format filter lets through during negotiation.

<a id="video-format"></a>

#### `video_format`

**Type:** int · **Values:** -1 to 5 (table E-2) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the LCEVC VUI video format.

<a id="video-format"></a>

#### `video_format`

**Type:** int · **Values:** -1 to 7 (table 6-6) · **Default:** -1 · **HDR-relevant** · advanced

Rewrites the MPEG-2 video format.

### Logging and statistics

<a id="data"></a>

#### `--data` (also `-d`)

**Type:** list · **Values:** all, scenes, level5 as key=output; repeatable or comma-separated · **Default:** not stated · **HDR-relevant** · advanced

Selects what to dump: the whole RPU list as JSON (all), the frame numbers where scene_refresh_flag is set (scenes), or the L5 active area as a ready-to-use editor JSON (level5).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `scenes` | Quick way to confirm the RPU's shot boundaries line up with the encode's scene cuts after retiming. | [source](https://github.com/quietvoid/dovi_tool) |

<a id="levels-format"></a>

#### `--levels-format` (also `-f`)

**Type:** enum · **Values:** csv, json · **Default:** csv · **HDR-relevant** · advanced

File format used for --levels exports.

<a id="levels"></a>

#### `--levels` (also `-l`)

**Type:** list · **Values:** level1, level2, level3, level4, level5, level6, level8, level9, level10, level11 as key=output · **Default:** not stated · **HDR-relevant** · advanced

Writes the chosen metadata levels (for example L1 per-frame min/avg/max) to files for analysis.

<a id="frame"></a>

#### `--frame` (also `-f`)

**Type:** int · **Values:** 0-based frame index · **Default:** not stated · **HDR-relevant** · advanced

Prints one frame's RPU as JSON.

**Notes:** README: frame indices start at 0.

<a id="summary"></a>

#### `--summary` (also `-s`)

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant**

Prints a summary: frame count, profile, CM version, scene count, levels present.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `run after every edit/inject` | Cheapest check that profile and frame count are what you expect. | [source](https://github.com/quietvoid/dovi_tool) |

**In Lumora:** DolbyVisionRetimer parses the first integer greater than 1 in `info -i rpu -s` output as the frame count (somewhat fragile if the summary layout changes).

<a id="title"></a>

#### `--title` (also `-t`)

**Type:** string · **Values:** text · **Default:** not stated · advanced

Chart title.

<a id="start"></a>

#### `--start` (also `-s`)

**Type:** int · **Values:** frame · **Default:** not stated · advanced

First frame to plot.

<a id="end"></a>

#### `--end` (also `-e`)

**Type:** int · **Values:** frame (inclusive) · **Default:** not stated · advanced

Last frame to plot.

<a id="plot-type"></a>

#### `--plot-type` (also `-p`)

**Type:** enum · **Values:** l1, l2, l8, l8-saturation, l8-hue · **Default:** l1 · **HDR-relevant** · advanced

Which metadata level to graph; L8 types need CM v4.0 RPUs.

<a id="target-nits"></a>

#### `--target-nits`

**Type:** enum · **Values:** 100, 300, 600, 1000, 2000, 4000 · **Default:** 100 · **HDR-relevant** · advanced

Target display level used for L2/L8 trim plots.

<a id="trims"></a>

#### `--trims`

**Type:** list · **Values:** slope, offset, power, chroma, saturation, ms, mid, clip · **Default:** all included · **HDR-relevant** · advanced

Limits L2/L8 plots to the named trim parameters.

<a id="verify"></a>

#### `--verify`

**Type:** bool · **Values:** flag · **Default:** off · **HDR-relevant**

Only checks whether the input holds HDR10+ dynamic metadata and reports it; no effect on inject or remove.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `hdr10plus_tool --verify extract file.hevc` | Fast yes/no check after injection or before relying on a source's HDR10+. | [source](https://github.com/quietvoid/hdr10plus_tool) |

<a id="title"></a>

#### `--title` (also `-t`)

**Type:** string · **Values:** text · **Default:** not stated · advanced

Chart title.

<a id="peak-source"></a>

#### `--peak-source` (also `-p`)

**Type:** enum · **Values:** histogram, histogram99, max-scl, max-scl-luminance · **Default:** histogram · **HDR-relevant** · advanced

Which field is plotted as the frame peak.

<a id="start"></a>

#### `--start` (also `-s`)

**Type:** int · **Values:** frame · **Default:** not stated · advanced

First frame to plot.

<a id="end"></a>

#### `--end` (also `-e`)

**Type:** int · **Values:** frame (inclusive) · **Default:** not stated · advanced

Last frame to plot.

<a id="info"></a>

#### `-info` (also `-infon`, `-infox`)

**Type:** string · **Values:** none (movie) or track ID; -infon takes a track number; -infox prints all tracks · **Default:** not stated · **HDR-relevant**

Prints movie or track information, including codec string, DV configuration and color/HDR boxes.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `MP4Box -infox out.mp4` | Quick check that the DV configuration and hvc1/dvh1 entry made it into the file; for colr, mdcv and clli dump the boxes with MP4Box -diso. | [source](https://wiki.gpac.io/MP4Box/mp4box-gen-opts/) |

**Notes:** Not in the captured help file (it covers general and import options); listed by `MP4Box -h dump` and confirmed by running MP4Box -infox with GPAC 26.07, which prints the DV configuration. It does not print colr/mdcv/clli; use MP4Box -diso (box dump) for those.

<a id="identify"></a>

#### `--identify` (also `-i`)

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Prints what mkvmerge detects in a file.

<a id="j"></a>

#### `-J`

**Type:** path · **Values:** file · **Default:** not stated · **HDR-relevant**

Shorthand for --identification-format json --identify; since v68 the JSON includes color, mastering and projection properties.

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `mkvmerge -J out.mkv` | Machine-readable check of color/mastering fields and DV block-addition mappings after muxing. | [source](https://mkvtoolnix.download/doc/NEWS.md) |

**Notes:** Tested with v103: for an MKV the JSON lists color_* and mastering fields; for an MP4 input only the colr values; for a raw HEVC elementary stream none.

<a id="identification-format"></a>

#### `--identification-format` (also `-F`)

**Type:** enum · **Values:** text, json · **Default:** text · advanced

Output format for --identify.

<a id="export-side-data"></a>

#### `-export_side_data`

**Type:** flags · **Values:** mvs, prft, venc_params, film_grain, enhancements · **Default:** 0 · advanced

Asks decoders/encoders to attach extra data (motion vectors, film grain parameters, encoder params, enhancement layers) to frames or packets.

**In Lumora:** Metrics uses `-export_side_data film_grain` so AV1 synthetic grain is exported rather than applied when scoring.

**Notes:** Mastering display, content light, HDR10+ and DV RPU side data are exported by default; they are not in this flag list.

<a id="stats"></a>

#### `stats` (also `:stats`, `:fstat`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Prints filter session statistics after import.

<a id="graph"></a>

#### `graph` (also `:graph`, `:fgraph`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Prints the filter session graph after import.

<a id="verbose"></a>

#### `--verbose` (also `-v`)

**Type:** bool · **Values:** flag · **Default:** off

Prints more detail.

<a id="quiet"></a>

#### `--quiet` (also `-q`)

**Type:** bool · **Values:** flag · **Default:** off

Suppresses status output.

<a id="list-types"></a>

#### `--list-types` (also `-l`)

**Type:** bool · **Values:** flag · **Default:** off

Lists supported source file types.

<a id="list-audio-emphasis"></a>

#### `--list-audio-emphasis`

**Type:** bool · **Values:** flag · **Default:** off

Lists values for --audio-emphasis.

<a id="list-languages"></a>

#### `--list-languages`

**Type:** bool · **Values:** flag · **Default:** off

Lists ISO 639 languages and codes.

<a id="list-stereo-modes"></a>

#### `--list-stereo-modes`

**Type:** bool · **Values:** flag · **Default:** off

Lists values for --stereo-mode.

<a id="capabilities"></a>

#### `--capabilities`

**Type:** bool · **Values:** flag · **Default:** off

Lists optional features compiled in.

<a id="redirect-output"></a>

#### `--redirect-output` (also `-r`)

**Type:** path · **Values:** file · **Default:** not stated

Writes all messages to a file.

<a id="debug"></a>

#### `--debug`

**Type:** string · **Values:** topic · **Default:** not stated · advanced

Turns on debug output for a topic.

### Other

<a id="help"></a>

#### `--help` (also `-h`)

**Type:** bool · **Values:** flag · **Default:** not stated

Prints help; -h gives the short form and --help the long form. Accepted by the tool and by every subcommand.

<a id="version"></a>

#### `--version` (also `-V`)

**Type:** bool · **Values:** flag · **Default:** not stated

Prints the tool version.

**In Lumora:** Packager runs `dovi_tool --version` to record the tool version in its report.

<a id="no-add-aud"></a>

#### `--no-add-aud`

**Type:** bool · **Values:** flag · **Default:** off (AUDs are added) · advanced

Stops the tool from inserting access unit delimiters between frames.

**Notes:** Leave AUDs on unless a downstream tool objects; they help some demuxers find frame boundaries.

<a id="no-add-aud"></a>

#### `--no-add-aud`

**Type:** bool · **Values:** flag · **Default:** off (AUDs are added) · advanced

Do not insert access unit delimiters between frames.

<a id="remove-eos"></a>

#### `--remove-eos`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Strips end-of-sequence/end-of-bitstream NAL units from both layers.

<a id="eos-before-el"></a>

#### `--eos-before-el`

**Type:** bool · **Values:** flag · **Default:** on (deprecated flag) · advanced

Deprecated; the behavior is always on now.

**Notes:** Help: 'Deprecated, enabled by default'. Safe to omit.

<a id="help"></a>

#### `--help` (also `-h`)

**Type:** bool · **Values:** flag · **Default:** not stated

Prints help for the tool or a subcommand.

<a id="version"></a>

#### `--version` (also `-V`)

**Type:** bool · **Values:** flag · **Default:** not stated

Prints the tool version.

<a id="au-delim"></a>

#### `au_delim` (also `:au_delim`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Keeps access unit delimiter NAL units in the imported samples.

<a id="novpsext"></a>

#### `novpsext` (also `:novpsext`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Removes VPS extensions from HEVC.

<a id="forcesync"></a>

#### `forcesync` (also `:forcesync`)

**Type:** bool · **Values:** flag · **Default:** off · advanced

Marks non-IDR I-frames (open GOP/GDR) as sync points; help warns the result is not spec compliant.

<a id="fix-bitstream-timing-information"></a>

#### `--fix-bitstream-timing-information`

**Type:** bool · **Values:** TID[:bool] · **Default:** off · advanced

Rewrites frame-rate info inside the bitstream to match the container.

**Notes:** The mkvmerge docs say this is only implemented for AVC/H.264, so it does nothing for HEVC.

<a id="engage"></a>

#### `--engage`

**Type:** string · **Values:** feature (see --engage list) · **Default:** not stated · advanced

Turns on experimental features; not for normal use.

<a id="deterministic"></a>

#### `--deterministic`

**Type:** string · **Values:** seed · **Default:** not stated · advanced

Produces byte-identical output for identical inputs, options and seed.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `a fixed seed` | Makes re-muxes reproducible so checksums can be compared. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="abort-on-warnings"></a>

#### `--abort-on-warnings`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Stops at the first warning.

| For | Value | Why | Source |
|---|---|---|---|
| archive | `set in automated pipelines` | Turns silent problems (timing, missing headers) into hard failures. | [source](https://mkvtoolnix.download/doc/mkvmerge.html) |

<a id="strict"></a>

#### `-strict`

**Type:** enum · **Values:** very(2) strict(1) normal(0) unofficial(-1) experimental(-2) · **Default:** normal · **HDR-relevant** · advanced

How strictly to follow specs. For MP4/MOV output, 'unofficial' is required for FFmpeg to write the dvcC/dvvC Dolby Vision box (and hvcE).

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `-strict unofficial when stream-copying DV into MP4` | Without it the muxer warns and drops dvcC, so the file plays as plain HDR10. | [source](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c) |

**In Lumora:** Lumora uses `-strict -1` only for 10-bit yuv4mpegpipe output; its ffmpeg fallback remux to MP4 does not pass it, so DV would lose dvcC there (MP4Box is preferred when installed).

<a id="aud"></a>

#### `aud`

**Type:** enum · **Values:** pass(0) insert(1) remove(2) · **Default:** pass · advanced

Inserts or removes access unit delimiters.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="video-format"></a>

#### `video_format`

**Type:** int · **Values:** -1 to 7 (table E-2) · **Default:** -1 · advanced

Rewrites VUI video_format.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="tick-rate"></a>

#### `tick_rate`

**Type:** string · **Values:** rational · **Default:** 0/1 · advanced

Sets VPS/VUI timing tick rate (containers usually override it).

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="num-ticks-poc-diff-one"></a>

#### `num_ticks_poc_diff_one`

**Type:** int · **Values:** -1 to INT_MAX · **Default:** -1 · advanced

Sets VPS/VUI ticks per POC step.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="level"></a>

#### `level`

**Type:** enum · **Values:** auto, 1 ... 6.2, 8.5 (or level_idc) · **Default:** -2 (unchanged) · advanced

Rewrites the VPS/SPS level.

**Notes:** Bitstream filter name is hevc_metadata (help section is titled h265_metadata_bsf). Changes header fields only, never pixels. HDR10 SEI (mastering/CLL) cannot be added with this filter.

<a id="tick-rate"></a>

#### `tick_rate`

**Type:** string · **Values:** rational · **Default:** 0/1 · advanced

Sets display tick rate in the timing info.

<a id="num-ticks-per-picture"></a>

#### `num_ticks_per_picture`

**Type:** int · **Values:** -1 to INT_MAX · **Default:** -1 · advanced

Ticks per picture for CFR (needs tick_rate).

<a id="td"></a>

#### `td`

**Type:** enum · **Values:** pass(0) insert(1) remove(2) · **Default:** pass · advanced

Inserts or removes temporal delimiter OBUs.

<a id="delete-padding"></a>

#### `delete_padding`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Removes padding OBUs.

<a id="aud"></a>

#### `aud`

**Type:** enum · **Values:** pass(0) insert(1) remove(2) · **Default:** pass · advanced

Inserts or removes AUDs in VVC; the only option (no color fields).

**Notes:** Help section is titled h266_metadata_bsf; there is no VVC color-rewrite bsf in this build.

<a id="p"></a>

#### `-p`

**Type:** string · **Values:** profile name, file path, or 0 · **Default:** not stated · advanced

Picks a GPAC configuration profile (created if missing); a path loads one from a file and 0 means a temporary profile that is not saved.

<a id="sopt"></a>

#### `sopt` (also `:sopt:`)

**Type:** string · **Values:** filter arguments · **Default:** not stated · advanced

Passes extra arguments to the source filter; must come after all other per-file options.

<a id="dopt"></a>

#### `dopt` (also `:dopt:`)

**Type:** string · **Values:** filter arguments · **Default:** not stated · advanced

Passes extra arguments to the destination filter; must come after all other per-file options.

<a id="f1-args-fn-args"></a>

#### `@f1[:args][@fN:args]`

**Type:** string · **Values:** filter chain (@@ starts a new chain) · **Default:** not stated · advanced

Inserts a filter chain before the multiplexer; must come after all other per-file options.

<a id="probe-range-percentage"></a>

#### `--probe-range-percentage`

**Type:** float · **Values:** percent · **Default:** 0.3 · advanced

Maximum share of the file size probed for tracks in some file types.

<a id="priority"></a>

#### `--priority`

**Type:** string · **Values:** priority · **Default:** not stated · advanced

Process priority.

<a id="ui-language"></a>

#### `--ui-language`

**Type:** string · **Values:** code · **Default:** not stated · advanced

Forces the UI translation.

<a id="command-line-charset"></a>

#### `--command-line-charset`

**Type:** string · **Values:** charset · **Default:** not stated · advanced

Charset of strings on the command line.

<a id="output-charset"></a>

#### `--output-charset`

**Type:** string · **Values:** charset · **Default:** not stated · advanced

Charset of output messages.

<a id="no-bom"></a>

#### `--no-bom`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Does not write byte order marks to text files.

<a id="flush-on-close"></a>

#### `--flush-on-close`

**Type:** bool · **Values:** flag · **Default:** off · advanced

Flushes cached data to storage when closing output files.

<a id="option-file-json"></a>

#### `@option-file.json`

**Type:** path · **Values:** JSON file · **Default:** not stated · advanced

Reads more command-line options from a JSON file (see the man page).

<a id="help"></a>

#### `--help` (also `-h`)

**Type:** bool · **Values:** flag · **Default:** off

Shows help.

<a id="version"></a>

#### `--version` (also `-V`)

**Type:** bool · **Values:** flag · **Default:** off

Shows version information.

<a id="sei-user-data"></a>

#### `sei_user_data`

**Type:** string · **Values:** UUID+string · **Default:** not stated · advanced

Inserts a user-data-unregistered SEI message.

<a id="pass-types"></a>

#### `pass_types`

**Type:** string · **Values:** list of unit types · **Default:** not stated · advanced

Passes only the listed NAL/OBU unit types.

<a id="remove-types"></a>

#### `remove_types`

**Type:** string · **Values:** list of unit types · **Default:** not stated · advanced

Removes the listed NAL/OBU unit types.

**Notes:** Unverified for this build: with HEVC, remove_types=62|63 is the usual way to drop DV RPU/EL NAL units; dovi_rpu=strip=1 is the documented route.

<a id="discard"></a>

#### `discard`

**Type:** enum · **Values:** none(-16), default(0), nonref(8), bidir(16), nonintra(24), nonkey(32), all(48) · **Default:** none · advanced

Drops whole frames of the selected kind.

<a id="discard-flags"></a>

#### `discard_flags`

**Type:** flags · **Values:** keep_non_vcl · **Default:** 0 · advanced

Keeps non-VCL units of dropped pictures.

## Sources

- [dovi_tool README](https://github.com/quietvoid/dovi_tool)
- [dovi_tool editor documentation](https://github.com/quietvoid/dovi_tool/blob/main/docs/editor.md)
- [hdr10plus_tool README](https://github.com/quietvoid/hdr10plus_tool)
- [GPAC wiki: MP4Box import options](https://wiki.gpac.io/MP4Box/mp4box-import-opts/)
- [GPAC wiki: MP4Box general options](https://wiki.gpac.io/MP4Box/mp4box-gen-opts/)
- [GPAC source: applications/mp4box/fileimport.c (HDR XML parser)](https://github.com/gpac/gpac/blob/master/applications/mp4box/fileimport.c)
- [mkvmerge documentation](https://mkvtoolnix.download/doc/mkvmerge.html)
- [MKVToolNix NEWS (Dolby Vision and color history)](https://mkvtoolnix.download/doc/NEWS.md)
- [ffmpeg tool documentation](https://ffmpeg.org/ffmpeg.html)
- [FFmpeg codecs documentation](https://ffmpeg.org/ffmpeg-codecs.html)
- [FFmpeg bitstream filters documentation](https://ffmpeg.org/ffmpeg-bitstream-filters.html)
- [FFmpeg filters documentation (read via the installed ffmpeg-filters man page)](https://ffmpeg.org/ffmpeg-filters.html)
- [FFmpeg Changelog](https://github.com/FFmpeg/FFmpeg/blob/master/Changelog)
- [FFmpeg libavutil/pixfmt.h color enums](https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/pixfmt.h)
- [FFmpeg libavformat/movenc.c (colr/mdcv/clli/dvcC writing rules)](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c)
- [FFmpeg libavcodec/libx265.c (HDR10 and DV side data handling)](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/libx265.c)
- [x265 CLI documentation (master-display, max-cll, Dolby Vision)](https://x265.readthedocs.io/en/master/cli.html)
- [Apple HLS Authoring Specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)
- [Emby: Dolby Vision Profile 8](https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html)
- [dvmkv2mp4 script (community DV workflow)](https://github.com/gacopl/dvmkv2mp4)
- [Wikipedia: Coding-independent code points](https://en.wikipedia.org/wiki/Coding-independent_code_points)
- [ITU-T H.273 (referenced standard; not fetched, tables cross-checked with FFmpeg and GPAC)](https://www.itu.int/rec/T-REC-H.273)

{% endraw %}
