// The Unreal-free half of giving a Pal, declared in pal_gift_logic.hpp.
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

    namespace
    {
        // Longer than any row name in DT_PalMonsterParameter, and than any level Lua could mean.
        constexpr size_t MAX_SPECIES_CHARS = 64;
        constexpr size_t MAX_LEVEL_DIGITS = 3;

        // Whether `species` can be a row name: letters, digits and underscores. Anything else can't be a Pal and
        // isn't worth an FName lookup.
        auto species_like(const std::string& species) -> bool
        {
            if (species.empty() || species.size() > MAX_SPECIES_CHARS) return false;
            for (char c : species)
            {
                const bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
                const bool word = letter || (c >= '0' && c <= '9') || c == '_';
                if (!word) return false;
            }
            return true;
        }

        // `level` ("1".."65", digits only; "" means MIN_LEVEL) into out; false when it is not a level.
        auto read_level(const std::string& level, int& out) -> bool
        {
            out = MIN_LEVEL;
            if (level.empty()) return true;
            if (level.size() > MAX_LEVEL_DIGITS) return false;
            int n = 0;
            for (char c : level)
            {
                if (c < '0' || c > '9') return false;
                n = n * 10 + (c - '0');
            }
            if (n < MIN_LEVEL || n > MAX_LEVEL) return false;
            out = n;
            return true;
        }

        // The route Lua named (route_name's names; "" means auto) into out; false for an unknown name.
        auto read_route(const std::string& route, Route& out) -> bool
        {
            constexpr Route ROUTES[] = {Route::Auto, Route::PartyDebug, Route::PartyPlain, Route::Handle,
                                        Route::Palbox};
            if (route.empty())
            {
                out = Route::Auto;
                return true;
            }
            for (const Route known : ROUTES)
            {
                if (route != route_name(known)) continue;
                out = known;
                return true;
            }
            return false;
        }
    } // namespace

    auto parse_request(const std::string& species, const std::string& level, const std::string& route,
                       const std::string& options, Request& out) -> std::string
    {
        if (!species_like(species)) return "unknown species '" + species + "' (no such name)";
        out.species = species;
        if (!read_level(level, out.level)) return "bad level '" + level + "'";
        if (!read_route(route, out.route)) return "bad route '" + route + "'";
        out.rare = out.nopassive = false;
        for (const auto& opt : lua_text::split_csv(options))
        {
            if (opt == "rare")
            {
                out.rare = true;
            }
            else if (opt == "nopassive")
            {
                out.nopassive = true;
            }
            else
            {
                return "bad option '" + opt + "'";
            }
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
        for (int i = 0; i < GUID_BYTES; ++i)
        {
            if (guid[i]) return false;
        }
        return true;
    }

    auto fail_result(const std::string& reason) -> std::string
    {
        return "fail " + reason;
    }

    auto Report::line(const std::string& text) -> void
    {
        m_lines.push_back(text);
        if (m_sink)
        {
            m_sink(text);
        }
    }

    auto Report::finish(const std::string& result) -> std::string
    {
        line("result: " + result);
        std::string out;
        for (size_t i = 0; i < m_lines.size(); ++i)
        {
            if (i)
            {
                out += '\n';
            }
            out += m_lines[i];
        }
        return out;
    }

    auto arrived_by_count(bool has_id, int count_before, int count_now) -> bool
    {
        return !has_id && count_now > count_before;
    }

    auto next_poll(PendingGift& gift, PlayerAtPoll player, bool seen) -> PollVerdict
    {
        switch (player)
        {
        case PlayerAtPoll::Gone: return PollVerdict::Dropped;
        case PlayerAtPoll::BetweenPawns: return PollVerdict::Wait;
        case PlayerAtPoll::Here: break;
        }
        ++gift.polls;
        if (seen) return PollVerdict::Ok;
        return gift.polls >= MAX_POLLS ? PollVerdict::Timeout : PollVerdict::Wait;
    }
} // namespace pal_gift
