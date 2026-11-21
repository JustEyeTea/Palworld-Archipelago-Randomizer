// ApBridge (ap_bridge.hpp). The bridge's own thread runs run(), which polls apclientpp; the server's handlers run
// inside that poll and only push event lines. Every public method runs on the caller's (Lua's) thread.
#include "ap_bridge.hpp"
#include "event_lines.hpp"
#include "lua_text.hpp"

#include <chrono>
#include <list>
#include <sstream>

#include <apclient.hpp>

using namespace event_lines;

namespace
{
    constexpr int ITEMS_HANDLING_ALL = 0b111;   // items from other worlds, our own world and the starting inventory
    // How long run() sleeps between polls: a server message waits at most this long before Lua can take it, and the
    // thread stays idle nearly all the time.
    constexpr int POLL_INTERVAL_MS = 20;
    // The Archipelago version this client reports; keep with minimum_ap_version in apworld/palworld/archipelago.json.
    const APClient::Version ARCHIPELAGO_VERSION{0, 6, 8};
    // The tags every join starts with; Lua adds DeathLink with set_tags().
    const std::list<std::string> JOIN_TAGS{"AP"};

    // A list of tags as one field, "A,B".
    auto tags_text(const nlohmann::json& tags) -> std::string
    {
        std::string text;
        for (const auto& tag : tags)
        {
            text += (text.empty() ? "" : ",") + tag.get<std::string>();
        }
        return text;
    }

    // The server's reasons for refusing a slot as one field, "A, B".
    auto reasons_text(const std::list<std::string>& reasons) -> std::string
    {
        std::string text;
        for (const auto& reason : reasons)
        {
            text += (text.empty() ? "" : ", ") + reason;
        }
        return text;
    }

    // Tags Lua sent as "A,B", as the list apclientpp takes.
    auto tag_list(const std::string& tags_csv) -> std::list<std::string>
    {
        const auto parts = lua_text::split_csv(tags_csv);
        return {parts.begin(), parts.end()};
    }
} // namespace

ApBridge::ApBridge(std::string game, std::string uuid, std::string cert_store)
    : m_game(std::move(game)), m_uuid(std::move(uuid)), m_cert_store(std::move(cert_store))
{
}

ApBridge::~ApBridge()
{
    disconnect();
}

void ApBridge::connect(const std::string& server, const std::string& slot_name, const std::string& password)
{
    disconnect();
    {
        std::lock_guard lock(m_mutex);
        m_slot_name = slot_name;
        m_password = password;
        m_slot_data_json.clear();
        m_client = std::make_unique<APClient>(m_uuid, m_game, server, m_cert_store);
        wire_handlers();
        set_status("connecting", server);
    }
    m_running = true;
    m_thread = std::thread(&ApBridge::run, this);
}

void ApBridge::disconnect()
{
    // Stop and join first, without the lock: run() takes the lock on every pass.
    m_running = false;
    if (m_thread.joinable())
    {
        m_thread.join();
    }
    std::lock_guard lock(m_mutex);
    if (m_client)
    {
        m_client.reset();
        set_status("disconnected");
    }
}

