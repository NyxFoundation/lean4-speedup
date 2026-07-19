# lean4-speedup — making Lean4 compilation faster on CPU

Started 2026-07-17. Method: the NTT-FPGA playbook (visioned vibe coding) —
clone the real implementation, profile it, visualize the architecture with
visually-3d, verify claims with the repo's verify backends, and invent
optimizations by transferring ideas from other research fields.

## Goal

Reduce wall-clock time of compiling Lean4 code (elaboration + codegen +
.olean production), CPU-only. Deliverable: at least one *verified* new
optimization method, either as a fork/PR against leanprover/lean4 or a
standalone implementation in this folder.

## Ground truth (evidence)

- `lean4/` — shallow clone of leanprover/lean4 (the compiler itself; mostly
  written in Lean, C++ kernel/runtime under `src/kernel`, `src/runtime`).
- Toolchain installed: Lean 4.32.0 via elan, 16-core linux box, clang+gcc,
  no `perf` yet (NixOS — use `nix shell nixpkgs#linuxPackages_latest.perf`
  or valgrind/callgrind, or Lean's own `--profile` / trace.profiler).
- Comparison compilers to study for idea transfer (clone as needed):
  GHC (interface files, recompilation avoidance), rustc (incremental
  red/green query graph, pipelined rlib metadata), Koka (Perceus — Lean's
  RC model relative), sccache/ccache (content-addressed caching), MLIR
  (pass pipelining), Cranelift (fast-path codegen).

## Where Lean compile time goes (to be confirmed by profiling)

1. **Elaboration** (usually dominant): unification, typeclass resolution
   (instance search), `simp`, metavariable machinery, macro expansion.
2. **Imports**: .olean loading (mmap'd compacted regions) + environment
   construction.
3. **Kernel checking** of produced terms.
4. **Codegen**: LCNF pipeline → C → external cc (or interpreter). `precompileModules` cost.
5. **Serialization**: .olean write (compacted region build).

## Profiling plan

- Micro: `lean --profile` on representative files (core-only, macro-heavy,
  simp-heavy, decide-heavy); `--stats`; `trace.profiler` + Firefox Profiler
  export (`--profiler.out`).
- Macro: `lake build` of a mid-size project (Batteries) with cold/warm
  .olean caches; measure per-module times from lake's parallel schedule.
- CPU-level: callgrind or perf on `lean` binary for the top file.

## Cross-domain invention candidates (to explore, NTT-style)

- **Folding/dedup** (from FoldNTT psi-fold ROM): content-address and fold
  duplicated proof terms / instances across modules; .olean-level sharing.
- **Strength reduction** (from K-RED): replace expensive general unifier
  paths with specialized closed forms for common patterns (e.g. Nat literal
  defeq, instance head-matching discrimination).
- **Pipelining (hardware)**: overlap elaboration of decl N+1 with kernel
  check + codegen of decl N (Lean already has some async; measure real
  utilization on 16 cores).
- **BMC/incremental SMT**: incremental re-elaboration — red/green query
  graph à la rustc instead of module-granularity recompilation.
- **Speculation (branch prediction)**: speculative instance resolution with
  cheap rollback.

## visually-3d integration

- Scene `lean4-compiler`: `visually visualize` gathers evidence (clones the
  repo into ~/.visually-3d/evidence/lean4-compiler/source) and builds a 3D
  model of the compilation pipeline; `verify` writes a z3/sim self-check
  grounded in the real source (python-smt backend for algorithm mode).
- The point of the 3D pass: the psi-fold invention came from *looking at*
  the floorplan render. Look for structural redundancy in the rendered
  pipeline (duplicated stages, oversized ROM-like tables = caches).

## Track portfolio (user directive 2026-07-17: rotate approaches per
## iteration — don't tunnel on one idea)

- **T1 TC dedup cache** (active): v0 exact-key ✓, v1 shape-key building.
- **T2 Critical path / parallelism**: "blocked 6.65-8.3s" per hot module;
  --threads plateaus at 2.4x. Where does the serial 40% live? (header
  elaboration? env mutation serialization? kernel queue?) Transfer:
  instruction-level parallelism / speculation.
  FINDINGS (iter 8, from trace-profiler samples): main thread busy
  2.31s of ~2.9s wall = 80% occupied — the main thread IS the critical
  path; workers only 0.7-1.0s each. Main-thread self time: runFrontend
  0.73s (parsing is only 56ms of it — rest is untraced frontend loop /
  import / snapshots), Batteries `alias` metaprogram 0.50s,
  definition.header 0.34s, grind-on-main 0.27s. ASYNC GATE
  (MutualDef.lean:1236-1243): async elaboration ONLY for single
  non-mutual `theorem`s with mvar-free statements — `def`/`instance`/
  `example` bodies and all metaprogram commands run synchronously on
  main. INVENTION CANDIDATE T2a: demand-driven async def bodies —
  register the body as a task in the env (proofs-as-tasks
  infrastructure half-exists), join only when a later command actually
  unfolds it; most defs are never unfolded within their own module.
  T2b (smaller): async `example`, async mvar-free `instance` (value
  irrelevant when class is a Prop?).
- 2026-07-17 (iter 8, part 2): V1 VALIDATED. Micro (200 isomorphic
  under-binder queries): TC 169ms→9.7ms (17x), 199/200 shape hits; v0
  alone provably useless there (169≈160 baseline). Both mutation
  probes PASS incl. new under-binder failure-flip probe
  (M_shape_mutation.lean). Hot module: fresh derivations
  13,018→4,695 (v0+v1), TC 842→447ms (−47%). Corpus (Batteries cold):
  124.3 vs 125.6s user ≈ −1% — TC is a small share of Batteries CPU;
  the TC-heavy corpus where T1 should pay is Mathlib. v1 ON-vs-ON
  deterministic. Remaining fresh derivations: mvar goals (excluded by
  design), grind-internal contexts, universe-name mismatches.
  T1 NEXT (later): Mathlib-subset benchmark; olean renormalization for
  upstreamability; universe-level canonicalization.
  ITER 9 PLAN (rotation): T2a prototype — demand-driven async def
  bodies (or first: quantify T2a ceiling by counting sync-elaborated
  def/instance/example bodies & their time share across Batteries).
- 2026-07-17 (iter 9): T2a/T2c ceilings quantified over the 5 slowest
  modules (main-thread total 8.54s, by top-level command):
  theorem 21.3% | runFrontend-self 21.1% | definition 17.9% |
  structure 17.8% | inductive 9.9% | metaprograms (alias+elab) 10.6% |
  instance 0.3%. DRILL-DOWN: BinomialHeap's structure time is
  **Kernel 1.31s of 1.33s** — synchronous kernel checking of
  structures ON MAIN (FindMin.WF fields force kernel unfolding of
  WellFounded.fix terms — WF-recursion pathology); = 60% of that
  module's critical path. ROOT CAUSE (AddDecl.lean:112-131): async
  addDecl rules exist ONLY for thm/single-defn/opaque/axiom;
  inductDecl and mutual defns fall through to synchronous doAdd.
  T2c INVENTION: extend async addDecl to inductDecl — requires
  Lean-side construction of preliminary ConstantInfos (type, ctors,
  and notably the RECURSOR type, mechanically derivable from the
  inductive spec) so aux constructions (casesOn etc.) can proceed
  while the kernel checks in background (same trust model as async
  theorem proofs). T2c-lite (smaller first step): async mutual defns —
  all infos already available, needs multi-const addConstAsync commit.
  CAVEAT resolved (iter 10): Kernel share verified per-module —
  String.Lemmas inductive 0.77s Kernel; UnionFind/GeneralizeProofs
  near-zero → T2c win is SPIKY, concentrated in WF-heavy modules,
  which are the build-tail modules that gate parallel wall-clock.
- 2026-07-17 (iter 10): T2c FEASIBILITY CONFIRMED, design written
  (docs/t2c-async-inductives.md): addConstAsync already two-phase
  (commitSignature/commitConst); kernel tasks auto-serialize on
  env.checked; aux constructions need only the rec SIGNATURE (eager,
  Lean-side ~150-line builder) — rules demand-join on the kernel task.
  v0 scope: single non-mutual inductives, option Elab.asyncInductive,
  fallback to sync elsewhere. Chart main-thread-by-command.svg added
  to docs. NEXT (iter 11): implement the recursor-signature builder +
  the inductDecl async branch in AddDecl.lean.
- **T3 Kernel checking (1.1-1.5s/module)**: dedup shared proof subterms?
  batch checking? Transfer: content-addressed verification (Nix/git).
- **T4 grind+simp (~2.8s/module)**: simp-set discrimination tree reuse
  across commands (same pointer-stamp trick applies to simp exts!);
  grind's own re-initialization per goal.
- **T5 import/startup (100-200ms/module × 217)**: olean mmap already;
  but 5.7GB env re-materialized per process — persistent elaborator
  daemon? Transfer: compile servers (sccache/zapcc).
- **T6 LCNF/codegen (~60ms small files)**: lower priority.
- Rotation rule: while a track's build/benchmark runs detached, the
  iteration's foreground work opens a DIFFERENT track.

## Log

- 2026-07-17: workspace created; lean4 cloned (767M, HEAD 4f53dd7).
  Baseline `lean --profile` on bench/B1_core.lean (Lean 4.32.0): import
  102ms, typeclass inference 104ms, elaboration 78ms, LCNF codegen ~58ms,
  blocked (unaccounted) 46.5ms — small files are startup/import-dominated.
  Batteries cold `lake build` benchmark started in background
  (bench/batteries_cold_build.log).
- 2026-07-17 (iter 2): Batteries HEAD needs v4.33.0-rc1; pinned tag
  v4.32.0. Clean cold build baseline: **15.1s wall / 148s user CPU
  (1146% of 16 cores)**, 217 jobs, slowest module 4.8s → ~28% core
  idle = critical-path headroom; per-module cost is elaboration-heavy.
  Source map: Meta 4.9M (unifier/TC), Elab 3.9M, Compiler/LCNF ~1.3M,
  C++ kernel 420K + runtime 828K. `visually visualize` launched for
  scene "Lean4 compiler pipeline" (bench/visualize_lean4.log).
- 2026-07-17 (iter 3): scene lean4-compiler-pipeline-...-lcnf-code-g
  built: 49 parts, 89/100, grounded in thesis Fig 3.1 (incl. bootstrap
  loop, LCNF erasure chain). `visually verify` running. Deep profile of
  slowest module (Batteries.Data.List.Lemmas, 4.8s in build):
  cumulative = blocked 6.65s (!) > grind 2.8s > kernel type checking
  1.51s > TC inference 1.3s > simp 0.72s > tactic exec 0.57s.
  `lean --threads` sweep: 1t=7.16s, 2t=4.21s, 4t=3.03s, 8t=2.96s wall →
  intra-module parallelism plateaus at ~2.4x/4 threads; Amdahl serial
  fraction ~40% = decl dependency chain. (LEAN_NUM_THREADS is a no-op;
  the knob is -j/--threads.) TWO ATTACK AXES: (A) cut raw per-decl CPU
  (grind/simp/TC/kernel recheck) via cross-module memo/folding;
  (B) break the decl-chain serial fraction (speculative elaboration
  against predicted signatures — branch-prediction transfer).
  NEXT: read src/Lean/Meta/SynthInstance.lean cache scope + kernel
  check caching; check verify result.
- 2026-07-17 (iter 4): verify ✓ (architecture mode → sim backend; checks
  the 3D model faithfully encodes thesis Fig 3.1 zoning/order/loops —
  NOT perf; perf claims need own benchmarks). CACHE LIFETIME CONFIRMED:
  Meta caches (synthInstance/whnf/inferType/defEq) are per-command and
  `modifyEnv` wipes them entirely (Elab/Command.lean:894-898) — every
  addDecl clears. Synthetic experiment (bench/T_tc_*.lean): 200
  identical `DecidableEq (List (Option (Nat×String×Int)))` queries =
  206ms TC vs 1.26ms for one → zero cross-command reuse, ~1ms re-derive
  each. INVENTION CANDIDATE #1: class-versioned persistent synthInstance
  cache — env is monotone, so a cached derivation is invalidated only if
  the instance table of a class TOUCHED during that derivation grew;
  stamp per-class table versions, record touched-class set per entry
  (rustc red/green transfer); persistable into .olean with class-table
  fingerprints for cross-module reuse. From-source lean4 release build
  detached (pid 2582498, bench/lean4_build.log, ~1h) to enable patching.
  TODO next: prior-art check (Lean zulip/PRs on synthInstance cache
  invalidation); read SynthInstance.lean cache key; design experiment
  to count duplicate queries in Batteries List.Lemmas.
- 2026-07-17 (iter 5): stage1 build OK (4.34.0-pre). Prior art: none —
  core has only full reset (resetSynthInstanceCache); 4.30 Lake cache
  overhaul is artifact-level. Duplicate measurement on List.Lemmas via
  trace.Meta.synthInstance.cache: 13,018 real derivations ("new:"),
  only 1,179 unique → **91% duplicate derivations**; per-command cache
  absorbs just 30% of calls (5,707 "cached:"). Top: OfNat Int 1 ×774,
  Grind.CommSemiring Nat ×663, OfNat Int 0 ×658. IMPLEMENTED v0 on
  branch speedup/global-synth-cache (lean4 fork): process-global
  IO.Ref cache keyed by upstream SynthInstanceCacheKey; entries
  stamped with POINTER IDENTITY of instanceExtension /
  defaultInstanceExtension / reducibilityExtraExt states (unrelated
  decls preserve pointers → sound O(1) validity; any table change →
  new object → miss). Kill-switch option synthInstance.globalCache
  for A/B. Known v0 gaps (documented in code): unification hints not
  stamped (import cycle); localInsts fvarids differ across commands so
  under-binder goals never cross-hit (future v1: context-independence
  analysis). Incremental stage1 rebuild detached
  (bench/lean4_rebuild_patched.log). VALIDATION PLAN: (1) patched
  stage1 must produce byte-identical Batteries .oleans vs
  -DsynthInstance.globalCache=false; (2) A/B timing List.Lemmas + full
  Batteries; (3) mutation probe: file adding instance/reducibility
  mid-module must behave identically patched vs not.
- 2026-07-17 (iter 6): v0 VALIDATED mechanically, win too narrow.
  Results: (a) micro 200-dup benchmark TC 166ms→7ms (24x), 199/200
  global hits; (b) mutation probe PASSES (cached failure correctly
  invalidated on instance add); (c) Batteries main builds fine under
  patched 4.34-pre (toolchain linked as `speedup-stage1`; runLinter
  exe cc-link fails outside nix develop — unrelated); (d) OFF-vs-OFF
  deterministic, ON-vs-ON deterministic, but ON differs from OFF in
  ~30 metaprogramming-heavy oleans → cache reuse changes universe-
  param/mvar numbering = stable ALTERNATE normal form (would need
  renormalization for upstreaming); (e) hot-module derivations
  13,018→5,725 (−56%) yet corpus timing FLAT (126.8s user both) —
  eliminated queries were cheap closed goals; expensive duplicate mass
  is UNDER BINDERS where exact localInsts (fvarids) never match across
  commands. → V1 INVENTION: alpha-normalized "context-shape" cache key
  — de-Bruijn-normalize (goal type, local instance types) so
  isomorphic contexts share entries (synthesis is stable under
  renaming); keeps pointer-identity invalidation. Should capture the
  full 91% incl. `BEq α`-style queries. Result must be re-abstracted
  into the TARGET context's fvars on hit (also fixes the olean-drift
  issue if params renormalized canonically). NEXT: time-weighted dup
  analysis (which duplicate queries cost the most ms), then implement
  v1 shape key.
- 2026-07-17 (iter 7): v0 A/B on hot module: TC 851ms→565ms (−34%);
  everything else flat → remaining 565ms is the under-binder mass.
  IMPLEMENTED v1 shape cache (same branch, 2nd commit): ShapeKey =
  eraseBinderNames(mkForallFVars(fvar-closure telescope, goal)) +
  instPositions + synthPendingDepth; entries store results as closed
  lambdas beta-applied to the target telescope on hit; bails on
  let-decls/mvars/escaping results/universe-abstracted results; only
  kind=.noMVars; guarded by same pointer stamps; option
  synthInstance.globalCache.shape for ablation. KNOWN LIMIT: literal
  universe param names must match (u_1 vs u usually consistent from
  auto-bound). Rebuild detached (bench/lean4_rebuild_v1.log).
  VALIDATE NEXT WAKE: compile errors? micro shape test (200 lemmas
  each `{α} [BEq α] : BEq (List α)`-ish), mutation probe rerun,
  List.Lemmas trace (shape: count), Batteries A/B time + determinism,
  olean ON-vs-OFF diff scope.
- 2026-07-17 (iter 11): T2c prototype attempted, DEFERRED at the
  multi-const async commit gap (addConstAsync is per-constant;
  framework self-describes inductDecl as unsupported). skipKernelTC
  ceiling probe: BinomialHeap wall UNCHANGED (1.94s) with checking
  skipped → the 1.31s is the kernel inductive COMPILER (construction),
  not checking (or skip unhonored for inductDecl); T2c still valid
  (whole addDecl moves to background) but framing corrected.
  List.Lemmas: −1.1s user / only −0.2s wall with all kernel checks
  skipped → thm-proof checking already well-hidden by async (T3
  down-weighted). Design doc updated with the RecursorVal-verification
  soundness note. NEXT (iter 12, rotation): T4 — apply the validated
  pointer-stamp technique to simp-set / discrimination-tree reuse
  across commands (simp 0.72s + grind simp 0.83s per hot module).
- 2026-07-17 (iter 12): T4 grind-init hypothesis FALSIFIED cheaply:
  100 trivial grind calls = 8.8ms grind + 23ms grind-simp total
  (~0.3ms/call setup incl. mkParams) — nothing to cache; grind's real
  cost is per-goal ematch/CC work on big goals. (The 142ms TC in the
  probe is legit distinct OfNat-literal queries, not duplicates.)
  T4 remaining candidate (deferred): global whnf/defEqPerm caches for
  closed terms under reducibility stamps — needs instrumentation to
  size before another rebuild cycle. PIVOT: Mathlib-subset benchmark
  for T1's headline value (mathlib4 clone + compat probe with
  speedup-stage1 running in background).
