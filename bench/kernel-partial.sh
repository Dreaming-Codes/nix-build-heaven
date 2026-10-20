#!/usr/bin/env bash
# kernel-partial.sh DRV COMPILE_SECONDS OUTDIR
# Builds DRV from cache.nixos.org only (no xinux), lets the compile phase run
# for COMPILE_SECONDS after the first kbuild line, then stops the build. Every
# 2 s it records total and largest RSS of compiler/linker processes, kbuild
# lines seen, free RAM and free disk. Stops early if / drops under 6 GB free or MemAvailable under 1.5 GB.
# CORES (default 6) sets --cores, so make runs at -j$CORES.
set -u
drv=$1 limit=$2 out=$3
mkdir -p "$out"
: > "$out/samples.tsv"
echo -e "t_s\trss_sum_mb\trss_max_mb\tnprocs\tkbuild_lines\tmem_avail_mb\tdisk_free_gb" >> "$out/samples.tsv"
sudo -n env -i PATH="$PATH" HOME=/root nix build "$drv^out" --no-link -L \
  --max-jobs 1 --cores "${CORES:-6}" --option builders '' \
  --option substituters https://cache.nixos.org \
  > "$out/build.log" 2>&1 &
pid=$!
t0=$(date +%s) first=""
stop() { echo "stop: $1 at $(( $(date +%s) - t0 )) s" >> "$out/summary.txt"; sudo -n kill -INT "$pid"; sleep 10; sudo -n kill "$pid" 2>/dev/null; }
while kill -0 "$pid" 2>/dev/null; do
  t=$(( $(date +%s) - t0 ))
  read -r sum max n < <(ps -eo rss=,comm= | awk '$2 ~ /^(clang|ld\.lld|lld|rustc|pahole|llvm|objtool|cc1)/ {s+=$1; if($1>m)m=$1; c++} END{printf "%d %d %d\n", s/1024, m/1024, c}')
  k=$(grep -cE '> +(CC|AS|RUSTC|LD|AR|HOSTCC|BTF|MODPOST)' "$out/build.log")
  [ -z "$first" ] && [ "$k" -gt 0 ] && first=$t && echo "first kbuild line at $t s" >> "$out/summary.txt"
  ma=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  df_gb=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  echo -e "$t\t$sum\t$max\t$n\t$k\t$ma\t$df_gb" >> "$out/samples.tsv"
  if [ "$df_gb" -lt 6 ]; then stop "disk under 6 GB"; break; fi
  if [ "$ma" -lt 1500 ]; then stop "MemAvailable under 1.5 GB"; break; fi
  if [ -n "$first" ] && [ $(( t - first )) -ge "$limit" ]; then stop "time box"; break; fi
  sleep 2
done
wait "$pid"; echo "nix build exit $?" >> "$out/summary.txt"
