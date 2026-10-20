#!/usr/bin/env bash
# smoke-ec2.sh OUTDIR [deadman] runs one cold session on real EC2 from the box:
# nbh-gate (aws backend, nbh-gate's least-privilege key) launches a small Spot
# builder, a root hook-mode build with max-jobs 0 goes through it, and the
# script records launch, splice, build and termination times from the gate log
# and DescribeInstances. With `deadman` the gate is killed right after the
# build, so only the builder's dead-man switch can end the instance.
# `-transport ssh-ng` (first argument) uses Nix's built-in ssh-ng instead of the
# grpc plugin: the gate listens on 2222 and holds the connection while booting.
set -euo pipefail
transport=grpc
if [ "${1:-}" = -transport ]; then transport=${2:?}; shift 2; fi
out=${1:?usage: smoke-ec2.sh [-transport grpc|ssh-ng] OUTDIR [deadman]}
mode=${2:-gate}
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
pki=/home/box/secrets/nbh-pki
gate=$(nix build --no-link --print-out-paths "$repo#gate")/bin/nbh-gate
"$gate" pki-init "$pki" box-smoke
grep -q ' nbh-builder$' /etc/hosts || echo '127.0.0.1 nbh-builder' | sudo -n tee -a /etc/hosts >/dev/null
DET_NIX=/nix/var/nix/profiles/default/bin/nix
DET_SO=$(readlink -f /workspace/nbh/proof/res-det2)/lib/nix/nix-grpc-store-versions/2.35.3/nix-grpc-store.so
types=${NBH_TYPES:-m7a.large,c7a.large}
if [ "$transport" = ssh-ng ]; then
  entry="ssh-ng://nbh@nbh-builder:2222 x86_64-linux $pki/ssh_client 2 1 big-parallel,benchmark - -"
  listen=127.0.0.1:2222
  # Same ssh options as modules/client.nix; no ConnectTimeout so ssh waits
  # for the banner while the gate holds the connection through the boot.
  # The box has no system ssh; NixOS clients get it from programs.ssh.
  sshbin=$(nix build --no-link --print-out-paths nixpkgs#openssh)/bin
  nixenv=(PATH="$sshbin:$PATH" NIX_SSHOPTS="-o HostKeyAlias=nbh-builder -o UserKnownHostsFile=$pki/ssh_known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4")
else
  uri="grpc://nbh-builder:50051?ca-cert=$pki/ca.crt&client-cert=$pki/client.crt&client-key=$pki/client.key&connect-timeout=150"
  entry="$uri x86_64-linux - 2 1 big-parallel,benchmark"
  listen=127.0.0.1:50051
  nixenv=(NIX_CONFIG="plugin-files = $DET_SO")
fi
admin() { AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot AWS_REGION=eu-north-1 nix shell nixpkgs#awscli2 -c aws "$@"; }
ts() { date +%s.%N; }

AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/nbh-gate.credentials AWS_PROFILE=nbh-gate \
  "$gate" -backend aws -pki "$pki" -owner "${NBH_OWNER:-box-smoke}" -instance-types "$types" -max-price "${NBH_MAX_PRICE:-0.05}" \
  -listen "$listen" -transport "$transport" \
  -machines-file "$out/machines" -machines-entry "$entry" \
  -retry-hold 150s >"$out/gate.log" 2>&1 &
gpid=$!
trap 'kill $gpid 2>/dev/null || true' EXIT
sleep 1
nonce=ec2-$(date +%s)
t0=$(ts)
set +e
sudo -n env "${nixenv[@]}" "$DET_NIX" build --impure -f /workspace/nbh/proof/tiny.nix \
  --argstr nonce "$nonce" --no-link --print-out-paths -L --store local --max-jobs 0 --builders-use-substitutes \
  --builders "$entry" >"$out/build.log" 2>&1
rc=$?
set -e
t1=$(ts)
echo "transport=$transport build exit=$rc wall=$(awk "BEGIN{print $t1-$t0}") s" | tee "$out/summary.txt"
cat /nix/store/*-grpc-probe-$nonce 2>/dev/null | tee -a "$out/summary.txt" || true
id=$(grep -oE 'launched [^ ]+ as i-[0-9a-f]+' "$out/gate.log" | head -1 | awk '{print $4}')
echo "instance=$id" | tee -a "$out/summary.txt"
if [ "$mode" = deadman ]; then
  kill -9 $gpid; echo "gate killed at $(date -Is)" | tee -a "$out/summary.txt"
fi
# Poll until EC2 says the instance is gone, then record when.
while :; do
  st=$(admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "$(date -Is) $st" >>"$out/states.txt"
  case $st in shutting-down|terminated) break ;; esac
  sleep 10
done
t2=$(ts)
echo "instance $st $(awk "BEGIN{print $t2-$t1}") s after the build ended" | tee -a "$out/summary.txt"
admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone,LaunchTime,StateTransitionReason,StateReason.Message]' --output text | tee -a "$out/summary.txt"
