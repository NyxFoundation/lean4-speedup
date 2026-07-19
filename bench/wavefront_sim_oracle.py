#!/usr/bin/env python3
"""Exact wavefront ceiling on ORACLE-true dependencies (iter 83).

Joins bench/c1_oracle_equiv_basic.jsonl (per-command true reads/writes,
info-tree based) with bench/equiv_basic_cmdprof.txt (per-command main-thread
times, >=1ms). Model as wavefront_sim.py: true ctx writers (bare
variable/open/section/... syntax kinds) form a sequential chain; decl
commands wait on the chain + the writer commands of their true reads.
"""
import json, re, heapq

ORACLE = "bench/c1_oracle_equiv_basic.jsonl"
TRACE = "bench/equiv_basic_cmdprof.txt"
CTX_KINDS = {"variable", "open", "section", "namespace", "end", "set_option",
             "universe", "attribute", "macro", "notation", "syntax", "eoi", "moduleDoc"}
DECL_RE = re.compile(r"\b(theorem|def|instance|abbrev|structure|lemma)\s+(?:_root_\.)?([^\s:({\[⦃]+)")

# ---- oracle commands --------------------------------------------------------
orc = [json.loads(l) for l in open(ORACLE)]
for r in orc:
    r["short"] = r["kind"].split(".")[-1]
    r["ctx"] = r["short"] in CTX_KINDS and not r["writes"]

# ---- profile times (parse like wavefront_sim) -------------------------------
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

# ---- join: oracle cmd -> time ----------------------------------------------
# match by written full names ending with the profile-extracted short name,
# scanning both sequences in order (both are file-ordered).
pi = 0
matched_time = 0.0
for r in orc:
    r["t"] = None
    if not r["writes"]:
        continue
    for j in range(pi, len(cmds)):
        nm = cmds[j]["name"]
        if nm and any(w == nm or w.endswith("." + nm) for w in r["writes"]):
            r["t"] = cmds[j]["t"]
            matched_time += cmds[j]["t"]
            pi = j + 1
            break
# ctx writers: match bare 'variable'/'open' etc. by order among unmatched
# profile cmds is fragile; instead assign each ctx command the median bare-
# variable cost bucket from the profile: we instead give unmatched commands
# a small default and report coverage honestly.
total_profile = sum(c["t"] for c in cmds)
# variable-command times: profile text starting with 'variable' and no decl name
var_times = [c["t"] for c in cmds if c["text"].split(None, 1)[:1] == ["variable"] and not c["name"]]
vi = 0
for r in orc:
    if r["t"] is None and r["short"] == "variable" and vi < len(var_times):
        r["t"] = var_times[vi]; matched_time += var_times[vi]; vi += 1
DEFAULT = 0.0005
for r in orc:
    if r["t"] is None:
        r["t"] = DEFAULT
print(f"profile total {total_profile*1000:.0f} ms; matched into oracle commands "
      f"{matched_time*1000:.0f} ms ({100*matched_time/total_profile:.0f}%)")

# ---- DAG: ctx chain + true read edges --------------------------------------
n = len(orc)
writers = {}
for r in orc:
    for w in r["writes"]:
        writers[w] = r["i"]
preds = [set() for _ in range(n)]
prev_ctx = None
for i, r in enumerate(orc):
    if prev_ctx is not None:
        preds[i].add(prev_ctx)
    if r["ctx"]:
        prev_ctx = i
for i, r in enumerate(orc):
    for u in r["reads"]:
        j = writers.get(u)
        if j is not None and j < i:
            preds[i].add(j)

seq = sum(r["t"] for r in orc)
finish = [0.0] * n
for i in range(n):
    finish[i] = max((finish[j] for j in preds[i]), default=0.0) + orc[i]["t"]
cp = max(finish)

def sched(workers):
    indeg = [len(preds[i]) for i in range(n)]
    succs = [[] for _ in range(n)]
    for i in range(n):
        for j in preds[i]: succs[j].append(i)
    ready = [i for i in range(n) if indeg[i] == 0]
    heapq.heapify(ready)
    busy, t, free, done = [], 0.0, workers, 0
    while done < n:
        while ready and free > 0:
            i = heapq.heappop(ready)
            heapq.heappush(busy, (t + orc[i]["t"], i))
            free -= 1
        ft, i = heapq.heappop(busy)
        t, free, done = ft, free + 1, done + 1
        for s in succs[i]:
            indeg[s] -= 1
            if indeg[s] == 0: heapq.heappush(ready, s)
    return t

print(f"sequential: {seq*1000:.0f} ms")
print(f"critical path (oracle-true deps, inf workers): {cp*1000:.0f} ms -> {seq/cp:.1f}x")
for k in (16, 8, 4):
    w = sched(k)
    print(f"{k:>2} workers: {w*1000:.0f} ms -> {seq/w:.1f}x")
