# T6 upstream package — draft issue/PR for leanprover/lean4

Status: **FILED 2026-07-19** (user-authorized) —
issue: https://github.com/leanprover/lean4/issues/14448
PR: https://github.com/leanprover/lean4/pull/14449
(branch `t6-upstream` on grandchildrice/lean4, rebased onto master 25ba8c3d;
clean cherry-pick, squashed). Master repro re-measured before filing:
1.64/3.22/8.43/27.6/101.4 ms per command for k=1/2/4/8/16 on stock
nightly-2026-07-19; fix on the rebased build: k=16 100.8→21.4 ms, oleans
byte-identical, deterministic, mutation gate green. Patch also kept
locally as `patches/0023-t6-tcSkipUnchanged.patch` (4f53dd7 base).

## Draft title

`perf: synthetic-mvar resumption loop is quadratic in chained pending
TC instances; skip re-attempts with unchanged instantiated goals`

## Draft body

**Problem.** `Elab.synthesizeSyntheticMVars` re-attempts every pending
`.typeClass` metavariable whenever any single one makes progress. In
statements whose literals/operators produce a chain of interdependent
default-instance mvars (each assignment unlocks the next), k pending
instances cost k+(k−1)+… = O(k²) `synthInstance` attempts, each attempt an
expensive underdetermined (mvar-headed) search.

**Microbench.** 200 theorems `7 + … + 7 = 7 + … + 7` (k sevens/side),
term-mode `rfl`. Per-command main-thread cost: 0.57 / 2.09 / 7.17 / 26.4 /
99.6 ms for k = 1/2/4/8/16 (×3.4–3.8 per doubling ⇒ quadratic). Controls:
same expressions in `def`s (expected type known) and theorems over
variables are both linear — the quadratic needs the
postpone-until-defaulting path.

**Fix.** Memoize per pending `.tc` mvar the instantiated goal type at its
last failed attempt (one `MVarIdMap Expr` in `Term.State`); skip the
re-attempt when the instantiated goal is unchanged. `synthInstance` is
deterministic in the instantiated goal for a fixed env/local-instance
context, so the skip elides only attempts whose outcome is already known.
Gated behind `Elab.tcSkipUnchanged` (default off) for evaluation; the
intent would be default-on if accepted.

**Evidence.**
- Microbench: k=16 per-command 99.2 → 21.2 ms (4.7×); quadratic term gone.
- Real module, numeral-dense regime:
  `Mathlib.NumberTheory.PythagoreanTriples` wall 2.40 → 2.22 s (−7.4 %),
  interleaved runs.
- Honest scoping: modules whose numerals are isolated literals
  (`Mathlib.Data.Nat.Log`, `Mathlib.Data.Nat.Choose.Sum`) are neutral —
  the win is specific to the chained-literal (quadratic) regime.
- Soundness: Batteries corpus builds clean with the option on; broken
  proofs error identically; **oleans are byte-identical ON vs OFF** on
  `Batteries.Data.List.Lemmas` and `PythagoreanTriples`; ON-vs-ON
  deterministic.

**Known residual.** With the skip on, the remaining superlinearity in the
microbench is `binop%` re-elaborating its full tree on each resume
(`.postponed`, not `.tc`). The same memo is *unsound* there
(`resumeElabTerm` depends on the whole mctx); the principled fix is
dependency-precise wakeup (postponed elaborators register blocked-on
mvars). Separate issue material.

## Filing checklist (when authorized)

- [ ] rebase the two commits onto current master; squash the accessor fixup
- [ ] re-run the microbench + gates on the rebased build
- [ ] `Std.TreeMap` → check master's preferred map for `Term.State`
- [ ] CLA/house style pass; drop the option or keep per maintainer guidance
