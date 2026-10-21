#!/usr/bin/env python3
"""Summarise a builder run of the CUDA set from remote-events.log, remote-df.log and remote-*-info.json."""
import collections, json, re, sys

d = sys.argv[1] if len(sys.argv) > 1 else "."
starts, stops, subs = {}, {}, collections.Counter()
for line in open(f"{d}/remote-events.log"):
    t, _, j = line.partition(" @nix ")
    if not j:
        continue
    e = json.loads(j)
    if e["action"] == "start" and e.get("type") == 105:
        starts[e["id"]] = (int(t), re.sub(r"^/nix/store/[a-z0-9]{32}-", "", e["fields"][0])[:-4])
    elif e["action"] == "start" and e.get("type") == 108:
        subs[e["fields"][1]] += 1
    elif e["action"] == "stop":
        stops[e["id"]] = int(t)
t0 = int(open(f"{d}/remote-t-start").read())
t1 = int(open(f"{d}/remote-t-end").read())
builds = sorted(((stops[i] - s, n, s - t0) for i, (s, n) in starts.items()), reverse=True)
df = [tuple(map(int, l.split())) for l in open(f"{d}/remote-df.log") if l.strip()]
outs = json.load(open(f"{d}/remote-outs-info.json"))
outs = outs.values() if isinstance(outs, dict) else outs
sigs = collections.Counter(s.split(":")[0] for o in outs for s in (o or {}).get("signatures", []))
unsigned = sum(1 for o in outs if o and not o.get("signatures"))
clo = json.load(open(f"{d}/remote-closure-info.json"))
clo = clo.values() if isinstance(clo, dict) else clo
res = {
    "total_wall_s": t1 - t0,
    "builds": len(builds),
    "build_wall_s": [{"name": n, "wall_s": w, "started_at_s": s} for w, n, s in builds],
    "substitutions_by_cache": dict(subs),
    "disk_used_bytes": {"before": df[0][1], "peak": max(x[1] for x in df), "after": df[-1][1]},
    "target_outputs": len(list(outs)) if not isinstance(outs, list) else len(outs),
    "target_output_signers": dict(sigs),
    "target_outputs_unsigned_locally_built": unsigned,
    "runtime_closure_nar_bytes": sum((o or {}).get("narSize", 0) for o in clo),
}
json.dump(res, open(f"{d}/summary.json", "w"), indent=1)
print(json.dumps({k: v for k, v in res.items() if k != "build_wall_s"}, indent=1))
for b in res["build_wall_s"][:25]:
    print(f'{b["wall_s"]:6d} s  start +{b["started_at_s"]:5d} s  {b["name"]}')
