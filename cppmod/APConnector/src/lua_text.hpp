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

    // "id,id,..." as numbers. A part that isn't a number is skipped.
    auto ids(std::string_view csv) -> std::vector<int64_t>;

    // A number Lua sent as text, or `fallback` when it doesn't start with one.
    auto int_or(const std::string& text, int fallback) -> int;
    auto double_or(const std::string& text, double fallback) -> double;
} // namespace lua_text
