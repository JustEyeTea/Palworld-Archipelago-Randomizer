// Turns the text the Lua mod passes the connector into numbers and lists. Lua passes every argument as text
// (dllmain.cpp's header), so each reader here is the one place its rule is written. Needs no Unreal.
// Tests: test/lua_text_test.cpp (in CI, step "The C++ part's text arguments").
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lua_text
{
    // "A,B,,C" as its non-empty parts, in order: {"A", "B", "C"}.
    auto split_csv(std::string_view csv) -> std::vector<std::string>;

    // The number readers share one rule for "a number Lua sent as text": the whole text is the number (a leading
    // space is allowed, as std::stoll allows it). "12abc", "" and, for an int, "2048.7" are not numbers; for a
    // double or a float, nor are "nan" and "inf" (what Lua's tostring gives for 0/0 and 1/0).
    //
    // "id,id,..." read as numbers: the numbers in order, and the parts that were not numbers (empty parts are
    // neither), so the caller can report them.
    struct IdList
    {
        std::vector<int64_t> numbers;
        std::vector<std::string> skipped;
    };
    auto parse_ids(std::string_view csv) -> IdList;

    // A number Lua sent as text, or `fallback` when the text isn't one.
    auto int_or(const std::string& text, int fallback) -> int;
    auto double_or(const std::string& text, double fallback) -> double;

    // Whether the text is a number; if so, it is written to `number`. read_float reads it as a float directly
    // (std::stof), as the pictures use it, not through a double.
    auto read_double(const std::string& text, double& number) -> bool;
    auto read_float(const std::string& text, float& number) -> bool;

    // "a,b,c" (parts split at `separator`) as floats, into `numbers`: false, with `numbers` incomplete, when a part is
    // not a number (an empty part neither). "" is no numbers.
    auto parse_floats(std::string_view text, char separator, std::vector<float>& numbers) -> bool;

    // "RRGGBB" (six hex digits, either case) as red, green and blue 0..1: false when the text is not that.
    auto parse_hex_rgb(std::string_view text, float (&rgb)[3]) -> bool;
} // namespace lua_text
