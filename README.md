# Nix Build Heaven

One elastic AWS Spot builder per build session for Dreaming-Codes/nixos. `nh os switch` stays the same command. When a rebuild misses the binary caches, the nix-daemon's connection to `grpc://nbh-builder` reaches a local gate, which launches a builder and resets connections while it boots. The plugin retries a reset for `connect-timeout`, so its next attempt after boot is spliced through. The gate terminates the builder when the session goes idle. When AWS is unreachable the gate empties the machines file and Nix builds locally.

See `/workspace/nbh/DESIGN.md` for the design and `TRAIL.md` for what was checked and how.

## Layout

- `gate/` is `nbh-gate` in Go. `fleet` is the pure state machine, `gate` is the proxy and effect executor, `cloud` is the EC2 boundary with an in-memory fake, `certs` is the private CA that mints per-launch user-data.
- `modules/builder.nix` is the builder NixOS module. `nix/ami.nix` turns it into the raw amazon image (`packages.ami`).
- `modules/client.nix` is the client NixOS module: plugin, machines file, gate unit.
- `nix/plugin.nix` builds the nix-grpc-store plugin for a Determinate input, with `patches/determinate-addTempRoots.patch`.
- `tests/` holds the VM tests for phases 1 to 3, their logs in `tests/results/`, and `plugin-probe/`, which shows how the plugin reacts to a held, reset or closed connection. `bench/` holds the Phase 0 baseline harness, results and `simulate.py`.

## Checks

```
cd gate && go test -race ./...
scripts/check.sh phase1-hook-build phase2-builder-image phase3-gate-coldstart
tests/plugin-probe/run.sh
bench/nbh-bench OUT INSTALLABLE...
bench/simulate.py bench/results/s2-libinput-oom
```

`scripts/check.sh` exists because the shared box's nix-daemon does not advertise `kvm` and its nested KVM crashes on vCPU creation, so the VMs run under TCG and their timings are slower than EC2. On a normal NixOS host `nix build .#checks.x86_64-linux.<name>` is enough.
