# T6 — the quadratic literal-defaulting loop (queueing-theory / muda transfer)

Status: **VALIDATED** (iter 58) — fix eliminates the quadratic (4.7× at
k=16 on the probe), all soundness gates green including ON-vs-OFF
byte-identical oleans on a real module; corpus wall neutral on Batteries
(its statements aren't numeral chains). Upstream-quality candidate.
Found by following the iter-56 floor decomposition (0.3 ms per
pending-instance-mvar cycle) to its scaling limit.

## The measurement (bench/M_scale_*.lean)

200 theorems per file, statement `7 + 7 + … = 7 + 7 + …` with k sevens per
side, term-mode `rfl`. Per-command main-thread cost:

| k | per-command |
|---|---|
| 1 | 0.57 ms |
| 2 | 2.09 ms |
| 4 | 7.17 ms |
| 8 | 26.4 ms |
| 16 | **99.6 ms** |

×3.4–3.8 per doubling ⇒ **O(k²)**. Controls that pin it:

- same expressions in `def`s (expected type known, no postponement):
  0.95 → 2.83 ms for k=4→16 — **linear**;
- theorems over *variables* (`n + n + …`, no literals): 0.83 → 3.00 ms —
  **linear**.

Quadratic requires literals (pending `OfNat`/`HAdd` default-instance
mvars) *and* an unknown expected type (theorem equality) — i.e. the
postpone-until-defaulting path.

## The mechanism (Lean/Elab/SyntheticMVars.lean)

`synthesizeSyntheticMVars.loop` / `synthesizeUsingInstances`: whenever any
single pending mvar makes progress, the loop **re-attempts every remaining
pending mvar**. Chained literal statements resolve one mvar per pass
(each assignment unlocks the next), so k pending instances cost
k + (k−1) + … = O(k²) `synthInstance` attempts — and each failed attempt
on an underdetermined goal is expensive (mvar-headed discrimination-tree
search). The defaulting outer loop (`synthesizeUsingDefaultLoop`)
multiplies the same shape.

This is a *per-command main-thread* cost — exactly the sequential
feed-rate wall the synthesis identified. Arithmetic-heavy statements
(numerals, `BitVec`/`Fin` literals, polynomial coefficients, matrix
entries — Mathlib is full of them) pay it on every command.

## The fix (lean4 branch: `Elab.tcSkipUnchanged`, default off)

Memoize, per pending `.typeClass` mvar, the instantiated goal type at its
last failed attempt (`Term.State.tcSynthAttempt`); skip the re-attempt when
the instantiated goal is unchanged. `synthInstance` is deterministic in
the (instantiated) goal within a fixed env/local-instance context, so a
skipped attempt has the same outcome as the attempt it elides — pendings
stay pending, resolutions happen exactly when the goal actually changes.
O(k²) cheap instantiate-and-compare checks remain; O(k) expensive synth
calls replace the former O(k²).

## Validation (iter 58)

k-series per-command, option OFF → ON:

| k | OFF | ON | speedup |
|---|---|---|---|
| 1 | 0.59 ms | 0.42 ms | 1.4× |
| 4 | 7.21 ms | 3.19 ms | 2.3× |
| 8 | 26.3 ms | 7.85 ms | 3.4× |
| 16 | 99.2 ms | **21.2 ms** | **4.7×** |

(The prediction said ~10 ms at k=16; 21 ms observed — the remaining
superlinear residue is the defaulting outer loop, which still applies one
default per full pass. A batch-defaulting follow-up could take it further.)

Gates, all green:
- mutation probe: the broken theorem errors identically ON;
- full Batteries corpus ON: rc=0, 188 oleans, zero errors
  (lakefile `leanOptions`);
- **`List.Lemmas` olean ON vs OFF: byte-identical**, ON-vs-ON
  deterministic — the option provably elides only wasted work on real code;
- corpus wall: ON 13.39–13.49 s vs OFF 13.49–13.60 s — neutral on
  Batteries, as expected (few numeral chains).

## Where the win should land

Numeral-dense corpora: `norm_num`/`decide`-heavy files, `BitVec`/`Fin`
literal lemmas, polynomial/matrix coefficients — Mathlib territory. The
built Mathlib slice here is foundation-only, so real-world magnitude is
unmeasured; that plus a batch-defaulting variant are the follow-ups. As an
asymptotic fix with a crisp microbench and byte-identical-output proof,
this is the repo's first genuinely upstreamable *performance* patch
(lean4 branch commit `T6: Elab.tcSkipUnchanged`).
