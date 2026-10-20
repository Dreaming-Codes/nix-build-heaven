#!/usr/bin/env bash
# tofu.sh ARGS... runs OpenTofu on the terranix config with local state kept
# outside git, in a 0700 directory, because the state holds nbh-gate's secret
# access key. Provisioning credentials come from the grok-bot admin profile.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
state=${NBH_TOFU_DIR:-/home/box/secrets/nbh-tofu}
umask 077
mkdir -p "$state"
chmod 700 "$state"
cfg=$(nix build --no-link --print-out-paths "$repo#infra")
install -m 600 "$cfg" "$state/config.tf.json"
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/home/box/secrets/aws-grok-bot.credentials}
export AWS_PROFILE=${AWS_PROFILE:-grok-bot} AWS_REGION=${AWS_REGION:-eu-north-1}
cd "$state"
exec nix shell nixpkgs#opentofu -c tofu "$@"
