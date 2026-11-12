# Feature reference

Everything Lumora does, where it lives in the code, and the reasoning behind each choice. New to Lumora? Start with
[Getting started](getting-started.md). Want to know what has actually been tested? See
[Project status](../README.md#project-status).

Some sections describe features that are written but not yet verified end to end; the status table in the README is
the source of truth. Items marked **VERIFY** depend on details that couldn't be confirmed without specific hardware,
SDKs or tool versions.

Related: [COMPARISON.md](../COMPARISON.md) compares Lumora with other tools feature by feature, and
[CHANGELOG.md](../CHANGELOG.md) lists everything in each version.

---

## What it does

| Request | Where it lives |
|---|---|
| Mac-native, from scratch | Swift, SwiftUI and Metal throughout. No cross-platform layers. |
| macOS 27 + M5 / M5 Pro / M5 Max | `ChipProfile.swift`: detects chip, GPU cores, encode engines and memory, then sizes every stage. See **M5** below. |
| HEVC, AV1, H.266/VVC, AV2 (+ ProRes) | `Codec.swift`, `ExportEngine.swift`, `encoders.json` |
| 10-bit and 12-bit only, minimum 4:2:0, accepts 8-bit input | `Codec.bitDepths` / `chromaFormats`. The 12-bit path decodes and grades in 32-bit float. |
| Any RAW format | ProRes RAW (AVFoundation); DNG/CinemaDNG and ~600 camera stills formats (Core Image RAW, scene-linear); BRAW, R3D, ARRIRAW, Canon RAW (vendor SDK plug-ins); everything else via FFmpeg |
| Auto presets from Apple Log / Apple Log 2 | `SourceInspector` reads Apple's log tag, camera model and the picture itself. `AutoPresetEngine` builds presets for each likely profile. |
| Detect and make multiple presets | Natural, Punchy, Super Punchy, Cinematic, Bright & Clean, Moody, and Rip Revive for HDR sources. Each is adapted to the footage, with per-scene exposure. |
| Natural and super punchy | `Grade.metal`: hue-preserving tone curve, local-contrast "punch", Oklab vibrance with skin protection, film-like highlight roll-off |
| LUTs | `LUTExporter`: 33- or 65-point `.cube` of any preset, from any source profile to any target |
| HDR→SDR, SDR→HDR, HDR→HDR | One engine. PQ/HLG/Dolby Vision sources are decoded to scene light, then tone-mapped to any target. SDR sources get highlight reconstruction. |
| All HDR formats | HDR10, HDR10+ (beta), HLG, Dolby Vision 8.1, Dolby Vision 8.4. Inputs include Dolby Vision 5/8 via AVFoundation. |
| Plain-English advice | `FormatAdvisor`: pick where the video is going, get a recommendation, the reasons, and what to watch out for |
| Full interpolation (RIFE and others) | `Core/Interpolation`: RIFE, FILM, IFRNet, GMFSS via Core ML; 2×/4×, exact 60/59.94/120 fps, slow motion |
| Find and fix bad interpolation, only where needed | `InterpolationQC`: per-tile artifact scan, re-render with a stronger model, feathered patching, whole-frame replace; never warps across cuts; fades and dissolves are blended |
| Works with HDR / 10-bit | Models run on the encoded log/PQ/HLG signal in fp16 tensors (no 8-bit round trip). Original frames are never touched. |
| UHD HDR reference library | `HDRLibrary` + `LibraryView`: schema, your own entries, and sync from a community JSON URL |
| Fix your own rips | HDR Report Card (plain-English verdict on any file), then the Rip Revive preset, then HEVC/AV1 HDR10 or Dolby Vision 8.1, keeping all audio and subtitles |

---

## Grading pipeline (one code path for preview, analysis and export)

Every pixel goes through these steps, in order:

1. **Decode to scene light.** The encoded signal is decoded with Apple Log, S-Log3, LogC3, LogC4, V-Log, BT.1886, sRGB, PQ, HLG or linear RAW.
2. **Convert to the working space**, linear BT.2020.
3. **White balance and exposure**, including per-scene auto exposure.
4. **Punch.** Local contrast is applied in log-luminance. The radius scales with the image, and a soft clamp prevents halos.
5. **Tone curve.** Contrast is set around mid gray, a generalized Reinhard shoulder rolls off to the target peak, and a toe adds shadow density. The curve uses a hue-preserving norm.
6. **Highlight desaturation** near peak, like film.
7. **Color.** Oklab saturation plus vibrance, with skin hues held back.
8. **Output.** Conversion to the output gamut with soft gamut compression, then PQ, HLG (BT.2100 inverse OOTF) or BT.1886 encoding.

The preview writes PQ or HLG straight into an EDR `CAMetalLayer` with `CAEDRMetadata`. On a MacBook Pro XDR screen you see the actual HDR output. **Before/After** shows the ungraded signal beside the grade.

**Rip Revive** is for dim HDR masters. It decodes PQ, expands only the light above about 100 nits up to the source's measured peak, then re-tone-maps to the new target peak. Mid-tones keep the colorist's original intent, and highlights gain real punch.

---

## M5 and macOS 27 specifics

- **Media engine.**
  - Decode: hardware for H.264, HEVC, ProRes, ProRes RAW and AV1.
  - Encode: hardware for HEVC Main10 and ProRes.
  - The M5 Max has **two** video encode engines and two ProRes engines. Lumora splits hardware exports into one segment per engine. Segments are snapped to scene cuts so there are no seams.
- **CPU.** The 18-core M5 Pro/Max (6 super + 12 performance cores) runs the software encoders as parallel segment instances:
  - SVT-AV1: about 2 instances
  - VVenC: about 4 instances
  - AVM: many instances, because it is mostly single-threaded
- **GPU Neural Accelerators.** Each M5 GPU core has one. Interpolation models run through Core ML with `computeUnits = .all` and fp16 tensors, so Core ML can schedule layers onto the GPU Neural Accelerators or the 16-core Neural Engine. A future step is moving the hottest layers to Metal 4.1 TensorOps (macOS 27 adds FP8/MX formats).
- **Unified memory.** Decoded frames are wrapped as Metal textures with no copies (`CVMetalTextureCache`). Core ML writes its output straight into Metal-visible buffers (`outputBackings`). The software encoders read planar frames the GPU wrote, also without copies.
- **Analysis resolution** scales with the chip tier: 960 px on Pro/Max, 640 px on base chips.
- **macOS 27.** The deployment target is 27.0, arm64 only. Xcode 27 applies Liquid Glass automatically.

---

## Codecs, bit depth, chroma

| Codec | Engine | Bit depth | Chroma | HDR formats |
|---|---|---|---|---|
| HEVC | VideoToolbox (hardware) | 10 | 4:2:0 | HDR10, HLG, HDR10+, DV 8.1, DV 8.4 |
| ProRes 422 HQ | VideoToolbox (hardware) | 10 | 4:2:2 | HDR10, HLG |
| ProRes 4444 XQ | VideoToolbox (hardware) | 12 | 4:4:4 | HDR10, HLG |
| AV1 | SVT-AV1 | 10 | 4:2:0 | HDR10, HLG |
| AV1 Pro | libaom | 10/12 | 4:2:0/4:2:2/4:4:4 | HDR10, HLG |
| H.266 / VVC | VVenC | 10 | 4:2:0 | HDR10, HLG |
| AV2 (experimental) | AVM reference | 10 (12 experimental) | 4:2:0 | HDR10, HLG |
| HEVC Main 12 | x265 | 12 | 4:2:0/4:2:2/4:4:4 | HDR10, HLG |

H.264 was dropped because Apple's hardware encoder for it is 8-bit only.

AV1, VVC and AV2 are always software encodes: the M5 media engine decodes AV1 but encodes none of these three.

AV2 is an experimental, raw `.obu` export only, for two reasons:

- The AV2 specification was finalized in mid-2026, but only the slow reference encoder exists.
- There is no MP4 binding for AV2 yet.

---

## Encoding to a VMAF target

Turn on **Deliver → Quality target**, pick a score, and Lumora encodes each scene-aligned chunk at the cheapest setting that reaches it:

1. The chunk is rendered once (decode, interpolate, upscale, grade) into RAM. It is not written to disk.
2. The chunk is encoded, decoded by FFmpeg, and scored by libvmaf, streamed through named pipes.
3. A search refines the setting in 2–4 trials, guided by a predictor that learns from your past encodes.
4. Any 1-second stretch that still dips below target is re-encoded on its own.

**Targets in plain terms:**

| VMAF | What it means |
|---|---|
| 97+ | Practically identical |
| 94–97 | Visually indistinguishable at normal distance |
| 90–94 | Excellent |
| Below 90 | Streaming quality |

**About HDR.** VMAF was trained on SDR viewing. Lumora scores the PQ/HLG-coded 10-bit signal, which measures compression loss consistently, but VMAF is not a calibrated HDR scale. Use targets as a consistent safety margin, and confirm by eye on an HDR display (the Compare window helps).

**What it compares against.** The reference is Lumora's lossless render of the graded, interpolated picture, not the original file. Interpolated frames have no original to compare to; their quality is judged separately by the Interpolation Report Card.

Install VMAF with `brew install libvmaf`; it provides the `vmaf` command. FFmpeg builds that include `libvmaf` are also used if present.

## Finished files

Every export is packaged automatically:
- **Name:** Plex/Infuse naming, a custom pattern, or your own name.
- **Metadata:** keep it, remove personal details, or remove everything, plus your own fields (optional online lookup).
- **Tracks:** chosen audio and subtitles, an optional Dolby Digital Plus compatibility track, chapters.
- **Appendices:** settings file, quality report, checksum, NFO, poster, chapters, HDR report, log.
- **Verification:** the finished file is decoded end to end.

Long batches survive restarts, follow your hours, pause on battery or heat, and notify your Mac or phone. **Tools → Verify an archive folder** re-checks checksums on your archive drive.

## Dolby Vision and screens

- **Original Dolby Vision kept and retimed** when the look is unchanged and the output is HEVC. That includes the colorist's trims, through interpolation and cropping. Otherwise Lumora writes new metadata and says why.
- **Grade for a screen** reads this Mac's display (reference modes exactly; XDR panels from Apple's specs; other HDR screens estimated) or targets phones, OLED and mini-LED TVs. It grades highlights to the real peak and guards against TV brightness limiters. **Make it pop** uses the screen's full headroom.
- **Future-proof export:** a 4000-nit 12-bit master plus a Dolby Vision viewing copy.

