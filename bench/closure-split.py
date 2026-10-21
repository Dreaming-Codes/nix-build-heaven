#!/usr/bin/env python3
"""Split a NixOS toplevel into outputs public caches already have and outputs we must build and store.

Usage: closure-split.py <toplevel.drv> <out.json>
Reads the derivation graph with `nix derivation show -r`, never builds.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UPSTREAMS = [
    "https://install.determinate.systems",
    "https://cache.nixos.org",
    "https://nix-community.cachix.org",
    "https://numtide.cachix.org",
    "https://cache.nixos-cuda.org",
]
NARINFO_CACHE = "/tmp/nx/narinfo-cache.json"


def load_cache():
    try:
        return json.load(open(NARINFO_CACHE))
    except FileNotFoundError:
        return {}


def fetch(h):
    for u in UPSTREAMS:
        for attempt in range(3):
            try:
                with urllib.request.urlopen(f"{u}/{h}.narinfo", timeout=20) as r:
                    f = dict(l.split(": ", 1) for l in r.read().decode().splitlines() if ": " in l)
                    return h, {
                        "cache": u,
                        "nar": int(f.get("NarSize", 0)),
                        "file": int(f.get("FileSize", 0) or 0),
                        "refs": [x.split("-", 1)[0] for x in f.get("References", "").split()],
                    }
            except urllib.error.HTTPError as e:
                if e.code in (404, 403):
                    break
            except OSError:
                continue
    return h, None


def lookup(cache, hashes):
    todo = [h for h in set(hashes) if h not in cache]
    with ThreadPoolExecutor(48) as ex:
        for h, info in ex.map(fetch, todo):
            cache[h] = info
    return cache


def fod_paths(drvs):
    out = {}
    drvs = sorted(drvs)
    for i in range(0, len(drvs), 500):
        batch = drvs[i : i + 500]
        res = subprocess.run(["nix-store", "-q", "--outputs"] + [f"/nix/store/{d}" for d in batch],
                             check=True, capture_output=True, text=True).stdout.split()
        assert len(res) == len(batch), "a fixed-output derivation has exactly one output"
        for d, p in zip(batch, res):
            out[d] = p.removeprefix("/nix/store/")
    return out


def main():
    top, out_file = sys.argv[1], sys.argv[2]
    graph = json.loads(subprocess.run(["nix", "derivation", "show", "-r", top], check=True,
                                      capture_output=True, text=True).stdout)["derivations"]
    fods = fod_paths([d for d, v in graph.items() if any("path" not in o for o in v["outputs"].values())])

    def path_of(d, o):
        return graph[d]["outputs"][o].get("path") or fods[d]

    cache = load_cache()
    upstream, built, seen = {}, {}, set()
    level = [(top.removeprefix("/nix/store/"), ("out",))]
    while level:
        level = [x for x in set(level) if x not in seen]
        seen.update(level)
        lookup(cache, [path_of(d, o).split("-", 1)[0] for d, outs in level for o in outs])
        nxt = []
        for d, outs in level:
            paths = [path_of(d, o) for o in outs]
            if all(cache.get(p.split("-", 1)[0]) for p in paths):
                for p in paths:
                    upstream[p] = cache[p.split("-", 1)[0]]
                continue
            for o, x in graph[d]["outputs"].items():
                built[path_of(d, o)] = {"drv": d, "fod": "path" not in x}
            for dep, spec in graph[d]["inputs"]["drvs"].items():
                nxt.append((dep, tuple(sorted(spec["outputs"]))))
        level = nxt

    # Upper bound on what a host fetches from public caches at runtime: the
    # reference closure of every upstream path a built derivation consumes.
    closure, frontier = set(), [p.split("-", 1)[0] for p in upstream]
    while frontier:
        lookup(cache, frontier)
        nxt = []
        for h in frontier:
            if h in closure or not cache.get(h):
                continue
            closure.add(h)
            nxt.extend(r for r in cache[h]["refs"] if r not in closure)
        frontier = nxt

    json.dump(cache, open(NARINFO_CACHE, "w"))
    json.dump({
        "top": top,
        "drvs_in_graph": len(graph),
        "upstream": {p: {k: v[k] for k in ("cache", "nar", "file")} for p, v in upstream.items()},
        "upstream_closure": {h: {k: cache[h][k] for k in ("cache", "nar", "file")} for h in closure},
        "built": built,
    }, open(out_file, "w"), indent=0)
    print(f"{top}: graph {len(graph)} drvs, upstream inputs {len(upstream)}, "
          f"upstream closure {len(closure)}, to build {len(built)}")


if __name__ == "__main__":
    main()
