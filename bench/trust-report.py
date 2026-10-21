#!/usr/bin/env python3
"""Summarise trust-split.py output per substituter for one or more hosts.

Usage: trust-report.py <trust-host.json>... > report.json
"""
import json
import re
import sys
from collections import defaultdict

TRUSTED = {"determinate", "nixos"}
MB = 1e6


def pname(p):
    n = p.split("-", 1)[1]
    return re.sub(r"-[0-9][^-]*.*$", "", n) or n


def main():
    union_win, union_extra, per_host = defaultdict(dict), {}, {}
    for f in sys.argv[1:]:
        d = json.load(open(f))
        host = re.search(r"nixos-system-([A-Za-z]+)", d["top"]).group(1)
        names = d["names"]
        win = defaultdict(list)
        shadowed = defaultdict(int)
        for h, v in d["full"]["substituted"].items():
            cs = v["caches"]
            if not cs:
                continue
            win[cs[0]].append(h)
            if cs[0] in TRUSTED:
                for c in cs[1:]:
                    if c not in TRUSTED:
                        shadowed[c] += 1
        base = set(d["baseline_built"])
        extra = {p: v["caches"] for p, v in d["trusted"]["built"].items() if p not in base}
        ni = d["narinfo"]
        h_out = {"winner_counts": {c: len(v) for c, v in win.items()},
                 "winner_file_mb": {c: round(sum(d["full"]["substituted"][h]["file"] for h in v) / MB, 1)
                                    for c, v in win.items()},
                 "risky_also_on_trusted_but_trusted_wins": dict(shadowed),
                 "baseline_builds": len(base), "trusted_only_builds": len(d["trusted"]["built"]),
                 "extra_builds_vs_baseline": len(extra)}
        for c, hs in win.items():
            if c in TRUSTED:
                continue
            for h in hs:
                p = names.get(h, h)
                union_win[c][h] = (p, d["full"]["substituted"][h]["file"], d["full"]["substituted"][h]["nar"])
        for p, cs in extra.items():
            h = p.split("-", 1)[0]
            src = [c for c in cs if c not in TRUSTED]
            size = ni.get(h, {}).get(src[0], {}).get("file") if src else None
            union_extra[p] = {"caches": src, "file": size, "runtime": h in d["full"]["substituted"],
                              "host": union_extra.get(p, {}).get("host", []) + [host]}
        per_host[host] = h_out
    out = {"per_host": per_host, "risky_winners": {}, "extra": {}}
    for c, m in union_win.items():
        groups = defaultdict(lambda: [0, 0])
        for p, fsz, _ in m.values():
            groups[pname(p)][0] += 1
            groups[pname(p)][1] += fsz
        out["risky_winners"][c] = {"paths": len(m), "file_mb": round(sum(x[1] for x in m.values()) / MB, 1),
                                   "nar_mb": round(sum(x[2] for x in m.values()) / MB, 1),
                                   "by_name": sorted(([k, v[0], round(v[1] / MB, 1)] for k, v in groups.items()),
                                                     key=lambda x: -x[2])}
    by_src = defaultdict(lambda: [0, 0, 0])
    for p, v in union_extra.items():
        k = (v["caches"][0] if v["caches"] else "none") + ("/runtime" if v["runtime"] else "/build-only")
        by_src[k][0] += 1
        by_src[k][1] += v["file"] or 0
        by_src[k][2] += v["file"] is None
    out["extra"] = {"paths": len(union_extra), "by_first_risky_source": {
        k: {"paths": a, "file_mb": round(b / MB, 1), "unsized": n} for k, (a, b, n) in by_src.items()},
        "list": sorted(([p, v["caches"], round((v["file"] or 0) / MB, 1), v["runtime"], v["host"]]
                        for p, v in union_extra.items()), key=lambda x: -x[2])}
    json.dump(out, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