## Simple mode

Lumora opens in **Simple mode**:

1. Drop a file. Lumora reads every frame (scenes, HDR quality, grain, motion), with a live, playable preview and an info panel on the picture.
2. Pick what you want: watch on TV, archive, make smaller, share, or make motion smoother.
3. Read the recommendations, each with a plain-English reason, and click **Use these settings**.

**Busiest moments → Test smoothing** shows the original next to the interpolated version of the film's hardest motion before you commit. **Pro mode** exposes every control.

## Interpolation intelligence

| Level | What it does | Speed |
|---|---|---|
| Check each frame | One model for the film; every generated frame is checked (structure + motion agreement + flicker) and repaired | Fastest |
| Route a model per scene | Likely models are rebuilt against real frames removed from each scene; each scene uses its winner | Moderate |
| Exhaustive until confident | Every installed model is tested on every scene until the winner is proven at your confidence (97% default); uncertain or hard scenes are generated twice per frame and the cleaner frame is kept | Very slow, maximum quality |

The **pain-point map** (top row of the scene strip, plus the Motion tab) shows each scene's model, confidence and expected repair rate. If a finished export still has flagged frames, **Compare → Repair these frames** fixes just those chunks in place.

## Grain

- **Grain-aware interpolation:** de-grain → interpolate → re-grain with real grain from the nearest frame.
- **Grain-blind artifact checks.**
- **Fair scoring with AV1 grain synthesis:** synthetic grain is stripped at decode and compared against a de-grained master.
- **Measured AV1 grain tables** built from the film's own grain.
- **Restore film texture** for grain-scrubbed transfers, at no bitrate cost.

