#!/bin/bash
# Copies helper tools into Lumora.app/Contents/Resources/bin for distribution builds.
#
# Only self-contained binaries are copied: a tool that links libraries outside macOS itself (Homebrew builds
# link @rpath/... or /opt/homebrew/... dylibs) would fail to launch from inside the app, and because bundled
# tools win over Homebrew ones in ToolLocator, a broken copy would shadow a working install. Those tools are
# simply found in Homebrew at run time instead. For a shippable app, use static builds or relink with a tool
# like dylibbundler, and check each tool's licence (FFmpeg built with GPL parts and x265 are GPL).
set -e
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/bin"
mkdir -p "$DEST"
self_contained() {
  # Every linked library must be part of macOS (/usr/lib or /System).
  ! otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -vqE '^(/usr/lib/|/System/)'
}
for t in ffmpeg ffprobe SvtAv1EncApp aomenc x265 vvencapp avmenc MP4Box mkvmerge dovi_tool hdr10plus_tool; do
  rm -f "$DEST/$t"
  for d in /opt/homebrew/bin "$HOME/.local/bin"; do
    if [ -x "$d/$t" ]; then
      src="$(readlink -f "$d/$t")"
      if self_contained "$src"; then cp -f "$src" "$DEST/$t"; else echo "note: $t links non-system libraries; using it from $d at run time"; fi
      break
    fi
  done
done
