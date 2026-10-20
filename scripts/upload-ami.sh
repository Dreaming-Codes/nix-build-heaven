#!/usr/bin/env bash
# upload-ami.sh IMAGE_RESULT writes the raw builder image to an EBS snapshot
# with coldsnap (EBS direct API: no S3 bucket, no vmimport round trip) and
# prints `snapshot_id image_name` for scripts/tofu.sh apply -var ...
set -euo pipefail
res=${1:?usage: upload-ami.sh RESULT_DIR}
info=$res/nix-support/image-info.json
img=$(jq -r .file "$info")
label=$(jq -r .label "$info")
name="nbh-builder-$label-$(basename "$(dirname "$img")" | cut -c1-8)"
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/home/box/secrets/aws-grok-bot.credentials}
export AWS_PROFILE=${AWS_PROFILE:-grok-bot} AWS_REGION=${AWS_REGION:-eu-north-1}
start=$(date +%s)
snap=$(nix shell nixpkgs#coldsnap -c coldsnap --region "$AWS_REGION" upload --wait \
  --description "$name" "$img" | tail -n1)
nix shell nixpkgs#awscli2 -c aws ec2 create-tags --resources "$snap" \
  --tags Key=nbh:managed,Value=true Key=Name,Value="$name"
echo "upload took $(( $(date +%s) - start )) s" >&2
echo "$snap $name"
