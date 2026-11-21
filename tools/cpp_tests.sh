#!/usr/bin/env bash
# Runs the APConnector's Linux tests: the parts of the C++ mod that need no Unreal (cppmod/APConnector/test/), each
# built with g++ and run, then check_lua_api.sh (dllmain.cpp's function list, its registrations and the Lua mod's calls
# agree). CI runs this script; so can anyone with g++ and bash. Fails at the first test that fails.
#     tools/cpp_tests.sh
set -euo pipefail
cd "$(dirname "$0")/../cppmod/APConnector"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Builds one test from its sources with the flags every test shares, then runs it. Extra g++ flags come first.
build_and_run() {
    local name=$1
    shift
    echo "=== $name"
    g++ -std=c++17 -O1 -Isrc "$@" -o "$out/$name"
    "$out/$name"
}

# The map pictures' files, as cppmod/APConnector/CMakeLists.txt lists them; change both.
build_and_run image_test -pthread -Ithird_party/stb test/image_test.cpp src/lua_text.cpp \
    src/image_basics.cpp src/image_jobs.cpp src/image_grey_map.cpp src/image_chart.cpp src/image_land_sea.cpp \
    src/image_fog.cpp src/image_territories.cpp
# The Pal-gift logic: the half of pal_gift.cpp that needs no Unreal headers.
build_and_run pal_gift_test test/pal_gift_test.cpp src/pal_gift_logic.cpp src/lua_text.cpp
# How the connector reads the text Lua sends.
build_and_run lua_text_test test/lua_text_test.cpp src/lua_text.cpp
# The text the connector hands Lua for each thing the server sent.
build_and_run event_lines_test test/event_lines_test.cpp src/event_lines.cpp
echo "=== check_lua_api.sh"
test/check_lua_api.sh
echo "all C++ tests passed"
