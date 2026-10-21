# Substituter trust review

Status: analysis only. Nothing deployed. No change to the nixos repo.

Question, in Lorenzo's words: "Ideally we keep only trusted caches". He trusts install.determinate.systems and cache.nixos.org and does not trust cache.xinux.uz. This file judges nix-community.cachix.org, numtide.cachix.org and cache.nixos-cuda.org, measures what each one actually serves to DreamingDesk and DreamingBlade, and prices dropping them.

Who notices. Both hosts stop accepting binaries signed by keys he has no reason to trust. DreamingBlade pays for that with CUDA builds on our Spot builders, or with dropping global `cudaSupport`. The next maintainer inherits two trusted keys plus our own cache key, instead of six.

Labels. (measured) means seen this session. (read) means taken from a source listed at the end. (inferred) follows from those. (guess) is a prediction.

## Why every trusted key is a global key

Nix keeps one set of trusted public keys. `getDefaultPublicKeys()` builds it from `trusted-public-keys` and `secret-key-files`, and `LocalStore::pathInfoIsUntrusted` checks every substituted path against that one set (read, `src/libstore/keys.cc` and `src/libstore/local-store.cc` at NixOS/nix 79b6d5b). There is no per-substituter key binding and no per-cache path scoping (read, same files). So a key from any cache can sign any store path, including `nixos-system-DreamingBlade`, `sudo` or the kernel. nix.dev says the same and warns to "only add public keys you trust unconditionally" (read).

Priority does not contain this. The substitution loop tries substituters in priority order. It moves to the next one when a narinfo is missing and also when a query fails with any `Error`, such as a timeout or a 5xx (read, `src/libstore/build/substitution-goal.cc` lines 61 to 95). So a lower-priority cache serves a path whenever cache.nixos.org does not have it, or whenever cache.nixos.org fails to answer for it. Every path we build ourselves is in that first group by definition (inferred).

A compromised key or push token can therefore replace any path his hosts do not get from cache.nixos.org, for example his own system closure, his kernel or the unfree apps. With a network-position attacker who can make cache.nixos.org fail, it can replace any path at all (inferred from the loop above).

## Cachix in general

Cachix has two signing models (read, docs.cachix.org/security). In a managed cache, the default, Cachix holds the private key and signs whatever a valid push token uploads. In a self-signed cache the pusher holds the key and signs locally. In both, anyone holding a write token or the key can publish arbitrary paths that every consumer of that public key accepts (inferred). A managed cache adds Cachix the company to the trust set (inferred). cachix-action documents that anyone who can edit workflow files can read the secrets, and that code merged from forks can reveal tokens (read).

## Per-cache trust

| Cache | Operator | Who can push | Key | Serves | Risk |
|---|---|---|---|---|---|
| nix-community.cachix.org | nix-community org (volunteers, Hetzner builders) | nixbot (buildbot-nix fork) and Hydra on build03, plus `cachix-watch-store` on build03 that pushes everything entering that store (read). nixbot builds PRs from forks for 28 allowlisted GitHub repos (read). An org-wide `CACHIX_AUTH_TOKEN` Actions secret was slated for removal in 2023 and the issue is still open (read) | `nix-community.cachix.org-1`, unchanged since at least 2020 (measured name via the Cachix API). A self-managed signing key was an org-wide Actions secret until 2023-04-18 and was never rotated, since the public key is the same (inferred) | Any path its CI builds, including fork PR outputs and Hydra `nixpkgs` unfree jobsets (read) | Medium. Large pusher surface and a key that sat in org secrets for 3 years, but an active, known team |
| numtide.cachix.org | Numtide | Not verified this session. Numtide's llm-agents.nix now publishes to cache.numtide.com, a niks3 cache with key `niks3.numtide.com-1` (read) | `numtide.cachix.org-1` (measured via the Cachix API) | Legacy Cachix cache. Contents not verified | Medium, scored for zero benefit. Unknown pushers, apparently superseded |
| cache.nixos-cuda.org | NixOS-CUDA team. "This is not an official NixOS project" (read, nixos-cuda/infra) | One Hydra on `hydra.nixos-cuda.org`, served by harmonia from Hydra's own store (read) | `cache.nixos-cuda.org`, a self-held harmonia key on the Hydra host (read) | Everything that Hydra's store holds. It builds `cuda-packages-unstable` from nixos-unstable-small, plus 2445 `github-ci` PR jobsets for nixos-cuda/nixpkgs (measured via the Hydra API). Their own PR jobset comments that the merge commit "should not" be trusted (read). The infra TODO lists "Prevent unaudited SSH access to hypervisors and to Hydra" and moving to isolated stores as not done (read). It also re-serves 2546 cache.nixos.org-signed paths and 15 nix-community-signed paths (measured) | Medium. Small team, one key on a host that also evaluates and builds untrusted PRs, and isolation not done yet. It is the only cache that saves him real work |
| cache.xinux.uz | Xinux | Unknown | `cache.xinux.uz`. It signs 46 of the queried paths itself and mirrors 3523 cache.nixos.org-signed ones (measured) | CachyOS kernel builds and a mirror of cache.nixos.org | High, per Lorenzo. Already off by default on `nbh-drop-xinux-kernel` |

