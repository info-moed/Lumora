# Lumora vs VESAI (Tekno3D)

The VESAI column reflects what Tekno3D's own website listed as of November 2026. The Lumora column is marked:

- **Built:** in this repository; not yet compiled or field-tested.
- **Beta:** works end to end, but depends on details marked VERIFY in the README.
- **Planned:** designed, not yet written.

Neither column claims anything about final picture quality. That can only be judged side by side on real footage, once Lumora is compiled and tuned.

| Capability | VESAI | Lumora |
|---|---|---|
| Platform | Windows 10/11 only (Mac via paid cloud) | **Native macOS 27, Apple silicon** — Built |
| GPU acceleration | NVIDIA TensorRT, DirectML | Metal + Core ML, tuned for M5 (both encode engines on Max, GPU Neural Accelerators) — Built |
| Real HDR preview | Needs Windows HDR mode | Built-in XDR/EDR preview on every M-series MacBook Pro — Built |
| SDR → HDR10 | ✓ | ✓ — Built |
| HDR → SDR, HDR → HDR re-grade | Not advertised | ✓, including Rip Revive for dim HDR masters — Built |
| Camera log input (Apple Log/Log 2, S-Log3, LogC3/4, V-Log) | Not advertised | ✓, auto-detected — Built (Apple Log 2 gamut: VERIFY) |
| Camera RAW input | Not advertised | ProRes RAW, DNG/CinemaDNG and stills RAW; vendor SDK plug-ins — Built |
| Scene analysis | ✓ | ✓ cuts, fades, dissolves, duplicates — Built |
| Edge-aware local contrast | Not advertised | Guided filter + flicker guard — Built |
| Banding control | Not advertised | TPDF dither + deband — Built |
| Auto black-bar crop | Not advertised | ✓ — Built |
| Deinterlace / inverse telecine | Not advertised | ✓, auto-detected — Built |
| Reference matching to official UHD | ✓ (VESAI Match) | ✓ (Reference Match, with per-band stop report) — Built |
| HDR scopes | Waveform, parade, CIE, false color, nits read-out | Waveform (PQ scale), CIE, false color, nits picker — Built · RGB parade — Planned |
| Measured MaxCLL/MaxFALL | ✓ | ✓ from the graded output — Built |
| Dolby Vision | "Compatible workflow" (Pro tier) | DV 8.4 native via VideoToolbox; DV 8.1 via dovi_tool — Beta |
| HDR10+ | ✓ (Pro tier) | ✓ — Beta |
| HLG output | Not advertised | ✓ — Built |
| Codecs | ProRes, HEVC, AV1 | ProRes 422 HQ / 4444 XQ, HEVC, **AV1, H.266/VVC, AV2**, HEVC Main 12 — Built (AV2 experimental) |
| 12-bit output | ProRes 4444 XQ | ProRes 4444 XQ, AV1 12-bit, HEVC Main 12, with a 32-bit-float pipeline — Built |
| AI upscaling | 50+ models, up to 12K | MetalFX (built in) + Real-ESRGAN family, up to 12K — Built |
| Frame interpolation | ✓, with scene-cut protection | ✓ RIFE / FILM / IFRNet / GMFSS, cut-safe, fade-aware, duplicate-aware — Built |
| Interpolation artifact repair | Not advertised | Per-tile QC plus a forward/backward motion check, then stronger-model re-render, feathered patch, or replace — Built |
| HDR interpolation precision | Not specified | Flow mode: the network estimates motion; original 10/12-bit pixels are warped in 32-bit float — Built |
| Grade interpolation against the original | — | Report Card (PSNR/SSIM in PQ, artifacts, ghosting, fake frames, cut morphs, smoothness) + hold-out model benchmark — Built |
| Side-by-side original vs processed | Before/after preview | Synced HDR compare window, each side read in its own format — Built |
| Concurrent pipeline (decode / AI / grade / encode) | Not specified | Bounded async stages across media engine, Neural Engine, GPU and CPU — Built |
| LUT export | Imports .cube as a last step | Exports any preset as .cube (33/65) — Built |
| HDR stills | HDR AVIF + SDR JPG | HDR HEIC + HDR AVIF + SDR JPG — Built |
| Plain-English guidance | — | Format Advisor (9 destinations) + HDR Report Card — Built |
| UHD reference library | Demo comparisons on site | Library system with measurements and sources (ships empty by design) — Built |
| Batch processing | Not advertised | Whole-folder batch — Built |
| Shareable presets | Profiles | `.lumorapreset` files — Built |
| Automated tests of color math | Not public | Unit tests pinned to published reference values — Built |
| Encode to a VMAF target | — | Per-chunk VMAF target with dip repair and an on-device predictor — Built |
| Content-aware tuning | — | 8 detected content types driving models, QC, grain, encoder flags and targets — Built |
| Model management | 50+ bundled models | Model Lab: RIFE 4.6–4.26 catalog, download/import, Core ML conversion (image + HDR flow), per-content benchmark winners — Built |
| Slow-drive handling | — | Drive detection, single-reader read-ahead, auto-staging to SSD, SSD preview proxies — Built |
| Disk writes during processing | Not specified | No frame dumps; everything streams; temp only on the chosen SSD — Built |
| Progress and logging | Not specified | Activity center (progress, rate, ETA for every job) and a searchable log console — Built |
| Archival encoder recipes | Custom encoding parameters | Research-based AV1 (SVT-AV1) and HEVC (x265) recipes per content type, flag-probed against your encoder build — Built |
| Time-budget planning | — | Fastest / budget / best-for-this-Mac / maximum; whole-file time estimates; "X more time buys Y%" hints; on-Mac measurement — Built |
| Quality metrics | — | ColorVideoVDP (HDR), PU21-PSNR, XPSNR, VMAF + NEG, CAMBI banding, MS-SSIM, PSNR-HVS, CIEDE2000, SSIMULACRA 2, AVQT, with search/gate/report roles — Built |
| "Imperceptible" encoding standard | — | Relaxed VMAF search, proven by perceptual, banding and color gates — Built |
| Cloud processing | ✓ (paid) | — |
| Generative AI suite | ✓ (separate product) | — (out of scope) |

**What Lumora still has to prove:** compile cleanly, then tune its tone curves on reference footage and a real HDR display. VESAI has shipping software and a user base; Lumora has a broader feature set on paper. The comparison that matters is picture quality, side by side.
