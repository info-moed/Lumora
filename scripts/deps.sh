#!/bin/bash
# Lumora dependency manager: see what's installed, update it, and prove the result still builds and works.
#
#   scripts/deps.sh                   same as "status"
#   scripts/deps.sh status            installed vs latest vs last-verified version of every dependency
#   scripts/deps.sh install [--all]   install missing required tools (--all: optional encoders too)
#   scripts/deps.sh update [--yes] [--python]
#                                     upgrade outdated tools, then verify; record versions only if verify passes
#   scripts/deps.sh verify [--quick]  encoder-flag check + build + full test suite (--quick: flags + build only)
#   scripts/deps.sh check [--auto-update] [--no-verify] [--notify]
#                                     unattended check (used by the schedule): report what's outdated, verify,
#                                     optionally update, write a report, and post a notification when needed
#   scripts/deps.sh schedule install|remove|status
#                                     run "check --notify" weekly on this Mac via a LaunchAgent, from a dedicated
#                                     clone in ~/Library/Application Support/Lumora/DependencyCheck (kept up to date)
#
# Exit codes: 0 ok, 1 verification failed, 2 usage error, 3 updates available (check only).
# Works with macOS's /bin/bash 3.2. Needs Homebrew for anything beyond "status" and "verify".

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/deps.lock"
BUILD="$ROOT/build"
# Build products live outside the repository by default. A test run launches the freshly built app; if it sat inside
# a folder macOS protects (Downloads, Desktop, Documents), every rebuild would ask for permission again.
DERIVED="${LUMORA_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Lumora-deps}"
LOGDIR="$HOME/Library/Logs/Lumora"
LABEL="io.github.info-moed.Lumora.deps-check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

# formula | binary that proves it's installed | required? | what Lumora uses it for
DEPS="xcodegen|xcodegen|required|generates the Xcode project
ffmpeg|ffmpeg|required|reads non-AVFoundation files, joins segments, carries audio/subtitles, end-to-end tests
svt-av1|SvtAv1EncApp|optional|AV1 export
aom|aomenc|optional|AV1 Pro export (12-bit, 4:2:2, 4:4:4)
x265|x265|optional|12-bit HEVC export
vvenc|vvencapp|optional|H.266 / VVC export
libvmaf|vmaf|optional|quality-target encoding and VMAF/CAMBI/MS-SSIM metrics
gpac|MP4Box|optional|Dolby Vision MP4 muxing
mkvtoolnix|mkvmerge|optional|MKV muxing with Dolby Vision / chapters
dovi_tool|dovi_tool|optional|Dolby Vision metadata (generate, keep and retime)
hdr10plus_tool|hdr10plus_tool|optional|HDR10+ metadata"

# encoders.json key | binary | how to get its full option list
ENCODER_HELP="svtav1|SvtAv1EncApp|--help
aomenc|aomenc|--help
x265|x265|--fullhelp
vvenc|vvencapp|--fullhelp
avm|avmenc|--help"

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B= G= Y= R= D= N=; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '%s✗%s %s\n' "$R" "$N" "$*"; }
die()  { bad "$*"; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

lock_get() { [ -f "$LOCK" ] && awk -v k="$1" '$1==k { $1=""; sub(/^ /,""); print; exit }' "$LOCK"; }
xcode_version() { xcodebuild -version 2>/dev/null | awk 'NR==1{v=$2} NR==2{b=$3} END{ if (v) print v" ("b")" }'; }
macos_version() { sw_vers -productVersion 2>/dev/null; }

# One `brew info` call for every formula: "name installed stable outdated" per line.
brew_table() {
  have brew || return 0
  local names; names=$(printf '%s\n' "$DEPS" | cut -d'|' -f1 | tr '\n' ' ')
  # shellcheck disable=SC2086
  brew info --json=v2 $names 2>/dev/null | python3 -I -c '
import json, sys
for f in json.load(sys.stdin).get("formulae", []):
    inst = f.get("installed") or []
    v = inst[-1]["version"] if inst else "-"
    print(f["name"], v, f["versions"]["stable"], "yes" if f.get("outdated") else "no")'
}

# Can each installed tool actually start? Catches missing-library breakage after partial upgrades
# (e.g. "Library not loaded: …libboost_system.dylib"), which version numbers alone don't show.
version_arg() { case "$1" in ffmpeg|ffprobe|MP4Box) echo -version;; aomenc) echo --help;; *) echo --version;; esac; }
health() {
  local broken=0 bins
  bins="$(printf '%s\n' "$DEPS" | cut -d'|' -f2) ffprobe avmenc"
  for bin in $bins; do
    have "$bin" || continue
    local out rc
    out=$("$bin" "$(version_arg "$bin")" 2>&1 </dev/null); rc=$?
    if printf '%s' "$out" | grep -qE 'Library not loaded|dyld\[|image not found|Symbol not found' || [ $rc -ge 128 ]; then
      bad "$bin is installed but can't start: $(printf '%s' "$out" | grep -m1 -E 'Library not loaded|Symbol not found|dyld' | sed -E 's/^[[:space:]]+//' | cut -c1-110)"
      broken=$((broken+1))
    fi
  done
  [ $broken -eq 0 ] && ok "Every installed tool starts" || say "  Fix: brew reinstall <formula>  (or run 'brew doctor'); scripts/deps.sh verify fails until this is fixed."
  return $broken
}

