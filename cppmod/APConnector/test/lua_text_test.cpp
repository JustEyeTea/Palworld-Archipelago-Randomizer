// Linux check of lua_text: how the text Lua sends becomes numbers and lists. Run by CI ("The C++ part's text
// arguments"); by hand:
//   g++ -std=c++17 -Isrc test/lua_text_test.cpp src/lua_text.cpp -o /tmp/lua_text_test && /tmp/lua_text_test
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include "lua_text.hpp"

using namespace lua_text;

static int failures = 0;

// Prints one check's result, and counts it when it failed.
static void expect(bool ok, const std::string& what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    if (!ok) ++failures;
}

// A number too big for int64_t, so std::stoll throws out_of_range on it.
static const std::string TOO_BIG = "99999999999999999999";

static void check_split_csv()
{
    expect(split_csv("AP,DeathLink") == std::vector<std::string>{"AP", "DeathLink"}, "split_csv: two tags");
    expect(split_csv(",A,,B,") == std::vector<std::string>{"A", "B"}, "split_csv: empty parts are dropped");
    expect(split_csv("").empty(), "split_csv: \"\" has no parts");
    expect(split_csv(" A") == std::vector<std::string>{" A"}, "split_csv: spaces are kept");
}

static void check_ids()
{
    expect(ids("1,2,3") == std::vector<int64_t>{1, 2, 3}, "ids: three numbers");
    expect(ids("12abc").empty(), "ids: \"12abc\" is skipped (the whole part must be a number)");
    expect(ids("").empty(), "ids: \"\" gives none");
    expect(ids(" 12") == std::vector<int64_t>{12}, "ids: a leading space is allowed");
    expect(ids(TOO_BIG).empty(), "ids: a number too big to hold is skipped");
    expect(ids("5,,x,6") == std::vector<int64_t>{5, 6}, "ids: empty and bad parts skipped, the rest kept");
    expect(ids("1352729581") == std::vector<int64_t>{1352729581}, "ids: a Palworld location id");
}

static void check_int_or()
{
    expect(int_or("2048", 7) == 2048, "int_or: a number");
    expect(int_or("12abc", 7) == 12, "int_or: \"12abc\" reads as 12 (only the start must be a number)");
    expect(int_or("", 7) == 7, "int_or: \"\" gives the fallback");
    expect(int_or(" 12", 7) == 12, "int_or: a leading space is allowed");
    expect(int_or(TOO_BIG, 7) == 7, "int_or: a number too big to hold gives the fallback");
    expect(int_or("2048.7", 7) == 2048, "int_or: \"2048.7\" reads as 2048");
}

static void check_double_or()
{
    expect(double_or("0.4545", 1.0) == 0.4545, "double_or: a number");
    expect(double_or("1.5x", 1.0) == 1.5, "double_or: \"1.5x\" reads as 1.5");
    expect(double_or("", 1.0) == 1.0, "double_or: \"\" gives the fallback");
    expect(double_or(" 2", 1.0) == 2.0, "double_or: a leading space is allowed");
    expect(double_or("1e999", 1.0) == 1.0, "double_or: a number too big to hold gives the fallback");
}

int main()
{
    check_split_csv();
    check_ids();
    check_int_or();
    check_double_or();
    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
