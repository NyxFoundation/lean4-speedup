# T10 upstream package (DRAFT — do not file without explicit user go-ahead)

Prepared 2026-07-20 (iter 79). Target: leanprover/lean4. Patch =
`t6-upstream` branch commits 7730c797 + f5c54485 (squash before filing),
independent of the T6 PR (#14449) — different files, no overlap.

## Suggested split

The patch contains two separable pieces:

1. **`perf: avoid reallocating the environment when kernel diagnostics
   are off`** — the `runCore` resetDiag guard. Zero-risk two-line change,
   valuable standalone (one env allocation + kernel-map op per command).
   Could be filed alone first to establish object-identity semantics.
2. **`perf: cache the elaborated section-variable telescope across
   commands`** — the main patch, depends on (1) for its staleness stamp.

## Issue text (for the main patch)

Title: **`variable` commands re-elaborate the entire accumulated
telescope — quadratic per section, ~22 % of elaboration time on
section-heavy Mathlib modules**

Every command that enters `runTermElabM` re-elaborates all accumulated
section binders (`Term.elabBinders scope.varDecls`, Command.lean), and
`elabVariable`'s sanity check pays the same cost per `variable` command —
so the k-th `variable` command in a section costs O(k), O(k²) per
section.

Repro (any toolchain, `bench/M_t10_scale_k.lean` shape):

```
section
variable {R1 : Type} [Mul R1]
variable {R2 : Type} [Mul R2]
-- ... k times
end
```

Measured per-file wall (median of 5, nightly-2026-07-19 rebuild,
16-core linux): k=64: 266 ms, k=128: 538 ms, k=256: 1648 ms — ×2 input
→ ×3.1–3.8 time. On `Mathlib.Algebra.Module.Equiv.Basic` (82 bare
`variable` commands), trace.profiler shows `variable` command spans
growing 20 → 81 ms within a section and resetting at section
boundaries; 1,306 ms of a 5,969 ms module = 22 %.

## PR text (for the main patch)

Title: `perf: cache the elaborated section-variable telescope across
commands`

This PR adds the option `Elab.varTelescopeCache` (default false). When
enabled, `runTermElabM` caches the elaborated `scope.varDecls` telescope
(term/meta state snapshot, local context, local instances, binder fvars)
in a process-global single entry and reuses it when the next command's
scope is identical; a longer `variable` telescope re-elaborates only the
new suffix binders. This removes the per-section quadratic cost of
`variable` commands: a 256-command `variable` chain drops from 1648 ms to
264 ms, and `Mathlib.Algebra.Module.Equiv.Basic` (heavily sectioned)
drops from 4.91 s to 4.31 s (−12 %) end-to-end.

Staleness is decided without hooks: the entry stores the environment
*object* (unchanged env ⇒ same object, enabled by the `runCore` change
that only calls `Kernel.resetDiag` when diagnostics are enabled) plus the
scope's namespace/open declarations/level names/`noncomputable`/
`public`/`meta` flags and options; any mismatch re-elaborates. Three
hazards discovered during validation are handled explicitly: the name
generator is fast-forwarded past the snapshot's id range on every hit
(elaboration such as instance-name computation runs under state rollback,
which a process-global cache survives — without the fast-forward,
reissued ids collide with ids embedded in the snapshot); error-state
telescopes are never cached; telescopes containing auto-bound section
variables are never cached (auto-bounds live in the reader's
`autoBoundImplicitContext` retry loop, which a state snapshot cannot
restore).

Validation: `variable`-interleaved mutation probes (open/instance/
universe/set_option/binder-annotation-update/auto-bound) produce
byte-identical output with the option on and off; Batteries builds
188/188 modules cleanly with the option enabled; structural comparison
(name, universe params, type, value of every constant via
`readModuleData`) of oleans built with the option on vs off shows zero
differences on the measured Mathlib module.

Known limitation, disclosed: olean *byte* layout under the option can
differ from the option-off build (and rarely across runs) because
restored snapshots physically share expression objects across commands,
which the compacted-region writer preserves; content is proven
structurally identical. Left default-off pending a decision on
byte-reproducibility requirements; the cache also currently misses
whenever any declaration was added since the last store (environment
object stamp), so only `variable`-chain re-elaboration is accelerated —
the per-declaration telescope cost is future work.

## Pre-filing checklist

- [ ] Squash the two commits (or split per §Suggested split) onto
      current master; re-run: probes, k-series, Batteries corpus,
      Equiv.Basic A/B, structural olean diff.
- [ ] `make test` (ctest) on the lean4 tree — NOT yet run (the fork's
      stage1 was only exercised via the project's own gates).
- [ ] Check CI-required style (copyright headers untouched — only
      Command.lean modified).
- [ ] USER GO-AHEAD to file (outward-facing).
