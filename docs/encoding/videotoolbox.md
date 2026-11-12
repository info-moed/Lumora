---
title: Apple VideoToolbox (HEVC and ProRes hardware encoders)
parent: Encoding settings
nav_order: 7
---

{% raw %}

# Apple VideoToolbox (HEVC and ProRes hardware encoders)

**Documented version:** ffmpeg version 9.0.2 · **Codec:** HEVC · **License:** Proprietary (VideoToolbox ships with macOS). FFmpeg wrappers: LGPL-2.1-or-later source; the Homebrew ffmpeg build is GPL-3.0-or-later. · **Homepage:** <https://developer.apple.com/documentation/videotoolbox> · **Homebrew:** [`ffmpeg`](https://formulae.brew.sh/formula/ffmpeg)

VideoToolbox is Apple's system framework that drives the Media Engine's hardware HEVC encoder and the separate ProRes encode engines; Lumora calls it in-process through AVAssetWriter, and FFmpeg exposes the same encoders as hevc_videotoolbox and prores_videotoolbox. It is extremely fast, uses little CPU or power, and its ProRes output is the post-production standard. The trade-offs: hardware HEVC needs noticeably more bits than a slow x265 encode for the same quality, there are almost no tuning knobs (no presets, psy options or grain tools), HEVC stops at 10-bit, and the FFmpeg wrapper cannot carry HDR10 static metadata. Two FFmpeg 9.0.2 traps, both confirmed by test encodes: output -color_primaries/-color_trc do not override the input frames' tags (tag with the setparams filter instead), and FFmpeg's generic -g default of 12 is passed to VideoToolbox as the maximum keyframe interval. Documented against FFmpeg 9.0.2 and the macOS 27 SDK on macOS 27.3 (Apple M3 Max); this one entry covers both HEVC and ProRes.

**Bit depths:** 8, 10, 12 · **Chroma:** 4:2:0, 4:2:2, 4:4:4, 4:4:4:4

Machine-readable data: [`data/videotoolbox.json`](data/videotoolbox.json). Every option below is listed in the installed tool's own help; descriptions are written for this reference, and each recommendation links to its source.

