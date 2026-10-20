#!/usr/bin/env bash
# check.sh CHECK... builds flake checks on the shared box, where the daemon's
# own system-features lack kvm. The box kernel (6.12.94+, nested VMX) hits
# "kernel BUG at arch/x86/kvm/x86.c:702" on KVM_CREATE_VCPU, which leaves qemu
# hung forever in qemu_init_vcpu. So /dev/kvm must stay closed to build users:
# qemu's accel=kvm:tcg then falls back to TCG, slow but correct.
# Evaluation runs as the invoking user, because root's libgit2 refuses a
# repository it does not own; only the build of the .drv files runs as root,
# the one trusted user that may override system-features.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /dev/kvm && $(stat -c %a /dev/kvm) == *6 ]]; then
  echo "check.sh: /dev/kvm is world-writable; VM tests would hang on this box's broken nested KVM. Run: sudo chmod 0660 /dev/kvm" >&2
  exit 1
fi
NIX=/nix/var/nix/profiles/default/bin/nix
drvs=()
for c in "$@"; do
  drvs+=("$("$NIX" eval --raw ".#checks.x86_64-linux.$c.drvPath")^*")
done
exec sudo -n env -i PATH="$PATH" "$NIX" build -L --no-link --print-out-paths \
  --option system-features "benchmark big-parallel nixos-test uid-range kvm" "${drvs[@]}"
