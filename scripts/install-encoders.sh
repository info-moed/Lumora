#!/bin/bash
# Installs the open-source helper tools Lumora drives. Everything except AVM comes from Homebrew.
set -euo pipefail
brew install xcodegen ffmpeg libvmaf svt-av1 aom x265 vvenc gpac mkvtoolnix dovi_tool hdr10plus_tool || true
# VMAF: the 'vmaf' command comes with libvmaf. Check with:  vmaf --version

# AV2: the AOMedia reference encoder (AVM). Builds from source; expect very slow encodes.
if ! command -v avmenc >/dev/null; then
  git clone --depth 1 https://gitlab.com/AOMediaCodec/avm.git /tmp/avm
  cmake -S /tmp/avm -B /tmp/avm/build -DCMAKE_BUILD_TYPE=Release
  cmake --build /tmp/avm/build -j"$(sysctl -n hw.ncpu)"
  mkdir -p "$HOME/.local/bin" && cp /tmp/avm/build/avmenc /tmp/avm/build/avmdec "$HOME/.local/bin/" 2>/dev/null || \
    echo "AVM built in /tmp/avm/build — copy the encoder binary to ~/.local/bin/avmenc"
fi
echo "Done. Formula names can change; if one failed, search 'brew search <name>'."
