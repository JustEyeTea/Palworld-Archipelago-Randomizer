#!/usr/bin/env bash
# Checks that dllmain.cpp's header lists exactly the AP_* functions it registers, and that every AP_* name the Lua
# mod uses is registered, apart from the game-side names below. Run by CI ("The C++ part's function list"); by hand:
#   cppmod/APConnector/test/check_lua_api.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
dllmain=cppmod/APConnector/src/dllmain.cpp
lua_mod=mod/PalworldArchipelago/Scripts

# Names that share the AP_ prefix but belong to the game side, not the connector: the mailbox row's Blueprint event
# (mailbox.lua), the mailbox's no-deposit marker (mailbox.lua), the shop card's widget name (main.lua) and the Slow
# Trap's key (traps.lua). A new one goes here, with where it lives.
GAME_SIDE_NAMES="AP_Clicked AP_MailboxGivesOnly AP_ShopSlot AP_SlowTrap"

names() { grep -oE '\bAP_[A-Za-z]+\b' | sort -u; }
listed=$(sed '/^#include/,$d' "$dllmain" | names)
registered=$(grep -oE 'register_text<[a-z_]+>\(lua, "AP_[A-Za-z]+"\)' "$dllmain" | names)
used=$(cat "$lua_mod"/*.lua | names | grep -vxF -f <(tr ' ' '\n' <<< "$GAME_SIDE_NAMES"))

failed=0
# Prints the names in the first list that the second lacks, under a heading; counts a failure if there are any.
report_missing() {
  local heading=$1 missing
  missing=$(comm -23 <(echo "$2") <(echo "$3"))
  if [ -n "$missing" ]; then
    echo "FAIL $heading:" $missing
    failed=1
  fi
}
report_missing "registered in $dllmain but not in its header" "$registered" "$listed"
report_missing "in $dllmain's header but not registered" "$listed" "$registered"
report_missing "used by the Lua mod but not registered (or add it to GAME_SIDE_NAMES)" "$used" "$registered"
[ "$failed" = 0 ] && echo "ok   $(echo "$registered" | wc -l) functions: header, registrations and the Lua mod agree"
exit "$failed"
