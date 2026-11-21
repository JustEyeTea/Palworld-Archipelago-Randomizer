// The text readers declared in lua_text.hpp. None of them throws: they run inside functions Lua called.
#include "lua_text.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace lua_text
{
    auto split_csv(std::string_view csv) -> std::vector<std::string>
    {
        std::vector<std::string> parts;
        std::stringstream ss{std::string(csv)};
        for (std::string part; std::getline(ss, part, ',');)
        {
            if (!part.empty())
            {
                parts.push_back(part);
            }
        }
        return parts;
    }

    namespace
    {
        // Whether the whole text is one int64_t; if so, it is written to `number`.
        auto read_int64(const std::string& text, int64_t& number) -> bool
        {
            try
            {
                std::size_t used = 0;
                number = std::stoll(text, &used);
                return used == text.size();
            }
            catch (...)
            {
                return false;
            }
        }
    } // namespace

    auto parse_ids(std::string_view csv) -> IdList
    {
        IdList list;
        for (const auto& part : split_csv(csv))
        {
            int64_t number = 0;
            if (read_int64(part, number))
            {
                list.numbers.push_back(number);
            }
            else
            {
                list.skipped.push_back(part);
            }
        }
        return list;
    }

    auto int_or(const std::string& text, int fallback) -> int
    {
        try
        {
            std::size_t used = 0;
            const int number = std::stoi(text, &used);
            return used == text.size() ? number : fallback;
        }
        catch (...)
        {
            return fallback;
        }
    }

    auto double_or(const std::string& text, double fallback) -> double
    {
        double number = 0;
        return read_double(text, number) ? number : fallback;
    }

    auto read_double(const std::string& text, double& number) -> bool
    {
        try
        {
            std::size_t used = 0;
            const double read = std::stod(text, &used);
            // stod also reads "nan" and "inf" whole; neither is a number a picture's position or gamma can use.
            if (used != text.size() || !std::isfinite(read)) return false;
            number = read;
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    auto read_float(const std::string& text, float& number) -> bool
    {
        try
        {
            std::size_t used = 0;
            const float read = std::stof(text, &used);
            if (used != text.size() || !std::isfinite(read)) return false;
            number = read;
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    auto parse_floats(std::string_view text, char separator, std::vector<float>& numbers) -> bool
    {
        numbers.clear();
        if (text.empty()) return true;
        std::size_t start = 0;
        while (true)
        {
            const std::size_t end = text.find(separator, start);
            const std::size_t length = end == std::string_view::npos ? std::string_view::npos : end - start;
            const std::string part(text.substr(start, length));
            float number = 0;
            if (!read_float(part, number)) return false;
            numbers.push_back(number);
            if (end == std::string_view::npos) return true;
            start = end + 1;
        }
    }

    namespace
    {
        // A hex digit's value, or -1.
        auto hex_digit(char c) -> int
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }
    } // namespace

    auto parse_hex_rgb(std::string_view text, float (&rgb)[3]) -> bool
    {
        constexpr std::size_t HEX_RGB_DIGITS = 6;
        if (text.size() != HEX_RGB_DIGITS) return false;
        float read[3]{};
        for (int c = 0; c < 3; ++c)
        {
            const int high = hex_digit(text[c * 2]), low = hex_digit(text[c * 2 + 1]);
            if (high < 0 || low < 0) return false;
            read[c] = static_cast<float>(high * 16 + low) / 255.f;
        }
        std::copy(read, read + 3, rgb);
        return true;
    }
} // namespace lua_text
