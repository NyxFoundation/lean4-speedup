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
