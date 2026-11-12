# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/info-moed/Lumora/security/advisories/new) rather than a public
issue. Include the Lumora version or commit, macOS version, and a minimal file or steps that reproduce it.

## Threat model

Lumora is a desktop app that opens video files you give it, runs open-source command-line tools on them, and writes
new files where you choose. The inputs it treats as **untrusted** are:

- video files and everything inside them (metadata, tags, track and chapter names, declared sizes and frame rates),
- file and folder names,
- imported presets, community HDR-library JSON, online title lookups (TMDB),
- downloaded or imported interpolation-model archives.

## What Lumora does about it

| Risk | Defence |
|---|---|
| Command injection | Every tool is launched with an argument array, never a shell. Source and output paths are absolute, so names can't become options. |
| FFmpeg reaching other resources | Every FFmpeg/ffprobe input is restricted to `file,pipe,fd` protocols, so a playlist disguised as a video can't fetch anything. |
| Writing outside the chosen folder | Output names are sanitised per path component (no `..`, leading dots or control characters) and the final path is checked to be inside the destination. |
| Destroying the source | An export or package that would replace its own source is refused; an older output is moved to the Trash, not deleted. |
| Malformed files crashing the app | Frame rates outside 1–1000 fps, impossible frame counts and sizes outside 16–16384 px are rejected or clamped before they reach timing or GPU code. |
| Personal metadata leaking | "Remove personal details" copies back only an allowlist of safe tags; sidecar files drop home-folder paths unless you keep metadata. |
| Secrets | The TMDB API key lives in the login Keychain. Neither it nor the notification webhook is logged. |
| Model archives running code | Catalog downloads are pinned to published SHA-256 digests and re-checked before conversion; anything else is checksummed on import and Lumora asks before converting it. Checkpoints load with PyTorch `weights_only`, Python packages install from prebuilt wheels only, the Practical-RIFE source is pinned to a commit, and archives with symbolic links are refused. |
| Loading foreign code | Release builds use the hardened runtime with library validation (no `disable-library-validation`). |

Regression tests for each of these live in [`Tests/LumoraTests/SecurityTests.swift`](Tests/LumoraTests/SecurityTests.swift).

## Known limitations

- **Model conversion runs third-party Python.** Each RIFE release ships its network definition as Python inside its
  archive; converting it runs that code on your Mac. Pinned checksums protect catalog downloads from being swapped;
  for anything you import yourself, only convert archives from sources you trust.
- **Not sandboxed.** Lumora launches encoder tools and reads files anywhere you point it, which the App Sandbox
  doesn't allow. It runs with your user's permissions.
- **Helper tools are only as safe as their versions.** Keep them current with `scripts/deps.sh update`.
- **Webhooks send file names** to the service you configure. Use a private topic.
