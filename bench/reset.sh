#!/usr/bin/env bash
# reset.sh TOBUILD_TXT: delete local outputs of a recorded cache-miss set so the
# next nbh-bench run rebuilds exactly that set.
set -euo pipefail
NIX=${NIX:-/nix/var/nix/profiles/default/bin/nix}
mapfile -t outs < <("$NIX" derivation show $(sed 's/$/^*/' "$1") | python3 -c '
import json, sys
for v in json.load(sys.stdin)["derivations"].values():
    for o in v["outputs"].values():
        if "path" in o:
            print("/nix/store/" + o["path"])
')
present=()
for o in "${outs[@]}"; do [ -e "$o" ] && present+=("$o"); done
if [ ${#present[@]} -gt 0 ]; then
  sudo -n env -i "$NIX" store delete "${present[@]}"
fi
echo "reset: ${#present[@]} of ${#outs[@]} outputs deleted"
