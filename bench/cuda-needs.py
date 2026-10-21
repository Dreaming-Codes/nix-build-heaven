#!/usr/bin/env python3
"""Derivations of a toplevel that neither trusted cache serves, and which of those depend on CUDA.

Usage: cuda-needs.py <toplevel.drv> <out.json>
Never builds. Reads the derivation graph and narinfo files only.
"""
import json, re, subprocess, sys, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

CACHES = ["https://install.determinate.systems", "https://cache.nixos.org"]
CUDA = re.compile(r"^(cuda\d+(\.\d+)*-|cudnn|libcu(blas|fft|rand|solver|sparse|file|pti)|libnpp|libnvjpeg|nccl|cutensor|tensorrt|cuda_)")


def served(h):
    for url in CACHES:
        for _ in range(4):
            try:
                with urllib.request.urlopen(f"{url}/{h}.narinfo", timeout=30):
                    return True
            except urllib.error.HTTPError as e:
                if e.code in (404, 403, 410):
                    break
            except OSError:
                continue
    return False


def name(p):
    return re.sub(r"^(/nix/store/)?[a-z0-9]{32}-", "", p).removesuffix(".drv")


def main():
    top, out = sys.argv[1], sys.argv[2]
    g = json.loads(subprocess.run(["nix", "derivation", "show", "-r", top], check=True,
                                  capture_output=True, text=True).stdout)
    g = g.get("derivations", g)
    g = {k.removeprefix("/nix/store/"): v for k, v in g.items()}
    fods = [d for d, v in g.items() if any("path" not in o for o in v["outputs"].values())]
    fod_out = {}
    for i in range(0, len(fods), 500):
        chunk = fods[i:i + 500]
        paths = subprocess.run(["nix-store", "-q", "--outputs"] + ["/nix/store/" + d for d in chunk],
                               check=True, capture_output=True, text=True).stdout.split()
        fod_out.update(zip(chunk, paths))
    outs = {d: [fod_out[d].removeprefix("/nix/store/")[:32]] if d in fod_out else
            [o["path"].removeprefix("/nix/store/")[:32] for o in v["outputs"].values()] for d, v in g.items()}
    with ThreadPoolExecutor(64) as ex:
        hs = sorted({h for v in outs.values() for h in v})
        have = dict(zip(hs, ex.map(served, hs)))
    deps = {d: list((v.get("inputs", {}).get("drvs") or v.get("inputDrvs") or {}).keys()) for d, v in g.items()}
    need, stack = set(), [top.removeprefix("/nix/store/")]
    while stack:
        d = stack.pop()
        if d in need or all(have[h] for h in outs[d]):
            continue
        need.add(d)
        stack.extend(deps[d])
    memo = {}

    def tainted(d):
        if d not in memo:
            memo[d] = False
            memo[d] = bool(CUDA.match(name(d))) or any(tainted(x) for x in deps[d])
        return memo[d]

    sys.setrecursionlimit(100000)
    fod = set(fods)

    def local(d):
        v = g[d]
        attrs = v.get("structuredAttrs") or v.get("env", {})
        return str(attrs.get("preferLocalBuild", "")).lower() in ("1", "true")
    cuda = sorted(d for d in need if tainted(d))
    res = {"toplevel": top, "need": len(need), "need_fod": len(fod & need),
           "cuda": [name(d) for d in cuda], "cuda_drvs": cuda,
           "cuda_fod": sorted(name(d) for d in cuda if d in fod),
           "cuda_local": sorted(name(d) for d in cuda if d not in fod and local(d)),
           "cuda_compile": sorted(name(d) for d in cuda if d not in fod and not local(d)),
           "non_cuda": sorted(name(d) for d in need - set(cuda))}
    json.dump(res, open(out, "w"), indent=1)
    print(top, "need", len(need), "cuda", len(cuda), "cuda_fod", len(res["cuda_fod"]))


main()
