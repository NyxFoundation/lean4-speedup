# lean4-speedup

**Profiling-driven research on making Lean 4 compilation faster on CPU** —
measurements, architecture analysis, and experimental compiler patches with a
verification-first methodology.

This repository documents an ongoing investigation into where Lean 4
compilation time actually goes and prototypes optimizations against a fork of
[leanprover/lean4](https://github.com/leanprover/lean4). Every claim is backed
by a benchmark in [`bench/`](bench/), and every optimization ships with a
soundness probe, a determinism check, and an honest account of where it does
*not* help.

## Key results so far

| Finding | Evidence |
|---|---|
| **91 % of typeclass derivations in a hot proof-heavy module are duplicates** — Lean's Meta caches are per-command and wiped on every `addDecl` | [docs/benchmarks.md §3](docs/benchmarks.md) |
| **Cross-command instance cache with pointer-identity invalidation** (experimental patch): 24× on synthetic duplicates, −47 % typeclass CPU on the hot module, sound (mutation probes), deterministic, with proven record-and-replay revalidation (v2) | [docs/benchmarks.md §4-7](docs/benchmarks.md), [patches/](patches/) |
| **System-level finding**: typeclass work rides worker threads in async-era Lean, so the cache's CPU savings (−1 % corpus) don't move single-module wall time — the critical path is the main thread | [docs/benchmarks.md §7](docs/benchmarks.md) |
| **The main thread is the critical path** (~80 % occupied while workers idle); async elaboration currently admits only single mvar-free `theorem`s | [docs/benchmarks.md §5](docs/benchmarks.md) |
| **Async kernel processing for inductives** (experimental patch, module system included): capability sound at corpus scale; performance verdict **null** on Batteries — the motivating "sync kernel" signal proved to be queue-wait, and the honest measurement story (incl. a retraction) is documented | [docs/benchmarks.md §8](docs/benchmarks.md), [docs/t2c-async-inductives.md](docs/t2c-async-inductives.md) |
| Intra-module parallelism plateaus at ~2.4× regardless of cores (Amdahl serial fraction ≈ 40 %) | [docs/benchmarks.md §2](docs/benchmarks.md) |
| **Synthesis — the wall-clock lever is located**: the build is critical-path-bound (10.0 s path vs 8.1 s 16-core floor); the path runs through proof-heavy modules that cap at ~2.9/16 cores. The lever is their intra-module serial decl-dependency fraction — what all three async tracks correctly targeted | [docs/benchmarks.md §9](docs/benchmarks.md) |

## The experimental patch: a global synthInstance cache

Lean re-derives typeclass instances from scratch for every declaration. The
patch (branch `speedup/global-synth-cache`, exported in [`patches/`](patches/))
adds a process-lifetime cache with two novel ingredients:

1. **Pointer-identity invalidation** — a cache entry is stamped with the
   instance-table / default-instance / reducibility extension state *objects*.
   Since the environment only grows and unrelated declarations never touch
   those objects, pointer equality is an O(1), sound, and precise witness that
   a cached derivation is still valid.
2. **Context-shape keys** — goals under binders (`BEq α`, …) are keyed by the
   alpha-normalized telescope of (goal, local instances), so isomorphic
   contexts across hundreds of lemmas share one entry; results are stored as
   closed lambdas and re-applied to the target context.

Both are gated behind options (`synthInstance.globalCache`,
`synthInstance.globalCache.shape`) for A/B measurement.

## Architecture notes

The measured pipeline (with a 3D model of the compiler grounded in the Lean 4
thesis and system paper, built with
[visually-3d](https://github.com/grandchildrice/visually-3d)):

![Lean 4 compiler pipeline, 3D contact sheet](docs/assets/scene-lean4-compiler.png)

See [docs/architecture.md](docs/architecture.md) for the pipeline diagram,
zoning, and source map.

## Reproducing

```bash
# 1. Toolchain: apply patches/ to leanprover/lean4 @ 4f53dd7, then
cd lean4 && nix develop --command bash -c "cmake --preset release && make -C build/release -j14"
elan toolchain link speedup-stage1 lean4/build/release/stage1

# 2. Corpus: Batteries pinned to the toolchain, then e.g.
cd batteries && lake env lean --profile Batteries/Data/List/Lemmas.lean

# 3. A/B the cache:
lake env lean -DsynthInstance.globalCache=false --profile Batteries/Data/List/Lemmas.lean

# 4. Count duplicate derivations:
lake env lean -Dtrace.Meta.synthInstance.cache=true Batteries/Data/List/Lemmas.lean \
  | grep -oE '\] (new|cached|global|shape): ' | sort | uniq -c
```

Full methodology and raw numbers: [docs/benchmarks.md](docs/benchmarks.md).

## Repository layout

| path | contents |
|---|---|
| [`docs/`](docs/) | benchmark reports with charts, architecture notes, design documents |
| [`patches/`](patches/) | the experimental commits against lean4 `4f53dd7` |
| [`bench/`](bench/) | benchmark sources, probes, and raw logs |
| [`PLAN.md`](PLAN.md) | research journal: track portfolio and per-iteration log |

## Roadmap

- **v2 cache**: per-class version stamps + touched-class sets, extending the
  win to instance-defining modules (red/green-style invalidation).
- **Async inductives**: move kernel processing of `inductive`/`structure` off
  the critical path ([design](docs/t2c-async-inductives.md); blocked on
  multi-constant async commits in the environment framework).
- **Demand-driven async `def` bodies**: widen the theorem-only async
  elaboration gate.
- Universe-parameter renormalization so cache reuse produces byte-identical
  `.olean`s (currently a stable alternate normal form).

## Status & caveats

This is research code, not a production toolchain. The patches are
experiments: options default to on in the fork for measurement convenience,
but known gaps (unification-hint stamping, universe-name-sensitive shape keys)
are documented in the patch headers and design docs. Nothing here has been
proposed upstream yet.

## License

Documentation and research notes: CC-BY-4.0. Patches to Lean 4 follow Lean's
Apache-2.0. Benchmarks build on
[Batteries](https://github.com/leanprover-community/batteries) and
[Mathlib](https://github.com/leanprover-community/mathlib4) (Apache-2.0).
