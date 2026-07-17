# T1 v2 design: two-tier cache validation (hook-free)

Status: fully specified (2026-07-17); implementation queued.

## Problem

v0/v1 stamp cache entries with the *whole* instance-table state object.
In instance-defining modules (Mathlib's algebra bootstrap) nearly every
command grows the table → the pointer changes → the cache never hits
(measured: ~0 effect on `Hom.Defs`, `WithBot`, `InjSurj`).

## Rejected: per-class version counters

Bumping a per-class counter in `addInstance`/`erase` is not sound: scoped
activation (`open`), attribute erasure, and wholesale `modifyState`
restores (Instances.lean:351-353) mutate the table without passing through
any hookable per-class point, and `SimpleScopedEnvExtension.addEntry` is
pure (no IO possible).

## Chosen: record-and-replay candidate lists

A derivation's dependence on the instance table is *exactly* the sequence
of candidate lists it retrieved. So:

**Recording** (in `mkGeneratorNode?` / `getInstances` call path): for each
subgoal query, record `(abstractMVars subgoalType, candidateNames)` where
`candidateNames` is the **global** candidate list after the erased filter,
in priority order (locals excluded — they are already covered by the
cache key / shape telescope). Accumulate per-derivation in `SynthM.State`;
store the array in the cache entry.

**Probe** =
- **Tier 1 (fast path)**: whole-table pointer identity (as v0/v1) → valid.
  Covers proof-heavy lemma files.
- **Tier 2 (slow path, on pointer mismatch)**: for each recorded query,
  re-run the discrTree lookup and BEq-compare candidate names. All equal →
  the table changes were irrelevant to this derivation → valid. Sound
  under ANY mutation path by construction. Cost: ~10-50 µs per recorded
  query, typically 1-5 queries; only paid when tier 1 misses.
- `defaultInstances` / `reducibilityExtra` keep pointer stamps in both
  tiers (rare churn; a tier-2 for them can come later).

## Replay subtleties (worked out, do not rediscover)

1. **Metavariables**: recorded subgoal types come from the derivation's
   mctx; replaying `getUnify` on an expr with dangling mvar ids consults
   the *current* mctx → wrong/unsafe. Store `abstractMVars` of the type;
   on replay, open with **fresh mvars** (cf. `openAbstractMVarsResult`) so
   discrTree sees the same star pattern structure.
2. **Free variables** (shape-cache entries): recorded types mention origin
   fvars; DiscrTree keys embed fvar identity, so replaying with origin
   fvars queries the wrong keys in the target context. Store query types
   **telescope-closed** (lambda over the shape telescope, like results)
   and beta-apply to the *target* fvars before replaying.
3. Compare **names + order** (priority order is part of search semantics).
   Ignore the `us` level instantiation (fresh per call by design).
4. The local-instance portion of `getInstances` must be excluded from the
   recorded list: exact-key entries fix `localInsts` in the key; shape
   entries fix local-instance *positions* in the telescope.

## Expected effect

- Lemma-heavy modules: unchanged (tier 1 hits as today, −34…47 % TC).
- Instance-defining modules: tier 2 rescues entries whose touched classes
  didn't change — e.g. hundreds of `OfNat`/`Decidable` re-derivations in a
  file adding `Monoid` instances.
- Probe overhead guard: tier 2 only runs after a tier-1 pointer miss, so
  the InjSurj-style micro-regression should not grow.

## Validation additions (beyond the standard battery)

- Mutation probe variant: add an instance of class C *between* two
  identical queries of class D — with v2 the second query must be a cache
  hit (tier 2) yet a C-query cached earlier must miss/flip correctly.
- Scoped probe: `open` a namespace with a `scoped instance` between two
  queries of the affected class — the entry must invalidate (candidate
  list changes).
