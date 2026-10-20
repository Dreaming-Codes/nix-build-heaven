#!/usr/bin/env python3
"""Derivation-graph parallelism analysis for nbh-bench.

graph.py stats   CLOSURE_JSON [--subset FILE] [--times TIMES_JSON]
graph.py rdeps   CLOSURE_JSON NAME_REGEX
graph.py times   BUILD_LOG_JSONL > TIMES_JSON

CLOSURE_JSON is `nix derivation show -r` output. --subset restricts the graph to
the derivations listed (one store path or basename per line), which is how a
cache-miss set is analysed: only the derivations that will actually build.
"""
import heapq
import json
import re
import sys


def load_closure(path):
    d = json.load(open(path))
    d = d.get("derivations", d)
    deps = {k: set(v["inputs"].get("drvs", {})) for k, v in d.items()}
    fod = {k for k, v in d.items() if any("hash" in o for o in v["outputs"].values())}
    names = {k: v["name"] for k, v in d.items()}
    return deps, fod, names


def base(p):
    return p.strip().rsplit("/", 1)[-1]


def restrict(deps, nodes):
    """Edges between nodes, closing over intermediate nodes outside the set."""
    out = {}
    for n in nodes:
        seen, stack, reach = set(), list(deps.get(n, ())), set()
        while stack:
            m = stack.pop()
            if m in seen:
                continue
            seen.add(m)
            if m in nodes:
                reach.add(m)
            else:
                stack.extend(deps.get(m, ()))
        out[n] = reach
    return out


def topo(g):
    indeg = {n: 0 for n in g}
    rev = {n: [] for n in g}
    for n, ds in g.items():
        for m in ds:
            indeg[n] += 1
            rev[m].append(n)
    order, q = [], [n for n, c in indeg.items() if c == 0]
    while q:
        n = q.pop()
        order.append(n)
        for r in rev[n]:
            indeg[r] -= 1
            if indeg[r] == 0:
                q.append(r)
    assert len(order) == len(g), "cycle"
    return order, rev


def analyse(g, w, names, procs=(1, 8, 16, 32, 64, 96, 192)):
    order, rev = topo(g)
    finish, level, pred = {}, {}, {}
    for n in order:
        best = max(g[n], key=lambda m: finish[m], default=None)
        finish[n] = (finish[best] if best else 0.0) + w(n)
        pred[n] = best
        level[n] = 1 + max((level[m] for m in g[n]), default=0)
    tail = {}
    for n in reversed(order):
        tail[n] = w(n) + max((tail[r] for r in rev[n]), default=0.0)
    end = max(finish, key=finish.get) if finish else None
    path, n = [], end
    while n:
        path.append(n)
        n = pred[n]
    width = {}
    for n, l in level.items():
        width[l] = width.get(l, 0) + 1
    work = sum(w(n) for n in g)
    crit = finish[end] if end else 0.0
    return {
        "derivations": len(g),
        "edges": sum(len(v) for v in g.values()),
        "depth_levels": max(level.values(), default=0),
        "max_level_width": max(width.values(), default=0),
        "total_work_s": round(work, 1),
        "critical_path_s": round(crit, 1),
        "avg_parallelism": round(work / crit, 2) if crit else None,
        "critical_path": [
            {"drv": names.get(p, p), "s": round(w(p), 1)} for p in reversed(path) if w(p) >= 1
        ],
        "simulated_makespan_s": {str(p): round(simulate(g, rev, w, tail, p), 1) for p in procs},
    }


def simulate(g, rev, w, tail, procs):
    """List scheduling, longest remaining path first. Durations are fixed, so this
    ignores that a job given more cores could itself run faster."""
    remaining = {n: len(g[n]) for n in g}
    ready = [(-tail[n], n) for n, c in remaining.items() if c == 0]
    heapq.heapify(ready)
    running, t, free = [], 0.0, procs
    while ready or running:
        while ready and free:
            _, n = heapq.heappop(ready)
            heapq.heappush(running, (t + w(n), n))
            free -= 1
        t, n = heapq.heappop(running)
        free += 1
        for r in rev[n]:
            remaining[r] -= 1
            if remaining[r] == 0:
                heapq.heappush(ready, (-tail[r], r))
    return t


def times(log):
    """Per-derivation build seconds from a timestamped internal-json log."""
    start, out = {}, {}
    for line in open(log):
        rec = json.loads(line)
        ev = rec["ev"]
        if ev.get("action") == "start" and ev.get("type") == 105:
            start[ev["id"]] = (base(ev["fields"][0]), rec["t"])
        elif ev.get("action") == "stop" and ev["id"] in start:
            drv, t0 = start.pop(ev["id"])
            out[drv] = {"start": t0, "end": rec["t"], "s": rec["t"] - t0}
    return out


def main(argv):
    cmd, closure = argv[1], argv[2]
    if cmd == "times":
        json.dump(times(closure), sys.stdout, indent=1)
        return
    deps, fod, names = load_closure(closure)
    if cmd == "rdeps":
        rx = re.compile(argv[3])
        rev = {}
        for n, ds in deps.items():
            for m in ds:
                rev.setdefault(m, set()).add(n)
        for n in sorted(k for k in deps if rx.search(names[k])):
            seen, stack = set(), [n]
            while stack:
                for r in rev.get(stack.pop(), ()):
                    if r not in seen and r not in fod:
                        seen.add(r)
                        stack.append(r)
            print(len(seen), n)
        return
    args = dict(zip(argv[3::2], argv[4::2]))
    if "--subset" in args:
        nodes = {base(l) for l in open(args["--subset"]) if l.strip()}
    else:
        nodes = set(deps) - fod
    g = restrict(deps, nodes)
    if "--times" in args:
        t = json.load(open(args["--times"]))
        missing = [n for n in g if n not in t]
        w = lambda n: t[n]["s"] if n in t else 0.0
        res = analyse(g, w, names)
        res["weights"] = "measured"
        res["unmeasured_derivations"] = len(missing)
        busy = sorted((v["start"], v["end"]) for k, v in t.items() if k in g)
        res["observed_max_concurrent_builds"] = max_overlap(busy)
        if busy:
            res["observed_wall_s"] = round(max(e for _, e in busy) - min(s for s, _ in busy), 1)
    else:
        res = analyse(g, lambda n: 1.0, names, procs=(1, 8, 64, 192))
        res["weights"] = "unit (1 per derivation)"
        res.pop("critical_path")
    json.dump(res, sys.stdout, indent=1)
    print()


def max_overlap(intervals):
    ev = sorted([(s, 1) for s, _ in intervals] + [(e, -1) for _, e in intervals])
    cur = best = 0
    for _, d in ev:
        cur += d
        best = max(best, cur)
    return best


if __name__ == "__main__":
    main(sys.argv)
