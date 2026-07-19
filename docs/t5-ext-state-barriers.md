# T5 — env-extension state barriers: the census, and the reducibility root cause

Status: root cause identified + core patch applied (iter 53); rebuild/measure
in progress. This is T4's general finding turned into a systematic audit —
and the audit landed on what looks like the mechanism behind the project's
oldest unexplained numbers.

## The audit (bench/t5_barrier_audit.sh)

Sample a *vanilla* compile of the hot module (`Batteries.Data.List.Lemmas`)
at staggered offsets: run `lean` as a gdb child, SIGINT the inferior
mid-flight, dump all thread backtraces (16 samples, `bench/t5_samples/`).
Census of `lean_task_get` blocking sites across all threads:

| blocked in | hits |
|---|---|
| **`EnvExtension.getStateUnsafe` ← `getReducibilityStatusCore` ← `Meta.Sym.isUnfoldReducibleCandidate`** | **49** |
| `SnapshotTask.get` (frontend report loop — benign) | 6 |
| `AsyncConsts.findRec?` | 2 |
| `getState` ← `Match.Extension.getMatcherInfo?` | 1 |

One query dominates everything: grind/sym's unfold-candidate check reading
reducibility state.

## The mechanism

`getReducibilityStatusCore` (`ReducibilityAttrs.lean`) performs two
env-extension reads per call:

1. `reducibilityExtraExt.getState env` — scoped-override map (rare, mostly
   empty), read on **every** call with the extension's default mode;
2. for same-module constants, `reducibilityCoreExt.getState
   (asyncDecl := declName)` — blocks on the queried decl's *branch* until
   that decl's extension state is committed.

Per `EnvExtension.AsyncMode` docs, non-`.local` reads from an async task
block — `.sync` on *all prior environment branches* (`checked`), `.async`
on the producing branch. grind/sym calls `isUnfoldReducibleCandidate`
constantly *inside proof tasks on worker threads*, so proof workers
re-serialize behind the elaboration pipeline on every unfold-candidate
check. This plausibly explains, at last:

- the **"blocked 6.65 s"** line — the largest single category in the original
  hot-module profile (docs/benchmarks.md §1);
- the **2.4× intra-module parallelism plateau** (§2) and the ~34 % "serial
  fraction" the whole campaign has circled — part of it is not a decl
  dependency chain at all, but workers convoying on one extension read.

## The patch (lean4 branch, commit "T5: non-blocking (.local) reducibility-status reads")

Both reads become `asyncMode := .local`. Soundness argument: reducibility
attributes are applied on the **main** elaboration thread before any
dependent proof task is spawned (commands are sequential; `applyAttributes`
runs on main), so the local branch state at task spawn is complete for every
constant a task can legitimately mention. The only divergence would be an
attribute written *inside a concurrent async branch* — which the `.mainOnly`
default of scoped extensions already forbids elsewhere.

Gates before any perf claim (methodology as always): full stage1 rebuild,
Batteries corpus builds clean, ON-vs-ON olean determinism, then 5-run
medians on List.Lemmas (`--threads` sweep — the plateau is the prediction:
if the mechanism is right, the 2.4× ceiling should lift) and cold corpus
wall.

## Why this one might actually move wall clock

Unlike T1–T4, this sits on the *worker* side of the iter-49 frontier: it
doesn't try to parallelize main-thread command elaboration; it stops the
already-parallel proof workers from being throttled back to sequential. The
"blocked" mass (6.65 s cumulative on the hot module) is the budget; any
fraction recovered is critical-path time on the module that gates the
Batteries build.
