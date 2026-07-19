#!/usr/bin/env python3
"""C1 kill-or-fund gate: wavefront schedule simulator (iter 76 final).

Inputs: per-command main-thread times (trace.profiler [Elab.command] spans,
bench/equiv_basic_cmdprof.txt, threshold 1ms) + the statement-dep census
DAG (bench/equiv_basic_stmtdeps.jsonl). Model:
- true context writers (variable/open/... WITHOUT `in`) form a sequential
  chain; each command depends on the latest preceding ctx writer;
- `variable ... in <decl>` counts as a decl command (per-decl scope);
- decl commands additionally depend on the commands of their census
  statement deps; @[simps]-generated decls ride their parent's command
  (nearest earlier matched decl within 40 lines);
- proof bodies stay async as today (they are outside [Elab.command] spans).
Caveats (documented in docs/t9-command-independence.md): ambiguous-name
skips and unmatched commands lose census edges (optimistic); repair costs
and commit serialization unmodeled (optimistic); ctx chain fully
sequential (pessimistic).
"""
import json, re, heapq, bisect
from collections import Counter

TRACE = "bench/equiv_basic_cmdprof.txt"
CENSUS = "bench/equiv_basic_stmtdeps.jsonl"
CTX_KINDS = {"variable", "open", "section", "namespace", "end", "set_option",
             "universe", "attribute", "macro", "notation", "syntax", "unif_hint"}
DECL_RE = re.compile(r"\b(theorem|def|instance|abbrev|structure|lemma)\s+(?:_root_\.)?([^\s:({\[⦃]+)")

cmds, cur, accum = [], None, False
for line in open(TRACE):
    m = re.match(r"\[Elab\.command\] \[([0-9.]+)\]\s*\S*\s*(.*)", line)
    if m:
        if cur: cmds.append(cur)
        cur = {"t": float(m.group(1)), "text": m.group(2)}
        accum = True
    elif cur is not None and accum:
        if line.lstrip().startswith("["):
            accum = False
        else:
            cur["text"] += " " + line.strip()
if cur: cmds.append(cur)
for c in cmds:
    dm = DECL_RE.search(c["text"])
    c["name"] = dm.group(2) if dm else None
    first = re.sub(r"^(@\[[^\]]*\]|/--.*?-/|\s)+", "", c["text"]).split(None, 1)
    kw = first[0] if first else "?"
    c["ctx"] = (kw in CTX_KINDS) and not dm

decls = [json.loads(l) for l in open(CENSUS) if json.loads(l)["l"] > 0]
decls.sort(key=lambda d: d["l"])
short2decls = Counter(d["n"].split(".")[-1] for d in decls)
name2cmds = {}
for j, c in enumerate(cmds):
    if c["name"]: name2cmds.setdefault(c["name"], []).append(j)
name2cmd = {}
for d in decls:
    s = d["n"].split(".")[-1]
    js = name2cmds.get(s, [])
    if len(js) == 1 and short2decls[s] == 1:
        name2cmd[d["n"]] = js[0]
ambig = sum(1 for d in decls if d["n"] not in name2cmd and d["n"].split(".")[-1] in name2cmds)
matched_sorted = sorted((d["l"], name2cmd[d["n"]]) for d in decls if d["n"] in name2cmd)
for d in decls:
    if d["n"] in name2cmd: continue
    i = bisect.bisect_right([x[0] for x in matched_sorted], d["l"]) - 1
    if i >= 0 and d["l"] - matched_sorted[i][0] <= 40:
        name2cmd[d["n"]] = matched_sorted[i][1]
direct = len([d for d in decls if d["n"] in name2cmd])
print(f"trace commands: {len(cmds)} (sum {sum(c['t'] for c in cmds)*1000:.0f} ms); "
      f"census decls mapped: {direct}/{len(decls)} (ambiguous-name skips: {ambig})")

n = len(cmds)
preds = [set() for _ in range(n)]
ctxset = {i for i, c in enumerate(cmds) if c["ctx"]}
prev = None
last_before = [None] * n
for i in range(n):
    last_before[i] = prev
    if i in ctxset:
        if prev is not None: preds[i].add(prev)
        prev = i
for i in range(n):
    if i not in ctxset and last_before[i] is not None:
        preds[i].add(last_before[i])
for d in decls:
    if d["n"] not in name2cmd: continue
    i = name2cmd[d["n"]]
    for u in d["sd"]:
        if u in name2cmd and name2cmd[u] < i:
            preds[i].add(name2cmd[u])

seq = sum(c["t"] for c in cmds)
finish = [0.0] * n
for i in range(n):
    finish[i] = max((finish[j] for j in preds[i]), default=0.0) + cmds[i]["t"]
cp = max(finish)

def sched(w):
    indeg = [len(preds[i]) for i in range(n)]
    succs = [[] for _ in range(n)]
    for i in range(n):
        for j in preds[i]: succs[j].append(i)
    ready = [i for i in range(n) if indeg[i] == 0]
    heapq.heapify(ready)
    busy, t, free, done = [], 0.0, w, 0
    while done < n:
        while ready and free > 0:
            i = heapq.heappop(ready)
            heapq.heappush(busy, (t + cmds[i]["t"], i))
            free -= 1
        ft, i = heapq.heappop(busy)
        t, free, done = ft, free + 1, done + 1
        for s in succs[i]:
            indeg[s] -= 1
            if indeg[s] == 0: heapq.heappush(ready, s)
    return t

print(f"\nsequential: {seq*1000:.0f} ms")
print(f"critical path (inf workers): {cp*1000:.0f} ms -> {seq/cp:.1f}x")
for k in (16, 8, 4):
    w = sched(k)
    print(f"{k:>2} workers: {w*1000:.0f} ms -> {seq/w:.1f}x")
ctx_mass = sum(cmds[i]["t"] for i in ctxset)
print(f"\ntrue ctx writers: {len(ctxset)}, chain mass {ctx_mass*1000:.0f} ms")
