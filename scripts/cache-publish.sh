#!/usr/bin/env bash
# cache-publish.sh BUILDER EXPECT PATH... runs after a build session: the
# builder pushes unsigned with its nbh-builder instance role; the signer here
# signs only EXPECT paths whose nar matches; gc runs daily.
set -euo pipefail
builder=${1:?usage: cache-publish.sh BUILDER EXPECT PATH...}
expect=${2:?usage: cache-publish.sh BUILDER EXPECT PATH...}
shift 2
repo=$(cd "$(dirname "$0")/.." && pwd)
secrets=${NBH_SECRETS:-/home/box/secrets}
state=${NBH_STATE:-$HOME/.local/state/nbh}
ssh=(${NBH_SSH:-ssh})
remote=${NBH_CACHE_REMOTE:-nbh-cache}
local_cache=${NBH_CACHE:-$(nix build --no-link --print-out-paths "$repo#nbh-cache")/bin/nbh-cache}
eval "$(nix eval --raw --file "$repo/nix/cache.nix" --apply 'c: "bucket=${c.bucket} region=${c.region} account=${c.account} upstream=(${toString c.upstream})"')"
common=(--bucket "$bucket" --region "$region" --aws-account "$account")
up=()
for u in "${upstream[@]}"; do up+=(--upstream "$u"); done

"${ssh[@]}" "$builder" "$remote" "${common[@]}" push "${up[@]}" --tmpdir /tmp "$@"
"$local_cache" "${common[@]}" --credentials-file "$secrets/nbh-cache-signer.credentials" --profile nbh-cache-signer \
  sign --secret-key-file "$secrets/nbh-cache-signing.sec" --expect "$expect"
"$local_cache" "${common[@]}" --credentials-file "$secrets/nbh-cache-gc.credentials" --profile nbh-cache-gc \
  gc --stamp "$state/cache-gc.stamp" --min-interval-hours 24
