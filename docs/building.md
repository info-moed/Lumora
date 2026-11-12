# Building from source

Everything about turning the source into an app: the project generator, `xcodebuild`, configurations, signing,
helper tools and the test suite. For a gentler walkthrough, see [Getting started](getting-started.md).

---

## Contents

- [Toolchain](#toolchain)
- [Project generation (XcodeGen)](#project-generation-xcodegen)
- [Build commands](#build-commands)
- [Build settings that matter](#build-settings-that-matter)
- [Signing, hardened runtime and notarization](#signing-hardened-runtime-and-notarization)
- [Helper tools: bundled vs Homebrew](#helper-tools-bundled-vs-homebrew)
- [Running the tests](#running-the-tests)
- [Clean builds and caches](#clean-builds-and-caches)
- [Common build failures](#common-build-failures)

---

## Toolchain

| Component | Version | Notes |
|---|---|---|
| macOS | 27.0+ | Deployment target 27.0, `arm64` only |
| Xcode | 27+ | Swift 6 compiler in **Swift 5 language mode** (`SWIFT_VERSION = 5.0`), relaxed concurrency checking |
| Metal | Metal toolchain shipped with Xcode 27 | `Grade.metal` uses the standard library's `max3`/`min3` |
| XcodeGen | any recent | `brew install xcodegen` |

Check your toolchain:

```bash
xcodebuild -version && xcode-select -p && swift --version
```

If `xcode-select -p` points at the Command Line Tools instead of Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## Project generation (XcodeGen)

The Xcode project is **generated** from [`project.yml`](../project.yml) and is not committed (it's in
`.gitignore`). Regenerate it whenever you add, remove or rename files, or change `project.yml`:

```bash
xcodegen
```

`project.yml` defines two targets:

| Target | Type | Sources |
|---|---|---|
| `Lumora` | macOS application | `Lumora/` (code, shaders); `Lumora/Resources/` is copied as bundle resources |
| `LumoraTests` | unit-test bundle hosted in the app | `Tests/LumoraTests/` |

The `Info.plist` is generated too (`Lumora/Info.plist`, git-ignored) from the `info.properties` block, which sets the
display name, version, minimum system version and app category.

---

## Build commands

All commands run from the repository root. `-derivedDataPath` keeps build products inside the repo (under `build/`,
which is git-ignored) so they're easy to find. Drop it to use Xcode's default DerivedData folder.

**Debug build** (faster to compile, includes debug info):

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

**Release build:**

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Release -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

The app lands in `build/DerivedData/Build/Products/<Configuration>/Lumora.app`.

**Quieter output.** `xcodebuild` is verbose. Keep a full log and show only problems:

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Release -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build > build/build.log 2>&1; grep -E ': (error|warning):' build/build.log | sort -u
```

Or install [xcbeautify](https://github.com/cpisciotta/xcbeautify) and pipe through it.

**Launch from Terminal** (also shows the app's log output in the terminal):

```bash
build/DerivedData/Build/Products/Release/Lumora.app/Contents/MacOS/Lumora
```

**Archive** (for distribution):

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Release -archivePath build/Lumora.xcarchive archive
```

---

## Build settings that matter

From `project.yml`:

| Setting | Value | Why |
|---|---|---|
| `SWIFT_VERSION` | `5.0` | Swift 5 language mode on the Swift 6 compiler. Strict Swift 6 concurrency is not adopted yet. |
| `ARCHS` | `arm64` | Apple silicon only (Metal features, media engine, unified memory). |
| `MACOSX_DEPLOYMENT_TARGET` | `27.0` | Uses macOS 27 APIs. |
| `SWIFT_OBJC_BRIDGING_HEADER` | `Lumora/Shaders/Lumora-Bridging-Header.h` | Imports `ShaderTypes.h` so Swift and Metal share the exact uniform struct layouts. |
| `MTL_HEADER_SEARCH_PATHS` | `$(SRCROOT)/Lumora/Shaders` | Lets `Grade.metal` include `ShaderTypes.h`. |
| `MTL_FAST_MATH` | `YES` | Faster GPU maths; the grading maths is written to tolerate it. |
| `SWIFT_OPTIMIZATION_LEVEL` | `-O` | Even Debug builds are optimised: the frame pipeline is too slow otherwise. Use a `-Onone` override if you need to step through code. |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Required for notarization. |
| `CODE_SIGN_ENTITLEMENTS` | `Lumora/Lumora.entitlements` | **No App Sandbox** (Lumora launches encoder tools) and **library validation disabled** (for future vendor RAW plug-ins). |

Override any setting on the command line, e.g. an unoptimised Debug build for stepping through code:

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- SWIFT_OPTIMIZATION_LEVEL=-Onone build
```

---

## Signing, hardened runtime and notarization

**For your own Mac**, ad-hoc signing (`CODE_SIGN_IDENTITY=-`) is enough. Apps you build locally aren't quarantined,
so Gatekeeper opens them.

**In Xcode:** target **Lumora** → **Signing & Capabilities** → *Sign to Run Locally*, or pick your own team.

**For distribution to other people**, Lumora must be signed with a **Developer ID Application** certificate and
**notarized**. The App Store is not an option: the sandbox would block launching encoder tools.

1. Archive (see above), then export with a Developer ID method, or sign directly:

   ```bash
   codesign --force --deep --options runtime --timestamp --entitlements Lumora/Lumora.entitlements --sign "Developer ID Application: YOUR NAME (TEAMID)" build/DerivedData/Build/Products/Release/Lumora.app
   ```

2. Zip and submit for notarization (store credentials once with `xcrun notarytool store-credentials`):

   ```bash
   ditto -c -k --keepParent build/DerivedData/Build/Products/Release/Lumora.app build/Lumora.zip
   ```

   ```bash
   xcrun notarytool submit build/Lumora.zip --keychain-profile "YOUR_PROFILE" --wait
   ```

3. Staple the ticket:

   ```bash
   xcrun stapler staple build/DerivedData/Build/Products/Release/Lumora.app
   ```

Any helper tools you bundle (next section) must be signed with the same identity and hardened runtime.

---

## Helper tools: bundled vs Homebrew

Lumora finds each helper tool (FFmpeg, encoders, metadata tools) in this order:

1. A per-tool override path in user defaults (`toolPath.<name>`; see the
   [Command-line guide](command-line.md#pointing-lumora-at-specific-tools)).
2. `Lumora.app/Contents/Resources/bin/<name>` (bundled copies).
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`.

A build phase runs [`scripts/bundle-tools.sh`](../scripts/bundle-tools.sh), which copies tools into
`Contents/Resources/bin` **only if they are self-contained**, i.e. they link nothing outside macOS itself. Homebrew
builds link Homebrew libraries, so the script skips them and prints a note like:

```
note: SvtAv1EncApp links non-system libraries; using it from /opt/homebrew/bin at run time
```

That's expected on a developer Mac. (A bundled copy whose libraries are missing would fail to start *and*, because
bundled copies win, hide the working Homebrew one.)

To ship a self-contained app, put **static builds** of the tools in `/opt/homebrew/bin` or `~/.local/bin` before
building, or relink them with a tool such as `dylibbundler`, then sign them. Check each tool's licence: FFmpeg with
GPL parts, and x265, are GPL.

---

## Running the tests

The test suite has 83 tests in five groups:

| Group | Files | What it covers | Needs |
|---|---|---|---|
| Unit | `ColorMathTests`, `DolbyVisionTests`, `ForecastTests`, `MetricTests`, `PackagingTests`, `PipelineTests`, `PlannerTests`, `QualityTests`, `RecommenderTests`, `RoutingAndGrainTests` | Transfer curves, gamut matrices, HDR metadata, planners, naming, checksums… | nothing |
| End to end | `EndToEndTests` | Generates test clips with FFmpeg, runs them through inspect → analyze → presets → GPU grade → encode, and checks the output with `ffprobe` | FFmpeg (with libx264/libx265); SVT-AV1 for the AV1 test (skipped otherwise) |
| UI smoke | `UISmokeTests` | Builds every window offscreen with a video loaded and draws it to a PNG | FFmpeg |
| Security | `SecurityTests` | Hostile inputs: crafted names, metadata, frame rates, sizes, playlists, model archives | FFmpeg |

**Run everything:**

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- test
```

**Run one class or one test:**

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- test -only-testing:LumoraTests/EndToEndTests
```

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- test -only-testing:LumoraTests/EndToEndTests/testSDRToHDR10HardwareHEVC
```

**Headless by design.** The tests run inside the app (a "hosted" test bundle). When Lumora detects XCTest it starts
with no windows, no Dock icon and no focus change, so a test run never interrupts whoever is using the Mac. See
`LumoraMain` in [`Lumora/App/LumoraApp.swift`](../Lumora/App/LumoraApp.swift).

**Test artefacts.** End-to-end clips, outputs and UI snapshots are written to `$TMPDIR/LumoraE2E-<pid>/` (snapshots
in its `screens/` subfolder). Open the most recent one:

```bash
open "$(ls -dt "$TMPDIR"/LumoraE2E-* | head -1)"
```

**Reading failures.** Results are stored in an `.xcresult` bundle:

```bash
xcrun xcresulttool get test-results tests --path "$(ls -dt build/DerivedData/Logs/Test/*.xcresult | head -1)"
```

A test that crashes the host shows as "Test crashed with signal …"; macOS writes a crash report to
`~/Library/Logs/DiagnosticReports/Lumora-*.ips`.

---

## Clean builds and caches

```bash
rm -rf build/DerivedData && xcodegen
```

Lumora's own runtime caches are separate from build products; see
[Command-line guide → Files and folders](command-line.md#files-and-folders).

---

## Common build failures

| Symptom | Fix |
|---|---|
| `xcodegen: command not found` | `brew install xcodegen` |
| `xcode-select: error: tool 'xcodebuild' requires Xcode` | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `Signing for "Lumora" requires a development team` | Add `CODE_SIGN_IDENTITY=-` to the command, or pick *Sign to Run Locally* in Xcode. |
| `call to 'max3' is ambiguous` (Metal) | You're on an old revision; update. The Metal standard library now defines `max3`/`min3`. |
| `The macOS deployment target … is set to 27.0, but the range of supported deployment target versions is …` | Your Xcode is too old. Install Xcode 27+. |
| Files you added don't compile in | Run `xcodegen` again; the project is generated from the folder contents. |
| Tests can't find `ffmpeg` | `brew install ffmpeg`; end-to-end tests look in `/opt/homebrew/bin` and `/usr/local/bin`. |

More in [Troubleshooting](troubleshooting.md).
