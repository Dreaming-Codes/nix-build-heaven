# kernel-3: kernel-2 over ssh-ng on one EC2 Spot builder, hook mode

Same drv as kernel-2 (`61g9...-linux-cachyos-latest-lto-x86_64-v3-7.2.8.drv`,
nixos branch nbh-drop-xinux-kernel 3708fbf), re-instantiated after the box GC.
Root Determinate nix 3.23.3, `--store local --max-jobs 0
--builders-use-substitutes`, substituters cache.nixos.org and
install.determinate.systems only (no xinux on box or builder). Transport ssh-ng,
gate `-transport ssh-ng` on 127.0.0.1:2222 (hold while booting), no plugin.
AMI ami-046c3f591eca17088. Build log lines carry box arrival times
(`build.log.gz`), so builder-side phases are as seen from the box. Times UTC+2.

| What | ssh-ng (kernel-3) | grpc (kernel-2) | Label |
|---|---|---|---|
| Type, AZ, price | c7i.24xlarge eu-north-1b $0.5499/h, i-015f0f3b3a0fe7640, sir-gjkzm8xg | same type, AZ, price | measured |
| Launch request to RunInstances returned | 1.9 s | 2.1 s | measured |
| Launch request to builder listening | 34.6 s (:22) | 34.5 s (:50051) | measured |
| Launch request to first splice | 34.6 s (same probe, hold mode) | 47.7 s (client reconnect backoff) | measured |
| Copy back of linux-src-patched (1.64 GB NAR, an intermediate output the hook returns) | 94 s, +76.1 to +169.8 s, about 17 MB/s | not separated | measured |
| Inputs until the kernel drv starts | +212 s | +160 s | measured (grpc 10 s sampling) |
| Kernel drv on builder (start to last log line) | 781 s | about 831 s | measured |
| of which buildPhase | 654 s (+249 to +903) | 711 s (+190 to +901) | measured |
| of which installPhase | 72 s | 70 s | measured |
| Copy of the 826 MB outputs back to the box | about 52 s (+1001 to end), about 16 MB/s | about 20 s (fixup plus copy took 40 s at 10 s sampling; fixup is about 19 s here) | ssh-ng measured, grpc inferred |
| Whole session, nix build start to outputs local | 1054 s (17.6 min) | 1011.2 s (16.9 min) | measured |
| Gate terminate after the build ended | 63 s | 58 s | measured |
| Instance running | 1111 s (21:07:00Z to 21:25:31Z) | 1067 s | measured |
| Compute cost | $0.170 | $0.163 | measured price and seconds |
| With EBS 100 GB gp3 and IPv4 | about $0.177 | about $0.170 | inferred, list rates |

Reading: hold mode saves the 13 s reconnect backoff (measured). The builder
compile ran faster this time (one sample each, inferred noise or a different
host). Copies back are slower over ssh-ng: about 16 to 17 MB/s for both big
NARs against roughly 40 MB/s for grpc's output copy (inferred from 10 s
sampling). The net is a session 43 s longer. On a home uplink slower than
16 MB/s the transport would not be the bound (guess, unmeasured).

## Outputs (verify.txt)

The three outputs equal the drv's, deriver 61g9, `nix store verify --no-trust`
reports no error, and the NAR hashes are identical to kernel-2's, which are
identical to cache.xinux.uz's (measured):

- out kxs8... sha256-ZgB4o9anRaqJM8zJIi4s13ge1RwMHoShCAwvEnfdSBg= 25.8 MB
- modules vn1l... sha256-oNIomyUHboo4QEGX0SLXrMn7CGw2LN/Xpzc/FglKl0c= 161.9 MB
- dev z2wk... sha256-ng27DP5d3mQzz2h/W6HqISmoIsoDzlg3bth6q1wtTag= 638.7 MB

## Cleanup (cleanup.txt)

i-015f0f3b3a0fe7640 terminated by the gate (user initiated 21:25:31Z). At
23:54 no non-terminated instance in eu-north-1 or any other region, no
volumes, no addresses, no open or active Spot request; no nbh-gate process on
the box (measured).
