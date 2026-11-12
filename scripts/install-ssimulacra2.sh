#!/bin/bash
# Builds SSIMULACRA 2's video tool (ssimulacra2_rs) from its own source into ~/.local/bin, where Lumora finds it.
#
#   scripts/install-ssimulacra2.sh
#
# Why not plain `cargo install ssimulacra2_rs`: its video mode opens every file through VapourSynth (only stdin is
# read as Y4M), so it needs VapourSynth's libraries at link time and a VapourSynth source plugin at run time, and it
# can't read the named pipes Lumora streams frames through. The patch in scripts/patches/ssimulacra2_rs-y4m-input.patch
# makes it read Y4M files and pipes directly and drops the VapourSynth dependency; scoring code is unchanged.
#
# Needs Rust (brew install rust). Uses the release's own Cargo.lock, so dependency versions are the upstream ones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="https://github.com/rust-av/ssimulacra2_bin"
TAG="v0.5.2"
COMMIT="08fdfb9c8186134802f2e36318c619a72dcaa9e8"   # tag v0.5.2, verified 2026-11-12
PATCH="$ROOT/scripts/patches/ssimulacra2_rs-y4m-input.patch"
DEST="$HOME/.local/bin"
JOBS="${JOBS:-3}"

command -v cargo >/dev/null || { echo "Rust isn't installed. Install it with: brew install rust" >&2; exit 1; }
SRC="$(mktemp -d "${TMPDIR:-/tmp}/ssimulacra2-src.XXXXXX")"
trap 'rm -rf "$SRC"' EXIT

git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$REPO" "$COMMIT"
git -C "$SRC" checkout -q FETCH_HEAD
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "Fetched the wrong revision of $REPO" >&2; exit 1; }
git -C "$SRC" apply "$PATCH"

# cargo build (not cargo install) honors Cargo.lock; removing the VapourSynth feature only prunes entries from it.
(cd "$SRC" && nice -n 15 cargo build --release -j "$JOBS")
mkdir -p "$DEST"
install -m 0755 "$SRC/target/release/ssimulacra2_rs" "$DEST/ssimulacra2_rs"
echo "Installed $("$DEST/ssimulacra2_rs" --version) ($TAG + Y4M input patch) to $DEST/ssimulacra2_rs"
