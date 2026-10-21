#!/usr/bin/env bash
# smoke-ec2.sh OUTDIR [gate|warm|deadman] runs one cold session on real EC2
# from the box: nbh-gate (aws backend, nbh-gate's least-privilege key)
# launches a small Spot builder, a root hook-mode build with max-jobs 0 goes
# through it over ssh-ng, and the script records launch, splice, build and
# termination times from the gate log and DescribeInstances. `warm` adds a
# second build while the builder serves. `deadman` kills the gate right after
# the build, so only the builder's dead-man switch can end the instance.
# NBH_TYPES, NBH_MAX_PRICE and NBH_OWNER override the Spot types, the price
# cap in $/h and the nbh:owner tag.
set -euo pipefail
out=${1:?usage: smoke-ec2.sh OUTDIR [gate|warm|deadman]}
mode=${2:-gate}
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
pki=/home/box/secrets/nbh-pki-ssh
gate=$(nix build --no-link --print-out-paths "$repo#gate")/bin/nbh-gate
"$gate" pki-init "$pki" box-smoke
grep -q ' nbh-builder$' /etc/hosts || echo '127.0.0.1 nbh-builder' | sudo -n tee -a /etc/hosts >/dev/null
NIX=/nix/var/nix/profiles/default/bin/nix
entry="ssh-ng://nbh@nbh-builder:2222 x86_64-linux $pki/ssh_client 2 1 big-parallel,benchmark - -"
# Same ssh options as modules/client.nix. The box has no system ssh; NixOS
# clients get it from programs.ssh.
sshbin=$(nix build --no-link --print-out-paths --inputs-from "$repo" nixpkgs#openssh.out)/bin
nixenv=(PATH="$sshbin:$PATH" NIX_SSHOPTS="-o HostKeyAlias=nbh-builder -o UserKnownHostsFile=$pki/ssh_known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4")
admin() { AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot AWS_REGION=eu-north-1 nix shell nixpkgs#awscli2 -c aws "$@"; }
ts() { date +%s.%N; }
build() {
  sudo -n env "${nixenv[@]}" "$NIX" build --impure -f "$repo/scripts/probe.nix" \
    --argstr nonce "$1" --no-link --print-out-paths -L --store local --max-jobs 0 --builders-use-substitutes \
    --builders "$entry"
}

"$gate" run --backend aws --aws-account 845087560967 \
  --credentials-file /home/box/secrets/nbh-gate.credentials --profile nbh-gate --pki "$pki" --owner "${NBH_OWNER:-box-smoke}" \
  --instance-types "${NBH_TYPES:-m7a.large,c7a.large}" --max-price "${NBH_MAX_PRICE:-0.05}" \
  --listen 127.0.0.1:2222 --machines-file "$out/machines" --machines-entry "$entry" >"$out/gate.log" 2>&1 &
gpid=$!
trap 'kill $gpid 2>/dev/null || true' EXIT
sleep 1
nonce=ec2-$(date +%s)
t0=$(ts)
build "$nonce" >"$out/build.log" 2>&1 && rc=0 || rc=$?
t1=$(ts)
echo "build exit=$rc wall=$(awk "BEGIN{print $t1-$t0}") s" | tee "$out/summary.txt"
cat /nix/store/*-nbh-probe-"$nonce" 2>/dev/null | tee -a "$out/summary.txt" || true
if [ "$mode" = warm ]; then
  w0=$(ts)
  build "$nonce-warm" >"$out/build-warm.log" 2>&1 && wrc=0 || wrc=$?
  t1=$(ts)
  echo "warm build exit=$wrc wall=$(awk "BEGIN{print $t1-$w0}") s remote=$(grep -c "on 'ssh-ng://" "$out/build-warm.log")" | tee -a "$out/summary.txt"
fi
id=$(grep -oE 'launched [^ ]+ as i-[0-9a-f]+' "$out/gate.log" | head -1 | awk '{print $4}')
echo "instance=$id" | tee -a "$out/summary.txt"
if [ "$mode" = deadman ]; then
  kill -9 $gpid; echo "gate killed at $(date -Is)" | tee -a "$out/summary.txt"
fi
while :; do
  st=$(admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "$(date -Is) $st" >>"$out/states.txt"
  case $st in shutting-down|terminated) break ;; esac
  sleep 10
done
t2=$(ts)
echo "instance $st $(awk "BEGIN{print $t2-$t1}") s after the build ended" | tee -a "$out/summary.txt"
admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone,LaunchTime,StateTransitionReason,StateReason.Message]' --output text | tee -a "$out/summary.txt"
