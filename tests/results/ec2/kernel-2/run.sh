#!/usr/bin/env bash
# kernel-2/run.sh: one cold nbh-gate session on real EC2 that builds the
# DreamingDesk CachyOS LTO kernel (drv 61g9) in hook mode, the way the
# client hosts will: root nix with --store local, max-jobs 0 so nothing builds
# on the box, builders-use-substitutes so the builder fetches inputs from
# cache.nixos.org itself, substituters pinned without xinux. Outputs come back
# through the gate as part of the hook. Guards: abort and terminate past
# ABORT_S or when the box has under MIN_FREE_KB free.
set -euo pipefail
out=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$out/../../../.." && pwd)
pki=/home/box/secrets/nbh-pki
drv=/nix/store/61g9nhv4i4ywv34w53aw10z3q20rgy6k-linux-cachyos-latest-lto-x86_64-v3-7.2.8.drv
types=${NBH_TYPES:?}
maxprice=${NBH_MAX_PRICE:?}
abort_s=${ABORT_S:-2700}
min_free_kb=${MIN_FREE_KB:-800000}
gate=$(nix build --no-link --print-out-paths "$repo#gate")/bin/nbh-gate
"$gate" pki-init "$pki" box-smoke
DET_NIX=/nix/var/nix/profiles/default/bin/nix
DET_SO=$(readlink -f /workspace/nbh/proof/res-det2)/lib/nix/nix-grpc-store-versions/2.35.3/nix-grpc-store.so
uri="grpc://nbh-builder:50051?ca-cert=$pki/ca.crt&client-cert=$pki/client.crt&client-key=$pki/client.key&connect-timeout=300"
entry="$uri x86_64-linux - 8 1 big-parallel,benchmark"
admin() { AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot AWS_REGION=eu-north-1 nix shell nixpkgs#awscli2 -c aws "$@"; }
ts() { date +%s.%N; }
log() { echo "$(date -Is) $*" | tee -a "$out/summary.txt"; }

AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/nbh-gate.credentials AWS_PROFILE=nbh-gate \
  "$gate" -backend aws -pki "$pki" -owner box-kernel -instance-types "$types" -max-price "$maxprice" \
  -machines-file "$out/machines" -machines-entry "$entry" \
  -retry-hold 300s -boot-timeout 300s -max-session 55m >"$out/gate.log" 2>&1 &
gpid=$!
trap 'kill $gpid 2>/dev/null || true' EXIT
sleep 1
log "types=$types max-price=$maxprice abort_s=$abort_s free_kb=$(df --output=avail / | tail -1)"
t0=$(ts)
set +e
sudo -n env NIX_CONFIG="plugin-files = $DET_SO" "$DET_NIX" build --store local --max-jobs 0 \
  --option substituters 'https://cache.nixos.org https://install.determinate.systems' \
  --builders-use-substitutes --builders "$entry" \
  --no-link --print-out-paths -L "$drv^*" >"$out/build.stdout" 2>"$out/build.log" &
bpid=$!
aborted=0
while kill -0 $bpid 2>/dev/null; do
  sleep 10
  el=$(awk "BEGIN{print int($(ts)-$t0)}")
  free=$(df --output=avail / | tail -1)
  echo "$(date -Is) +${el}s free_kb=$free log_lines=$(wc -l <"$out/build.log")" >>"$out/progress.txt"
  if [ "$el" -ge "$abort_s" ]; then aborted=1; log "ABORT: build past ${abort_s}s"; fi
  if [ "$free" -lt "$min_free_kb" ]; then aborted=1; log "ABORT: box free ${free} KB"; fi
  if [ "$aborted" = 1 ]; then sudo -n pkill -INT -f -- "--builders-use-substitutes --builders grpc://nbh-builder"; sleep 5; break; fi
done
wait $bpid; rc=$?
set -e
t1=$(ts)
log "build exit=$rc aborted=$aborted wall=$(awk "BEGIN{print $t1-$t0}") s free_kb=$(df --output=avail / | tail -1)"
id=$(grep -oE 'launched [^ ]+ as i-[0-9a-f]+' "$out/gate.log" | head -1 | awk '{print $4}')
log "instance=$id"
if [ "$rc" != 0 ] || [ "$aborted" = 1 ]; then
  log "build failed or aborted; terminating $id"
  [ -n "$id" ] && admin ec2 terminate-instances --instance-ids "$id" >/dev/null
fi
tb=$(ts)
while [ -n "$id" ]; do
  st=$(admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "$(date -Is) $st" >>"$out/states.txt"
  case $st in shutting-down|terminated) break ;; esac
  if [ "$(awk "BEGIN{print int($(ts)-$tb)}")" -ge 400 ]; then log "gate did not terminate in 400 s; terminating"; admin ec2 terminate-instances --instance-ids "$id" >/dev/null; fi
  sleep 10
done
log "instance $st $(awk "BEGIN{print $(ts)-$tb}") s after the build ended"
admin ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].[InstanceType,Placement.AvailabilityZone,LaunchTime,StateTransitionReason,SpotInstanceRequestId]' --output text | tee -a "$out/summary.txt"
