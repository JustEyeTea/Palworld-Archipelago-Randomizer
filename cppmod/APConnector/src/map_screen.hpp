// The world map screen, changed from C++ inside the game's own call that sets it up, so the player never sees the
// game's version first (the user, 2026-11-06: Lua's swaps show; "this would be better done as a C++ mod"). Lua says
// what to show; this applies it in the screen's Setup, before the screen draws.
#pragma once

#include <string>

namespace map_screen
{
    // From Lua (any thread). cmd:
    //   "body", path     the picture the main world's map shows (an object path; "" = the game's own)
    //   "fog", "r,g,b,a" the exploration fog's colour in linear light ("" = the game's own)
    //   "fogpic", path   the fog image shows this picture instead of the game's fog (the explorer's chart; "" = none)
    //   "enable", "1"    act on Setup at all ("0": the screen is left to the game; off until Lua says)
    //   "status"         a one-line summary for Lua's log (what was hooked, how often Setup ran, what was applied)
    // Returns "" or the status line.
    auto command(const std::string& cmd, const std::string& value) -> std::string;

    // From the mod once Unreal is up: hooks the map screen's Setup (retried on the game thread until its class loads).
    auto install() -> void;
} // namespace map_screen
