#!/usr/bin/env bash
# Runs mod/test/harness.lua: the mod's Lua against stand-ins for UE4SS, the game and the APConnector.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r mod/PalworldArchipelago "$work/mod"
printf 'server=localhost:38281\nslot=Tester\npassword=\n' > "$work/mod/config.txt"
lua5.4 mod/test/harness.lua "$work/mod"
