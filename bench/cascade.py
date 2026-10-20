#!/usr/bin/env python3
"""cascade.py CLOSURE_JSON NAME_REGEX... : for each matching derivation, the
unit-weight structure of the rebuild a cache-busting change to it would cause
in the closure (the derivation plus every non-fetch dependent)."""
import json
import re
import sys

import graph

deps, fod, names = graph.load_closure(sys.argv[1])
rev = {}
for n, ds in deps.items():
    for m in ds:
        rev.setdefault(m, set()).add(n)
out = {}
for rx in sys.argv[2:]:
    for root in sorted(k for k in deps if re.search(rx, names[k]) and k not in fod):
        seen, stack = {root}, [root]
        while stack:
            for r in rev.get(stack.pop(), ()):
                if r not in seen and r not in fod:
                    seen.add(r)
                    stack.append(r)
        res = graph.analyse(graph.restrict(deps, seen), lambda n: 1.0, names, procs=(8, 64, 192))
        res.pop("critical_path")
        out[names[root] + " " + root[:8]] = res
json.dump(out, sys.stdout, indent=1)
print()
