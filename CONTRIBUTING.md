# Contributing to Lumora

Thanks for helping. Bug reports, test results from other Macs, documentation fixes and code are all welcome.

## Reporting a bug

[Open an issue](https://github.com/info-moed/Lumora/issues) with:

1. what you did, what you expected, and what happened;
2. `scripts/deps.sh status` output;
3. the relevant lines from `~/Library/Logs/Lumora/lumora-YYYY-MM-DD.log` (turn on `verboseLogging` for tool command
   lines; see the [Command-line guide](docs/command-line.md#logs));
4. if possible, a short sample file or the `ffprobe` output of yours.

Remove private paths and names first. Security problems go through [SECURITY.md](SECURITY.md) instead.

**Trying an unverified feature?** Reports that something *works* are just as useful: they move features up the
[status table](README.md#project-status).

## Setting up

```bash
scripts/deps.sh install --all
```

```bash
xcodegen && open Lumora.xcodeproj
```

Details: [Building from source](docs/building.md). Code tour: [Architecture](docs/architecture.md).

## Before you open a pull request

```bash
scripts/deps.sh verify
```

That checks encoder flags, builds, and runs the whole test suite (headless; about a minute). CI runs the same on
GitHub's macOS 27 / Xcode 27 runner for every push and pull request.

- **Add a test** for any bug you fix or feature you add. End-to-end tests (`EndToEndTests`) are the best proof:
  generate a small clip with FFmpeg, run the real pipeline, check the file with `ffprobe`. Hostile-input fixes go in
  `SecurityTests`.
- **Keep the one grading path.** Preview, analysis and export must share `gradeKernel` and `UniformBuilder`.
- **Never write next to the source**; use `ScratchManager.jobDirectory`.
- **No shell.** Launch tools through `ToolLocator` with argument arrays.
- **Explain choices in plain English** wherever the UI makes a decision for the user.
- **Update the docs** you affect, and add a line to `CHANGELOG.md` under *Unreleased*.
- Regenerate the project with `xcodegen` after adding files; don't commit `Lumora.xcodeproj`.

## Code style

Follow the surrounding code: Swift 5 language mode, `@MainActor @Observable` for UI state, structured concurrency
for pipelines, small focused types, doc comments that say *why*. Metal changes must keep `ShaderTypes.h` as the
single definition of shared structs.

## License

By contributing you agree that your contribution is released under the project's [MIT license](LICENSE).
