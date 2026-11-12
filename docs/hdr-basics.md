# HDR and video basics

A plain-English primer on the terms Lumora uses. Ten minutes here makes every setting in the app make sense. No maths
required; there are a few numbers, all explained.

---

## Contents

- [Brightness is measured in nits](#brightness-is-measured-in-nits)
- [SDR and HDR](#sdr-and-hdr)
- [Transfer functions: BT.1886, PQ, HLG and log](#transfer-functions-bt1886-pq-hlg-and-log)
- [Colour gamut: Rec.709 vs Rec.2020](#colour-gamut-rec709-vs-rec2020)
- [HDR formats: HDR10, HDR10+, HLG, Dolby Vision](#hdr-formats-hdr10-hdr10-hlg-dolby-vision)
- [Bit depth: 8, 10, 12-bit](#bit-depth-8-10-12-bit)
- [Chroma subsampling: 4:2:0, 4:2:2, 4:4:4](#chroma-subsampling-420-422-444)
- [Codecs vs containers](#codecs-vs-containers)
- [Hardware vs software encoders](#hardware-vs-software-encoders)
- [Frame rate and interpolation](#frame-rate-and-interpolation)
- [Measuring quality: VMAF and friends](#measuring-quality-vmaf-and-friends)
- [Tone mapping](#tone-mapping)
- [Glossary](#glossary)

---

## Brightness is measured in nits

A **nit** (candela per square metre, cd/m²) is a unit of brightness on a screen.

| Thing | Roughly |
|---|---|
| Normal SDR "white" (paper white) | 100 nits |
| A laptop at full brightness | 400–500 nits |
| MacBook Pro XDR, HDR highlights | 1,600 nits |
| Good OLED TV, small highlights | 800–1,500 nits |
| Bright mini-LED TV | 1,500–3,000+ nits |
| Maximum the HDR10 format can describe | 10,000 nits |

HDR is mostly about **highlights**: sun glints, lamps, specular reflections. The average picture is not much
brighter than SDR. That's why Lumora talks about "where the real highlights live" (the brightest 0.1% of pixels).

---

## SDR and HDR

- **SDR (standard dynamic range)** is the video of the last 70 years: designed for about 100 nits and a limited set
  of colours. Every screen plays it correctly.
- **HDR (high dynamic range)** describes brightness up to thousands of nits and a much wider range of colours.
  It needs an HDR screen to look right. On an SDR screen it looks dim and grey unless the player converts it.

Lumora converts in every direction:

- **SDR → HDR:** rebuilds highlights that SDR had to compress, so a TV can show them brighter.
- **HDR → SDR:** compresses HDR's range into SDR so it looks right everywhere (tone mapping).
- **HDR → HDR:** regrades, or retargets to a different peak brightness (e.g. a dim 1,000-nit master expanded to use
  a 4,000-nit range: Lumora's **Rip Revive** look).

---

## Transfer functions: BT.1886, PQ, HLG and log

A video file doesn't store light directly. It stores **code values** (numbers), and a **transfer function** says how
code values map to brightness.

| Transfer | Used by | In short |
|---|---|---|
| **BT.1886** (gamma ≈ 2.4) | SDR video | The classic TV curve, relative to the screen's own white. |
| **sRGB** | Computer graphics, stills | Similar to gamma 2.2. |
| **PQ** (SMPTE ST 2084) | HDR10, HDR10+, Dolby Vision | *Absolute*: each code value means a specific number of nits, up to 10,000. |
| **HLG** (Hybrid Log-Gamma) | Broadcast HDR, iPhone video | *Relative* like SDR, so it degrades gracefully on SDR screens. |
| **Log** (Apple Log, S-Log3, LogC3/4, V-Log) | Cameras | Flat-looking footage that keeps the most information for grading later. |

When Lumora "decodes to scene light", it uses the right curve to turn code values back into real light levels,
works on those, then re-encodes with the target curve.

---

## Colour gamut: Rec.709 vs Rec.2020

The **gamut** is the range of colours a format can describe.

- **Rec.709 (BT.709)**: SDR's gamut. Same colours as sRGB.
- **Rec.2020 (BT.2020)**: HDR's container gamut. Much more saturated reds, greens and cyans.
- **P3**: in between; what most HDR content is actually mastered in, inside a Rec.2020 container.

Rec.2020's pure primaries are slightly different *hues* from Rec.709's (its red leans a little towards magenta, its
green towards cyan). When Lumora squeezes extreme Rec.2020 colours into Rec.709, it uses soft gamut compression and
keeps the hue, so those colours may look slightly different from the "same" named colour in SDR. That is correct
behaviour.

---

## HDR formats: HDR10, HDR10+, HLG, Dolby Vision

| Format | Curve | Metadata | Where it works |
|---|---|---|---|
| **HDR10** | PQ | *Static*: one set of numbers for the whole film (mastering display, MaxCLL, MaxFALL) | Every HDR TV, Apple TV, Plex, Infuse, YouTube |
| **HDR10+** | PQ | *Dynamic*: per-scene brightness hints | Samsung TVs, Amazon; others fall back to HDR10 |
| **HLG** | HLG | None needed | Broadcast, phones, social media; looks OK on SDR screens |
| **Dolby Vision 8.1** | PQ | Dolby's dynamic metadata, HDR10-compatible base | LG, Sony, TCL, Apple TV; others play the HDR10 base |
| **Dolby Vision 8.4** | HLG | Dolby's dynamic metadata, HLG-compatible base | What iPhones record; Apple devices, Instagram |

**Dolby Vision profiles** you'll see on sources:

- **Profile 5**: streaming-only, not backwards compatible.
- **Profile 7**: UHD Blu-ray, with an enhancement layer (FEL or MEL).
- **Profile 8**: single-layer with an HDR10 (8.1) or HLG (8.4) base.

Lumora can keep a film's **original** Dolby Vision when the picture isn't regraded (converting profile 7 to 8.1),
or write new metadata when it is.

---

## Bit depth: 8, 10, 12-bit

**Bit depth** is how many steps each colour channel has.

| Bits | Steps per channel | Use |
|---|---|---|
| 8 | 256 | Old SDR. Shows **banding** in smooth gradients, especially in HDR. |
| 10 | 1,024 | The HDR standard. Lumora's default. |
| 12 | 4,096 | Masters and archives; Dolby Vision's internal precision. |

Lumora exports **only 10-bit and 12-bit**, because 8-bit can't carry HDR without visible banding. It *accepts* 8-bit
input and grades it in higher precision.

---

## Chroma subsampling: 4:2:0, 4:2:2, 4:4:4

Video stores brightness (**luma**) and colour (**chroma**) separately, and usually keeps less colour detail, because
eyes are less sensitive to it.

| Format | Colour resolution | Use |
|---|---|---|
| **4:2:0** | ¼ of full | Almost all delivery: Blu-ray, streaming, TV playback |
| **4:2:2** | ½ of full | Professional intermediates (ProRes 422) |
| **4:4:4** | Full | Masters, graphics, screen recordings (ProRes 4444) |

---

## Codecs vs containers

- A **codec** compresses the video: HEVC (H.265), AV1, VVC (H.266), AV2, ProRes.
- A **container** is the file wrapper that holds video, audio, subtitles and chapters together: `.mov`, `.mp4`,
  `.mkv`, `.ivf`, `.obu`.

| Codec | Strength | Weakness |
|---|---|---|
| **HEVC** | Plays everywhere HDR plays; hardware-encoded on Macs (fast) | Larger than AV1 at equal quality |
| **AV1** | ~20–30% smaller than HEVC; royalty-free | Software encode (slow); needs a recent player |
| **VVC (H.266)** | Smaller still | Very few players yet |
| **AV2** | Newest; experimental in Lumora | Only a slow reference encoder exists; no MP4 support yet |
| **ProRes** | Editing quality, fast, 12-bit 4:4:4 | Huge files |

H.264 isn't offered: Apple's hardware H.264 encoder is 8-bit only.

---

## Hardware vs software encoders

- **Hardware** (VideoToolbox: HEVC, ProRes) uses the Mac's dedicated media engine. Very fast, good quality.
- **Software** (SVT-AV1, libaom, x265, VVenC, AVM) runs on the CPU. Slower, but more efficient and more
  configurable. Lumora runs several copies in parallel on scene-aligned segments to keep every core busy.

---

## Frame rate and interpolation

**Frame rate** (fps) is how many pictures per second. Films are 24 (23.976); TV and games are 50–60; phones often 30
or 60.

**Interpolation** creates new in-between frames to raise the frame rate (e.g. 24 → 60). This makes motion smoother
but can give films a "soap opera" look, which is why Lumora's recommender keeps films at their original rate unless
you ask for smoothness. Interpolation can also produce **artifacts** (warping, ghosting); Lumora checks every
generated frame and repairs bad ones. It never interpolates across a scene cut.

---

## Measuring quality: VMAF and friends

How do you know a smaller file "looks the same"? Metrics compare the encode to the reference:

- **VMAF** (0–100): Netflix's perceptual score. 95+ ≈ visually indistinguishable at normal distance. Trained on SDR.
- **ColorVideoVDP** (JOD, 10 = identical): models human vision including HDR, colour and motion.
- **CAMBI**: detects banding added by the encode.
- **ΔE2000**: detects colour shifts.

Lumora's **Imperceptible** standard uses a fast metric to find the cheapest setting, then checks several others
before accepting it. See [Feature reference → Quality metrics](features.md#quality-metrics-why-not-just-vmaf).

---

## Tone mapping

**Tone mapping** fits one brightness range into another, for example a 4,000-nit HDR master onto a 1,000-nit TV or a
100-nit SDR screen. A good tone map keeps mid-tones and skin where the colourist put them, and rolls highlights off
smoothly instead of clipping them to flat white. Lumora's curve sets contrast around mid-grey, adds a gentle toe for
shadows, and uses a soft shoulder for highlights, all while preserving hue.

---

## Glossary

| Term | Meaning |
|---|---|
| **EDR** | Apple's Extended Dynamic Range: how macOS shows HDR on capable screens. Lumora's preview uses it. |
| **MaxCLL / MaxFALL** | HDR10 metadata: brightest single pixel, and brightest frame average, in nits. |
| **Mastering display** | HDR10 metadata describing the monitor the film was graded on (primaries, peak, minimum). |
| **Paper white / diffuse white** | The brightness of a white object that isn't a light source; ~100–203 nits in HDR. |
| **Scene light / display light** | Light as the camera saw it vs as the screen emits it. |
| **OOTF** | The adjustment between scene light and display light (HLG applies one in the TV). |
| **CRF / QP** | Encoder quality setting: lower = better quality and bigger file. |
| **Preset (encoder)** | Speed vs efficiency trade-off: slower presets make smaller files at the same quality. |
| **Grain synthesis** | AV1 can strip film grain before encoding and re-add it at playback, saving bitrate. |
| **RPU** | The Dolby Vision metadata unit attached to each frame. |
| **LUT / .cube** | A lookup table that applies a colour transform; Lumora can export any look as one. |
| **Proxy** | A small, low-resolution copy of a video used for smooth scrubbing. |
| **Scratch drive** | Fast disk where Lumora puts all temporary files. |
