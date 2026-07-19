# T10 — the section-telescope re-elaboration tax (a second T6-class quadratic)

2026-07-19, iter 76. Found by *looking at the critical chain* of the C1
wavefront simulator: the chain was full of `variable` commands.

## The scaling law (measured)

Per-command `[Elab.command]` spans for the 82 bare `variable` commands in
`Mathlib.Algebra.Module.Equiv.Basic` (trace.profiler, threshold 1 ms):
within a section the cost grows monotonically — 20 → 25 → 30 → … → 81 ms
over 19 consecutive commands — then RESETS to ~2 ms at the section
boundary. Total: **1,306 ms of 5,969 ms module elaboration = 22 % spent
in bare `variable` commands alone** (and this is only the visible part —
see "hidden share" below).

## Mechanism (located in core)

- `elabVariable` (`src/Lean/Elab/BuiltinCommand.lean:415-430`): every
  `variable` command "tries to elaborate binders for sanity checking" via
  `runTermElabM`.
- `runTermElabM` (`src/Lean/Elab/Command.lean:774-778`): brings section
  variables into scope by `Term.elabBinders scope.varDecls` — the ENTIRE
  accumulated telescope, every time.

So the k-th `variable` command in a section elaborates all binders of
commands 1..k → O(k²) per section, with a large constant: each binder
like `[Module R M]` runs real TC synthesis. Trace evidence: the 81 ms
`variable [RingHomCompTriple …]` block visibly re-elaborates
`RingHomInvPair σ₁'₂' σ₂'₁'` etc. — binders declared by EARLIER commands.

**Hidden share**: every DECL command also enters `runTermElabM` and pays
the same accumulated-telescope elaboration before its own statement. This
is the root mechanism behind the iter-64 "Semiring flood" (60 % of TC
queries in the hottest module = trivial local-instance goals at
accumulating binder stages — those stages ARE the per-command telescope
re-elaborations) and part of the Mathlib statement-elaboration wall
(iter 72: 1.3–1.7 cores).

## Prior-art status

Known community pain point — the [Zulip `variable` command discussion](https://leanprover-community.github.io/archive/stream/270676-lean4/topic/Lean.204.20variable.20command.20discussion.html)
records "variables are elaborated again for every declaration, which can
be a performance issue", and the [survival guide](https://github.com/leanprover-community/mathlib4/wiki/Lean-4-survival-guide-for-Lean-3-users)
notes the design "conflicts with … parallel compilation". No fix landed
as of master 2026-07 (the quadratic is measured on our 4.34-pre stage1).
Our delta: the quantified scaling law + critical-path placement + a
concrete fix design.

## Fix design space (queued)

1. **v0 — variable-command prefix skip**: `elabVariable` sanity-checks
   only the NEW binders, elaborated in the context of the accumulated
   telescope (needs the telescope anyway → see v1; but a cheap variant —
   elaborate new binders under the full prefix without re-checking the
   prefix — kills the intra-`variable` quadratic while keeping per-decl
   cost).
2. **v1 — cached elaborated telescope**: memoize the elaborated
   `scope.varDecls` prefix (exprs + local instances) per scope, keyed by
   the T1 pointer-stamp technique (instance/reducibility table identity);
   `runTermElabM` extends the cache with only new binders. Kills both the
   `variable` quadratic AND the per-decl hidden share. Invalidation
   hazards: new instances/notation between commands changing binder
   elaboration (stamps catch instance-table growth); mvar/universe
   hygiene across commands (the T1 v1/v2 experience applies directly);
   auto-bound implicits recomputed per command.
3. **Interaction with C1 wavefront**: cached telescopes are exactly the
   "reconstructible context" C5 assumed; T10's fix is a prerequisite for
   cheap out-of-order command elaboration (each speculated command must
   materialize its scope without O(telescope) cost).

## Verdict potential

Equiv.Basic ceiling for the visible part alone: −22 % module wall if
telescope elaboration became O(new binders). Mathlib-wide: `variable`
commands number in the tens of thousands. This is the highest-EV core
patch candidate since T6.
