#!/usr/bin/env bash
# Builds the Archipelago bridge (cppmod/APConnector/src/ap_bridge.cpp) for Linux and runs it against a local server
# hosting a fresh Palworld seed: connect, slot data, scout, check, chat. Needs g++, libssl-dev and zlib1g-dev.
#   DEPS=<dir with apclientpp, wswrap, ap-soeclient> tools/bridge_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
deps=${DEPS:?set DEPS to a folder holding apclientpp, wswrap and ap-soeclient clones}
ap=${AP_DIR:-$(cd .. && pwd)/archipelago-0.6.8}
work=$(mktemp -d)
installed="$ap/custom_worlds/palworld.apworld"
# The test installs this repo's world; whatever was installed before is put back afterwards.
[ -f "$installed" ] && cp "$installed" "$work/installed.bak"
server=                                                    # (set once the server starts; the clean-up checks it)
LOG_LINES=20                                               # how much of each log a failed run prints
# On a failure, the generation's and the server's logs are printed before the work folder (and they) are deleted.
restore() {
  local status=$?
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    for log in "$work/gen.log" "$work/server.log"; do
      [ -f "$log" ] && { echo "--- the last $LOG_LINES lines of $(basename "$log"):"; tail -n "$LOG_LINES" "$log"; }
    done
  fi
  [ -f "$work/installed.bak" ] && cp "$work/installed.bak" "$installed"
  rm -rf "$work"
}
trap restore EXIT
s=$deps/ap-soeclient/subprojects
# The same defines and include paths as cppmod/APConnector/CMakeLists.txt (the Windows build); change both. -w: the
# dependencies' headers give hundreds of warnings.
g++ -std=c++17 -O1 -DASIO_STANDALONE -DAP_NO_SCHEMA -I"$deps/apclientpp" -I"$deps/wswrap/include" \
  -I"$s/asio/include" -I"$s/websocketpp" -I"$s/json/include" -w \
  cppmod/APConnector/src/ap_bridge.cpp cppmod/APConnector/src/event_lines.cpp cppmod/APConnector/src/lua_text.cpp \
  cppmod/APConnector/test/bridge_test.cpp \
  -o "$work/bridge_test" -lssl -lcrypto -lz -pthread
mkdir -p "$work/players" "$work/out"
printf 'name: Tester\ngame: Palworld\nPalworld:\n  tower_count: 2\n' > "$work/players/t.yaml"
mkdir -p "$ap/custom_worlds"
AP_DIR="$ap" "$ap/.venv/bin/python" tools/build_apworld.py "$ap/custom_worlds/palworld.apworld" > /dev/null
(cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 .venv/bin/python Generate.py --player_files_path "$work/players" \
   --outputpath "$work/out" --seed 7 < /dev/null > "$work/gen.log" 2>&1)
(cd "$ap" && SKIP_REQUIREMENTS_UPDATE=1 exec .venv/bin/python MultiServer.py --host 127.0.0.1 --port 38301 --hint_cost "${HINT_COST:-10}" "$work"/out/*.zip \
   < /dev/null > "$work/server.log" 2>&1) & server=$!
sleep 8
"$work/bridge_test" ws://127.0.0.1:38301 Tester $((0x50A10000 + 1000 + 5))
