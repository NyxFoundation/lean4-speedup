# T4 — the `alias` pipeline barrier (RAW-hazard transfer)

Status: barrier discovered and rigorously characterized (iter 51); precise
forcing site + fix still open. Found by micro-attributing main-thread time
per command (the T3 follow-up question: *what does the main thread actually
do?*), analogized from CPU pipeline hazards: a read-after-write dependency
that stalls the pipe until the producer retires.

## The finding

Batteries' `alias new := target` command (`Batteries/Tactic/Alias.lean`)
**stalls the main elaboration thread until `target`'s transitive async
dependency cone — proof elaboration + kernel checking — completes.** In
`Batteries.Data.List.Lemmas`, the single command
`@[deprecated] alias idxOf_eq_idxOf? := idxOf_eq_getD_idxOf?` costs **394 ms
of main-thread time** (the module's biggest single command by far; ~11 % of
the module job) — none of it work, all of it waiting.

The `@[deprecated] alias` idiom places the alias *immediately after its
target* — the worst case, since the target's cone is at its hottest. Batteries
has 44 aliases; Mathlib has thousands.

## Evidence (bench/M_t4_*.lean, bench/t4_*.txt)

Probe: one heavy `by decide` theorem (async worker + async kernel task) + a
100-command cheap tail; the probe command sits between them. 5-run walls:

| variant | median | stall |
|---|---|---|
| no probe command (base) | 0.417 s | — |
| `#check @probeChain` | 0.410 s | none |
| `attribute [simp] probeChain` | 0.412 s | none |
| **`alias probeAlias := probeChain`** | **0.518 s** | **+100 ms** |

Controls that pin the mechanism:

- `-DElab.async=false` → stall vanishes (it is a *wait*, not work).
- alias of an **imported** constant → no stall (only in-flight cones block).
- alias of a *trivially-proved* theorem that merely *references* the heavy
  one → still stalls (**transitive**: the cone, not the target, is joined).
- stall scales with cone weight (53 ms → 117 ms when the heavy proof doubles).
- `#check`/`attribute` touch the same fresh constant's *type* without
  stalling → the barrier is specific to the alias path, not to any use of an
  in-flight constant.

## What we know about the forcing site (and what defeated localization)

- `addDecl` itself is exonerated: the thmDecl takes the async adding rules
  (1 ms, kernel work on a task).
- A signature-only rewrite of the alias elab (`Environment.findAsync?` +
  `AsyncConstantInfo.toConstantVal`/`.isUnsafe`, never materializing the full
  `ConstantInfo`) compiles and is semantically sound — **but does not remove
  the stall**, so the force is not (only) `getConstInfo`'s value thunk.
- Timestamp bisection is systematically defeated: every individual call in
  the stalling span measures 0 ms while the span holds the full wait —
  compiled-code thunk forcing does not respect source order, so the wait
  surfaces at whatever pure expression first touches the blocking closure
  (classic lazy-force attribution failure). trace.profiler cannot help
  either: it samples trace nodes, not blocked threads.
- Reconciliation gap: the `[Elab.command]` alias node reads ~358 ms while
  instrumented spans inside the elab body sum to ~110 ms — a large share of
  the wait lives *outside* the body (command-elab entry/finalization,
  `liftTermElabM` machinery), consistent with the force hiding in a captured
  env/closure rather than a named call.

## Next session

1. OS-level sampling (gdb/eu-stack batch attach to the frontend thread
   during the stall) to name the blocking frame — trace-based tools cannot.
2. Grep the alias-specific machinery (`realizeGlobalConstNoOverloadWithInfo`,
   `addDeclarationRangesFromSyntax`, info-tree finalization, `withExporting`
   env copies) for `Task.get`/`.constInfo.get`/`checked.get` users.
3. Fix shape once named: alias needs only the target's signature; everything
   value-dependent already has an async lane (addDecl's async rules). A
   correct fix should make `alias` cost ~1 ms like `#check`.
4. Upstream relevance: Mathlib-scale `deprecated alias` density makes this a
   candidate real-wall win beyond this repo's corpus — worth an upstream
   issue once the forcing site is named.
