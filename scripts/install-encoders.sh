#!/bin/bash
# Installs the open-source helper tools Lumora drives. Everything except AVM comes from Homebrew.
set -euo pipefail
brew install xcodegen ffmpeg libvmaf svt-av1 aom x265 vvenc gpac mkvtoolnix dovi_tool hdr10plus_tool || true
# VMAF: the 'vmaf' command comes with libvmaf. Check with:  vmaf --version

# AV2: the AOMedia reference encoder and decoder (AVM), built from the official repository at a release tag. Every
# third-party library it needs (TensorFlow Lite, abseil, XNNPACK…) ships inside that repository as a tarball.
# Build options: ENABLE_EXAMPLES is what builds avmenc and avmdec; tests, docs and tools are skipped. The build runs
# at low priority with 4 jobs (AVM_JOBS=n to change) and takes about 10 minutes on an M-series Mac; expect very slow
# encodes (see docs/features.md → AV2). Rebuild a newer tag with AVM_TAG=research-vX.Y.Z AVM_REBUILD=1.
AVM_TAG="${AVM_TAG:-research-v15.0.0}"
AVM_DIR="${AVM_DIR:-$HOME/Library/Caches/Lumora-AVM}"
if ! command -v avmenc >/dev/null || [ "${AVM_REBUILD:-0}" = 1 ]; then
  command -v cmake >/dev/null || brew install cmake
  rm -rf "$AVM_DIR/src" "$AVM_DIR/build"
  mkdir -p "$AVM_DIR"
  git clone --depth 1 --branch "$AVM_TAG" https://gitlab.com/AOMediaCodec/avm.git "$AVM_DIR/src"
  nice -n 15 cmake -S "$AVM_DIR/src" -B "$AVM_DIR/build" -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_EXAMPLES=1 -DENABLE_TESTS=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0
  nice -n 15 cmake --build "$AVM_DIR/build" -j"${AVM_JOBS:-4}" --target avmenc avmdec
  mkdir -p "$HOME/.local/bin"
  cp "$AVM_DIR/build/avmenc" "$AVM_DIR/build/avmdec" "$HOME/.local/bin/"
  "$HOME/.local/bin/avmenc" --help 2>&1 | tail -3 | grep -i "AV2 Encoder" || true
fi
echo "Done. Formula names can change; if one failed, search 'brew search <name>'."
