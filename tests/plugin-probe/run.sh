#!/usr/bin/env bash
# run.sh prints how the nix-grpc-store client reacts to a gate that holds,
# resets, FINs or closes a connection before any TLS answer.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$work/ca.key" -out "$work/ca.crt" -subj /CN=probe -days 1 2>/dev/null
plugin=$(nix build --no-link --print-out-paths ../..#plugin)/nix-grpc-store.so
port=50199
for mode in hold rst fin close; do
  python3 listener.py "$mode" "$port" > "$work/$mode.srv" &
  srv=$!
  sleep 0.5
  t0=$(date +%s%N)
  rc=0
  timeout 60 /nix/var/nix/profiles/default/bin/nix store info --option plugin-files "$plugin" \
    --store "grpc://127.0.0.1:$port?ca-cert=$work/ca.crt&connect-timeout=20" > "$work/$mode.cli" 2>&1 || rc=$?
  echo "$mode: exit=$rc elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 )) accepts=$(wc -l < "$work/$mode.srv") last_error=$(grep -o 'last error: .*' "$work/$mode.cli" | tail -1)"
  kill "$srv"; wait "$srv" 2>/dev/null || true
done
