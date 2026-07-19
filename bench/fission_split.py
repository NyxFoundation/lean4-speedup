#!/usr/bin/env python3
"""T3 module fission: split Batteries.Data.List.Lemmas into k independent
fragments at topic-block granularity, guided by the decl dependency DAG
(bench/list_lemmas_dag.jsonl). Fragments have zero cross-fragment deps by
construction (connected components of the block graph, bin-packed by decl
count); a stub Lemmas.lean re-exports all fragments so downstream is unchanged.
"""
import json, collections, sys, pathlib

K = 3
ROOT = pathlib.Path(__file__).resolve().parent.parent / "batteries"
SRC = ROOT / "Batteries/Data/List/Lemmas.lean"
DAG = pathlib.Path(__file__).resolve().parent / "list_lemmas_dag.jsonl"

text = SRC.read_text().splitlines()

# ---- parse blocks -----------------------------------------------------------
# prelude = up to and including `namespace List`
ns_line = next(i for i, l in enumerate(text) if l.strip() == "namespace List")
prelude = text[: ns_line + 1]
marker_lines = [i for i, l in enumerate(text) if l.startswith("/-! ###")]
blocks = []  # (title, start, end) 0-based line ranges, end exclusive
# pre-block: between namespace and first marker (the NeZero instance)
if marker_lines[0] > ns_line + 1:
    blocks.append(("pre", ns_line + 1, marker_lines[0]))
for j, m in enumerate(marker_lines):
    end = marker_lines[j + 1] if j + 1 < len(marker_lines) else len(text)
    blocks.append((text[m].strip(), m, end))

# ---- decl -> block ----------------------------------------------------------
nodes = {}
for line in open(DAG):
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    nodes[d["n"]] = {"l": d["l"], "d": d["d"]}

def pub(n):
    if n.startswith("_private."):
        p = n.split(".0.", 1)
        if len(p) == 2:
            return p[1]
    return n

G = collections.defaultdict(set)
L = {}
for n, v in nodes.items():
    p = pub(n)
    G[p] |= set()
    for dep in v["d"]:
        dp = pub(dep)
        if dp != p:
            G[p].add(dp)
    if v["l"] not in (0, 1000000):
        L[p] = min(L.get(p, 10**9), v["l"])

def block_of_line(ln):  # ln is 1-based
    for bi, (_, s, e) in enumerate(blocks):
        if s <= ln - 1 < e:
            return bi
    return None

decl_block = {n: block_of_line(L[n]) for n in G if n in L}
decl_block = {n: b for n, b in decl_block.items() if b is not None}

# ---- block graph & components ----------------------------------------------
BU = collections.defaultdict(set)
for a in G:
    if a not in decl_block:
        continue
    for b in G[a]:
        if b in decl_block and decl_block[a] != decl_block[b]:
            BU[decl_block[a]].add(decl_block[b])
            BU[decl_block[b]].add(decl_block[a])

seen, comps = set(), []
for bi in range(len(blocks)):
    if bi in seen:
        continue
    stack, comp = [bi], []
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        comp.append(x)
        stack += list(BU[x])
    comps.append(sorted(comp))

wt = collections.Counter(decl_block.values())
def cw(c):
    return sum(wt[b] for b in c) + 1  # +1 so empty blocks still cost something

comps.sort(key=cw, reverse=True)
bins = [[] for _ in range(K)]
bw = [0] * K
for c in comps:
    i = bw.index(min(bw))
    bins[i] += c
    bw[i] += cw(c)
print("fragment decl-weights:", bw, file=sys.stderr)

# ---- emit -------------------------------------------------------------------
# hoist naked top-level `attribute` lines into every fragment's prelude (their
# registrations feed grind/simp in arbitrary other blocks); strip them from the
# blocks so each fragment holds exactly one copy.
attr_lines = [i for i, l in enumerate(text) if l.startswith("attribute ")]
open_option_line = next(i for i, l in enumerate(text) if l.strip() == "open Option")

frag_dir = ROOT / "Batteries/Data/List"
for i, bs in enumerate(bins, 1):
    out = list(prelude)
    out.append("")
    out += [text[j] for j in attr_lines]
    out.append("")
    opened = False
    for bi in sorted(bs):
        _, s, e = blocks[bi]
        # `open Option` at line 1108 scopes everything after it in the original;
        # re-open it before the first block that originally followed it.
        if not opened and s > open_option_line:
            out.append("open Option")
            out.append("")
            opened = True
        out += [text[j] for j in range(s, e) if j not in attr_lines]
    out.append("")
    (frag_dir / f"Lemmas{i}.lean").write_text("\n".join(out) + "\n")
    print(f"Lemmas{i}.lean: {len(bs)} blocks, {sum(wt[b] for b in bs)} decls",
          file=sys.stderr)

stub = []
for l in text:
    stub.append(l)
    if l.strip() == "module":
        break
stub += [
    "",
] + [f"public import Batteries.Data.List.Lemmas{i}" for i in range(1, K + 1)] + [
    "",
]
SRC.write_text("\n".join(stub) + "\n")
print("stub written", file=sys.stderr)