cmd_status() {
  say "${B}Lumora dependencies${N}  ${D}(versions from Homebrew; last verified: $(lock_get verified || echo never))${N}"
  say ""
  local xv; xv=$(xcode_version)
  local xl; xl=$(lock_get xcode)
  if [ -z "$xv" ]; then bad "Xcode: not found (install Xcode 27+ from the App Store)"
  elif [ -n "$xl" ] && [ "$xv" != "$xl" ]; then warn "Xcode $xv  ${D}(last verified with $xl; run: scripts/deps.sh verify)${N}"
  else ok "Xcode $xv"; fi
  say "  macOS $(macos_version)"
  have brew || { bad "Homebrew: not installed (https://brew.sh)"; return 0; }
  say ""
  printf "${B}%-15s %-9s %-12s %-12s %-12s %s${N}\n" "Formula" "Needed" "Installed" "Latest" "Verified" "Used for"
  local table; table=$(brew_table)
  local outdated=0 missing=0
  while IFS='|' read -r name bin need why; do
    local row inst stable od locked mark
    row=$(printf '%s\n' "$table" | awk -v n="$name" '$1==n')
    inst=$(printf '%s' "$row" | awk '{print $2}'); stable=$(printf '%s' "$row" | awk '{print $3}'); od=$(printf '%s' "$row" | awk '{print $4}')
    [ -z "$inst" ] && inst="-"; [ -z "$stable" ] && stable="?"
    locked=$(lock_get "$name"); [ -z "$locked" ] && locked="-"
    if [ "$inst" = "-" ]; then
      if have "$bin"; then inst="(not brew)"; mark="$Y"; else mark=$([ "$need" = required ] && echo "$R" || echo "$D"); [ "$need" = required ] && missing=$((missing+1)); fi
    elif [ "$od" = "yes" ]; then mark="$Y"; outdated=$((outdated+1))
    else mark="$G"; fi
    printf "%s%-15s%s %-9s %-12s %-12s %-12s %s\n" "$mark" "$name" "$N" "$need" "$inst" "$stable" "$locked" "$why"
  done <<EOF
$DEPS
EOF
  if have avmenc; then say "${G}avmenc${N}          optional  (source)     -            -            AV2 export (built from source; rebuild with scripts/install-encoders.sh)"
  else say "${D}avmenc          optional  -            -            -            AV2 export (built from source by scripts/install-encoders.sh)${N}"; fi
  if have ssimulacra2_rs; then say "${G}ssimulacra2_rs${N}  optional  $(printf '%-12s' "$(ssimulacra2_rs --version 2>/dev/null | awk '{print $2}')") -            -            SSIMULACRA 2 metric (built from source; rebuild with scripts/install-ssimulacra2.sh)"
  else say "${D}ssimulacra2_rs  optional  -            -            -            SSIMULACRA 2 metric (built from source by scripts/install-ssimulacra2.sh)${N}"; fi
  local venv="$HOME/Library/Application Support/Lumora/ModelLab/venv"
  if [ -x "$venv/bin/python" ]; then
    say ""; say "${B}Model Lab Python environment${N}  ${D}$venv${N}"
    "$venv/bin/python" -m pip list --outdated --format=json 2>/dev/null | python3 -I -c '
import json, sys
watch = {"torch", "coremltools", "numpy", "cvvdp"}
rows = [p for p in json.load(sys.stdin) if p["name"].lower() in watch]
print("\n".join("  %s: %s -> %s" % (p["name"], p["version"], p["latest_version"]) for p in rows) or "  up to date")' || true
  fi
  say ""
  health
  [ "$missing" -gt 0 ] && bad "$missing required tool(s) missing: run scripts/deps.sh install"
  [ "$outdated" -gt 0 ] && warn "$outdated tool(s) can be updated: run scripts/deps.sh update"
  [ "$missing" -eq 0 ] && [ "$outdated" -eq 0 ] && ok "Everything installed is up to date (as of Homebrew's last refresh; 'brew update' refreshes it)."
  return 0
}

