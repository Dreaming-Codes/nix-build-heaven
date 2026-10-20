#!/usr/bin/env python3
"""Kernel build wall time and Spot cost per instance shape.

Inputs and their labels are in INPUTS; rerun after a real EC2 build replaces a guess.
"""
import json

INPUTS = {
    "box_core_s_per_cc": (343 * 6) / 2899,  # measured, -j6 partial on the 8-vCPU Xeon box
    "real_cc_objects": 20406 + 200,         # measured, xinux log, CC lines before vmlinux.o plus late non-.mod.o
    "mod_o_and_links_core_s": 7000,         # guess: 7446 .mod.o, 9751 LD [M] ThinLTO links, BTF [M]
    "serial_s": (240, 300, 460),            # inferred low/mid/high: vmlinux.o ThinLTO, 3 kallsyms links, pahole BTF; high fits xinux 633 s at -j128
    "fixed_s": 390,                         # boot 75 guess, inputs 60 guess, unpack+configure 60, install 106 and fixup 31 measured on xinux, register+copy 60 guess
}

SHAPES = [
    # name, region, vCPU, GiB, spot $/h (DevZero snapshot, Oct 2026), speed per vCPU vs box vCPU (guess)
    ("c7a.24xlarge", "eu-north-1", 96, 192, 0.743, 1.3),
    ("c7i.24xlarge", "eu-north-1", 96, 192, 0.559, 1.0),
    ("c7i.48xlarge", "eu-north-1", 192, 384, 1.108, 1.0),
    ("m7a.48xlarge", "eu-north-1", 192, 768, 1.182, 1.3),
    ("c7a.48xlarge", "eu-north-1", 192, 384, 1.652, 1.3),
    ("c7a.24xlarge", "eu-central-1", 96, 192, 1.901, 1.3),
    ("c7i.48xlarge", "eu-central-1", 192, 384, 2.030, 1.0),
    ("c8a.48xlarge", "eu-central-1", 192, 384, 2.334, 1.7),
    ("box (local)", "-", 8, 15, 0.0, 1.0),
]

i = INPUTS
work = i["box_core_s_per_cc"] * i["real_cc_objects"] + i["mod_o_and_links_core_s"]
rows = []
for name, region, vcpu, gib, price, speed in SHAPES:
    fixed = i["fixed_s"] - (75 if name.startswith("box") else 0)
    walls = [fixed + work / (vcpu * speed) + s for s in i["serial_s"]]
    rows.append({"instance": name, "region": region, "vcpu": vcpu, "gib": gib, "spot_usd_h": price,
                 "wall_min": [round(w / 60, 1) for w in walls],
                 "usd_per_build": [round(w / 3600 * price, 2) for w in walls]})
print(json.dumps({"work_box_core_s": round(work), "inputs": i, "rows": rows}, indent=1))
