#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../batteries"
LOG=../bench/t4_ab_results.txt
: > "$LOG"
run_block () {
  for i in 1 2 3 4 5; do
    rm -rf .lake/build
    s=$(date +%s.%N)
    lake build Batteries > /tmp/t4_build_$1_$i.log 2>&1
    rc=$?
    e=$(date +%s.%N)
    oleans=$(find .lake/build/lib/lean -name '*.olean' | wc -l)
    wall=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.2f", b-a}')
    echo "$1 run$i wall=${wall}s rc=$rc oleans=$oleans" | tee -a "$LOG"
  done
}
git stash push -q -- Batteries/Tactic/Alias.lean   # baseline: pristine Alias.lean
run_block base
git stash pop -q                  # fixed
run_block fixed
echo "--- List.Lemmas module times (run5 each) ---" | tee -a "$LOG"
grep -E "Built Batteries.Data.List.Lemmas |Built Batteries.Tactic.Alias " /tmp/t4_build_base_5.log | tee -a "$LOG"
grep -E "Built Batteries.Data.List.Lemmas |Built Batteries.Tactic.Alias " /tmp/t4_build_fixed_5.log | tee -a "$LOG"
