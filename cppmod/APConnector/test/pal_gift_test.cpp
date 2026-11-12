// Linux check of pal_gift_logic (the Unreal-free half of AP_GivePal): arguments, route choice, report shape, polling.
//   g++ -std=c++17 -Isrc test/pal_gift_test.cpp src/pal_gift_logic.cpp src/lua_text.cpp -o /tmp/pal_gift_test
//   /tmp/pal_gift_test
#include <cstdio>
#include <string>
#include <vector>
#include "pal_gift_logic.hpp"

using namespace pal_gift;

static int failures = 0;
static void expect(bool ok, const std::string& what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) ++failures;
}

int main()
{
    Request q;
    expect(parse_request("Anubis", "50", "party_debug", "", q) == "" && q.species == "Anubis" && q.level == 50 &&
               q.route == Route::PartyDebug && !q.rare && !q.nopassive,
           "a full request");
    expect(parse_request("SheepBall", "", "", "", q) == "" && q.level == 1 && q.route == Route::Auto,
           "missing level and route: level 1, auto");
    expect(parse_request("PinkCat", "13", "handle", "rare,nopassive", q) == "" && q.rare && q.nopassive, "options");
    expect(parse_request("Anubis", "0", "auto", "", q) == "bad level '0'", "level 0 refused");
    expect(parse_request("Anubis", "66", "auto", "", q) == "bad level '66'", "level 66 refused");
    expect(parse_request("Anubis", "5x", "auto", "", q) == "bad level '5x'", "a level that isn't a number");
    expect(parse_request("Anubis", "5", "cage", "", q) == "bad route 'cage'", "an unknown route");
    expect(parse_request("Anubis", "5", "auto", "shiny", q) == "bad option 'shiny'", "an unknown option");
    expect(parse_request("", "5", "auto", "", q).find("unknown species") == 0, "no species");
    expect(parse_request("Anu bis", "5", "auto", "", q).find("unknown species") == 0, "a species that can't be a name");

    expect(choose_route(Route::Auto, 3, 5) == Route::PartyDebug, "auto with room: the party");
    expect(choose_route(Route::Auto, 5, 5) == Route::Palbox, "auto with a full party: the Palbox");
    expect(choose_route(Route::PartyPlain, 5, 5) == Route::PartyPlain, "a named route is kept, even when full");
    expect(std::string(route_name(Route::PartyDebug)) == "party_debug" && std::string(route_name(Route::Palbox)) == "palbox",
           "route names match what Lua passes");

    const uint8_t g[16] = {0x4D, 0x3C, 0x2B, 0x1A, 0, 0, 0, 0, 1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};
    expect(format_guid(g) == "1A2B3C4D-00000000-00000001-FFFFFFFF", "a GUID as text: " + format_guid(g));
    const uint8_t z[16]{};
    expect(guid_is_zero(z) && !guid_is_zero(g), "a zero GUID");

    std::vector<std::string> mirrored;
    Report r([&](const std::string& l) { mirrored.push_back(l); });
    r.line("party: 3/5");
    const auto text = r.finish("ok party");
    expect(text == "party: 3/5\nresult: ok party", "the report ends with its result line");
    expect(mirrored.size() == 2 && mirrored[1] == "result: ok party", "every line is mirrored as it is added");

    expect(arrived_by_count(false, 3, 4), "a gift with no id: the party growing counts as its arrival");
    expect(!arrived_by_count(true, 3, 4),
           "a gift with an id: the party growing does not count (another Pal moved in?)");
    expect(!arrived_by_count(false, 3, 3), "a gift with no id: the party the same size, not arrived");

    const auto here = PlayerAtPoll::Here;
    PendingGift p;
    PollVerdict v = PollVerdict::Wait;
    for (int i = 0; i < MAX_POLLS - 1; ++i) v = next_poll(p, here, false);
    expect(v == PollVerdict::Wait, "still waiting before the last poll");
    expect(next_poll(p, here, false) == PollVerdict::Timeout, "a timeout after MAX_POLLS polls");
    PendingGift q2;
    expect(next_poll(q2, here, false) == PollVerdict::Wait && next_poll(q2, here, true) == PollVerdict::Ok,
           "ok once seen");

    PendingGift fainted;
    fainted.polls = MAX_POLLS - 1;
    expect(next_poll(fainted, PlayerAtPoll::BetweenPawns, false) == PollVerdict::Wait,
           "no pawn (fainted, respawning) with the same controller: the gift is kept");
    expect(fainted.polls == MAX_POLLS - 1, "a poll without a pawn is not counted");
    PendingGift left;
    expect(next_poll(left, PlayerAtPoll::Gone, false) == PollVerdict::Dropped,
           "no controller or another one: the gift is dropped");

    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
