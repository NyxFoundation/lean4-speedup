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