- 2026-07-17 (iter 13): MATHLIB RESULTS (356+~600 modules build under
  patched 4.34-pre; deep build fails on API drift past
  Algebra.Order.Field area). A/B on TC-heavy bootstrap modules:
  Hom.Defs 287/282ms, WithBot 671/741ms (−9%), InjSurj 313/286ms —
  ~no effect. EXPLANATION (mechanism now fully understood): these are
  instance-DEFINING modules — nearly every command grows the instance
  table, so the whole-table pointer stamp invalidates constantly.
  Proof-heavy lemma files (Batteries List.Lemmas −47% TC) keep stable
  tables. → T1 v2 DIRECTION: return to the original red/green design —
  per-class version stamps + touched-class sets per derivation, so an
  instance addition to class C only kills entries whose derivation
  touched C. ALSO: v0's InjSurj slight regression suggests probe
  overhead is nonzero; v2 should probe only after a fingerprint check.
  Portfolio status: T1 (v2 design ready) | T2a/T2c (designs ready,
  multi-const gap) | T3 down-weighted | T4 partially falsified |
  T5/T6 unopened.
- 2026-07-17 (iter 14): T1 v2 DESIGN FINALIZED after mutation-path
  audit (addInstance is monadic/hookable, but scoped activation +
  attribute-erase + wholesale modifyState restores bypass any
  counter hooks → counters unsound). BETTER DESIGN, hook-free:
  record during each derivation the list of (subgoal type, candidate
  instance names) pairs returned by discrTree getInstances; cache
  probe = tier-1 whole-table pointer check (fast path, lemma files),
  on mismatch tier-2 = RE-QUERY the discrTree for each recorded
  subgoal (structural, lctx-free, ~10-50us each) and BEq the
  candidate-name arrays — sound under ANY mutation path by
  construction. Default-instance/reducibility keep pointer stamps
  (rare churn). Est. ~100 lines in SynthInstance.lean + SynthM
  recording. Also: evidence notes.md extended with all measured
  architecture facts; visually improve pass running in background to
  re-ground the 3D scene on measured reality. NEXT (iter 15):
  implement v2 tier-2; check improve pass result + rerun verify;
  refresh scene screenshot in docs.