cmd_install() {
  have brew || die "Homebrew is required: https://brew.sh"
  local want=""
  while IFS='|' read -r name bin need _; do
    { [ "$need" = required ] || [ "${1:-}" = "--all" ]; } || continue
    have "$bin" || want="$want $name"
  done <<EOF
$DEPS
EOF
  if [ -n "$want" ]; then
    say "Installing:$want"
    # shellcheck disable=SC2086
    brew install $want
  fi
  # SSIMULACRA 2's video tool isn't in Homebrew: build it (needs Rust from Homebrew).
  if [ "${1:-}" = "--all" ] && ! have ssimulacra2_rs; then
    have cargo || brew install rust
    bash "$ROOT/scripts/install-ssimulacra2.sh"
  elif [ -z "$want" ]; then
    ok "Nothing to install."
  fi
}

# Every flag in encoders.json must still be listed in the installed encoder's own help text.
verify_flags() {
  local failures=0 json="$ROOT/Lumora/Resources/encoders.json"
  while IFS='|' read -r key bin helparg; do
    have "$bin" || { say "  ${D}$bin not installed; skipped${N}"; continue; }
    # Normalize "--[no-]flag" (x265, vvenc) so it counts as listing "--flag".
    local help; help=$("$bin" "$helparg" 2>&1 | sed 's/--\[no-\]/--/g' || true)
    local flags; flags=$(python3 -I - "$json" "$key" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))[sys.argv[2]]
seen = set()
for lst in [spec["args"], spec["hdrArgs"], *(spec.get("tunes") or {}).values()]:
    for a in lst:
        if a.startswith("-") and not a.lstrip("-").replace(".", "").isdigit():
            seen.add(a.split("=")[0])
print("\n".join(sorted(seen)))
PY
)
    local missing=""
    for f in $flags; do
      printf '%s' "$help" | grep -qE -- "(^|[^A-Za-z0-9-])${f}([^A-Za-z0-9-]|$)" || missing="$missing $f"
    done
    if [ -n "$missing" ]; then bad "$bin $(${bin} --version 2>&1 | head -1 | cut -c1-60): no longer lists:$missing"; failures=$((failures+1))
    else ok "$bin accepts every flag in encoders.json ($key)"; fi
  done <<EOF
$ENCODER_HELP
EOF
  return $failures
}

