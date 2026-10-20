#!/usr/bin/env python3
"""Per-build cost across clouds. Same model as kernel-estimate.py.
work units are box-vCPU-seconds (measured). Per-core factors are GUESSES (see notes)."""
WORK=21628; SERIAL=(240,300,460); FIXED=390  # from kernel-estimate.py
# name, $/h, billed minimum seconds (0=per-second), units (cores*factor), serial slowdown, extra boot s
C=[
 ("AWS c7a.24xlarge eu-north-1 (DevZero, prior)",0.743,60, 96*1.3,1.0,0),
 ("AWS c7a.24xlarge eu-north-1 (spot feed)",0.9273,60, 96*1.3,1.0,0),
 ("AWS m7a.24xlarge eu-north-1 (spot feed)",0.7957,60, 96*1.3,1.0,0),
 ("AWS c7i.24xlarge eu-north-1 (spot feed)",0.8463,60, 96*1.0,1.0,0),
 ("GCP c3d-highcpu-180 europe-west1",2.189,60, 90*1.45,1.0,0),
 ("GCP c2d-highcpu-112 europe-west1",0.615,60, 56*1.07,1.2,0),
 ("GCP t2d-standard-60 europe-southwest1",0.438,60, 60*0.86,1.2,0),
 ("GCP c4-highcpu-96 europe-west9",0.732,60, 96*1.1,1.0,0),
 ("GCP c4-highcpu-192 europe-west9",1.463,60, 192*1.1,1.0,0),
 ("Azure D96als_v6 swedencentral",0.763,60, 48*1.5,1.0,60),
 ("Azure F64als_v6 swedencentral",0.766,60, 64*1.3,1.0,60),
 ("OCI E5.Flex 48 OCPU/96GB preempt",(48*0.03+96*0.002)/2,60, 48*1.5,1.0,90),
 ("OCI E5.Flex 94 OCPU/188GB preempt",(94*0.03+188*0.002)/2,60, 94*1.5,1.0,90),
 ("Hetzner CCX63 (EUR, hourly)",1.3686,3600, 48*0.8,1.0,0),
]
for n,p,minb,u,sf,boot in C:
    w=[FIXED+boot+WORK/u+s*sf for s in SERIAL]
    cost=[max(x,minb)/3600*p for x in w]
    print(f"{n:45s} ${p:.3f}/h units={u:5.0f} wall={w[0]/60:4.1f}-{w[1]/60:4.1f}-{w[2]/60:4.1f}min cost={cost[0]:.2f}-{cost[1]:.2f}-{cost[2]:.2f}")