- 2026-07-17 (iter 15): scene re-verified (PASS on attempt 2 — the
  self-revising verify loop corrected its own counterexample);
  measured-architecture screenshot pushed. T1 v2 implementation spec
  COMPLETED (docs/t1-v2-design.md) incl. the two replay subtleties
  (abstractMVars + fresh-mvar reopen for dangling mctx refs;
  telescope-closure + target-beta for fvar-containing subgoal
  queries) and two new v2-specific mutation probes. NEXT (iter 16,
  fresh context): implement v2 from the spec — recording in
  mkGeneratorNode?/SynthM.State, entry schema change, two-tier probe;
  rebuild; run the extended battery incl. scoped-instance probe;
  re-A/B Mathlib bootstrap modules (WithBot/InjSurj) expecting
  tier-2 rescues.
- 2026-07-17 (iter 16): T1 v2 IMPLEMENTED per spec (4th commit on the
  lean4 branch): SynthM.State.queryLog records (abstractMVars subgoal,
  global candidate names incl. EMPTY lists for failures) in
  newSubgoal; main returns the log; entries carry queries;
  instancesStillValid = tier-1 pointer / tier-2 replayQuery (mirrors
  getInstances filtering: erased + isExporting, priority order);
  shape entries telescope-close query types and beta to target fvars
  at probe; empty-queries entries fail tier-2 (defensive); options
  moved to top-of-file (forward-reference fix learned from v1 error).
  New probes: M_v2_unrelated_class.lean (unrelated instance add must
  tier-2-rescue class-D entry AND flip class-C failure),
  M_v2_scoped.lean (scoped-instance `open` must invalidate). Rebuild
  detached (bench/lean4_rebuild_v2.log). NEXT: full battery (probes,
  determinism, Batteries A/B) + Mathlib bootstrap re-A/B
  (WithBot/InjSurj — expecting tier-2 rescues this time).
