#!/usr/bin/env bash
# T5 validation + measurement (run after stage1 rebuild with the .local patch).
# Gates first: corpus builds clean, ON-vs-ON olean determinism.
# Then: --threads sweep on List.Lemmas + 5-run cold corpus wall.
set -u
cd "$(dirname "$0")/../batteries"
LOG=../bench/t5_results.txt
: > "$LOG"
say () { echo "$@" | tee -a "$LOG"; }

# Gate 1: full corpus build
rm -rf .lake/build
s=$(date +%s.%N)
lake build Batteries > /tmp/t5_corpus_1.log 2>&1
rc=$?
e=$(date +%s.%N)
oleans=$(find .lake/build/lib/lean -name '*.olean' | wc -l)
say "gate1 corpus: rc=$rc oleans=$oleans wall=$(awk -v a=$s -v b=$e 'BEGIN{printf "%.2f",b-a}')s"
[ "$rc" -ne 0 ] && { say "GATE1 FAILED"; grep -m5 "error" /tmp/t5_corpus_1.log | tee -a "$LOG"; exit 1; }
find .lake/build/lib/lean -name '*.olean' -exec sha256sum {} \; | sort -k2 > ../bench/t5_oleans_1.txt

# Gate 2: determinism (second cold build, compare olean hashes)
rm -rf .lake/build
lake build Batteries > /tmp/t5_corpus_2.log 2>&1
rc2=$?
find .lake/build/lib/lean -name '*.olean' -exec sha256sum {} \; | sort -k2 > ../bench/t5_oleans_2.txt
if diff -q ../bench/t5_oleans_1.txt ../bench/t5_oleans_2.txt > /dev/null; then
  say "gate2 determinism: IDENTICAL (rc2=$rc2)"
else
  say "gate2 determinism: DIFFER ($(diff ../bench/t5_oleans_1.txt ../bench/t5_oleans_2.txt | wc -l) lines)"
fi

# Threads sweep on the hot module (the plateau prediction)
say "--- threads sweep: lake env lean --threads=N List.Lemmas ---"
for n in 1 2 4 8 16; do
  best=""
  for i in 1 2 3; do
    s=$(date +%s.%N)
    lake env lean --threads=$n Batteries/Data/List/Lemmas.lean >/dev/null 2>&1
    e=$(date +%s.%N)
    w=$(awk -v a=$s -v b=$e 'BEGIN{printf "%.3f",b-a}')
    best=$(awk -v w=$w -v b="${best:-999}" 'BEGIN{print (w<b)?w:b}')
  done
  say "threads=$n best-of-3 wall=${best}s"
done

# Cold corpus wall, 5 runs
say "--- cold corpus wall (5 runs) ---"
for i in 1 2 3 4 5; do
  rm -rf .lake/build
  s=$(date +%s.%N)
  lake build Batteries > /tmp/t5_corpus_w$i.log 2>&1
  rc=$?
  e=$(date +%s.%N)
  say "run$i wall=$(awk -v a=$s -v b=$e 'BEGIN{printf "%.2f",b-a}')s rc=$rc"
done
say "done"
