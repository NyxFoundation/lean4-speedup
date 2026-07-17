# T2c design: asynchronous kernel checking for inductives/structures

Status: design (2026-07-17, iter 10). Prototype planned behind
`Elab.asyncInductive` (default false).

## Motivation (measured)

The main thread is the critical path (80 % occupied on hot modules), and
synchronous kernel checking of `inductive`/`structure` declarations sits
directly on it:

- `BinomialHeap/Basic`: **1.31 s of the 1.33 s** structure-command time is
  `Kernel` — 60 % of the module's critical path. Cause: `FindMin.WF` field
  types force kernel unfolding of `WellFounded.fix` chains (the file defines
  `merge` etc. by `termination_by`).
- `String/Lemmas`: inductive-command time is 0.77 s Kernel out of 0.78 s.
- Other modules (UnionFind, GeneralizeProofs): near-zero kernel share — the
  win is **spiky, concentrated in WF-heavy modules**, which are exactly the
  build-tail modules that gate parallel `lake build` wall-clock.

## Root cause

`AddDecl.lean` (`addDeclCore`) has async kernel-checking rules only for
`thmDecl | defnDecl [single] | opaqueDecl | axiomDecl`. Everything else —
`inductDecl`, mutual `defnDecl` — falls through to a synchronous `doAdd`
(kernel typecheck on the main thread).

## Design

Reuse the async-theorem trust model: commit elaborator-known info to the
environment immediately, let the kernel confirm in a background task, and
surface kernel errors at the end of the module snapshot.

1. **Eager commits** for `Declaration.inductDecl`:
   - `InductiveVal` + `ConstructorVal`s: fully known to the elaborator
     (they are literally the declaration payload) → `commitConst` eagerly.
   - `rec` (and `casesOn`-feeding aux recursors for mutual/nested):
     construct the **recursor signature Lean-side** (motives + minor
     premises + majors telescope — mechanical from the inductive spec,
     ~150 lines mirroring the kernel's `mk_rec_decl`) → `commitSignature`
     eagerly; `commitConst` (with `RecursorVal.rules`) when the kernel task
     completes.
2. **Kernel ordering is already correct**: async check tasks chain on
   `env.checked` (`BaseIO.mapTask checkAct env.checked`), so the kernel
   still processes the inductive before any later declaration that
   mentions it.
3. **Demand-join semantics**: the elaborator's aux constructions
   (`casesOn`, `recOn`, `noConfusion`, …) only need the rec *signature* to
   build their terms — they proceed immediately. A later elaboration step
   that needs rec **rules** (iota reduction in `whnf`) resolves the async
   constant's full info and blocks on the kernel task — the uncommon case
   pays, the common case flows.

## Prototype scope cuts (v0)

- Single non-mutual, non-nested inductives/structures only; anything else
  falls back to the sync path.
- Skip under the module system's export rewriting (`isModule` envs use the
  existing path) until semantics are clear.
- Option-gated: `Elab.asyncInductive`, default false; benchmarked
  explicitly.

## Validation plan (same discipline as T1)

1. **Blocking probe**: a file that defines `inductive T` then immediately
   proves `T.rec`-reducing facts (`example : T.rec ... (T.mk ...) = ...`)
   must behave identically (blocks on the kernel task, same errors).
2. **Error-surfacing probe**: an inductive the kernel rejects (e.g.
   universe error injected via `unsafe`-free trick) must still fail the
   module, async or not.
3. Determinism + olean byte-comparison vs sync path on Batteries.
4. A/B wall-clock on BinomialHeap/Basic and String/Lemmas (expected: −40 %
  /−60 % main-thread on those modules), plus full-Batteries wall.

## Alternative/complementary attacks on the same 1.31 s

- Kernel-side: cache/short-circuit `WellFounded.fix` unfolding (C++,
  deeper risk); or core moving WF bodies behind `irreducible` markers the
  kernel respects (`Nat.rec`-style structural wrappers).
- Library-side: Batteries could `irreducible_def` the WF functions before
  the structure — but that treats one file, not the disease.
