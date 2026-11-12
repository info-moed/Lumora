#!/bin/bash
# Copies helper tools into Lumora.app/Contents/Resources/bin for distribution builds.
# NOTE: Homebrew binaries link to Homebrew dylibs. For a shippable app, use static builds or a tool like
# dylibbundler, and check each tool's licence (FFmpeg built with GPL parts and x265 are GPL).
set -e
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/bin"
mkdir -p "$DEST"
for t in ffmpeg ffprobe SvtAv1EncApp aomenc x265 vvencapp avmenc MP4Box mkvmerge dovi_tool hdr10plus_tool; do
  for d in /opt/homebrew/bin "$HOME/.local/bin"; do
    [ -x "$d/$t" ] && cp -f "$d/$t" "$DEST/" && break
  done
done
