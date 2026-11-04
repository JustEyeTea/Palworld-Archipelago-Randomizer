#!/usr/bin/env bash
# Builds the APWorld and generates test seeds with a local Archipelago 0.6.8, checking each one is beatable.
#   tools/test_generate.sh [seeds]                         e.g. tools/test_generate.sh 5
#   EXTRA_OPTIONS='tower_count: 8' tools/test_generate.sh 3   (extra lines under Palworld:)
# AP_DIR defaults to ../archipelago-0.6.8 (with a venv in .venv).
set -euo pipefail
cd "$(dirname "$0")/.."
seeds=${1:-3}
ap=${AP_DIR:-$(cd .. && pwd)/archipelago-0.6.8}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$ap/custom_worlds" "$work/players" "$work/out"
# Packed as players get it (tools/build_apworld.py), so the world loads with its own version.
AP_DIR="$ap" "$ap/.venv/bin/python" tools/build_apworld.py "$work/palworld.apworld" > /dev/null
cp "$work/palworld.apworld" "$ap/custom_worlds/palworld.apworld"
{ printf 'name: Tester\ngame: Palworld\nPalworld:\n  progression_balancing: 50\n'
  [ -n "${EXTRA_OPTIONS:-}" ] && printf '  %s\n' "$EXTRA_OPTIONS"; } > "$work/players/test.yaml"
fails=0
for seed in $(seq 1 "$seeds"); do
  rm -rf "$work/out"/*
  if ! (cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 timeout 600 .venv/bin/python Generate.py \
          --player_files_path "$work/players" --outputpath "$work/out" --seed "$seed" --spoiler 2 \
          < /dev/null > "$work/log" 2>&1); then
    echo "seed $seed: GENERATION FAILED"; grep -v zilliandomizer "$work/log" | tail -8; fails=$((fails+1)); continue
  fi
  spoiler=$(cd "$work/out" && python3 -I -c 'import zipfile,glob; z=zipfile.ZipFile(glob.glob("*.zip")[0]); print(z.read([n for n in z.namelist() if n.endswith("_Spoiler.txt")][0]).decode())')
  spheres=$(printf '%s\n' "$spoiler" | grep -c -E '^[0-9]+: \{' || true)
  if printf '%s\n' "$spoiler" | grep -q 'Goal Complete'; then echo "seed $seed: ok ($spheres spheres)"
  else echo "seed $seed: NO GOAL IN PLAYTHROUGH"; fails=$((fails+1)); fi
  [ "$seed" = 1 ] && printf '%s\n' "$spoiler" > "$work/../palworld_spoiler_seed1.txt" || true
done
[ "$fails" -eq 0 ] && echo "all $seeds seeds beatable" || { echo "$fails of $seeds failed"; exit 1; }
