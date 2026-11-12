# Troubleshooting

Find your symptom below. If nothing here helps, [open an issue](https://github.com/info-moed/Lumora/issues) with:

- what you did, what you expected and what happened,
- the output of `scripts/deps.sh status`,
- the relevant part of today's log (`~/Library/Logs/Lumora/lumora-YYYY-MM-DD.log`, or Tools → Log → export).

Remove anything private (file names, paths) before posting.

---

## Contents

- [Build problems](#build-problems)
- [The app won't open](#the-app-wont-open)
- [Opening files](#opening-files)
- [Preview and picture](#preview-and-picture)
- [Exporting](#exporting)
- [Encoders and helper tools](#encoders-and-helper-tools)
- [Interpolation and models](#interpolation-and-models)
- [Speed and storage](#speed-and-storage)
- [Dependency updates](#dependency-updates)
- [Getting more information](#getting-more-information)

---

## Build problems

| Problem | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` (or `scripts/deps.sh install`). |
| `xcode-select: error: tool 'xcodebuild' requires Xcode` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `Signing for "Lumora" requires a development team` | Build with `CODE_SIGN_IDENTITY=-`, or in Xcode choose **Sign to Run Locally** under Signing & Capabilities. |
| Deployment-target or SDK errors | You need Xcode 27 or later on macOS 27 or later. |
| A file you added isn't compiled | Run `xcodegen` again. The project is generated from the folders. |
| Strange errors after switching branches | `rm -rf build/DerivedData && xcodegen`, then build again. |

Full details: [Building from source](building.md#common-build-failures).

---

## The app won't open

- **"Lumora can't be opened because Apple cannot check it for malicious software"**: this happens with a copy
  someone else built and sent you. Right-click the app → **Open** → **Open**. Apps you build yourself aren't affected.
- **It quits immediately**: check `~/Library/Logs/DiagnosticReports/Lumora-*.ips`. "Lumora requires an Apple
  silicon GPU with Metal" means the Mac (or virtual machine) has no usable GPU. "Missing Metal kernel" means a
  broken build; clean and rebuild.
- **Nothing happens on an Intel Mac**: Lumora requires Apple silicon.

---

## Opening files

| Problem | Fix |
|---|---|
| "This file has no video track." | It's an audio-only or broken file. Check with `ffprobe file`. |
| MKV, AVI, WebM… won't open | Those formats go through FFmpeg: `brew install ffmpeg`. |
| "…files need the camera maker's RAW SDK plug-in" | BRAW, R3D, ARRIRAW and Canon RAW need vendor SDK plug-ins, which aren't available yet. Convert to ProRes in the camera maker's app first. |
| Colours look wrong on camera footage | Lumora may have guessed the log profile wrongly. Compare the looks for each interpretation in the sidebar, or pick the right one under Source → **Read as**. Apple Log 2 colour is approximate until Apple publishes its gamut. |
| Opening a file on a hard drive is slow | Lumora reads hard drives once, in order, and builds a preview proxy. Let the first read finish; scrubbing is fast afterwards. |
| Black bars were removed but you want them | Source → Picture → untick **Remove black bars**. |
| Interlaced footage shows combing | Source → Picture → **Scan** → choose the right fix. |

---

## Preview and picture

| Problem | Fix |
|---|---|
| HDR preview looks dim or grey | Your display isn't in HDR mode, or isn't an HDR display. On a MacBook Pro XDR it's automatic; for external screens turn on **High Dynamic Range** in System Settings → Displays. |
| Preview looks too bright on an SDR screen | Set **Display as** to SDR to preview the SDR version. |
| HDR file looks washed out in another player | That player is showing HDR on an SDR screen without tone mapping. Try QuickTime Player, IINA or Infuse, or play it on an HDR TV. |
| Saturated colours shift slightly converting HDR → SDR | Expected for colours outside Rec.709: Lumora keeps their hue while bringing them into gamut. See [HDR basics → gamut](hdr-basics.md#colour-gamut-rec709-vs-rec2020). |
| Banding in skies | Look → Clean-up and HDR → **Deband**; export 10-bit or 12-bit (always on). |

---

## Exporting

| Problem | Fix |
|---|---|
| "… can't do N-bit" / "… supports … colour only" | That codec doesn't support that bit depth or chroma format. The message lists what it does support. |
| "Dolby Vision 8.1 … isn't available with …" / "HDR10+ isn't available with …" | The message lists the codecs that can carry it: hardware HEVC for Dolby Vision; hardware HEVC or x265 HEVC for HDR10+. |
| "AV1 · SVT-AV1 needs the SvtAv1EncApp encoder, which isn't installed" (or another) | `scripts/deps.sh install --all`, or install that one tool. |
| "The helper tool “MP4Box” isn't installed" (x265 or VVC export) | Raw HEVC/VVC streams need MP4Box (or mkvmerge for HEVC) to get correct timestamps: `brew install gpac`. |
| "SvtAv1EncApp failed: …" (or another encoder) | The message ends with the encoder's own error. A missing library ("Library not loaded") means a broken install: `scripts/deps.sh status` shows it; `brew reinstall <formula>` fixes it. An unknown option means the encoder changed; run `scripts/deps.sh verify` and report it. |
| "The helper tool “ffmpeg” isn't installed" | `brew install ffmpeg` |
| Export is very slow | Software encoders (AV1, VVC, AV2) are much slower than hardware HEVC/ProRes. Check Deliver → **Time and quality**, or choose HEVC. Run **Optimize for this Mac** once. |
| Output file is bigger than the source | You're asking for higher quality than the source has. Lower quality or use a quality target; the size forecast warns you before you start. |
| No sound in the output | Sources read through AVFoundation get their audio copied when the output is `.mov`/`.mp4`; other cases go through FFmpeg. Check the track picker under Deliver → packaging. Slow-motion exports drop audio by design. |
| A batch stopped part-way | It resumes: Tools → **Resume unfinished batch…**. Check Settings → Runs & Library → **Long runs** (working hours, battery, heat). |

---

## Encoders and helper tools

```bash
scripts/deps.sh status
```

shows every tool, its version, whether it's up to date, and whether it **actually starts**. Common fixes:

| Status says | Fix |
|---|---|
| `✗ … can't start: Library not loaded …` | `brew reinstall <formula>`. Often caused by a partial `brew upgrade`. |
| A required tool is missing | `scripts/deps.sh install` |
| Updates available | `scripts/deps.sh update` (verifies Lumora afterwards) |
| `(not brew)` | Lumora found a copy outside Homebrew. Fine, but `deps.sh` can't update it. |

To use a specific build of a tool, see [Pointing Lumora at specific tools](command-line.md#pointing-lumora-at-specific-tools).

---

## Interpolation and models

| Problem | Fix |
|---|---|
| Generated frames look like cross-fades | No model is installed, so Lumora blends. Install RIFE through Tools → **Model Lab**. |
| Model Lab can't convert | Click **Set up converter** first (creates a Python environment with PyTorch and coremltools; needs internet and ~2 GB). |
| Warping or ghosting on fast motion | Motion → **Intelligence** → *Route a model per scene* or *Exhaustive*; keep **Find and fix artifacts** on; use **Scan for interpolation problems** before exporting. |
| Films look like a soap opera | That's what higher frame rates do to film. Keep the original rate, or use the comparison export (**Also export the original frame rate**). |

---

## Speed and storage

| Problem | Fix |
|---|---|
| "Not enough space" or exports stop | Lumora writes temporary files to the scratch drive. Settings → Storage → **Empty scratch**, or choose a bigger/faster drive. |
| Everything is slow on an external drive | Set Settings → Storage → scratch to your fastest SSD; enable copying slow sources to it. |
| The Mac gets hot or loud | Expected for long software encodes. Use **Run rules** to work overnight, or Pause. |

---

## Dependency updates

| Problem | Fix |
|---|---|
| `scripts/deps.sh update` says the upgrade reported a problem | Usually a Homebrew link conflict with an older formula (the message names it). Upgrade the conflicting formula, e.g. `brew upgrade qt`, then run `scripts/deps.sh verify`. |
| `verify` fails after an update | The log path is printed. Hold the tool back with `brew pin <formula>` and reinstall the version listed in `deps.lock`, or fix `encoders.json` / the code and open an issue. |
| Weekly check notifications are annoying | `scripts/deps.sh schedule remove` |
| CI shows tests as skipped | GitHub's runners have no usable GPU or hardware encoder; those tests run on real Macs. |

---

## Getting more information

Turn on verbose logging (full tool command lines included):

```bash
defaults write io.github.info-moed.Lumora verboseLogging -bool true
```

Watch the log live while reproducing the problem:

```bash
log stream --level debug --predicate 'subsystem == "io.github.info-moed.Lumora"'
```

More in the [Command-line guide](command-line.md#logs).
