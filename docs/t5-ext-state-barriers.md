# T5 — env-extension state barriers: the census, and the reducibility root cause

Status: **measured, perf-null under strict A/B** (iter 54). The audit and
mechanism are real; the fix is sound (corpus clean, olean-determinism
identical) but moves neither the module sweep nor the corpus wall. The
strict same-stage1 baseline also exposed that the historical
`--threads` plateau numbers were stale — see the verdict section. This is
T4's general finding turned into a systematic audit.

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

## Verdict (iter 54): sound, perf-null — and a stale-baseline catch

Gates: corpus clean (188 oleans, rc=0), ON-vs-ON olean hashes **identical**.
Strict A/B — same stage1, patch present vs reverted (`bench/t5_results.txt`,
`bench/t5_base_results.txt`), best-of-3 walls on `List.Lemmas`:

| `--threads` | baseline | patched | benchmarks.md §2 (v4.32, stale) |
|---|---|---|---|
| 1 | 5.31 s | 5.44 s | 7.16 s |
| 2 | 3.14 s | 3.32 s | 4.21 s |
| 4 | 2.15 s | 2.20 s | 3.03 s |
| 8 | 1.72 s | 1.71 s | 2.96 s |
| 16 | 1.69 s | 1.67 s | — |

Cold corpus: 13.38–13.49 s vs 13.38–13.70 s. **Identical within noise.**

Two lessons, both worth the rebuilds:

1. **The convoy is momentary and off the critical path.** The census
   (49 blocked hits) is real, but ~8 threads block *simultaneously* in a few
   short windows and drain as soon as the producing branch commits; the
   module's wall is set by the main thread's sequential feed rate (iter 49),
   which the workers' latency doesn't gate. A blocking census weighted by
   *time × criticality*, not hit count, would have predicted this.
2. **The historical plateau was toolchain-stale.** v4.32's 2.96 s @ 8
   threads is 1.72 s on the current 4.34-pre stage1 — Lean core's own
   parallelism improved ~40 % on this module between releases. The old §2
   numbers must not be compared against current measurements.

The patch stays on the lean4 branch (it is semantically sound and
non-blocking reads are the documented best practice for
parallel-elaboration-facing extensions) but claims no performance benefit;
the installed stage1 remains the unpatched baseline.
