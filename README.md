# lean4-speedup

Making **compilation of Lean 4 code faster on CPU** — an autonomous
visioned-vibe-coding research loop in the style of
[FoldNTT](https://github.com/NyxFoundation/ntt-fpga-z3): clone the real
implementation, profile it, visualize the architecture in 3D
([visually-3d](https://github.com/grandchildrice/visually-3d)), verify every
claim, and invent optimizations by transferring ideas from other fields
(hardware folding, branch prediction, incremental query graphs).

**Status (2026-07-17): active.** First invention implemented & mechanically
validated: a cross-command typeclass-resolution cache with **pointer-identity
invalidation** (v0: 24× on synthetic, −34 % TC time on the hot module, sound
per mutation probe, deterministic; corpus-level win requires the v1
alpha-normalized *context-shape* key, currently building).

## Layout

| path | what |
|---|---|
| [`PLAN.md`](PLAN.md) | living research journal: track portfolio + per-iteration log |
| [`docs/architecture.md`](docs/architecture.md) | measured compiler architecture, mermaid + 3D model |
| [`docs/benchmarks.md`](docs/benchmarks.md) | all quantitative results with charts |
| [`patches/`](patches/) | the `speedup/global-synth-cache` commits vs lean4 `4f53dd7` |
| [`bench/`](bench/) | benchmark files, probes, raw logs |
| `lean4/`, `batteries/` | working clones (not committed) |

## The idea so far (track T1)

Lean's `synthInstance`/`whnf`/`defEq` caches die at every command boundary, so
the hot Batteries module re-derives **91 %** of its 13,018 instance
resolutions. The environment only *grows*, and unrelated declarations don't
touch the instance tables — so a global cache entry stamped with the
**pointer identity** of the instance/default-instance/reducibility extension
states is valid iff those pointers are unchanged: an O(1), sound, precise
invalidation witness. v1 extends the key to the **alpha-normalized shape** of
(goal, local-instance telescope) so isomorphic contexts (`[BEq α]` in 200
lemmas) share one entry.

Other tracks (parallelism critical path, kernel-check dedup, simp-set reuse,
compile-server imports) are queued in `PLAN.md`.

## License

Research notes: CC-BY-4.0. Patches to lean4 follow lean4's Apache-2.0.