The grain table scale constant is marked VERIFY. Tune the strength by eye on your TV.

## Optimize for this Mac

**Tools → Optimize for this Mac** tunes Lumora to the exact machine:

- GPU threadgroup shapes
- which compute units each neural model should use
- how many hardware encodes run in parallel
- how many CPU encoders keep every core busy
- memory budgets
- sustained (heat-soaked) speed

Levels: Quick (about 5 min), Thorough (about 30 min), and Burn-in (hours; also calibrates encoders and interpolation on your open film). Live gauges show CPU, GPU, memory and thermal state. Results are stored per machine model and OS version.

## Size forecast

**Deliver → Result** shows the answer before you encode: *"≈16 GB (14–18) · 73% smaller · looks identical · about 9 hr"*.

| Stage | How | Typical accuracy |
|---|---|---|
| Instant | Duration, resolution, frame rate, content type, codec, quality standard | ±30% |
| Refine with samples | ~8 short samples of contrasting scenes, encoded with your exact settings and checks, extrapolated scene by scene | ±10–15% |
| During the encode | Measured chunks, blended with the forecast | about ±5% after a quarter of the film |
| Over time | Every finished export corrects future forecasts for that codec and content type | Tightens with use |

Audio and subtitles are measured exactly from the source and added unchanged. **Tools → Estimate sizes for a folder…** gives archive-wide totals from metadata alone.

