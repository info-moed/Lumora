#!/bin/bash
# Regenerates the documentation screenshots in docs/images/ (headless: nothing appears on screen).
# Every screen is rendered offscreen by Tests/LumoraTests/ScreenshotTests.swift with original, generated footage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${LUMORA_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Lumora-deps}"
OUT="${TMPDIR:-/tmp}/LumoraScreenshots"
rm -f "$OUT"/*.png 2>/dev/null || true
cd "$ROOT"
xcodegen -q
TEST_RUNNER_LUMORA_SCREENSHOTS=1 xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- test -only-testing:LumoraTests/ScreenshotTests > "$OUT.log" 2>&1 || {
  echo "Screenshot run failed; see $OUT.log"; grep -E 'error:|failed' "$OUT.log" | head -20; exit 1; }
mkdir -p docs/images
for f in "$OUT"/*.png; do
  # Retina captures are 2x; 1600 px wide keeps them sharp on GitHub and small in the repository.
  sips -s format png --resampleWidth 1600 "$f" --out "docs/images/$(basename "$f")" >/dev/null
done
# Privacy: nothing personal may appear in a published screenshot.
TEXT=$(swift "$ROOT/scripts/ocr-text.swift" docs/images/*.png 2>/dev/null)
LEAK=$(printf '%s' "$TEXT" | grep -iE "/Users/|$(id -un)|privaterelay" | head -5)
if [ -n "$LEAK" ]; then echo "Screenshots show personal information; not keeping them:"; echo "$LEAK"; git -C "$ROOT" checkout -q -- docs/images 2>/dev/null; exit 1; fi
echo "Wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') screenshots to docs/images/ (privacy scan clean)"
