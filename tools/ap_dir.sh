#!/usr/bin/env bash
# Prints the Archipelago folder the test scripts use when AP_DIR is not set: archipelago-<version> beside this
# repository's folder, the version being the APWorld's minimum_ap_version (apworld/palworld/archipelago.json), the
# one place it is kept. Wrong in a git worktree, which is not beside the Archipelago folder: set AP_DIR there.
#   ap=${AP_DIR:-$(tools/ap_dir.sh)}
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
version=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["minimum_ap_version"])' \
            "$repo/apworld/palworld/archipelago.json")
echo "$(dirname "$repo")/archipelago-$version"
