# grpc:// or ssh-ng:// for the one elastic builder

Question from Lorenzo (2026-10-20): does nix-grpc-store make sense, or is
something simpler better? Context: one builder is enough (Phase 0), the gate
runs locally and costs nothing, hook mode is the only mode that works for a
single builder (direct `--store grpc://` does not substitute inputs, kernel-1),
and the grpc plugin needs a local patch for Determinate 3.23.x.

Labels: measured (run here), read (source), inferred, guess. Times UTC+2.

## Recommendation

Switch to ssh-ng, keep the gate. ssh-ng is built into Determinate Nix, so the
plugin, its patch, its soname workaround and its GLIBCXX pinning all go away.
The gate's only change is to hold a connection through the boot instead of
resetting it, which ssh needs and which makes the cold start shorter. Auth
stays per-boot via user-data (an SSH host CA instead of a TLS CA). The one cost
is copy throughput, slower under TCG emulation; on real hardware the home
uplink, not the cipher, should bound it (inferred, not measured on EC2).

No Lambda or Cloudflare Worker is needed in either design: nothing runs in the
cloud between sessions now. The gate is a local process on the client host.

## Findings

| # | Claim | Label | Evidence |
|---|---|---|---|
| 1 | Nix's ssh-ng client sets no connect timeout and waits for the "started" line from ssh with no deadline; build-remote disables a machine for the rest of that hook process on any connect error and then declines (local build) or, with max-jobs 0, fails | read | `src/libstore/ssh.cc` startCommand/startMaster, `src/nix/build-remote/build-remote.cc` 280-286, Determinate nix-src 3.23.1 |
| 2 | Against a gate that resets, FINs or closes, ssh-ng fails in 42 to 53 ms with one connection, no retry | measured (box, Determinate 3.23.3, OpenSSH 10.5p1) | `tests/results/ssh-probe.txt` |
| 3 | Against a gate that holds the connection silent, ssh-ng waits (still waiting at 45 s); `ConnectTimeout=10` turns that into a failure at 10.3 s ("banner exchange"), so ConnectTimeout must stay unset | measured | same |
| 4 | Hold 30 s then splice to a real sshd: `nix store info` succeeds at 29.9 s with one accept. ConnectionAttempts=20 changes nothing (30.1 s); it only retries a refused TCP connect, 1 s apart (5 attempts, 4.05 s, then fail) | measured | same |
| 5 | A ProxyCommand that sleeps 30 s then pipes to sshd also works, 30.2 s | measured | same |
| 6 | Cold start through the real gate in hold mode, 20 s fake boot, TCG VMs: 33.3, 33.8, 32.9 s over three runs; one launch, no refusal, no "cannot build on". grpc Phase 3 run 7 on the same setup: 43.1 s | measured, TCG | `tests/results/ssh-coldstart.log`, `tests/results/phase3-gate-coldstart.log` |
| 7 | Warm two-step build through the gate: ssh-ng 5.8 to 5.9 s, grpc run 7 11.0 s | measured, TCG, one grpc sample | same |
| 8 | On EC2 the grpc client splices 13.2 s after the builder listens (kernel-2: listening 34.5 s, splice 47.7 s; smokes 8 to 17 s). With hold, the splice follows the gate's first good probe, so that gap shrinks to the 2 s probe cadence | measured gap; saving inferred | `tests/results/ec2/kernel-2/RESULT.md`, TRAIL 20:17 |
| 9 | A gate that resets (today's grpc behaviour) is wrong for ssh-ng: with max-jobs 1 both derivations build locally after 2.1 s; with max-jobs 0 the build fails in 1.4 s ("local builds are disabled") | measured, TCG | `tests/results/ssh-coldstart.log`, subtest "a resetting gate" |
| 10 | Scale-down: terminate 16.2 and 16.6 s after the last build with idle-grace 10 s. Hold mode never sets LastRefused, so the RetryHold delay behind the 132 to 144 s EC2 scale-down miss does not exist for ssh-ng | measured TCG; EC2 effect inferred | `tests/results/ssh-coldstart.log`, TRAIL 20:17 |
| 11 | Fallback with the cloud down: empty machines file, local build 1.6 s vs 1.7 s with nbh off | measured, TCG | same |
| 12 | Auth: the gate's SSH CA certifies a fresh ed25519 host key per launch (3 h validity, principal nbh-builder) and user-data carries the gate's client public key. The client logs in as `nbh`; a foreign client key, root, and a client without the CA line are all refused; an expired host cert is refused | measured (VM test and Go test) | `gate/certs/ssh.go`, `gate/certs/ssh_test.go`, ssh-coldstart subtest "auth" |
| 13 | User-data with TLS and SSH material is 2518 bytes, under EC2's 16 KB | measured | `nbh-gate userdata` |
| 14 | Dead-man: an established TCP connection on 22 cannot mean busy because scanners hit 22; any nbh process cannot either, because PAM leaves nbh's `systemd --user` running after logout (run 1 false positive). Busy is now an nbh `nix-daemon` (the ssh-ng session) or a nixbld process; verified busy during a build and idle after it with the user manager lingering | measured, TCG | `tests/results/ssh-coldstart.run1-busy-false-positive.log`, `tests/results/ssh-coldstart.log` |
| 15 | Small two-step build, no gate, alternating: grpc 13.35, 9.89, 9.74 s; ssh-ng 10.59, 9.78, 9.45 s | measured, TCG | `tests/results/transport-bench.run3-bulk-then-client-vm-died.log` |
| 16 | 64 MiB fresh input up and 64 MiB output back: grpc 29.75, 30.6, 29.83 s; ssh-ng 50.72, 48.03, 46.94 s, so ssh-ng is about 1.6x slower here | measured, TCG | same |
| 17 | The 1.6x is mostly emulated crypto and copies, which cost far more under TCG than on hardware; on EC2 and a home link the uplink should dominate both. The kernel-2 run uploaded 1.2 MB and downloaded 826 MB, so the download of outputs is the part that matters | inferred, not measured on EC2 | kernel-2 RESULT.md |
| 18 | builders-use-substitutes works over both transports: with a 32 MiB input present in an HTTP binary cache the builder fetched its narinfo (200) and NAR from the cache instead of receiving it from the client, for grpc and for ssh-ng | measured, TCG | `tests/results/transport-subst.log` |

## Designs considered

- **A. ssh-ng behind the hold-mode gate (prototyped).** Same machines-file
  switch, same fleet reducer, `-transport ssh-ng`. Implemented in
  `gate/fleet` (HoldWhileBooting, Held, settleHeld), `gate/certs/ssh.go`,
  `modules/builder.nix` (`transports`), `modules/client.nix` (`transport`).
- **B. ProxyCommand only, no gate daemon (not prototyped).** ssh_config for
  nbh-builder runs `nbh-gate connect`, which finds or launches the instance,
  waits for port 22, then pipes. Termination is left to the builder's dead-man
  switch, which with precise ssh-ng busy detection could use a short idle
  timeout (say 2 min). It removes the daemon and the machines-file switch, but
  every hook connection then pays an EC2 API call or a cached lookup, needs a
  lock against concurrent launches, and needs its own "cloud unavailable"
  memory so each derivation does not wait on a dead API. Finding 5 shows ssh
  is happy with it. A good follow-up once A runs on EC2, not before (guess).
- **C. Keep grpc.** Works today and copies faster under TCG, but carries the
  plugin patch through every Determinate upgrade and the client's reconnect
  backoff on every cold start.

## Status 2026-10-20 23:55

Steps 1 to 4 done: ami-046c3f591eca17088 with both transports and the tcp/22
rule applied; ssh-ng EC2 smokes pass cold (36.0, 33.7 s), warm (3.3 s),
terminate (73 s) and dead-man (626 s); kernel-3 over ssh-ng in 1054 s for
about $0.18 with outputs bit-identical; nixos branch nbh-ssh-ng-client
(c1f0ebd, local). Step 5 not started. See TRAIL 22:33 to 23:55.

## Status 2026-10-21 00:52

Step 5 done on branch rust-gate, with the gate rewritten in Rust. grpc is
gone from the repo and from AWS: no plugin, no patch, no 50051 rule. The
builder AMI is ami-0dbc5c7676643380c, ssh-ng only. The old AMI is deleted.
The Rust gate's EC2 smoke spliced 25.8 s after launch and built cold in 31.7 s.
The nixos branch still sets `transport` and the old single-dash gate flags,
so it needs the changes listed in TRAIL 00:42. See TRAIL 00:13 to 00:52.

## Work to finish the switch (estimates, guess)

1. Re-bake the AMI with `transports = [ "grpc" "ssh-ng" ]` (already set in
   `nix/ami.nix`), upload with coldsnap, `tofu apply` for the new AMI and the
   port 22 rule (in `infra/default.nix`, not applied). About 30 min; the raw
   image needs about 4 GB of box disk, so GC first.
2. `scripts/smoke-ec2.sh` with `-transport ssh-ng` on a small Spot type: cold
   start, warm, terminate, dead-man. About 30 min, about 1 cent.
3. Optional: rerun kernel-2 over ssh-ng to measure the 826 MB download and the
   cold-start gain on real hardware. About 25 min, about 17 cents.
4. Client in Dreaming-Codes/nixos: `services.nbh.transport = "ssh-ng"`, drop
   the plugin input and `plugin-files`. About 30 min, local branch only.
5. Once ssh-ng is proven, remove grpc: `nix/plugin.nix`, the patch, the grpc
   parts of both modules, RetryHold/Refuse in the reducer, and the AMI's 50051.
   About 1 h.

Total about half a day of agent time and under $0.25 of EC2.
