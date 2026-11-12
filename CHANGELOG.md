# Changelog

All notable changes to Lumora. Format based on [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

Status tags used below:
- **Built:** code written and in this repository (not yet compiled or field-tested).
- **Beta:** works end to end, but depends on details marked VERIFY in the README.
- **Planned:** designed, not yet written.

---

## [0.11.1] — 2026-11-11 · "Builds, runs, tested"

The first version that compiles and runs. Earlier versions were complete source that had never been built.

### Fixed — build
- Metal: removed local `max3`/`min3`, which now clash with the Metal standard library.
- Swift: a `let internal` binding (a keyword), `@Observable` properties declared several per line, a shadowed `plan`,
  main-actor isolation of Model Lab paths, a private method used across files, a stale `.h264` case, missing
  `av1Pro`/`hevc12` segment counts, and two type mismatches in packaging reports.
- `usesExternalPlaybackWhileExternalScreenIsActive` is unavailable on macOS; removed.

### Fixed — runtime
- **AV1 / every software encoder failed.** The build step copied Homebrew encoders into the app without their
  libraries, and bundled copies take priority. Only self-contained tools are bundled now.
- **A failed encoder was reported as "CancellationError".** Lumora now shows the encoder's own error.
- **Opening Model Lab (and Deliver → Quality) could crash.** Tool probes ran `waitUntilExit()` inside a SwiftUI
  update, which spins the run loop. Tool calls no longer spin the run loop, and probes run in the background at
  launch.
- "about -170 KB larger than the source": the size difference was subtracted the wrong way round.
- When packaging, a title already inside the file now beats a guess from its file name.

### Security
- Output names can no longer escape the chosen folder (`..`, absolute paths, hidden names, control characters), and
  the final path is checked.
- Exports and packaging refuse to replace their own source; replaced outputs go to the Trash.
- "Remove personal details" uses an allowlist of safe tags instead of a denylist; sidecars drop home-folder paths.
- Hostile frame rates, frame counts and sizes are rejected or clamped instead of crashing.
- FFmpeg inputs are restricted to local files and pipes; concat lists and filter arguments are escaped or relative.
- RIFE downloads are pinned to published SHA-256 digests; imports are checksummed and need confirmation before
  conversion; PyTorch loads weights only; pip installs wheels only; Practical-RIFE is pinned to a commit; archives
  with symbolic links are refused.
- The TMDB key moved to the Keychain. Release builds no longer disable library validation.
- New [SECURITY.md](SECURITY.md).

### Added
- **Tests:** end-to-end exports (SDR→HDR10 HEVC, HDR10→SDR, ProRes 4444 XQ 12-bit, AV1, 2× frame rate), offscreen
  rendering of every window, and 17 hostile-input tests. Tests run headless and skip cleanly on machines without a
  GPU or hardware encoder.
- **`scripts/deps.sh`:** status (including whether each tool actually starts), install, update-then-verify, a weekly
  unattended check with notifications, and `deps.lock` with the last verified versions.
- **CI** on GitHub's macOS 27 / Xcode 27 runners: every push, and weekly against the newest dependencies.
  Dependabot for the workflow's actions.
- **Documentation** for every level: getting started, HDR basics, user guide, building, command line, architecture,
  troubleshooting, contributing.
- MIT licence; bundle identifier `io.github.info-moed.Lumora`.

---

## [0.11.0] — 2026-11-03 · "Library-ready, verifiable, unattended"

### Packaging: every export comes out finished
- **Built — Naming:** Plex/Infuse movie (`Title (Year)/Title (Year) {edition-…} - 2160p HDR10 AV1`), Plex/Infuse TV episode (`Show (Year)/Season 01/Show (Year) - S01E01 - Title`), keep the original name, or a custom pattern with tokens. A free-text **Rename** overrides everything, with a live preview of the final path. Titles, years, seasons and episodes are guessed from file names.
- **Built — Metadata already in the file:**
  - **Keep it.**
  - **Remove personal details:** GPS location, device make/model, creation dates, encoder/software names, comments, author.
  - **Remove everything** except the track languages players need.

  The panel lists the personal tags it found in your file. Removal modes also suppress the muxer's own writing-app stamp.
- **Built — Your own metadata:** title, year, edition, show/season/episode/episode title, genres, description, comment, IMDb/TMDB IDs, and any custom key/value fields you add.
- **Built — Optional online lookup** (The Movie Database, with your own free API key) fills title, year, plot, genres and IDs. Everything works offline without it.
- **Built — Tracks:** choose which audio and subtitle tracks to keep, with lossless TrueHD/DTS-HD/Atmos copied untouched. An optional **Dolby Digital Plus compatibility track** is added for devices that can't play lossless audio. Chapters are kept. Blu-ray image subtitles are kept by writing MKV automatically.
- **Built — Appendices** (each optional) next to the video:
  - **Settings file:** every setting, tool version and checksum, to reproduce the encode exactly
  - **Quality report**
  - **SHA-256 checksum**
  - **NFO** for Plex/Kodi/Infuse
  - **Poster frame**
  - **Chapter list**
  - **HDR report card**
  - **Encode log**

### Archive safety
- **Built — Verification after export:** every frame of every track is decoded, and any error is flagged.
- **Built — SHA-256 checksums:** streaming and hardware-accelerated.
- **Built — Verify an archive folder:** re-hashes every file that has a checksum sidecar (e.g. your archive drive) and lists mismatches.

### Unattended runs
- **Built — Pause and resume** from the toolbar, without losing work.
- **Built — Run rules:** only work between set hours (e.g. 23:00–07:00), pause on battery, pause when the Mac is critically hot.
- **Built — Batch queue that survives quitting and crashes.** Unfinished files resume next launch, and finished ones are skipped.
- **Built — Done notifications:** on the Mac, and on your iPhone through a webhook (ntfy.sh, Pushover, Home Assistant).
- **Built — Per-file packaging in batches,** with names and metadata guessed per file.

### Preview on your TV
- **Built — AirPlay preview:** renders 15 seconds from the current position with your current settings (hardware HEVC HDR10/HLG) and plays it on your Apple TV through the AirPlay picker. VERIFY: HDR passthrough over AirPlay from macOS on your setup.

### Picture regression set
- **Built — Reference frames from your own films,** with their settings. **Check all** re-renders them after any update and flags visible changes (below 45 dB in a perceptual domain).

### Tests
- **Built:** name guessing, Plex paths with editions, rename sanitising, NFO escaping and IDs, overnight schedule windows, SHA-256 known answer.

---

## [0.10.0] — 2026-11-03 · "The colourist's Dolby Vision survives; the grade fits your screen"

### Dolby Vision, kept
- **Built — Profile detection** (5, 7, 8) and whether an enhancement layer is present.
- **Built — Original Dolby Vision retimed.** When the picture isn't regraded (Keep original look) and the output is HEVC, Lumora carries the film's **own** Dolby Vision through interpolation, black-bar cropping and re-encoding, including the colourist's trims for different TVs:
  1. Extract the RPU, converting profile 7 to 8.1.
  2. Map every output frame to the source frame it came from. Generated frames take the nearest original in the same shot, since Lumora never interpolates across cuts.
  3. Rebuild with dovi_tool's editor in two safe passes: removals, then duplications applied from the end.
  4. Reset the active-area metadata (L5) when black bars are removed.
  5. Verify the frame count, then inject.

  If anything doesn't line up, it falls back to generating new metadata and logs why.
- **Built — Automatic decision with a plain reason,** shown in Deliver and in the recommendations: *keeps the film's original Dolby Vision*, or *new metadata because the picture is being regraded / AV1 can't carry it / frames are being reconstructed*. The recommender switches to HEVC Dolby Vision 8.1 to preserve it when that fits your goal, and explains that AV1 files are HDR10.

### Grade for a screen
- **Built — Reads this Mac's display.** A reference mode reports its exact brightness scale. The built-in Liquid Retina XDR and the Pro Display XDR use Apple's published figures (1600 nits peak, 1000 full-screen). External HDR screens are estimated from the HDR headroom macOS reports, with the source of every figure shown.
- **Built — Device targets:**
  - iPhone or iPad Pro (recent)
  - OLED TV
  - Bright OLED TV
  - Mini-LED TV
  - Entry HDR TV / monitor
  - Pro Display XDR
  - Future-proof master (4000 nits)
- **Built — Display-adapted grading:**
  - Highlights are graded to the screen's real peak, and the preview shows it as that screen would.
  - A **brightness-limiter guard** holds back scenes that would push past what the screen can sustain full-screen (OLEDs especially), so the TV doesn't dim the whole picture unpredictably.
  - **Make it pop** uses the screen's headroom: brighter highlights, a touch more clarity and colour, and highlight rebuild for HDR sources.
- **Built — Future-proof export** in one click, producing two files:
  - a 12-bit, 4000-nit ProRes 4444 XQ master for tomorrow's screens
  - a 1000-nit HEVC Dolby Vision 8.1 copy for today's TVs

### Tests
- **Built:** the Dolby Vision keep-vs-generate decision, the output-to-source frame mapping, and the brightness-limiter guard only lowering bright scenes.

---

## [0.9.0] — 2026-11-03 · "Easy for beginners, tireless underneath"

### Simple mode (the default for new users)
- **Built — A big live preview that plays** (space bar). It plays from the SSD proxy when the source is on a slow drive. An on-picture panel shows the file, resolution and frame rate, how it's being read, the HDR verdict with highlight level, the detected content type, timecode, scene, and whether the current moment is calm, has some motion, or is fast.
- **Built — One question: "What do you want to do?"** The choices:
  - Watch on my TV
  - Archive (best quality)
  - Make it much smaller
  - Share or play anywhere
  - Make motion smoother

  Plus one checkbox: *my TV or player can play AV1*.
- **Built — "Lumora recommends".** Recommended settings from a deep read of the file, each with a one-line reason in plain English:
  - **Look:** Keep original, Rip Revive for dim HDR, or Natural for camera log.
  - **HDR format.**
  - **Codec, quality standard and time mode.**
  - **Interpolation:** off for films, with the soap-opera warning; on with per-scene routing when you ask for smoothness.
  - **Grain handling,** including a gentle film texture for grain-scrubbed films.
  - **Black-bar removal and scan fixes.**

  *Use these settings* applies everything in one click (and builds the motion map when needed), and *Export…* goes straight on. The size and time forecast sits right below.
- **Built — Pro mode** is one click away, with every control.

### Motion hotspots and a smoothing test
- **Built — Per-frame motion** is recorded during analysis. The busiest moments of the film are listed, click to jump.
- **Built — Test smoothing** runs about 2 seconds of interpolation on a hotspot with your real settings (including the scene's routed model and all the checks). It plays the original, judder and all, side by side with the smoothed version, in step, at real, half or quarter speed. New frames are marked, and the verdict says how many needed repair.

### Repair interpolated files from any app
- **Built — Compare → "Repair this interpolated file using the original".** Works with files from SVP, Real Video Enhancer, Topaz or anything else. It checks **every** in-between frame against the original, then rebuilds only the bad ones. The rebuild uses that file's own original frames, so its look and HDR match even if it was regraded, with the strongest installed models and the full repair ladder. It writes a repaired copy to the same quality standard, then opens it next to the original for review.

### AV1: SVT-AV1 first, libaom for true archival
- **Built — One AV1 ladder.** It continues past SVT-AV1's slowest presets into libaom (cpu-used 4 → 0), with libaom's own extras: quantization matrices, noise-model grain synthesis, measured grain tables. The planner chooses libaom only when the time allowed makes it worthwhile (Maximum, or very long budgets), where it is marginally smaller for a very long encode. **Measure on this Mac** measures one libaom setting alongside SVT-AV1, so that choice uses real numbers.

### Tests
- **Built:** films keep their frame rate unless smoothness is the goal, archive recommendations, original-frame alignment for 24 → 60 fps repairs, and libaom placement on the AV1 ladder.

---

## [0.8.0] — 2026-11-03 · "Smart all the way down"

### Grain, made safe everywhere
- **Built — Grain-aware interpolation.** For grainy footage, Lumora splits each frame into clean picture and grain with an edge-preserving filter tuned to the measured grain. It interpolates the clean picture, then re-grains each new frame with real grain from the nearest source frame, shifted to a fresh random offset. In-between frames keep exactly the film's grain size, colour and strength: no softer "pumping" frames, no frozen grain. This switches on automatically for heavy grain, old anime and low-light footage.
- **Built — Grain-blind artifact checks.** The structure check compares 3×3 averages, so random grain is no longer mistaken for warping.
- **Built — Fair scoring with grain synthesis.** Every metric (VMAF, CAMBI, XPSNR, SSIMULACRA 2, ColorVideoVDP, PU21) now:
  - decodes AV1 **without** its synthetic grain (`-export_side_data film_grain`)
  - compares against a **de-grained master**

  Grain synthesis and quality targets therefore work together, and the planner can use grain synthesis for grainy films even in quality-target mode.
- **Built — Three grain strategies,** all scored fairly:
  - the encoder's own grain synthesis (now with explicit denoising)
  - **grain measured from this film**: Lumora removes the grain itself, measures its strength per brightness band, and writes a matching AV1 grain table
  - **Restore film texture:** fine 35mm, 35mm, or 16mm/heavy, with a strength control. It adds organic grain to over-processed or scrubbed transfers at zero bitrate cost.

### Interpolation intelligence
- **Built — Three levels:**
  - **Check each frame:** one model; every frame is checked and repaired on its own.
  - **Route a model per scene:** likely candidates are tested on real frames removed from each scene, and each scene goes to its winner.
  - **Exhaustive until confident:** every installed model is tested on every scene until the winner is proven at your confidence level (97% by default, adjustable 90–99.5%). Scenes that are still uncertain, or painful, are generated twice per frame and the cleaner result is kept.
- **Built — Sequential statistics.** Paired comparisons against ground truth run until the leader beats every alternative with the requested probability. Ties are detected and resolved toward the faster model.
- **Built — Pain-point map.** Each scene's model, runner-up, confidence, motion and expected repair rate, saved per file and reused. The scene strip gains a top row (green settled, amber hard, red not yet confident), and the Motion tab lists the hardest scenes, click to jump.
- **Built — Flicker check.** Consecutive generated frames must move evenly between the real frames; a frame that jumps out of line is rebuilt.

### Fix after the fact, surgically
- **Built — Export manifests.** Target-quality exports record their chunk map (keyframe-aligned) and settings.
- **Built — Repair in place.** From the Interpolation Report Card, *Repair these frames* re-renders only the chunks containing flagged frames, with exhaustive interpolation, double generation and stricter checks. It re-encodes them to the same quality standard, splits the finished file at chunk boundaries, swaps the repaired chunks in, and keeps every audio and subtitle track. The previous version is kept alongside. (Dolby Vision / HDR10+ files: re-export instead.)

### Optimize for this Mac
- **Built — A burn-in that measures this exact machine.** Nothing is assumed from the chip's name, so it scales to M5 Ultra and beyond:
  - **GPU:** the fastest threadgroup shape per heavy kernel, timed on the GPU on 4K frames.
  - **Neural models:** whether each interpolation model runs fastest on the Neural Engine + GPU, the GPU alone, or the Neural Engine alone.
  - **Media engines:** how many hardware HEVC encodes really run in parallel (keeps adding sessions until scaling stops).
  - **CPU encoders:** the best number of parallel SVT-AV1 / x265 / VVenC / libaom instances and threads, keeping every core busy without oversubscription.
  - **Memory:** how much RAM to use for frame masters, frames in flight and concurrent chunks, scaled from actual installed memory.
  - **Scratch drive:** write speed.
  - **Heat soak:** GPU and every CPU core loaded together until steady state, measuring how much speed survives. Long-job time estimates use it.
  - **Burn-in level, on your open film:** encoder calibration and the interpolation benchmark for its content type.
- **Built — Live gauges** for CPU, GPU, memory and thermal state, plus per-test results and a first-run prompt.
- **Built — The profile is applied everywhere.** Kernel dispatch, Core ML compute units, media-engine and CPU-encoder parallelism, pipeline depth, chunk concurrency, memory budget and planner estimates all read it. It's tied to the machine model and OS version, so a new Mac or OS re-optimizes.

### Tests
- **Built:** confidence decisions (clear winner, tie, noisy close race), grain table format, film-texture shape, and grain synthesis in quality-target mode.

---

## [0.7.0] — 2026-11-03 · "Know the answer before you press Export"

### Size forecast
- **Built — Result card at the top of Deliver.** One plain answer: *"≈16 GB (14–18 GB) · 73% smaller than the 60 GB source · looks identical to the source · about 9 hr"*. It updates instantly as you change the codec, quality standard, content type, interpolation, upscaling or time budget.
- **Built — Quick estimate** (always on, instant). Uses duration, output resolution and frame rate, content type, codec, quality standard, bit depth and chroma, with seed bits-per-pixel values per content type. It accounts for:
  - lower resolutions needing more bits per pixel
  - cheap interpolated frames
  - grain synthesis
  - ProRes, which uses Apple's published data rates

  Typically within ±30%.
- **Built — Refine with samples** (a few minutes). Encodes ~8 two-second samples of contrasting scenes with your exact settings, including the full quality search and perceptual checks. It then extrapolates across every scene of the film, weighting each by how alike it is to the samples (dynamic range, colour, darkness, skin), and corrects for keyframe overhead. Typically ±10–15%, shown as a range with a confidence figure.
- **Built — Exact audio and subtitle sizes.** Measured from the container (AVFoundation sample sizes, MKV byte-count tags, or bitrate × duration) and added unchanged, since those streams pass straight through.
- **Built — Live projection.** During target-quality encodes, the monitor projects the final size from finished chunks, blending from the forecast to measured data. It fully trusts the measurements once a third of the film is done.
- **Built — Learns from every export.** The actual size is compared with the forecast, per codec, content type and forecast method. The median correction and the spread of past errors then tighten future forecasts; the card says how many encodes it learned from.
- **Built — Folder estimates.** Tools → *Estimate sizes for a folder…* scans a whole directory (subfolders included), metadata only, and reports totals: *"412 files: 24.7 TB → about 6.8 TB (5.9–7.9 TB)"*.

### Changed
- One shared chunk encoder now serves target-quality exports, forecast sampling and calibration, so all three encode identically.

### Tests
- **Built:** forecast ranges are ordered and include audio, a 2-hour 4K AV1 film lands at 10–25 GB, codecs and content types rank correctly, grain synthesis shrinks the estimate, and sampled extrapolation scales with frame counts.

---

## [0.6.0] — 2026-11-03 · "Every metric, one verdict"

### Beyond VMAF: a multi-metric quality engine
- **Built — Eleven metrics**, each explained in plain words and marked when it is HDR-aware:
  - **ColorVideoVDP** (Cambridge, SIGGRAPH 2024). Models human vision for luminance, colour and motion on a described display, SDR and HDR (PQ/HLG). Scores are in JOD: 10 = identical; a 1-JOD drop means 75% of viewers notice. Runs on this Mac (MPS when available).
  - **PU21-PSNR.** PSNR on perceptually uniform HDR values.
  - **XPSNR** (Fraunhofer). Perceptually weighted PSNR, via FFmpeg's filter.
  - **VMAF**, plus **VMAF NEG**, which ignores encoder sharpening tricks.
  - **CAMBI** (Netflix). Banding, in full-reference mode (how much banding the encode *adds*), with PQ-aware visibility for HDR.
  - **MS-SSIM**, **PSNR-HVS** and **CIEDE2000** colour difference, all from the same libvmaf pass.
  - **SSIMULACRA 2.** Psycho-visual, SDR deliveries, via `ssimulacra2_rs`.
  - **AVQT** (Apple). HDR10/HLG/Dolby Vision aware, used when comparing finished files.
- **Built — Concurrent, streamed metrics.** The RAM master is piped into each tool at once, so every metric runs in parallel and nothing is written to disk. ColorVideoVDP scores 1-second windows across each chunk, which keeps memory bounded at 4K/8K.

### Quality standards
- **Built — Each metric gets a role:**
  - *search on* (one fast metric drives the bitrate search)
  - *must pass* (every gate is checked before a chunk is accepted)
  - *report*
  - *off*

  Thresholds are editable, and each rule can pool on the average or the worst 5% of frames.
- **Built — Presets per delivery (HDR or SDR):**
  - **Imperceptible.** Search on VMAF 93, then require ColorVideoVDP ≥ 9.6 JOD, added banding ≤ 1 CAMBI, VMAF NEG worst-5% ≥ 88, ΔE2000 ≤ 1.5, and for SDR SSIMULACRA 2 ≥ 85.
  - **Visually lossless.**
  - **Transparent streaming.**
  - **VMAF only.**
- **Better bitrate for the same invisibility.** The search uses a relaxed VMAF and lets the perceptual gates decide. Chunks that VMAF would over-feed stop as soon as human-vision models can't see a difference; chunks VMAF misjudges (banding, colour shifts, HDR highlights) get extra bits until they pass.
- **Safe fallbacks.** If a gate's tool isn't installed, it is skipped with a note, and missing ColorVideoVDP raises the VMAF target to 95 automatically.

### Encoder and planner
- **Built — Two-stage acceptance per chunk:** a fast search with VMAF/XPSNR/CAMBI/colour, then a perceptual proof with ColorVideoVDP/SSIMULACRA 2. A failed gate raises quality and re-checks, up to four times, with the reason logged and shown in the encode monitor.
- **Built — Encode monitor** shows every metric per chunk, plus which gate forced extra quality.
- **Built — Time planner** includes the cost of the slow perceptual gates in its estimates.

### Tools
- **Built — Model Lab → Install ColorVideoVDP and PU21 metrics** (pip, in the same on-device Python environment), a status list for every metric, and links for AVQT and SSIMULACRA 2.
- **Built — Compare window → Score with every metric**, for versions with the same frame rate (such as re-encoded rips), including AVQT.

### Tests
- **Built:** threshold direction (higher- or lower-is-better), worst-5% pooling, exactly one fast search metric per preset, SSIMULACRA 2 kept out of HDR, and gate evaluation that skips unmeasured metrics.

---

## [0.5.0] — 2026-11-03 · "Tell me how long, I'll do the rest"

### Archival encode recipes (AV1 and HEVC), per content type
- **Built — SVT-AV1 recipes.** A preset ladder from 10 down to 0, plus extras chosen per content type:
  - Variance boost: protects flat and dark areas. Consistent gains in SVT-AV1 3.x tests.
  - Quantization matrices, with a lower minimum level.
  - Deeper look-ahead.
  - Sharpness: crisper line art for anime, finer detail for live action.
  - Temporal filter: off for anime and grain, gentle for live action.
  - Dark-scene bias.
  - Film grain synthesis: level 4 for animation, 8 for live action, 12 for heavy grain.
  - Screen-content tools.
- **Built — x265 recipes (HEVC 10/12-bit software).** A preset ladder from fast to placebo, plus:
  - AQ mode 3 (dark-scene bias)
  - 8 B-frames, or 16 for anime
  - 6 reference frames and a 60-frame look-ahead
  - SAO limited for anime, off for live action
  - Gentle deblocking: -1 for anime, -2 for live action
  - psy-rd 2 / psy-rdoq 1.5, or 4 for grain
  - No strong intra smoothing
  - rd 6 for grain
- **Built — libaom and VVenC ladders.** VideoToolbox HEVC is shown as the media-engine option, with its known efficiency trade-off.
- **Built — Flag probing.** Lumora reads each installed encoder's `--help` and only offers extras that build understands. Options from newer versions or forks appear automatically when supported.
- Every extra is explained in plain words and tagged: *for the eye* (fidelity VMAF doesn't measure), *≈N% smaller*, *+N% time* or *free*, and *not judged by VMAF*.

### Time budget planner: choose your tolerance
- **Built — Four modes:**
  - **Fastest**
  - **Time budget:** 15 minutes to 2 days.
  - **Best for this Mac:** stops where extra time stops paying off, below 2% smaller per doubling of time.
  - **Maximum**
- **Built — Whole-file estimates.** For every preset and combination of extras, the planner estimates the job's wall time. That covers rendering (decode, interpolation, upscaling, grading), encoding, VMAF trials and dip repairs. Expected trials drop as the quality predictor learns. The planner keeps only the Pareto frontier and picks the most efficient point that fits.
- **Built — Upgrade hint.** *"With about 1 hr 20 min more, this file would be ≈9% smaller at the same quality — or ≈+0.8 VMAF at the same size."* One click uses the extra time; another dismisses the hint for good.
- **Built — Automatic extras you can override.** The planner switches extras on and off for you; any toggle you flip is marked *your choice* and kept. One click returns control to the planner.
- **Built — Measure on this Mac.** Renders two contrasting samples of the open file, encodes them at four presets and two quality levels, and scores them with VMAF. Real speed and real size-at-target replace the published seed numbers for that codec and content type, and are remembered.
- **Built — Batch uses the planner too:** every file gets settings that fit your chosen mode and budget.

### Honesty notes built into the UI
- Film grain synthesis is off by default in VMAF-target mode, because VMAF penalises re-created grain. You can turn it on and judge by eye.
- Psycho-visual extras improve what eyes see; the VMAF loop may spend a few more bits to hold its score.
- Until you measure, times are labelled *estimated*.

### Tests
- **Built:** modes ordered by time and efficiency, budget respected, upgrades slower and better, grain synthesis rules, and anime x265 flags.

---

## [0.4.0] — 2026-11-03 · "Visually indistinguishable, on purpose"

### Encode to a VMAF target
- **Built — Target-quality encoding.** Choose a VMAF score; 95 is "visually indistinguishable at normal viewing distance". For every chunk, Lumora finds the cheapest encoder setting that reaches it.
  - The reference is Lumora's own lossless render of the graded, interpolated, HDR picture: the master you approved.
  - Chunks follow scene cuts and are sized to fit in RAM, so the master is rendered **once** and never written to disk.
  - Each chunk is encoded, decoded by FFmpeg and scored by libvmaf, all streamed through named pipes. A secant search on CRF/QP (or VideoToolbox quality) converges in 2–4 trials.
  - Pass rule: the pooled score (average, worst 5%, or harmonic mean) must meet the target, **and** the worst 5% of frames may dip at most a set margin below it.
- **Built — Dip repair.** After a chunk passes, any 1-second stretch scoring more than 2 points under target is split out and re-encoded on its own at higher quality. Weak spots get the bits; the rest of the chunk doesn't inflate.
- **Built — On-device quality predictor.** Ridge regression over shot features learns, from your own past encodes, which setting reaches a target. New chunks start close to the answer, so fewer trial encodes are needed.
  - Features: brightness, dynamic range, skin, interpolated share, resolution, content type, target.
  - It improves the more you encode, and nothing leaves the Mac.
- **Built — Fast validation.** 4K is scored at 1080p with the standard model on every second frame (the full 4K model is optional). Several chunks are searched in parallel while the GPU renders the next ones.
- **Built — Encode monitor.** A live per-frame VMAF chart against the target and floor, plus a chunk map showing state, trials, setting and score. A VMAF row also appears under the scene strip.

### Content test and granular content types
- **Built — Content test on import.** About 40 sampled moments are measured on the GPU: detail, flat-colour share, grain in smooth areas, hard edges, colourfulness and motion, combined with repeated-frame and telecine detection. The result is a type with a confidence and plain-English evidence ("62% flat colour; 44% of frames repeat; film grain; telecined").
- **Built — Eight tuned content types:**
  - Real life
  - Real life, heavy grain
  - Anime
  - Old anime
  - 3D animation / CGI
  - Screen content
  - Low light, noisy
  - Sports / fast motion

  Each sets:
  - the interpolation-model preference order and repair model
  - artifact strictness (grain is random, so grainy types lean on the motion check)
  - repeated-frame smoothing
  - deband, halo protection and punch
  - grain handling (keep, or let the encoder synthesise it)
  - encoder tuning (SVT-AV1 film grain / screen-content mode, x265 `--tune grain|animation`, libaom grain denoising or screen tuning)
  - the VMAF target
  - the suggested upscaler

### Model Lab
- **Built — RIFE catalog**, 4.6 through 4.26, with release dates and plain-English notes from the author's README and community testing (see README → *Which RIFE?*).
- **Built — Download** (4.26, 4.26 heavy, 4.25 and 4.25 lite from a Hugging Face mirror, with the SHA-256 logged) **or import** (releases only on Google Drive).
- **Built — One-click converter environment** (Python venv with PyTorch and coremltools, plus the Practical-RIFE source). Each release is converted to **two** Core ML models: image output, and HDR flow output.
- **Built — Per-content winners.** Benchmarks on your own footage record the best model for each content type, and that model is used automatically next time.
- **Changed — Converter:** detects each release's number of flow blocks automatically, and feeds IFNet the 6-channel input it expects.

### Storage: slow archives in, fast SSD for everything else
- **Built — Drive detection.** The bus (Thunderbolt, USB, internal, SATA, network) and whether a drive is an SSD or a hard drive, via DiskArbitration and IOKit, plus measured read and write speed.
- **Built — Storage plan per file.** Lumora compares the file's bitrate with the drive's real speed and decides:
  - **Stream** directly from fast drives.
  - **Stream with read-ahead (single reader)** from hard drives. The kernel is kept reading ahead of the decoder with `F_RDADVISE`, and there is never more than one reader, so a 150 MB/s archive drive doesn't thrash.
  - **Copy to the scratch SSD first** (16 MB sequential blocks, uncached), when streaming would be slower.
- **Built — Preview proxy.** A 720p 10-bit HEVC proxy of the encoded signal is written to the SSD during the single analysis read. Scrubbing and preview then never seek the hard drive.
- **Built — Scratch manager.** All temporary and intermediate files go to the SSD you choose, never to the source drive. It includes free-space checks, a speed test and a purge button.
- **No frame dumps anywhere.** Interpolation, grading, encoding and VMAF all stream: decoder to GPU to encoder pipes and VMAF FIFOs. The only large writes are the final file and, optionally, the staged copy.

### Interface
- **Built — Redesigned main window.** It follows the grading suite: a neutral-grey surround so the picture is judged correctly, wide expanded headings, and colour used only for meaning.
  - **Scene strip:** every scene is shown lit at its real highlight brightness, in true HDR on XDR displays. It carries repair ticks and VMAF results, and you click to jump.
  - **Inspector tabs:** Source, Look, Motion, Enhance, Deliver.
  - **Parameter sliders:** each shows a live value and a tick at its default; double-click the label to reset.
  - **Timecode transport** with frame stepping.
- **Built — Activity centre.** Every long job (analysis, content test, staging, downloads, conversion, export) has a progress bar, rate and ETA. It sits in a toolbar ring.
- **Built — Log console.** Level and area filters, search, follow mode, a verbose switch, export, and daily log files in `~/Library/Logs/Lumora`. Every decision is logged: detection, storage plan, content test, chunk trials, model choice, and tool command lines when verbose.
- **Built — Settings:** scratch drive (with speed test), auto-staging, and status of every helper tool.

### Tests
- **Built:** VMAF log parsing and pooling, a tuning for every content type, ordered quality ranges for every codec, and the Y4M header.

---

## [0.3.0] — 2026-11-03 · "Full speed, true 12-bit HDR interpolation, graded against the original"

### HDR interpolation up to 12-bit
- **Built — Flow-warped interpolation.** RIFE converted with `--flow-output` predicts only *motion* and a blend mask. It runs on an SDR-like proxy picture, which is what it was trained on. Lumora then warps and blends the **original** frames itself in 32-bit float on the GPU.
  - Generated frames keep the full precision of 10-bit and 12-bit HDR. The old image-output path was limited by fp16 to about 11 bits.
  - Highlights, PQ/HLG/log encodings and wide gamut are never squeezed through the network.
  - On 4K and up, the network runs at half resolution and the motion is upscaled, while the warp runs at full resolution.
- **Built — Keep original look.** A new preset for finished HDR10/HLG/SDR masters shows and encodes the picture exactly as mastered.
  - PQ passes through, HLG goes through its 1000-nit OOTF, and SDR sits at BT.2408's 203-nit white.
  - A soft knee fits larger masters into smaller targets.
  - Drop an HDR .mp4 or .mkv in, interpolate, and export with no regrade.
- **Built — Exact BT.2020 decode for HDR MKV/MP4 through FFmpeg.** The YCbCr matrix, range and accurate rounding are now set explicitly instead of guessed.

### Smarter artifact detection
- **Built — Forward/backward motion check** (flow models). Where both frames contribute but the two motion fields disagree, the motion is unreliable. These tiles are combined with the existing "structure in neither neighbour" check. Occlusions, where one side is hidden by design, are excluded.
- **Built — Batched interpolation.** All in-between frames for a pair of originals (for example three frames for 4×) are generated in one Core ML batch.

### Full hardware utilisation
- **Built — Concurrent export pipeline.** The export now runs as three stages connected by bounded async channels:
  1. Decode, interpolation and upscaling. This uses the media engine, Neural Engine and GPU Neural Accelerators.
  2. GPU grading and packing. This never blocks a thread; it suspends on Metal completion handlers.
  3. Encoding, on the media engine or the CPU encoders.

  All of them work at the same time, with up to 4 frames prepared ahead and 3 graded ahead.
- **Built — Pipelined analysis.** Three frames are in flight on the GPU while the next decode.
- Texture rings were enlarged so nothing in flight is ever overwritten.

### Grading interpolation against the original
- **Built — Compare window.** The original and an interpolated (or otherwise processed) version play side by side or with a wipe, in real HDR. They stay synced in time and step frame by frame.
  - Each side has its own colour interpretation, so an SDR original and an HDR result both display correctly.
  - Every frame is labelled *original* or *generated (t)*.
- **Built — Interpolation Report Card.** It works for files from Lumora or any other app, even regraded or HDR-added ones. It reports:
  - **Original frames preserved:** PSNR and SSIM in the PQ domain on frames that should be untouched.
  - **Artifacts:** generated frames containing structure that exists in neither real neighbour.
  - **Ghosting:** generated frames that are only cross-fades.
  - **Fake frames:** copies of a real frame.
  - **Morphs across scene cuts.**
  - **Motion smoothness:** evenness of motion steps between originals.

  If the file was regraded, it is first tone-normalised, by curve-matching the brightness of aligned original frames, so the score measures motion rather than colour. Results come as a 0–100 score with plain-English findings and a clickable list of problem frames.
- **Built — Hold-out benchmark.** Real frames are removed from the original, rebuilt by every installed model (plus plain blending), and scored against the true frames. The best model is selected automatically, and the artifact detector's strictness is calibrated so it flags almost no real frames.
- **Built — Export both versions.** With interpolation on, Lumora can also export the same grade at the original frame rate. *Compare original vs interpolated…* opens both side by side.

### Tests
- **Built:** async channel ordering and failure propagation, tone-match identity, and duplicate-aware planning.

### Changed
- The `InterpolationEngine` API is batch-based and returns per-frame motion-consistency tiles.
- `FrameStream` needs decode uniforms for the source colour (used to build the flow proxy).
- Every render path goes through `renderNits`, which handles both grading and passthrough.

---

## [0.2.0] — 2026-11-03 · "Better than the reference"

### Picture quality
- **Built — Edge-aware punch (guided filter).** Clarity is now added relative to an edge-preserving base layer instead of a plain blur, which removes the halos around high-contrast edges (skylines, faces against windows, text). A *Halo protection* slider trades classic clarity for edge awareness.
- **Built — Flicker guard.** Within a shot, the punch filter's coefficients are eased toward the previous frame, so local contrast never shimmers or pumps. It resets automatically at every cut.
- **Built — TPDF dithering** at the true output bit depth (10 or 12-bit) before quantisation. This removes the contour banding that HDR expansion can expose in skies and gradients.
- **Built — Debanding for compressed sources** (rips, phone video, streams). Smooth gradients that compression stepped are detected and rebuilt before grading, so highlight expansion doesn't magnify the steps. *Deband* slider, off by default.
- **Built — Black-bar detection and auto-crop.** Letterbox and pillarbox bars are found automatically and removed from analysis, grading and encoding. This gives more accurate brightness measurements and no bits wasted on black. *Remove black bars* toggle.

### Source handling
- **Built — Deinterlacing and inverse telecine.** FFmpeg's `idet` field detector checks DVD, broadcast and legacy sources automatically, then applies one of:
  - BWDIF deinterlacing at the same rate, or at double rate for smoother motion
  - Inverse telecine that restores 24p film from 3:2 pulldown

  The fix is applied before grading, upscaling and interpolation, so combing and judder are never baked in. It can be overridden per file.
- **Built — Duplicate-frame detection.** Repeated frames (animation drawn on twos, padded variable-frame-rate phone video) are detected during analysis.

### Interpolation
- **Built — Duplicate-aware interpolation.** Motion is interpolated between the real, unique drawings instead of stuttering through held frames. *Smooth repeated frames* toggle; it never crosses a cut.

### AI upscaling (new)
- **Built — MetalFX upscaling.** Built in, with no download, using Apple's spatial upscaler in perceptual mode on the encoded log/PQ signal. It runs in up-to-2× steps up to 12K.
- **Built — Real-ESRGAN through Core ML** (x4plus, x2plus, AnimeVideo v3), processed in overlapping tiles so 8K/12K output fits in memory, with fp16 tensors written zero-copy by Core ML. Includes `scripts/convert_realesrgan_coreml.py`.
- Upscaling runs after cropping and before grading, so the grade is computed at full output resolution.

### Grading tools (new)
- **Built — HDR waveform** on the PQ (ST 2084) scale with 1 / 100 / 203 / 1000 / 4000-nit markers.
- **Built — CIE 1931 gamut scope** with Rec.709, P3-D65 and Rec.2020 triangles, measured from the graded output.
- **Built — False-colour mode.** It shows brightness bands: deep shadows, mid-tones, above HDR reference white (203), above 600, above 1000, and clipping.
- **Built — Nits picker.** Click any point of the picture to read its graded brightness and RGB in nits.
- **Built — Reference Match.** Give Lumora the official HDR release of the same film or show. It:
  - finds the time offset automatically by correlating thumbnails
  - measures both versions on 40 matched frames
  - fits a smooth, monotonic correction curve so Lumora's grade follows the studio's
  - reports each brightness band in stops, before and after

  The curve can be removed at any time.

### Workflow (new)
- **Built — Batch processing.** Point it at a folder (for example a season of episodes). Every file is inspected, cropped, analysed and given the recommended (or chosen) look, then exported with the current settings.
- **Built — Shareable presets** (`.lumorapreset`). They store the look, not footage-specific exposure, so a preset adapts to the next clip.
- **Built — HDR still export.** It saves the current frame as:
  - 10-bit HDR HEIC (native)
  - HDR AVIF (libaom)
  - a matching SDR JPEG

### Quality assurance (new)
- **Built — Unit test suite** (`LumoraTests`):
  - PQ, HLG, Apple Log, S-Log3, LogC3, LogC4 and V-Log pinned to published reference values, with round-trip tests
  - the Rec.709→2020 matrix pinned to BT.2087
  - HDR10 metadata byte layout
  - a test that interpolation never crosses a cut
- **Built — CPU reference implementations** of every curve (`TransferMath.swift`), shared by the UI and tests.

### Changed
- The punch filter uses guided-filter coefficients instead of a single blurred luminance plane (`gradeToNits` signature changed).
- Tensor kernels support tiles with overlap (upscaling) as well as whole frames (interpolation).
- All analysis, measurement, preview, export and scope passes honour the crop rectangle.
- Export sizes now come from the crop and upscale stage, not the decoded frame size.

---

## [0.1.0] — 2026-11-03 · First complete source

### Core
- Native macOS 27 app: Swift, SwiftUI, Metal, AVFoundation, VideoToolbox, Core ML. Apple silicon only.
- One grading engine for preview, analysis and export:
  - camera log, SDR and HDR decode
  - BT.2020 working space
  - hue-preserving HDR/SDR tone curve
  - Oklab vibrance with skin protection
  - soft gamut compression
  - PQ / HLG / BT.1886 encode
- Real HDR preview through an EDR `CAMetalLayer`, with a before/after split.
- M5-family tuning:
  - chip, GPU and memory detection
  - one export segment per hardware encode engine (two on M5 Max)
  - parallel software-encoder instances across the 18-core CPU
  - zero-copy unified-memory frames

### Input
- AVFoundation: ProRes, ProRes RAW, HEVC, H.264, AV1, Dolby Vision 5/8.
- FFmpeg pipe for MKV, MXF, AVI, TS, WebM, VVC, AV2 and more.
- Core Image RAW: DNG, CinemaDNG and camera stills, developed scene-linear.
- Vendor RAW plug-in interface: BRAW, R3D, ARRIRAW, Canon RAW.
- 32-bit-float decode and grading path for true 12-bit work.

### Detection and presets
- Detection of Apple Log, Apple Log 2, S-Log3, LogC3/4, V-Log, HDR10, HLG and Dolby Vision, from container tags, camera metadata and the picture itself, ranked by confidence.
- Auto presets per plausible profile: Natural, Punchy, Super Punchy, Cinematic, Bright & Clean, Moody, plus Rip Revive for dim HDR. Each adapts to the footage, with per-scene auto exposure.
- Scene analysis: cuts, fades, dissolves, per-scene statistics.

### Conversion and output
- SDR→HDR, HDR→SDR and HDR→HDR, including highlight expansion for dim HDR masters.
- Codecs:
  - HEVC Main10, ProRes 422 HQ and ProRes 4444 XQ 12-bit (hardware)
  - AV1 (SVT-AV1), AV1 12-bit/4:4:4 (libaom), VVC (VVenC), AV2 (AVM, experimental), HEVC Main 12 (x265)
- HDR formats: HDR10 (measured MaxCLL/MaxFALL), HLG, Dolby Vision 8.4 via VideoToolbox, and Dolby Vision 8.1 and HDR10+ (beta) via dovi_tool / hdr10plus_tool.
- Output is 10-bit and 12-bit only, minimum 4:2:0; 8-bit sources are accepted.
- `.cube` LUT export (33/65-point) of any preset.

### Interpolation
- RIFE, FILM, IFRNet and GMFSS through Core ML, on the encoded HDR/log signal in fp16.
- Modes: 2×/4×, exact 60 / 59.94 / 120 fps, and 2×/4×/8× slow motion.
- Never crosses cuts; fades and dissolves are blended.
- Artifact QC: a per-tile scan, then re-render with a stronger model, feathered patching, or whole-frame replacement.

### Guidance and library
- Plain-English Format Advisor for nine destinations.
- HDR Report Card with verdicts ("Basically SDR in an HDR wrapper", etc.).
- UHD HDR library system: schema, your own entries, community sync.

---

## [Unreleased] — Planned

### Next (0.7)
- **Planned — Butteraugli spot checks** on the worst frames of each chunk. It's an image metric, too slow to run on every frame.
- **Planned — Metal ports** of XPSNR and CAMBI, so the fast metrics run on the GPU.
- **Planned — Metal VMAF.** Port VMAF's VIF/ADM/motion features to the GPU, so validation runs at decode speed instead of on the CPU.
- **Planned — Mezzanine spill option.** For machines with little RAM, spill chunk masters to ProRes 422 HQ on the SSD (about 7× fewer writes than raw) instead of shrinking chunks.
- **Planned — Spatial dip repair.** Region-of-interest quality boosts (x265 zones / AV1 segments) for dips confined to part of the frame.
- **Planned — Learned content classifier.** A small Core ML model trained on your own corrected labels, replacing the rule-based content test.
- **Planned — Apple VideoToolbox frame-rate conversion** (`VTFrameProcessor`) as a zero-download interpolation engine.
- **Planned — Dolby Vision profile 7 (FEL) handling** for UHD rips (convert to 8.1 with RPU preservation).
- **Planned — Metal 4.1 TensorOps** paths for the interpolation and upscaling networks on M5 Neural Accelerators, using FP8/MX formats on macOS 27.
- **Planned — Vendor RAW plug-in loader**, with BRAW and R3D reference plug-ins built on each vendor's SDK.
- **Planned — ML highlight reconstruction** for clipped SDR skies and lights (learned inverse tone mapping).
- **Planned — Film-grain management:** denoise before encode, plus AV1/AV2 grain synthesis tables, for smaller files that don't look plastic.

### Later (0.4+)
- **Planned — Background export queue** with pause, resume and watch folders.
- **Planned — Project files** that reopen with grade, crop, match and interpolation settings.
- **Planned — RGB parade, vectorscope and per-shot MaxCLL/MaxFALL plots** across a whole film.
- **Planned — Shot-level grade overrides** from the timeline (tweak one scene without a full editor).
- **Planned — HDR10+ profile B** (Bézier tone curves) and per-scene trims for Dolby Vision.
- **Planned — Gain-map HDR stills** (ISO 21496-1 / Apple Adaptive HDR) alongside HEIC and AVIF.
- **Planned — Product:** Sparkle auto-updates, crash reporting, onboarding tour, Developer ID notarization pipeline, licensing.

### Known limitations
- Not yet compiled: written without access to a Mac; expect a round of fixes in Xcode 27.
- Apple Log 2 colour is approximate until Apple Wide Gamut primaries are copied from Apple's white paper.
- HDR10+ luminance distributions are approximated from per-scene max/average.
- AV2 output is raw `.obu` (no MP4 binding yet), with no audio; the reference encoder is very slow.
- Preview shows the un-upscaled frame; upscaling applies on export.
- Flow-mode output names (`flow`, `mask`) depend on the RIFE release you convert. VERIFY with the converter's `--mask-is-logit` flag.
- Dolby Vision profile 5 inside MKV isn't decoded correctly through FFmpeg. Remux it to MP4 so AVFoundation applies Dolby's reshaping (`ffmpeg -i in.mkv -map 0 -c copy -strict unofficial out.mp4`).
