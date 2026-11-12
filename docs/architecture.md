---
title: Architecture
nav_order: 9
---

# Architecture

How Lumora is put together: the big picture, the frame pipeline, concurrency, the GPU side, and where to make common
changes. Aimed at contributors. Read [Building from source](building.md) first.

---

## Contents

- [Design principles](#design-principles)
- [The big picture](#the-big-picture)
- [Code map](#code-map)
- [What happens when you open a file](#what-happens-when-you-open-a-file)
- [The grading kernel](#the-grading-kernel)
- [What happens when you export](#what-happens-when-you-export)
- [Concurrency model](#concurrency-model)
- [External tools](#external-tools)
- [State, persistence and learning](#state-persistence-and-learning)
- [Testing strategy](#testing-strategy)
- [How to…](#how-to)

---

## Design principles

1. **One grading code path.** Preview, analysis, thumbnails and export all run the same Metal kernel with the same
   uniforms, so the picture you approve is the picture you get.
2. **Never touch the source.** Sources are read-only; every temporary file goes to the scratch drive.
3. **Stream, don't extract.** Frames move through bounded in-memory channels and pipes. No frame dumps to disk.
4. **Zero-copy on unified memory.** Decoded `CVPixelBuffer`s are wrapped as Metal textures via
   `CVMetalTextureCache`; Core ML writes into Metal-visible buffers.
5. **Precision first.** 10-bit is the minimum output; 12-bit paths grade in 32-bit float.
6. **Measure, then decide.** Content type, light levels, encoder speed and quality come from measurements on *your*
   footage and *your* Mac, and learned values improve with use.
7. **Explain everything.** Every automatic choice carries a plain-English reason for the UI.

---

## The big picture

```
              ┌──────────────── Ingest ────────────────┐
  file ──────▶│ SourceInspector → SourceDescriptor     │
              │ + [SourceColor] candidates             │
              └──────────────┬─────────────────────────┘
                             ▼
              ┌──────────── Analysis (one pass) ────────┐
              │ FrameSource → GradeRenderer(analyze)    │──▶ AnalysisResult: scenes, cuts, fades,
              │ CropDetector, ContentProfiler, proxy    │    light levels, motion, grain
              └──────────────┬──────────────────────────┘
                             ▼
              ┌──────────── Decisions ──────────────────┐
              │ AutoPresetEngine → [PresetCandidate]    │
              │ Recommender / FormatAdvisor → advice    │
              │ EncodePlanner, SizeForecaster           │
              └──────────────┬──────────────────────────┘
                             ▼
              ┌──────────── Export ─────────────────────┐
              │ InterpolationPlanner → [PlannedFrame]   │
              │ producer: decode → interpolate (+QC)    │
              │           → crop/upscale                │
              │ grader:   GradeRenderer(grade) → pack   │
              │ writer:   VideoToolbox | CLI encoder    │
              │ join → metadata (HDR10+/DV) → package   │
              └─────────────────────────────────────────┘
```

---

## Code map

| Folder | Responsibility | Key types |
|---|---|---|
| `App/` | Entry point and the single app-wide model the UI binds to | `LumoraMain`, `LumoraApp`, `AppModel` (`@MainActor @Observable`) |
| `Core/Ingest/` | What a file is, how to decode it, where tools live | `SourceInspector`, `SourceDescriptor`, `SourceColor`, `FrameSource`s, `ToolLocator` |
| `Core/Color/` | Color science: primaries, transfer curves, grade parameters, output targets | `Gamut`, `TransferMath`, `GradeParams`, `Look`, `OutputTarget`, `UniformBuilder` |
| `Core/Analysis/` | One-pass film analysis and HDR judgment | `SceneAnalyzer`, `ContentProfiler`, `CropDetector`, `HDRReportCard`, `ReferenceMatcher`, `HDRLibrary`, `RegressionSet` |
| `Core/Presets/` | Turning analysis into choices and advice | `AutoPresetEngine`, `Recommender`, `FormatAdvisor` |
| `Core/Render/` | Metal device, pipelines and pass encoding | `MetalContext`, `GradeRenderer`, `GrainProcessor` |
| `Core/Interpolation/` | Planning, generating, checking and repairing in-between frames | `InterpolationPlanner`, `InterpolationEngines`, `InterpolationQC`, `MotionRouter`, `MotionScan`, `InterpolationEvaluator`, `ExternalRepair` |
| `Core/Upscale/` | Crop and upscale before grading | `PreGradeStage`, `Upscaler` |
| `Core/Quality/` | Metrics, quality-target encoding, planning and forecasting | `QualityMetric`, `MetricSuite`, `VMAFRunner`, `TargetQualityEncoder`, `EncodeMonitor`, `EncodePlanner`, `EncodeRecipes`, `SizeForecaster`, `QualityPredictor` |
| `Core/Export/` | The export engine and HDR metadata | `ExportEngine`, `ExportJob`, `Codec`, `DeliveryFormat`, `EncoderCatalog`, `HDRMetadata`, `DolbyVisionRetimer`, `ExportManifest` |
| `Core/Workflow/` | Pipeline plumbing and finishing | `BoundedChannel`, `Packager`, `Naming`, `PauseGate`, `RunRules`, `Notifier`, `QueueStore`, `Log`, `LogStore`, `TaskCenter`, `AirPlayPreview` |
| `Core/Hardware/` | The Mac and its displays | `ChipProfile`, `MacProfile`, `MacOptimizer`, `SystemMonitor`, `DisplayInspector` |
| `Core/Storage/` | Drives, scratch and staging | `StorageInspector`, `ScratchManager`, `ReadAheadAdvisor`, `ProxyWriter` |
| `Core/Models/` | RIFE download, conversion and ranking | `ModelLab` |
| `Shaders/` | Every GPU kernel, and the structs shared with Swift | `Grade.metal`, `ShaderTypes.h` |
| `UI/` | SwiftUI views | `ContentView`, `SimpleModeView`, `InspectorView`, `EDRViewer`, `CompareView`, `Panels`, `Sheets` |

The largest files are `AppModel.swift` (UI-facing orchestration), `ExportEngine.swift` (rendering and encoding) and
`Grade.metal` (all 32 GPU kernels).

---

## What happens when you open a file

`AppModel.open(_:)`:

1. **Inspect.** `SourceInspector.inspect` tries, in order, AVFoundation (container and color tags, Dolby Vision
   configuration, Apple Log tag, camera model), Core Image RAW for stills and DNG folders, then `ffprobe`. It
   returns a `SourceDescriptor` (geometry, rate, frame count, decoder kind, crop, scan type) and a ranked list of
   `SourceColor` interpretations (transfer, gamut, range, e.g. "Apple Log" *and* "Apple Log 2" when unsure).
2. **Storage.** `StorageInspector` measures the source drive against the bitrate the file needs and either streams
   it with read-ahead (`ReadAheadAdvisor`, `F_RDADVISE`) or stages it to scratch.
3. **Crop.** `CropDetector` finds letterbox and pillarbox bars.
4. **Analyze.** `SceneAnalyzer.analyze` decodes every frame once, runs the analysis kernels at the chip's analysis
   width (960 px on Pro/Max chips), and builds the `AnalysisResult`: scenes, cuts, fades, per-scene light levels
   and motion. The same pass can write the preview proxy.
5. **Profile.** `ContentProfiler` classifies the footage into a `ContentKind` with evidence and confidence;
   `ContentTuning` maps each kind to interpolation, QC, grain, encoder and quality settings.
6. **Presets.** `AutoPresetEngine.generate` builds a `PresetCandidate` per look and color interpretation, with
   per-scene exposure, and marks the recommended one.

---

## The grading kernel

`gradeKernel` in `Grade.metal` applies, per pixel:

1. Decode the source transfer (Apple Log, S-Log3, LogC3/4, V-Log, BT.1886, sRGB, PQ, HLG, linear RAW) to scene light.
2. Convert the source gamut to linear BT.2020.
3. White balance, exposure, per-scene auto exposure.
4. Punch: local contrast in log luminance from a guided-filter base layer (`guidedCoeffKernel`), radius scaled to
   the image, soft-clamped against halos.
5. Tone curve: contrast around mid gray, generalized Reinhard shoulder to the target peak, a toe for shadow density,
   using a hue-preserving max-RGB norm.
6. Film-like highlight desaturation near peak.
7. Oklab saturation and vibrance, with skin hues protected.
8. Output: gamut conversion with soft gamut compression, then PQ, HLG (BT.2100 inverse OOTF) or BT.1886 encoding,
   with dithering to the output bit depth.

Uniforms are a single `GradeUniforms` struct defined in `ShaderTypes.h` and imported into Swift through the bridging
header, so layouts can't drift. `UniformBuilder` fills it from `SourceColor` + `GradeParams` + `OutputTarget`.
CPU mirrors of the transfer functions live in `TransferMath.swift`, pinned by `ColorMathTests`.

Other kernel families: analysis (`analyzeKernel`, `measureKernel`, histograms, `contentStatsKernel`), packing for
encoders (`pack420/422Kernel`, `packPlanarKernel`, `packY416Kernel`), interpolation (`flowProxy`, `flowWarpBlend`,
`flowConsistency`, `blend`, `interpQC`, `repair`, `temporalBlend`), Core ML tensor bridges, grain (`bilateral`,
`grainStats`, `regrain`), scopes and probes. `MetalContext` builds a pipeline for each kernel at start-up and fails
loudly if one is missing.

---

## What happens when you export

`ExportEngine.run(_:status:)`:

1. **Validate** the job (bit depth, chroma and HDR format vs codec; encoder installed).
2. **Plan frames.** `InterpolationPlanner.plan` produces `[PlannedFrame]`: originals and generated frames with their
   source pair and time. Never across a cut; fades blend; duplicates are smoothed for animation.
3. **Measure light levels** for HDR10 MaxCLL/MaxFALL from sample frames.
4. **Segment.** `ChipProfile.segments(for:frameCount:)` splits the output into ranges snapped to scene cuts: one per
   hardware encode engine, or several CLI encoder instances to fill the CPU (or the measured value from
   `MacProfile`).
5. **Per segment, three stages connected by `BoundedChannel`s:**
   - *Producer*: `FrameStream` decodes and generates frames (Core ML or blend fallback), `InterpolationQC` checks and
     repairs them, `PreGradeStage` crops and upscales.
   - *Grader*: `GradeRenderer.encodeGrade` then pack to planar Y'CbCr at the target depth and chroma.
   - *Writer*: `AVAssetWriter` + VideoToolbox for HEVC/ProRes, or the CLI encoder fed Y4M through stdin or a FIFO.
6. **Join** segments: AVFoundation passthrough stitch for hardware `.mov`/`.mp4`, raw concatenation for Annex-B /
   OBU streams, otherwise FFmpeg concat, carrying the source's audio and subtitles.
7. **Dynamic metadata** for HDR10+ and Dolby Vision (`HDRMetadata`, `DolbyVisionRetimer`, `dovi_tool`,
   `hdr10plus_tool`, MP4Box/mkvmerge).
8. **Move** into place, then `Packager` handles naming, metadata, tracks, appendices and verification.

`TargetQualityEncoder` replaces step 5's writer with a per-chunk search: render the chunk once into RAM, encode
trials, score with `MetricSuite` through pipes, accept the cheapest passing setting, and re-encode dips.

---

## Concurrency model

- **UI state** is `@MainActor @Observable` (`AppModel`, `ModelLab`, `LogStore`, `TaskCenter`, `EncodeMonitor`…).
  Long work runs in `Task`s and publishes progress back on the main actor.
- **Pipelines** are structured concurrency: a task group per export (one child per segment), each segment with
  producer / grader / writer tasks joined by `BoundedChannel` (an async queue with back-pressure and error
  propagation). Cancellation flows down; errors flow up.
- **GPU work** is encoded into command buffers and awaited with `commitAndWait()` (async), never by blocking threads.
- **External processes** are awaited off the main thread. Short synchronous tool calls (`ToolLocator.run`) wait on a
  semaphore rather than `Process.waitUntilExit()`, because the latter spins the run loop, and doing that inside a
  SwiftUI update crashes the app. Capability probes (`VMAFRunner.backend`, `MetricSuite.ffmpegHasXPSNR`) are warmed
  on a background queue at launch (`ToolProbe.warmUp`).
- **SIGPIPE is ignored** process-wide, so an encoder that exits early surfaces as a thrown error. The engine then
  reports the encoder's own log instead of a generic broken pipe or cancellation error.
- The project builds in Swift 5 language mode; adopting strict Swift 6 concurrency is future work.

---

## External tools

All tool use goes through `ToolLocator` (lookup order and overrides in the
[Command-line guide](command-line.md#pointing-lumora-at-specific-tools)). Processes are launched with argument arrays,
never through a shell. Software encoder command lines come from `Resources/encoders.json` (`EncoderCatalog`,
`EncoderSpec.render`); efficiency extras from `EncodeRecipes` are filtered against each encoder's `--help`.
`scripts/deps.sh verify` checks every `encoders.json` flag against the installed tools.

---

## State, persistence and learning

| Store | Type | Written by |
|---|---|---|
| `UserDefaults` (`io.github.info-moed.Lumora`) | preferences | `AppModel`, `ScratchManager`, `RunRules`, `LibraryLookup`, `ToolLocator` overrides |
| `mac-profile.json` | measured threadgroups, compute units, parallelism, memory budgets | `MacOptimizer` → `MacProfile` |
| `Calibration/` | encoder speed and efficiency per rung | `ExportEngine.calibrate` → `EncodePlanner` |
| `quality-predictor.json` | setting → score model per shot type | `TargetQualityEncoder` → `QualityPredictor` |
| `forecast-learning.json` | forecast error per codec and content type | `SizeForecaster` |
| `Manifests/` | chunk boundaries and settings per export | `ExportEngine` → `ExportManifest` (repairs) |
| `MotionMaps/` | per-scene model routing | `MotionRouter` |
| `queue.json` | unfinished batch | `QueueStore` |

All paths are listed in the [Command-line guide](command-line.md#files-and-folders).

---

## Testing strategy

| Layer | How |
|---|---|
| Math | Pure unit tests against published reference values (`ColorMathTests`, `DolbyVisionTests`, …) |
| Planning logic | Unit tests on planners, recommender, forecaster, naming, packaging |
| Real pipeline | `EndToEndTests` generate clips with FFmpeg, run the real engine on the real GPU and encoders, and check the files with `ffprobe` (codec, bit depth, HDR tags, frame count, exposure) |
| UI | `UISmokeTests` build every window offscreen with a video loaded and draw it to PNG |
| Hardware gating | `TestHardware` skips GPU/media-engine tests on machines without them (CI VMs) |
| Dependencies | `scripts/deps.sh verify` (flags + build + tests), weekly in CI and optionally on your Mac |

Test runs are headless: under XCTest, `LumoraMain` starts the app with no windows, no Dock icon and no focus change.

---

## How to…

**Add a look.** Add a case to `Look` in `GradeParams.swift` (display name, base parameters), teach
`AutoPresetEngine.generate` when to offer and recommend it, and add a reason string. The kernel needs no change
unless the look needs a new control.

**Add a grade control.** Add the field to `GradeParams` and to `GradeUniforms` in `ShaderTypes.h` (keep alignment),
fill it in `UniformBuilder`, use it in `gradeKernel`, and add a `ParamSlider` in `LookPanel`.

**Add a software encoder.** Add an entry to `encoders.json` (see the
[format](command-line.md#encoder-recipes-encodersjson)), a `Codec` case with bit depths, chroma formats, HDR
support, `cliKey` and container, its segment count in `ChipProfile.segments`, optional recipes in
`EncodeRecipes`, its help flag in `scripts/deps.sh` (`ENCODER_HELP`), and an end-to-end test.

**Add an interpolation model.** Convert it to Core ML with named inputs/outputs, describe it in
`interpolation_models.json` (or the user `models.json`), and add it to `ContentTuning`'s model order if it should
be preferred for a content type.

**Add a metric.** Add a `QualityMetric` case (name, direction, threshold, availability, source), implement scoring
in `MetricSuite`, and add it to the relevant `QualityProfile` presets.

**Add a window.** Add a `Window` scene in `LumoraApp`, a Tools-menu entry in `ContentView`, and a render test in
`UISmokeTests`.