PR outputs are not a direct poisoning route on Hydra or nixbot. An input-addressed PR build lands at its own store path, and a fixed-output build is hash-checked (inferred). The real exposure is the build host. A sandbox escape, a stolen push token, or a stolen key on a machine that also runs untrusted code (inferred).

No public compromise of nix-community, numtide or nixos-cuda turned up in one search this session (measured). That search was shallow, so treat absence as weak evidence.

## What each cache serves today

Method. `nix-instantiate` of both toplevels on `nbh-drop-xinux-kernel` (nixpkgs 6aa7ad7), under temporary GC roots, never built. Then `bench/trust-split.py` walks `nix derivation show -r` from the toplevel and queries all six caches for every output it reaches. It walks three times. The first walk stops at any cache, in priority order, which models `master`. The second stops only at determinate or cache.nixos.org, which models the trusted-only config. The third stops at any cache but xinux, which is the baseline `CACHE.md` already priced. It then follows narinfo references for the substituted closure. `bench/trust-report.py` summarises it. Output is in `tests/results/cache-trust/report.json`. The drv hashes differ from the `cur` pair in `CACHE.md` because this eval used a `git+file` ref (measured). Counts match within a few paths.

Coverage per cache over the 4595 distinct paths queried (measured):

| Cache | Has | Wins by priority on DreamingDesk | Wins on DreamingBlade |
|---|---|---|---|
| install.determinate.systems | 69 | 69 | 69 |
| cache.nixos.org | 3762 | 3102 (13.3 GB) | 3466 (12.7 GB) |
| nix-community.cachix.org | 0 | 0 | 0 |
| numtide.cachix.org | 0 | 0 | 0 |
| cache.xinux.uz (master only) | 3569 | 9 (246 MB) | 12 (884 MB) |
| cache.nixos-cuda.org | 2693 | 6 (449 MB) | 48 (8.66 GB) |

A positive control rules out a broken query. nix-community returns 200 for `kw012zkj…-emacs-unstable-31.1-nox` from its own Hydra (measured).

No risky cache wins a path that cache.nixos.org also has (measured, 0 such paths). That is by construction, since all four have priority 41 or higher against 40 (inferred). The fallback-on-error case above is the exception.

Where they are declared (measured, `git grep`):
- `flake.nix` `nixConfig.substituters` and `extra-trusted-public-keys` list determinate, cache.nixos.org, nix-community, numtide and nixos-cuda, plus the `cache.flakehub.com-3` key.
- `modules/core/nix.nix` copies that list into `nix.settings.substituters` and sets `trusted-public-keys` to the cache.nixos.org key plus the flake's keys.
- `flake-modules/devshell.nix` passes the same list as `--option extra-substituters`.
- `modules/optimization/cachykernel.nix` adds xinux only when `binaryCache` is on. That is the default on `master` and off on `nbh-drop-xinux-kernel`.
- `modules/work/default.nix` adds the n7k gateway on work hosts only. `DreamingWork` adds nixos-apple-silicon.cachix.org. Neither affects these two hosts.

Why each one is there (measured, `git log`):
- nix-community came in with commits 826a3fa and 8d977f4, "add nix-community cache". It serves none of his paths today.
- numtide came in with 67c7279, "fix network" (2025-08-29), alongside chaotic-nyx, helix, zed and garnix. No numtide package input appears anywhere in the flake history (measured, `git log -G "numtide|nix-ai-tools|llm-agents"`). The only numtide input in the lock is `flake-utils`, a library with nothing to substitute (measured). It serves nothing.
- nixos-cuda came in with a86426c and dfa5e60, "cuda cache", and 817571e, "use nixos-unstable-small for cuda caching". It exists because `modules/hardware/optimus.nix` defaults `cudaSupport` to true, and DreamingBlade enables optimus (measured, `nixpkgs.config.cudaSupport` is true on Blade and false on Desk).

