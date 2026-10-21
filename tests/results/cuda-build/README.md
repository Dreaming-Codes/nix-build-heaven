# CUDA build on EC2 for DreamingBlade, cudaCapabilities 8.6

Run 2026-10-21, 04:22 to 05:05 CEST. Account 845087560967, checked with `sts get-caller-identity` for both keys (measured).

Input. nixos branch `nbh-trusted-caches` at 5cc1fb4, Blade toplevel `5rqzdv1k…-nixos-system-DreamingBlade`. `needs-blade-8.6.json` lists the derivations neither trusted cache serves, from `bench/cuda-needs.py`. `targets.txt` holds the 51 CUDA-dependent, non-trivial, non-fixed-output derivations, minus `pam.d`.

Method. `nix copy --derivation` of the targets to the builder, then `nix build` on the builder as `nbh` (`remote-run.sh`). Substituters were overridden to determinate and cache.nixos.org. max-jobs auto (96), cores 32. Outputs stayed on the builder.

Results (measured, `summary.json` from `bench/cuda-build-report.py`):
- Instance i-092bb1e799ca11cdf, c7i.24xlarge Spot in eu-north-1b at $0.5499/h, 96 vCPU, 185 GiB RAM, 100 GB gp3 root.
- Build wall time 2321 s. Instance lifetime 2556 s, launch to terminate.
- 79 derivations built, exit 0, nothing failed. 781 paths substituted, all from cache.nixos.org.
- All 124 target outputs carry no signature, so all were built on the builder and none came from a cache.
- Root disk used went from 2.4 GB to a peak of 33.3 GB, 30.96 GB at the end.
- Critical path is opencv (546 s), then vtk (916 s), then the second opencv (737 s).

Cost (inferred from measured time and list prices). Spot $0.390, gp3 storage and extra throughput $0.013, public IPv4 $0.004 (price from memory). About $0.41 for the run.

Termination. `sweep-before.txt` and `sweep-after.txt` cover all 17 regions. After the run there were 0 instances, 0 volumes and 0 open or active Spot requests (measured, eu-north-1 rechecked after the Spot request closed).
