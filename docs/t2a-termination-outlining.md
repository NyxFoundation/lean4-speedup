# T2a′ design: termination proof outlining

Status: fully specified (2026-07-18); implementation queued.

## Motivation (measured)

Main-thread time under `definition` commands is dominated (>60 % on
UnionFind/Basic) by tactic execution — the `decreasing_by` /
`decreasing_tactic` obligations of well-founded recursion, elaborated
inline on the main thread. WF-compiled bodies *embed* these proofs as
terms inside `WellFounded.fix` applications, so the theorem-only async
elaboration gate cannot be simply widened to defs.

## The idea

Emit each termination obligation as a **separate auxiliary theorem** —
async-eligible with today's machinery — and reference it by constant name
in the fixpoint body. Proof irrelevance makes the substitution
semantically invisible; codegen is unaffected (proofs erase in LCNF); the
kernel checks the aux theorems on the async chain like any user theorem.

## Implementation entry point

`Lean.Elab.PreDefinition.WF.Fix.solveDecreasingGoals` (Fix.lean:250):
goals are collected from the fixpoint value as mvars, grouped per
function, and solved in place by `decreasing_by` / `decreasing_tactic`.
Change per goal:

1. Close the goal's statement over its local context (the goal lctx's
   fvars beyond the elaboration base): `stmt := mkForallFVars fvars
   goalType`. Bail to the inline path if closure fails (mvars/let-decls —
   the T2c lesson: conservative bails + a failsafe).
2. Register an auxiliary theorem `<fn>._dec_<i>` via the async-theorem
   machinery: statement committed eagerly, the tactic runs in a
   background task producing the proof (mirror `Term.elabAsync`'s
   body-task pattern; the statement is known before the tactic runs, so
   the async-theorem precondition holds).
3. Assign the original mvar := `mkConst <fn>._dec_<i> lvls` applied to
   the telescope fvars. WF elaboration proceeds immediately.

## Critical caveat: GuessLex must stay synchronous

When no explicit `termination_by` is given, `GuessLex` *probes* decreasing
tactics speculatively to infer the lexicographic measure — those runs
drive elaboration decisions and cannot be deferred. Outlining applies only
to the final obligations after the measure is fixed. Corpus note:
Batteries' WF-heavy files use explicit `termination_by`, so their measured
tactic time is final-proof solving — the outlinable kind.

## Validation plan (per the established discipline)

- Probes: WF def with explicit `termination_by`+`decreasing_by`; default
  tactic; mutual WF defs; a failing decreasing proof must fail the module
  with the error attributed to the right syntax range (async error
  surfacing).
- `foo.eq_def` / equation lemma generation must be unaffected (they
  unfold through `WellFounded.fix` — check simp-based proofs about WF
  defs still work: Batteries corpus is the end-to-end test).
- Asserted harness (exit codes + olean counts), 5-run medians, ON-vs-ON
  determinism, olean ON-vs-OFF classification.
- Ceiling check first (cheap): count final-obligation tactic time vs
  GuessLex time across the corpus by profiling a file WITH explicit
  termination_by vs one relying on inference.

## Strengthening discovery: `mkAuxTheorem` (Closure.lean:457)

Lean already *extracts* value-embedded proofs into `foo.proof_N` auxiliary
lemmas via `Lean.Meta.mkAuxTheorem` — synchronously. The general form of
this design is therefore: at extraction points where the proof came from a
tactic block with an mvar-free goal, register the aux theorem with the
statement committed eagerly and the tactic running as a body task (the
async-theorem pattern). This covers BOTH termination obligations and
ordinary `by`-proofs inside definition values, reusing existing extraction
points instead of new surgery in the WF pipeline. Constraints: mvar-free
goals only (postponed by-blocks stay sync); GuessLex probing stays sync.

## Ceiling attribution (measured — narrows the design)

Frame-chain attribution on UnionFind/Basic: of def-command tactic time,
only **0.05 s runs under decreasing-tactic frames**; **0.35 s is ordinary
value-embedded proof tactics** (`⟨…, by …⟩` constructions). The WF-only
outlining variant therefore has a small ceiling (~10 % of def-tactic
time) and is NOT worth its own surgery — implement at the general
by-block level (async aux theorems for mvar-free proof goals in
definition contexts) or not at all.

## Expected effect

General by-block async: def-elaboration proof cost (the 0.35 s class plus
termination obligations as a special case) rides the async-theorem lane,
where worker cores idle at 30-45 %. Corpus effect concentrated in
build-tail impl modules; measured honestly via the asserted harness.