What nixos-cuda serves, by package (measured, union of both hosts, 48 paths, 8.66 GB NAR):
- On both hosts it serves unfree vendor binaries that cache.nixos.org does not carry. These are `Logic-2.4.44` AppImage (saleae-logic-2, 194 MB), the `spotify` snap (151 MB), the `cloudflare-warp` deb (73 MB), `steam` (20 MB) and `steam-run` (10 MB). Without the cache they are plain downloads from the vendor (inferred).
- On DreamingBlade it serves the CUDA closure. That covers `opencv` in two variants (3.40 GB), `cudnn` (914 MB), `libcublas` (605 MB), `libnpp` (541 MB), the `NVIDIA-Linux-x86_64-595.104.02.run` driver blob (423 MB), `vtk` (410 MB), `cuda_nvcc` (325 MB) and the other CUDA 13.4 libraries. It also covers `suitesparse`, `gimp`, `gegl`, `gmic`, `obs-studio`, `openturns`, `pagmo2`, `adios2`, `dlib` and `face-recognition`.
- Most of that comes from howdy. `opencv`, `vtk`, `openturns`, `pagmo2`, `dlib`, `adios2` and `face-recognition` reach the system through `python3-3.14.7-env` and then `howdy-3.0.0` and `pam.d` (measured, reverse drv walk). `gimp`, `gegl`, `suitesparse` and `gmic` come from `gimp3-with-plugins` in `modules/programs/packages.nix`. `obs-studio` comes from home-manager `programs.obs-studio.enable`.

What xinux serves on `master` (measured). It serves `linux-cachyos-latest-lto-x86_64-v3` (827 MB over 3 outputs), `sops-install-secrets` go-modules (57 MB) and a few trivial config paths. The branch already builds the kernel.

## Cost of dropping them

nix-community and numtide cost nothing to drop. They serve 0 paths (measured).

nixos-cuda costs this much over the `CACHE.md` baseline (measured counts, nixos-cuda narinfo sizes):

| Host | Extra outputs to build | Extra derivations | Of which fixed-output downloads |
|---|---|---|---|
| DreamingDesk | 8 | 8 | the unfree blobs above, plus their wrappers |
| DreamingBlade | 155 | 80 | 24 |

Sizes are NAR sizes. nixos-cuda serves uncompressed NARs (FileSize equals NarSize, measured), so our zstd or xz copies will be smaller (guess, about half for libraries and no gain for the `.tar.xz` archives).
- Runtime paths the hosts download are 48 paths and 8.66 GB.
- Build-only fixed-output sources are 51 paths and 10.76 GB. These are mostly NVIDIA `*-archive.tar.xz` and unpacked `*-source` trees. They can be fetched again from NVIDIA and need not live in our cache (inferred).
- 55 sibling outputs such as `-dev`, `-static` and `-stubs` are on no cache and have no size (measured). They come from the same builds.

Real compiles on DreamingBlade number about 22. These are `opencv` twice, `vtk`, `openturns`, `pagmo2`, `dlib`, `python3.14-dlib`, `face-recognition`, `suitesparse`, `gegl`, `gimp` and its plugins, `gmic`, `gmic-qt-gimp`, `obs-studio`, `ipopt`, `spral`, `ceres-solver`, `ucx`, `hwloc`, `adios2` and `zfp` (measured list). The `cuda13.4-*` derivations only unpack and patch vendor archives (read, nixpkgs redist builder behaviour, not re-checked this session).

Build time on c7i.24xlarge is not measured. The CUDA Hydra's opencv builds were all cache hits with 0 s duration, so they gave no timing (measured). My estimate is 45 to 90 minutes of builder wall time, dominated by CUDA `opencv` and `vtk` (guess). The kernel took 781 s on the same type (measured, earlier run). At $0.5499/h that is $0.41 to $0.83 per rebuild (guess).

How often it rebuilds. Every CUDA derivation (`opencv`, `vtk`, `cudnn`, `gimp`, `obs-studio`, `suitesparse`) changed hash between the 2026-10-12 and 2026-10-15 locks (measured, 3 days apart). So the weekly bot would rebuild the whole set almost every week (inferred from one pair). That comes to about $1.8 to $3.6 a month of Spot time (guess) and 8.7 GB more pulled by Blade per week.

