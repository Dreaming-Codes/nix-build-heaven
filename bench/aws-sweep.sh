#!/usr/bin/env bash
# Lists live instances, volumes and open Spot requests in every region of the admin account.
set -euo pipefail
aws=$(nix build --no-link --print-out-paths nixpkgs#awscli2)/bin/aws
export AWS_SHARED_CREDENTIALS_FILE=/home/box/secrets/aws-grok-bot.credentials AWS_PROFILE=grok-bot
echo "account $($aws sts get-caller-identity --query Account --output text --region eu-north-1)"
for r in $($aws ec2 describe-regions --region eu-north-1 --query 'Regions[].RegionName' --output text); do
  i=$($aws ec2 describe-instances --region "$r" --filters Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType]' --output text)
  v=$($aws ec2 describe-volumes --region "$r" --query 'Volumes[].[VolumeId,State,Size]' --output text)
  s=$($aws ec2 describe-spot-instance-requests --region "$r" --filters Name=state,Values=open,active --query 'SpotInstanceRequests[].[SpotInstanceRequestId,State]' --output text)
  echo "$r instances=$(grep -c . <<<"$i" || true) volumes=$(grep -c . <<<"$v" || true) spot_requests=$(grep -c . <<<"$s" || true)"
  [ -z "$i$v$s" ] || printf '%s\n%s\n%s\n' "$i" "$v" "$s" | sed '/^$/d; s/^/  /'
done
