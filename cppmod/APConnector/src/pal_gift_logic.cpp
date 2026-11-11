#include "pal_gift_logic.hpp"
#include "lua_text.hpp"

#include <cstdio>

namespace pal_gift
{
    auto route_name(Route route) -> const char*
    {
        switch (route)
        {
        case Route::Auto: return "auto";
        case Route::PartyDebug: return "party_debug";
        case Route::PartyPlain: return "party_plain";
        case Route::Handle: return "handle";
        case Route::Palbox: return "palbox";
        }
        return "?";
    }

    auto parse_request(const std::string& species, const std::string& level, const std::string& route,
                       const std::string& options, Request& out) -> std::string
    {
        // A row name: letters, digits and underscores. Anything else can't be a Pal and isn't worth an FName lookup.
        if (species.empty() || species.size() > 64) return "unknown species '" + species + "' (no such name)";
        for (char c : species)
        {
            const bool word = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
            if (!word) return "unknown species '" + species + "' (no such name)";
        }
        out.species = species;

        out.level = MIN_LEVEL;
        if (!level.empty())
        {
            if (level.size() > 3) return "bad level '" + level + "'";
            int n = 0;
            for (char c : level)
            {
                if (c < '0' || c > '9') return "bad level '" + level + "'";
                n = n * 10 + (c - '0');
            }
            if (n < MIN_LEVEL || n > MAX_LEVEL) return "bad level '" + level + "'";
            out.level = n;
        }

        if (route.empty() || route == "auto") out.route = Route::Auto;
        else if (route == "party_debug") out.route = Route::PartyDebug;
        else if (route == "party_plain") out.route = Route::PartyPlain;
        else if (route == "handle") out.route = Route::Handle;
        else if (route == "palbox") out.route = Route::Palbox;
        else return "bad route '" + route + "'";

        out.rare = out.nopassive = false;
        for (const auto& opt : lua_text::split_csv(options))
        {
            if (opt == "rare") out.rare = true;
            else if (opt == "nopassive") out.nopassive = true;
            else return "bad option '" + opt + "'";
        }
        return "";
    }

    auto choose_route(Route requested, int party_count, int party_max) -> Route
    {
        if (requested != Route::Auto) return requested;
        return party_count < party_max ? Route::PartyDebug : Route::Palbox;
    }

    auto format_guid(const uint8_t* guid) -> std::string
    {
        char out[40]{};
        uint32_t part[4]{};
        for (int i = 0; i < 4; ++i)
        {
            part[i] = static_cast<uint32_t>(guid[i * 4]) | static_cast<uint32_t>(guid[i * 4 + 1]) << 8 |
                      static_cast<uint32_t>(guid[i * 4 + 2]) << 16 | static_cast<uint32_t>(guid[i * 4 + 3]) << 24;
        }
        std::snprintf(out, sizeof out, "%08X-%08X-%08X-%08X", part[0], part[1], part[2], part[3]);
        return out;
    }

    auto guid_is_zero(const uint8_t* guid) -> bool
    {
        for (int i = 0; i < 16; ++i)
        {
            if (guid[i]) return false;
        }
        return true;
    }

    auto Report::line(const std::string& text) -> void
    {
        m_lines.push_back(text);
        if (m_sink) m_sink(text);
    }

    auto Report::finish(const std::string& result) -> std::string
    {
        line("result: " + result);
        std::string out;
        for (size_t i = 0; i < m_lines.size(); ++i)
        {
            if (i) out += '\n';
            out += m_lines[i];
        }
        return out;
    }

    auto next_poll(PendingGift& gift, bool seen) -> PollVerdict
    {
        ++gift.polls;
        if (seen) return PollVerdict::Ok;
        return gift.polls >= MAX_POLLS ? PollVerdict::Timeout : PollVerdict::Wait;
    }
} // namespace pal_gift