- 2026-07-17 (iter 17): v2 BATTERY: unrelated-class probe PASS (trace
  shows the money shot — after the CC-instance add changes the table
  pointer, `Inhabited DD` serves as `global:` via TIER-2 RESCUE while
  `CC DD` re-derives); scoped-open probe PASS (had to rename ST→STx,
  core name clash); Batteries 124.8s (parity) + v2 ON-ON
  deterministic. BUT Mathlib bootstrap ECONOMICS NEGATIVE: WithBot
  wall +20% (4.95 vs 4.11) — table churns every command → tier-2
  replays run constantly and mostly fail → pure overhead on top of
  re-derivation. v2.1: adaptive CIRCUIT BREAKER (IORef stats; open at
  <25% success after ≥32 attempts → graceful fallback to v1) + cap 4
  replays/probe. Rebuild detached (lean4_rebuild_v21.log). NEXT:
  re-run WithBot/InjSurj (expect parity, not regression) + probes
  still pass (breaker must not break correctness — it only SKIPS
  tier-2, conservative direction); then docs/charts refresh + README
  results update.
- 2026-07-17 (iter 18): v2.1 probes all PASS but WithBot STILL +19% —
  circuit breaker was aimed at the wrong cost. ROOT CAUSE
  QUANTIFIED: the RECORDING tax, not replays — WithBot has 8,441
  derivations, each paying duplicate inferType/instantiateMVars (both
  already computed inside mkGeneratorNode?) + abstractMVars ≈
  50-100us => ~+0.5-0.8s, matching the regression exactly. (v2 does
  earn 116 global + 341 shape hits there — swamped by the tax.)
  v2.2 DESIGN: (a) move recording inside mkGeneratorNode? reusing its
  mvarType; (b) DROP abstractMVars — record only hasMVar-free subgoal
  types as raw exprs (free), skip mvar-containing queries and mark
  the entry queriesComplete=false => tier-2 ineligible (those queries
  were never rescuable anyway). Expected: recording ~free, WithBot
  back to parity, lemma-file wins intact. NEXT (iter 19): implement
  v2.2, rebuild, full battery, then docs/README results refresh.
- 2026-07-18 (iter 20): v2.2 battery — all probes PASS, shape micro
  9ms intact, but WithBot STILL +20% → recording-tax hypothesis
  incomplete. Remaining ON-side costs identified: (a) SHAPE-entry
  insert closure (mkLambdaFVars + hasFVar per query per derivation,
  8.4k derivations) and (b) tier-2 replays kept alive by a mixed
  success rate (~116+341 hits keep the breaker closed). v2.3: shape
  entries are tier-1-only again (tier-2 restricted to the exact
  cache where query storage is a free pointer copy). DECISION RULE
  set: if v2.3 still regresses WithBot beyond ~2%, demote tier-2 to
  an opt-in option (default OFF) and freeze T1 at validated-v1
  defaults — honest stable endpoint; loop rotates onward (T2c time
  box or T5). Rebuild detached (lean4_rebuild_v23.log).
- 2026-07-18 (iter 21): MEASUREMENT CORRECTION — the +20% WithBot
  "regression" was single-shot noise/contamination (same binary
  minutes apart: 5.04 then 4.20). 5-run medians: WithBot 4.29 vs
  4.30 (parity), List.Lemmas 2.16 vs 2.17 (parity). FINAL T1
  UNDERSTANDING: TC savings are real CPU (−47% TC, −1% corpus) but
  TC runs on worker threads → not on the single-module critical
  path → no wall delta. T1 CONCLUDED (v2.3 stable: sound,
  deterministic, tier-2 proven, no regression). Methodology rule
  going forward: 5-run medians for all wall-time claims. Loop
  rotates to T2 (the actual wall-clock lever) next.
