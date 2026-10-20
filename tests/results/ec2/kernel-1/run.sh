#!/usr/bin/env bash
# kernel-1/run.sh: one cold nbh-gate session on real EC2 that builds the
# DreamingDesk CachyOS LTO kernel (drv 61g9) in direct mode
# (nix build --store grpc://nbh-builder --eval-store auto). The builder
# substitutes every input from its own caches (cache.nixos.org, no xinux);
# the box only ships .drv files and cannot build anything. Then the three
# outputs are copied back through the gate for local verification.
# Guard: abort and terminate if the build runs past ABORT_S.
set -euo pipefail
out=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$out/../../../.." && pwd)
pki=/home/box/secrets/nbh-pki
drv=/nix/store/61g9nhv4i4ywv34w53aw10z3q20rgy6k-linux-cachyos-latest-lto-x86_64-v3-7.2.8.drv
types=${NBH_TYPES:?}
maxprice=${NBH_MAX_PRICE:?}
abort_s=${ABORT_S:-2700}
gate=$(nix build --no-link --print-out-paths "$repo#gate")/bin/nbh-gate
"$gate" pki-init "$pki" box-smoke
DET_NIX=/nix/var/nix/profiles/default/bin/nix
DET_SO=$(readlink -f /workspace/nbh/proof/res-det2)/lib/nix/nix-grpc-store-versions/2.35.3/nix-grpc-store.so
uri="grpc://nbh-builder:50051?ca-cert=$pki/ca.crt&client-cert=$pki/client.crt&client-key=$pki/client.key&connect-timeout=300"
admin() { AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot AWS_REGION=eu-north-1 nix shell nixpkgs#awscli2 -c aws "$@"; }
ts() { date +%s.%N; }
log() { echo "$(date -Is) $*" | tee -a "$out/summary.txt"; }

AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/nbh-gate.credentials AWS_PROFILE=nbh-gate \
  "$gate" -backend aws -pki "$pki" -owner box-kernel -instance-types "$types" -max-price "$maxprice" \
  -machines-file "$out/machines" -machines-entry "$uri x86_64-linux - 1 1 big-parallel,benchmark" \
  -retry-hold 300s -boot-timeout 300s -max-session 55m >"$out/gate.log" 2>&1 &
gpid=$!
trap 'kill $gpid 2>/dev/null || true' EXIT
sleep 1
log "types=$types max-price=$maxprice abort_s=$abort_s"
t0=$(ts)
set +e
NIX_CONFIG="plugin-files = $DET_SO" "$DET_NIX" build --store "$uri" --eval-store auto --max-jobs 0 \
  --no-link --print-out-paths -L "$drv^*" >"$out/build.stdout" 2>"$out/build.log" &
bpid=$!
aborted=0
while kill -0 $bpid 2>/dev/null; do
  sleep 10
  el=$(awk "BEGIN{print int($(ts)-$t0)}")
  echo "$(date -Is) +${el}s $(df --output=avail -h / | tail -1) $(grep -c '^linux-cachyos.*>' "$out/build.log" 2>/dev/null) lines" >>"$out/progress.txt"
  if [ "$el" -ge "$abort_s" ]; then aborted=1; log "ABORT: build past ${abort_s}s"; kill $bpid; break; fi
done
wait $bpid; rc=$?
set -e
t1=$(ts)
log "build exit=$rc aborted=$aborted wall=$(awk "BEGIN{print $t1-$t0}") s"
id=$(grep -oE 'launched [^ ]+ as i-[0-9a-f]+' "$out/gate.log" | head -1 | awk '{print $4}')
log "instance=$id"
if [ "$rc" = 0 ] && [ "$aborted" = 0 ]; then
  t2=$(ts)
  set +e
  sudo -n env NIX_CONFIG="plugin-files = $DET_SO" "$DET_NIX" copy --from "$uri" --no-check-sigs \
    $(cat "$out/build.stdout") >"$out/copy.log" 2>&1
  crc=$?
  set -e
  log "copy-back exit=$crc wall=$(awk "BEGIN{print $(ts)-$t2}") s"
else
  log "skipping copy-back; terminating $id"
  [ -n "$id" ] && admin ec2 terminate-instances --instance-ids "$id" >/dev/null
fi
tb=$(ts)
while :; do
  st=$(admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "$(date -Is) $st" >>"$out/states.txt"
  case $st in shutting-down|terminated) break ;; esac
  if [ "$(awk "BEGIN{print int($(ts)-$t0)}")" -ge 3600 ]; then log "gate did not terminate; terminating"; admin ec2 terminate-instances --instance-ids "$id" >/dev/null; fi
  sleep 10
done
log "instance $st $(awk "BEGIN{print $(ts)-$tb}") s after build/copy ended"
admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone,LaunchTime,StateTransitionReason,SpotInstanceRequestId]' --output text | tee -a "$out/summary.txt"
