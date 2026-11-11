// Linux check of event_lines: each builder against a line typed out as ApBridge wrote it to a local server's test
// (tools/bridge_test.sh). Run by CI ("The C++ part's event lines"); by hand:
//   g++ -std=c++17 -Isrc test/event_lines_test.cpp src/event_lines.cpp -o /tmp/event_lines_test
//   /tmp/event_lines_test
#include <cstdio>
#include <string>
#include "event_lines.hpp"

using namespace event_lines;

static int failures = 0;

// Prints one check's result, with both lines when they differ, and counts it when it failed.
static void expect_line(const std::string& built, const std::string& typed, const std::string& what)
{
    const bool ok = built == typed;
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok)
    {
        std::printf("     built: %s\n     typed: %s\n", built.c_str(), typed.c_str());
        ++failures;
    }
}

int main()
{
    expect_line(status_line("connecting", "ws://127.0.0.1:38301"), "status\tconnecting\tws://127.0.0.1:38301",
                "status with a detail");
    expect_line(status_line("socket"), "status\tsocket", "status without a detail");
    expect_line(status_line("error", ""), "status\terror\t", "an empty detail is kept as an empty field");
    expect_line(item_line(0, 1352729534, 1352729581, 1, 0, "Palworld Crate", "Tester"),
                "item\t0\t1352729534\t1352729581\t1\t0\tPalworld Crate\tTester", "item");
    expect_line(scout_line(1352729581, 1352729534, 1, 0, "Palworld Crate", "Tester", "Palworld"),
                "scout\t1352729581\t1352729534\t1\t0\tPalworld Crate\tTester\tPalworld", "scout");
    expect_line(checked_line(1352729581), "checked\t1352729581", "checked");
    expect_line(message_line("Tester: bridge test says hello", "Chat"), "message\tTester: bridge test says hello\tChat",
                "message");
    expect_line(bounce_line("DeathLink", "{\"cause\":\"bridge test\"}"),
                "bounce\tDeathLink\t{\"cause\":\"bridge test\"}", "bounce");
    expect_line(message_line("two\tparts\nand a line", ""), "message\ttwo parts and a line\t",
                "tabs and line breaks inside a field become spaces");
    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
