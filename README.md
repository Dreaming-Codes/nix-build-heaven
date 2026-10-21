# Nix Build Heaven

> [!WARNING]
> This is an experiment in active development. Expect breaking changes, rough edges and missing docs. Don't rely on it for anything important yet.

One elastic AWS Spot builder per build session for Dreaming-Codes/nixos. `nh os switch` stays the same command. When a rebuild misses the binary caches, the nix-daemon's ssh-ng connection to `nbh-builder` reaches a local gate, which launches a builder and holds the connection, silent, while it boots. ssh waits for the server banner with no deadline, so the first attempt is spliced through once the builder's sshd answers. The gate terminates the builder when the session goes idle. When AWS is unreachable the gate empties the machines file and closes held connections, and Nix builds locally.

See `SSH-NG.md` for why ssh-ng replaced grpc, and `TRAIL.md` for what was checked and how.

## Layout

- `gate/` is `nbh-gate` in Rust. `fleet` is the pure state machine, `gate` is the proxy and effect executor, `cloud` is the cloud boundary with an in-memory fake, `ec2` signs the five EC2 calls and the STS account check the gate makes, `pki` is the SSH host CA that mints per-launch host certificates into user-data.
- `modules/builder.nix` is the builder NixOS module. `nix/ami.nix` turns it into the raw amazon image (`packages.ami`).
- `modules/client.nix` is the client NixOS module: machines file, ssh options for `nbh-builder`, gate unit.
- `infra/` is the AWS side in terranix, applied by `scripts/tofu.sh`. `scripts/upload-ami.sh` uploads the image with coldsnap.
- `tests/` holds the VM tests, their logs in `tests/results/` (earlier grpc runs included), and `ssh-probe/`, which shows how Nix's ssh-ng client reacts to a held, reset or closed connection. `bench/` holds the Phase 0 baseline harness, the kernel and provider cost models, and their results.

## Checks

```
cd gate && cargo test && cargo clippy --all-targets -- -D warnings
scripts/check.sh ssh-coldstart builder-image
scripts/smoke-ec2.sh OUTDIR [gate|warm|deadman]
tests/ssh-probe/run.sh
bench/nbh-bench OUT INSTALLABLE...
bench/simulate.py bench/results/s2-libinput-oom
```

`scripts/check.sh` exists because the shared box's nix-daemon does not advertise `kvm` and its nested KVM crashes on vCPU creation, so the VMs run under TCG and their timings are slower than EC2. On a normal NixOS host `nix build .#checks.x86_64-linux.<name>` is enough.

With `--backend aws` the gate reads AWS credentials only from `--credentials-file`, profile `--profile` (default `nbh-gate`). It never reads `AWS_*` variables or `~/.aws`. Before it can launch anything it asks STS GetCallerIdentity which account the key belongs to, and exits with status 78 if that is not `--aws-account`. The client module passes all three from `services.nbh.aws` and does not restart the unit on 78.
