// The world map screen, changed from C++ inside the game's own call that sets it up, so the player never sees the
// game's version first, as they do when Lua swaps it. Lua says what to show; this applies it in the screen's Setup,
// before the screen draws.
// Tests: none (it needs Unreal; only CI's Windows build compiles map_screen.cpp).
#pragma once

#include <string>

namespace map_screen
{
    // From Lua (any thread). cmd:
    //   "body", path     the picture the main world's map shows (an object path; "" = the game's own)
    //   "fog", "r,g,b,a" the exploration fog's colour in linear light ("" = the game's own)
    //   "fogpic", path   the fog image shows this fog picture instead of the game's fog (the chart, or the
    //                    Territories' fog art; "" = none; forgotten when the world's map screen goes, so send it again
    //                    for the next world)
    //   "enable", "1"    act on Setup at all ("0": the screen is left to the game; off until Lua says)
    //   "status"         a one-line summary for Lua's log (what was hooked, how often Setup ran, what was applied)
    // Returns "" or the status line; for any other cmd "unknown command <cmd>", also logged (once per cmd).
    auto command(const std::string& cmd, const std::string& value) -> std::string;

    // From the mod once Unreal is up: hooks the map screen's Setup (retried on the game thread until its class loads).
    auto install() -> void;
} // namespace map_screen
