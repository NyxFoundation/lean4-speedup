#!/usr/bin/env python3
"""Render docs/assets/t3-fission.svg: fragment packing + A/B wall bars."""
import sys, pathlib

# filled from bench/t3_ab_results.txt by the caller
base_median = float(sys.argv[1])
fiss_median = float(sys.argv[2])

frags = [("Lemmas1", 174, "#8250df"), ("Lemmas2", 61, "#1f6feb"), ("Lemmas3", 59, "#2da44e")]
total = sum(n for _, n, _ in frags)

W, H = 760, 320
s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
     f'font-family="ui-monospace,monospace" font-size="13">',
     f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
     '<text x="20" y="28" font-size="16" font-weight="bold" fill="#1f2328">'
     'T3 module fission: Batteries.Data.List.Lemmas → 3 independent fragments</text>']

# panel 1: the fission cut (decl-count packing)
x0, y0, bw = 20, 70, 500
s.append('<text x="20" y="58" fill="#57606a">294 line-mapped decls, 84 dependency components, zero cross-fragment edges</text>')
x = x0
for name, n, c in frags:
    w = bw * n / total
    s.append(f'<rect x="{x:.0f}" y="{y0}" width="{w:.0f}" height="40" fill="{c}" rx="4"/>')
    s.append(f'<text x="{x + w/2:.0f}" y="{y0+25}" fill="#fff" text-anchor="middle">{name} · {n}</text>')
    x += w + 6
s.append(f'<text x="{x+4:.0f}" y="{y0+25}" fill="#57606a">decls (main-thread weight)</text>')

# panel 2: A/B wall bars
y1 = 170
s.append(f'<text x="20" y="{y1-12}" fill="#57606a">cold `lake build Batteries` wall, 5-run medians, 16 cores</text>')
maxw = max(base_median, fiss_median)
for i, (label, v, c) in enumerate([("baseline", base_median, "#8c959f"),
                                   ("fissioned", fiss_median, "#2da44e")]):
    y = y1 + i * 52
    w = 560 * v / maxw
    s.append(f'<rect x="110" y="{y}" width="{w:.0f}" height="36" fill="{c}" rx="4"/>')
    s.append(f'<text x="100" y="{y+23}" text-anchor="end" fill="#1f2328">{label}</text>')
    s.append(f'<text x="{118+w:.0f}" y="{y+23}" fill="#1f2328">{v:.2f}s</text>')
d = (base_median - fiss_median) / base_median * 100
s.append(f'<text x="110" y="{y1+118}" fill="#1f2328" font-weight="bold">Δ wall: {base_median - fiss_median:+.2f}s ({d:.1f}%)</text>')
s.append('</svg>')

out = pathlib.Path(__file__).resolve().parent.parent / "docs/assets/t3-fission.svg"
out.write_text("\n".join(s) + "\n")
print("wrote", out)