// The bridge's thread: polls apclientpp, which runs the handlers, until disconnect() stops it.
void ApBridge::run()
{
    while (m_running)
    {
        {
            std::lock_guard lock(m_mutex);
            if (m_client)
            {
                m_client->poll();
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(POLL_INTERVAL_MS));
    }
}

// Adds one event line for take_events(). The caller holds m_mutex.
void ApBridge::push(const std::string& line)
{
    m_events.push_back(line);
}

// Stores the connection state and pushes its status line; the only writer of m_status. The caller holds m_mutex.
void ApBridge::set_status(const std::string& state)
{
    m_status = state;
    push(status_line(state));
}

void ApBridge::set_status(const std::string& state, const std::string& detail)
{
    m_status = state;
    push(status_line(state, detail));
}

// Each handler runs on the bridge's thread, inside poll(), with m_mutex held: it may only push a line. The lines'
// kinds, fields and order are defined in ap_bridge.hpp (take_events), built in event_lines.cpp and read by main.lua's
// on<Kind> handlers and EVENT_HANDLERS; change all of them together, and the harness's push helpers. The caller holds
// m_mutex.
void ApBridge::wire_handlers()
{
    wire_connection_handlers();
    wire_item_handlers();
    wire_message_handlers();
}

// The socket opening, failing and dropping, the room information, and the slot joined or refused.
void ApBridge::wire_connection_handlers()
{
    auto* client = m_client.get();
    client->set_socket_connected_handler([this] { push(status_line("socket")); });
    client->set_socket_error_handler([this](const std::string& error) { push(status_line("error", error)); });
    client->set_socket_disconnected_handler([this] { set_status("disconnected"); });
    // Also runs after apclientpp reconnects by itself, to join the slot again (untested in game; checked against a
    // local server). Every join starts again with JOIN_TAGS: Lua sends its own tags after each "status connected".
    client->set_room_info_handler([this, client] {
        client->ConnectSlot(m_slot_name, m_password, ITEMS_HANDLING_ALL, JOIN_TAGS, ARCHIPELAGO_VERSION);
    });
    client->set_slot_connected_handler([this](const nlohmann::json& slot_data) {
        m_slot_data_json = slot_data.dump();
        set_status("connected", m_slot_name);
    });
    client->set_slot_refused_handler([this](const std::list<std::string>& reasons) {
        set_status("refused", reasons_text(reasons));
    });
}

// Items received, the answers to scouts, and locations checked elsewhere.
void ApBridge::wire_item_handlers()
{
    auto* client = m_client.get();
    client->set_items_received_handler([this, client](const std::list<APClient::NetworkItem>& items) {
        for (const auto& item : items)
        {
            push(item_line(item.index, item.item, item.location, item.player, item.flags,
                           client->get_item_name(item.item, m_game), client->get_player_alias(item.player)));
        }
    });
    client->set_location_info_handler([this, client](const std::list<APClient::NetworkItem>& items) {
        for (const auto& item : items)
        {
            const auto& game = client->get_player_game(item.player);
            push(scout_line(item.location, item.item, item.player, item.flags, client->get_item_name(item.item, game),
                            client->get_player_alias(item.player), game));
        }
    });
    client->set_location_checked_handler([this](const std::list<int64_t>& locations) {
        for (const auto location : locations)
        {
            push(checked_line(location));
        }
    });
}

// The server's messages (chat, hints, command results) and bounces (Death Link).
void ApBridge::wire_message_handlers()
{
    auto* client = m_client.get();
    client->set_print_json_handler([this, client](const APClient::PrintJSONArgs& args) {
        push(message_line(client->render_json(args.data, APClient::RenderFormat::TEXT), args.type));
    });
    client->set_bounced_handler([this](const nlohmann::json& packet) {
        const auto tags = packet.contains("tags") ? tags_text(packet["tags"]) : "";
        push(bounce_line(tags, packet.contains("data") ? packet["data"].dump() : "{}"));
    });
}

void ApBridge::report_error(const std::string& problem)
{
    std::lock_guard lock(m_mutex);
    push(status_line("error", problem));
}

auto ApBridge::take_events() -> std::string
{
    std::lock_guard lock(m_mutex);
    std::string out;
    for (const auto& event : m_events)
    {
        out += event + '\n';
    }
    m_events.clear();
    return out;
}

void ApBridge::send_checks(const std::vector<int64_t>& locations)
{
    std::lock_guard lock(m_mutex);
    if (!m_client)
    {
        push(status_line("error", "checks not sent: no connection"));
        return;
    }
    m_client->LocationChecks({locations.begin(), locations.end()});
}

void ApBridge::send_scouts(const std::vector<int64_t>& locations)
{
    std::lock_guard lock(m_mutex);
    if (!m_client)
    {
        push(status_line("error", "scouts not sent: no connection"));
        return;
    }
    m_client->LocationScouts({locations.begin(), locations.end()}, /* create_as_hint */ 0);
}

void ApBridge::say(const std::string& text)
{
    std::lock_guard lock(m_mutex);
    // apclientpp refuses a chat line (returns false) until the server has greeted it, as while it reconnects.
    if (!m_client || !m_client->Say(text))
    {
        push(status_line("error", "chat not sent: no connection"));
    }
}

void ApBridge::goal()
{
    std::lock_guard lock(m_mutex);
    // Refused (false) until the slot has joined, as while apclientpp reconnects.
    if (!m_client || !m_client->StatusUpdate(APClient::ClientStatus::GOAL))
    {
        push(status_line("error", "goal not sent: no connection"));
    }
}

void ApBridge::set_tags(const std::string& tags_csv)
{
    const auto tags = tag_list(tags_csv);
    std::lock_guard lock(m_mutex);
    if (!m_client)
    {
        push(status_line("error", "tags not sent: no connection"));
        return;
    }
    m_client->ConnectUpdate(/* send items_handling */ false, 0, /* send tags */ true, tags);
}

void ApBridge::bounce(const std::string& json_data, const std::string& tags_csv)
{
    std::lock_guard lock(m_mutex);
    if (!m_client)
    {
        push(status_line("error", "bounce not sent: no connection"));
        return;
    }
    auto data = nlohmann::json::parse(json_data, nullptr, false);
    if (data.is_discarded())                 // not JSON: say so instead of sending an empty bounce
    {
        push(status_line("error", "bounce not sent: its data is not JSON"));
        return;
    }
    // Refused (false) until the server has greeted apclientpp, as while it reconnects.
    if (!m_client->Bounce(data, /* games */ {}, /* slots */ {}, tag_list(tags_csv)))
    {
        push(status_line("error", "bounce not sent: no connection"));
    }
}

auto ApBridge::slot_data(const std::string& path) -> std::string
{
    std::lock_guard lock(m_mutex);
    if (m_slot_data_json.empty()) return "";
    auto node = nlohmann::json::parse(m_slot_data_json, nullptr, false);
    std::stringstream ss(path);
    for (std::string key; std::getline(ss, key, '.');)
    {
        if (!node.is_object() || !node.contains(key)) return "";
        node = node[key];
    }
    if (node.is_string()) return node.get<std::string>();
    return node.dump();
}

auto ApBridge::status() -> std::string
{
    std::lock_guard lock(m_mutex);
    return m_status;
}

auto ApBridge::hint_points() -> std::string
{
    std::lock_guard lock(m_mutex);
    if (!m_client || m_client->get_state() != APClient::State::SLOT_CONNECTED) return "";
    return std::to_string(m_client->get_hint_points()) + "," + std::to_string(m_client->get_hint_cost_points());
}

auto ApBridge::player_number() -> int
{
    std::lock_guard lock(m_mutex);
    return m_client ? m_client->get_player_number() : -1;
}
