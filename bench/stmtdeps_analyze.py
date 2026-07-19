#!/usr/bin/env python3
"""Command-independence phenomenon analysis (protocol v2 step 2).

Input: jsonl from StmtDeps_*.lean — per user-facing decl: line, same-module
statement (type) deps `sd`, body-only deps `bd`.
Command order ~ line order. For each decl we compute the distance (in
commands) to its nearest earlier statement dep. The speculation window for
command-level parallelism = how many immediately-preceding commands a
statement does NOT read.
"""
import json, sys, collections

def load(path):
    decls = [json.loads(l) for l in open(path)]
    decls.sort(key=lambda d: d["l"])
    idx = {d["n"]: i for i, d in enumerate(decls)}
    return decls, idx

def analyze(path, label):
    decls, idx = load(path)
    n = len(decls)
    print(f"== {label}: {n} decls (command order = line order)")
    mindist_s, mindist_b = [], []
    no_stmt_dep = 0
    import_only = 0
    for i, d in enumerate(decls):
        sdists = [i - idx[u] for u in d["sd"] if u in idx and idx[u] < i]
        bdists = [i - idx[u] for u in d["bd"] if u in idx and idx[u] < i]
        if not d["sd"]:
            no_stmt_dep += 1
            if not d["bd"]:
                import_only += 1
        mindist_s.append(min(sdists) if sdists else None)
        mindist_b.append(min(bdists) if bdists else None)
    live_s = [x for x in mindist_s if x is not None]
    print(f"  statements with ZERO same-module type deps: {no_stmt_dep}/{n} = {100*no_stmt_dep/n:.0f}%")
    print(f"  decls fully import-only (stmt+body):        {import_only}/{n} = {100*import_only/n:.0f}%")
    for W in (1, 2, 4, 8, 16, 32):
        free = sum(1 for x in mindist_s if x is None or x > W)
        print(f"  stmt reads nothing from previous {W:>2} commands: {free}/{n} = {100*free/n:.0f}%")
    if live_s:
        live_s.sort()
        med = live_s[len(live_s)//2]
        print(f"  among decls WITH a stmt dep: min-dist median {med}, "
              f"p10 {live_s[len(live_s)//10]}, p90 {live_s[9*len(live_s)//10]}")
    # longest chain restricted to statement deps (the true sequential floor
    # if bodies and independent statements were all off the main path)
    depth = {}
    for i, d in enumerate(decls):
        ds = [depth.get(u, 0) for u in d["sd"] if u in idx and idx[u] < i]
        depth[d["n"]] = 1 + max(ds, default=0)
    full_depth = {}
    for i, d in enumerate(decls):
        ds = [full_depth.get(u, 0) for u in d["sd"] + d["bd"] if u in idx and idx[u] < i]
        full_depth[d["n"]] = 1 + max(ds, default=0)
    print(f"  longest STATEMENT-dep chain: {max(depth.values())} "
          f"(vs full-dep chain {max(full_depth.values())}, vs {n} sequential commands)")
    return decls, idx

if __name__ == "__main__":
    analyze("bench/list_lemmas_stmtdeps.jsonl", "Batteries.Data.List.Lemmas")
    print()
    analyze("bench/equiv_basic_stmtdeps.jsonl", "Mathlib.Algebra.Module.Equiv.Basic")
