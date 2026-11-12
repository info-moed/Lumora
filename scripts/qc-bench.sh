#!/bin/bash
# Interpolation QC benchmark (ground truth: Big Buck Bunny 60 fps). Headless, nice'd.
#
#   scripts/qc-bench.sh                 # dataset (cached after the first run) + baseline, prints the report
#   scripts/qc-bench.sh dataset         # only build / refresh the dataset
#   scripts/qc-bench.sh baseline        # only the current-checker baseline + oracle
#   scripts/qc-bench.sh score <label>   # score the policy the app code implements now -> qc-results/<label>-<split>.json
#   scripts/qc-bench.sh scan            # scan diagnostics + contact sheets (cut / fade / motion instruments)
#   scripts/qc-bench.sh scorer-data     # artifact scorer training data (qc-scorer/<set>.csv); then
#                                       # python3 scripts/qc_scorer/train.py retrains the scorer
#
# Optional environment (passed to the test host):
#   LUMORA_QC_SPLITS=test,testHDR      splits to run (default: all for dataset/baseline; held-out + cut + fade for score)
#   LUMORA_QC_SENSITIVITY=0,0.5,1      score only: sensitivities to score (default 0.5)
#   LUMORA_QC_REPAIR_MODEL=<id>|none   repair model (default: the app's default)
#   LUMORA_QC_INTELLIGENCE=eachFrame|perScene|exhaustive
#   LUMORA_QC_FLICKER=0                turn the flicker check off
#   LUMORA_QC_LIMIT=<n>                only the first n windows per split (quick runs; not cached)
#   LUMORA_QC_REBUILD=1                rebuild the dataset even if cached
#   LUMORA_QC_RESELECT=1               rescan and resample the windows (rewrites the committed manifest)
#   LUMORA_BENCH_ROOT=<dir>            default ~/Library/Caches/Lumora-Bench (films in <root>/bbb/)
#   QC_BENCH_SKIP_BUILD=1              reuse the last build
#   QC_BENCH_DERIVED=<dir>             derived data folder (default ~/Library/Developer/Xcode/DerivedData/Lumora-qc-bench)
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${QC_BENCH_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/Lumora-qc-bench}"
ROOT="${LUMORA_BENCH_ROOT:-$HOME/Library/Caches/Lumora-Bench}"
LOG_DIR="$ROOT/qc-results/logs"
mkdir -p "$LOG_DIR"

what="${1:-all}"
case "$what" in
  all)      tests=(test1_Dataset test2_Baseline) ;;
  dataset)  tests=(test1_Dataset) ;;
  baseline) tests=(test2_Baseline) ;;
  score|eval) tests=(test3_Evaluate); export TEST_RUNNER_LUMORA_QC_LABEL="${2:?usage: qc-bench.sh score <label>}" ;;
  scan)     tests=(test0_Scan) ;;
  scorer-data) tests=(QCScorerTrainingTests/test4_ScorerDataset) ;;
  *) echo "usage: $0 [all|dataset|baseline|score <label>|scan|scorer-data]" >&2; exit 2 ;;
esac

export TEST_RUNNER_LUMORA_QC_BENCH=1
for v in LUMORA_QC_SCORER_SETS LUMORA_QC_SPLITS LUMORA_QC_SENSITIVITY LUMORA_QC_REPAIR_MODEL LUMORA_QC_INTELLIGENCE LUMORA_QC_FLICKER \
         LUMORA_QC_LIMIT LUMORA_QC_REBUILD LUMORA_QC_RESELECT LUMORA_BENCH_ROOT; do
  if [ -n "${!v:-}" ]; then export "TEST_RUNNER_$v=${!v}"; fi
done

if [ "${QC_BENCH_SKIP_BUILD:-0}" != "1" ]; then
  command -v xcodegen >/dev/null && xcodegen >/dev/null
  nice -n 10 xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- \
    build-for-testing > "$LOG_DIR/build.log" 2>&1 || { tail -40 "$LOG_DIR/build.log"; exit 1; }
fi

only=()
for t in "${tests[@]}"; do
  case "$t" in */*) only+=("-only-testing:LumoraTests/$t") ;; *) only+=("-only-testing:LumoraTests/QCBenchmarkTests/$t") ;; esac
done
log="$LOG_DIR/$what-$(date +%Y%m%d-%H%M%S).log"
set +e
nice -n 10 xcodebuild -project Lumora.xcodeproj -scheme Lumora -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- \
  test-without-building "${only[@]}" > "$log" 2>&1
status=$?
set -e
grep -E "QCBENCH|error:|Test Case .*(passed|failed|skipped)" "$log" || true
echo "log: $log"
case "$what" in
  all|baseline) [ -f "$ROOT/qc-results/baseline.md" ] && cat "$ROOT/qc-results/baseline.md" ;;
  score|eval)   [ -f "$ROOT/qc-results/$2.md" ] && cat "$ROOT/qc-results/$2.md" ;;
esac
exit $status
