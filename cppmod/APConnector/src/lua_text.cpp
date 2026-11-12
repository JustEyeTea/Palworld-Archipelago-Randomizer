// The text readers declared in lua_text.hpp. None of them throws: they run inside functions Lua called.
#include "lua_text.hpp"

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
        try
        {
            std::size_t used = 0;
            const double number = std::stod(text, &used);
            // stod also reads "nan" and "inf" whole; neither is a number a picture's position or gamma can use.
            return used == text.size() && std::isfinite(number) ? number : fallback;
        }
        catch (...)
        {
            return fallback;
        }
    }
} // namespace lua_text
