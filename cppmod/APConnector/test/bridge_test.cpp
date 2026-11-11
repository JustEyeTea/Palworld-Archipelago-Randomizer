// Drives ApBridge against a live Archipelago server the way the Lua mod does: connect, read slot data, scout and
// check a location, chat, and send a bounce. Prints every event line, and exits 1 unless the lines main.lua depends
// on arrived in the format ap_bridge.hpp defines. Built and run by hand with tools/bridge_test.sh (CI does not run it).
//   bridge_test <server> <slot name> <location id> [password]
#include "../src/ap_bridge.hpp"

#include <chrono>
#include <cstdio>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace
{
    constexpr int CONNECT_TRIES = 100;              // tries of CONNECT_TRY_MS each: 10 s for the slot to join
    constexpr int CONNECT_TRY_MS = 100;
    constexpr int SCOUT_WAIT_MS = 1500;             // the server answers a scout well inside this
    constexpr int CHAT_WAIT_MS = 500;
    constexpr int BOUNCE_WAIT_MS = 2000;
    constexpr int DISCONNECT_WAIT_MS = 200;
    constexpr int TAKE_EVENTS_EVERY_MS = 50;
    constexpr std::size_t SCOUT_FIELDS = 8;         // "scout" and its seven fields (ap_bridge.hpp)
    constexpr int CHECKS_FAILED = 1;
    constexpr int BAD_USAGE = 2;

    std::vector<std::string> g_lines;               // every event line read so far, in order

    // Reads event lines for `ms` milliseconds, printing each and keeping it in g_lines.
    void drain(ApBridge& bridge, int ms)
    {
        const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < end)
        {
            std::stringstream events(bridge.take_events());
            for (std::string line; std::getline(events, line);)
            {
                std::printf("%s\n", line.c_str());
                g_lines.push_back(line);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(TAKE_EVENTS_EVERY_MS));
        }
    }

    // One event line's fields, split at its tabs ("status", "connected", "Tester").
    auto fields_of(const std::string& line) -> std::vector<std::string>
    {
        std::vector<std::string> fields;
        std::stringstream parts(line);
        for (std::string field; std::getline(parts, field, '\t');)
        {
            fields.push_back(field);
        }
        return fields;
    }

    // Whether a line from g_lines[from] on is a "scout" line of the full width whose location is `location`.
    auto scout_line_seen(std::size_t from, const std::string& location) -> bool
    {
        for (std::size_t i = from; i < g_lines.size(); ++i)
        {
            const auto fields = fields_of(g_lines[i]);
            if (fields.size() == SCOUT_FIELDS && fields[0] == "scout" && fields[1] == location) return true;
        }
        return false;
    }

    // Whether a line from g_lines[from] on is of this kind.
    auto line_seen(std::size_t from, const std::string& kind) -> bool
    {
        for (std::size_t i = from; i < g_lines.size(); ++i)
        {
            const auto fields = fields_of(g_lines[i]);
            if (!fields.empty() && fields[0] == kind) return true;
        }
        return false;
    }

    // Whether the line is in g_lines, exactly.
    auto exact_line_seen(const std::string& line) -> bool
    {
        for (const auto& seen : g_lines)
        {
            if (seen == line) return true;
        }
        return false;
    }

    int g_failures = 0;

    // Prints one check's result, and counts it when it failed.
    void expect(bool ok, const std::string& what)
    {
        std::printf("== %s %s\n", ok ? "ok  " : "FAIL", what.c_str());
        if (!ok) ++g_failures;
    }

    // Waits until the slot joins or is refused; whether it joined.
    auto wait_for_slot(ApBridge& bridge) -> bool
    {
        for (int i = 0; i < CONNECT_TRIES; ++i)
        {
            if (bridge.status() == "connected" || bridge.status() == "refused") break;
            drain(bridge, CONNECT_TRY_MS);
        }
        std::printf("== status %s, player number %d\n", bridge.status().c_str(), bridge.player_number());
        return bridge.status() == "connected";
    }

    // Scouts, then checks, the location: the scout's answer must come back as a "scout" line.
    void scout_and_check(ApBridge& bridge, long long location)
    {
        const auto before = g_lines.size();
        bridge.send_scouts({location});
        drain(bridge, SCOUT_WAIT_MS);
        expect(scout_line_seen(before, std::to_string(location)), "a scout line with seven fields for the location");
        bridge.send_checks({location});
    }

    // Chat and a hint command must come back as "message" lines.
    void chat(ApBridge& bridge)
    {
        const auto before = g_lines.size();
        bridge.say("bridge test says hello");
        std::printf("== hint points,cost = %s\n", bridge.hint_points().c_str());
        bridge.say("!hint Region Pass: Desiccated Dunes");
        drain(bridge, CHAT_WAIT_MS);
        expect(line_seen(before, "message"), "a message line after say()");
    }

    // With the DeathLink tag set, our own Death Link bounce must come back as a "bounce" line.
    void death_link(ApBridge& bridge)
    {
        bridge.set_tags("AP,DeathLink");
        drain(bridge, CHAT_WAIT_MS);
        const auto before = g_lines.size();
        bridge.bounce("{\"time\":1,\"source\":\"Tester\",\"cause\":\"bridge test\"}", "DeathLink");
        drain(bridge, BOUNCE_WAIT_MS);
        expect(line_seen(before, "bounce"), "a bounce line after a Death Link bounce");
    }
} // namespace

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: bridge_test <server> <slot name> <location id> [password]\n");
        return BAD_USAGE;
    }
    const std::string slot_name = argv[2];
    ApBridge bridge("Palworld", "bridge-test-0001");
    bridge.connect(argv[1], slot_name, argc > 4 ? argv[4] : "");
    const bool joined = wait_for_slot(bridge);
    expect(joined, "the slot joined");
    if (!joined) return CHECKS_FAILED;
    drain(bridge, CHAT_WAIT_MS);
    expect(exact_line_seen("status\tconnected\t" + slot_name), "a 'status connected <slot name>' line");
    // tools/bridge_test.sh's player file sets tower_count: 2.
    expect(bridge.slot_data("options.tower_count") == "2", "slot_data options.tower_count is 2");
    std::printf("== slot_data game_version = %s\n", bridge.slot_data("game_version").c_str());
    const long long location = std::stoll(argv[3]);
    if (location != 0)    // 0 is not a location; MultiServer drops a client that scouts or checks one
    {
        scout_and_check(bridge, location);
    }
    chat(bridge);
    death_link(bridge);
    bridge.disconnect();
    drain(bridge, DISCONNECT_WAIT_MS);
    std::printf("== %s\n", g_failures ? "FAILED" : "all passed");
    return g_failures ? CHECKS_FAILED : 0;
}