## Quality metrics: why not just VMAF

VMAF is fast and well understood, but it was trained on SDR viewing, misses banding and color shifts, and can be inflated by sharpening. Lumora combines several metrics, each doing what it's good at:

| Metric | What it catches | HDR | Speed | Source |
|---|---|---|---|---|
| ColorVideoVDP | Human-vision model: luminance, color and motion on a described display (JOD; 10 = identical) | Yes | Slow | `pip install cvvdp` (Model Lab) |
| PU21-PSNR | Fidelity in perceptually uniform HDR units | Yes | Fast | Same as above |
| XPSNR | Perceptually weighted error | — | Fast | FFmpeg 7+ |
| VMAF / VMAF NEG | Overall perceptual quality; NEG ignores sharpening | SDR-trained | Fast | libvmaf |
| CAMBI | Banding added by the encode | PQ-aware | Fast | libvmaf |
| MS-SSIM, PSNR-HVS | Structure and contrast-weighted error | — | Fast | libvmaf |
| CIEDE2000 | Color shifts | — | Fast | libvmaf |
| SSIMULACRA 2 | Psycho-visual fidelity (SDR) | No | Medium | `cargo install ssimulacra2_rs` |
| AVQT | Apple's perceptual score (file comparisons) | Yes | Fast | developer.apple.com |

**How the Imperceptible standard works:**

1. A fast metric (VMAF 93) finds the cheapest setting.
2. The gates must then all pass: ColorVideoVDP ≥ 9.6 JOD, banding added ≤ 1 CAMBI, worst-5% VMAF NEG ≥ 88, ΔE2000 ≤ 1.5, and SSIMULACRA 2 ≥ 85 for SDR.
3. If a gate fails, quality steps up and everything is re-checked.

This usually lands at a lower bitrate than chasing VMAF 95 alone, while catching the cases VMAF misses.

**Threshold caveats:**

- **ColorVideoVDP:** 9.6 JOD means less than half a just-objectionable difference from identical.
- **SSIMULACRA 2:** about 90 is "hard to tell apart at normal viewing".
- **XPSNR thresholds** aren't standardized, so XPSNR is report-only by default.

All thresholds are editable in Deliver → Quality.

## Encode recipes and the time budget

**Deliver → Time and quality** asks one question: how long are you willing to wait?

- **Fastest**
- **Time budget** (15 minutes to 2 days)
- **Best for this Mac**: stops where extra time stops paying off
- **Maximum**

Lumora estimates the whole job for every preset and extra, keeps the efficient options, and picks the best one that fits. It then tells you what more time would buy, and you can dismiss the suggestion.

**Where the recipes come from:**

- **SVT-AV1.**
  - Presets: 4 is the widely used balance point and 2 the efficient high end; gains below 2 are small (SVT-AV1 deep dives, codec wiki, JET guide).
  - Variance boost is consistently positive in 3.x tests.
  - Grain synthesis levels: about 8 for normal live-action grain, 10–15 heavy, around 4 for animation (SVT-AV1 docs and community advice).
- **x265 for anime.** The common archival choices are `--aq-mode 3`, more B-frames, `--limit-sao` or `--no-sao` for detail, gentle deblocking (-1, or -2 for live action), and moderate psy-rd/psy-rdoq. psy-rdoq goes higher only for grainy sources (JET guide, Doom9 and VideoHelp threads).
- **Seed numbers.** Speed and efficiency start from published benchmarks. **Measure on this Mac** replaces them with real numbers for your footage and machine.

**Two caveats, also shown in the app:**

- VMAF doesn't credit psycho-visual detail or synthetic grain. Lumora keeps those extras available, but labels what VMAF can and can't see.
- Encoder flags change between versions. Lumora only offers flags your installed encoder lists in `--help`.

## Content types

On import, a content test classifies the footage. You can override it in **Source → Content**. The types are real life, heavy grain, anime, old anime, 3D/CGI, screen content, low light, and fast motion.

