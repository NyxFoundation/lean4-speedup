# T4 — the `alias` pipeline barrier (RAW-hazard transfer)

Status: **RESOLVED** (iter 52) — both forcing sites named via gdb stack
sampling, fix implemented and validated at probe level
(`patches/batteries-0001-alias-async-stall-fix.patch`); corpus wall-neutral
on Batteries (slack absorbs it), upstream-relevant at Mathlib scale.
Discovered (iter 51) by micro-attributing main-thread time
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

## Resolution (iter 52): gdb names both forcing sites

ptrace_scope=1 blocks attach, so: run `lean` as a gdb child
(`gdb -batch -ex run -ex "thread apply all bt" --args lean …`), send the
inferior SIGINT from outside mid-stall — gdb stops and dumps all threads
(`bench/t4_gdb_stacks.txt`, `bench/t4_gdb_v0.txt`). The command-elaboration
thread was blocked in:

1. **`Environment.find?` → `AsyncConstantInfo.toConstantInfo` →
   `lean_task_get`** — the alias's `getConstInfo target` materializes the
   full `ConstantInfo`, forcing the target's pending cone. Fixed by the
   signature-only view (`findAsync?` + `toConstantVal`/`.isUnsafe`).
2. **`Lean.isNoncomputable` → `TagDeclarationExtension.isTagged` →
   `EnvExtension.getStateUnsafe` → `lean_task_get`** — reading a tag
   env-extension's state blocks on pending async branch merges. For
   *theorem* aliases `computeKind` is irrelevant (never compiled), so the
   fix skips `isNoncomputable`/`isMarkedMeta` entirely in that case.

Why timestamp bisection kept lying: these are *pure* calls, so the compiler
legally floats them across `IO.monoMsNow` binds to their first use — the
wait surfaces at whatever pure expression the IR evaluator touches first
(measured: every named call 0 ms, span 107 ms). Lesson recorded: **never
bisect a suspected lazy force with timestamps; sample stacks.**

With both fixes (v0+v1): probe stall **+100 ms → +4 ms ≈ noise** — the
alias now costs what `#check` costs.

## Corpus verdict

5-run cold `lake build Batteries` medians (`bench/t4_ab_results.txt`):
base 13.50 s vs fixed 13.48 s, 188 oleans, rc=0 — **wall-neutral**;
`List.Lemmas` job 3.5 → 3.3 s (single-sample, ≈noise). The drained cone is
work that must finish before module end regardless; Batteries' build slack
absorbs the recovered overlap. Same shape as T1–T3: mechanism real,
corpus wall unmoved.

## Why this still matters

- **General finding**: any metaprogram command that reads env-extension
  state (`getState`-based queries) mid-module is a silent async-pipeline
  barrier. This is a *class* of stalls, alias is just one member — a
  measurable audit target for Lean core (which ext reads block, at which
  asyncMode).
- **Upstream candidate**: Mathlib carries thousands of `deprecated alias`
  commands, typically *immediately after their targets* (worst case, cone
  hottest). The two-line-diff fix
  (`patches/batteries-0001-alias-async-stall-fix.patch`) is upstreamable to
  Batteries as-is — recommend filing after Mathlib-scale measurement.
