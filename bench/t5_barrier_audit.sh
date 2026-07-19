#!/usr/bin/env bash
# T5 barrier-class audit: sample the command thread of a hot-module compile
# at random offsets, dump all stacks, aggregate lean_task_get callers.
# Usage: t5_barrier_audit.sh <n-samples> <lean-file>
set -u
N=${1:-15}
FILE=${2:-Batteries/Data/List/Lemmas.lean}
cd "$(dirname "$0")/../batteries"
OUT=../bench/t5_samples
mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
  # random interrupt offset in [0.3, 2.3)s — inside elaboration, past header
  off=$(awk -v i="$i" -v n="$N" 'BEGIN{printf "%.2f", 0.3 + 2.0*(i-1)/n}')
  (timeout 120 lake env sh -c \
    "gdb -batch -ex 'set pagination off' -ex run -ex 'thread apply all bt 25' --args \"\$(which lean)\" $FILE" \
    > "$OUT/sample_$i.txt" 2>&1 &)
  # wait for the inferior to actually start (gdb symbol load takes ~1s)
  pid=""
  for _ in $(seq 1 100); do
    pid=$(pgrep -n -x lean || true)
    [ -n "$pid" ] && break
    sleep 0.1
  done
  sleep "$off"
  [ -n "$pid" ] && kill -INT "$pid" 2>/dev/null
  wait
  echo "sample $i @ ${off}s: $(grep -c '^Thread' "$OUT/sample_$i.txt" 2>/dev/null || echo 0) threads"
done