Each type tunes interpolation models, artifact strictness, repeated-frame smoothing, grain handling, encoder flags, the VMAF target and the upscaler. See `ContentTuning` for the exact values.

## Which RIFE? (Model Lab)

What the sources say, in short:

- **4.25** is the RIFE author's current recommended default for most scenes. It added more flow blocks and markedly improved anime.
- **4.26** is the newest release. Testers disagree: some report extra artifacts in certain scenes compared with 4.25, others prefer it. It needs 64-pixel padding instead of 32.
- **Lite variants** (4.25 lite, 4.22 lite, 4.17 lite) trade a little quality for speed. They're good for scans and long batches.
- **Community favorites:** 4.18 and 4.15 for live action, 4.9 as an all-rounder on lighter hardware, 4.6 for anime speed.

Because no single version wins everywhere, **Model Lab** benchmarks every installed model on real frames removed from *your* footage. It remembers the winner per content type. Until a benchmark exists, each type uses the starting order in `ContentTuning`.

Download links:

- **4.26, 4.26 heavy, 4.25, 4.25 lite** download from a third-party Hugging Face mirror, and the SHA-256 is logged.
- **Other releases** are linked from the Practical-RIFE README (Google Drive). Download them there, then use **Import**.

## Storage: slow archives, fast scratch

- **Scratch SSD.** Choose it in Settings → Storage; your fastest Thunderbolt 4/5 or internal drive is best. Every temporary and intermediate file goes there; nothing is ever written to the source drive.
- **Hard-drive sources** (for example a 70 TB archive reading 150 MB/s) are read **once, in order, by a single reader**, with kernel read-ahead (`F_RDADVISE`). That single pass also builds a 720p preview proxy on the SSD, so scrubbing never seeks the hard drive.
- **When a file needs more bandwidth than the drive gives** (for example 4K ProRes 4444 XQ at about 200 MB/s), Lumora copies it to the SSD first with large sequential reads. That's faster than streaming it.
- **Typical rips don't need staging.** A UHD Blu-ray rip needs roughly 10–16 MB/s, so streaming is fine.
- **No frame extraction.** Interpolation and VMAF never dump frames; everything streams through memory and pipes.

## Upscaling

- **MetalFX** is built in and needs no download. It is fast and good for 1080p→4K.
- **Real-ESRGAN** (BSD-3-Clause) gives the best detail. Convert it with `scripts/convert_realesrgan_coreml.py`, then copy the `.mlpackage` to `~/Library/Application Support/Lumora/Models/`.

Upscaling runs after black-bar cropping and before grading, on the encoded log/PQ signal. Output can go up to 12K.

## HDR interpolation up to 12-bit: how it works

Frame-interpolation networks (RIFE, FILM, IFRNet, GMFSS) are trained on 8-bit SDR video. There are three ways to use them on HDR, from worst to best:

1. **Tone-map to SDR, interpolate, convert back.** HDR is lost. Lumora never does this.
2. **Feed the encoded HDR signal (PQ / HLG / log) straight in.** Those encodings are perceptually spaced like SDR gamma, so the networks behave reasonably, and nothing is clipped. But the network's fp16 output carries only about 11 bits of precision, which is not enough for true 12-bit. This is Lumora's *image mode*.
3. **Use the network only for motion. Recommended; this is Lumora's *flow mode*.**
   - The network sees an SDR-like proxy, which is what it was trained on, so its motion estimates are as good as they get.
   - It returns optical flow and an occlusion/blend mask.
   - Lumora warps and blends the **original** 10/12-bit HDR frames itself, in 32-bit float on the GPU.
   - The generated frames carry the source's full precision, gamut and HDR encoding.
   - The two flows also power the forward/backward motion check that catches artifacts.

**To use flow mode:**

```bash
python scripts/convert_rife_coreml.py --rife-dir Practical-RIFE --weights train_log --flow-output --out RIFE4Flow.mlpackage
```

Copy the result to `~/Library/Application Support/Lumora/Models/`, then choose **RIFE 4.x HDR flow** under Frame interpolation. Original frames are never modified in any mode.

**To interpolate an HDR .mp4 or .mkv without changing its look:**

1. Drop the file in.
2. Pick the **Keep original look** preset.
3. Choose a frame rate.
4. Export as HDR10 with HEVC 10-bit, AV1, or 12-bit ProRes 4444 XQ.

## Grading interpolation quality

