#!/usr/bin/env bash
# check.sh CHECK... builds flake checks with KVM on the shared box, where the
# daemon's own system-features lack kvm. Needs /dev/kvm readable by build users.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
for c in "$@"; do args+=(".#checks.x86_64-linux.$c"); done
exec sudo -n env -i PATH="$PATH" /nix/var/nix/profiles/default/bin/nix build -L --no-link --print-out-paths \
  --option system-features "benchmark big-parallel nixos-test uid-range kvm" "${args[@]}"
