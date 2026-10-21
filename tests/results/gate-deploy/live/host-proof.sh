#!/usr/bin/env bash
# host-proof.sh runs the DreamingDesk nbh-gate unit from the nixos branch
# nbh-gate-deploy on the box as root. ExecStartPre and ExecStart are the
# evaluated strings with /run/secrets and /run/nbh moved under a root tmpdir,
# filled from the plaintext files that secrets/nbh-gate.yaml encrypts (the box
# has no age key). The build uses builders=@machines and the evaluated ssh_config.
set -euo pipefail
out=$(cd "$(dirname "$0")" && pwd)
flake=/workspace/nbh/nixos-gate
host=DreamingDesk
root=/run/nbh-proof
NIX=/nix/var/nix/profiles/default/bin/nix
admin() { AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot AWS_REGION=eu-north-1 nix shell nixpkgs#awscli2 -c aws "$@"; }
log() { echo "$(date -Is) $*" | tee -a "$out/summary.txt"; }
: >"$out/summary.txt"

ev() { nix eval --raw "$flake#nixosConfigurations.$host.config.$1"; }
pre=$(ev systemd.services.nbh-gate.serviceConfig.ExecStartPre)
exec_=$(ev systemd.services.nbh-gate.serviceConfig.ExecStart)
ssh_cfg=$(ev programs.ssh.extraConfig)
sub() { sed -e "s|/run/secrets/|$root/secrets/|g" -e "s|/run/nbh/machines|$root/machines|g"; }
printf '%s\n' "$pre" "$exec_" >"$out/unit-evaluated.txt"
pre=$(printf '%s' "$pre" | sub); exec_=$(printf '%s' "$exec_" | sub)
printf '%s\n' "$pre" "$exec_" >"$out/unit-run.txt"

sudo -n rm -rf "$root"
sudo -n install -d -m 0751 -o root -g root "$root" "$root/secrets"
sudo -n install -d -m 0751 -o root -g root "$root/secrets/nbh-pki"
s=/home/box/secrets
sudo -n install -m 0400 -o root -g root "$s/nbh-gate.credentials" "$root/secrets/nbh_gate_credentials"
for f in ssh_host_ca ssh_client ssh_client.pub ssh_known_hosts; do
  sudo -n install -m 0400 -o root -g root "$s/nbh-pki-ssh/$f" "$root/secrets/nbh-pki/$f"
done
printf '%s\n' "$ssh_cfg" | awk '/^Host nbh-builder/{p=1} /^Include/{p=0} p' | sub | sudo -n tee "$root/ssh_config" >/dev/null
cp /dev/null "$out/ssh_config.txt"; sudo -n cat "$root/ssh_config" >"$out/ssh_config.txt"

sudo -n bash -c "stat -c '%n %a %U:%G %Y' $root/secrets/nbh-pki/* $root/secrets/nbh_gate_credentials" | sed "s|$root|ROOT|" >"$out/secrets-before.txt"
sudo -n bash -c "$pre" >"$out/pki-init.log" 2>&1; log "ExecStartPre rc=$?"
sudo -n bash -c "stat -c '%n %a %U:%G %Y' $root/secrets/nbh-pki/* $root/secrets/nbh_gate_credentials" | sed "s|$root|ROOT|" >"$out/secrets-after.txt"
cmp -s "$out/secrets-before.txt" "$out/secrets-after.txt" && log "pki-init wrote nothing (names, modes, owners, mtimes equal)" || log "pki-init CHANGED the secret dir"

# Guard: a wrong account must exit 78, which RestartPreventExitStatus stops.
set +e
sudo -n timeout 60 bash -c "$(printf %s "$exec_" | sed -e "s/--aws-account 845087560967/--aws-account 000000000000/" -e "s/--listen 127.0.0.1:2222/--listen 127.0.0.1:2299/" -e "s|$root/machines|$root/machines-guard|")" >"$out/guard-mismatch.log" 2>&1
log "mismatch account rc=$? (want 78)"
set -e

sudo -n bash -c "exec $exec_" >"$out/gate.log" 2>&1 &
gpid=$!
trap 'sudo -n kill -TERM $gpid 2>/dev/null || true' EXIT
sleep 3
sudo -n ss -ltnp | grep ':2222 ' | sed 's/pid=[0-9]*/pid=N/; s/fd=[0-9]*/fd=N/' >"$out/listener.txt" || true
log "listener: $(cat "$out/listener.txt")"
log "machines file: $(sudo -n cat "$root/machines" | sed "s|$root|ROOT|")"

sshbin=$(nix build --no-link --print-out-paths --inputs-from "$flake" nixpkgs#openssh.out)/bin
nonce=host-proof-$(date +%s)
t0=$(date +%s.%N)
set +e
sudo -n env PATH="$sshbin:$PATH" NIX_SSHOPTS="-F $root/ssh_config" "$NIX" build --impure \
  -f /workspace/nbh/nix-build-heaven/scripts/probe.nix --argstr nonce "$nonce" \
  --no-link --print-out-paths -L --store local --max-jobs 0 --builders "@$root/machines" >"$out/build.log" 2>&1
rc=$?
set -e
t1=$(date +%s.%N)
log "build exit=$rc wall=$(awk "BEGIN{printf \"%.1f\", $t1-$t0}") s, remote lines: $(grep -c "on 'ssh-ng://nbh@nbh-builder:2222'" "$out/build.log")"
log "last ssh closed at $(date -Is)"
id=$(grep -oE 'launched [^ ]+ as i-[0-9a-f]+' "$out/gate.log" | head -1 | awk '{print $4}')
log "instance=$id"
for i in $(seq 1 60); do
  grep -q " terminate " "$out/gate.log" && break; sleep 5
done
log "gate: $(grep ' terminate ' "$out/gate.log" | head -1)"
for i in $(seq 1 30); do
  st=$(admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
  case $st in shutting-down|terminated) break ;; esac; sleep 10
done
admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,Placement.AvailabilityZone,State.Name,LaunchTime,StateTransitionReason,ImageId,join(`,`,Tags[?Key==`nbh:owner`].Value)]' --output text | tee -a "$out/summary.txt"
sleep 30
sudo -n kill -TERM $gpid || true
wait $gpid; log "gate exit=$?"
sudo -n rm -rf "$root"
log "removed $root"
