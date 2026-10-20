#!/usr/bin/env python3
"""Makespan simulation for a measured nbh-bench run. SIMULATION, not a measurement.

simulate.py RUN_DIR [--cores N] > SIMULATION_JSON

Work per derivation is estimated in core-seconds from the run itself: each CPU
sample's busy cores are split evenly across the builds running at that moment.
Builds the run never finished get an explicit estimate from ESTIMATES. Each
build then runs as Amdahl: serial core-seconds plus a parallel part spread over
the cores it gets, capped by how wide that build can go. A machine shares its
cores evenly among its running builds; a build never spans machines.
"""
import json
import sys

import graph

# Builds killed or never started in the S2 run. ninja progress comes from `nix log`.
ESTIMATES = {
    "kwin-x11-6.7.5": ("same source tree as kwin; ninja reached 370/1623 when killed", "kwin-6.7.5", 1.0),
    "plasma-pa-6.7.5": ("ninja reached 91/131 when killed", None, 131 / 91),
    "print-manager-6.7.5": ("ninja reached 55/117 when killed", None, 117 / 55),
    "niri-26.04": ("rustc killed while compiling the lib test target; observed work is a lower bound", None, 1.0),
    "plasma-desktop-6.7.5": ("never started; guess: as large as plasma-workspace", "plasma-workspace-6.7.5", 1.0),
    "kdeplasma-addons-6.7.5": ("never started; guess: as large as powerdevil", "powerdevil-6.7.5", 1.0),
}

# (serial share of work, extra serial core-seconds, widest a single build goes)
SCENARIOS = {
    "optimistic": (0.03, 15, 128),
    "pessimistic": (0.10, 60, 48),
}
RUST_CAP = 16

# Everything that ran before plasma-workspace finished, so the 1x8 replay can be
# compared with when it finished in the measured run.
CALIBRATION = ("libinput-1.31.3", "kwin-6.7.5", "niri-26.04", "xf86-input-libinput-1.5.0",
               "libinput-gestures-2.79", "plasma-workspace-6.7.5")

MACHINES = {
    "1x8 (the box's shape)": [8],
    "1x64": [64],
    "1x192": [192],
    "8x8 = 64 cores": [8] * 8,
    "24x8 = 192 cores": [8] * 24,
    "3x64 = 192 cores": [64] * 3,
}


def observed_work(run, cores):
    times = json.load(open(f"{run}/times.json"))
    rows = [l.split() for l in open(f"{run}/cpu.tsv").readlines()[1:]]
    samples = [(float(t), float(b)) for t, b in rows]
    work = {k: 0.0 for k in times}
    for (t0, b), (t1, _) in zip(samples, samples[1:]):
        mid = (t0 + t1) / 2
        live = [k for k, v in times.items() if v["start"] <= mid < v["end"]]
        for k in live:
            work[k] += b * cores * (t1 - t0) / len(live)
    return times, work


def duration_fn(work, serial_share, serial_extra, cap, names):
    def parts(n):
        w = work[n]
        s = min(w, serial_share * w + serial_extra)
        c = RUST_CAP if names[n].startswith("niri") else cap
        return s, w - s, c
    return parts


def simulate(g, parts, machines, dt=0.5):
    order, rev = graph.topo(g)
    remaining_deps = {n: len(g[n]) for n in g}
    left = {}
    for n in g:
        s, p, c = parts(n)
        left[n] = [s, p, c]
    ready = sorted((n for n in g if remaining_deps[n] == 0), key=lambda n: -sum(parts(n)[:2]))
    running = [[] for _ in machines]
    t, done = 0.0, 0
    while done < len(g):
        while ready:
            m = min(range(len(machines)), key=lambda i: len(running[i]) / machines[i])
            if running[m] and len(running[m]) >= machines[m]:
                break
            running[m].append(ready.pop(0))
        for i, cores in enumerate(machines):
            for n in list(running[i]):
                s, p, c = left[n]
                share = min(c, cores / len(running[i]))
                if s > 0:
                    left[n][0] = s - dt
                else:
                    left[n][1] = p - share * dt
                if left[n][0] <= 0 and left[n][1] <= 0:
                    running[i].remove(n)
                    done += 1
                    for r in rev[n]:
                        remaining_deps[r] -= 1
                        if remaining_deps[r] == 0:
                            ready.append(r)
        t += dt
    return t


def main(argv):
    run = argv[1]
    cores = int(argv[argv.index("--cores") + 1]) if "--cores" in argv else 8
    deps, _, names = graph.load_closure(f"{run}/closure.json")
    nodes = {graph.base(l) for l in open(f"{run}/tobuild.txt") if l.strip()}
    g = graph.restrict(deps, nodes)
    by_name = {names[n]: n for n in g}
    times, obs = observed_work(run, cores)
    work, provenance = {}, {}
    for n in g:
        nm = names[n]
        if nm in ESTIMATES:
            why, proxy, scale = ESTIMATES[nm]
            base_w = obs[by_name[proxy]] if proxy else obs.get(n, 0.0)
            work[n] = base_w * scale
            provenance[nm] = f"estimated: {why}"
        else:
            work[n] = obs[n]
            provenance[nm] = "observed in run"
    out = {
        "label": "SIMULATION from one measured run; work is inferred, serial share and caps are guesses",
        "run": run,
        "work_core_s": {names[n]: round(work[n]) for n in sorted(g, key=lambda n: -work[n])},
        "provenance": provenance,
        "total_work_core_s": round(sum(work.values())),
        "makespan_s": {},
    }
    for sc, (share, extra, cap) in SCENARIOS.items():
        parts = duration_fn(work, share, extra, cap, names)
        out["makespan_s"][sc] = {k: round(simulate(g, parts, m)) for k, m in MACHINES.items()}
        out["makespan_s"][sc]["critical_path_floor"] = round(critical_floor(g, parts))
        sub = graph.restrict(deps, {by_name[c] for c in CALIBRATION})
        out.setdefault("calibration_1x8", {"measured_plasma_workspace_end_s": times[by_name["plasma-workspace-6.7.5"]]["end"]})
        out["calibration_1x8"][sc] = round(simulate(sub, duration_fn(obs, share, extra, cap, names), [8]))
    json.dump(out, sys.stdout, indent=1)
    print()


def critical_floor(g, parts):
    order, _ = graph.topo(g)
    fin = {}
    for n in order:
        s, p, c = parts(n)
        fin[n] = max((fin[m] for m in g[n]), default=0.0) + s + p / c
    return max(fin.values())


if __name__ == "__main__":
    main(sys.argv)
