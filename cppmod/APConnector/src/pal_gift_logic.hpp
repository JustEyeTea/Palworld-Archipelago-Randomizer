// The parts of giving a Pal (pal_gift.cpp) that need no Unreal headers: reading AP_GivePal's arguments, choosing the
// route, the report text and its result words, and the pending gift's bookkeeping.
// Tests: test/pal_gift_test.cpp (in CI, step "The C++ part's Pal-gift logic").
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace pal_gift
{
    // How the Pal is made (see pal_gift.cpp for what each one calls):
    //   party_debug  CreateIndividual with the party's OnSpawnDebugOtomoCallback_ServerInternal (group, EXP, then
    //                party)
    //   party_plain  CreateIndividual with OnSpawnOtomoCallback_ServerInternal (party only)
    //   handle       CreateIndividual with no callback, then AddOtomoHandleToFreeSlot
    //   palbox       the Global Palbox import into an empty Palbox slot
    //   auto         party_debug while the party has room, else palbox
    enum class Route
    {
        Auto,
        PartyDebug,
        PartyPlain,
        Handle,
        Palbox
    };
    // The route's name as Lua passes it ("party_debug").
    auto route_name(Route route) -> const char*;

    constexpr int MIN_LEVEL = 1;
    constexpr int MAX_LEVEL = 65;

    struct Request
    {
        std::string species;      // the Pal's row name in DT_PalMonsterParameter ("Anubis")
        int level{MIN_LEVEL};
        Route route{Route::Auto};
        bool rare{};              // RarePalAble
        bool nopassive{};         // DisableRandomPassiveSkill
    };

    // Reads AP_GivePal's text arguments. An empty level means 1, an empty route means auto. Returns "" and fills out,
    // or the reason for the report's fail line ("bad level 'x'").
    auto parse_request(const std::string& species, const std::string& level, const std::string& route,
                       const std::string& options, Request& out) -> std::string;

    // The route actually taken: auto becomes party_debug while the party has room, palbox when it is full.
    auto choose_route(Route requested, int party_count, int party_max) -> Route;

    // An FGuid's size: four uint32. PlayerUId and FPalInstanceID's two halves are FGuids.
    constexpr int GUID_BYTES = 16;

    // A 16-byte FGuid (four little-endian uint32 A, B, C, D) as "AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD".
    auto format_guid(const uint8_t* guid) -> std::string;
    // Whether all 16 bytes are zero (no player, or an id not made yet).
    auto guid_is_zero(const uint8_t* guid) -> bool;

    // The report's result words, its last line being "result: <word>". test_tools.lua matches "result: pending" and
    // "result: busy" exactly (pal_gift_test checks them); a fail is "fail <reason>", from fail_result.
    constexpr auto RESULT_OK_PARTY = "ok party";
    constexpr auto RESULT_OK_PALBOX = "ok palbox";
    constexpr auto RESULT_PENDING = "pending";
    constexpr auto RESULT_BUSY = "busy";
    auto fail_result(const std::string& reason) -> std::string;

    // A report: lines of "step: detail", the last always "result: ok party|ok palbox|pending|busy|fail <reason>".
    // Lua reads the last line for logic and logs the rest. Each line also goes to the sink as it is added (the C++
    // mirrors them into UE4SS.log), so if the game dies inside a step the log still names the step it was in.
    class Report
    {
      public:
        explicit Report(std::function<void(const std::string&)> sink = {}) : m_sink(std::move(sink)) {}
        auto line(const std::string& text) -> void;
        // Adds "result: <result>" and returns the whole report.
        auto finish(const std::string& result) -> std::string;

      private:
        std::function<void(const std::string&)> m_sink;
        std::vector<std::string> m_lines;
    };

    // A gift the game had not finished when AP_GivePal returned. One at a time; AP_GivePalPoll looks for it. It holds
    // plain values only (no object pointers, no engine strings), so nothing in it can dangle across a world change or
    // need the engine to free it.
    struct PendingGift
    {
        Route route{Route::PartyDebug};
        bool has_id{};                 // the new Pal's FPalInstanceID was readable when the create returned
        uint8_t id_player[GUID_BYTES]{};     // FPalInstanceID.PlayerUId
        uint8_t id_instance[GUID_BYTES]{};   // FPalInstanceID.InstanceId
        int slot_index{-1};            // palbox: the slot the import was sent to
        int count_before{};            // the party count before the create
        uintptr_t controller{};        // the local player controller then: another one means the world changed (a
                                       // respawn makes a new pawn but keeps the controller)
        int polls{};
    };

    // Whether a party gift counts as arrived because the party grew: only when the create gave no id to look for it
    // by. A gift with an id is matched by its id alone: moving a Pal from the Palbox, or a capture, grows the party
    // too.
    auto arrived_by_count(bool has_id, int count_before, int count_now) -> bool;

    // About 6 s: test_tools.lua polls once per core update, every UTIL.UPDATE_MS (300 ms, util.lua). If that rate
    // changes, so does this timeout.
    constexpr int MAX_POLLS = 20;

    // Where the player stood when a poll looked for the gift (pal_gift.cpp, player_at_poll):
    //   Here          the same player controller as at the gift, with a pawn and a party to look in
    //   BetweenPawns  the same controller with no pawn to read (fainted, respawning): the game can still finish the
    //                 gift once the player has a pawn again
    //   Gone          no controller, or another one (a world load makes a new one): the gift can no longer arrive
    enum class PlayerAtPoll
    {
        Here,
        BetweenPawns,
        Gone
    };

    enum class PollVerdict
    {
        Wait,
        Ok,
        Timeout,
        Dropped
    };
    // Counts one poll. Here: Ok once the Pal was seen, Timeout after MAX_POLLS polls without it, else Wait.
    // BetweenPawns: Wait, not counted, so time spent respawning does not use up the gift's polls. Gone: Dropped.
    auto next_poll(PendingGift& gift, PlayerAtPoll player, bool seen) -> PollVerdict;
} // namespace pal_gift
