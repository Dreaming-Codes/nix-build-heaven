# kernel-2: DreamingDesk CachyOS LTO kernel on one EC2 Spot builder, hook mode

Drv `/nix/store/61g9nhv4i4ywv34w53aw10z3q20rgy6k-linux-cachyos-latest-lto-x86_64-v3-7.2.8.drv`
from /workspace/nbh/nixos branch nbh-drop-xinux-kernel (3708fbf). Root nix
3.23.3 with the patched plugin, `--store local --max-jobs 0
--builders-use-substitutes`, substituters pinned to cache.nixos.org and
install.determinate.systems (no xinux on box or builder). Times UTC+2.

| What | Value | Label |
|---|---|---|
| Type, AZ | c7i.24xlarge (96 vCPU), eu-north-1b, i-0b3a61000bf36b77d, sir-c1yfnjyk | measured |
| Choice | cheapest live Spot at 21:19:53: c7i 1b $0.5499, c7i 1c $0.6129, c7a 1c $0.7871, m7a 1b $0.9727; max-price $0.80 | measured |
| Spot price paid | $0.5499/h, unchanged 18:00Z to 19:40Z in 1b | measured |
| Launch request to RunInstances returned | 2.1 s | measured |
| Launch request to :50051 listening | 34.5 s (21:19:59.70 to 21:20:34.24) | measured |
| Launch request to first splice | 47.7 s (client gRPC reconnect backoff) | measured |
| Input drvs (tarball fetch, configs, clang-wrapper, stdenv, linux-src-patched) | about 112 s, ending when the kernel drv started at +160 s | measured, 10 s sampling |
| Kernel drv on builder: configure | +160 to +190 s | measured, 10 s |
| buildPhase compile to `LD vmlinux.o` | +190 to +620 s (430 s) | measured, 10 s |
| vmlinux.o link, kallsyms, BTF, then modules | +620 to +901 s (281 s, of which the serial stretch is at least 120 s) | measured, 10 s |
| installPhase (modules_install with xz) | +901 to +971 s (70 s) | measured, 10 s |
| fixup, copy 826 MB back to the box | +971 to +1011 s | measured, 10 s |
| Kernel derivation alone | about 831 s (13.9 min) | measured, 10 s |
| Whole session wall, nix build start to outputs local | 1011.2 s (16.9 min) | measured |
| Gate terminate after build end | 58 s (21:36:50 to 21:37:48) | measured |
| Instance running | 1067 s (19:20:01Z to 19:37:48Z) | measured |
| Cost compute | 1067 s x $0.5499/h = $0.163 | measured |
| Cost EBS 100 GB gp3 + extra 125 MB/s | about $0.005 ($0.0836/GB-month list price) | inferred |
| Cost public IPv4 | $0.0015 ($0.005/h list price) | inferred |
| Cost this run | about $0.170 | inferred from the above |
| Plus kernel-1 (aborted direct mode, 95 s) | about $0.017 | inferred |
| Session total | about $0.19, cap $1 | inferred |
| Uploaded box to builder | 2749 .drv files plus 626 sources (patches, scripts) totalling 1.2 MB; no toolchain output uploaded, the builder substituted it | measured |
| Box disk free | min 3.25 GB during the run | measured |

## Outputs (verify.txt)

All three output paths equal the drv's outputs, deriver is 61g9, `nix store
verify --no-trust` passes, and the NAR hashes are bit-identical to what
cache.xinux.uz serves for the same paths (measured):

- out `/nix/store/kxs8qcaf100xpklda6qwrsv0yvbqsp0g-linux-cachyos-latest-lto-x86_64-v3-7.2.8` sha256-ZgB4o9anRaqJM8zJIi4s13ge1RwMHoShCAwvEnfdSBg= 25.8 MB
- modules `/nix/store/vn1lzz4blxwsj26l0byl36cjyw2g4gkw-linux-cachyos-latest-lto-x86_64-v3-7.2.8-modules` sha256-oNIomyUHboo4QEGX0SLXrMn7CGw2LN/Xpzc/FglKl0c= 161.9 MB
- dev `/nix/store/z2wks294x06bmd6lfa69hcsk0qc13x0n-linux-cachyos-latest-lto-x86_64-v3-7.2.8-dev` sha256-ng27DP5d3mQzz2h/W6HqISmoIsoDzlg3bth6q1wtTag= 638.7 MB

The outputs sit unrooted in the box store.

## Cleanup (cleanup.txt)

Both instances terminated, no non-terminated instance in eu-north-1, no
volumes, no addresses. Right after termination sir-c1yfnjyk still read
`active/fulfilled` (EC2 lag, as in smoke 5).
At 21:39:52 both Spot requests (sir-c1yfnjyk, sir-cfyqmp3k) read `closed,
instance-terminated-by-user` (measured).
