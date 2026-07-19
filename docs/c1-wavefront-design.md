# C1 — wavefront (speculative) command elaboration: design

2026-07-20 (iter 80). The funded invention target (T9 gate: 4.0× ceiling
on Equiv.Basic; statement-dep DAGs are depth-≤3 def-rooted hubs). Status:
design + oracle plan; no implementation yet.

## Architecture reality (from src/Lean/Language/Lean.lean)

- The frontend is already task-structured: each command is a
  `CommandParsedSnapshot` produced by `process.parseCmd`, chained through
  the previous command's `cmdState` (`Command.State`: env, scopes, ngen,
  …). `parseCmd` for command N+1 runs only after N's
  `elabCommandTopLevel` finished (Lean.lean:751,770).
- **Parsing itself serializes on the env** — the token table / syntax
  extensions live there. A wavefront must either treat
  notation/macro-defining commands as parse barriers (they are rare
  mid-module; C5 census owed) or pre-parse optimistically and re-parse on
  token-table change.
- The sequential medium is exactly `cmdState`; the wavefront question is
  which components of it a command actually reads: env constants
  (measured shallow — T9), instance/attribute ext state, scope stack
  (reconstructible — T10 cache), macro state (rare writers).

## The plan: oracle first, speculation second

### v0 — zero-rebuild oracle (next iteration)

Before any scheduler surgery, measure the TRUE speculation-validity rate
(the census was syntactic/type-level only; it misses name-resolution
reads, failed-candidate instance probes, and notation deps):

- Run a module through a script-driver frontend (`run_meta`/frontend API
  in the corpus env, like bench/StmtDeps_*.lean) with info trees enabled.
- Per command, extract from its InfoTree every same-module constant
  reference in *statement-position* TermInfo nodes (proof-body subtrees
  excluded — bodies are async already).
- Replay the wavefront schedule offline (reuse bench/wavefront_sim.py's
  model) with these TRUE read sets + writer sets (decl names per
  command), and report: % of commands whose full statement-read set was
  committed at their wavefront slot; the corrected speedup ceiling.
- Gate: if the true ceiling collapses below ~1.5× on Equiv.Basic, C1
  dies cheaply and the loop pivots (e.g. to the T10 per-decl stamp,
  which needs no reordering at all).
- **RESULT (iter 82–83): gate PASSED.** True per-command read sets
  (info-tree oracle, `bench/c1_oracle.lean`) validate the census —
  85 %/37 %/32 % (prev-1/prev-8/fully-independent) vs the census's
  80 %/30 %/24 %. The exact-ceiling replay on oracle-true deps with
  measured per-command times (`bench/wavefront_sim_oracle.py`, 79 %
  time-mass aligned): sequential 4,797 ms → **1,631 ms = 2.9× (16
  workers), 2.3× (4 workers)**. Lower than the census-based 4.0×
  because true reads add name-resolution/coercion edges, but ~2×
  above the kill gate. v1 proceeds with 2.3–2.9× as the honest
  ceiling band on the hottest Mathlib module.

### v1 — speculative statement pre-elaboration (the invention slice)

Smallest reuse-bearing slice, respecting the T10 three-hazard law:

- While command N elaborates on main, a worker takes command N+1's
  already-parsed syntax and elaborates its *statement only* against the
  pre-N `cmdState` (scope materialized via the T10 telescope cache),
  recording (a) resolved same-module names, (b) instance-table stamps,
  (c) the post-header Term/Meta snapshot + ngen ceiling.
- When N commits, validate: N's written decl names ∩ N+1's read set = ∅,
  AND no name-capture (a new decl whose name would re-resolve one of
  N+1's references under N+1's namespace/open context), AND stamps
  clean. On success, restore the snapshot on main (ngen fast-forward!)
  and proceed directly to proof-task spawning; on failure, discard —
  behavior identical to today.
- Speculation depth 1 (one command ahead) first; the T9 DAG says even
  depth-1 covers 80 % of Mathlib statements (99 % Batteries).
- Env branching: the worker needs a read-only env view — Lean's async
  infrastructure already forks envs for proofs (`addConstAsync`
  branches); reuse that mechanism rather than inventing one.

### Failure modes to probe (from the T10 campaign's law)

rollback-escaping side channels (any global ref the speculation touches),
reader-context state (auto-bounds), realization-driven env mutation
mid-command (observed in iter 77: →+*/RingHomInvPair binder elaboration
changes the env object — speculation validation must tolerate or account
for realizations, which are semantically idempotent), and message/info
attribution (speculated elaboration's diagnostics must surface as if
sequential).

## Why this can be an *invention* (protocol v2 framing)

Status change: "statements rarely read recent writes" (measured) is
promoted to a scheduling axiom with repair — TRIZ separation-in-time;
Tomasulo transfer at the command level; Uzzi-shaped: entirely
conventional machinery (tasks, snapshots, validation) around one atypical
ingredient (textual order treated as advisory for statements). Upstream
parallelism stops at proof bodies; this is the unclaimed layer.

## v1 architecture (settled iter 92): speculative statement cache + addDecl replay

The commutativity experiments (iters 90–91) forced a redesign that is
*simpler* than state transfer:

- **Naive replay-adoption doesn't save wall**: continuing from the
  speculated state requires re-elaborating N on top of it — main pays N
  twice to hide N+1. Dead end (measured reasoning, iter 90).
- **State-diff merging is unnecessary**: a declaration command's effect
  on `Command.State` decomposes as (a) new constants, (b) attribute
  applications, (c) declaration ranges, (d) ngen/macro counters — all
  cheaply *replayable* onto the post-N state from the speculation's
  outputs. The expensive part (statement elaboration: TC, unification,
  coercions) is exactly what the speculation caches.

So v1 = **speculation as a statement-elaboration cache**:

1. Worker speculates command N+1 (statement-only, sorry-body — 94 %
   valid on Batteries, 79 % on Mathlib) against the pre-N state,
   returning the elaborated declaration signature (closed
   `ConstantInfo` type + binders) and its recorded read set.
2. On N's commit, validate (read/write disjointness + re-parse identity
   + clean): **hit** → skip statement re-elaboration; commit the
   speculated signature via the existing `addConstAsync` path on the
   post-N state and spawn the body as an async task against it (the
   async-theorem machinery consumes exactly (statement, body-task));
   replay attributes/ranges syntactically. **Miss** → elaborate
   sequentially as today (discard = current behavior; 0 risk).
3. No mctx/lctx/Term-state transfer at all — only closed terms cross
   the boundary, so the T10 three-hazard surface (ngen rollback,
   reader state, error states) mostly disappears; ngen fast-forward
   still applies for id hygiene.

Defeq-alternate statement drift (12 %, iter 89) becomes the same
documented byte-level phenomenon as T10's cache — semantically sound,
olean-byte-visible. Scope/ctx commands stay sequential (iter 91: the
cascade proof). Expected win: the hidden fraction measured live — 58 %
of main-thread time on Equiv.Basic at depth 1.
