#!/usr/bin/env python3
"""Content-Length of the URLs behind fixed-output derivations we would build. Usage: fod-sizes.py <split.json> <derivation-show.json>"""
import json
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

split, graph = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))["derivations"]


def size(item):
    path, drv = item
    sa = graph[drv].get("structuredAttrs") or {}
    urls = sa.get("urls") or ([sa["url"]] if sa.get("url") else [])
    for u in urls:
        try:
            req = urllib.request.Request(u, method="HEAD", headers={"User-Agent": "curl/8"})
            with urllib.request.urlopen(req, timeout=20) as r:
                n = r.headers.get("Content-Length")
                if n:
                    return path, int(n), u
        except OSError:
            continue
    return path, None, (urls[:1] or ["no url (git or builtin fetch)"])[0]


items = [(p, v["drv"]) for p, v in split["built"].items() if v["fod"]]
with ThreadPoolExecutor(16) as ex:
    res = list(ex.map(size, items))
json.dump({p: n for p, n, _ in res}, sys.stdout, indent=0)
for p, n, u in sorted(res, key=lambda r: -(r[1] or 0)):
    print(f"{(n or 0) / 1e6:9.1f} MB  {p[33:]}  {u[:70]}", file=sys.stderr)
