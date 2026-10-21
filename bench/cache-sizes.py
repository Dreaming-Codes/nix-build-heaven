#!/usr/bin/env python3
"""Per-host and deduped cache sizes from closure-split.py and fod-sizes.py output.

Usage: cache-sizes.py <dir> <old-tag> <new-tag> <cur-tag>
Reads <dir>/split-<tag>-<host>.json, fod-<tag>-<host>.json and g-<tag>-<host>.json.
Size sources per built path, in order: the local store (measured), the Content-Length of a
fixed-output URL (measured), twice the inputs it unpacks (guess), 0.5 MB (guess).
"""
import json
import subprocess
import sys

HOSTS = ["DreamingDesk", "DreamingBlade"]
UNPACK_FACTOR = 2.0
SMALL = 500_000
GB = 1e9


def load(d, tag, host, kind):
    return json.load(open(f"{d}/{kind}-{tag}-{host}.json"))


def local_sizes(paths):
    res = subprocess.run(["nix", "path-info", "--json", "--json-format", "1"] + [f"/nix/store/{p}" for p in paths],
                         capture_output=True, text=True)
    out = {}
    try:
        data = json.loads(res.stdout or "{}")
    except json.JSONDecodeError:
        return out
    items = data.items() if isinstance(data, dict) else ((x["path"], x) for x in data)
    for p, info in items:
        if info and info.get("narSize"):
            out[p.removeprefix("/nix/store/")] = info["narSize"]
    return out


def built_sizes(split, fod, graph):
    built = split["built"]
    measured = local_sizes(list(built))
    ratio = file_ratio(split)
    sizes = {}
    for p, v in built.items():
        if p in measured:
            sizes[p] = dict(nar=measured[p], file=measured[p] * ratio, src="local store")
        elif v["fod"]:
            n = fod.get(p)
            sizes[p] = dict(nar=n or SMALL, file=n or SMALL * ratio, src="url" if n else "guess")
    for p, v in built.items():
        if p in sizes:
            continue
        drv = graph[v["drv"]]
        if p != (drv["outputs"].get("out") or {}).get("path", p):
            sizes[p] = dict(nar=SMALL, file=SMALL * ratio, src="guess")
            continue
        fed = 0
        for dep, spec in drv["inputs"]["drvs"].items():
            dg = graph[dep]
            if all("path" not in o for o in dg["outputs"].values()):
                for q, s in sizes.items():
                    if built.get(q, {}).get("drv") == dep:
                        fed += s["nar"]
        nar = fed * UNPACK_FACTOR if fed > 5_000_000 else SMALL
        sizes[p] = dict(nar=nar, file=nar * ratio, src="guess")
    return sizes


def file_ratio(split):
    uc = split["upstream_closure"].values()
    return sum(v["file"] for v in uc) / sum(v["nar"] for v in uc)


def runtime(p):
    return not (p.endswith("-dev") or p.endswith(".tar.gz") or "vendor-staging" in p or "full.distro" in p
                or p.endswith(".deb") or p.endswith(".AppImage") or p.endswith(".pkg.tar.xz") or p.endswith(".run"))


def summarize(d, tag):
    per_host, union_built, union_up = {}, {}, {}
    for h in HOSTS:
        split, fod, graph = load(d, tag, h, "split"), load(d, tag, h, "fod"), load(d, tag, h, "g")["derivations"]
        sizes = built_sizes(split, fod, graph)
        up = split["upstream_closure"]
        per_host[h] = dict(
            built_paths=len(sizes),
            built_nar=sum(s["nar"] for s in sizes.values()),
            built_file=sum(s["file"] for s in sizes.values()),
            built_measured_nar=sum(s["nar"] for s in sizes.values() if s["src"] != "guess"),
            built_runtime_file=sum(s["file"] for p, s in sizes.items() if runtime(p)),
            upstream_paths=len(up),
            upstream_nar=sum(v["nar"] for v in up.values()),
            upstream_file=sum(v["file"] for v in up.values()),
            file_ratio=file_ratio(split),
        )
        union_built.update(sizes)
        union_up.update(up)
    return per_host, union_built, union_up


def gb(x):
    return round(x / GB, 2)


def main():
    d, old, new, cur = sys.argv[1:5]
    report = {}
    for tag in (cur, old, new):
        per_host, ub, uu = summarize(d, tag)
        report[tag] = dict(
            per_host={h: {k: (gb(v) if "nar" in k or "file" in k and k != "file_ratio" else round(v, 3)) for k, v in x.items()}
                      for h, x in per_host.items()},
            both_hosts=dict(built_paths=len(ub), built_nar_gb=gb(sum(s["nar"] for s in ub.values())),
                            built_file_gb=gb(sum(s["file"] for s in ub.values())),
                            upstream_paths=len(uu), upstream_nar_gb=gb(sum(v["nar"] for v in uu.values())),
                            upstream_file_gb=gb(sum(v["file"] for v in uu.values()))),
        )
        report[tag]["_sets"] = (ub, uu)
    ob, ou = report[old].pop("_sets")
    nb, nu = report[new].pop("_sets")
    report[cur].pop("_sets")
    new_built = {p: s for p, s in nb.items() if p not in ob}
    new_up = {h: v for h, v in nu.items() if h not in ou}
    per_host_new_runtime = {}
    for h in HOSTS:
        hs = set(load(d, new, h, "split")["built"])
        per_host_new_runtime[h] = gb(sum(s["file"] for p, s in new_built.items() if p in hs and runtime(p)))
    report["weekly_delta"] = dict(
        built_paths=len(new_built), built_nar_gb=gb(sum(s["nar"] for s in new_built.values())),
        built_file_gb=gb(sum(s["file"] for s in new_built.values())),
        built_file_measured_gb=gb(sum(s["file"] for s in new_built.values() if s["src"] != "guess")),
        upstream_paths=len(new_up), upstream_nar_gb=gb(sum(v["nar"] for v in new_up.values())),
        upstream_file_gb=gb(sum(v["file"] for v in new_up.values())),
        machine_pull_built_runtime_file_gb=per_host_new_runtime,
        top_new_built=[(p[33:], gb(s["file"]), s["src"]) for p, s in sorted(new_built.items(), key=lambda x: -x[1]["file"])[:15]],
    )
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
