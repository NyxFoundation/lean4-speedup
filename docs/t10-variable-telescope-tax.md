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

## Verdict (iters 77–78): IMPLEMENTED AND VALIDATED — −12.2 % module wall

`Elab.varTelescopeCache` (default off) on the lean4 `t6-upstream` branch
(commits 7730c797 + f5c54485): `runTermElabM` caches the elaborated
telescope in a single-entry process-global ref; key = varDecls
pointer-prefix + scope fields (ns/openDecls/levelNames/isNoncomputable/
isPublic/isMeta/opts) + env object identity (`runCore` now only calls
`Kernel.resetDiag` when diagnostics are on, so an unmodified env keeps its
pointer — a standalone allocation win too). Prefix hits elaborate only the
suffix binders.

Three soundness hazards found and closed during validation (all are
instances of one law: **state that lives outside the captured
Term/Meta snapshot must be captured, fast-forwarded, or refused**):

1. **ngen rollback** — instance-name pre-elaboration runs under state
   rollback; the IO.Ref cache escapes it, so snapshot ids collided with
   reissued ids (deterministic `AddCommMonoid M vs Type u_2` failure in
   Equiv.Basic). Fix: store the post-elaboration `NameGenerator`; every
   hit fast-forwards the current generator past it.
2. **Error-state telescopes** — caching a failed binder elaboration
   replays broken state; store now refuses when the (per-command) log has
   errors.
3. **Auto-bound section variables** — auto-bounds accumulate in the
   *reader's* `autoBoundImplicitContext` retry loop, invisible to the
   snapshot; a hit dropped them (dangling-fvar kernel error in
   `Batteries.Lean.HashSet`). Store now refuses auto-bound telescopes
   (Mathlib sets `autoImplicit false`, so its win is unaffected).

Measured (final binary): synthetic k=256 `variable` chain 1670 → 264 ms
(quadratic → linear); **Equiv.Basic 4.910 → 4.309 s = −12.2 % module
wall** (5-run interleaved medians, distributions fully separated) — the
project's largest verified wall win, exceeding T6's −7.4 %. Gates:
probes (7 axes incl. auto-bound) byte-identical ON/OFF; 66-line Mathlib
repro byte-identical; Batteries corpus 188/188 oleans rc=0 with cache ON.

Olean caveat, classified: ON runs show rare (1/5) 27-byte drift and a
253-byte ON-vs-OFF delta, but structural comparison of all 292 constants
(name/levelParams/type/value) shows **zero differences** in both cases —
the delta is physical compacted-region layout (sharing structure), not
content; hit/miss sequences are proven run-deterministic, and OFF under
CPU-load perturbation stays byte-stable (0/15). Byte-reproducibility
under the option is the one open item for a default-on upstream story;
as an opt-in build accelerator the gates are green.

Remaining headroom: the per-decl telescope tax (each decl command still
re-elaborates the full telescope when any decl intervened — the env
stamp is per-object). A finer stamp (constants-map identity + extension
sub-stamps) or C1-integrated scope reconstruction would unlock it.
