// One builder per kind of event line, the text ApBridge hands the Lua mod for each thing the server sent. The kinds,
// their fields and the order are defined in ap_bridge.hpp (take_events); main.lua's on<Kind> handlers and the
// harness's push helpers read the same table. To add a field: the table, the builder here, the handler in main.lua,
// and the harness. Plain values in, so this needs neither apclientpp nor Unreal.
// Tests: test/event_lines_test.cpp (in CI, step "The C++ part's event lines").
#pragma once

#include <cstdint>
#include <initializer_list>
#include <string>

namespace event_lines
{
    // The fields joined by tabs. Tabs and line breaks inside a field become spaces; empty fields are kept.
    auto join(std::initializer_list<std::string> fields) -> std::string;

    // status <state>                      (socket, disconnected)
    auto status_line(const std::string& state) -> std::string;
    // status <state> <detail>             (connecting, connected, refused, error)
    auto status_line(const std::string& state, const std::string& detail) -> std::string;

    // item <index> <item id> <location id> <player number> <flags> <item name> <player name>
    auto item_line(int index, int64_t item_id, int64_t location_id, int player_number, unsigned flags,
                   const std::string& item_name, const std::string& player_name) -> std::string;

    // scout <location id> <item id> <player number> <flags> <item name> <player name> <game>
    auto scout_line(int64_t location_id, int64_t item_id, int player_number, unsigned flags,
                    const std::string& item_name, const std::string& player_name, const std::string& game)
        -> std::string;

    // checked <location id>
    auto checked_line(int64_t location_id) -> std::string;

    // message <text> <type>
    auto message_line(const std::string& text, const std::string& type) -> std::string;

    // bounce <tags> <json>                (tags "A,B"; json the bounce's data object)
    auto bounce_line(const std::string& tags, const std::string& data_json) -> std::string;
} // namespace event_lines
