#!/usr/bin/env python3
"""Which store paths of a NixOS toplevel each substituter would serve, under the full cache list and under trusted caches only.

Usage: trust-split.py <toplevel.drv> <out.json>
Never builds. Reads the derivation graph and narinfo files only.
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

CACHES = [
    ("determinate", "https://install.determinate.systems", 20),
    ("nixos", "https://cache.nixos.org", 40),
    ("nix-community", "https://nix-community.cachix.org", 41),
    ("numtide", "https://numtide.cachix.org", 43),
    ("xinux", "https://cache.xinux.uz", 44),
    ("nixos-cuda", "https://cache.nixos-cuda.org", 45),
]
TRUSTED = {"determinate", "nixos"}
STATE = "/tmp/nx/trust-narinfo.json"


def fetch(key):
    name, h = key.split("/")
    url = dict((n, u) for n, u, _ in CACHES)[name]
    for _ in range(4):
        try:
            with urllib.request.urlopen(f"{url}/{h}.narinfo", timeout=30) as r:
                f = dict(l.split(": ", 1) for l in r.read().decode().splitlines() if ": " in l)
                return key, {"nar": int(f.get("NarSize", 0)), "file": int(f.get("FileSize", 0) or 0),
                             "refs": [x.split("-", 1)[0] for x in f.get("References", "").split()],
                             "sig": f.get("Sig", "")}
        except urllib.error.HTTPError as e:
            if e.code in (404, 403, 410):
                return key, None
        except OSError:
            continue
    raise RuntimeError(f"no answer for {key}")


def lookup(state, hashes):
    todo = [f"{n}/{h}" for h in set(hashes) for n, _, _ in CACHES if f"{n}/{h}" not in state]
    with ThreadPoolExecutor(64) as ex:
        for k, v in ex.map(fetch, todo):
            state[k] = v


def have(state, h):
    return [n for n, _, _ in CACHES if state.get(f"{n}/{h}")]


def main():
    top, out_file = sys.argv[1], sys.argv[2]
    graph = json.loads(subprocess.run(["nix", "derivation", "show", "-r", top], check=True,
                                      capture_output=True, text=True).stdout)["derivations"]
    fod = [d for d, v in graph.items() if any("path" not in o for o in v["outputs"].values())]
    fods = {}
    for i in range(0, len(fod), 500):
        b = sorted(fod)[i:i + 500]
        outs = subprocess.run(["nix-store", "-q", "--outputs"] + [f"/nix/store/{d}" for d in b],
                              check=True, capture_output=True, text=True).stdout.split()
        fods.update((d, p.removeprefix("/nix/store/")) for d, p in zip(b, outs))

    def path_of(d, o):
        return graph[d]["outputs"][o].get("path") or fods[d]

    try:
        state = json.load(open(STATE))
    except FileNotFoundError:
        state = {}

    def walk(stop):
        stops, built, seen = {}, {}, set()
        level = [(top.removeprefix("/nix/store/"), ("out",))]
        while level:
            level = [x for x in set(level) if x not in seen]
            seen.update(level)
            lookup(state, [path_of(d, o).split("-", 1)[0] for d, outs in level for o in outs])
            nxt = []
            for d, outs in level:
                paths = [path_of(d, o) for o in outs]
                if all(stop(have(state, p.split("-", 1)[0])) for p in paths):
                    stops.update((p, d) for p in paths)
                    continue
                for o in graph[d]["outputs"]:
                    built[path_of(d, o)] = d
                for dep, spec in graph[d]["inputs"]["drvs"].items():
                    nxt.append((dep, tuple(sorted(spec["outputs"]))))
            level = nxt
        return stops, built

    def closure(roots):
        names = {p.split("-", 1)[0]: p for p in roots}
        seen, frontier = {}, list(names)
        while frontier:
            lookup(state, frontier)
            nxt = []
            for h in frontier:
                if h in seen:
                    continue
                c = have(state, h)
                seen[h] = c
                if c:
                    nxt.extend(r for r in state[f"{c[0]}/{h}"]["refs"] if r not in seen)
            frontier = nxt
        return seen

    def summarise(c):
        return {h: {"caches": cs,
                    "file": state[f"{cs[0]}/{h}"]["file"] if cs else None,
                    "nar": state[f"{cs[0]}/{h}"]["nar"] if cs else None} for h, cs in c.items()}

    full_stops, full_built = walk(bool)
    trusted_stops, trusted_built = walk(lambda cs: bool(TRUSTED & set(cs)))
    _, baseline_built = walk(lambda cs: bool(set(cs) - {"xinux"}))
    names = {}
    for p in list(full_stops) + list(full_built) + list(trusted_stops) + list(trusted_built) + list(baseline_built):
        names[p.split("-", 1)[0]] = p
    full_closure = closure(full_stops)
    json.dump(state, open(STATE, "w"))
    json.dump({
        "top": top,
        "drvs_in_graph": len(graph),
        "names": names,
        "full": {"substituted": summarise(full_closure), "built": full_built},
        "baseline_built": baseline_built,
        "trusted": {"stops": {p.split("-", 1)[0]: p for p in trusted_stops}, "built": {
            p: {"drv": d, "caches": have(state, p.split("-", 1)[0])} for p, d in trusted_built.items()}},
        "narinfo": {h: {n: {k: state[f"{n}/{h}"][k] for k in ("file", "nar", "sig")}
                        for n in have(state, h)} for h in set(names) | set(full_closure)},
    }, open(out_file, "w"))
    print(f"{top}: graph {len(graph)}, full substituted closure {len(full_closure)}, full built {len(full_built)}, "
          f"trusted-only built {len(trusted_built)}, baseline built {len(baseline_built)}")


if __name__ == "__main__":
    main()
