#!/usr/bin/env python3
"""Reads nix --log-format internal-json on stdin, writes timestamped events to
OUT/build.jsonl and samples whole-machine CPU busy share to OUT/cpu.tsv."""
import json
import sys
import threading
import time

out = sys.argv[1]
stop = threading.Event()


def cpu_sampler():
    def snap():
        f = list(map(int, open("/proc/stat").readline().split()[1:]))
        return sum(f), f[3] + f[4]
    t0 = time.monotonic()
    with open(f"{out}/cpu.tsv", "w") as f:
        f.write("t\tbusy\n")
        prev = snap()
        while not stop.wait(1.0):
            cur = snap()
            total, idle = cur[0] - prev[0], cur[1] - prev[1]
            f.write(f"{time.monotonic() - t0:.1f}\t{(1 - idle / total) if total else 0:.3f}\n")
            f.flush()
            prev = cur


threading.Thread(target=cpu_sampler, daemon=True).start()
t0 = time.monotonic()
with open(f"{out}/build.jsonl", "w") as f:
    for line in sys.stdin:
        if line.startswith("@nix "):
            try:
                ev = json.loads(line[5:])
            except ValueError:
                continue
            if ev.get("action") not in ("start", "stop"):
                continue
            f.write(json.dumps({"t": round(time.monotonic() - t0, 3), "ev": ev}) + "\n")
stop.set()
