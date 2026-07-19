#!/usr/bin/env python3
"""Arc-diagram render of the command-order dependency structure (protocol
v2 step 7 — the perceptual channel). x = command index; arcs above the
axis = statement (type) deps, below = body-only (proof) deps. Statement
arcs are the sequential-frontier coupling; body arcs already ride async
workers."""
import json, math, sys

def render(path, out, label):
    decls = [json.loads(l) for l in open(path)]
    decls = [d for d in decls if d["l"] > 0]
    decls.sort(key=lambda d: d["l"])
    idx = {d["n"]: i for i, d in enumerate(decls)}
    n = len(decls)
    W, H, mid = 1600, 640, 320
    x = lambda i: 40 + i * (W - 80) / max(n - 1, 1)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'style="background:#101418;font-family:monospace">']
    parts.append(f'<text x="20" y="28" fill="#dce3ea" font-size="17">{label} — '
                 f'{n} commands; arcs ↑ statement(type) deps, ↓ body(proof) deps</text>')
    parts.append(f'<line x1="30" y1="{mid}" x2="{W-30}" y2="{mid}" stroke="#3a4652" stroke-width="1"/>')
    sa = ba = 0
    for i, d in enumerate(decls):
        for u in d["sd"]:
            if u in idx and idx[u] < i:
                j = idx[u]; sa += 1
                r = (x(i) - x(j)) / 2
                parts.append(f'<path d="M {x(j):.1f} {mid} A {r:.1f} {min(r,260):.1f} 0 0 1 {x(i):.1f} {mid}" '
                             f'fill="none" stroke="#ff9f43" stroke-opacity="0.75" stroke-width="1.3"/>')
        for u in d["bd"]:
            if u in idx and idx[u] < i:
                j = idx[u]; ba += 1
                r = (x(i) - x(j)) / 2
                parts.append(f'<path d="M {x(j):.1f} {mid} A {r:.1f} {min(r,260):.1f} 0 0 0 {x(i):.1f} {mid}" '
                             f'fill="none" stroke="#4aa3df" stroke-opacity="0.4" stroke-width="1"/>')
    for i in range(n):
        parts.append(f'<circle cx="{x(i):.1f}" cy="{mid}" r="1.6" fill="#8b97a3"/>')
    parts.append(f'<text x="20" y="{H-16}" fill="#ff9f43" font-size="14">statement arcs: {sa}</text>')
    parts.append(f'<text x="240" y="{H-16}" fill="#4aa3df" font-size="14">body arcs: {ba}</text>')
    parts.append('</svg>')
    open(out, "w").write("\n".join(parts))
    print(f"{out}: {n} cmds, {sa} stmt arcs, {ba} body arcs")

render("bench/list_lemmas_stmtdeps.jsonl", "docs/assets/arcs-list-lemmas.svg", "Batteries.Data.List.Lemmas")
render("bench/equiv_basic_stmtdeps.jsonl", "docs/assets/arcs-equiv-basic.svg", "Mathlib.Algebra.Module.Equiv.Basic")
