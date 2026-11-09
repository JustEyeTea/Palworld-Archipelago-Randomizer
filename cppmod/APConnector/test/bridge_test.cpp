// Drives ApBridge against a live Archipelago server the way the Lua mod will: connect, read slot data, scout and
// check a location, chat, and print every event line.  bridge_test <server> <slot> <location id>
#include "../src/ap_bridge.hpp"

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

static void drain(ApBridge& b, int ms)
{
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (std::chrono::steady_clock::now() < end)
    {
        auto ev = b.take_events();
        if (!ev.empty()) std::fputs(ev.c_str(), stdout);
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

int main(int argc, char** argv)
{
    if (argc < 4) { std::fprintf(stderr, "usage: bridge_test <server> <slot> <location id> [password]\n"); return 2; }
    ApBridge b("Palworld", "bridge-test-0001");
    b.connect(argv[1], argv[2], argc > 4 ? argv[4] : "");
    for (int i = 0; i < 100 && b.status() != "connected" && b.status() != "refused"; ++i) drain(b, 100);
    std::printf("== status %s, slot %d\n", b.status().c_str(), b.player_slot());
    if (b.status() != "connected") return 1;
    std::printf("== slot_data options.tower_count = %s\n", b.slot_data("options.tower_count").c_str());
    std::printf("== slot_data game_version = %s\n", b.slot_data("game_version").c_str());
    const long long loc = std::stoll(argv[3]);
    if (loc != 0)    // 0 is not a location; MultiServer drops a client that scouts or checks one
    {
        b.send_scouts({loc});
        drain(b, 1500);
        b.send_checks({loc});
    }
    b.say("bridge test says hello");
    std::printf("== hint points,cost = %s\n", b.hint_points().c_str());
    b.say("!hint Region Pass: Desiccated Dunes");
    b.set_tags("AP,DeathLink");
    drain(b, 500);
    b.bounce("{\"time\":1,\"source\":\"Tester\",\"cause\":\"bridge test\"}", "DeathLink");
    drain(b, 2000);
    b.disconnect();
    drain(b, 200);
    std::printf("== done\n");
    return 0;
}
