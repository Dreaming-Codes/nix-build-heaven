# kernel-1: direct mode, aborted by hand after 100 s

`nix build --store grpc://nbh-builder --eval-store auto` against one fresh
c7i.24xlarge (i-0a482cfaa645242ae, eu-north-1c, Spot $0.6129/h; eu-north-1b had
no capacity). Builder listening 42.0 s after the launch request, 34.3 s after RunInstances returned; the first try in 1b failed with InsufficientInstanceCapacity after 5.7 s (measured, gate.log).

The builder started building the whole minimal bootstrap from source (hex0,
M2, mes, tinycc: 267 derivations in 60 s) instead of substituting the
toolchain from cache.nixos.org (measured, build.log.gz). Cause (read,
nix-grpc-store src): direct mode decides which input derivations are missing
with `queryValidPaths(..., NoSubstitute)` (client/build.cc missingInputDrvs);
on the daemon that is `LocalStore::queryValidPaths`, which reports only paths
already on disk. Substitutable paths are added only when a farm cache is
configured (`coord.cache.hasRemote()`, daemon/main.cc QueryValidPaths). A lone
Tier A builder has none, so every input becomes a build job.

The client was killed (exit 1 in summary.txt is that kill, not a build
failure) and the script terminated the instance. Instance ran 95 s
(19:15:33Z to 19:17:08Z), about $0.017 (measured price x seconds, EBS and IPv4
inferred from list prices). Hook mode does not have this problem; see kernel-2.
