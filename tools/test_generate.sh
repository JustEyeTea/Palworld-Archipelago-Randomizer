#!/usr/bin/env bash
# Builds the APWorld and generates test seeds with a local Archipelago, checking each one is beatable.
#   tools/test_generate.sh [seeds]                         e.g. tools/test_generate.sh 5
#   EXTRA_OPTIONS='tower_count: 8' tools/test_generate.sh 3   (extra lines under Palworld:)
# AP_DIR: your Archipelago folder (with a venv in .venv). Without it, archipelago-<version> beside this repository's
# folder, the version being the APWorld's minimum_ap_version (wrong in a git worktree).
# Seed 1's spoiler is kept as $SPOILER_COPY (default: palworld_spoiler_seed1.txt in the temp folder), to read after.
set -euo pipefail
cd "$(dirname "$0")/.."
seeds=${1:-3}
ap=${AP_DIR:-$(tools/ap_dir.sh)}
spoiler_copy=${SPOILER_COPY:-${TMPDIR:-/tmp}/palworld_spoiler_seed1.txt}
generation_timeout=600                                     # seconds one seed may take
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The spoiler log inside the one seed zip in the output folder.
seed_spoiler() {
  (cd "$work/out" && python3 -I -c 'import glob, zipfile
seed = zipfile.ZipFile(glob.glob("*.zip")[0])
print(seed.read([n for n in seed.namelist() if n.endswith("_Spoiler.txt")][0]).decode())')
}

mkdir -p "$ap/custom_worlds" "$work/players" "$work/out"
# Packed as players get it (tools/build_apworld.py), so the world loads with its own version.
AP_DIR="$ap" "$ap/.venv/bin/python" tools/build_apworld.py "$work/palworld.apworld" > /dev/null
cp "$work/palworld.apworld" "$ap/custom_worlds/palworld.apworld"
{ printf 'name: Tester\ngame: Palworld\nPalworld:\n  progression_balancing: 50\n'
  [ -n "${EXTRA_OPTIONS:-}" ] && printf '  %s\n' "$EXTRA_OPTIONS"; } > "$work/players/test.yaml"
fails=0
for seed in $(seq 1 "$seeds"); do
  rm -rf "$work/out"/*
  if ! (cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 timeout "$generation_timeout" .venv/bin/python Generate.py \
          --player_files_path "$work/players" --outputpath "$work/out" --seed "$seed" --spoiler 2 \
          < /dev/null > "$work/log" 2>&1); then
    echo "seed $seed: GENERATION FAILED"
    grep -v zilliandomizer "$work/log" | tail -8
    fails=$((fails + 1))
    continue
  fi
  spoiler=$(seed_spoiler)
  spheres=$(printf '%s\n' "$spoiler" | grep -c -E '^[0-9]+: \{' || true)
  if printf '%s\n' "$spoiler" | grep -q 'Goal Complete'; then
    echo "seed $seed: ok ($spheres spheres)"
  else
    echo "seed $seed: NO GOAL IN PLAYTHROUGH"
    fails=$((fails + 1))
  fi
  if [ "$seed" = 1 ]; then
    printf '%s\n' "$spoiler" > "$spoiler_copy" || echo "could not keep seed 1's spoiler as $spoiler_copy"
  fi
done
if [ "$fails" -eq 0 ]; then
  echo "all $seeds seeds beatable"
else
  echo "$fails of $seeds failed"
  exit 1
fi
