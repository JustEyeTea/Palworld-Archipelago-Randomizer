// Giving the player a Pal, for the Lua mod (AP_GivePal, AP_GivePalPoll). UE4SS's Lua can't make the call itself: it
// passes parameters in a fixed 0x200-byte stack buffer, and a Pal's save data (0x370 bytes) overran it and crashed the
// game. Here each game function gets a heap parameter block of its own size. See pal_gift.cpp, which also says which
// routes have worked in game.
#pragma once

#include <string>

// Makes a Pal of `species` (DT_PalMonsterParameter row name) at `level` ("1".."65") by `route` (auto, party_debug,
// party_plain, handle, palbox; see pal_gift_logic.hpp) with `options` ("rare,nopassive"). Returns a report, one step per
// line; the last line is always "result: ok party|ok palbox|pending|busy|fail <reason>". Never throws. Game thread only.
auto give_pal(const std::string& species, const std::string& level, const std::string& route, const std::string& options)
        -> std::string;

// While a gift is pending: looks for it and returns a report ending like give_pal's. "" when nothing is pending.
auto give_pal_poll() -> std::string;
