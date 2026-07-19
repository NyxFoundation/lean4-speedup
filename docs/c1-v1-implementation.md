# C1 v1 — implementation spec (statement cache + addDecl replay)

2026-07-20 (iter 93). File-level plan for the settled architecture
([c1-wavefront-design.md](c1-wavefront-design.md) §v1 architecture).
Prior-art confirmation: `MutualDef.lean:1275` carries an upstream TODO —
"parallelize header elaboration as well? Would have to refactor auto
implicits catch, makes `@[simp]` etc harder?" — inside the async-theorem
branch. Our evidence chain answers both cited obstacles: auto-implicit
telescopes are *gated out* (T10's refusal rule; Mathlib is
autoImplicit-false), and attributes are *replayed syntactically* (the
main thread applies them as today — only header elaboration moves).

## Scope (v0 of v1)

Single non-mutual **theorems** with mvar-free speculated types — the
exact eligibility of today's `elabAsync` branch (MutualDef.lean:1237),
which is also the dominant Mathlib statement mass. Defs/instances stay
sequential (later widening).

## Pieces

1. **Cache** (`src/Lean/Elab/SpeculationCache.lean`, new):
   process-global `IO.Ref` mapping a syntax fingerprint (hash of the
   command syntax structure) to an entry
   `{ baseEnvPtr : USize, readSet : NameSet, sig : {name, levelParams,
   type : Expr}, bodyStx : Syntax, ngenHi : NameGenerator }`.
   Single-slot or small ring; entries are closed data only.

2. **Producer** — speculation launcher in the cmdline driver path
   (`Language.Lean.process.parseCmd`: after parsing command N and
   *before* its elaboration task completes, spawn a `BaseIO` task that
   parses N+1 from N's parser state under the pre-N env and, when it is
   a `declaration` whose view is a single theorem, elaborates
   `sorryBodies`-transformed syntax against a copy of the pre-N
   `Command.State` (async off inside the task), then extracts the new
   constant's type via the map₂ diff and the statement read set via the
   proven info-tree collector (harness code), storing the entry. The
   task must swallow errors (store nothing). Behind option
   `Elab.speculateStatements` (default false).

3. **Consumer** — in `elabMutualDef`'s async-theorem branch: before
   `elabHeaders` runs (or before its expensive part), probe the cache
   with the current command's fingerprint. Validation on hit:
   (a) writes since the entry's base env (map₂ diff between current env
   and base — requires the base env *value* or its map₂ snapshot in the
   entry) ∩ readSet = ∅; (b) re-parse identity is implied by fingerprint
   match on the *current* parse; (c) ngen fast-forward past entry.ngenHi
   (T10 technique). On valid hit: skip header elaboration; feed
   `async.commitSignature { name, levelParams, type }` from the entry;
   spawn the body task from the ORIGINAL body syntax (not the sorry) as
   today; apply attributes on main as today. On miss: sequential (zero
   delta from today).

4. **Counters/trace**: `trace.Elab.speculate` (hit/miss/invalid) +
   diag counters for A/B accounting.

## Gates (per playbook, all mandatory before any claim)

Probes: adjacent-dependency theorem pairs (must miss), attribute
preservation (@[simp] applied on adopted statements — simp set must
contain the decl), scoped/open interleave, universe-polymorphic
statements (defeq-alternate drift documented), error attribution
(body errors point at the right ranges when the statement was adopted).
Corpus: Batteries 188/188 + Equiv.Basic + 6-module canary, olean
structural-diff (byte drift documented as T10-class). A/B: 5-run
medians on Equiv.Basic (prediction from harness: up to −58 % of
main-thread statement time on hit-rate ~79 %; wall prediction more
modest — main also runs attribute application and commit).

## Risks carried forward

Speculation-task global side effects (realizeConst from the task —
audit; likely benign since env branches are designed for concurrent
realization); memory (state copies per speculation — bounded by
depth 1); the `Language.Lean` incremental/server path must keep
speculation OFF (server has its own incrementality; guard on
`Elab.inServer`).