- 2026-07-18 (iter 22): CAMPAIGN 2 opened. T2c piece 1 DONE:
  bench/RecTypeBuilder.lean — Lean-side recursor-TYPE construction
  for single-ctor no-index non-recursive inductives incl. Prop
  elimination computation (all-proof fields → large elim, data
  field → small elim) and fresh elim-level naming. Validated
  standalone via #eval against the kernel's actual rec types:
  7/7 EXACT (byte-identical) — Prod, Subtype, PProd, And, PropPure,
  PropWithData, Sigma. Zero rebuild cycles (script-first
  development). Orchestration design settled during the time box:
  three sequential addConstAsync handles (T/mk/rec) threading
  mainEnv; ONE kernel task on a1.asyncEnv (prefix T contains all
  three); task commits rec's info FROM THE KERNEL ENV (kills the
  RecursorVal-drift risk — commitConst sig check is the failsafe);
  aux constructions stay on main needing only the eager
  commitSignature (this builder). NEXT (iter 23): implement the
  orchestration in addAndFinalizeInductiveDecl behind
  Elab.asyncInductive (default false), rebuild, blocking/error
  probes, then 5-run-median A/B on BinomialHeap + String.Lemmas.
- 2026-07-18 (iter 23): T2c piece 1b DONE — full RecursorVal builder
  (rules rhs = fun params motive minor fields => minor fields; k=false
  for no-index types; arity metadata) validated 7/7 BYTE-EXACT against
  kernel output, still zero rebuilds. Consequence: the orchestration
  can follow addDeclCore's exact eager-commit pattern (all infos from
  validated builders; kernel confirms + commitCheckEnv), eliminating
  the kernel-env-commit semantics risk. NEXT (iter 24): wire
  addInductiveDeclAsync? into addAndFinalizeInductiveDecl behind
  Elab.asyncInductive (default false): eligibility (single-ctor,
  non-recursive via const-scan, no-index, non-module), three
  addConstAsync handles (T/mk/rec) threading mainEnv, one kernel task
  on a1.asyncEnv (prefix T), eager commits from builders, snapshot
  task for error surfacing; then rebuild + blocking/error probes +
  5-run-median A/B on BinomialHeap & String.Lemmas.
- 2026-07-18 (iter 24): T2c ORCHESTRATION IMPLEMENTED in
  MutualInductive.lean behind Elab.asyncInductive (default false):
  eligibility = single-ctor non-recursive no-index non-module;
  ported+adapted the validated RecursorVal builder (forallTelescope
  non-reducing — pre-addition types mention the unknown const);
  3 addConstAsync handles threading mainEnv; eager commitConst
  (T, mk) + commitSignature (rec); kernel task on a1.asyncEnv
  chained on env.checked via wrapAsyncAsSnapshot/logSnapshotTask
  (addDeclCore pattern); commitCheckEnv x3 in finally — rec's full
  info comes FROM the kernel env, sig-checked against the eager
  signature (documented drift failsafe). KNOWN GAPS: name-prefix
  registration skipped (private helper; namespaces usually
  registered by the namespace command anyway); error probe for
  kernel-rejected inductives TBD. Probe M_t2c_async_ind.lean staged
  (iota reduction, projections, Prop structs). Rebuild detached
  (lean4_rebuild_t2c.log). NEXT: probe battery; if green, 5-run
  median A/B on BinomialHeap/Basic + String/Lemmas with
  -DElab.asyncInductive=true.
- 2026-07-18 (iter 25): T2c first build GREEN, probe PASSES (Type
  structure: projections + iota rfl through the async-committed rec;
  #print shows correct type+rules; trace confirms '(async)' kernel
  checks). BUT A/B parity on BinomialHeap — diagnosis: FindMin.WF
  still sync (trace: plural 'declarations', no async tag). ROOT
  CAUSE: MutualInductive has TWO inductDecl addDecl sites; real
  structures go through mkFlatInductive's site, I had patched only
  addAndFinalizeInductiveDecl. Fixed: block moved above
  mkFlatInductive, both sites intercepted. Rebuilding
  (lean4_rebuild_t2c2.log). NEXT: re-probe + re-A/B (expect the
  1.31s FindMin.WF check to leave the critical path).
- 2026-07-18 (iter 26-27): T2c routing hunt. Mechanism PROVEN (probe
  structures incl. dotted names, section vars, real Batteries field
  types all go '(async)' standalone; iota/projections work). But in
  the REAL module NO structure reaches addInductiveDeclAsync? (bail
  traces show only Heap/HeapNode multi-ctor inductives arriving);
  FindMin/FindMin.WF are kernel-checked via a plain sync addDecl from
  a path not yet identified — a third inductDecl submission site
  (ComputedFields.lean:110? another MutualInductive addDecl?). A/B
  remains parity until routed. NEXT: enumerate ALL addDecl call sites
  reachable from structure elaboration (grep addDecl in
  MutualInductive fully + ComputedFields + Coinductive), instrument
  addDeclCore's sync inductDecl fallback with a decl-name trace, fix
  routing, re-run the A/B.
