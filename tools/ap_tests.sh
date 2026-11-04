#!/usr/bin/env bash
# Runs Archipelago's own test suites (general, options, multiworld, programs, webhost) for this world: the checks
# every world is expected to pass (ids, names and groups, fill, manifest, docs pages...). Then the world's own tests
# (apworld/palworld/test: logic, options, frozen ids).
# Needs pytest, pytest-subtests and WebHostLib/requirements.txt in the Archipelago venv.
#   tools/ap_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ap=${AP_DIR:-$(cd .. && pwd)/archipelago-0.6.8}
installed="$ap/custom_worlds/palworld.apworld"
# The tests run the world from a source folder; an installed .apworld would register twice.
trap 'rm -rf "$ap/worlds/palworld"; [ -f "$installed.bak" ] && mv "$installed.bak" "$installed"' EXIT
[ -f "$installed" ] && mv "$installed" "$installed.bak"
rm -rf "$ap/worlds/palworld" && cp -r apworld/palworld "$ap/worlds/" && rm -rf "$ap/worlds/palworld/__pycache__"
cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 AP_TEST_WORLDS=palworld .venv/bin/python -m pytest \
  test/general test/options test/multiworld test/programs test/webhost worlds/palworld/test -q -p no:cacheprovider --continue-on-collection-errors
