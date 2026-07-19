#!/usr/bin/env bash
# T10 validation battery (run after stage1 rebuild). Asserted per playbook:
# exit codes checked, outputs diffed, medians over 5 runs.
set -u
LEAN=lean4/build/release/stage1/bin/lean
cd "$(dirname "$0")/.."
echo "== probes ON vs OFF (must be byte-identical)"
$LEAN -DElab.varTelescopeCache=false bench/M_t10_probes.lean > /tmp/t10_off.txt 2>&1; rcoff=$?
$LEAN -DElab.varTelescopeCache=true  bench/M_t10_probes.lean > /tmp/t10_on.txt  2>&1; rcon=$?
echo "rc off=$rcoff on=$rcon"
if diff -q /tmp/t10_off.txt /tmp/t10_on.txt; then echo "PROBES PASS"; else echo "PROBES FAIL"; diff /tmp/t10_off.txt /tmp/t10_on.txt | head -20; fi
echo "== k-series (median of 5, ms)"
for k in 8 16 32 64 128 256; do
  for opt in false true; do
    ts=""
    for r in 1 2 3 4 5; do
      s=$(date +%s%N)
      $LEAN -DElab.varTelescopeCache=$opt bench/M_t10_scale_$k.lean || { echo "k=$k opt=$opt FAILED"; exit 1; }
      e=$(date +%s%N)
      ts="$ts $(( (e-s)/1000000 ))"
    done
    med=$(echo $ts | tr ' ' '\n' | sort -n | sed -n 3p)
    echo "k=$k cache=$opt median=${med}ms"
  done
done
