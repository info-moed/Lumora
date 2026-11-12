# Lumora

**Grade, convert and rebuild video between SDR and HDR on a Mac.** Lumora is a native macOS app (Swift, SwiftUI,
Metal, AVFoundation and VideoToolbox) that:

- turns SDR, HDR, camera log and RAW footage into natural or punchy **HDR10, HLG, Dolby Vision or SDR**
- converts **HDR → SDR**, **SDR → HDR** and **HDR → HDR** through one colour-managed engine
- exports **10-bit and 12-bit HEVC, ProRes, AV1, H.266/VVC and AV2**
- raises frame rates with **RIFE-class interpolation**, then finds and repairs bad generated frames
- encodes to a **quality target** (VMAF plus HDR-aware checks) instead of guessing a bitrate
- explains every recommendation **in plain English**

It opens in a **Simple mode**: drop a file, say what you want ("watch it on my TV", "make it much smaller"…), and
Lumora picks the settings and tells you why. **Pro mode** exposes every control.

> **Project status:** builds and runs on macOS 27 / Xcode 27. The core pipeline is verified end to end by automated
> tests; several advanced features are written but not yet verified. See [Project status](#project-status) before
> relying on any one feature.

---

## Contents

- [Who this is for](#who-this-is-for)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Documentation](#documentation)
- [Project status](#project-status)
- [How it works, in one paragraph](#how-it-works-in-one-paragraph)
- [Repository layout](#repository-layout)
- [Contributing](#contributing)
- [Licence and legal](#licence-and-legal)

---

## Who this is for

| You are… | Start here |
|---|---|
| **New to Macs, Terminal or HDR video** | [Getting started](docs/getting-started.md) walks through every step, from installing Xcode to your first converted file. [HDR and video basics](docs/hdr-basics.md) explains the vocabulary. |
| **Comfortable with apps, want to use Lumora well** | [User guide](docs/user-guide.md): Simple mode, every Pro tab, the Tools menu, windows and settings. |
| **Comfortable in Terminal** | [Building from source](docs/building.md) and the [Command-line guide](docs/command-line.md): `xcodebuild`, tests, `defaults` keys, tool overrides, logs, encoder recipes, model conversion, verifying output. |
| **Want to change the code** | [Architecture](docs/architecture.md) and [CONTRIBUTING.md](CONTRIBUTING.md). |
| **Something isn't working** | [Troubleshooting](docs/troubleshooting.md). |

---

## Requirements

| | Required | Notes |
|---|---|---|
| Mac | Apple silicon (M1 or later) | Intel Macs are not supported. Tuned for M5 / M5 Pro / M5 Max; tested on an M3 Max. |
| macOS | **27.0 or later** | The deployment target is 27.0. |
| Xcode | **27 or later** | Free from the Mac App Store. Only needed to build. |
| XcodeGen | any recent | `brew install xcodegen`. Generates the Xcode project from `project.yml`. |
| FFmpeg | recommended | `brew install ffmpeg`. Reads files AVFoundation can't (MKV and more), joins segments, carries audio/subtitles. |
| Software encoders | optional | Only for AV1, VVC, AV2 and 12-bit HEVC. See [Getting started → encoders](docs/getting-started.md#step-5-optional-install-the-extra-encoders). |

Hardware HEVC and ProRes exports need nothing beyond macOS.

---

## Quick start

There is no pre-built download yet, so you build Lumora yourself. It takes about five minutes the first time.
Complete beginners: follow [Getting started](docs/getting-started.md) instead. It explains every line below.

```bash
brew install xcodegen ffmpeg
```

```bash
git clone https://github.com/info-moed/Lumora.git
```

```bash
cd Lumora && xcodegen
```

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Release -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

```bash
open build/DerivedData/Build/Products/Release/Lumora.app
```

Then drop a video onto the window.

Prefer Xcode? After `xcodegen`, run `open Lumora.xcodeproj` and press **⌘R**.

---

## Documentation

| Guide | What's in it |
|---|---|
| [Getting started](docs/getting-started.md) | Install everything, build, first launch, your first conversion. Assumes no prior knowledge. |
| [HDR and video basics](docs/hdr-basics.md) | SDR vs HDR, nits, PQ and HLG, bit depth, chroma, codecs and containers, Dolby Vision profiles. |
| [User guide](docs/user-guide.md) | Simple mode, Pro mode tab by tab, the toolbar and Tools menu, every window, settings, shortcuts. |
| [Feature reference](docs/features.md) | Deep dive on every feature and the reasoning behind it: grading pipeline, codecs, quality metrics, interpolation, grain, storage, packaging. |
| [Building from source](docs/building.md) | XcodeGen, `xcodebuild`, Debug vs Release, signing and notarization, bundling helper tools, running the tests. |
| [Command-line guide](docs/command-line.md) | Everything you can drive or inspect from Terminal: settings keys, tool overrides, logs, scratch and data folders, encoder recipes, model conversion, checking output files. |
| [Architecture](docs/architecture.md) | How the code is organised, the frame pipeline, concurrency, Metal kernels, and how to extend it. |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and their fixes. |
| [COMPARISON.md](COMPARISON.md) | Feature-by-feature comparison with other tools. |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version. |

---

## Project status

Lumora's source was written as a complete design first and compiled later. Version 0.11.1 is the first version that
builds. "Verified" below means an automated test runs it for real (actual files, actual GPU, actual encoders) and
checks the result.

**Verified** (built with Xcode 27.0 on macOS 27.3, Apple M3 Max; 83 automated tests passing):

| Area | What's checked |
|---|---|
| Build | The app and test bundle compile cleanly; all 32 Metal kernels load. |
| Colour maths | Transfer curves (PQ, HLG, camera logs), gamut matrices and HDR10 metadata encoding against published reference values. |
| Ingest and analysis | Opening H.264 and HEVC files; detecting PQ HDR; scene-cut detection; auto-generated looks. |
| SDR → HDR10 | Hardware HEVC, 10-bit, PQ, BT.2020; correct frame count; picture neither black nor clipped. |
| HDR10 → SDR | Hardware HEVC, BT.709; correct frame count and exposure. |
| HDR10 → ProRes 4444 XQ | 12-bit 4:4:4, PQ tags kept. |
| SDR → HDR10 AV1 | SVT-AV1, 10-bit, PQ. |
| Frame interpolation (2×) | Correct frame count, never across a cut, using the built-in blend fallback (no ML model installed). |
| Security | 17 hostile-input tests: path traversal, source overwrite, absurd frame rates and sizes, disguised playlists, metadata leaks, unpinned model archives, Keychain storage. See [SECURITY.md](SECURITY.md). |
| Dependencies | Every encoder flag Lumora uses is accepted by the installed SVT-AV1, libaom, x265 and VVenC (`scripts/deps.sh verify`). |
| User interface | Every window (main window in Simple and Pro mode, Compare, Model Lab, Encode monitor, Library, AirPlay, Regression, Optimize, Log, Settings) builds and draws without crashing, with and without a video loaded. |

**Written but not yet verified.** These may work, may need fixes, or may depend on VERIFY items in the
[feature reference](docs/features.md#verify-before-relying-on-it):

- The on-screen HDR (EDR) preview. Tests draw windows offscreen, and the Metal preview layer can't be captured that way. The Simple-mode layout also hasn't been checked on a real screen yet.
- Dolby Vision 8.1 / 8.4 and HDR10+ metadata, and keeping a film's original Dolby Vision.
- VVC (VVenC), AV2 (AVM), 12-bit HEVC (x265) and libaom AV1 exports.
- RIFE / FILM / IFRNet / GMFSS Core ML models, artifact repair, per-scene model routing and Model Lab conversion.
- Upscaling (MetalFX and Real-ESRGAN).
- Encoding to a VMAF / quality target, and the extra metrics (ColorVideoVDP, CAMBI, SSIMULACRA 2…).
- RAW formats, vendor RAW plug-ins, Apple Log 2 colour.
- Packaging (naming, metadata, TMDB lookup, appendices), batch queue, run rules and notifications.
- AirPlay preview, Optimize for this Mac, size-forecast accuracy.

If you try one of these, please [open an issue](https://github.com/info-moed/Lumora/issues) with what happened, even
when it works. That's how items move up to "verified".

---

## How it works, in one paragraph

Lumora decodes each frame (with VideoToolbox, Core Image RAW or FFmpeg) and wraps it as a Metal texture with no
copies. One GPU grading kernel then runs every step: decode the transfer curve to scene light, convert to linear
BT.2020, white balance and exposure, local-contrast "punch", a hue-preserving tone curve, film-like highlight
roll-off, Oklab colour, gamut compression and the output encoding (PQ, HLG or BT.1886). Preview, analysis and export
share that one code path, so what you see is what you get. Frames stream through bounded in-memory pipelines into
the hardware encoders or into command-line encoders through pipes. Nothing is extracted to disk, and nothing is
written next to your source files. Details: [Architecture](docs/architecture.md).

---

## Repository layout

```
Lumora/
├── Lumora/                 the app
│   ├── App/                entry point and the main app model
│   ├── Core/               engine: ingest, colour, render, interpolation, quality, export, workflow…
│   ├── Shaders/            Grade.metal (all GPU kernels) and ShaderTypes.h (shared with Swift)
│   ├── UI/                 SwiftUI views
│   └── Resources/          encoder recipes, model catalogues, metric helper script
├── Tests/LumoraTests/      unit, end-to-end and UI smoke tests
├── scripts/                encoder installer, tool bundler, Core ML model converters
├── docs/                   all documentation
├── project.yml             XcodeGen project definition (the .xcodeproj is generated, not committed)
├── CHANGELOG.md  COMPARISON.md  CONTRIBUTING.md  LICENSE
```

---

## Contributing

Bug reports, test results on other Macs and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
first; it covers building, the test suite, code style and how to report a problem usefully.

---

## Licence and legal

Lumora is released under the [MIT licence](LICENSE).

- **Your files only.** Lumora works on video files you already have. It does not decrypt discs.
- **Helper tools keep their own licences.** FFmpeg builds with GPL parts, and x265, are GPL. Lumora runs them as
  separate programs that you install yourself. SVT-AV1, libaom, VVenC and AVM use BSD-style licences with
  AOMedia/Fraunhofer patent terms.
- **Models keep their own licences.** RIFE (MIT), FILM (Apache-2.0), Real-ESRGAN (BSD-3-Clause); check IFRNet and
  GMFSS before redistributing.
- **Dolby Vision and HDR10+** metadata is generated with open tools. Using the logos, or certified delivery,
  requires licences from Dolby and HDR10+ Technologies.
- **Independent work.** Lumora is not affiliated with any other video tool it is compared with, and contains none of
  their code, presets, models or branding.
