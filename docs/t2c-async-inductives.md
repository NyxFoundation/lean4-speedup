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

## Implementation notes (iter 11 — prototype deferred)

Two hard facts discovered attempting the v0 prototype:

1. **Multi-constant async commit is unbuilt territory.** `addConstAsync` is
   per-constant and `enterAsync` scopes one prefix; `addDeclCore` itself says
   "not all cases are supported yet". An inductive needs T / T.mk / T.rec
   committed coherently — orchestrating three handles + one kernel task is
   the real work, and each debug cycle costs a 20–40 min stage1 rebuild.
   Deferred to a dedicated time box.
2. **`debug.skipKernelTC` ceiling probe**: BinomialHeap wall is *unchanged*
   (1.94 s vs 1.94 s) with kernel checking skipped — the 1.31 s attributed
   to `Kernel` under the structure command survives, i.e. it is the
   kernel's *inductive compiler construction* path (recursor building),
   not the checking pass (or the skip flag is not honored for
   `inductDecl`). T2c still lifts it (the whole `addDecl` moves to the
   background task), but the "async checking" framing was imprecise.
   Also: List.Lemmas shows −1.1 s user but only −0.2 s wall with all
   kernel checking skipped — theorem-proof checks are already well hidden
   by the async pipeline. Tempering data for kernel-side tracks.

Soundness note recorded for the eventual prototype: `commitConst` verifies
only the signature — an eagerly-committed `RecursorVal` (rules, k) becomes
olean truth unverified. The prototype must compare the kernel-produced
RecursorVal against the eager one after the task completes and hard-error on
drift.
