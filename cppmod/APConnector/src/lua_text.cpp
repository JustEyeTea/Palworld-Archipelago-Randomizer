// The text readers declared in lua_text.hpp. None of them throws: they run inside functions Lua called.
#include "lua_text.hpp"

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

    auto ids(std::string_view csv) -> std::vector<int64_t>
    {
        std::vector<int64_t> out;
        std::stringstream ss{std::string(csv)};
        for (std::string part; std::getline(ss, part, ',');)
        {
            if (part.empty()) continue;
            try
            {
                std::size_t used = 0;
                const auto id = std::stoll(part, &used);
                if (used == part.size()) out.push_back(id);
            }
            catch (...)
            {
            }
        }
        return out;
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
            return used == text.size() ? number : fallback;
        }
        catch (...)
        {
            return fallback;
        }
    }
} // namespace lua_text
