// The parts of giving a Pal (pal_gift.cpp) that need no Unreal headers: reading AP_GivePal's arguments, choosing the
// route, the report text and the pending gift's bookkeeping. Tested on Linux by test/pal_gift_test.cpp.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace pal_gift
{
    // How the Pal is made (see pal_gift.cpp for what each one calls):
    //   party_debug  CreateIndividual with the party's OnSpawnDebugOtomoCallback_ServerInternal (group, EXP, then party)
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

    // A 16-byte FGuid (four little-endian uint32 A, B, C, D) as "AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD".
    auto format_guid(const uint8_t* guid) -> std::string;
    auto guid_is_zero(const uint8_t* guid) -> bool;

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
        uint8_t id_player[16]{};       // FPalInstanceID.PlayerUId
        uint8_t id_instance[16]{};     // FPalInstanceID.InstanceId
        int slot_index{-1};            // palbox: the slot the import was sent to
        int count_before{};            // the party count before the create
        uintptr_t controller{};        // the local player controller then: another one means the world changed (a
                                       // respawn makes a new pawn but keeps the controller)
        int polls{};
    };

    // About 6 s: the Lua side polls once per core update, every 300 ms.
    constexpr int MAX_POLLS = 20;

    enum class PollVerdict
    {
        Wait,
        Ok,
        Timeout
    };
    // Counts one poll: Ok once the Pal was seen, Timeout after MAX_POLLS polls without it, else Wait.
    auto next_poll(PendingGift& gift, bool seen) -> PollVerdict;
} // namespace pal_gift
