#!/usr/bin/env bash
# Builds the Archipelago bridge (cppmod/APConnector/src/ap_bridge.cpp) for Linux and runs it against a local server
# hosting a fresh Palworld seed: connect, slot data, scout, check, chat. Needs g++, libssl-dev and zlib1g-dev.
#   DEPS=<dir with apclientpp, wswrap, ap-soeclient> tools/bridge_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
deps=${DEPS:?set DEPS to a folder holding apclientpp, wswrap and ap-soeclient clones}
ap=${AP_DIR:-$(cd .. && pwd)/archipelago-0.6.8}
work=$(mktemp -d); trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT
s=$deps/ap-soeclient/subprojects
g++ -std=c++17 -O1 -DASIO_STANDALONE -DAP_NO_SCHEMA -I"$deps/apclientpp" -I"$deps/wswrap/include" \
  -I"$s/asio/include" -I"$s/websocketpp" -I"$s/json/include" -w \
  cppmod/APConnector/src/ap_bridge.cpp cppmod/APConnector/test/bridge_test.cpp -o "$work/bridge_test" -lssl -lcrypto -lz -pthread
mkdir -p "$work/players" "$work/out"
printf 'name: Tester\ngame: Palworld\nPalworld:\n  tower_count: 2\n' > "$work/players/t.yaml"
(cd apworld && find palworld -name __pycache__ -prune -o -type f -print | zip -q "$ap/custom_worlds/palworld.apworld" -@)
(cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 .venv/bin/python Generate.py --player_files_path "$work/players" \
   --outputpath "$work/out" --seed 7 < /dev/null > "$work/gen.log" 2>&1)
(cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 exec .venv/bin/python MultiServer.py --host 127.0.0.1 --port 38301 "$work"/out/*.zip \
   < /dev/null > "$work/server.log" 2>&1) & server=$!
sleep 8
"$work/bridge_test" ws://127.0.0.1:38301 Tester $((0x50A10000 + 1000 + 5))
