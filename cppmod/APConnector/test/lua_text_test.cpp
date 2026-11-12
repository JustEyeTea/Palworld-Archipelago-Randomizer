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
    if (!ok)
    {
        ++failures;
    }
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

static void check_parse_ids()
{
    expect(parse_ids("1,2,3").numbers == std::vector<int64_t>{1, 2, 3}, "parse_ids: three numbers");
    expect(parse_ids("12abc").numbers.empty(), "parse_ids: \"12abc\" is skipped (the whole part must be a number)");
    expect(parse_ids("").numbers.empty(), "parse_ids: \"\" gives none");
    expect(parse_ids(" 12").numbers == std::vector<int64_t>{12}, "parse_ids: a leading space is allowed");
    expect(parse_ids(TOO_BIG).numbers.empty(), "parse_ids: a number too big to hold is skipped");
    expect(parse_ids("5,,x,6").numbers == std::vector<int64_t>{5, 6},
           "parse_ids: empty and bad parts skipped, the rest kept");
    expect(parse_ids("1352729581").numbers == std::vector<int64_t>{1352729581}, "parse_ids: a Palworld location id");
    expect(parse_ids("5,,x,12abc,6").skipped == std::vector<std::string>{"x", "12abc"},
           "parse_ids: the parts that are not numbers are reported, empty parts are not");
}

static void check_int_or()
{
    expect(int_or("2048", 7) == 2048, "int_or: a number");
    expect(int_or("12abc", 7) == 7, "int_or: \"12abc\" gives the fallback (the whole text must be a number)");
    expect(int_or("", 7) == 7, "int_or: \"\" gives the fallback");
    expect(int_or(" 12", 7) == 12, "int_or: a leading space is allowed");
    expect(int_or(TOO_BIG, 7) == 7, "int_or: a number too big to hold gives the fallback");
    expect(int_or("2048.7", 7) == 7, "int_or: \"2048.7\" gives the fallback");
}

static void check_double_or()
{
    expect(double_or("0.4545", 1.0) == 0.4545, "double_or: a number");
    expect(double_or("1.5x", 1.0) == 1.0, "double_or: \"1.5x\" gives the fallback");
    expect(double_or("2048", 1.0) == 2048.0, "double_or: a whole number");
    expect(double_or("", 1.0) == 1.0, "double_or: \"\" gives the fallback");
    expect(double_or(" 2", 1.0) == 2.0, "double_or: a leading space is allowed");
    expect(double_or("1e999", 1.0) == 1.0, "double_or: a number too big to hold gives the fallback");
    expect(double_or("nan", 1.0) == 1.0, "double_or: \"nan\" (Lua's 0/0) gives the fallback");
    expect(double_or("inf", 1.0) == 1.0, "double_or: \"inf\" (Lua's 1/0) gives the fallback");
    expect(double_or("-inf", 1.0) == 1.0, "double_or: \"-inf\" gives the fallback");
}

static void check_read_float()
{
    float f = 0;
    expect(read_float("0.55", f) && f == 0.55f, "read_float: a number, as std::stof reads it");
    expect(!read_float("0.55x", f), "read_float: \"0.55x\" is not a number");
    expect(!read_float("", f), "read_float: \"\" is not a number");
    expect(!read_float("nan", f) && !read_float("inf", f), "read_float: \"nan\" and \"inf\" are not numbers");
    double d = 0;
    expect(read_double("1.5", d) && d == 1.5 && !read_double("1.5x", d), "read_double: the same rule");
}

static void check_parse_floats()
{
    std::vector<float> n;
    expect(parse_floats("59,42,26,210", ',', n) && n == std::vector<float>{59, 42, 26, 210}, "parse_floats: four");
    expect(parse_floats("", ',', n) && n.empty(), "parse_floats: \"\" is no numbers");
    expect(!parse_floats("1,,2", ',', n), "parse_floats: an empty part is not a number");
    expect(!parse_floats("1,2x", ',', n), "parse_floats: a part that is not a number");
    expect(parse_floats("0.5|0.25", '|', n) && n.size() == 2, "parse_floats: another separator");
}

static void check_parse_hex_rgb()
{
    float c[3] = {9, 9, 9};
    expect(parse_hex_rgb("FF8000", c) && c[0] == 1.f && c[1] == 128 / 255.f && c[2] == 0.f, "parse_hex_rgb: FF8000");
    expect(parse_hex_rgb("ffe9b0", c) && c[1] == 0xe9 / 255.f, "parse_hex_rgb: lower case");
    expect(!parse_hex_rgb("FF80", c) && !parse_hex_rgb("FF8000AA", c), "parse_hex_rgb: not six digits");
    expect(!parse_hex_rgb("-1FFFF", c) && !parse_hex_rgb("0xFFFF", c), "parse_hex_rgb: \"-1FFFF\", \"0xFFFF\" refused");
    expect(c[0] == 0xff / 255.f, "parse_hex_rgb: a refused text leaves the colour as it was");
}

int main()
{
    check_split_csv();
    check_parse_ids();
    check_int_or();
    check_double_or();
    check_read_float();
    check_parse_floats();
    check_parse_hex_rgb();
    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
