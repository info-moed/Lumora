# Command-line guide

For people comfortable in Terminal: everything about Lumora you can drive, configure, inspect or automate from the
shell. Lumora is a GUI app with no command-line interface of its own (yet); this guide covers the scripts, settings,
files and tools around it.

Building and testing commands are in [Building from source](building.md); this guide links there rather than
repeating them.

---

## Contents

- [Keeping dependencies up to date](#keeping-dependencies-up-to-date)
- [Pointing Lumora at specific tools](#pointing-lumora-at-specific-tools)
- [Settings keys (`defaults`)](#settings-keys-defaults)
- [Files and folders](#files-and-folders)
- [Logs](#logs)
- [Encoder recipes (`encoders.json`)](#encoder-recipes-encodersjson)
- [Interpolation and upscaling models](#interpolation-and-upscaling-models)
- [Converting interpolation models](#converting-interpolation-models)
- [Quality metrics from the shell](#quality-metrics-from-the-shell)
- [Checking output files](#checking-output-files)
- [Community HDR library format](#community-hdr-library-format)
- [Batch runs and notifications](#batch-runs-and-notifications)
- [Resetting Lumora](#resetting-lumora)
- [Continuous integration](#continuous-integration)

---

## Keeping dependencies up to date

[`scripts/deps.sh`](../scripts/deps.sh) manages every external tool Lumora uses, and proves Lumora still works after
an update.

| Command | What it does |
|---|---|
| `scripts/deps.sh` or `scripts/deps.sh status` | Table of every dependency: needed or optional, installed version, latest Homebrew version, last verified version, what Lumora uses it for. Also Xcode, macOS and the Model Lab Python environment. |
| `scripts/deps.sh install` | Installs missing **required** tools (XcodeGen, FFmpeg). |
| `scripts/deps.sh install --all` | Also installs every optional encoder and metadata tool. |
| `scripts/deps.sh update` | Refreshes Homebrew, shows what would change, asks, upgrades, then runs `verify`. |
| `scripts/deps.sh update --yes --python` | Same without asking, and also upgrades `torch`, `coremltools` and `numpy` in the Model Lab environment. |
| `scripts/deps.sh verify` | The proof: (1) every flag in `encoders.json` is still accepted by the installed encoder, (2) the app builds, (3) the full test suite passes. On success it rewrites `deps.lock`. |
| `scripts/deps.sh verify --quick` | Flags and build only, no tests, no `deps.lock` update. |
| `scripts/deps.sh check [--notify] [--auto-update] [--no-verify]` | Unattended check for schedulers: refresh, report, verify (or update then verify with `--auto-update`), write a report to `~/Library/Logs/Lumora/deps-check-DATE.log`, and with `--notify` post a macOS notification when updates exist or verification fails. |
| `scripts/deps.sh schedule install` | Runs `check --notify` every Monday at 10:00 via a LaunchAgent (low priority, no windows). A missed run happens at the next wake. |
| `scripts/deps.sh schedule status` / `remove` | Show or remove the schedule. |

Exit codes: `0` OK, `1` verification failed, `2` usage error, `3` updates available (`check` only), so you can
chain it: `scripts/deps.sh check --no-verify || scripts/deps.sh update --yes`.

**`deps.lock`** records the exact versions (plus macOS and Xcode) that last passed `verify`. It's committed, so
everyone can see a known-good set. If an update breaks something, `update` prints the previous versions; hold a
tool back with `brew pin <formula>`.

**Xcode updates** can't be scripted (App Store), but `status` warns when your Xcode differs from the verified one,
and the scheduled `check` rebuilds and retests every week, so a breaking Xcode update is caught within days.

---

## Pointing Lumora at specific tools

Lumora looks for each helper tool in this order:

1. `defaults` key `toolPath.<name>` (must be an executable file)
2. `Lumora.app/Contents/Resources/bin/<name>`
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`

Tool names: `ffmpeg`, `ffprobe`, `SvtAv1EncApp`, `aomenc`, `x265`, `vvencapp`, `avmenc`, `MP4Box`, `mkvmerge`,
`dovi_tool`, `hdr10plus_tool`, `vmaf`, `ssimulacra2_rs`, `AVQT`.

Use a custom FFmpeg build:

```bash
defaults write io.github.info-moed.Lumora toolPath.ffmpeg /usr/local/opt/my-ffmpeg/bin/ffmpeg
```

Go back to automatic lookup:

```bash
defaults delete io.github.info-moed.Lumora toolPath.ffmpeg
```

Restart Lumora after changing tool paths; tool capabilities (e.g. whether FFmpeg has libvmaf or XPSNR) are probed
once at launch.

---

## Settings keys (`defaults`)

Lumora's preferences live in the `io.github.info-moed.Lumora` defaults domain. Quit Lumora before writing them.

```bash
defaults read io.github.info-moed.Lumora
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `simpleMode` | bool | `true` | Open in Simple mode. |
| `playsAV1` | bool | `true` | Simple mode: "My TV or player can play AV1". |
| `scratchRoot` | string (path) | `~/Library/Caches/Lumora Scratch` | Scratch folder for all temporary files. |
| `autoStage` | bool | `true` | Copy sources to scratch when the drive is too slow to stream. |
| `planMode` | string | `Best for this Mac` | `Fastest`, `Time budget`, `Best for this Mac` or `Maximum`. |
| `budgetHours` | real | `4` | Time budget in hours (for `Time budget`). |
| `verboseLogging` | bool | `false` | Debug-level entries in the Log window and log file (includes full encoder command lines). |
| `hdrLibraryURL` | string (URL) | none | Community HDR library JSON to sync. |
| `tmdbKey` | string | none | TMDB API key for online title lookup. |
| `optimizeBannerDismissed` | bool | `false` | Hide the "Optimize for this Mac" banner. |
| `dismissedUpgrades` | array of strings | `[]` | "More time would buy…" suggestions you dismissed. |
| `runRules` | data (JSON) | | Long-run rules; edit in Settings → Runs & Library. |
| `toolPath.<name>` | string (path) | none | Per-tool override (above). |

Examples:

```bash
defaults write io.github.info-moed.Lumora verboseLogging -bool true
```

```bash
defaults write io.github.info-moed.Lumora scratchRoot "/Volumes/FastSSD/Lumora Scratch"
```

```bash
defaults write io.github.info-moed.Lumora planMode "Time budget" && defaults write io.github.info-moed.Lumora budgetHours -float 8
```

---

## Files and folders

| Path | Contents | Safe to delete? |
|---|---|---|
| `~/Library/Caches/Lumora Scratch/` (or your `scratchRoot`) | Per-job folders (`export-…`, `grain-…`, `airplay-…`), `Proxies/` | Yes, when Lumora isn't running. Settings → Empty scratch does it for you. |
| `~/Library/Application Support/Lumora/Models/` | Core ML `.mlpackage` models, `models.json` (models you added), `model-choices.json` (best model per content type) | Models: re-convert to restore. |
| `~/Library/Application Support/Lumora/ModelLab/` | Python `venv`, Practical-RIFE checkout, converter state | Yes; Model Lab rebuilds it. |
| `~/Library/Application Support/Lumora/mac-profile.json` | "Optimize for this Mac" results | Yes (or Forget profile). |
| `~/Library/Application Support/Lumora/forecast-learning.json` | Size-forecast corrections learned from finished exports | Yes; forecasts get less accurate. |
| `~/Library/Application Support/Lumora/quality-predictor.json` | Quality-search predictor learned from past encodes | Yes; first trials get slower. |
| `~/Library/Application Support/Lumora/queue.json` | Unfinished batch queue | Yes; you lose "resume". |
| `~/Library/Application Support/Lumora/Calibration/` | Encoder speed/efficiency measured on this Mac | Yes. |
| `~/Library/Application Support/Lumora/Manifests/` | Export manifests (frame maps used by "Repair these frames") | Yes; repair of old exports stops working. |
| `~/Library/Application Support/Lumora/MotionMaps/` | Cached per-scene motion maps | Yes. |
| `~/Library/Application Support/Lumora/Regression/` | Picture regression set | Only if you don't need it. |
| `~/Library/Application Support/Lumora/hdr_library_user.json` | Your own HDR library entries | Only if you don't need them. |
| `~/Library/Application Support/Lumora/PlugIns/` | Vendor RAW plug-ins (future) | — |
| `~/Library/Logs/Lumora/` | Daily logs, dependency-check reports | Yes. |

Disk use at a glance:

```bash
du -sh ~/Library/Caches/Lumora\ Scratch ~/Library/Application\ Support/Lumora ~/Library/Logs/Lumora 2>/dev/null
```

---

## Logs

Lumora logs to three places at once:

1. **The Log window** (Tools → Log), filterable and exportable.
2. **A daily file**: `~/Library/Logs/Lumora/lumora-YYYY-MM-DD.log`.
3. **The unified system log**, subsystem `io.github.info-moed.Lumora`, with categories `app`, `ingest`,
   `analysis`, `storage`, `interpolation`, `upscale`, `encode`, `quality`, `models`, `tools`.

Follow today's file:

```bash
tail -f ~/Library/Logs/Lumora/lumora-$(date +%F).log
```

Stream live from the system log, everything:

```bash
log stream --level debug --predicate 'subsystem == "io.github.info-moed.Lumora"'
```

Only encoding and tool invocations:

```bash
log stream --level debug --predicate 'subsystem == "io.github.info-moed.Lumora" AND (category == "encode" OR category == "tools")'
```

The last hour, after the fact:

```bash
log show --last 1h --info --predicate 'subsystem == "io.github.info-moed.Lumora"'
```

With `verboseLogging` on, every encoder command line is logged under `tools`, so you can re-run an encode by hand.

---

## Encoder recipes (`encoders.json`)

Software encoders are driven by [`Lumora/Resources/encoders.json`](../Lumora/Resources/encoders.json). Each entry:

```json
"svtav1": {
  "binary": "SvtAv1EncApp",          // tool name (see "Pointing Lumora at specific tools")
  "input": "stdin",                   // "stdin" or "fifo" (named pipe for tools that can't read stdin)
  "inputArg": "stdin",                // what {in} becomes; "{fifo}" is replaced by a pipe path
  "ext": "ivf",                       // raw output extension before muxing
  "preset": "4",                      // default speed preset
  "qualityBest": 16, "qualityWorst": 40,   // CRF/QP range mapped from the 0…1 quality slider
  "args":    ["-i", "{in}", "-b", "{out}", "--preset", "{preset}", "--crf", "{quality}", …],
  "hdrArgs": ["--mastering-display", "{svt_mastering}", "--content-light", "{maxcll},{maxfall}"],
  "colorNames": {},                   // per transfer ("pq", "hlg", "sdr"): names for {cp_name} {tc_name} {mc_name}
  "tunes": { "default": [], "grain": […], "anime": […], "screen": […] }   // appended per content type
}
```

Placeholders filled at run time:

| Placeholder | Value |
|---|---|
| `{in}` `{out}` | input (stdin/pipe) and output path |
| `{w}` `{h}` `{fps_num}` `{fps_den}` `{bits}` `{threads}` | frame geometry, rate, bit depth, threads per segment |
| `{preset}` `{quality}` | speed preset; quality mapped into `qualityBest…qualityWorst` |
| `{cp}` `{tc}` `{mc}` | numeric color primaries / transfer / matrix (9/16/9 for PQ, 9/18/9 for HLG, 1/1/1 for SDR) |
| `{cp_name}` `{tc_name}` `{mc_name}` `{vvenc_hdr}` | named equivalents from `colorNames` |
| `{maxcll}` `{maxfall}` `{svt_mastering}` `{x265_mastering}` | HDR10 static metadata, measured from your film |
| `{aom_profile}` `{x265_profile}` | profile for the chosen bit depth and chroma |
| `{grain_table}` | path to a measured AV1 film-grain table |

The file is a bundle resource, so **rebuild after editing it**, then run `scripts/deps.sh verify` to confirm every
flag is accepted by your installed encoders. The extra "efficiency" options chosen by the time-budget planner live in
[`EncodeRecipes.swift`](../Lumora/Core/Quality/EncodeRecipes.swift); Lumora only offers those your encoder lists in its
`--help`.

---

## Interpolation and upscaling models

Models live in `~/Library/Application Support/Lumora/Models/`.

- Bundled descriptions: [`interpolation_models.json`](../Lumora/Resources/interpolation_models.json) and
  [`upscale_models.json`](../Lumora/Resources/upscale_models.json).
- Your own: `~/Library/Application Support/Lumora/Models/models.json`, same format; entries with the same `id`
  replace bundled ones.

An interpolation model entry:

```json
{
  "id": "rife-4-flow",
  "displayName": "RIFE 4.x HDR flow (true 10/12-bit, recommended for HDR)",
  "file": "RIFE4Flow.mlpackage",
  "inputA": "img0", "inputB": "img1",
  "timestep": "timestep", "timestepKind": "map",
  "output": "output",
  "padMultiple": 64,
  "tier": "best",
  "license": "MIT (Practical-RIFE)",
  "outputKind": "flow", "flowOutput": "flow", "maskOutput": "mask"
}
```

`outputKind: "flow"` models only predict motion; Lumora then warps the original 10/12-bit frames itself in 32-bit
float. Image models return the finished frame. With no model installed, generated frames fall back to blending.

---

## Converting interpolation models

Model Lab (Tools → Model Lab) does all of this for you. By hand:

```bash
python3 -m venv ~/rife-venv && source ~/rife-venv/bin/activate && pip install torch coremltools numpy
```

```bash
git clone https://github.com/hzwer/Practical-RIFE
```

Download the 4.x weights as described in Practical-RIFE's README into `Practical-RIFE/train_log/`, then:

```bash
python scripts/convert_rife_coreml.py --rife-dir Practical-RIFE --weights Practical-RIFE/train_log --out RIFE4.mlpackage
```

```bash
python scripts/convert_rife_coreml.py --rife-dir Practical-RIFE --weights Practical-RIFE/train_log --flow-output --out RIFE4Flow.mlpackage
```

```bash
cp -R RIFE4.mlpackage RIFE4Flow.mlpackage ~/Library/Application\ Support/Lumora/Models/
```

Options: `--max-size` (largest dimension, default 4096), `--mask-is-logit` (if your RIFE version returns raw mask
logits). Real-ESRGAN: `scripts/convert_realesrgan_coreml.py --model <name> --weights <file.pth>`.

---

## Quality metrics from the shell

Lumora's metrics are ordinary tools, so you can reproduce its scores.

VMAF of an encode against a reference (both decoded by FFmpeg; needs FFmpeg built with libvmaf):

```bash
ffmpeg -i encoded.mkv -i reference.mov -lavfi "[0:v][1:v]libvmaf=log_fmt=json:log_path=vmaf.json:n_threads=8" -f null -
```

With the standalone `vmaf` tool (from `brew install libvmaf`), using Y4M files:

```bash
vmaf -r reference.y4m -d encoded.y4m --json -o vmaf.json
```

XPSNR (FFmpeg 7+):

```bash
ffmpeg -i encoded.mkv -i reference.mov -lavfi xpsnr -f null -
```

ColorVideoVDP and PU21-PSNR are installed by Model Lab into its Python environment; see
[`lumora_metrics.py`](../Lumora/Resources/lumora_metrics.py) for how Lumora calls them.

---

## Checking output files

Basic stream facts, including HDR signaling:

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,pix_fmt,width,height,r_frame_rate,color_range,color_space,color_transfer,color_primaries -of default=nw=1 output.mov
```

HDR10 static metadata (mastering display, MaxCLL/MaxFALL):

```bash
ffprobe -v error -select_streams v:0 -show_frames -read_intervals "%+#1" -show_entries frame=side_data_list -of json output.mov
```

Exact frame count:

```bash
ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 output.mov
```

Decode every frame and report errors (what Lumora's "Verify" does):

```bash
ffmpeg -v error -i output.mkv -f null - && echo "decodes cleanly"
```

Dolby Vision: extract the RPU and summarize it:

```bash
ffmpeg -v error -i output.mkv -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | dovi_tool extract-rpu - -o rpu.bin && dovi_tool info -i rpu.bin --summary
```

HDR10+: extract dynamic metadata:

```bash
ffmpeg -v error -i output.mkv -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc - | hdr10plus_tool extract - -o hdr10plus.json
```

Lumora's appendices sit next to the video with the same base name: `.sha256` (checksum), `.lumora.json` (settings),
`.quality.txt`, `.nfo`, `-poster.jpg`, `.chapters.txt`, `.hdr-report.txt` and `.log`. The checksum file uses the
standard `shasum` format; check it from the video's folder:

```bash
shasum -a 256 -c "Movie (2020).sha256"
```

---

## Community HDR library format

Point Lumora at a JSON array of titles (Settings or `defaults write … hdrLibraryURL https://…/library.json`):

```json
[
  {
    "title": "Example Film",
    "year": 2017,
    "edition": "2017 UHD Blu-ray",
    "hdrFormats": ["HDR10", "Dolby Vision P7 FEL"],
    "masteringPeakNits": 1000,
    "maxCLL": 940,
    "maxFALL": 210,
    "measuredP999Nits": 820,
    "nativeResolution": "4K DI",
    "rating": "Great",
    "reasons": ["Bright, detailed highlights", "Natural skin"],
    "sources": ["https://example.org/measurements"],
    "contributedBy": "your-name"
  }
]
```

`rating` is one of `Reference`, `Great`, `Average`, `Dim / conservative`, `Poor`. Optional fields may be omitted.
Respect the original authors' terms when compiling community measurements.

---

## Batch runs and notifications

- **Tools → Batch process a folder…** applies the current settings to every file in a folder. The queue is saved in
  `queue.json` and resumes after a quit or crash; finished files are skipped.
- **Run rules** (Settings → Runs & Library): working hours, pause on battery, pause when hot.
- **Webhook:** when a batch finishes, Lumora sends a message to the URL you set. An [ntfy](https://ntfy.sh) topic is
  the simplest way to reach a phone. Test your topic first:

  ```bash
  curl -d "Lumora test" https://ntfy.sh/your-private-topic-name
  ```

  Treat the topic name like a password: anyone who knows it can read your notifications.

---

## Resetting Lumora

Quit Lumora first.

Preferences only:

```bash
defaults delete io.github.info-moed.Lumora
```

Scratch and caches:

```bash
rm -rf ~/Library/Caches/Lumora\ Scratch
```

Everything Lumora has learned or stored, including models, the Model Lab environment, the regression set and the
batch queue (this cannot be undone):

```bash
rm -rf ~/Library/Application\ Support/Lumora
```

---

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on GitHub's `xcode-27` runner (macOS 27, Apple
silicon):

- on every push and pull request,
- **every Monday**, against the newest Homebrew encoders and the runner's newest Xcode 27, so breaking dependency
  updates are caught even when nobody pushes,
- on demand (**Actions → CI → Run workflow**), optionally with a specific Xcode (e.g. `Xcode_27.2.app`).

It runs `scripts/deps.sh status` and `scripts/deps.sh verify`, and uploads the log, the `.xcresult` bundle and the
verified `deps.lock` as an artifact. The `xcode-27` runner currently provides a GPU and the hardware video encoder,
so the whole suite runs there. On a machine without them, those tests **skip** with a reason instead of failing; the
weekly local check (`scripts/deps.sh schedule install`) covers them on a real Mac.
[Dependabot](../.github/dependabot.yml) keeps the workflow's actions current.

Run the same check locally before pushing:

```bash
scripts/deps.sh verify
```
