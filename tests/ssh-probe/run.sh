#!/usr/bin/env bash
# run.sh prints how Determinate Nix's ssh-ng client reacts to a gate that holds,
# resets, FINs or closes a connection, and to one that holds through a 30 s
# "boot" and then splices to a real sshd. The sshd runs unprivileged on the box
# as the invoking user, so its remote `nix-daemon --stdio` talks to the box daemon.
# Only `nix store info` is run: it goes through the same openStore + connect()
# that build-remote calls before it accepts a build.
set -euo pipefail
cd "$(dirname "$0")"
NIX=/nix/var/nix/profiles/default/bin/nix
ssh=$($NIX build --no-link --print-out-paths --inputs-from ../.. nixpkgs#openssh.out)/bin
export PATH=$ssh:$(dirname "$(readlink -f $NIX)"):$PATH
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$work/host" && ssh-keygen -q -t ed25519 -N '' -f "$work/client"
cp "$work/client.pub" "$work/authorized_keys"
echo "[127.0.0.1]:52199 $(cut -d' ' -f1,2 "$work/host.pub")" > "$work/known_hosts"
cat > "$work/sshd_config" <<CFG
Port 52298
ListenAddress 127.0.0.1
HostKey $work/host
AuthorizedKeysFile $work/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $work/sshd.pid
SetEnv PATH=$PATH
CFG
"$ssh/sshd" -D -f "$work/sshd_config" -E "$work/sshd.log" &
sleep 0.5
export NIX_SSHOPTS="-F /dev/null -i $work/client -o UserKnownHostsFile=$work/known_hosts -o BatchMode=yes"
uri="ssh-ng://$(id -un)@127.0.0.1:52199?remote-program=$(dirname "$(readlink -f $NIX)")/nix-daemon"
probe() { # probe MODE TIMEOUT [UP BOOT] [EXTRA_SSHOPTS]
  local mode=$1 to=$2 up=${3:-} boot=${4:-} extra=${5:-}
  python3 listener.py "$mode" 52199 $up $boot > "$work/$mode.srv" &
  local srv=$!
  sleep 0.3
  local t0 rc=0
  t0=$(date +%s%N)
  NIX_SSHOPTS="$NIX_SSHOPTS $extra" timeout "$to" $NIX store info --store "$uri" > "$work/$mode.cli" 2>&1 || rc=$?
  echo "$mode${extra:+ [$extra]}: exit=$rc elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 )) accepts=$(grep -c accept "$work/$mode.srv") splices=$(grep -c splice "$work/$mode.srv") out=$(tr '\n' ' ' < "$work/$mode.cli" | cut -c1-200)"
  kill "$srv"; wait "$srv" 2>/dev/null || true
}
socat=$($NIX build --no-link --print-out-paths --inputs-from ../.. nixpkgs#socat)/bin/socat
refused() { # nothing listens on the gate port: ssh's ConnectionAttempts retries a refused connect once a second
  local t0 rc=0
  t0=$(date +%s%N)
  NIX_SSHOPTS="$NIX_SSHOPTS $1" timeout 60 $NIX store info --store "$uri" > "$work/refused.cli" 2>&1 || rc=$?
  echo "refused [$1]: exit=$rc elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 )) out=$(tr '\n' ' ' < "$work/refused.cli" | cut -c150-330)"
}
[[ ${1:-} == extra ]] || {
probe rst 60
probe fin 60
probe close 60
probe hold 45
probe hold 45 "" "" "-o ConnectTimeout=10"
probe boot 90 52298 30
probe boot 90 52298 30 "-o ConnectTimeout=10"
probe boot 90 52298 30 "-o ConnectionAttempts=20"
}
refused ""
refused "-o ConnectionAttempts=5"
# A ProxyCommand that blocks for a 30 s boot and then pipes: ssh simply waits on the pipe.
t0=$(date +%s%N); rc=0
NIX_SSHOPTS="$NIX_SSHOPTS -o ProxyCommand=\"sh -c 'sleep 30; exec $socat - TCP:127.0.0.1:52298'\"" timeout 90 $NIX store info --store "$uri" > "$work/proxy.cli" 2>&1 || rc=$?
echo "proxycommand sleep 30 then pipe: exit=$rc elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 )) out=$(tr '\n' ' ' < "$work/proxy.cli" | cut -c150-260)"
