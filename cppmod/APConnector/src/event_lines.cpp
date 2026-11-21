// The event-line builders declared in event_lines.hpp.
#include "event_lines.hpp"

namespace event_lines
{
    namespace
    {
        // A tab or a line break inside a field would split the line; game text never needs them.
        auto clean(std::string field) -> std::string
        {
            for (auto& c : field)
            {
                if (c == '\t' || c == '\n' || c == '\r')
                {
                    c = ' ';
                }
            }
            return field;
        }
    } // namespace

    auto join(std::initializer_list<std::string> fields) -> std::string
    {
        std::string line;
        bool first = true;
        for (const auto& field : fields)
        {
            if (!first)
            {
                line += '\t';
            }
            line += clean(field);
            first = false;
        }
        return line;
    }

    auto status_line(const std::string& state) -> std::string
    {
        return join({"status", state});
    }

    auto status_line(const std::string& state, const std::string& detail) -> std::string
    {
        return join({"status", state, detail});
    }

    auto item_line(int index, int64_t item_id, int64_t location_id, int player_number, unsigned flags,
                   const std::string& item_name, const std::string& player_name) -> std::string
    {
        return join({"item", std::to_string(index), std::to_string(item_id), std::to_string(location_id),
                     std::to_string(player_number), std::to_string(flags), item_name, player_name});
    }

    auto scout_line(int64_t location_id, int64_t item_id, int player_number, unsigned flags,
                    const std::string& item_name, const std::string& player_name, const std::string& game)
        -> std::string
    {
        return join({"scout", std::to_string(location_id), std::to_string(item_id), std::to_string(player_number),
                     std::to_string(flags), item_name, player_name, game});
    }

    auto checked_line(int64_t location_id) -> std::string
    {
        return join({"checked", std::to_string(location_id)});
    }

    auto message_line(const std::string& text, const std::string& type) -> std::string
    {
        return join({"message", text, type});
    }

    auto bounce_line(const std::string& tags, const std::string& data_json) -> std::string
    {
        return join({"bounce", tags, data_json});
    }
} // namespace event_lines