cmd_verify() {
  local quick="${1:-}"
  mkdir -p "$BUILD"
  local log="$BUILD/deps-verify.log"; : > "$log"
  say "${B}0/3 Tools start${N}"
  health; local health_rc=$?
  say "${B}1/3 Encoder flags${N}"
  verify_flags; local flags_rc=$?
  python3 "$ROOT/scripts/encoding_reference.py" check 2>/dev/null | sed 's/^/  /' || true
  say "${B}2/3 Build${N}"
  have xcodegen || { bad "xcodegen missing: scripts/deps.sh install"; return 1; }
  (cd "$ROOT" && xcodegen -q) >>"$log" 2>&1 || { bad "xcodegen failed (see $log)"; return 1; }
  if (cd "$ROOT" && xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Debug -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- build) >>"$log" 2>&1; then
    ok "Build succeeded"
  else
    bad "Build failed:"; grep -E ': error:' "$log" | sed "s|$ROOT/||" | sort -u | head -20; say "  full log: $log"; return 1
  fi
  local tests_rc=0
  if [ "$quick" = "--quick" ]; then say "${B}3/3 Tests${N} ${D}skipped (--quick)${N}"
  else
    say "${B}3/3 Tests${N} ${D}(headless; about a minute)${N}"
    if (cd "$ROOT" && xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- test) >>"$log" 2>&1; then
      ok "$(grep -E 'Executed [0-9]+ tests' "$log" | tail -1 | sed -E 's/^[[:space:]]+//')"
    else
      tests_rc=1
      bad "Tests failed:"; grep -E "(error: -\[|Test Case .* failed|crashed)" "$log" | sed "s|$ROOT/||" | sort -u | head -20; say "  full log: $log"
    fi
  fi
  if [ $health_rc -ne 0 ] || [ $flags_rc -ne 0 ] || [ $tests_rc -ne 0 ]; then return 1; fi
  [ "$quick" = "--quick" ] || write_lock
  return 0
}

write_lock() {
  {
    say "# Dependency versions last verified by scripts/deps.sh verify:"
    say "# encoder-flag check + build + full test suite all passed with exactly these versions."
    say "# Rewritten automatically after every successful verify. Commit it so others know a known-good set."
    say "verified $(date +%Y-%m-%d)"
    say "macos $(macos_version)"
    say "xcode $(xcode_version)"
    brew_table | awk '$2!="-" { print $1, $2 }'
  } > "$LOCK"
  ok "Recorded verified versions in deps.lock"
}

outdated_list() {
  brew_table | awk '$4=="yes" { print $1 }' | tr '\n' ' '
}

cmd_update() {
  local yes="" python=""
  for a in "$@"; do case "$a" in --yes|-y) yes=1;; --python) python=1;; *) die "unknown option $a";; esac; done
  have brew || die "Homebrew is required: https://brew.sh"
  say "Refreshing Homebrew…"; brew update --quiet >/dev/null 2>&1 || warn "brew update failed; using cached formula data"
  local outdated; outdated=$(outdated_list)
  if [ -z "${outdated// }" ] && [ -z "$python" ]; then ok "All installed dependencies are already up to date."; return 0; fi
  if [ -n "${outdated// }" ]; then
    say "Will upgrade: ${B}$outdated${N}"
    brew_table | awk -v l=" $outdated " 'index(l, " "$1" ") { printf "  %-15s %s -> %s\n", $1, $2, $3 }'
    if [ -z "$yes" ]; then
      printf "Continue? [y/N] "; read -r reply; case "$reply" in y|Y|yes) ;; *) say "Nothing changed."; return 0;; esac
    fi
    # shellcheck disable=SC2086
    if ! brew upgrade $outdated; then
      bad "brew upgrade reported a problem (often a link conflict with an older formula; see brew's message above)."
      say "  Typical fixes: 'brew upgrade <conflicting formula>', or 'brew unlink <old formula>' then 'brew link <new formula>'."
      say "  Checking which tools still work, then verifying Lumora anyway…"
    fi
  fi
  if [ -n "$python" ]; then
    local venv="$HOME/Library/Application Support/Lumora/ModelLab/venv"
    if [ -x "$venv/bin/python" ]; then "$venv/bin/python" -m pip install --upgrade torch coremltools numpy || warn "pip upgrade failed"
    else warn "No Model Lab environment yet (create it from Model Lab in the app)"; fi
  fi
  say ""; say "Verifying the upgraded set…"
  if cmd_verify; then ok "Update complete and verified."; return 0; fi
  bad "The upgraded tools broke the build, the tests or the encoder flags."
  say "Previously verified versions (deps.lock):"; grep -vE '^(#|verified|macos|xcode)' "$LOCK" 2>/dev/null | sed 's/^/  /'
  say "Options: fix the code or encoders.json, or hold a tool back with 'brew pin <formula>' and reinstall the older version."
  return 1
}

