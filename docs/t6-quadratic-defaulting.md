# T6 — the quadratic literal-defaulting loop (queueing-theory / muda transfer)

Status: quadratic **measured and located** (iter 57); fix
(`Elab.tcSkipUnchanged`) implemented, stage rebuild + validation pending.
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

## Validation plan (next wake)

1. Gates: full Batteries corpus builds clean ON; ON-vs-ON olean
   determinism; ON-vs-OFF olean equality (elaboration results must be
   byte-identical — the option must only skip *wasted* work).
2. Falsifiable prediction: the k-series flattens toward linear; k=16
   per-command 99.6 ms → ~10 ms if the model is right.
3. Corpus + List.Lemmas wall; then an arithmetic-heavy real module.