Storage and egress, using CACHE.md prices (read):
- Storing the runtime set only costs at most 8.66 GB times $0.023, about $0.20 a month. Two overlapping generations during a rollout make it $0.40 (inferred, NAR upper bound).
- Storing the build-only sources as well adds $0.25.
- Blade's extra pulls come to about 37 GB a month. With the 9.4 GB baseline and the 15 GB copy-back, the account stays near 62 GB, under the 100 GB free egress (inferred). That still leaves the S3 over R2 verdict in CACHE.md unchanged.

A cheaper variant if we build CUDA ourselves. Set `nixpkgs.config.cudaCapabilities` to Blade's GPU only. That changes every CUDA hash, so nixos-cuda could no longer serve them anyway. It should cut opencv's nvcc work several times over (guess). Blade's GPU model was not read this session.

CUDA is the only substantive impact. Desk only loses the unfree downloads.

## Recommendation

- install.determinate.systems. Keep (his call). It signs with `cache.flakehub.com-4` (measured on all 69 paths). The flake lists only `-3`. On the box, determinate-nixd's own `/etc/nix/nix.conf` adds `-3` through `-10` (measured). His hosts likely get the same (inferred). Leave it.
- cache.nixos.org. Keep.
- nix-community.cachix.org. Drop. It is medium risk and serves 0 paths.
- numtide.cachix.org. Drop. It serves 0 paths and no input ever needed it. If he later adds llm-agents.nix, its current cache is cache.numtide.com.
- cache.xinux.uz. Drop. That is already done on `nbh-drop-xinux-kernel` with `binaryCache = false`. Delete the option when that branch lands.
- cache.nixos-cuda.org. Drop, and build the CUDA set ourselves into our S3 cache, signed by our key. Push only runtime outputs and skip fixed-output sources. If howdy, the gimp filters and OBS do not need CUDA, set `dreaming.hardware.optimus.cudaSupport = false` on Blade instead. Then all of it comes from cache.nixos.org and costs nothing. That trade is his decision. I can't see from here which he uses with CUDA.

## Exact change

`flake.nix` on `nbh-drop-xinux-kernel`. `modules/core/nix.nix` and the devshell read from it, so this one edit covers both hosts and the devshell:

```diff
   nixConfig = {
     substituters = [
       "https://install.determinate.systems?priority=20"
       "https://cache.nixos.org?priority=40"
-      "https://nix-community.cachix.org?priority=41"
-      "https://numtide.cachix.org?priority=43"
-      "https://cache.nixos-cuda.org?priority=45"
     ];
     extra-trusted-public-keys = [
       "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
-      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
-      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
-      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
     ];
   };
```

If he picks the no-CUDA option, also add this to `hosts/x86_64-nixos/DreamingBlade/default.nix`:

```diff
   dreaming.hardware.optimus = {
     enable = true;
+    cudaSupport = false;
     nvidiaBusId = "PCI:1:0:0";
     amdgpuBusId = "PCI:4:0:0";
   };
```

Our own cache's substituter and public key get appended to the same two lists when it is deployed. The first lockfile switch after this change on Blade will build the CUDA set locally unless the builders have already pushed it. Run the weekly bot before switching (inferred).

## Sources read this session

- https://github.com/NixOS/nix at 79b6d5b, files `src/libstore/keys.cc`, `src/libstore/local-store.cc`, `src/libstore/build/substitution-goal.cc`, `src/libstore/include/nix/store/globals.hh`
- https://nix.dev/guides/recipes/add-binary-cache.html (search excerpt)
- https://docs.cachix.org/security and https://docs.cachix.org/getting-started (search excerpts)
- https://github.com/cachix/cachix-action README (search excerpt)
- https://nix-community.org/continuous-integration/ and https://nix-community.org/cache/
- https://github.com/nix-community/infra at master, files `modules/nixos/nixbot.nix`, `modules/nixos/watch-store.nix`, `hosts/build03/default.nix`, `flake.nix`
- https://github.com/nix-community/infra/issues/532 and commit 43e72bf
- https://github.com/nix-community/buildbot-nix, files `nixosModules/cachix.nix`, `buildbot_nix/buildbot_nix/nix_build.py`
- https://github.com/nixos-cuda/infra README (search excerpt), https://cache.nixos-cuda.org/, https://hydra.nixos-cuda.org API
- https://github.com/nixos-cuda/hydra-jobsets, `README.md` and `jobsets/nixpkgs-pr.nix`
- https://cache.numtide.com/index.html and https://github.com/numtide/llm-agents.nix README (search excerpts)
- Cachix API `/api/v1/cache/{nix-community,numtide}` for public key names
