---
title: Encoding settings
nav_order: 6
has_children: true
---
{% raw %}
# Choosing encoder settings

> **The reference:** every option of every encoder Lumora drives, checked against the installed tools' own help:
> [SVT-AV1](svtav1.md) · [x265](x265.md) · [VVenC](vvenc.md) · [libaom](aomenc.md) · [AVM (AV2)](avm.md) ·
> [VideoToolbox](videotoolbox.md) · [HDR metadata tools](hdrtools.md). Machine-readable data is in
> [`data/`](https://github.com/info-moed/Lumora/tree/main/docs/encoding/data);
> `python3 scripts/encoding_reference.py check` compares it with the encoders you have installed.


A cross-encoder guide for SVT-AV1, x265, VVenC, libaom (aomenc), AVM (AV2) and Apple VideoToolbox, plus the HDR metadata tools around them (dovi_tool, hdr10plus_tool, MP4Box, mkvmerge, FFmpeg).

**Versions this guide was written against:** SVT-AV1 v4.3.0, x265 4.3+1, VVenC (vvencapp) 1.14.0, aomenc 3.15.3, AVM v1.0.0 (installed and checked as GitLab tag research-v15.0.0), FFmpeg 9.0.2, dovi_tool 2.3.4, hdr10plus_tool 1.7.2, MP4Box (GPAC 26.07), mkvmerge v103.0. Encoder options and defaults change between releases, and many published guides describe forks or older versions. Check `--help` on your own build before trusting any flag here.

**How to read the citations.** Each claim links to the source it came from. Links are reference-style, for example [svt-faq], and the full list is at the end. Statements about Lumora's own behavior cite the Lumora file they come from (paths are relative to the repository root). Where the sources disagree, both views are given. Where a statement is my inference rather than something a source states, it says so.

**Starting values are only starting values.** CRF, QP and cq-level numbers below are places to begin a search, not targets. Pick the final value by eye or with a metric on your own footage ([svt-faq], [cw-x265]). Where a source gives no number for a content type (most VVenC rows, and x265 for CGI), the starting value is my inference from the encoder's documented useful range, for example VVenC's QP 21-47 ([vvenc-usage]).

Contents

1. [Quick chooser](#1-quick-chooser)
2. [By content type](#2-by-content-type)
3. [HDR done right](#3-hdr-done-right)
4. [Speed vs efficiency ladders](#4-speed-vs-efficiency-ladders)
5. [Myths and pitfalls](#5-myths-and-pitfalls)
6. [Appendix: where Lumora's current settings differ from this guide](#appendix-where-lumoras-current-settings-differ-from-this-guide)
7. [Sources](#sources)

---

## 1. Quick chooser

Pick the row that matches what the file is for. "Key flags" lists only what differs from the encoder's defaults or is easy to get wrong.

| Goal | Codec / encoder | Preset or speed | Rate control | Key flags | Why |
|---|---|---|---|---|---|
| **Watch on a TV** (SDR) | HEVC Main10, x265 | `slow` | CRF, start near 18-20 | `--output-depth 10 --profile main10`, explicit `--colorprim/--transfer/--colormatrix`, mux as `hvc1` in MP4 or as MKV | HEVC Main10 is the format Apple's HDR and streaming rules are built around ([apple-hls], [tn3145]); that it is the safest TV choice of these codecs is my inference. `slow` is the common quality-for-time balance ([x265-presets], [koko]). Apple asks for `hvc1` rather than `hev1` in MP4 ([apple-hls]). |
| **Archive** (keep for years, smallest at near-transparent quality) | AV1, SVT-AV1 | `--preset 4` (or `2` when time does not matter) | CRF, start near 28-30 | `--input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0 --tf-strength 1 --keyint 10s --irefresh-type 2` | Preset 4 is the community balance point and preset 2 gets close to preset 1 at about half its time ([cw-svt-p1]). Variance boost, quantization matrices and a weaker temporal filter each tested positive ([cw-svt-p2], [cw-svt]). 5-10 s closed GOPs suit home playback ([svt-faq], [cw-svt]). |
| **Archive, HEVC, 12-bit** | HEVC Main12, x265 | `slower` | CRF, start near 16 | `--output-depth 12 --profile main12 --no-sao --deblock -2:-2 --no-strong-intra-smoothing --ref 6 --rc-lookahead 60 --bframes 8` | Low CRF with SAO off and gentler deblocking keeps fine texture ([jet], [cw-x265]). Main12 decoders are rare, so keep a 10-bit copy for playback ([x265-cli], [cw-x265]). |
| **Smallest file** (time no object) | VVC, VVenC | `--preset slow` (`slower` adds about 3 points) | QP with perceptual QPA (default), start near 24-30 | `-q <QP>`; leave `--qpa` on | `slow` saves about 39% over the HM reference, `slower` about 42% at roughly 4-5x the time ([vvenc-perf]). Raw `.266` needs FFmpeg 7+ to mux into MP4 ([cw-vvenc]); expect few players to handle VVC (inference). If you need AV1 instead: SVT-AV1 `--preset 2` ([cw-svt-p1]). |
| **Share anywhere** (upload, message, stream) | HEVC, VideoToolbox (hardware) or x265 | VideoToolbox: no presets; x265: `slow` | Bitrate with a peak cap | VideoToolbox via FFmpeg: `-b:v 12M -maxrate 18M -g 48 -bf 2 -tag:v hvc1` and tag frames with `setparams`; x265: two-pass `--bitrate` with `--vbv-maxrate/--vbv-bufsize` | A capped rate gives a predictable size and peak ([vt-avgbr], [vt-dlimits], [x265-cli]). VideoToolbox is very fast but needs noticeably more bits than x265 for the same result ([yre]). H.264 is not covered by these references. |
| **Editing master** (intermediate for an NLE) | ProRes 422 HQ, VideoToolbox | `-prio_speed 0` | None (ProRes profiles are fixed-rate) | `-c:v prores_videotoolbox -profile:v hq -pix_fmt p210le`; for 12-bit 4:4:4 use `-profile:v xq -pix_fmt p416le` | 422 HQ is widely adopted in post and stays visually lossless over many generations; about 220 Mb/s at 1080p29.97 and 884 Mb/s at 2160p30 ([prores-pdf]). ProRes hardware defaults to speed, so ask for quality explicitly ([vt-prio]). |
| **HDR10** | HEVC Main10, x265 (or SVT-AV1 / VVenC, see section 3) | `slow` | CRF, start near 18-20 | `--output-depth 10 --profile main10 --range limited --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --master-display "<from source>" --max-cll "<from source>" --hdr10 --hdr10-opt` | Full PQ signaling plus ST 2086 and light-level SEI, and PQ-aware QP from `--hdr10-opt` at 10-bit ([x265-cli]). The HDR article used CRF 20 and its readers reported 16-24 ([codecalamity]). |
| **HLG** | HEVC Main10, x265 | `slow` | CRF, start near 18 | `--output-depth 10 --profile main10 --video-signal-type-preset BT2100_HLG_YCC` | One preset sets BT.2020 primaries, HLG transfer, BT.2020 matrix, limited range and chroma location; HLG needs no mastering metadata ([x265-cli]). |
| **Dolby Vision** (profile 8.1, HDR10-compatible base) | HEVC Main10, x265 + dovi_tool | `slow` | Capped CRF (VBV is mandatory) | `dovi_tool -m 2 extract-rpu`, then x265 `--dolby-vision-profile 8.1 --dolby-vision-rpu RPU.bin --vbv-bufsize N --vbv-maxrate N --master-display ...`; mux with `MP4Box ...:dvp=8.1` | dovi_tool mode 2 rewrites the RPU for profile 8.1 ([dovi]). x265 refuses Dolby Vision without VBV, refuses 8.1 without `--master-display`, and allows it only at 10-bit (profile options: [x265-cli]; the refusals were checked on the installed 4.3+1 build). MP4Box `dvp` writes the Dolby Vision configuration box ([gpac-import]). |
| **Dolby Vision 8.4** (from HLG, iPhone style) | HEVC Main10, AVAssetWriter / VideoToolbox | n/a | Constant quality | HLG color properties, `kVTProfileLevel_HEVC_Main10_AutoLevel`, `kVTHDRMetadataInsertionMode_Auto`, 10-bit buffers that carry the ambient viewing environment | Apple's guide gives this combination, and TN3145 requires the `amve` box ([apple-dv-pdf], [tn3145]). FFmpeg cannot do this path. |

---

## 2. By content type

These are the eight content kinds Lumora's profiler uses (`Lumora/Core/Analysis/ContentProfiler.swift`, `ContentTuning`). For each kind the table gives starting settings for SVT-AV1, x265 and VVenC side by side, followed by the reasons and sources.

A general note on VVenC: vvencapp has **no content tunes** ([vvenc]). Its perceptual QP adaptation (QPA, on by default) does the per-block adaptation that you tune by hand in the other two, so the VVenC column changes much less between rows ([vvenc], [vvenc-usage]).

### Live action (normal camera footage)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` (archive: `slower`/`veryslow`) | `--preset medium` (archive: `slow`) |
| Quality | `--crf 30` | `--crf 18` (1080p, near transparent: 16) | `-q 30` (archive: 21-27) |
| Flags | `--input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0 --tf-strength 1 --irefresh-type 2 --keyint 10s` | `--output-depth 10 --aq-mode 3 --psy-rd 2.0 --psy-rdoq 1.0 --deblock -2:-2 --no-sao` (at low CRF) | `--sdr sdr_709` |

- **SVT-AV1.** Preset 4 is the usual balance and presets 4-6 are the project's suggested home range ([svt-faq], [cw-svt-p1]). Variance boost beat no boost on nearly every clip and metric except VMAF ([cw-svt-p2]). Codec Wiki recommends quantization matrices and a `--qm-min` of 0 ([cw-svt]). A temporal-filter strength of 1 or lower removes keyframe smoothing problems ([cw-svt-p2]). Closed GOPs are advised because open-GOP support is incomplete ([cw-svt]). On tune: the v3.0 metric study found the default tune 1 best overall, while the Codec Wiki encoder page calls tune 0 the safe psychovisual choice and the FAQ says tune 0 often looks sharper ([cw-svt-p2], [cw-svt], [svt-faq]). The sources disagree, so test both.
- **x265.** The JET guide finds `--no-sao` usually best and SAO heavy on blur; Codec Wiki ties SAO to CRF (keep it at CRF 20 and above, drop it below 16) ([jet], [cw-x265]). Deblock offsets of -3:-3 to -1:-1 are the live-action range ([jet]). psy-rd 0.8-2.0 and psy-rdoq 0-2 are the working ranges ([jet]). AQ mode 3 or 4 is usually best per the JET guide, while Codec Wiki keeps the default 2 because 3 can bloat bitrate ([jet], [cw-x265]). The CRF tiers (14/16/18 for 720p/1080p/4K) come from Codec Wiki ([cw-x265]).
- **VVenC.** `medium` is the project's recommended trade-off and `slow` is the efficient archival choice ([vvenc-perf]). QPA is designed for subjective quality and is on by default ([vvenc]). Explicit BT.709 signaling keeps players from guessing ([vvenc-usage]). The useful QP range is about 21-47 ([vvenc-usage]).

### Heavy grain (film or high-ISO noise)

Two strategies exist for every encoder: **synthesize** the grain (remove it, describe it, let the player add it back: small files) or **keep** the real grain (more bits, more authentic).

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Synthesize | `--preset 4 --crf 30 --film-grain 12 --film-grain-denoise 1 --adaptive-film-grain 1` | Not practical (see below) | `--fga 1` (experimental) |
| Keep | `--preset 4 --crf 26 --ac-bias 4.0 --enable-tf 0 --enable-cdef 0 --enable-variance-boost 1` | `--preset slow --crf 18 --output-depth 10 --tune grain`, or by hand: `--psy-rdoq 2-3 --no-sao --deblock -2:-2 --no-strong-intra-smoothing` | `--preset slow -q 24-27` |

- **SVT-AV1.** Noisier sources take film-grain levels of 10-15 ([svt-faq]). Denoising the coded picture is where the large savings come from ([svt-faq]), but Codec Wiki prefers `--film-grain-denoise 0` in most cases because denoising always removes some fine detail ([cw-svt]). The FAQ adds that leaving denoise off can give higher fidelity if you verify the level, since too high a level stacks synthetic noise on top of the real noise ([svt-faq]). Adaptive film grain often greatly improves grain consistency ([svt-params]). To keep the real grain, the psychovisual appendix names AC bias 4.0-6.0 with TF and CDEF off ([svt-params]). Keep `--qm-min` at its default instead of 0 on extremely heavy grain ([cw-svt]). Above preset 6, SVT-AV1 v4.3.0 prints a warning that film grain adds significant compute overhead ([svt-settings]).
- **x265.** `--tune grain` flattens the QP ratios, enables `rc-grain`, turns off AQ, cutree and SAO, and raises psy-rd to 4 and psy-rdoq to 10 so grain neither smears nor pulses ([x265-presets]). The anime guide finds the grain tune too strong on slower presets and prefers setting psy values by hand ([koko]). `--no-strong-intra-smoothing` suits sharp or grainy sources ([jet]). x265 can write a film-grain SEI from a model file you supply, but it does not estimate or remove grain itself ([x265-cli]); few HEVC players apply that SEI (unverified by the sources).
- **VVenC.** `--fga 1` analyzes the grain and writes a film-grain characteristics SEI; it is experimental since v1.13.0, describes the grain without removing it, and needs MCTF and an intra period of at least 2 ([vvenc-changelog]). Few VVC decoders apply that SEI, so its playback effect is uncertain ([vvenc-changelog]). For reliably kept grain, spend bits with a lower QP (inference from the QP range in [vvenc-usage]).

### Anime (modern digital, flat color, clean lines)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` | `--preset medium` or `slow` |
| Quality | `--crf 32` | `--crf 19` (18-21 by viewing setup) | `-q 30-32` |
| Flags | `--input-depth 10 --film-grain 4 --enable-variance-boost 1 --variance-boost-strength 1 --enable-qm 1 --qm-min 0 --sharpness 1` | `--output-depth 10 --profile main10 --aq-mode 3 --bframes 8 --psy-rd 1 --limit-sao` (near CRF 18) | defaults; 10-bit internal |

- **SVT-AV1.** Animation looks good at higher CRF than live action, and about film-grain level 4 suits hand-drawn work ([svt-faq]). Variance-boost strength 1 is meant for smooth, untextured animation ([svt-vb]). Quantization matrices helped the anime test set, and sharpness +1 to +2 helped the animated clip in the v3.0 study ([cw-svt-anim], [cw-svt-p2]). The animation deep dive found turning TF off can help slightly at high quality but is clip dependent ([cw-svt-anim]). On tune, it found 1 and 2 equal at high quality and 2 ahead at low quality ([cw-svt-anim]). Going from preset 4 to preset 0 cost 5-10x the time for about 1.5 SSIMULACRA2 points ([cw-svt-anim]).
- **x265.** The anime guide calls AQ mode 3 a must against banding in dark scenes, recommends `slow` and advises against `fast` ([koko]). 8 B-frames saved about 3-5% over 4 for little time; 16 was not worth it ([koko]). It ties SAO to CRF: on at 20 and above, `--limit-sao` near 18, off at 16 and below ([koko]). It found 10-bit better than 12-bit at typical anime CRFs ([koko]). `--tune animation` exists but is missing from the help list; it sets psy-rd and aq-strength to 0.4 and deblock 1:1 ([x265-presets]). Note that this psy-rd differs from the anime guide's 1.0 ([koko]).
- **VVenC.** No anime-specific tools are exposed in vvencapp ([vvenc]). Keep the default 10-bit internal depth; HDR modes require it and the AV2 test conditions also code 8-bit animation at 10-bit ([vvenc-cfg], [avm-ctc]).

### Old anime (cel or early-digital, film grain, soft lines)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` | `--preset slow` |
| Quality | `--crf 30` | `--crf 18-20` | `-q 26-30` |
| Flags | `--input-depth 10 --film-grain 10 --film-grain-denoise 0 --enable-variance-boost 1 --variance-boost-strength 2 --enable-tf 0` | `--output-depth 10 --aq-mode 3 --psy-rd 1.5 --psy-rdoq 2-3 --deblock -1:-1`; keep strong intra smoothing on for soft sources | defaults; optional `--fga 1` |

- **SVT-AV1.** Grainy, film-era animation can use grain levels up to about 10 ([svt-faq]). Turning TF off keeps more of the source grain, but the animation deep dive found TF-off results clip dependent, so compare with `--tf-strength 1` ([cw-svt-anim]).
- **x265.** The anime guide raises psy-rd to 1.5 for grainy or dark shows and uses psy-rdoq 2-3 for grain or CRT texture ([koko]). It uses deblock -1:-1 for more grain or detail ([koko]). The JET guide keeps strong intra smoothing on for blurry sources because its blur helps prevent banding ([jet]).
- **VVenC.** As for heavy grain: `--fga` is experimental ([vvenc-changelog]).

### 3D / CGI (rendered, clean surfaces, smooth gradients)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` | `--preset medium` or `slow` |
| Quality | `--crf 30` | `--crf 18` | `-q 28-30` |
| Flags | `--input-depth 10 --enable-variance-boost 1 --enable-qm 1 --qm-min 0` (no film grain) | `--output-depth 10`, default AQ; consider `--aq-mode 3` for dark gradients | defaults |

- **SVT-AV1.** Leave film grain off on grainless 3D: it is faster and avoids losing detail ([svt-faq]). The default variance-boost strength suits detailed textures ([svt-vb]).
- **x265.** None of the referenced guides gives CGI-specific x265 settings. Treat it like clean live action, and use AQ mode 3 where dark gradients band ([x265-cli]).
- **libaom note.** Codec Wiki suggests `--arnr-strength=1` for 3D/CGI-like and 2D animation, because strong temporal filtering harms flat areas and lines ([cw-aom]).
- **VVenC.** Defaults ([vvenc-perf]).

### Screen content (text, UI, sharp graphics)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 6` | `--preset slow` | `--preset medium` |
| Quality | `--crf 30` | `--crf 18-22` | `-q 28-32` |
| Flags | `--scm 1 --enable-intrabc 1 --keyint 10s` | `--tskip` (consider `--cu-lossless`) | defaults |

- **SVT-AV1.** Mode 1 forces palette and intra block copy, which make text and UI cheap to code; modes 2 and 3 detect it per frame, which suits mixed sources ([svt-params]).
- **x265.** This build has no HEVC screen-content-coding extension; those options are rejected ([x265-cli]). Transform skip helps sharp synthetic edges such as text, and lossless CU decisions help at very low QP or on screen content ([x265-cli]).
- **libaom and AVM.** `--tune-content=screen` forces palette and intra block copy on every frame ([aom-encoder-c], [avm-ctc]).
- **VVenC.** No screen tune is exposed in vvencapp ([vvenc]).

### Low light (dark, noisy footage)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` | `--preset slow` |
| Quality | `--crf 28-30` | `--crf 18` | `-q 26-28` |
| Flags | `--input-depth 10 --enable-variance-boost 1 --variance-boost-strength 3 --film-grain 10-15`; SDR or HLG only: `--luminance-qp-bias 10-50` | `--output-depth 10 --aq-mode 3`; noisy: treat as heavy grain | `--sdr sdr_709` (enables the brightness-dependent QPA offset) |

- **SVT-AV1.** The variance-boost appendix targets night and foggy scenes, and strength 3 suits content that mixes very high- and low-contrast scenes ([svt-vb]). High-ISO noise behaves like heavy grain, so levels 10-15 apply ([svt-faq]). Luminance QP bias improved anime most and hurt live action in the BD-rate figures, so test 10, 30 and 50; the author says it is not suited to PQ ([cw-svt-p2]).
- **x265.** The docs recommend AQ mode 3 for 8-bit or low-bitrate 10-bit to prevent banding and blocking in dark areas ([x265-cli]).
- **VVenC.** In the v1.14.0 source, any `--hdr` or `--sdr` mode turns on a QPA offset that depends on brightness; without one of those modes it does not run ([vvenc-bitalloc]). This is from source reading; the project does not document it.

### Fast motion (sports, action, big camera moves)

| | SVT-AV1 | x265 | VVenC |
|---|---|---|---|
| Preset | `--preset 4` | `--preset slow` | `--preset medium` |
| Quality | `--crf 28-30` | `--crf 18` | `-q 28` |
| Flags | `--ac-bias 1.0-1.5 --enable-variance-boost 1`; optional `--passes 2` | `--hme` at high resolution; do not lower psy-rd at high quality | correct `--fps` (Y4M carries it) |

- **SVT-AV1.** Moderate AC bias keeps sharpness in textures and complex motion ([svt-params]). Extra passes in CRF mode mainly help corner cases such as high motion ([svt-faq]). Dynamic GOP (on by default) shortens mini-GOPs in high motion ([svt-params]).
- **x265.** Hierarchical motion estimation searches downscaled pictures first, which helps very fast or large motion at high resolution ([x265-cli]). The docs say lower bitrates call for lower psy strength or motion can judder ([x265-cli]).
- **VVenC.** QPA uses the frame rate, and rate control needs it to hit a target, so make sure it is right ([vvenc-usage]).

---

## 3. HDR done right

An HDR10 file is correct only when four things agree: 10-bit 4:2:0 pixels; the bitstream color tags (BT.2020 primaries, PQ transfer, BT.2020 non-constant matrix, limited range); the static metadata (ST 2086 mastering display and MaxCLL/MaxFALL); and the same values in the container ([ff-movenc], [mkvmerge]). HLG uses transfer 18 and usually no mastering metadata ([h273], [x265-cli]).

**None of these encoders converts transfer functions.** They only label the pixels. The input must already be PQ or HLG BT.2020 at the right range ([x265-cli], [svt-params]).

### 3.1 Signaling HDR10 and HLG, per encoder

| Encoder | HDR10 (PQ) | HLG | Static metadata | Notes |
|---|---|---|---|---|
| **x265** | `--output-depth 10 --profile main10 --range limited --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc` (or `--video-signal-type-preset BT2100_PQ_YCC`) | `--transfer arib-std-b67` (or `--video-signal-type-preset BT2100_HLG_YCC`); some delivery specs also want `--atc-sei 18 --pic-struct` | `--master-display "..." --max-cll "cll,fall"`; these imply `--hdr10`, which turns on `--repeat-headers` | `--hdr10-opt` adds PQ-aware QP only at 10-bit 4:2:0 BT.2020 PQ ([x265-cli]); otherwise x265 logs an error, disables it and still exits 0 (checked on 4.3+1). `--hdr-opt` is the old name ([x265-rel]). |
| **SVT-AV1** | `--input-depth 10 --color-primaries 9 --transfer-characteristics 16 --matrix-coefficients 9 --color-range 0 --chroma-sample-position topleft` | `--transfer-characteristics 18` (other fields as PQ) | `--mastering-display 'G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)' --content-light cll,fall` | No HDR10+ or Dolby Vision in the mainline CLI ([svt-params], [svt-hdr]). Through FFmpeg, `libsvtav1` copies mastering and light-level side data and can pass Dolby Vision RPUs ([ff-libsvtav1]). |
| **VVenC** | `--hdr pq_2020 --range limited` with 10-bit input | `--hdr hlg_2020` (add `--additional TransferCharacteristics=arib-std-b67` to put HLG in the VUI) | `--additional MasteringDisplayColourVolume=...:MaxContentLightLevel=cll,fall` | `--hdr pq` signals **BT.709** primaries; use `pq_2020` ([vvenc-usage]). The `--hdr` modes also switch on PQ/HLG chroma QP tables and HDR-aware QPA ([vvenc-cfg], [vvenc-bitalloc]). Setting the color fields through `--additional` alone leaves the encoder in SDR mode ([vvenc-cfg]). |
| **aomenc** | `--bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl` | `--transfer-characteristics=hlg` (`arib-std-b67` is rejected) | None; add them at mux time with mkvmerge | Range comes from the Y4M header ([aom-argdefs], [aom-y4m], [mkvmerge]). |
| **AVM (AV2)** | `--bit-depth=10 --color-primaries=bt2020 --transfer-characteristics=smpte2084 --matrix-coefficients=bt2020ncl --chroma-sample-position=topleft` | `--transfer-characteristics=hlg` | None; the app never inserts the metadata OBUs | ([avm-argdefs], [avm-ctc]) |
| **VideoToolbox via FFmpeg** | `-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -tag:v hvc1` | same with `color_trc=arib-std-b67` | **None**: the FFmpeg wrapper never forwards mastering or light-level data | ([vt-enc-src], [ff-setparams]) |
| **VideoToolbox via AVAssetWriter** | `AVVideoColorPropertiesKey` = BT.2020 / PQ / BT.2020, `kVTProfileLevel_HEVC_Main10_AutoLevel`, 10-bit buffers | HLG color properties | `kVTCompressionPropertyKey_MasteringDisplayColorVolume` (24 bytes) and `kVTCompressionPropertyKey_ContentLightLevelInfo` (4 bytes) | VideoToolbox writes both the SEI and the container atoms ([vt-mdcv], [vt-cll]). |
| **FFmpeg + libx265** (all-in-one) | `-mastering_display "..." -content_light cll,fall -i in -vf setparams=... -c:v libx265 -pix_fmt yuv420p10le -x265-params hdr10-opt=1 -tag:v hvc1` | as PQ with `color_trc=arib-std-b67` | `-mastering_display` and `-content_light` are **input** options, placed before `-i` | This form gave VUI, SEI and MP4 `colr`/`mdcv`/`clli` that all agree in a test with FFmpeg 9.0.2 and x265 4.3 (option behavior: [ff-doc], [ff-movenc], [x265-cli]). |

**Chroma siting.** UHD BT.2020 masters usually use top-left (co-sited) chroma. SVT-AV1's official HDR example uses `topleft`, x265's BT.2100 presets use `--chromaloc 2`, VVenC's 2020 modes set top-left automatically, and aomenc calls it `colocated` ([svt-params], [x265-cli], [vvenc-cfg], [aom-argdefs]). Copy the source's real siting when you know it.

### 3.2 Mastering display and MaxCLL syntax differences

The same P3-D65, 1000-nit, 0.0001-nit mastering display, written for each tool:

| Tool | Syntax | Order | Units |
|---|---|---|---|
| x265, FFmpeg `-mastering_display`, HEVC SEI | `G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)` | G, B, R, white point, then max, min | Chromaticity in 0.00002 steps (x/50000); luminance in 0.0001 nits (1000 nits = 10000000) ([x265-cli], [ff-doc]) |
| SVT-AV1 `--mastering-display` | `G(0.2650,0.6900)B(0.1500,0.0600)R(0.6800,0.3200)WP(0.3127,0.3290)L(1000,0.0001)` | G, B, R, white point, then max, min | Plain decimals; luminance in nits ([svt-params]) |
| VVenC `MasteringDisplayColourVolume` | `13250,34500,7500,3000,34000,16000,15635,16450,10000000,1` | G, B, R, white point, max, min | Same integer units as x265 ([vvenc-usage]) |
| mkvmerge | `--chromaticity-coordinates 0:0.680,0.320,0.265,0.690,0.150,0.060 --white-color-coordinates 0:0.3127,0.3290 --max-luminance 0:1000 --min-luminance 0:0.0001` | **R, G, B** | Decimals and nits ([mkvmerge]) |
| MP4Box `-hdr` | XML with `display_primaries_*` and luminance attributes, same integer units as the SEI | G, B, R | ([gpac-import], [gpac-fileimport]) |
| VideoToolbox | 24 big-endian bytes (`MasteringDisplayColorVolume`) | as the SEI | ([vt-mdcv]) |
| aomenc, AVM | No option; add at mux time | | ([aom-argdefs], [avm-argdefs]) |

Light level (MaxCLL, MaxFALL in nits):

| Tool | Syntax | Notes |
|---|---|---|
| x265 | `--max-cll "1000,400"` | `0,0` means unknown ([x265-cli]) |
| SVT-AV1 | `--content-light 1000,400` | integers; `0,0` means unknown ([svt-params]) |
| VVenC | `MaxContentLightLevel=1000,400` | both values must be non-zero or the SEI is skipped; v1.14.0 rejects values above 10000 ([vvenc-gop], [vvenc-cfg]) |
| FFmpeg | `-content_light 1000,400` (input option) | ([ff-doc]) |
| mkvmerge | `--max-content-light 0:1000 --max-frame-light 0:400` | ([mkvmerge]) |

Common mistakes with these strings:

- Swapping max and min luminance, or writing R, G, B where the tool expects G, B, R ([x265-cli], [vvenc-usage]).
- Using x265's integer units in SVT-AV1, or SVT-AV1's nits in x265 ([svt-params]).
- Pasting curly quotes, or leaving the parentheses unquoted in the shell ([x265-cli]).
- Inside `-x265-params`, `:` separates options, so write commas inside values (`max-cll=1000,400`) ([ff-codecs-x265]).
- Copying placeholder numbers. Take the real values from the source with ffprobe or MediaInfo ([codecalamity]). After a grade or tone change, the source's MaxCLL/MaxFALL may no longer be right ([x265-cli]).

### 3.3 HDR10+ workflow

HDR10+ adds per-frame (dynamic) metadata on top of an HDR10 stream. In this toolset it is an HEVC-only workflow, because hdr10plus_tool reads Annex B HEVC (and MKV) ([hdr10p]).

1. **Extract** from the source: `ffmpeg -i src.mkv -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | hdr10plus_tool extract -o hdr10plus.json -` ([hdr10p]).
2. **Encode** with the metadata, or add it afterwards:
   - In-encode: x265 `--dhdr10-info hdr10plus.json` (not in the help). In the Homebrew 4.3+1 build it worked only in **10-bit** encodes; the 8-bit and 12-bit libraries ignored it with a warning (checked locally; see [x265-cli] and [hdr10p] for the tools).
   - Afterwards: `hdr10plus_tool inject -i video.hevc -j hdr10plus.json -o video_hdr10p.hevc` ([hdr10p]).
3. **Verify**: `hdr10plus_tool --verify extract video_hdr10p.hevc` ([hdr10p]).
4. **Remux** with an explicit frame rate: `mkvmerge -o out.mkv --default-duration 0:24000/1001fps video_hdr10p.hevc -D encode.mkv` ([mkvmerge]).

**The JSON must match the encoded frames one to one.** Any trim, frame-rate change or interpolation breaks the match; retime with `hdr10plus_tool editor` or regenerate the metadata ([hdr10p]).

### 3.4 Dolby Vision workflows

| Path | Commands | Notes |
|---|---|---|
| **Re-encode, keep the source's DV as 8.1** | `dovi_tool -m 2 extract-rpu src.hevc -o RPU.bin`, then x265 with `--dolby-vision-profile 8.1 --dolby-vision-rpu RPU.bin --vbv-bufsize N --vbv-maxrate N --master-display ...` | Mode 2 rewrites each RPU as profile 8.1 ([dovi]). x265 requires VBV, Main10 and 4:2:0, and `--master-display` for 8.1; 12-bit is refused ([x265-cli]; the refusal messages were checked on 4.3+1). The VBV values are placeholders: use what your target level and devices allow. |
| **Encode HDR10, inject DV later** | `dovi_tool inject-rpu -i BL.hevc --rpu-in RPU.bin -o BL_RPU.hevc` | inject-rpu adds access unit delimiters by default unless `--no-add-aud` is given ([dovi]). |
| **Convert UHD Blu-ray profile 7 to 8.1** | `... -f hevc - \| dovi_tool -m 2 convert --discard - -o BL_RPU.hevc` | `--discard` drops the enhancement layer. FEL titles lose a usually small amount of detail; MEL titles lose nothing visible ([dovi], [emby-dv8]). |
| **Generate 8.1 from HDR10+** | `dovi_tool generate -j gen.json --hdr10plus-json hdr10plus.json -o RPU.bin` | The HDR10+ data becomes L1; gen.json supplies profile, length and L6 ([dovi]). |
| **8.4 from HLG** | AVAssetWriter with HLG color properties and `kVTHDRMetadataInsertionMode_Auto` | Needs the ambient viewing environment (`amve`) on every buffer you render ([apple-dv-pdf], [tn3145]). |
| **FFmpeg transcode** | libx265 `-dolbyvision auto`; libsvtav1 `-dolbyvision` | Passes decoded RPUs to the encoder ([ff-codecs-x265], [ff-libsvtav1]). x265's DV rules still apply. |
| **Strip DV to plain HDR10** | `ffmpeg -i in.mkv -map 0 -c copy -bsf:v dovi_rpu=strip=1 out.mkv` or `dovi_tool remove` | Never on profile 5: its base layer is IPT, not HDR10 ([ff-bsf], [dovi]). |

**Muxing DV:**

- **MP4:** `MP4Box -add BL_RPU.hevc:dvp=8.1:fps=24000/1001 -add source.mp4#audio -new out.mp4` ([gpac-import]). Raw HEVC has no timing, so give `fps` or MP4Box assumes 25 ([gpac-import]).
- **MP4 with FFmpeg:** pass `-strict unofficial -tag:v hvc1`. Without `-strict unofficial` the muxer drops `dvcC`, and the file silently plays as HDR10 ([ff-movenc]).
- **MKV:** `mkvmerge -o out.mkv --default-duration 0:24000/1001fps BL_RPU.hevc -D source.mkv` ([mkv-news], [mkvmerge]).

**Frame alignment is everything.** RPUs map to frames by order. Interpolation, trims or frame-rate changes need the RPU retimed with `dovi_tool editor` or regenerated ([dovi-editor]). Cropping letterbox bars invalidates the L5 offsets; use `dovi_tool --crop` or the editor's `active_area` ([dovi]). x265 `--frame-dup` changes the coded frame count, which also breaks alignment ([x265-cli]).

### 3.5 Verification commands

Run all of these on the finished file, not on the elementary stream.

```sh
# Stream tags: expect bt2020 / smpte2084 (or arib-std-b67) / bt2020nc / tv, and hvc1 or dvh1
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_tag_string,pix_fmt,color_range,color_space,color_transfer,color_primaries,chroma_location:stream_side_data_list \
  -of json out.mp4

# First frame's side data: mastering display, content light level, HDR10+
ffprobe -v error -select_streams v:0 -read_intervals %+#1 -show_frames \
  -show_entries frame=side_data_list -of json out.mp4

# HDR10+ present?
ffmpeg -i out.mp4 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | hdr10plus_tool --verify extract -

# Dolby Vision RPU: profile and frame count
ffmpeg -i out.mp4 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool extract-rpu -l 200 - -o rpu.bin
dovi_tool info -i rpu.bin -s

# Container boxes: DV configuration, colr, mdcv, clli
MP4Box -infox out.mp4
MP4Box -diso out.mp4 -out boxes.xml

# Matroska color fields
mkvmerge -J out.mkv
```

What each check shows comes from [hdr10p], [dovi], [ff-movenc] and [mkv-news]. Also read the encoder log: x265 4.3+1 disables `--hdr10-opt` with an error message but still exits 0 (checked locally).

### 3.6 Container pitfalls that break HDR after a correct encode

- In tests with FFmpeg 9.0.2, output `-color_primaries`/`-color_trc` were overwritten by the decoded frames' tags. An untagged source therefore got no `colr` box in MP4 and no primaries or transfer in MKV, even when the bitstream VUI was right. Tag the frames with `setparams` instead ([ff-setparams], [vt-enc-src]).
- The MP4 muxer writes `colr` only when primaries, transfer **and** matrix are all set ([ff-movenc]).
- mkvmerge v103 did not copy bitstream color into Matroska `Colour` fields when muxing raw HEVC (checked with `mkvmerge -J`), so players that read only the container see no HDR tags. Pass `--color-*` and `--max-*` explicitly ([mkvmerge]).
- `MP4Box :nosei` strips HDR10 and HDR10+ SEI ([gpac-import]).
- x265 `--repeat-headers` puts parameter sets inside the samples. It is meant for raw streams; leave it off for `hvc1` MP4 ([x265-cli], [apple-hls]).
- Each tool numbers range differently: FFmpeg `color_range` 1 = tv and 2 = pc; H.273 and the bitstream filters 0 = limited and 1 = full; mkvmerge 1 = broadcast and 2 = full ([ff-pixfmt], [mkvmerge]).
- Wrong tags on an existing file can be fixed without re-encoding: `-bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9:video_full_range_flag=0` (AV1: `av1_metadata`). These filters cannot add mastering or light-level SEI ([ff-bsf]).

---

## 4. Speed vs efficiency ladders

**These numbers vary by machine, content, resolution, quality level and encoder version.** Each comes from a different benchmark with its own method. Numbers inside one encoder's rows are comparable; numbers across encoders are **not**. Use them to choose where to start, then measure on your own machine and footage (Lumora's "Measure on this Mac" replaces its seed numbers with measurements; see `Lumora/Core/Quality/EncodeRecipes.swift`).

| Encoder | Setting | Relative speed | Relative efficiency | Source |
|---|---|---|---|---|
| **SVT-AV1** | `--preset -1` | about 50-60x slower than preset 4 (v1.8) | reference point (0%) | [cw-svt-p1] |
| | `--preset 0` | about 5-10x slower than preset 4 (v1.8) | about 0.97% worse than -1 (v3.0) | [cw-svt-p1] |
| | `--preset 1` | about 2x slower than preset 2 | about 3.79% worse than -1 | [cw-svt-p1] |
| | `--preset 2` | about 2x slower than preset 4 (v1.8) | about 7.82% worse than -1 | [cw-svt-p1] |
| | `--preset 3` | about 1.5x faster than preset 2 (v2.2) | about 17.08% worse than -1; preset 4 is close behind | [cw-svt-p1], [cw-svt3] |
| | `--preset 4` | baseline; a large speed jump follows at 5 | about 22.41% worse than -1; on v1.4, 98.92% of the best VMAF at 3.5% of the encode time | [cw-svt-p1], [slc] |
| | `--preset 5`-`8` | much faster than 4 | 8 is the last preset Codec Wiki considers fully usable in v3.0 | [cw-svt-p1] |
| | `--preset 9`+ | fastest | inconsistent quality at low CRF; 10+ meant for automation tooling | [cw-svt-p1], [svt-handle] |
| **x265** | `ultrafast` ... `veryfast` | fastest | largest files; ultrafast is inconsistent | [cw-x265], [x265-presets] |
| | `medium` (default) | moderate | baseline | [x265-presets] |
| | `slow` | slow | common good balance | [x265-presets], [koko] |
| | `slower` / `veryslow` | very / extremely slow | veryslow brings small gains over slower | [x265-presets], [jet] |
| | `placebo` | slowest | slightly **worse** than veryslow in practice | [cw-x265] |
| | option: `--no-rect` | saves about 25% time | costs about 1-3% | [koko] |
| | option: frame threading on (`--frame-threads 0`) | large speed gain | costs about 1-3% | [cw-x265] |
| | option: `--bframes 8` vs 4 | little extra time | saves about 3-5% (anime) | [koko] |
| | option: `--ctu 32` vs 64 | faster | costs about 1-2% (anime) | [koko] |
| **VVenC** (v1.14.0, vs HM-17.0) | `faster` | about 380x faster than HM at 8 threads; about 7x faster than medium | about 13% smaller than HM | [vvenc-perf] |
| | `fast` | about 2x slower than faster | about 26% smaller than HM | [vvenc-perf] |
| | `medium` (default) | about 3.5x slower than fast | about 35% smaller than HM | [vvenc-perf] |
| | `slow` | about 4x slower than medium | about 39% smaller than HM | [vvenc-perf] |
| | `slower` | about 4-5x slower than slow | about 42% smaller than HM | [vvenc-perf] |
| | `medium_lowDecEnergy` | not measured by the project | over 25% lower decoder energy for under 5% more bitrate (research result) | [arxiv] |
| **libaom** | `--cpu-used=0` | could take weeks for a full encode | best libaom offers | [cw-aom] |
| | `--cpu-used=2` / `3` | very slow / slow | worth it for more efficiency than 4 | [cw-aom] |
| | `--cpu-used=4` | moderate | recommended balance | [cw-aom] |
| | `--cpu-used=6` | fastest useful good-quality speed | 7-9 behave like 6 in good mode | [cw-aom], [aom-speed] |
| **AVM (AV2)** | `--cpu-used=0` (default) | slowest; all AV2 test-condition encodes use it | AOMedia cites about 30% savings over AV1 | [avm-ctc], [aom-av2-blog] |
| | `--cpu-used=6` | fastest distinct level (7-9 = 6), still far slower than libaom | | [avm-cx] |
| **VideoToolbox HEVC** | hardware, no preset ladder; `-prio_speed 0/1` | far faster than x265 | one 4K test found `-q:v 50` artifact-free but about 7x larger than x265 CRF 28, and x265 sharper at a similar size | [vt-prio], [yre] |

How the encoders relate to each other cannot be read from this table, because no shared benchmark covers them all. Two sourced cross-encoder points: Codec Wiki notes SVT-AV1 handles only 4:2:0, so libaom is the AV1 choice for 4:2:2 and 4:4:4 ([cw-aom]), and the VVenC `slower` preset is described as similar to the VTM reference encoder ([vvenc-perf]).

**Lumora's seed numbers line up with the SVT-AV1 data.** Its AV1 ladder seeds preset 4 at 0.085 and preset 2 at 0.040 of preset 10's speed, a ratio of about 2.1x, which matches the roughly 2x in the v1.8 tests ([cw-svt-p1]; `Lumora/Core/Quality/EncodeRecipes.swift`). Its x265 seeds are its own estimates, not taken from a cited benchmark (`Lumora/Core/Quality/EncodeRecipes.swift`).

**Parallelism, which changes real speed more than presets on a big machine:**

- SVT-AV1 `--lp` is a parallelism **level** from 0 to 6, not a thread count. Running several instances with a modest level each scales better than one encode on many cores ([svt-params], [svt-handle]).
- libaom makes poor use of many threads in one process, so chunked encoding (for example Av1an) is the usual way to parallelize it ([cw-aom]).
- AVM's test conditions state that closed-GOP chunks encoded separately and concatenated give the same bitstream ([avm-ctc]).
- VVenC picks threads by resolution (4, 8 or 12) and turns on tiles, WPP and inter-frame parallelism when you raise `--threads` above that default ([vvenc-cfg]). Rate control allows at most 4 parallel frames ([vvenc-cfg]).
- x265 frame threading costs about 1-3%; the wiki saw no difference between 2 and 16 threads in 4.1 ([cw-x265]).
- Apple M5 Max has two video encode engines and M5 Ultra four; Apple's segment flags (`MoreFramesBeforeStart/AfterEnd`) keep the joins smooth ([apple-mbp-specs], [apple-studio-specs], [vt-parallel]).

---

## 5. Myths and pitfalls

### Metrics

- **"Higher VMAF always means better."** It does not. SVT-AV1's VMAF tune (tune 5) targets about 15% VMAF BD-rate gain, and the encoder itself warns that it applies unsharp-mask pre-processing, so a higher VMAF may not mean higher fidelity ([svt-changelog]). In the v3.0 study, variance boost improved nearly every metric except VMAF ([cw-svt-p2]). VMAF NEG is the variant that ignores sharpening gains (Lumora's metric notes, `docs/features.md`).
- **"Tune for the metric you report."** Tuning for a metric optimizes that number, not what eyes see. Codec Wiki discourages PSNR tuning on SVT-AV1 ([cw-svt]), and VVenC's own PSNR results are measured with QPA off because QPA targets perceived quality ([vvenc-perf]). VMAF models are trained on SDR viewing, which makes VMAF tunes a questionable target for HDR (`docs/features.md`; libaom's VMAF tunes also need an explicit model path on Homebrew, [aom-cxiface]).
- **"VMAF works for HDR."** VMAF was trained on SDR viewing (`docs/features.md`). Lumora scores the PQ/HLG-coded signal for consistency but treats it as a safety margin, not a calibrated HDR scale (`docs/features.md`).

### Grain synthesis

- **"Grain synthesis lowers quality scores, so it is worse."** Synthetic grain is random by design. Pixel-matching metrics penalize grain that looks right but does not match pixel for pixel. Score the decode with the synthetic grain removed, against a de-grained reference. FFmpeg's `-export_side_data film_grain` exports AV1 grain instead of applying it, which Lumora uses for exactly this ([ff-doc]; `docs/features.md`).
- **SVT-AV1's own PSNR/SSIM report may compare against the denoised picture** when grain denoising is on, so treat those numbers with care (unverified by the project; see [svt-fgs]).
- **"More grain level is more film-like."** Too high a level with denoise off stacks synthetic noise on top of the real noise ([svt-faq]). libaom grain above about 12 starts to look patterned ([cw-aom]), and a Doom9 user found raising it gave artificial-looking noise ([doom9-aom]).
- **"Denoise is free."** Denoising before synthesis gives the big savings, but it always removes some fine detail ([svt-faq], [cw-svt]). In libaom, `--enable-dnl-denoising=0` keeps the real grain and adds synthetic grain on top; Codec Wiki prefers that, except on very noisy sources ([cw-aom]).
- **`--tune-content=film` in libaom** writes the same generic grain into every frame without measuring the source ([aom-encoder-c]).
- **Grain tables are not interchangeable across codecs.** SVT-AV1 and libaom read `filmgrn1`; AVM needs `filmgrn2` ([svt-appcfg], [avm-grain]). With a supplied table, SVT-AV1 does not denoise, so feed it a clean source or the grain doubles ([svt-appcfg]).
- **HEVC and VVC grain SEI are rarely applied by players.** x265 writes it only from a model you supply ([x265-cli]); VVenC's `--fga` is experimental ([vvenc-changelog]). On those codecs, keep real grain with bits instead.

### Bit depth

- **"8-bit is fine for HDR."** It is not. PQ or HLG gradients cut to 8 bits band visibly. SVT-AV1 cannot turn an 8-bit pipe into a real HDR encode, since `--input-depth` describes both input and output ([svt-params], [svt-faq]). VVenC accepts 8-bit input in an HDR mode but the result is prone to banding ([vvenc-cfg]). One reader of the HDR article got 8-bit output from x265 until adding `-D 10` ([codecalamity]). Apple's Dolby Vision 8.4 rules require Main10, and FFmpeg refuses `main10` with 8-bit input ([tn3145], [vt-enc-src]).
- **"10-bit costs more bits for SDR."** The sources disagree. Codec Wiki recommends 10-bit for everything, including 8-bit sources, for less banding and usually smaller files; the SVT-AV1 FAQ describes about a 5% size cost for slightly better fidelity ([cw-aom], [cw-svt], [svt-faq]).
- **"12-bit is always better than 10-bit."** For HEVC, 12-bit is an archival format: Main12 decoders are rare, Dolby Vision is refused, and `--hdr10-opt` is disabled ([x265-cli]). The anime guide found 10-bit better than 12-bit at high CRF ([koko]).

### Tune options that hurt

- **x265 `--tune grain` with HDR10.** The grain tune turns AQ off ([x265-presets]), while `--hdr10-opt` is documented to work best with AQ on ([x265-cli]). If you need both, set the grain-friendly options by hand and keep AQ.
- **x265 `--tune grain` on slower presets** is too strong according to the anime guide ([koko]).
- **x265 `--tune animation` vs the anime guide.** The tune sets psy-rd 0.4; the anime guide uses 1.0 ([x265-presets], [koko]). Options you set explicitly always override a tune ([x265-presets]).
- **SVT-AV1 `--tune 3` (IQ) is for still images.** Parameters.md marks it still-image only, and v4.3.0 rejects it in random-access video mode ([svt-params], [svt-settings]).
- **SVT-AV1 tune numbers differ between forks.** SVT-AV1-PSY's tune 3 was "subjective SSIM", not mainline's IQ, and svt-av1-hdr adds a tune 6 that mainline lacks ([cw-svt-psy], [svt-hdr]).
- **SVT-AV1 `--luminance-qp-bias` on PQ.** Codec Wiki says to use it only on SDR and HLG ([cw-svt-p2]).
- **Fork-only flags** such as `--variance-boost-curve 3`, `--hdr10plus-json` or `--dolby-vision-rpu` do not exist in mainline SVT-AV1 ([svt-hdr]).
- **libaom `--deltaq-mode=5` ("HDR video") is mostly inert** in 3.15.3. The per-block luma offsets are compiled out, and only frame-level chroma offsets remain for 10-bit BT.2020 ([aom-encoderh], [aom-quantize]).
- **libaom `--tune=butteraugli`** accepts only 8-bit input and is not in the Homebrew build ([aom-aomenc]).
- **x265 `--cutree`.** The JET guide turns it off, Codec Wiki says turning it off usually hurts ([jet], [cw-x265]). Test before changing it.

### Things that silently go wrong

- **SVT-AV1 never puts keyframes at scene cuts** regardless of `--scd`; split the video at cuts externally ([svt-faq]).
- **SVT-AV1 `--lp` above 6 is clamped to 6** with a warning ([svt-handle]).
- **SVT-AV1 at 4K and above** caps random-access presets at 9, and above 4K it rejects presets 4 and below ([svt-handle], [svt-settings]).
- **SVT-AV1 `--frames` larger than the input loops back** to the start ([svt-params]).
- **FFmpeg `-crf` for libsvtav1 is an integer 0-63**; fractional or higher CRF needs `-svtav1-params crf=...`, which is parsed last and overrides FFmpeg-level color fields ([ff-libsvtav1]).
- **hevc_videotoolbox defaults in FFmpeg**: no bitrate (encoder picks a low one), `-bf 0` (no B-frames), `-g 12` (a keyframe every 12 frames), `hev1` tag. Pass `-q:v` or `-b:v`, `-bf 2`, `-g 0` and `-tag:v hvc1` ([vt-enc-src]). `-q:v` works only on Apple silicon ([vt-enc-src]).
- **VVenC Y4M is detected by file extension only**; piped Y4M needs `--y4m`, and two-pass rate control cannot read from stdin ([cw-vvenc], [vvenc-appcfg]).
- **VVenC `--hdr hlg_2020` leaves the VUI transfer at bt2020-10** and carries HLG only in an SEI ([vvenc-cfg]).
- **aomenc with piped input needs `--passes=1`**; otherwise the output is just a 32-byte header ([aom-aomenc]).
- **x265 `placebo` is not worth it**: slightly worse than veryslow ([cw-x265]).
- **x265 `--help` omits about 50 flags** that `--fullhelp` lists, including `--y4m`, `--qcomp` and `--zones` (compared on 4.3+1; the full option set is in [x265-cli]).
- **Raw HEVC has no timing**: MP4Box assumes 25 fps without `:fps=`, and mkvmerge needs `--default-duration` ([gpac-import], [mkvmerge]).

---

## Appendix: where Lumora's current settings differ from this guide

These come from reading Lumora's code against the references above. None was confirmed by running the app.
(Two earlier rows are fixed: aomenc and AVM now get HLG as `hlg`, and AVM gets grain as `--film-grain-table` with a
`filmgrn2` table. The AVM side was verified by real AV2 exports; see [Features → AV2](../features.md#av2-avm).)

| Area | What Lumora does | What the references say | Source |
|---|---|---|---|
| SVT-AV1 `--lp` | passes the core count (or cores per instance) | `--lp` is a 0-6 level; anything above 6 is clamped, so every instance runs at maximum parallelism and memory | [svt-handle]; `Lumora/Resources/encoders.json` |
| SVT-AV1 luminance bias | `--luminance-qp-bias 25` offered for real life, heavy grain, low light and old anime regardless of output transfer | not for PQ (HDR10) | [cw-svt-p2]; `Lumora/Core/Quality/EncodeRecipes.swift` |
| SVT-AV1 grain | the `grain` tune uses `--film-grain 10 --film-grain-denoise 0`; the recipe option uses 12/8/4 with denoise 1 | the two paths behave differently; the FAQ suggests up to about 10 for grainy animation, Lumora uses 4 for old anime | [svt-faq]; both Lumora files |
| SVT-AV1 grain at fast presets | grain options can combine with presets 8 and 10 | SVT-AV1 warns that grain above preset 6 is costly; at 4K preset 10 becomes 9 | [svt-handle]; `EncodeRecipes.swift` |
| x265 `--hdr10-opt` on the 12-bit path | passed for HDR10 jobs | does nothing at 12-bit (error logged, exit 0; checked on 4.3+1) | [x265-cli]; `encoders.json` |
| x265 grain tune | `--tune grain`, then the recipe adds `--aq-mode 3` and `--psy-rd 2.0` | explicit options override the tune, undoing its AQ-off and psy-rd 4 | [x265-presets]; both Lumora files |
| x265 `psy-rdoq` on fast rungs | offered on every rung | needs `--rdoq-level` 1 or 2, which only `slow` and up set | [x265-cli]; `EncodeRecipes.swift` |
| x265 flag probing | `supportedFlags()` runs `x265 --help` | `--help` omits about 50 flags that `--fullhelp` lists (compared on 4.3+1) | [x265-cli]; `EncodeRecipes.swift` |
| VVenC HLG and metadata | `hdrArgs` are appended only for HDR10; no `MasteringDisplayColourVolume` or `MaxContentLightLevel` | HLG needs `--hdr hlg_2020`; HDR10 static metadata needs `--additional` | [vvenc-usage], [vvenc-cfg]; `encoders.json` |
| VVenC SDR | no `--sdr` flag, so SDR encodes carry no color description and no brightness-dependent QPA | `--sdr sdr_709` gives explicit signaling | [vvenc-usage], [vvenc-bitalloc]; `encoders.json` |
| FFmpeg MP4 fallback remux | passes neither `-tag:v hvc1` nor `-strict unofficial` | HEVC may be tagged `hev1`, and Dolby Vision loses `dvcC` | [ff-movenc], [apple-hls] |
| MKV color | no mkvmerge color or mastering flags | mkvmerge leaves Matroska `Colour` empty for raw HEVC | [mkvmerge] |

---

## Sources

SVT-AV1

[svt-params]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md
[svt-faq]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/CommonQuestions.md
[svt-fgs]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Film-Grain-Synthesis.md
[svt-vb]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Appendix-Variance-Boost.md
[svt-changelog]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/CHANGELOG.md
[svt-handle]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_handle.c
[svt-settings]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/Lib/Globals/enc_settings.c
[svt-appcfg]: https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.3.0/Source/App/app_config.c
[cw-svt-p1]: https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p1
[cw-svt-p2]: https://codecs.wiki/blog/svt-av1-fourth-deep-dive-p2
[cw-svt3]: https://codecs.wiki/blog/svt-av1-third-deep-dive
[cw-svt-anim]: https://codecs.wiki/blog/svt-av1-deep-dive
[cw-svt]: https://codecs.wiki/docs/encoders/SVT-AV1
[cw-svt-psy]: https://codecs.wiki/docs/encoders/SVT-AV1-PSY
[svt-hdr]: https://github.com/juliobbv-p/svt-av1-hdr
[slc]: https://streaminglearningcenter.com/encoding/choosing-a-preset-for-svt-av1-and-libaom-av1.html
[ff-libsvtav1]: https://code.ffmpeg.org/FFmpeg/FFmpeg/raw/branch/master/libavcodec/libsvtav1.c

- [SVT-AV1 Parameters][svt-params]
- [SVT-AV1 Common Questions][svt-faq]
- [SVT-AV1 Film Grain Synthesis appendix][svt-fgs]
- [SVT-AV1 Variance Boost appendix][svt-vb]
- [SVT-AV1 CHANGELOG][svt-changelog]
- [SVT-AV1 v4.3.0 enc_handle.c][svt-handle]
- [SVT-AV1 v4.3.0 enc_settings.c][svt-settings]
- [SVT-AV1 v4.3.0 app_config.c][svt-appcfg]
- [Codec Wiki: SVT-AV1 deep dive part 1 (presets v2.0 to v3.0)][cw-svt-p1]
- [Codec Wiki: SVT-AV1 deep dive part 2 (parameters revisited)][cw-svt-p2]
- [Codec Wiki: SVT-AV1 v2.2 deep dive][cw-svt3]
- [Codec Wiki: Encoding animation with SVT-AV1][cw-svt-anim]
- [Codec Wiki: SVT-AV1][cw-svt]
- [Codec Wiki: SVT-AV1-PSY][cw-svt-psy]
- [svt-av1-hdr fork][svt-hdr]
- [Streaming Learning Center: choosing a preset for SVT-AV1 and libaom][slc]
- [FFmpeg libsvtav1.c][ff-libsvtav1]

x265

[x265-cli]: https://x265.readthedocs.io/en/master/cli.html
[x265-presets]: https://x265.readthedocs.io/en/master/presets.html
[x265-rel]: https://x265.readthedocs.io/en/master/releasenotes.html
[jet]: https://silentaperture.gitlab.io/mdbook-guide/encoding/x265.html
[koko]: https://kokomins.wordpress.com/2019/10/10/anime-encoding-guide-for-x265-and-why-to-never-use-flac/
[cw-x265]: https://codecs.wiki/docs/encoders/x265
[codecalamity]: https://codecalamity.com/encoding-uhd-4k-hdr10-videos-with-ffmpeg/
[ff-codecs-x265]: https://ffmpeg.org/ffmpeg-codecs.html#libx265

- [x265 command line options][x265-cli]
- [x265 preset options and tunes][x265-presets]
- [x265 release notes][x265-rel]
- [Encoding guide: x265 settings (JET / silentaperture)][jet]
- [Kokomins: anime encoding guide for x265][koko]
- [Codec Wiki: x265][cw-x265]
- [Code Calamity: encoding UHD 4K HDR10 with FFmpeg][codecalamity]
- [FFmpeg codecs: libx265][ff-codecs-x265]

VVenC

[vvenc]: https://github.com/fraunhoferhhi/vvenc
[vvenc-usage]: https://github.com/fraunhoferhhi/vvenc/wiki/Usage
[vvenc-perf]: https://github.com/fraunhoferhhi/vvenc/wiki/Encoder-Performance
[vvenc-changelog]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/master/changelog.txt
[vvenc-cfg]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/vvenc/vvencCfg.cpp
[vvenc-appcfg]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/apputils/VVEncAppCfg.h
[vvenc-gop]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/EncGOP.cpp
[vvenc-bitalloc]: https://raw.githubusercontent.com/fraunhoferhhi/vvenc/v1.14.0/source/Lib/EncoderLib/BitAllocation.cpp
[cw-vvenc]: https://codecs.wiki/docs/encoders/VVenC
[arxiv]: https://arxiv.org/abs/2206.13483

- [VVenC repository README][vvenc]
- [VVenC wiki: Usage][vvenc-usage]
- [VVenC wiki: Encoder Performance][vvenc-perf]
- [VVenC changelog][vvenc-changelog]
- [VVenC v1.14.0 vvencCfg.cpp][vvenc-cfg]
- [VVenC v1.14.0 VVEncAppCfg.h][vvenc-appcfg]
- [VVenC v1.14.0 EncGOP.cpp][vvenc-gop]
- [VVenC v1.14.0 BitAllocation.cpp][vvenc-bitalloc]
- [Codec Wiki: VVenC][cw-vvenc]
- [Decoding-energy-aware encoding in practical VVC implementations (arXiv 2206.13483)][arxiv]

libaom and AVM

[cw-aom]: https://codecs.wiki/docs/encoders/aomenc
[aom-argdefs]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/arg_defs.c
[aom-aomenc]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/apps/aomenc.c
[aom-cxiface]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/av1_cx_iface.c
[aom-encoderh]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.h
[aom-quantize]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/av1_quantize.c
[aom-encoder-c]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/encoder.c
[aom-speed]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/av1/encoder/speed_features.c
[aom-y4m]: https://aomedia.googlesource.com/aom/+/refs/tags/v3.15.3/common/y4minput.c
[doom9-aom]: https://forum.doom9.org/archive/index.php/t-184143.html
[avm-argdefs]: https://github.com/AOMediaCodec/avm/blob/v1.0.0/av2/arg_defs.c
[avm-cx]: https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm/avmcx.h
[avm-grain]: https://github.com/AOMediaCodec/avm/blob/v1.0.0/avm_dsp/grain_table.c
[avm-ctc]: https://aomedia.org/docs/CWG-G082_AV2_CTC_v9.pdf
[aom-av2-blog]: https://aomedia.org/blog%20posts/AV2-What-the-Final-Specification-Means-for-Implementers/

- [Codec Wiki: aomenc][cw-aom]
- [libaom v3.15.3 arg_defs.c][aom-argdefs]
- [libaom v3.15.3 aomenc.c][aom-aomenc]
- [libaom v3.15.3 av1_cx_iface.c][aom-cxiface]
- [libaom v3.15.3 encoder.h][aom-encoderh]
- [libaom v3.15.3 av1_quantize.c][aom-quantize]
- [libaom v3.15.3 encoder.c][aom-encoder-c]
- [libaom v3.15.3 speed_features.c][aom-speed]
- [libaom v3.15.3 y4minput.c][aom-y4m]
- [Doom9 forum: aomenc film grain table workflow][doom9-aom]
- [AVM v1.0.0 arg_defs.c][avm-argdefs]
- [AVM v1.0.0 avmcx.h][avm-cx]
- [AVM v1.0.0 grain_table.c][avm-grain]
- [AOM Common Test Conditions v9.0 (CWG-G082)][avm-ctc]
- [AOMedia: AV2, what the final specification means for implementers][aom-av2-blog]

Apple VideoToolbox and ProRes

[vt-enc-src]: https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c
[vt-prio]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality
[vt-mdcv]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_masteringdisplaycolorvolume
[vt-cll]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_contentlightlevelinfo
[vt-avgbr]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate
[vt-dlimits]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits
[vt-parallel]: https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit
[tn3145]: https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata
[apple-dv-pdf]: https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf
[prores-pdf]: https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf
[apple-mbp-specs]: https://www.apple.com/macbook-pro/specs/
[apple-studio-specs]: https://www.apple.com/mac-studio/specs/
[yre]: https://yre.jp/en/post/m1mac_h265/

- [FFmpeg n9.0.2 videotoolboxenc.c][vt-enc-src]
- [kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality][vt-prio]
- [kVTCompressionPropertyKey_MasteringDisplayColorVolume][vt-mdcv]
- [kVTCompressionPropertyKey_ContentLightLevelInfo][vt-cll]
- [kVTCompressionPropertyKey_AverageBitRate][vt-avgbr]
- [kVTCompressionPropertyKey_DataRateLimits][vt-dlimits]
- [kVTCompressionPropertyKey_RecommendedParallelizationLimit][vt-parallel]
- [TN3145: HDR video metadata][tn3145]
- [Incorporating HDR video with Dolby Vision into your apps][apple-dv-pdf]
- [Apple ProRes white paper (April 2022)][prores-pdf]
- [MacBook Pro tech specs][apple-mbp-specs]
- [Mac Studio tech specs][apple-studio-specs]
- [M1 Pro H.265: VideoToolbox vs libx265 benchmark][yre]

HDR metadata, muxing and FFmpeg

[dovi]: https://github.com/quietvoid/dovi_tool
[dovi-editor]: https://github.com/quietvoid/dovi_tool/blob/main/docs/editor.md
[hdr10p]: https://github.com/quietvoid/hdr10plus_tool
[gpac-import]: https://wiki.gpac.io/MP4Box/mp4box-import-opts/
[gpac-fileimport]: https://github.com/gpac/gpac/blob/master/applications/mp4box/fileimport.c
[mkvmerge]: https://mkvtoolnix.download/doc/mkvmerge.html
[mkv-news]: https://mkvtoolnix.download/doc/NEWS.md
[ff-doc]: https://ffmpeg.org/ffmpeg.html
[ff-bsf]: https://ffmpeg.org/ffmpeg-bitstream-filters.html
[ff-setparams]: https://ffmpeg.org/ffmpeg-filters.html#setparams
[ff-movenc]: https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c
[ff-pixfmt]: https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/pixfmt.h
[apple-hls]: https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices
[emby-dv8]: https://emby.media/learn/articles/video/hdr/formats/dolby-vision/profiles-and-compatibility/Dolby-Vision-Profile-8.html
[h273]: https://www.itu.int/rec/T-REC-H.273

- [dovi_tool README][dovi]
- [dovi_tool editor documentation][dovi-editor]
- [hdr10plus_tool README][hdr10p]
- [GPAC wiki: MP4Box import options][gpac-import]
- [GPAC source: fileimport.c (HDR XML parser)][gpac-fileimport]
- [mkvmerge documentation][mkvmerge]
- [MKVToolNix NEWS][mkv-news]
- [ffmpeg tool documentation][ff-doc]
- [FFmpeg bitstream filters][ff-bsf]
- [FFmpeg filters: setparams][ff-setparams]
- [FFmpeg movenc.c (colr/mdcv/clli/dvcC rules)][ff-movenc]
- [FFmpeg pixfmt.h color enums][ff-pixfmt]
- [Apple HLS authoring specification][apple-hls]
- [Emby: Dolby Vision profile 8][emby-dv8]
- [ITU-T H.273 (CICP)][h273]

Lumora files referenced (repository-relative): `Lumora/Resources/encoders.json`, `Lumora/Core/Quality/EncodeRecipes.swift`, `Lumora/Core/Analysis/ContentProfiler.swift` (`ContentTuning`), `docs/features.md`.

{% endraw %}
