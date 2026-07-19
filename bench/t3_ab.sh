#!/usr/bin/env bash
# T3 fission A/B: cold `lake build Batteries` wall, 5 runs per variant.
set -u
cd "$(dirname "$0")/../batteries"
LOG=../bench/t3_ab_results.txt
: > "$LOG"

run_block () { # $1 = label
  for i in 1 2 3 4 5; do
    rm -rf .lake/build
    s=$(date +%s.%N)
    lake build Batteries > /tmp/t3_build_$1_$i.log 2>&1
    rc=$?
    e=$(date +%s.%N)
    oleans=$(find .lake/build/lib/lean -name '*.olean' | wc -l)
    wall=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", b-a}')
    echo "$1 run$i wall=${wall}s rc=$rc oleans=$oleans" | tee -a "$LOG"
  done
}

# baseline: pristine Lemmas.lean, no fragments
git checkout -- Batteries/Data/List/Lemmas.lean
rm -f Batteries/Data/List/Lemmas[123].lean
run_block base

# fission
python3 ../bench/fission_split.py 2>> "$LOG"
run_block fission

# per-module times for the Lemmas modules from the last logs
echo "--- module times (last run each) ---" | tee -a "$LOG"
grep -E "Built Batteries.Data.List.(Lemmas|Basic)" /tmp/t3_build_base_5.log | tee -a "$LOG"
grep -E "Built Batteries.Data.List.(Lemmas|Basic)" /tmp/t3_build_fission_5.log | tee -a "$LOG"
