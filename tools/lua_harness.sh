#!/usr/bin/env bash
# Runs mod/test/harness.lua: the mod's Lua against stand-ins for UE4SS, the game and the APConnector.
# Twice: as a player runs it (no probe), and with the performance probe and its test hotkeys on (perf_log=1,
# test_tools=1), so every test also shows the probe changes nothing. Fails if either run fails.
set -euo pipefail
cd "$(dirname "$0")/.."
run() {
    local mode=$1 extra=$2
    local work
    work=$(mktemp -d)
    cp -r mod/PalworldArchipelago "$work/mod"
    printf 'server=localhost:38281\nslot=Tester\npassword=\nwall_radius=0\n%b' "$extra" > "$work/mod/config.txt"
    echo "=== harness: $mode"
    local status=0
    lua5.4 mod/test/harness.lua "$work/mod" "$mode" || status=$?
    rm -rf "$work"
    return $status
}
run plain ''
run perf 'perf_log=1\ntest_tools=1\n'