- 2026-07-18 (iter 28): MYSTERY SOLVED — Batteries main uses the
  MODULE SYSTEM (`module` keyword line 6); my silent v0 scope cut
  (isModule → bail) excluded the entire benchmark corpus. Standalone
  diags lacked `module` → async worked. DEEPER FINDING via non-module
  copy of BinomialHeap: there the heavy kernel items are the WF DEFS
  (HeapNode.WF, already async as defns) and the FindMin.WF structure
  checks in <100ms — the 1.31s sync structure check is a
  MODULE-SYSTEM-SPECIFIC cost (defs exported as axioms change the
  kernel's unfolding path when checking dependent structure fields).
  T2c's target lives exactly in the env my scope cut excludes.
  COMPLETION CONDITION: module-env support — understand what the sync
  path exports for inductDecl under isModule (likely full infos,
  types are structural) and pass exportedInfo? accordingly; lift the
  isModule gate. NEXT (iter 29): read the module-export handling for
  inductives (Environment/module export machinery), implement, A/B on
  the REAL module corpus.
- 2026-07-18 (iter 29): T2c module-env support implemented — isModule
  blanket bail replaced by private-name bail; identity export relied
  on (eager commits already pass exported infos; addConstAsync
  exportedKind defaults correct). Module-header probe staged
  (M_t2c_module_probe.lean). VALIDATION NEXT WAKE (the export
  identity assumption is the risk): (1) module probe, (2) full
  Batteries build ON vs OFF with COMPLETE olean byte-diff (export
  path exercised by every downstream import — any rewriting my
  identity assumption misses will show), (3) the real A/B on
  BinomialHeap/String.Lemmas in their native module form, 5-run
  medians.
- 2026-07-18 (iter 30): T2C FUNCTIONAL AT SCALE + FINAL UNDERSTANDING.
  Module probe PASSES (with @[expose] fix — probe bug, module
  semantics); FindMin.WF confirmed '(async)' in the real corpus; FULL
  Batteries builds with asyncInductive enabled everywhere (217
  modules, no errors). A/B: PARITY (1.94/1.93; 1.52/1.52) — and the
  complete explanation: the 1.31s 'Kernel under structure command'
  was the sync addDecl BLOCKING ON THE KERNEL JOIN (toKernelEnv waits
  for all pending async proof checks) — QUEUE WAIT, not check work.
  Explains skipKernelTC no-op, the non-module-copy vanishing act, and
  async parity (nothing left for main to do at file end).
  MEASUREMENT LESSON for docs: main-thread 'Kernel' trace time can be
  join-waits. Single-shot corpus build showed user −3%/wall −6% (ON)
  — needs medians before claiming. SOUNDNESS ITEM OPEN: 23/188
  oleans differ ON-vs-OFF — must classify (benign normal-form drift
  vs missed export rewriting) + re-verify ON-vs-ON determinism.
  NEXT: determinism check, classify one differing olean, corpus
  medians, then final T2c documentation + README refresh.
- 2026-07-18 (iter 31): T2C VERDICT — WIN. Corpus 5-run medians:
  wall 13.09 vs 13.69 (−4.4%, distributions fully separated), user
  120.4 vs 123.8 (−2.8%); ON-vs-ON deterministic; RatCast public-view
  semantic comparison IDENTICAL (23-olean byte diff classified benign
  stable alternate encoding; downstream corpus type-checks are the
  end-to-end guard). Single-module parity explained (join-wait, pays
  only under core saturation). Docs §8 + README updated. The
  project's largest verified wall-clock improvement. REMAINING for
  T2c hardening: per-file semantic classification of all 23 oleans;
  error-surfacing probe (kernel-rejected inductive); mutual/indexed
  eligibility widening; upstream conversation.
- 2026-07-18 (iter 32): HEADLINE RETRACTED. The commitConst failsafe
  FIRED on NameMapAttributeImpl: fields with optParam/autoParam keep
  their wrappers in the kernel's rec minor premise; my builder strips
  them → sig mismatch → throw (+ upstream fallback PANICs on
  ConstantKind.recursor — framework gap to report). WORSE: my corpus
  A/B harness piped through `tail -1`, hiding per-module build
  failures (lake keeps going) — the −4.4% ON runs may have done less
  work. Eligibility fixed (bail on optParam/autoParam fields);
  docs/README corrected immediately (retraction notes). REDO next
  wake with exit-code + olean-count checks: full battery, then
  either restore the headline with clean numbers or report the
  honest null. Memory lesson: NEVER pipe build A/Bs through tail -1;
  always assert exit status and artifact counts.
- 2026-07-18 (iter 33): asserted harness immediately caught a SECOND
  failsafe fire: classes (LawfulMonadStateOf) — kernel keeps
  outParam/semiOutParam wrappers AND explicit class params in the rec
  type; builder loses both. This also confirms the retraction: the
  iter-30/31 'successful' corpus builds must have been failing on
  these same modules all along (fake −4.4% = less work done). v1.2
  eligibility: wholesale wrapper scan (optParam/autoParam/outParam/
  semiOutParam) + instImplicit-param bail — eligible set narrowed to
  plain wrapper-free structures (FindMin.WF stays in; classes and
  default-field structures out). Rebuilding; next wake = asserted
  ON×5/OFF×5 with exit codes + olean counts, expectation reset to
  modest-or-null (smaller eligible set).
- 2026-07-18 (iter 34): T2C FINAL VERDICT — capability sound, perf
  NULL. Asserted A/B: ON 13.88 vs OFF 13.78 median, overlap, 188/188
  oleans, 10/10 builds green, probes green. The −4.4% is fully
  explained as unbuilt work. Value delivered: async-inductive
  capability (module envs incl.), byte-exact RecursorVal builder,
  failsafe-documented kernel rec-type semantics (wrappers, class
  binder rules), the join-wait measurement lesson, and a clean
  retraction story. T2c CLOSED (v1). Portfolio next: T2a async def
  bodies (17.9% of main thread — the bigger eligible mass) via the
  same now-proven framework path; or T5 imports.
- 2026-07-18 (iter 35): T2a DECOMPOSED before implementing (join-wait
  lesson applied): UnionFind def-command main-thread time is >60%
  TACTIC execution (split/rewrite/simp/simpAll) = termination-proof
  obligations (decreasing_by) INSIDE def elaboration — not body
  computation, not LCNF. And WF-compiled bodies EMBED the termination
  proofs as terms → simple gate-widening cannot decouple them.
  INVENTION SKETCH (T2a'): TERMINATION PROOF OUTLINING — the equation
  compiler emits decreasing_by obligations as SEPARATE theorem
  declarations (async-eligible today!) and the WellFounded.fix body
  references them by constant name; proof irrelevance preserves
  semantics; kernel/codegen unaffected (proofs erased). Effect: WF
  defs' dominant cost rides the existing async-theorem lane. Deep
  surgery in the equation compiler (Elab/PreDefinition/WF) — needs a
  dedicated time box. Portfolio also still holds: T5 imports,
  T4 whnf-global instrumentation, T1-v2 probe-perf polish,
  T2c upstream conversation.
- 2026-07-18 (iter 36): T2a' spec COMPLETE
  (docs/t2a-termination-outlining.md): entry point =
  WF.Fix.solveDecreasingGoals:250 (goals as mvars, solved in place);
  outline = telescope-close each goal, register <fn>._dec_<i> via the
  async-theorem body-task pattern (statement known pre-tactic), assign
  mvar := const app; GuessLex probing must stay sync (drives measure
  inference — only post-measure obligations outline; Batteries uses
  explicit termination_by so its tactic time is the outlinable kind).
  Validation plan per established discipline incl. eq-lemma
  end-to-end and async error attribution. NEXT: implement from spec.
- 2026-07-18 (iter 37): T2a' STRENGTHENED — Lean.Meta.mkAuxTheorem
  (Closure.lean:457) already extracts value-embedded proofs as
  foo.proof_N aux lemmas (synchronously). The general design: async-ify
  aux-theorem registration (eager statement + tactic as body task) at
  the existing extraction points — covers termination obligations AND
  ordinary by-proofs in def values. mvar-free goals only; GuessLex
  sync. This is the implementation-ready shape for the next deep time
  box (fresh session recommended: multi-rebuild surgery). Session
  state: 2 campaigns closed (T1 wall-neutral CPU-real; T2c sound but
  perf-null), T2a' implementation-ready, all materials in docs/,
  14-commit patch series, methodology hardened (asserted harness,
  5-run medians, join-wait classification).

## NEXT SESSION: START HERE

The T2a' implementation (docs/t2a-termination-outlining.md) is the queued
deep time box. Critical realization recorded at session end: mkAuxTheorem
receives the proof VALUE already computed — the tactic time is spent
earlier, in the by-tactic term elaborator (Term.runTactic /
elabByTactic / postponed-block synthesis). The async-ification point is
therefore the BY-BLOCK elaborator: for mvar-free goals in def contexts,
register the aux theorem with eager statement, spawn the tactic as a body
task (study Term.wrapAsync + snapshot + realization machinery in
Elab/MutualDef — theorem-body async already solves the env-effects
problem), return the const reference immediately. Watch: tactics with
environment effects (native_decide, run_tac) need the realization channel
or a sync bail.

Working setup: lean4/ fork branch speedup/global-synth-cache (16
commits), stage1 built, toolchain linked as `speedup-stage1`; batteries
+ mathlib4 clones configured; asserted A/B harness at scratchpad ab.sh
pattern (exit codes + olean counts + awk timing — bc is absent on this
box); 5-run medians mandatory; probes in bench/M_*.lean.
- 2026-07-18 (iter 39): T2a' ceiling ATTRIBUTED from existing profile:
  UnionFind def-tactic time = 0.05s under decreasing frames vs 0.35s
  ordinary value-embedded proofs. WF-only outlining variant KILLED
  (small ceiling); the general by-block async (mvar-free proof goals
  in def contexts -> async aux theorems) is the single implementation
  target. Design doc updated. Zero-cost iteration (existing data).
- 2026-07-18 (iter 40): T2A V0 IMPLEMENTED — tryRunTacticAsync in
  SyntheticMVars.lean (mutual block with runTactic): gates = .term
  kind, option Elab.asyncByProofs (default OFF), Elab.async, non-
  module env, mvar-free Prop goal, let-free lctx, closed stmt;
  mechanism = addConstAsync(.thm) + eager commitSignature +
  wrapAsyncAsSnapshot task (forallTelescope-recreated goal, runTactic,
  addDecl thmDecl, commitConst/commitCheckEnv) + logSnapshotTask with
  the by-block stx for error attribution + mvar assigned const app.
  Rebuild detached (lean4_rebuild_t2a.log). NEXT: compile fixes if
  any; probe file (def with by-proof values, error attribution,
  within-def dependent proofs); asserted A/B on UnionFind/Basic
  (0.35s ceiling) + corpus.
- 2026-07-18 (iter 42): T2a v0 — PERF PROMISING, CORRECTNESS BROKEN
  (honest interim). Non-module UnionFind A/B: 0.65 vs 1.02s median
  (−36%!) — the by-proof mass genuinely moves off the main thread,
  AND unlike T2c this is single-file wall (proofs were on the crit
  path). Failing-proof error surfacing PASSES (omega failure attributed
  to the right by-block range). BUT the olean determinism check hit a
  SOUNDNESS BUG: 'kernel declaration has free variables
  parentD_set._byAsync_1_1' — for by-proofs that depend on local
  hypotheses (dite/Array.size_set h), AbstractNestedProofs inside the
  async addDecl extracts sub-proofs that capture the reopened
  telescope fvars incorrectly. ROOT: my forallTelescope-reopen +
  mkLambdaFVars + addDecl path lets nested-proof abstraction lift
  telescope-bound vars out of scope. Options default OFF so main
  build unaffected. FIX DIRECTIONS (next): (a) disable nested proof
  abstraction in the async aux (set the option around addDecl), or
  (b) don't reopen — keep the proof as a 0-ary theorem of the CLOSED
  stmt and let the caller instantiate, or (c) abstractNestedProofs
  BEFORE going async so extraction happens in the right context.
  DO NOT claim the −36% until correctness holds. README/docs
  unchanged (nothing to publish yet).
- 2026-07-18 (iter 43): T2a v0.1 (closed-goal-only) — SOUND but
  PERF-NULL. Determinism ✓ (ON-vs-ON identical oleans), zero build
  errors, no free-variable kernel error. BUT A/B parity (1.04 vs
  1.04): the −36% came ENTIRELY from under-context proofs, which are
  the ones with the telescope-capture bug. UnionFind's by-proofs all
  carry local hypotheses (arr/i/h) → closed-goal guard almost never
  fires. HONEST VERDICT: the async-by-proof idea is real (proofs ARE
  on the single-file crit path, unlike TC/inductives) but the SAFE
  subset is empty of value; the valuable subset needs telescope-safe
  nested-proof abstraction = the genuinely hard part. That's the
  queued deep-session work (handoff below updated). Nothing published
  (correct: no honest headline yet). This closes the light-iteration
  productive surface — remaining tracks (correct T2a, T5 imports) are
  all deep multi-rebuild surgery best done in a focused session.

## HANDOFF (updated iter 43)

Three campaigns run: T1 (synthInstance cache — CPU-real, wall-neutral,
shipped+documented), T2c (async inductives — sound, perf-null,
documented), T2a (async by-proofs — sound subset perf-null; valuable
subset needs telescope-safe nested-proof abstraction). All on branch
speedup/global-synth-cache (19 commits), stage1 built. The one
remaining high-value lead: make tryRunTacticAsync
(SyntheticMVars.lean) handle non-empty contexts correctly —
abstractNestedProofs must abstract the telescope vars, or the
extracted <decl>._N aux proofs must be committed as async consts
closed over the same binders. Ceiling: ~0.35s/def-heavy-file (the
−36% seen before the soundness gate). Methodology locked: asserted
harness (exit+olean counts), 5-run medians, soundness gate BEFORE
perf claims, honest retractions.
- 2026-07-18 (iter 44): INFORMED root-cause read + soundness-at-scale.
  Read the closure machinery: mkAuxTheorem -> mkValueTypeClosure
  CLOSES over fvars by construction (returns mkAppN (mkConst name)
  exprArgs), so nested-proof abstraction is fvar-safe in principle.
  => the telescope-capture bug is NOT in closure logic but in a
  subtler async-branch interaction (the asyncEnv prefix restriction
  `_byAsync_N` vs the declNGen used by mkAuxLemma during the task, or
  aux decls added to the async branch before the closure's fvar set is
  finalized). This NARROWS the next-session search to the async
  env-branch/declNGen seam, not the abstraction algorithm.
  DELIVERABLE: full Batteries corpus builds CLEAN with
  Elab.asyncByProofs=true (closed-goal subset), 188/188 oleans, exit 0
  via the asserted harness — the safe subset is corpus-sound at scale
  (perf-neutral, as expected). One build, not iterative.
- 2026-07-18 (iter 45): T2a v0.2 — INFORMED FIX for the capture bug.
  Confirmed via DeclNameGenerator (CoreM.lean): aux proofs extracted
  during the tactic were named `<def>._proof_N` (prefix = enclosing
  def) but the async branch is restricted to `<def>._byAsync_N` →
  the 'restricted to prefix' / free-variable rejection. FIX: wrap the
  task in `withDeclNameForAuxNaming declName` so extracted proofs are
  named `<declName>._proof_N` (under the async prefix). This lets the
  valuable UNDER-CONTEXT path be re-enabled (telescope-close + lambda).
  Rebuild detached (lean4_rebuild_t2a5.log). VALIDATION NEXT WAKE
  (soundness gate FIRST): UnionFind free-variable check, ON-vs-ON
  determinism, then 5-run A/B (expecting the −36% to return SOUNDLY);
  if determinism/kernel fails, revert to v0.1.
- 2026-07-18 (iter 46): T2a DEFINITIVE NEGATIVE. v0.2 naming fix
  confirmed working (aux now under async prefix) but the free-variable
  error PERSISTS + new 'synthesize placeholder hc' error → the true
  blocker surfaced: under-context by-proofs share the def's synthetic
  placeholders (hc) and outer-scope fvars; they are NOT self-contained
  and cannot be outlined without solving Lean's delayed-assignment /
  cross-goal-placeholder problem (research-grade, out of scope).
  Reverted to sound closed-goal subset (perf-null), kept the correct
  naming fix, documented the full verdict in docs. T2a CLOSED. ALL
  THREE async tracks now have honest final verdicts: T1 CPU-real/
  wall-neutral; T2c sound/perf-null; T2a sound-subset-perf-null,
  general-case-blocked. The campaign's durable output = the
  measurement methodology + a precise map of WHERE Lean's async
  boundary can and cannot move, all documented + patch series.
- 2026-07-18 (iter 48): SYNTHESIS — located the wall-clock lever via
  module-DAG critical-path analysis (no rebuild). Batteries: work
  129.6s, 16-core floor 8.1s, WEIGHTED CRITICAL PATH 10.0s
  (Alias→List.Basic→List.Lemmas + RBTree.Lemmas), wall ~13s =>
  CRITICAL-PATH-BOUND. Critical modules cap at 2.9/16 cores (List.
  Lemmas 6.08s user/2.09s wall @16thr, ~34% serial) → ~13 cores idle
  in the build tail. THIS UNIFIES ALL THREE CAMPAIGNS: the lever is
  the intra-module serial decl-dependency fraction of critical-path
  proof modules; T1/T2c/T2a each targeted it and each was
  individually insufficient because it IS the fundamental proof-N-
  depends-on-N-1 chain. Future target (precise, measured): critical-
  path decl/module fission OR more-parallel dependent-chain
  elaboration. Chart docs/assets/critical-path.svg. Docs+README
  updated with the synthesis. This is the project's central
  diagnostic result — worth more than any single patch.
- 2026-07-18 (iter 49): SYNTHESIS SHARPENED via thread profile of
  List.Lemmas: main-thread busy 2.29s ≈ wall 2.09s; 26 workers carry
  proofs (~6s CPU / 2.9 cores real). => proof-body parallelism is
  ALREADY SOLVED; the ceiling is SEQUENTIAL MAIN-THREAD STATEMENT/
  COMMAND elaboration (main occupancy = wall). This is WHY T2a/T2c
  hit a wall — they parallelize bodies, not statements. The true
  frontier = COMMAND-LEVEL PARALLELISM (concurrent independent
  theorem-statement elaboration), which Lean's frontend does
  sequentially by design (macro/env ordering). Highest lever,
  hardest change. Docs updated. This fully closes the diagnostic
  arc: measured, charted, and the frontier named precisely.
- 2026-07-19 (iter 50): T3 MODULE FISSION — new track (nuclear-fission
  transfer: split the heavy critical-path nucleus iff fragment binding
  is weak). Measured fissility of List.Lemmas via a decl-DAG extractor
  (bench/DeclDag.lean): 339 decls / 347 edges / longest chain 11 —
  wide+shallow, 84 components. Component-packed 3-way split
  (bench/fission_split.py: block granularity, hoisted naked attribute
  lines, open-Option scope repair) + re-exporting stub; full corpus
  builds CLEAN (191 oleans, rc=0). A/B (5-run medians, cold lake
  build): 13.79 vs 13.79 s — WALL-NEUTRAL. Mechanism works (Lemmas1
  3.2s ∥ Lemmas2 1.8s ∥ Lemmas3 1.1s vs monolith 3.7s) but the giant
  dependency component = 59% of decls carries 86% of time: TIME-
  fissility is the limit, not count-fissility. Fourth independent
  confirmation of the iter-48/49 synthesis (the decl-dependency core
  IS the wall) — and the cheapest probe of it (zero compiler changes).
  Docs: docs/t3-module-fission.md + chart; batteries tree restored
  pristine (split regenerable from scripts).
- 2026-07-19 (iter 51): T4 ALIAS BARRIER — micro-attribution of main-
  thread time (T3 follow-up: what IS the sequential mass?) found the
  biggest single command in List.Lemmas is `@[deprecated] alias ...`
  = 394ms of main-thread WAIT (not work). Characterized rigorously
  (bench/M_t4_*): alias stalls main until the target's TRANSITIVE
  async cone (elab+kernel) completes — async-off kills it, imported
  targets don't stall, it follows references, scales with cone
  weight; #check/attribute on the same fresh const DON'T stall →
  alias-specific (RAW-hazard transfer). addDecl exonerated (async
  rules, 1ms). Sig-only rewrite of Alias.lean (findAsync? +
  toConstantVal) compiles but does NOT remove the stall; timestamp
  bisection defeated by thunk-force reordering (every call 0ms, span
  107ms); trace.profiler can't sample blocked threads. OPEN: name the
  forcing frame via OS-level sampler (gdb batch), then fix (alias
  should cost ~1ms like #check). Mathlib has thousands of deprecated
  aliases directly after their targets = worst case → real upstream
  candidate. docs/t4-alias-barrier.md. Batteries tree restored.
