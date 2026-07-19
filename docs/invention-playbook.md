# Invention playbook — analogy retrospectives and the evolving method

> **2026-07-19 update**: this playbook turned out to be the *selection*
> half of the method only. Why iterations 50–73 produced diagnostics and
> bug fixes but no invention — and the generation-side protocol v2 (five
> delta operators, budgeted blind variance, C-expansion) — is in
> [invention-theory.md](invention-theory.md).

Self-improvement log for the ideation method itself (directive 2026-07-19:
rotate lateral-thinking sources *and* improve how they're chosen). Updated
each time a track closes.

## Scoreboard: which analogies earned their keep

| Analogy | Track | What it produced | Grade |
|---|---|---|---|
| Strength reduction (K-RED) | T1 | real CPU savings, wall-neutral | B — mechanism found, wrong layer |
| Pipelining (hardware) | T2a/T2c | precise map of Lean's async boundary; perf-null | B |
| Nuclear fission (binding energy) | T3 | time-fissility datum; fission criterion ("fissility parameter") transferred cleanly | B+ |
| CPU RAW hazard / pipeline stall | T4 | **discovery + fix**: the alias cone-drain barrier; gdb methodology | A |
| Barrier *class* generalization (from one hazard to the family) | T5 | dominant-blocking census; sound core patch; perf-null but killed a false hypothesis | B+ |
| Muda → queueing (floor decomposition → scaling law) | T6 | **O(k²) defaulting loop found + asymptotic fix** (4.7× at k=16, byte-identical output) — first upstreamable perf patch | A |

## Meta-lessons (what actually generates value)

1. **Analogy as explanation compressor, not idea generator.** Every A/B+
   above started from a *measured anomaly* (394 ms command, 49-hit census,
   86 %-time component) and used the analogy to *explain and name* it —
   which then dictated the fix shape. Analogies applied to unmeasured hopes
   (the folding/dedup and speculation candidates from the original list)
   never produced anything. Rule: **measure first, then shop for the
   analogy that explains the anomaly.**
2. **The census must be weighted by time-on-critical-path, not hit count**
   (T5's lesson). A blocked thread off the critical path is free.
3. **Never timestamp-bisect a suspected lazy force; sample stacks** (T4's
   lesson — pure calls float across timing binds).
4. **Always strict same-binary baselines** (T5 caught a 40 % toolchain
   drift that would have been claimed as a win).
5. **Outliers are not the mass.** T4's 394 ms alias was real but an
   outlier; the Mathlib foundation slice shows ≤30 ms stalls. Before
   scaling a fix's value, measure the *distribution*, not the max.

## Mathlib-scale alias verdict (iter 55)

Built-deps alias-dense modules measured (`Order/BooleanAlgebra/Set` 82
aliases, `Data/Set/Basic` 28, `Logic/Basic` 28, `Order/Basic` 26,
`Order/RelClasses` 44, `Logic/Relation` 31): alias command stalls ≥20 ms —
**two**, both ≤28 ms. Foundation-module proof cones drain before the alias
arrives; the Batteries hot case (grind cluster directly above the alias) is
the outlier shape. Upstream case: the fix stays principled and harmless,
but no wall claim at Mathlib scale without measuring proof-heavy
Analysis/Topology modules (deps unbuilt — hours; deferred).

## Next-rotation queue (each with its falsifiable prediction)

- **Lean manufacturing / muda (non-value-added step elimination)**: what is
  the per-command *floor*? A trivial `theorem t : 1+0=1 := rfl` costs
  ~5–8 ms of main thread. Composition unknown: parse / snapshot machinery /
  info-tree construction / .ilean bookkeeping. Prediction: if info-tree +
  snapshot overhead ≥ half the floor, a batch-mode fast path (no editor
  artifacts) cuts corpus main-thread time by a measurable fraction.
  Measure with a 1000-trivial-theorem file + stack sampling.
- **Queueing theory (Little's law)**: model the main thread as the single
  server; the arrival process is the parser. Where is the utilization lost —
  service time or queue discipline?
- **Ecology (r/K selection)**: modules as organisms — many cheap commands
  vs few expensive ones; does Lean's scheduling favor the wrong strategy on
  the critical path?

## Iter 56 retrospective (muda / per-command floor)

Floor measured (1000-command files, startup-subtracted, per command):
`def` 0.30 ms · `theorem` 1.40 ms · `example` 1.51 ms (examples stay on
main — matches the async gate). Predictions tested:

- "async bookkeeping is the tax" — **falsified**: `Elab.async=false` makes
  both theorems (+13 %) and defs (+47 %) *slower*; async is net-positive
  even at the floor.
- "TC re-derivation is the tax" — **falsified**: T1 v1 shape cache is a
  no-op on the floor (1.594 vs 1.578 s).
- Stack samples: all elaboration-thread hits in
  `synthesizePendingInstMVar`/`synthesizeInstMVarCore`/`resumePostponed` —
  the **synthetic-instance-mvar orchestration** (postpone → mvar-context
  switch → resume → instantiate), ~0.3 ms per pending instance mvar
  (theorem ≈ 4–5 of them, def ≈ 1 — the ratio explains the premium).
  The muda is the orchestration *around* synthesis, invisible to any
  synthesis-result cache.

New meta-rules (both bought with today's mistakes):

6. **Verify rc *inside* the measurement loop.** A "27× speedup" was a
   zsh word-splitting bug making `lean` fail instantly (rc=1 swallowed by
   `>/dev/null`); a mutation probe's rc was `head`'s, not `lean`'s.
   Any speedup that beats the empty-file baseline is a broken harness.
7. **A cost invisible to a cache is orchestration, not computation.**
   When a result-cache no-ops on a repetitive workload, stop optimizing
   the computation and profile the machinery that schedules it.

## Iter 65-67 retrospective (T7: the flood that wasn't the wall)

The TLB/ASID transfer (prefix-reuse of direct local-instance hits) was
implemented, fired (2.5k hits/module) — and was **unsound** (fvar reuse
across metavar-context boundaries; caught by the olean gate + a real
elaboration error) and **null** (wall unchanged: the avoided searches were
the cheap ones). Two self-inflicted lessons, both already in the rules:

- **Rule 2 violated by its own author**: the iter-64 "60 % of queries"
  census weighted by *count*; the 2.14 s of TC time lives in mvar-laden
  deep-hierarchy queries, not in the trivial local-hit flood. Time-weight
  first, always.
- **New rule 8 — ABI: rebuilding corpora is part of the patch.** Changing a
  core data structure (`Meta.Cache` field) invalidates downstream oleans;
  the resulting segfault in A/B looks like a logic bug but is an ABI smell.
  Rebuild every corpus after every core-struct change, before measuring.

Rotation queue update: next = **literal fast-path** (strength-reduction
analogy re-aimed at the elaborator): `OfNat Nat` / `HAdd Nat` literal
instances could short-circuit the postpone/resume dance for the
overwhelmingly common cases. Falsifiable: floor theorem cost should
approach `def`-level (~0.5 ms) if 3-4 of the 4-5 cycles are elided.

## Retrospective 5 (iters 74–89): protocol v2's first full cycle

Protocol v2 (invention-theory.md) was written at iter 74 because 24
iterations of measurement-first discipline had produced world-class
diagnostics and one bug fix, but no invention. The next 15 iterations
ran the new protocol end-to-end. What it delivered:

- **Phenomenon inventory (step 2) worked immediately**: the T9 census
  found textual command order is a ~99 %-empty over-serialization of a
  depth-3 partial order — measured, not assumed.
- **The perceptual channel (step 7) paid twice**: the arc render made
  the hub-and-spoke structure obvious, and *looking at* the wavefront
  simulator's critical chain exposed T10 (the variable-telescope
  quadratic, −12.2 % shipped) — an accidental discovery no targeted
  query would have made. psi-fold's lesson replicated.
- **C-expansion + status-change (steps 3/1) produced the invention
  frame**: "textual order is advisory for statements, with repair" —
  then five escalating zero-rebuild instruments (census → oracle →
  ceiling replay → live speculation → result equivalence) carried it
  from concept to 79–94 % valid speculation hiding 58 % of main-thread
  time with 100 % semantic adoption soundness, before any compiler
  surgery.
- **Selection stayed brutal (step 6)**: three T10 soundness hazards
  found and closed by the gates; the ngen/rollback law generalized.
- **Meta-rule 9 (new)**: verify every programmatic log edit landed
  (grep after write) — six iterations of PLAN log were silently lost
  to stale-needle str.replace no-ops and reconstructed from commits.
- **Meta-rule 10 (new)**: when a driver mysteriously lacks data, check
  its INPUTS are loaded before excavating its plumbing — the oracle's
  "dropped info trees" were three layers of red herring over an empty
  import environment with swallowed error messages.