Open **Tools → Compare original vs interpolated…** to:

- view both versions side by side in HDR and step frame by frame
- **grade** any interpolated file against its original (0–100, with plain-English findings and a list of problem frames)
- **benchmark** every installed model by rebuilding frames that were removed from the original and scoring them against the real ones

## Interpolation models

Put converted `.mlpackage` files in `~/Library/Application Support/Lumora/Models/`. Models are described in `Resources/interpolation_models.json`.

- **RIFE 4.x** (MIT) is the default. Convert it with `scripts/convert_rife_coreml.py`.
- **FILM** (Apache-2.0) is the default repair model, because it is better on large motion.
- **IFRNet** and **GMFSS** are optional. **Check each model's license before you distribute it.**

If no model is installed, generated frames fall back to blending, so the app still works.

**Artifact repair.** Every generated frame is checked for structure that exists in neither neighboring frame, which is the signature of warping, tearing or ghosting. Flagged frames are repaired in this order:

1. Re-render that frame with the repair model, and keep whichever version is cleaner.
2. Patch only the bad tiles through a feathered mask.
3. If more than 35% of the frame is broken, replace it with the nearest original.

**Scan for interpolation problems** runs this check at proxy resolution and lists every repaired frame before you commit to a full export.

---

## RAW formats

- **Native:** ProRes RAW, DNG / CinemaDNG sequences (open the folder), and single RAW stills from most cameras.
- **Vendor SDKs:** BRAW, R3D, ARRIRAW and Canon RAW need each vendor's SDK under its own license.
  - Implement `VendorRAWPlugin` in a bundle under `~/Library/Application Support/Lumora/PlugIns/`.
  - The plug-in loader is still to be written.

---

## UHD HDR reference library

Lumora ships **without ratings of its own**. A list of "best and worst" discs is only trustworthy if it's built from measurements and sources, so the library is a system rather than a fixed list:

- **Report Card.** It measures any file and writes the verdict in plain English. You can add the result to your library.
- **Community sync.** Point the library at a JSON file of `HDRTitle` entries, for example on GitHub raw. Respect the original authors' terms when compiling community measurements.
- **Comparison.** The Report Card ranks your file's highlight level against the measured titles in your library.

---

## VERIFY before relying on it

1. **Apple Wide Gamut primaries** (Apple Log 2). They are not in public sources. Copy them from Apple's *Apple Log Profile* white paper into `Gamut.appleWideGamut`. Until then, Apple Log 2 color is approximate, and the UI says so.
2. **Apple Log signal range.** The decoder assumes Apple Log values are normalized to legal range. Camera logs (S-Log3, LogC, V-Log) are re-expanded first. Check against Apple's LUTs.
3. **Encoder flags in `encoders.json`.** Check each tool's `--help` for the version installed, especially the VVenC HDR flags and AVM flags.
4. **Metadata schemas.** The dovi_tool `generate` JSON, the HDR10+ JSON schema (beta: its luminance distributions are approximated), and `MP4Box :dvp=8.1`.
5. **Dolby Vision 8.4 via VideoToolbox.** Lumora sets `kVTHDRMetadataInsertionMode_Auto` for HLG HEVC. Confirm the result with MediaInfo.
6. **Pixel formats.** ProRes 4444 XQ input via `y416`, and `128RGBAFloat` reader output for the 12-bit path.

---

## Legal notes

- **Your files only.** Lumora works on video files you already have. It does not decrypt discs; breaking AACS is illegal in the US even for personal copies.
- **Dolby Vision and HDR10+.** The metadata is generated with open tools. Using the logos, or certified delivery, requires licenses from Dolby and HDR10+ Technologies.
- **Tool licenses.** FFmpeg builds with GPL components, and x265, are GPL. Ship LGPL builds, or keep GPL tools as user-installed. SVT-AV1, libaom, VVenC and AVM use BSD-style licenses with AOM/Fraunhofer patent terms.
- **Original work.** Lumora is not affiliated with Tekno3D/VESAI or Real Video Enhancer and contains none of their code.

---

## Tests

Run them in Xcode with **Cmd+U**, or from Terminal (see [Building from source](building.md#running-the-tests)). They pin every transfer curve, the gamut matrices and the HDR metadata layout to published reference values, check that interpolation never crosses a cut, run real clips through the full export pipeline, and draw every window offscreen.

## Roadmap

See the *Unreleased* section of CHANGELOG.md.