**On this page:** [HDR](#hdr) · [Presets](#presets) · [Rate control](#rate-control) · [Recipes](#recipes) · [All options](#all-options) · [Options in detail](#options-in-detail) · [Sources](#sources)

## HDR

HEVC HDR needs three things: a 10-bit pipeline (Main10 profile plus 10-bit pixel buffers such as x420/p010), correct color tags (BT.2020 primaries, BT.2020 non-constant matrix, and either PQ or HLG transfer), and, for HDR10, static metadata (mastering display color volume and content light level). Through AVAssetWriter, put the tags in AVVideoColorPropertiesKey and the static metadata in AVVideoCompressionPropertiesKey as kVTCompressionPropertyKey_MasteringDisplayColorVolume (24 big-endian bytes) and kVTCompressionPropertyKey_ContentLightLevelInfo (4 big-endian bytes); VideoToolbox writes both the SEI messages and the container atoms. kVTCompressionPropertyKey_HDRMetadataInsertionMode (default Auto) decides what metadata VideoToolbox adds on its own based on the output color space; for HLG it can generate Dolby Vision 8.4 metadata. The FFmpeg wrappers pass the encoder context's color fields to VideoToolbox, but the FFmpeg 9.0.2 command line fills primaries and transfer from the decoded frames, so output -color_primaries/-color_trc are ignored when the input is untagged or tagged differently (verified: an untagged source stayed 'unknown', and a PQ source stayed PQ under -color_trc arib-std-b67). Tag the frames with -vf setparams=... instead. The wrappers (n9.0.2 source) also never pass mastering display or light level side data to VideoToolbox, so FFmpeg-made HDR10 files lack static metadata. ProRes carries HDR as plain tags (PQ or HLG) at 10-bit (422 family) or up to 12-bit (4444 family).

**Flags involved:** `-profile:v main10`, `-pix_fmt p010le`, `-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv`, `-vf setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc:range=tv`, `-colorspace bt2020nc`, `-tag:v hvc1`, `-bf 2`, `-g 0`, `AVVideoColorPropertiesKey`, `AVVideoProfileLevelKey = kVTProfileLevel_HEVC_Main10_AutoLevel`, `kVTCompressionPropertyKey_MasteringDisplayColorVolume`, `kVTCompressionPropertyKey_ContentLightLevelInfo`, `kVTCompressionPropertyKey_HDRMetadataInsertionMode`, `kVTCompressionPropertyKey_PreserveDynamicHDRMetadata`

**Example (HDR10):**

```bash
ffmpeg -i master_pq.mov -map 0:v:0 -map '0:a?' -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -q:v 62 -bf 2 -g 0 -prio_speed 0 -tag:v hvc1 -c:a copy out_hdr10.mov
```

**Pitfalls:**

- FFmpeg's hevc_videotoolbox (n9.0.2 source) does not forward mastering display or content light level side data to VideoToolbox, so the HEVC stream gets no static HDR10 SEI. Use AVAssetWriter/VTCompressionSession directly (as Lumora does) or x265 when MaxCLL/MaxFALL and mastering metadata matter, and check the result with ffprobe or MediaInfo.
- In FFmpeg 9.0.2, output -color_primaries and -color_trc are overridden by the decoded frames' tags; only -colorspace and -color_range reach the encoder reliably. Use -vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv (or color_trc=arib-std-b67 for HLG). Test encodes confirmed both the failure and the fix.
- -q:v (constant quality) works only on Apple-silicon Macs; on Intel FFmpeg stops with an error and you must use -b:v.
- If neither -q:v nor -b:v is given, FFmpeg passes a bitrate of 0, so VideoToolbox picks its own, usually low, rate. Expect soft, hazy output.
- FFmpeg's default -bf is 0, and the wrapper then sets AllowFrameReordering to false, which turns off B-frames. Pass -bf 2 (any positive value) to let the encoder reorder.
- FFmpeg's generic -g default (12) is passed to kVTCompressionPropertyKey_MaxKeyFrameInterval, so a plain hevc_videotoolbox encode gets a keyframe every 12 frames (confirmed by test). Pass -g 0 to let VideoToolbox choose, or a value that matches your segment length.
- Without -tag:v hvc1, FFmpeg 9.0.2 tags HEVC as hev1 in both .mov and .mp4 (checked with ffprobe). Apple's Dolby Vision 8.4 constraints require hvc1, and AVFoundation's own HEVC codec type is 'hvc1'.
- PQ or HLG tags on an 8-bit (Main) stream will band visibly. Feed p010le or x420 and use Main10.
- HDRMetadataInsertionMode defaults to Auto, so VideoToolbox may add metadata (Dolby Vision 8.4 for HLG, for example) even when you did not ask for it. Set None only if you need a plain stream and accept that static metadata insertion is turned off too. Apple documents that None removes all HDR metadata.
- Dolby Vision 8.4 needs an ambient viewing environment ('amve'). If you render fresh pixel buffers instead of passing decoded ones through, copy kCVImageBufferAmbientViewingEnvironmentKey onto them (TN3145).
- Lumora: if AVAssetWriter.canApply rejects the full settings, ExportEngine retries without the whole compression dictionary. That silently drops Main10, Quality and the HDR10 static metadata at the same time.
- ProRes 422 profiles are 4:2:2 10-bit. Only 4444 and 4444 XQ keep 12-bit and full chroma.
- Quote stream specifiers that contain '?', for example -map '0:a?'. Unquoted, zsh (the macOS default shell) treats '?' as a glob and stops with 'no matches found'.

## Presets

| Preset | Speed | Notes |
|---|---|---|
| (default; no prio_speed set) | Typically faster than real time, even at 4K (1.7x on a 4K clip on an M1 Pro in one published benchmark) | VideoToolbox has no preset ladder. With the speed/quality hint left unset, Apple says the HEVC hardware encoder favors quality and the ProRes hardware encoder favors speed. |
| -prio_speed 0 (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = false) | Speed cost not quantified by Apple | Asks the encoder to spend its effort on quality at the given bitrate. This is what Lumora sets for HEVC. For ProRes it reverses the hardware default, which favors speed. |
| -prio_speed 1 (PrioritizeEncodingSpeedOverQuality = true) | Maximum throughput | Lets the encoder skip refinement steps. Good for previews, proxies and dailies. |
| -realtime 1 (kVTCompressionPropertyKey_RealTime = true) | Keeps pace with wall-clock time; no faster | For live capture or streaming. For file export Apple advises false, which lets the encoder run faster or slower than real time. |
| -power_efficient 1 (kVTCompressionPropertyKey_MaximizePowerEfficiency = true) | Speed effect not stated by Apple; minimizes power use and system impact | For background jobs on battery. VideoToolbox may ignore it when realtime is on. |

## Rate control

| Mode | Flags | Notes |
|---|---|---|
| Constant quality (CQ) | -q:v 1-100 (FFmpeg) / kVTCompressionPropertyKey_Quality 0.0-1.0 (API) | The main mode for file export, and the one Lumora uses. FFmpeg divides -q:v by 100, so -q:v 62 becomes Quality 0.62. Apple's general scale is 0.25 low, 0.50 normal, 0.75 high, 1.0 lossless where supported, and the header says some formats treat it as a fixed QP. In FFmpeg it is limited to Apple-silicon Macs; -global_quality reaches the same property without that check. slhck's FFmpeg guide recommends -q:v 45-65 for hevc_videotoolbox (55-65 about VMAF 95-98, 45-50 about VMAF 90-93). The scale is not comparable to x265 CRF. |
| Average bitrate (ABR/VBR) | -b:v <rate> / kVTCompressionPropertyKey_AverageBitRate (AVVideoAverageBitRateKey) | A long-term target that peaks may exceed. FFmpeg's VideoToolbox default is 0, meaning the encoder chooses (low). Only works when frames carry timestamps. Not used for ProRes; FFmpeg skips bitrate for it. |
| Peak-limited VBR | -b:v <avg> -maxrate <peak> / kVTCompressionPropertyKey_DataRateLimits | FFmpeg turns -maxrate into one hard limit of maxrate/8 bytes per 1-second window. -bufsize is not used. Older macOS releases may reject the key for HEVC, in which case FFmpeg ignores the error. |
| Constant bitrate (CBR) | -b:v <rate> -constant_bit_rate 1 / kVTCompressionPropertyKey_ConstantBitRate | macOS 13 or newer. Pads frames to hold the rate. Apple advises against it for general export and meant it for CDNs that demand CBR. Cannot be combined with AverageBitRate or DataRateLimits, and should be paired with ExpectedFrameRate. |
| QP clamps | -qmin <n> -qmax <n> / kVTCompressionPropertyKey_MinAllowedFrameQP, kVTCompressionPropertyKey_MaxAllowedFrameQP | Optional floor and ceiling for frame QP (max from macOS 12, min from macOS 13). Apple warns the encoder may drop frames to satisfy a QP ceiling together with a bitrate. FFmpeg defaults both to -1 (unset). |
| ProRes fixed-rate profiles | -profile:v proxy\|lt\|standard\|hq\|4444\|xq / AVVideoCodecKey ProRes type | ProRes has no rate control. Each profile aims at a target bits-per-frame that scales with frame size and rate; frames come in at or under target. At 1920x1080 29.97: Proxy 45, LT 102, 422 147, HQ 220, 4444 330, 4444 XQ 500 Mb/s. At 3840x2160 30p (the white paper's table row): 182, 410, 589, 884, 1326, 1989 Mb/s (Apple ProRes white paper, April 2022). |

## Recipes

### HEVC HDR10 delivery (FFmpeg)

**Goal:** Small, widely playable HDR10 file from a 10-bit PQ master · **Content:** live action, HDR

```bash
-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -q:v 62 -bf 2 -g 0 -prio_speed 0 -tag:v hvc1
```

setparams tags the frames, because FFmpeg 9.0.2 ignores output -color_primaries/-color_trc. Main10 with p010 avoids banding, -q:v 62 sits inside slhck's recommended 45-65 range, -bf 2 re-enables B-frames that FFmpeg disables by default, -g 0 stops FFmpeg's 12-frame keyframe default, and hvc1 is what Apple's HDR rules use. The wrapper writes no static HDR10 metadata, so use AVAssetWriter or x265 if MaxCLL and mastering data are required.

Sources: [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c), [source](https://slhck.info/video/2017/02/24/vbr-settings.html), [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata), [source](https://ffmpeg.org/ffmpeg-filters.html#setparams)

### HEVC HLG (FFmpeg)

**Goal:** Broadcast-style HLG that degrades gracefully on SDR screens · **Content:** live action, HDR

```bash
-vf setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc:range=tv -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -q:v 62 -bf 2 -g 0 -tag:v hvc1
```

The colr atom and VUI carry BT.2020/HLG/BT.2020 (checked with ffprobe and trace_headers). The wrapper's missing mastering metadata matters less here than for PQ. For Dolby Vision 8.4 on top of HLG, use the AVAssetWriter recipe.

Sources: [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata), [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c), [source](https://ffmpeg.org/ffmpeg-filters.html#setparams)

### HEVC bitrate-capped SDR stream (FFmpeg)

**Goal:** Predictable size and peak for streaming uploads · **Content:** streaming/small size

```bash
-vf setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709 -c:v hevc_videotoolbox -profile:v main -b:v 12M -maxrate 18M -g 48 -bf 2 -tag:v hvc1
```

-b:v sets AverageBitRate, -maxrate becomes a one-second DataRateLimits cap, and -g sets MaxKeyFrameInterval (2 s at 23.976). Works on Intel Macs too, where -q:v is unavailable.

Sources: [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate), [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits), [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c), [source](https://ffmpeg.org/ffmpeg-filters.html#setparams)

### ProRes 422 HQ HDR mezzanine (FFmpeg)

**Goal:** Editable, visually lossless HDR intermediate · **Content:** HDR, live action

```bash
-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v prores_videotoolbox -profile:v hq -pix_fmt p210le -prio_speed 0
```

Apple says 422 HQ has wide adoption across post-production and stays visually lossless over many generations (about 220 Mb/s at 1080p29.97, 884 Mb/s at 2160p30). p210le keeps 10-bit 4:2:2. prio_speed 0 overrides the ProRes hardware's speed-first default, and setparams supplies the PQ tags FFmpeg 9.0.2 would otherwise drop.

Sources: [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf), [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality), [source](https://ffmpeg.org/ffmpeg-filters.html#setparams)

### ProRes 4444 XQ 12-bit archive (FFmpeg)

**Goal:** Highest-quality long-term master · **Content:** archive, HDR, CGI

```bash
-vf setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv -c:v prores_videotoolbox -profile:v xq -pix_fmt p416le -prio_speed 0
```

XQ keeps up to 12 bits per channel at about 500 Mb/s (1080p29.97) or 1989 Mb/s (2160p30); a test encode came out as yuv444p12le. A 16-bit 4:4:4 input avoids truncation. Use ayuv64le instead to keep an alpha channel.

Sources: [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf), [source](https://ffmpeg.org/ffmpeg-filters.html#setparams)

### ProRes Proxy for editing (FFmpeg)

**Goal:** Lightweight full-resolution proxies · **Content:** speed

```bash
-c:v prores_videotoolbox -profile:v proxy -pix_fmt p210le -prio_speed 1
```

Proxy targets about 45 Mb/s at 1080p29.97 for offline editing. Speed priority suits throwaway media.

Sources: [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf)

### Two-engine segment encode on a Max chip (FFmpeg)

**Goal:** Use both encode engines on M-series Max (four on Ultra) for one movie · **Content:** speed

```bash
segment 1: -c:v hevc_videotoolbox -q:v 62 -bf 2 -frames_after 1 ; segment 2: -c:v hevc_videotoolbox -q:v 62 -bf 2 -frames_before 1 (middle segments on Ultra: -frames_before 1 -frames_after 1)
```

Apple lists two video encode engines for M5 Max and four for M5 Ultra. Apple's parallel-encoding setup marks each segment's neighbors with MoreFramesBeforeStart/AfterEnd so the joins stay smooth. Concatenate afterwards with the concat demuxer and -c copy.

Sources: [source](https://www.apple.com/macbook-pro/specs/), [source](https://www.apple.com/mac-studio/specs/), [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit)

### HEVC with alpha (FFmpeg)

**Goal:** Transparent overlays playable in Apple apps · **Content:** CGI, screen content

```bash
-c:v hevc_videotoolbox -pix_fmt bgra -alpha_quality 0.9 -q:v 65 -tag:v hvc1
```

A bgra input plus alpha_quality > 0 switches to HEVC with Alpha. Values near 1.0 keep mattes close to lossless.

Sources: [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c), [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_targetqualityforalpha)

### Lumora HEVC HDR10 export (AVAssetWriter)

**Goal:** What Lumora's ExportEngine sends for an HDR10 HEVC job · **Content:** HDR

```bash
AVVideoCodecKey=.hevc; AVVideoWidthKey/HeightKey=output size; AVVideoColorPropertiesKey={ITU_R_2020, SMPTE_ST_2084_PQ, ITU_R_2020}; AVVideoCompressionPropertiesKey={AVVideoProfileLevelKey=kVTProfileLevel_HEVC_Main10_AutoLevel, kVTCompressionPropertyKey_Quality=job.quality, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality=false, kVTCompressionPropertyKey_MasteringDisplayColorVolume=<24 bytes>, kVTCompressionPropertyKey_ContentLightLevelInfo=<4 bytes>}; pixel buffers 420YpCbCr10BiPlanarVideoRange; expectsMediaDataInRealTime=false
```

Uses Main10, BT.2020/PQ tags and HDR10 static metadata through the VT keys, which the FFmpeg wrapper cannot write. Possible additions: AVVideoExpectedSourceFrameRateKey for high-frame-rate output (Apple asks for it with AutoLevel profiles), segment flags (MoreFramesBeforeStart/AfterEnd, SourceFrameCount) when splitting across engines, and a fallback that drops only the rejected key instead of the whole compression dictionary.

Sources: [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf), [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_masteringdisplaycolorvolume), [source](https://developer.apple.com/documentation/avfoundation/avvideoexpectedsourceframeratekey)

### Dolby Vision 8.4 from HLG (AVAssetWriter)

**Goal:** iPhone-style Dolby Vision 8.4 that falls back to HLG · **Content:** HDR

```bash
AVVideoCodecKey=.hevc; AVVideoColorPropertiesKey={ITU_R_2020, ITU_R_2100_HLG, ITU_R_2020}; AVVideoCompressionPropertiesKey={AVVideoProfileLevelKey=kVTProfileLevel_HEVC_Main10_AutoLevel, kVTCompressionPropertyKey_HDRMetadataInsertionMode=kVTHDRMetadataInsertionMode_Auto, kVTCompressionPropertyKey_PreserveDynamicHDRMetadata=false}; 10-bit x420 buffers carrying kCVImageBufferAmbientViewingEnvironmentKey
```

Apple's guide gives the codec, profile, color and insertion-mode pairs, and says to recompute dynamic metadata when frames change. TN3145 requires the 'amve' ambient viewing box.

Sources: [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf), [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata)

## All options

40 options. Click a flag for details. **HDR** marks options that matter for HDR, wide gamut or 10/12-bit; **Lumora** marks options Lumora sets.

### Input and output

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-profile`](#profile) | main (1) Main Profile; main10 (2) Main10 Profile; main42210 (4) Main 4:2:2 10 Profile; rext (4) Main 4:2:2 10 Profile; numeric range -99 to INT_MAX | -99 | hevc_videotoolbox: picks the HEVC profile. | ✓ | ✓ |
| [`-profile`](#profile) | auto (-99) Automatically determine based on input format; proxy (0) ProRes 422 Proxy; lt (1) ProRes 422 LT; standard (2) ProRes 422; hq (3) ProRes 422 HQ; 4444 (4) ProRes 4444; xq (5) ProRes 4444 XQ; range -99 to 5 | auto | prores_videotoolbox: picks the ProRes flavor, and with it the target data rate and chroma format. | ✓ | ✓ |
| [`AVVideoCodecKey`](#avvideocodeckey) | AVVideoCodecType: .hevc ('hvc1'), .hevcWithAlpha ('muxa'), .proRes422Proxy ('apco'), .proRes422LT ('apcs'), .proRes422 ('apcn'), .proRes422HQ ('apch'), .proRes4444 ('ap4h'), AVVideoCodecTypeAppleProRes4444XQ ('ap4x', macOS 15+), plus H.264/JPEG and ProRes RAW types | required (no default) | AVAssetWriter output-settings key that picks the codec and, for ProRes, the flavor. | ✓ | ✓ |
| [`AVVideoWidthKey`](#avvideowidthkey) | pixels | required (no default) | Output frame width in pixels for AVAssetWriter. |  | ✓ |
| [`AVVideoHeightKey`](#avvideoheightkey) | pixels | required (no default) | Output frame height in pixels for AVAssetWriter. |  | ✓ |
| [`AVVideoProfileLevelKey`](#avvideoprofilelevelkey) | kVTProfileLevel_HEVC_Main_AutoLevel, kVTProfileLevel_HEVC_Main10_AutoLevel, kVTProfileLevel_HEVC_Main42210_AutoLevel (macOS 12.3+), kVTProfileLevel_HEVC_Monochrome_AutoLevel, kVTProfileLevel_HEVC_Monochrome10_AutoLevel | not stated (encoder picks) | Sets the HEVC profile, with the level chosen automatically from size and frame rate. | ✓ | ✓ |
| [`kCVPixelBufferPixelFormatTypeKey`](#kcvpixelbufferpixelformattypekey) | e.g. kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (x420 / p010), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange (x422 / p210), kCVPixelFormatType_4444AYpCbCr16 (y416), 8-bit 420v/BGRA | not stated | Source pixel-buffer attribute on the AVAssetWriterInputPixelBufferAdaptor. | ✓ | ✓ |

### Rate control

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-alpha_quality`](#alpha-quality) | 0 to 1 | 0 | hevc_videotoolbox only: when this is above 0 and the input pixel format has an alpha channel (bgra or ayuv), FFmpeg switches to Apple's HEVC with Alpha codec and sets the alpha plane's target quality. |  |  |
| [`-constant_bit_rate`](#constant-bit-rate) | true/false | false | hevc_videotoolbox only: hands -b:v to VideoToolbox as a strict constant bitrate instead of an average target. |  |  |
| [`AVVideoCompressionPropertiesKey`](#avvideocompressionpropertieskey) | dictionary of AVVideo* compression keys and kVTCompressionPropertyKey_* keys | not stated (encoder defaults) | Dictionary that AVAssetWriter passes through to the VideoToolbox session. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_Quality`](#kvtcompressionpropertykey-quality) | 0.0 to 1.0 (Apple: 0.25 low, 0.50 normal, 0.75 high, 1.0 lossless where supported) | not stated (unset means bitrate or encoder-chosen rate) | Constant-quality target. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_ConstantQualityFactor`](#kvtcompressionpropertykey-constantqualityfactor) | 0.0 (lowest) to 1.0 (highest quality possible) | not stated | New in macOS 27: asks the encoder to hold consistent visual quality at a target factor, with or without bitrate limits. |  | ✓ |
| [`kVTCompressionPropertyKey_AverageBitRate`](#kvtcompressionpropertykey-averagebitrate) | bits per second; 0 = encoder decides | 0 | Long-term average bitrate target. |  | ✓ |
| [`kVTCompressionPropertyKey_DataRateLimits`](#kvtcompressionpropertykey-dataratelimits) | CFArray of alternating [bytes, seconds] pairs; zero, one or two limits | no limits | Hard caps on how many bytes any window of the given length (in decode time) may hold. |  | ✓ |

### Speed and presets

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-realtime`](#realtime) | true/false | false | Tells the encoder whether frames arrive on a live clock. |  | ✓ |
| [`-prio_speed`](#prio-speed) | true/false (auto = leave unset) | auto | Sets the encoder's speed-versus-quality preference. |  | ✓ |
| [`kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`](#kvtcompressionpropertykey-prioritizeencodingspeedoverquality) | true / false / NULL | NULL (HEVC hardware favors quality; ProRes hardware favors speed) | The API key behind -prio_speed: a hint that trades a little quality for encoding speed, or the reverse. |  | ✓ |
| [`expectsMediaDataInRealTime`](#expectsmediadatainrealtime) | true/false | not stated | AVAssetWriterInput property saying whether samples come from a live source. |  | ✓ |

### GOP and keyframes

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-frames_before`](#frames-before) | true/false | false | Tells the encoder that frames from another session will be joined before this one, so it can avoid a data-rate spike or other discontinuity at the seam. |  | ✓ |
| [`-frames_after`](#frames-after) | true/false | false | Tells the encoder that frames from another session will be appended after this one. |  | ✓ |
| [`AVVideoExpectedSourceFrameRateKey`](#avvideoexpectedsourceframeratekey) | frames per second | 0 (unknown) | Tells the encoder the frame rate to expect, so it can configure itself (level, rate control) before the first frame. |  | ✓ |
| [`kVTCompressionPropertyKey_MaxKeyFrameInterval`](#kvtcompressionpropertykey-maxkeyframeinterval) | frames; 0 = encoder chooses, 1 = all keyframes | 0 in VideoToolbox (encoder chooses); FFmpeg passes its generic -g default of 12 | Longest allowed distance between keyframes. |  | ✓ |
| [`kVTCompressionPropertyKey_AllowFrameReordering`](#kvtcompressionpropertykey-allowframereordering) | true/false | true (VideoToolbox); FFmpeg sends false unless -bf > 0 | Allows B-frames (frames coded out of display order). |  | ✓ |

### Psychovisual and tuning

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-spatial_aq`](#spatial-aq) | -1 to 1 | -1 | Controls spatial adaptive quantization, meaning per-block QP changes driven by each frame's local detail. |  |  |

### Color and HDR

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`AVVideoColorPropertiesKey`](#avvideocolorpropertieskey) | dictionary holding AVVideoColorPrimariesKey, AVVideoTransferFunctionKey and AVVideoYCbCrMatrixKey | not stated (tags are inherited or left unspecified when absent) | Dictionary of color tags that AVAssetWriter attaches to the output format description and that VideoToolbox writes into the bitstream VUI and the 'colr' atom. | ✓ | ✓ |
| [`AVVideoColorPrimariesKey`](#avvideocolorprimarieskey) | AVVideoColorPrimaries_ITU_R_709_2, _EBU_3213, _SMPTE_C, _P3_D65, _ITU_R_2020 | not stated | Declares the color primaries (gamut) of the encoded pixels. | ✓ | ✓ |
| [`AVVideoTransferFunctionKey`](#avvideotransferfunctionkey) | AVVideoTransferFunction_ITU_R_709_2, _SMPTE_240M_1995, _SMPTE_ST_2084_PQ, _ITU_R_2100_HLG, _Linear (macOS 13+), _IEC_sRGB (macOS 15+) | not stated | Declares the transfer curve, which is what makes a stream HDR (PQ or HLG) or SDR. | ✓ | ✓ |
| [`AVVideoYCbCrMatrixKey`](#avvideoycbcrmatrixkey) | AVVideoYCbCrMatrix_ITU_R_709_2, _ITU_R_601_4, _SMPTE_240M_1995, _ITU_R_2020 | not stated | Declares the RGB-to-Y'CbCr matrix the pixels were built with, so decoders invert it correctly. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_HDRMetadataInsertionMode`](#kvtcompressionpropertykey-hdrmetadatainsertionmode) | kVTHDRMetadataInsertionMode_None, kVTHDRMetadataInsertionMode_Auto, kVTHDRMetadataInsertionMode_RequestSDRRangePreservation (macOS 26+) | kVTHDRMetadataInsertionMode_Auto | Controls whether VideoToolbox adds HDR metadata on its own. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_PreserveDynamicHDRMetadata`](#kvtcompressionpropertykey-preservedynamichdrmetadata) | true/false | not stated | Decides whether dynamic HDR metadata already attached to the input pixel buffers is kept, or (when false and insertion mode is not None) recomputed from the new pixels. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_MasteringDisplayColorVolume`](#kvtcompressionpropertykey-masteringdisplaycolorvolume) | CFData, 24 bytes, big-endian: G, B, R primaries x/y (units of 0.00002), white point x/y, max then min luminance (units of 0.0001 cd/m2), the HEVC SEI D.2.28 layout | not stated (absent) | HDR10 static metadata describing the mastering monitor. | ✓ | ✓ |
| [`kVTCompressionPropertyKey_ContentLightLevelInfo`](#kvtcompressionpropertykey-contentlightlevelinfo) | CFData, 4 bytes, big-endian: MaxCLL (uint16, nits), MaxFALL (uint16, nits) | not stated (absent) | HDR10 content light level metadata: the brightest pixel (MaxCLL) and brightest frame average (MaxFALL) in the program. | ✓ | ✓ |
| [`kCVImageBufferAmbientViewingEnvironmentKey`](#kcvimagebufferambientviewingenvironmentkey) | CFData, 8 bytes, big-endian, on each CVPixelBuffer: ambient illuminance (32-bit) plus ambient light x/y (16-bit each), the HEVC ambient viewing environment SEI payload | not stated (absent on new buffers) | Pixel-buffer attachment carrying the intended viewing ambience. | ✓ | ✓ |

### Analysis and motion search

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-max_ref_frames`](#max-ref-frames) | 0 to INT_MAX | 0 | Caps how many reference frames the encoder may keep. |  |  |

### Threading and performance

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`-allow_sw`](#allow-sw) | true/false | false | Lets VideoToolbox fall back to Apple's software encoder when no hardware session is available. |  | ✓ |
| [`-require_sw`](#require-sw) | true/false | false | Forces Apple's software encoder by explicitly disabling hardware acceleration in the encoder specification. |  |  |
| [`-power_efficient`](#power-efficient) | -1 to 1 | -1 | 1 asks the encoder to minimize power use and system impact, for example for background jobs. |  |  |
| [`kVTCompressionPropertyKey_SourceFrameCount`](#kvtcompressionpropertykey-sourceframecount) | frames | 0 (unknown) | Number of frames this session will receive, if known. |  | ✓ |
| [`kVTCompressionPropertyKey_RecommendedParallelizationLimit`](#kvtcompressionpropertykey-recommendedparallelizationlimit) | read-only count | not stated (read-only) | Read-only (macOS 14+): how many compression sessions VideoToolbox recommends running in parallel for this configuration. |  | ✓ |

### Logging and statistics

| Flag | Values | Default | What it does | HDR | Lumora |
|---|---|---|---|---|---|
| [`kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`](#kvtcompressionpropertykey-usinghardwareacceleratedvideoencoder) | read-only true/false | not stated (read-only) | Read-only check after session creation: tells you whether VideoToolbox actually picked a hardware encoder. |  | ✓ |

## Options in detail

### Input and output

<a id="profile"></a>

#### `-profile` (also `-profile:v`)

**Type:** enum · **Values:** main (1) Main Profile; main10 (2) Main10 Profile; main42210 (4) Main 4:2:2 10 Profile; rext (4) Main 4:2:2 10 Profile; numeric range -99 to INT_MAX · **Default:** -99 · **HDR-relevant**

hevc_videotoolbox: picks the HEVC profile. Left at -99 (unset), FFmpeg asks for Main10 automatically when the input pixel format is 10-bit and otherwise lets VideoToolbox choose. main42210 and rext are the same value and select the 4:2:2 10-bit range-extension profile.

**Effect:** quality main10 removes 8-bit banding; 4:2:2 keeps chroma detail · speed none · size main42210 is larger than 4:2:0

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `main10 with -pix_fmt p010le` | Apple's Dolby Vision 8.4 constraints (TN3145) require HEVC Main10, and FFmpeg rejects main10 when the input pixel format is not 10-bit (it stops with 'Invalid main10 profile with 8 bit input'). | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |
| archive | `main42210 with -pix_fmt p210le` | Keeps 4:2:2 chroma from camera or ProRes sources. FFmpeg maps it to kVTProfileLevel_HEVC_Main42210_AutoLevel (macOS 12.3+). Hardware support depends on the chip, so check that the encode actually runs in hardware. | [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c) |
| streaming/small size | `main (8-bit SDR only) or main10` | Main is the most compatible profile for SDR. Main10 also works for SDR and avoids banding in gradients, at the cost of older-device support. | [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c) |

**In Lumora:** Not used through FFmpeg. The in-process equivalent AVVideoProfileLevelKey is always kVTProfileLevel_HEVC_Main10_AutoLevel for HEVC (ExportEngine.videoSettings).

**Notes:** Only the HEVC values are shown here; the ProRes encoder has its own -profile entry. FFmpeg logs a warning when main is used with 10-bit input. There is no 12-bit HEVC in VideoToolbox; Lumora uses x265 for 12-bit HEVC.

<a id="profile"></a>

#### `-profile` (also `-profile:v`)

**Type:** enum · **Values:** auto (-99) Automatically determine based on input format; proxy (0) ProRes 422 Proxy; lt (1) ProRes 422 LT; standard (2) ProRes 422; hq (3) ProRes 422 HQ; 4444 (4) ProRes 4444; xq (5) ProRes 4444 XQ; range -99 to 5 · **Default:** auto · **HDR-relevant**

prores_videotoolbox: picks the ProRes flavor, and with it the target data rate and chroma format. In auto mode FFmpeg chooses ProRes 4444 when the input has alpha or full-resolution chroma, and ProRes 422 otherwise. It never picks HQ or XQ on its own.

**Effect:** quality proxy < lt < standard < hq ~ 4444 < xq · speed all real-time on the ProRes engine; higher tiers write more data · size 1080p29.97 targets: 45 / 102 / 147 / 220 / 330 / 500 Mb/s

| For | Value | Why | Source |
|---|---|---|---|
| archive | `xq with -pix_fmt p416le (or ayuv64le with alpha)` | 4444 XQ is Apple's top tier, built to keep the wide dynamic range of camera originals through heavy grading. It holds up to 12 bits per channel, about 500 Mb/s at 1080p29.97. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |
| HDR | `hq (4:2:2 10-bit) or xq (12-bit)` | Apple rates 422 HQ, 4444 and 4444 XQ as virtually never showing visible differences after the first generation, with very high headroom for multi-generation finishing. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |
| CGI | `4444 (or xq) with an alpha pixel format` | Only the 4444 family carries alpha, and the alpha is mathematically lossless up to 16 bits; Apple says alpha typically costs about 10 percent or less in performance. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |
| speed | `proxy` | Offline-edit proxies at full resolution and about 45 Mb/s at 1080p29.97. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |
| streaming/small size | `lt` | About 70 percent of the 422 data rate, for when storage matters but you still need an editable intermediate. For actual delivery use HEVC instead. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |
| live action | `hq` | The widely adopted mastering and broadcast intermediate; visually lossless for 10-bit 4:2:2 sources over many generations. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |

**In Lumora:** Not used through FFmpeg. Lumora selects ProRes through AVVideoCodecKey: proRes422HQ ('apch') with 10-bit 4:2:2 buffers, or 'ap4x' (4444 XQ) with 16-bit 4:4:4 y416 buffers for its 12-bit path. SizeForecaster uses 3.54 bits per pixel per frame for HQ and 8.04 for XQ, which reproduces Apple's 220 and 500 Mb/s 1080p29.97 targets.

**Notes:** This is the ProRes-encoder variant of -profile; values and default differ from hevc_videotoolbox. Data rates scale with pixels and frame rate (for example 3840x2160 at 60p: HQ 1768, XQ 3977 Mb/s). Bitrate options are ignored for ProRes.

<a id="avvideocodeckey"></a>

#### `AVVideoCodecKey` (also `kCMVideoCodecType_*`)

**Type:** enum · **Values:** AVVideoCodecType: .hevc ('hvc1'), .hevcWithAlpha ('muxa'), .proRes422Proxy ('apco'), .proRes422LT ('apcs'), .proRes422 ('apcn'), .proRes422HQ ('apch'), .proRes4444 ('ap4h'), AVVideoCodecTypeAppleProRes4444XQ ('ap4x', macOS 15+), plus H.264/JPEG and ProRes RAW types · **Default:** required (no default) · **HDR-relevant**

AVAssetWriter output-settings key that picks the codec and, for ProRes, the flavor. It also decides which engine runs the job: HEVC goes to the video encode engine(s), ProRes to the ProRes engine(s).

**Effect:** quality codec choice · speed both hardware · size HEVC tens of Mb/s; ProRes hundreds or thousands

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `.hevc ('hvc1')` | Apple's Dolby Vision 8.4 constraints (TN3145) require the hvc1 codec type with Main10; AVVideoCodecTypeHEVC is 'hvc1'. | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |
| archive | `ap4x (ProRes 4444 XQ)` | Highest ProRes tier, up to 12-bit, built for camera originals and heavy grading. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |

**In Lumora:** ExportEngine.videoSettings: .hevc for HEVC, .proRes422HQ for ProRes 422 HQ, and AVVideoCodecType(rawValue: "ap4x") for ProRes 4444 XQ (the named constant AVVideoCodecTypeAppleProRes4444XQ exists from macOS 15).

**Notes:** AVVideoSettings.h lists each codec type with its availability: ProRes 4444 from macOS 10.13, ProRes 422 HQ/LT/Proxy from 10.15, 4444 XQ from 15, ProRes RAW from 26. 'muxa' (HEVC with Alpha) only selects the encoder; the file still uses 'hvc1'. AVAssetWriter.canApply(outputSettings:forMediaType:) checks whether a full settings dictionary is accepted.

<a id="avvideowidthkey"></a>

#### `AVVideoWidthKey`

**Type:** int · **Values:** pixels · **Default:** required (no default)

Output frame width in pixels for AVAssetWriter. It must match the pixel buffers you append, or be a size the encoder can scale to.

**Effect:** quality resolution · speed scales with pixel count · size scales with pixel count

**In Lumora:** Set to the job's output width (ctx.width) for every VideoToolbox export.

**Notes:** HEVC AutoLevel picks the level from size and frame rate. See AVVideoExpectedSourceFrameRateKey.

<a id="avvideoheightkey"></a>

#### `AVVideoHeightKey`

**Type:** int · **Values:** pixels · **Default:** required (no default)

Output frame height in pixels for AVAssetWriter.

**Effect:** quality resolution · speed scales with pixel count · size scales with pixel count

**In Lumora:** Set to ctx.height.

<a id="avvideoprofilelevelkey"></a>

#### `AVVideoProfileLevelKey` (also `kVTCompressionPropertyKey_ProfileLevel`)

**Type:** enum · **Values:** kVTProfileLevel_HEVC_Main_AutoLevel, kVTProfileLevel_HEVC_Main10_AutoLevel, kVTProfileLevel_HEVC_Main42210_AutoLevel (macOS 12.3+), kVTProfileLevel_HEVC_Monochrome_AutoLevel, kVTProfileLevel_HEVC_Monochrome10_AutoLevel · **Default:** not stated (encoder picks) · **HDR-relevant**

Sets the HEVC profile, with the level chosen automatically from size and frame rate. Main10 is what enables 10-bit output.

**Effect:** quality Main10: + no 8-bit banding · speed none · size ≈ same

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `kVTProfileLevel_HEVC_Main10_AutoLevel` | Apple's Dolby Vision guide uses it in the AVAssetWriter example and says the profile must be 10-bit. | [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf) |

**In Lumora:** Always Main10 AutoLevel for HEVC, including SDR exports. MacOptimizer's benchmark and the Storage preview encoder also use Main10.

**Notes:** With an AutoLevel profile Apple says to also set AVVideoExpectedSourceFrameRateKey; otherwise the encoder may pick too low a level and drop frames at high frame rates.

<a id="kcvpixelbufferpixelformattypekey"></a>

#### `kCVPixelBufferPixelFormatTypeKey` (also `-pix_fmt`)

**Type:** enum · **Values:** e.g. kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (x420 / p010), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange (x422 / p210), kCVPixelFormatType_4444AYpCbCr16 (y416), 8-bit 420v/BGRA · **Default:** not stated · **HDR-relevant**

Source pixel-buffer attribute on the AVAssetWriterInputPixelBufferAdaptor. It sets the bit depth and chroma layout that actually reach the encoder, so Main10 or 12-bit ProRes only help if this is deep enough.

**Effect:** quality bit depth and chroma ceiling · speed deeper formats move more memory · size none directly

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `x420 (10-bit 4:2:0 biplanar) for HEVC` | Apple's Dolby Vision guide asks for 10-bit buffers such as x420 when exporting HDR with AVAssetWriter. | [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf) |
| archive | `16-bit 4:4:4 (y416 / FFmpeg p416le or ayuv64le) for ProRes 4444 XQ` | ProRes 4444 XQ holds up to 12 bits per channel, so give it a 16-bit container to avoid truncating before the encoder. | [source](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf) |

**In Lumora:** HEVC: 420YpCbCr10BiPlanarVideoRange. ProRes 422 HQ: 422YpCbCr10BiPlanarVideoRange. ProRes 4444 XQ: 4444AYpCbCr16 (Grade.metal y416 pack). Buffers are Metal-compatible and IOSurface-backed.

**Notes:** FFmpeg pixel formats accepted: hevc_videotoolbox: videotoolbox_vld nv12 yuv420p bgra ayuv p010le p210le; prores_videotoolbox: videotoolbox_vld yuv420p nv12 ayuv64le uyvy422 p010le nv16 p210le p216le nv24 p410le p416le bgra.

### Rate control

<a id="alpha-quality"></a>

#### `-alpha_quality`

**Type:** float · **Values:** 0 to 1 · **Default:** 0 · advanced

hevc_videotoolbox only: when this is above 0 and the input pixel format has an alpha channel (bgra or ayuv), FFmpeg switches to Apple's HEVC with Alpha codec and sets the alpha plane's target quality. Higher values bring alpha closer to lossless and cost more bits.

**Effect:** quality + alpha edge fidelity · speed none · size + grows with value

| For | Value | Why | Source |
|---|---|---|---|
| CGI | `1.0 when the matte must stay nearly lossless` | Apple defines 0.0 as the lowest alpha quality and 1.0 as nearly lossless, and says the alpha encode puts quality ahead of bitrate. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_targetqualityforalpha) |

**Notes:** Maps to kVTCompressionPropertyKey_TargetQualityForAlpha (macOS 10.15+), which only HEVC with Alpha encoders support. It has no effect on 4:2:0/p010 input. For alpha masters, ProRes 4444 is the more interoperable choice. Values between 0 and 1 are a size/quality trade-off with no Apple guidance; test on your own mattes (unverified).

<a id="constant-bit-rate"></a>

#### `-constant_bit_rate`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

hevc_videotoolbox only: hands -b:v to VideoToolbox as a strict constant bitrate instead of an average target. The encoder pads small frames to hold the rate.

**Effect:** quality - wastes bits on easy scenes · speed none · size fixed; usually larger than VBR for the same quality

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `false (true only when a CDN or ingest spec demands CBR)` | Apple says the CBR key is not recommended for general streaming or export and exists for CDNs that need the rate to stay up even in still scenes. Pair it with an expected frame rate. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_constantbitrate) |

**Notes:** Maps to kVTCompressionPropertyKey_ConstantBitRate (macOS 13+). FFmpeg exits with an error when the encoder reports the property unsupported. It cannot be combined with AverageBitRate or DataRateLimits, so do not also pass -maxrate.

<a id="avvideocompressionpropertieskey"></a>

#### `AVVideoCompressionPropertiesKey`

**Type:** string · **Values:** dictionary of AVVideo* compression keys and kVTCompressionPropertyKey_* keys · **Default:** not stated (encoder defaults) · **HDR-relevant**

Dictionary that AVAssetWriter passes through to the VideoToolbox session. It is how an AVFoundation app reaches Quality, bitrate, profile, keyframe and HDR metadata properties.

**Effect:** quality container for the settings · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `include kVTCompressionPropertyKey_HDRMetadataInsertionMode = Auto and a Main10 profile for Dolby Vision 8.4` | Apple's Dolby Vision export guide puts exactly these pairs in this dictionary for AVAssetWriter. | [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf) |

**In Lumora:** Built only when not empty. HEVC gets profile, Quality and the speed hint (plus insertion mode for Dolby Vision 8.4); HDR10 jobs of any codec get mastering display and light level. If writer.canApply fails, Lumora retries with no compression dictionary at all, which also drops Main10 and the HDR10 metadata.

**Notes:** Apple's page says entries here change bit rate, B-frame delivery, I-frame interval and quality, and points to supportedOutputSettingsKeys(for:) for the keys a release supports. AVAssetWriter.canApply(outputSettings:forMediaType:) checks a complete dictionary.

<a id="kvtcompressionpropertykey-quality"></a>

#### `kVTCompressionPropertyKey_Quality` (also `-q:v`, `-global_quality`, `AVVideoQualityKey`)

**Type:** float · **Values:** 0.0 to 1.0 (Apple: 0.25 low, 0.50 normal, 0.75 high, 1.0 lossless where supported) · **Default:** not stated (unset means bitrate or encoder-chosen rate) · **HDR-relevant**

Constant-quality target. Higher values spend more bits for a cleaner picture and the size is not fixed. Apple's header says that for some formats it makes the encoder use a fixed quantizer, so it acts more like constant QP than a perceptual CRF.

**Effect:** quality + with value · speed none (hardware) · size + grows steeply near the top

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `0.45-0.50 (-q:v 45-50)` | slhck's FFmpeg rate-control guide puts -q:v 45-50 at about VMAF 90-93, which it calls good. | [source](https://slhck.info/video/2017/02/24/vbr-settings.html) |
| live action | `0.55-0.65 (-q:v 55-65)` | The same guide reports about VMAF 95-98 in this range and recommends 45-65 overall. | [source](https://slhck.info/video/2017/02/24/vbr-settings.html) |
| speed | `0.50 (-q:v 50)` | An M1 Pro 4K test found -q:v 50 artifact-free on a low-motion clip, while the default (no quality or bitrate) looked hazy. That -q:v 50 file was about 7x larger than x265 CRF 28. | [source](https://yre.jp/en/post/m1mac_h265/) |
| archive | `do not use HEVC hardware; use ProRes 422 HQ/4444 XQ or x265` | The same benchmark judged x265 sharper at a similar size and recommends it for quality-critical archiving. Hardware HEVC needs a much higher rate for the same result. | [source](https://yre.jp/en/post/m1mac_h265/) |

**In Lumora:** Lumora's main HEVC control. Fixed mode uses job.quality (AppModel default 0.8). Target-quality mode searches 0.30-0.96 in steps of 0.02, starting at 0.62 (TargetQualityEncoder.levelRange), and re-encodes chunks with the chosen value (encodeChunkVT). The Storage preview encoder uses 0.6. It is not applied to ProRes. EncodeRecipes describes the media-engine HEVC rung as roughly 15-25% larger than x265 at equal quality.

**Notes:** Apple silicon only through FFmpeg: -q:v exits with an error on Intel, and -global_quality N (divided by 100) skips that check. The scale does not map to x265 CRF. Apple's header says the SuggestedLookAheadFrameCount hint is ignored when Quality is 1.0. Apple's docs do not say the constant-quality restriction is hardware-specific; it comes from a comment in FFmpeg's source. Unverified judgment, no source gives an HDR number: 10-bit PQ material may need a slightly higher value than SDR (for example 0.60-0.70); confirm with an HDR-aware metric. macOS 27 adds kVTCompressionPropertyKey_ConstantQualityFactor, which Apple describes as perceptually consistent quality rather than a fixed QP.

<a id="kvtcompressionpropertykey-constantqualityfactor"></a>

#### `kVTCompressionPropertyKey_ConstantQualityFactor`

**Type:** float · **Values:** 0.0 (lowest) to 1.0 (highest quality possible) · **Default:** not stated · advanced

New in macOS 27: asks the encoder to hold consistent visual quality at a target factor, with or without bitrate limits. Apple contrasts it with kVTCompressionPropertyKey_Quality, which for some formats pins the quantizer to a fixed value.

**Effect:** quality + with value; aims for even perceived quality · speed not stated · size + with value

| For | Value | Why | Source |
|---|---|---|---|
| live action | `try it in place of Quality on macOS 27 when you want CRF-like behavior, and compare with a metric` | Apple designed it for consistent visual quality rather than a fixed QP, and it can be combined with bitrate limits. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_constantqualityfactor) |

**In Lumora:** Not used. Lumora's HEVC path sets kVTCompressionPropertyKey_Quality.

**Notes:** macOS 27.0 SDK only; not exposed by FFmpeg 9.0.2. Which encoders support it, and how its scale lines up with Quality, was not verified.

<a id="kvtcompressionpropertykey-averagebitrate"></a>

#### `kVTCompressionPropertyKey_AverageBitRate` (also `AVVideoAverageBitRateKey`, `-b:v`)

**Type:** int · **Values:** bits per second; 0 = encoder decides · **Default:** 0

Long-term average bitrate target. Peaks may exceed it. Use it instead of Quality when the output size matters more than consistent quality.

**Effect:** quality follows the budget · speed none · size predictable

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `a bitrate from your delivery spec, plus -maxrate for a ceiling` | Apple calls it a soft target that only works when frames carry timing. Pair it with DataRateLimits for a hard peak. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate) |

**In Lumora:** Not used. Lumora runs HEVC in Quality mode only.

**Notes:** FFmpeg sets it from -b:v (VideoToolbox default 0) for HEVC, but never for ProRes.

<a id="kvtcompressionpropertykey-dataratelimits"></a>

#### `kVTCompressionPropertyKey_DataRateLimits` (also `-maxrate`)

**Type:** list · **Values:** CFArray of alternating [bytes, seconds] pairs; zero, one or two limits · **Default:** no limits · advanced

Hard caps on how many bytes any window of the given length (in decode time) may hold. Used to keep peaks within a player's or network's capacity.

**Effect:** quality - in complex scenes when the cap binds · speed none · size caps peaks

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `-maxrate above -b:v; the ratio comes from your delivery spec` | Apple describes each limit as a hard cap on bytes over any window of the given duration, in decode time. FFmpeg turns -maxrate into one limit of maxrate/8 bytes per 1-second window. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits) |

**In Lumora:** Not used.

**Notes:** Some codecs ignore it. FFmpeg ignores a failure for HEVC because older OS releases lacked support. Apple's SDK header adds that an average target set too close to the hard limit tends to undershoot. The common 1.5x maxrate-to-bitrate ratio is practice, not an Apple figure (unverified).

### Speed and presets

<a id="realtime"></a>

#### `-realtime`

**Type:** bool · **Values:** true/false · **Default:** false

Tells the encoder whether frames arrive on a live clock. When true, it aims to keep up with real time and may save energy, but does not try to run faster. When false, it may run slower or faster than real time as needed.

**Effect:** quality ± true may trade quality to keep pace · speed true caps useful speed at real time · size none

| For | Value | Why | Source |
|---|---|---|---|
| archive | `false` | Apple advises false for offline compression, which frees the encoder from wall-clock pacing. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_realtime) |
| streaming/small size | `true (live capture or live streaming only)` | For a live source Apple advises true, so encoding stays on schedule. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_realtime) |

**In Lumora:** Not set on the session. Lumora sets the related AVAssetWriterInput.expectsMediaDataInRealTime = false.

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_RealTime. FFmpeg always sends the value, so the default sends false rather than leaving it unknown, which is VideoToolbox's own default.

<a id="prio-speed"></a>

#### `-prio_speed`

**Type:** bool · **Values:** true/false (auto = leave unset) · **Default:** auto

Sets the encoder's speed-versus-quality preference. 1 lets it cut refinement steps to go faster; 0 asks it to maximize quality at the given bitrate. Auto leaves the choice to VideoToolbox.

**Effect:** quality 0: + (marginal); 1: - · speed 1: +; 0: - · size none at fixed bitrate; ± in quality mode

| For | Value | Why | Source |
|---|---|---|---|
| archive | `0` | Apple notes that the ProRes hardware encoders favor speed by default, so you must ask for quality explicitly. HEVC already favors quality, so 0 there mostly pins the behavior. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality) |
| speed | `1` | Allows the encoder to give up marginal quality for throughput, which is fine for previews and proxies. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality) |

**In Lumora:** Lumora sets kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = false for HEVC only. ProRes exports leave it unset and so run with the speed-first hardware default.

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality (macOS 11+). FFmpeg only warns if it is unsupported. The default behaviors per codec come from the SDK header (VTCompressionProperties.h); the web page carries only the summary. Apple does not quantify the quality difference.

<a id="kvtcompressionpropertykey-prioritizeencodingspeedoverquality"></a>

#### `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` (also `-prio_speed`)

**Type:** bool · **Values:** true / false / NULL · **Default:** NULL (HEVC hardware favors quality; ProRes hardware favors speed)

The API key behind -prio_speed: a hint that trades a little quality for encoding speed, or the reverse.

**Effect:** quality false: + marginal · speed true: + · size none at fixed rate

| For | Value | Why | Source |
|---|---|---|---|
| archive | `false (also for ProRes)` | Apple's header says ProRes hardware currently defaults to speed. Requesting quality explicitly is the only way to get its best output. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality) |

**In Lumora:** false for HEVC. Not set for ProRes 422 HQ or 4444 XQ, even though both are labeled master or archive formats in Lumora.

**Notes:** macOS 11+. Not every encoder supports it.

<a id="expectsmediadatainrealtime"></a>

#### `expectsMediaDataInRealTime` (also `AVAssetWriterInput.expectsMediaDataInRealTime`)

**Type:** bool · **Values:** true/false · **Default:** not stated

AVAssetWriterInput property saying whether samples come from a live source. When true the writer tunes its readiness signaling for live capture. It cannot change once writing starts.

**Effect:** quality none · speed false suits offline throughput · size none

| For | Value | Why | Source |
|---|---|---|---|
| archive | `false` | Apple reserves true for real-time sources such as capture output. File transcodes should leave it false. | [source](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/expectsmediadatainrealtime) |

**In Lumora:** Set to false for every VideoToolbox writer (full export and target-quality chunks).

**Notes:** Not a VideoToolbox key, but it decides how AVAssetWriter feeds the session. Apple also advises against setting it together with performsMultiPassEncodingIfSupported.

### GOP and keyframes

<a id="frames-before"></a>

#### `-frames_before`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Tells the encoder that frames from another session will be joined before this one, so it can avoid a data-rate spike or other discontinuity at the seam. Set it on every segment except the first in a split-and-concatenate encode.

**Effect:** quality + smoother joins · speed none · size ± smoother rate at seams

| For | Value | Why | Source |
|---|---|---|---|
| speed | `true on segments 2..N of a parallel segment encode` | Apple's parallel-encoding recipe sets MoreFramesBeforeStart on every session but the first, together with MoreFramesAfterEnd and SourceFrameCount. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit) |

**In Lumora:** Not set. Lumora splits long HEVC/ProRes jobs into one segment per encode engine (ChipProfile.segments) but does not mark the segments with MoreFramesBeforeStart/AfterEnd, so the seams are encoded as stand-alone files.

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_MoreFramesBeforeStart. FFmpeg only warns if the device does not support it. Of little use for intra-only ProRes.

<a id="frames-after"></a>

#### `-frames_after`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Tells the encoder that frames from another session will be appended after this one. Set it on every segment except the last in a split-and-concatenate encode.

**Effect:** quality + smoother joins · speed none · size ± smoother rate at seams

| For | Value | Why | Source |
|---|---|---|---|
| speed | `true on segments 1..N-1 of a parallel segment encode` | Apple's parallel-encoding example sets MoreFramesAfterEnd on every session except the last. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit) |

**In Lumora:** Not set (see -frames_before).

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_MoreFramesAfterEnd.

<a id="avvideoexpectedsourceframeratekey"></a>

#### `AVVideoExpectedSourceFrameRateKey` (also `kVTCompressionPropertyKey_ExpectedFrameRate`)

**Type:** float · **Values:** frames per second · **Default:** 0 (unknown)

Tells the encoder the frame rate to expect, so it can configure itself (level, rate control) before the first frame. It is a hint and does not change timing.

**Effect:** quality + avoids frame drops and bad level choice · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| fast motion | `the real output rate (e.g. 59.94, 120)` | Apple says to set it with an AutoLevel profile or above 30 fps, or the encoder may drop frames to stay within the bitstream limits. | [source](https://developer.apple.com/documentation/avfoundation/avvideoexpectedsourceframeratekey) |

**In Lumora:** Not set, although Lumora uses Main10 AutoLevel and its frame interpolation often produces 48-120 fps output. That is exactly the case Apple warns about.

**Notes:** FFmpeg does not expose it as a private option. Apple also asks for it alongside ConstantBitRate.

<a id="kvtcompressionpropertykey-maxkeyframeinterval"></a>

#### `kVTCompressionPropertyKey_MaxKeyFrameInterval` (also `AVVideoMaxKeyFrameIntervalKey`, `-g`)

**Type:** int · **Values:** frames; 0 = encoder chooses, 1 = all keyframes · **Default:** 0 in VideoToolbox (encoder chooses); FFmpeg passes its generic -g default of 12

Longest allowed distance between keyframes. The encoder may still insert keyframes sooner when that compresses better.

**Effect:** quality shorter GOP: - at a fixed rate · speed none · size shorter GOP: +

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `-g 0 to let VideoToolbox choose, or a frame count that matches your segment length` | Apple's 0 means the encoder places keyframes, and the key can be combined with MaxKeyFrameIntervalDuration, whichever limit comes first. In a 9.0.2 test, -g 0 gave keyframes every 30 frames at 24 fps, while the default gave one every 12. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxkeyframeinterval) |

**In Lumora:** Not set. Keyframe placement is left to VideoToolbox.

**Notes:** FFmpeg sets it from -g for HEVC (gop_size > 0) and never for ProRes. A 2-second interval (48 at 23.976) is common streaming practice, not an Apple number (unverified).

<a id="kvtcompressionpropertykey-allowframereordering"></a>

#### `kVTCompressionPropertyKey_AllowFrameReordering` (also `AVVideoAllowFrameReorderingKey`, `-bf`)

**Type:** bool · **Values:** true/false · **Default:** true (VideoToolbox); FFmpeg sends false unless -bf > 0

Allows B-frames (frames coded out of display order). Turning it off lowers latency and hurts compression efficiency.

**Effect:** quality + at fixed bitrate when on · speed none · size - when on

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `on (FFmpeg: -bf 2)` | FFmpeg's wrapper sends AllowFrameReordering=false whenever -bf is 0, which is FFmpeg's generic default, so B-frames must be requested explicitly. | [source](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c) |

**In Lumora:** Not set, so AVAssetWriter's default reordering applies.

**Notes:** Any -bf > 0 just turns reordering on; VideoToolbox chooses the B-frame structure itself. Not applicable to ProRes.

### Psychovisual and tuning

<a id="spatial-aq"></a>

#### `-spatial_aq`

**Type:** int · **Values:** -1 to 1 · **Default:** -1 · advanced

Controls spatial adaptive quantization, meaning per-block QP changes driven by each frame's local detail. 1 allows it (the rate controller picks the strength), 0 disables it, and -1 leaves the encoder default.

**Effect:** quality ± perceptual gain in flat areas is typical of AQ; usually lowers PSNR · speed none · size none at fixed rate

| For | Value | Why | Source |
|---|---|---|---|
| live action | `-1 (encoder default)` | Apple exposes only on or off, with strength chosen internally, and gives no tuning guidance. Keep the default unless a test on your own content shows a gain. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_spatialadaptiveqplevel) |

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_SpatialAdaptiveQPLevel (macOS 15+; codec dependent). FFmpeg sends kVTQPModulationLevel_Default for 1 and kVTQPModulationLevel_Disable for 0. Apple requires it to be off when low-latency rate control is on. Probably meaningless for ProRes (not verified). The AQ effects listed are the general behavior of AQ, not measured on VideoToolbox.

### Color and HDR

<a id="avvideocolorpropertieskey"></a>

#### `AVVideoColorPropertiesKey` (also `kVTCompressionPropertyKey_ColorPrimaries`, `kVTCompressionPropertyKey_TransferFunction`, `kVTCompressionPropertyKey_YCbCrMatrix`)

**Type:** string · **Values:** dictionary holding AVVideoColorPrimariesKey, AVVideoTransferFunctionKey and AVVideoYCbCrMatrixKey · **Default:** not stated (tags are inherited or left unspecified when absent) · **HDR-relevant**

Dictionary of color tags that AVAssetWriter attaches to the output format description and that VideoToolbox writes into the bitstream VUI and the 'colr' atom. Apple requires all three keys when the dictionary is present.

**Effect:** quality correct display; no change to the pixels · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `ITU_R_2020 / SMPTE_ST_2084_PQ / ITU_R_2020 (HDR10) or ITU_R_2020 / ITU_R_2100_HLG / ITU_R_2020 (HLG)` | TN3145 requires a colr atom with primaries 9 (BT.2020), transfer 18 (HLG) and matrix 9 (BT.2020) for Dolby Vision 8.4. HDR10 uses the same primaries and matrix with the PQ transfer (AVVideoTransferFunction_SMPTE_ST_2084_PQ). | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |

**In Lumora:** Always set. HDR10: 2020/PQ/2020; HLG: 2020/HLG/2020; SDR: 709/709/709 (ExportEngine.videoSettings).

**Notes:** If an encoder enforces its own colorimetry, the matching VT properties are read-only. FFmpeg's wrappers set the same VT properties from -color_primaries, -color_trc and -colorspace.

<a id="avvideocolorprimarieskey"></a>

#### `AVVideoColorPrimariesKey` (also `kVTCompressionPropertyKey_ColorPrimaries`)

**Type:** enum · **Values:** AVVideoColorPrimaries_ITU_R_709_2, _EBU_3213, _SMPTE_C, _P3_D65, _ITU_R_2020 · **Default:** not stated · **HDR-relevant**

Declares the color primaries (gamut) of the encoded pixels. It does not convert anything; your pixels must already be in that gamut.

**Effect:** quality wrong tag means wrong colors on playback · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `AVVideoColorPrimaries_ITU_R_2020` | Dolby Vision 8.4 requires colr primaries 9 (BT.2020) per TN3145; HDR10 and HLG deliveries normally signal the same BT.2020 container gamut. | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |

**In Lumora:** ITU_R_2020 for HDR10 and HLG; ITU_R_709_2 for SDR.

**Notes:** P3_D65 with HLG is a valid Apple combination (the AVVideoSettings.h examples list it), but most TVs expect BT.2020.

<a id="avvideotransferfunctionkey"></a>

#### `AVVideoTransferFunctionKey` (also `kVTCompressionPropertyKey_TransferFunction`)

**Type:** enum · **Values:** AVVideoTransferFunction_ITU_R_709_2, _SMPTE_240M_1995, _SMPTE_ST_2084_PQ, _ITU_R_2100_HLG, _Linear (macOS 13+), _IEC_sRGB (macOS 15+) · **Default:** not stated · **HDR-relevant**

Declares the transfer curve, which is what makes a stream HDR (PQ or HLG) or SDR. With HDRMetadataInsertionMode it also determines which HDR metadata VideoToolbox will insert.

**Effect:** quality wrong tag means wrong brightness or contrast · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `SMPTE_ST_2084_PQ for HDR10; ITU_R_2100_HLG for HLG and Dolby Vision 8.4` | Dolby Vision 8.4 is HLG-based: its colr atom must carry transfer 18 (HLG). | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |

**In Lumora:** SMPTE_ST_2084_PQ for HDR10, ITU_R_2100_HLG for HLG (including Dolby Vision 8.4), ITU_R_709_2 for SDR.

**Notes:** The macOS 27 SDK adds AVVideoLogTransferFunction_AppleLog/AppleLog2 under a separate log key.

<a id="avvideoycbcrmatrixkey"></a>

#### `AVVideoYCbCrMatrixKey` (also `kVTCompressionPropertyKey_YCbCrMatrix`)

**Type:** enum · **Values:** AVVideoYCbCrMatrix_ITU_R_709_2, _ITU_R_601_4, _SMPTE_240M_1995, _ITU_R_2020 · **Default:** not stated · **HDR-relevant**

Declares the RGB-to-Y'CbCr matrix the pixels were built with, so decoders invert it correctly.

**Effect:** quality a mismatch shifts hues and saturation · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `AVVideoYCbCrMatrix_ITU_R_2020` | TN3145 requires matrix 9 (BT.2020 non-constant luminance) in the colr atom for Dolby Vision 8.4. | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |

**In Lumora:** ITU_R_2020 for HDR, ITU_R_709_2 for SDR. Lumora's Metal pack shaders use the same Kr/Kb (ctx.kr/ctx.kb) when converting RGB to Y'CbCr, so the tag matches the pixels.

**Notes:** This tag only describes the pixels. If it does not match the shader's actual math, the error stays in the file.

<a id="kvtcompressionpropertykey-hdrmetadatainsertionmode"></a>

#### `kVTCompressionPropertyKey_HDRMetadataInsertionMode`

**Type:** enum · **Values:** kVTHDRMetadataInsertionMode_None, kVTHDRMetadataInsertionMode_Auto, kVTHDRMetadataInsertionMode_RequestSDRRangePreservation (macOS 26+) · **Default:** kVTHDRMetadataInsertionMode_Auto · **HDR-relevant** · advanced

Controls whether VideoToolbox adds HDR metadata on its own. None writes no HDR metadata. Auto lets it choose what to insert from the output color space, such as Dolby Vision or HDR10. RequestSDRRangePreservation only acts on PQ + BT.2020 streams.

**Effect:** quality affects display mapping only · speed none · size tiny

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `kVTHDRMetadataInsertionMode_Auto with HLG tags and Main10 (Dolby Vision 8.4)` | Apple's Dolby Vision guide says AVAssetWriter needs this pair, 10-bit buffers such as x420, and HLG/BT.2020 color properties to produce Dolby Vision 8.4. | [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf) |

**In Lumora:** Set to Auto only for the Dolby Vision 8.4 delivery. Because Auto is already the default, plain HLG exports run in the same mode and may also gain Dolby Vision 8.4 metadata (not verified).

**Notes:** macOS 11+. It does nothing for SDR output or for formats VideoToolbox cannot generate. Apple's web page has no discussion; the behavior described here comes from the macOS 27 SDK header.

<a id="kvtcompressionpropertykey-preservedynamichdrmetadata"></a>

#### `kVTCompressionPropertyKey_PreserveDynamicHDRMetadata`

**Type:** bool · **Values:** true/false · **Default:** not stated · **HDR-relevant** · advanced

Decides whether dynamic HDR metadata already attached to the input pixel buffers is kept, or (when false and insertion mode is not None) recomputed from the new pixels.

**Effect:** quality accurate tone-mapping metadata after edits · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `false whenever frames were modified (graded, scaled, interpolated)` | Apple's Dolby Vision guide says to set it false so the writer recomputes Dolby Vision 8.4 metadata whenever the app changes the frames. | [source](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf) |

**In Lumora:** Not set. Lumora renders brand-new Metal pixel buffers, so there is no input metadata to keep. Setting false would make the recompute explicit.

**Notes:** macOS 11+. Write-only.

<a id="kvtcompressionpropertykey-masteringdisplaycolorvolume"></a>

#### `kVTCompressionPropertyKey_MasteringDisplayColorVolume` (also `kCMFormatDescriptionExtension_MasteringDisplayColorVolume`)

**Type:** string · **Values:** CFData, 24 bytes, big-endian: G, B, R primaries x/y (units of 0.00002), white point x/y, max then min luminance (units of 0.0001 cd/m2), the HEVC SEI D.2.28 layout · **Default:** not stated (absent) · **HDR-relevant**

HDR10 static metadata describing the mastering monitor. VideoToolbox stores it on the output format description and writes the matching SEI where the codec supports it.

**Effect:** quality drives TV tone mapping · speed none · size tiny

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `the real grading display, e.g. P3-D65 primaries, 1000 or 4000 nit max, 0.005 nit min` | Apple defines the payload as the 24-byte HEVC mastering display SEI structure. Wrong primaries or luminance mislead TV tone mapping. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_masteringdisplaycolorvolume) |

**In Lumora:** Set for every HDR10 job (HEVC and ProRes) from HDRMetadata.vtMasteringDisplay: P3-D65 primaries (G 13250/34500, B 7500/3000, R 34000/16000, WP 15635/16450), max = target peak x 10000, min 0.005 nit. Byte order and units match the SEI layout.

**Notes:** macOS 10.13+. The FFmpeg wrapper has no way to set this.

<a id="kvtcompressionpropertykey-contentlightlevelinfo"></a>

#### `kVTCompressionPropertyKey_ContentLightLevelInfo` (also `kCMFormatDescriptionExtension_ContentLightLevelInfo`)

**Type:** string · **Values:** CFData, 4 bytes, big-endian: MaxCLL (uint16, nits), MaxFALL (uint16, nits) · **Default:** not stated (absent) · **HDR-relevant**

HDR10 content light level metadata: the brightest pixel (MaxCLL) and brightest frame average (MaxFALL) in the program.

**Effect:** quality helps TVs tone-map without clipping · speed none · size tiny

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `values measured from the final graded frames` | Apple defines the payload as the Content Light Level Info SEI; inaccurate values push TVs into needless dimming or clipping. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_contentlightlevelinfo) |

**In Lumora:** Set for HDR10 jobs from measured levels (ctx.meta maxCLL/maxFALL, clamped to 65535). It falls back to 0/0, meaning unknown, when there is no measurement.

**Notes:** macOS 10.13+. Not reachable from the FFmpeg wrapper.

<a id="kcvimagebufferambientviewingenvironmentkey"></a>

#### `kCVImageBufferAmbientViewingEnvironmentKey` (also `kCMFormatDescriptionExtension_AmbientViewingEnvironment`, `amve`)

**Type:** string · **Values:** CFData, 8 bytes, big-endian, on each CVPixelBuffer: ambient illuminance (32-bit) plus ambient light x/y (16-bit each), the HEVC ambient viewing environment SEI payload · **Default:** not stated (absent on new buffers) · **HDR-relevant** · advanced

Pixel-buffer attachment carrying the intended viewing ambience. Apple players use it for HLG and Dolby Vision 8.4. Missing it can make HDR look too bright on Apple devices.

**Effect:** quality correct brightness on Apple devices · speed none · size tiny

| For | Value | Why | Source |
|---|---|---|---|
| HDR | `copy the source's amve onto newly rendered buffers for Dolby Vision 8.4 / HLG` | TN3145 makes 'amve' mandatory for Dolby Vision 8.4 and says apps that create new pixel buffers must carry it over themselves. | [source](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata) |

**In Lumora:** Not attached. Lumora's Dolby Vision 8.4 path renders fresh buffers in Metal and does not copy any ambient viewing environment onto them.

**Notes:** CoreVideo key, macOS 12+. Listed because Apple's Dolby Vision 8.4 output depends on it.

### Analysis and motion search

<a id="max-ref-frames"></a>

#### `-max_ref_frames`

**Type:** int · **Values:** 0 to INT_MAX · **Default:** 0 · advanced

Caps how many reference frames the encoder may keep. It only matters when it is below what the profile and level already allow. 0 means no cap.

**Effect:** quality - lower values reduce prediction options · speed none to slight + · size + lower values can grow files

| For | Value | Why | Source |
|---|---|---|---|
| streaming/small size | `0 (no cap) unless a target decoder has a DPB limit` | Apple describes the key as a way to force fewer references than the standard allows, and the encoder errors if the request exceeds the profile/level limit. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_referencebuffercount) |

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_ReferenceBufferCount (macOS 13+). No effect for intra-only ProRes.

### Threading and performance

<a id="allow-sw"></a>

#### `-allow_sw`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Lets VideoToolbox fall back to Apple's software encoder when no hardware session is available. With the default (false), FFmpeg requires hardware and fails if none can be created.

**Effect:** quality software path may differ; not documented · speed - much slower when the fallback happens · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `false` | Requiring hardware makes a busy or unsupported configuration fail loudly instead of quietly running in slow software. Apple lists busy encode resources as one reason hardware can be unavailable. | [source](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder) |

**In Lumora:** Not used. AVAssetWriter chooses the encoder itself; Lumora does not pass an encoder specification.

**Notes:** Shared by hevc_videotoolbox and prores_videotoolbox. Default false sets kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder; true sets EnableHardwareAcceleratedVideoEncoder instead. Useful when many parallel sessions might exceed the engine count.

<a id="require-sw"></a>

#### `-require_sw`

**Type:** bool · **Values:** true/false · **Default:** false · advanced

Forces Apple's software encoder by explicitly disabling hardware acceleration in the encoder specification.

**Effect:** quality different encoder implementation · speed - far slower · size varies

**Notes:** Shared by both encoders. It takes priority over -allow_sw: FFmpeg sets EnableHardwareAcceleratedVideoEncoder = false in the encoder specification. Mostly for debugging or comparing against hardware output. Whether every ProRes flavor has a software encoder was not verified.

<a id="power-efficient"></a>

#### `-power_efficient`

**Type:** int · **Values:** -1 to 1 · **Default:** -1 · advanced

1 asks the encoder to minimize power use and system impact, for example for background jobs. 0 turns that off; -1 leaves it unset.

**Effect:** quality unspecified · speed not stated by Apple · size unspecified

| For | Value | Why | Source |
|---|---|---|---|
| speed | `-1 (leave unset)` | Apple frames this as a background-work hint, and null behaves like false, so a foreground export gains nothing from it. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maximizepowerefficiency) |

**Notes:** Shared by both encoders. Maps to kVTCompressionPropertyKey_MaximizePowerEfficiency (macOS 10.14+). Not every encoder supports it, and it may be ignored when RealTime is true.

<a id="kvtcompressionpropertykey-sourceframecount"></a>

#### `kVTCompressionPropertyKey_SourceFrameCount`

**Type:** int · **Values:** frames · **Default:** 0 (unknown) · advanced

Number of frames this session will receive, if known. Apple's parallel-encoding recipe sets it on each segment's session along with MoreFramesBeforeStart and MoreFramesAfterEnd.

**Effect:** quality + helps rate planning per segment · speed none · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `the segment's exact frame count when splitting across engines` | It is part of Apple's documented setup for running several compression sessions in parallel on one movie. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit) |

**In Lumora:** Not set.

**Notes:** The parallel-encoding example is in the macOS SDK header under RecommendedParallelizationLimit.

<a id="kvtcompressionpropertykey-recommendedparallelizationlimit"></a>

#### `kVTCompressionPropertyKey_RecommendedParallelizationLimit`

**Type:** int · **Values:** read-only count · **Default:** not stated (read-only) · advanced

Read-only (macOS 14+): how many compression sessions VideoToolbox recommends running in parallel for this configuration. It is the official way to learn how many engines a Max or Ultra chip can use for one movie.

**Effect:** quality none · speed + up to the engine count · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `query it; run that many segment sessions (Max: 2 engines, Ultra: 4)` | Apple lists two video encode engines and two ProRes engines for M5 Max and four of each for M5 Ultra. A single session is not documented to span engines, so parallel sessions are how you fill them. | [source](https://www.apple.com/mac-studio/specs/) |
| speed | `keep each segment at or above the recommended minimum frame count and duration` | Apple exposes a recommended minimum frame count (and duration) per parallel subdivision and says that, for best results, each subdivision should be at least that long. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizedsubdivisionminimumframecount) |

**In Lumora:** Not queried. ChipProfile.videoEncodeEngines assumes 1 (base/Pro), 2 (Max) or 4 (Ultra), or uses MacOptimizer's measured vtSessions (it adds parallel 4K HEVC sessions until throughput stops growing 8%). It then splits HEVC and ProRes jobs into that many segments.

**Notes:** Engine counts from Apple: M1 Max has two ProRes accelerators and about 2x M1 Pro's encode speed; M1 Ultra has double M1 Max's media engine; M5 Pro has 1 encode + 1 ProRes engine; M5 Max has 2 + 2; M5 Ultra has 4 + 4. Users report that some apps feed only one engine; this was not verified here.

### Logging and statistics

<a id="kvtcompressionpropertykey-usinghardwareacceleratedvideoencoder"></a>

#### `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`

**Type:** bool · **Values:** read-only true/false · **Default:** not stated (read-only) · advanced

Read-only check after session creation: tells you whether VideoToolbox actually picked a hardware encoder.

**Effect:** quality none · speed diagnostic · size none

| For | Value | Why | Source |
|---|---|---|---|
| speed | `assert true after creating each parallel session` | Apple says to query it once hardware encode is enabled. When engines are busy the session may otherwise run in software. | [source](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder) |

**In Lumora:** Not queried. AVAssetWriter does not expose the session, so Lumora relies on its measured throughput instead.

**Notes:** FFmpeg logs the chosen encoder ID only at -loglevel debug ('Init the encoder: ...', from vt_dump_encoder).

## Sources

- [VideoToolbox framework documentation (Apple)](https://developer.apple.com/documentation/videotoolbox)
- [kVTCompressionPropertyKey_Quality (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_quality)
- [kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality)
- [kVTCompressionPropertyKey_HDRMetadataInsertionMode (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_hdrmetadatainsertionmode)
- [kVTCompressionPropertyKey_PreserveDynamicHDRMetadata (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_preservedynamichdrmetadata)
- [kVTCompressionPropertyKey_MasteringDisplayColorVolume (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_masteringdisplaycolorvolume)
- [kVTCompressionPropertyKey_ContentLightLevelInfo (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_contentlightlevelinfo)
- [kVTCompressionPropertyKey_ConstantBitRate (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_constantbitrate)
- [kVTCompressionPropertyKey_AverageBitRate (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate)
- [kVTCompressionPropertyKey_DataRateLimits (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits)
- [kVTCompressionPropertyKey_RealTime (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_realtime)
- [kVTCompressionPropertyKey_MaximizePowerEfficiency (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maximizepowerefficiency)
- [kVTCompressionPropertyKey_SpatialAdaptiveQPLevel (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_spatialadaptiveqplevel)
- [kVTCompressionPropertyKey_ReferenceBufferCount (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_referencebuffercount)
- [kVTCompressionPropertyKey_TargetQualityForAlpha (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_targetqualityforalpha)
- [kVTCompressionPropertyKey_MoreFramesBeforeStart (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_moreframesbeforestart)
- [kVTCompressionPropertyKey_MoreFramesAfterEnd (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_moreframesafterend)
- [kVTCompressionPropertyKey_SourceFrameCount (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_sourceframecount)
- [kVTCompressionPropertyKey_RecommendedParallelizationLimit (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizationlimit)
- [kVTCompressionPropertyKey_MaxKeyFrameInterval (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxkeyframeinterval)
- [kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder)
- [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder)
- [AVVideoExpectedSourceFrameRateKey (Apple)](https://developer.apple.com/documentation/avfoundation/avvideoexpectedsourceframeratekey)
- [AVVideoColorPropertiesKey (Apple)](https://developer.apple.com/documentation/avfoundation/avvideocolorpropertieskey)
- [AVVideoCompressionPropertiesKey (Apple)](https://developer.apple.com/documentation/avfoundation/avvideocompressionpropertieskey)
- [AVAssetWriterInput.expectsMediaDataInRealTime (Apple)](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/expectsmediadatainrealtime)
- [TN3145: HDR video metadata (Apple)](https://developer.apple.com/documentation/technotes/tn3145-hdr-video-metadata)
- [Incorporating HDR video with Dolby Vision into your apps (Apple)](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
- [Apple ProRes White Paper, April 2022 (Apple)](https://www.apple.com/final-cut-pro/docs/Apple_ProRes.pdf)
- [MacBook Pro tech specs: media engine per chip (Apple)](https://www.apple.com/macbook-pro/specs/)
- [Mac Studio tech specs: M5 Max / M5 Ultra media engines (Apple)](https://www.apple.com/mac-studio/specs/)
- [Introducing M1 Pro and M1 Max (Apple Newsroom)](https://www.apple.com/newsroom/2021/10/introducing-m1-pro-and-m1-max-the-most-powerful-chips-apple-has-ever-built/)
- [Apple unveils M1 Ultra (Apple Newsroom)](https://www.apple.com/newsroom/2022/03/apple-unveils-m1-ultra-the-worlds-most-powerful-chip-for-a-personal-computer/)
- [Apple debuts M5 Pro and M5 Max (Apple Newsroom)](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/)
- [FFmpeg libavcodec/videotoolboxenc.c at tag n9.0.2 (source of hevc_videotoolbox / prores_videotoolbox)](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/videotoolboxenc.c)
- [FFmpeg VBR / quality settings guide (slhck)](https://slhck.info/video/2017/02/24/vbr-settings.html)
- [M1 Pro H.265 hardware encoding: videotoolbox vs libx265 benchmark](https://yre.jp/en/post/m1mac_h265/)
- [HandBrake documentation: Apple VideoToolbox](https://handbrake.fr/docs/en/latest/technical/video-videotoolbox.html)
- [Hardware accelerated video encoding on Apple Silicon with FFmpeg (CodeTV)](https://codetv.dev/blog/hardware-acceleration-ffmpeg-apple-silicon)
- [kVTCompressionPropertyKey_RecommendedParallelizedSubdivisionMinimumFrameCount (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_recommendedparallelizedsubdivisionminimumframecount)
- [kVTCompressionPropertyKey_ConstantQualityFactor (Apple)](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_constantqualityfactor)
- [FFmpeg filters documentation: setparams](https://ffmpeg.org/ffmpeg-filters.html#setparams)

{% endraw %}