notify() {
  # Lumora's own scheduled check posting a Notification Center banner.
  osascript -e "display notification \"$2\" with title \"Lumora\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

cmd_check() {
  local auto="" verify=1 notifyme=""
  local pull=""
  for a in "$@"; do case "$a" in --auto-update) auto=1;; --no-verify) verify="";; --notify) notifyme=1;; --pull) pull=1;; *) die "unknown option $a";; esac; done
  if [ -n "$pull" ]; then git -C "$ROOT" pull --ff-only -q 2>/dev/null || warn "couldn't update the check clone; checking the current copy"; fi
  mkdir -p "$LOGDIR"
  local report; report="$LOGDIR/deps-check-$(date +%Y-%m-%d).log"
  {
    say "Lumora dependency check, $(date)"
    if have brew; then brew update --quiet >/dev/null 2>&1 || say "brew update failed; using cached data"; fi
    cmd_status
    local outdated; outdated=$(outdated_list)
    local rc=0
    if [ -n "$auto" ] && [ -n "${outdated// }" ]; then
      cmd_update --yes || rc=1
    elif [ -n "$verify" ]; then
      say ""; cmd_verify || rc=1
    fi
    if [ $rc -ne 0 ]; then
      [ -n "$notifyme" ] && notify "Check failed" "Lumora no longer builds or passes its tests. See $report"
      exit 1
    elif [ -n "${outdated// }" ] && [ -z "$auto" ]; then
      [ -n "$notifyme" ] && notify "Updates available" "$outdated- run scripts/deps.sh update"
      exit 3
    fi
    exit 0
  } 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tee "$report"
  return "${PIPESTATUS[0]}"
}

cmd_schedule() {
  case "${1:-status}" in
    install)
      mkdir -p "$(dirname "$PLIST")" "$LOGDIR"
      # Background jobs can't be granted access to Downloads/Desktop/Documents, so the weekly check runs from its own
      # clone of this repository's remote, outside those folders, updated before every check.
      local origin; origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
      [ -n "$origin" ] || die "The weekly check needs a git clone with a remote (git clone https://github.com/info-moed/Lumora.git)."
      local clone="$HOME/Library/Application Support/Lumora/DependencyCheck/Lumora"
      if [ -d "$clone/.git" ]; then git -C "$clone" pull --ff-only -q || die "couldn't update $clone"
      else mkdir -p "$(dirname "$clone")" && git clone -q "$origin" "$clone" || die "couldn't clone $origin"; fi
      local runner="$clone/scripts/deps.sh"
      cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$runner</string><string>check</string><string>--pull</string><string>--notify</string></array>
  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGDIR/deps-check.out.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/deps-check.out.log</string>
</dict>
</plist>
PL
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST" && ok "Weekly check scheduled (Mondays 10:00; missed runs happen at next wake), running from $clone. Reports: $LOGDIR"
      ;;
    remove)
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      rm -f "$PLIST" && ok "Weekly check removed."
      ;;
    status)
      if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then ok "Weekly check is scheduled ($PLIST)"; else say "Weekly check is not scheduled. Enable: scripts/deps.sh schedule install"; fi
      local last; last=$(ls -t "$LOGDIR"/deps-check-*.log 2>/dev/null | head -1)
      [ -n "$last" ] && say "Last report: $last"
      ;;
    *) die "usage: scripts/deps.sh schedule install|remove|status";;
  esac
}

case "${1:-status}" in
  status)   cmd_status ;;
  install)  shift; cmd_install "$@" ;;
  update)   shift; cmd_update "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  check)    shift; cmd_check "$@" ;;
  schedule) shift; cmd_schedule "$@" ;;
  -h|--help|help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try: scripts/deps.sh help)" ;;
esac
