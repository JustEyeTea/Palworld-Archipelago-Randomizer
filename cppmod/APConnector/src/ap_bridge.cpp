#include "ap_bridge.hpp"

#include <chrono>
#include <list>
#include <sstream>

#include <apclient.hpp>

namespace
{
    // Tabs and newlines would break the line format; game text never needs them.
    auto clean(std::string s) -> std::string
    {
        for (auto& c : s)
        {
            if (c == '\t' || c == '\n' || c == '\r') c = ' ';
        }
        return s;
    }

    auto join(std::initializer_list<std::string> fields) -> std::string
    {
        std::string out;
        for (const auto& f : fields)
        {
            if (!out.empty()) out += '\t';
            out += clean(f);
        }
        return out;
    }

    constexpr int ITEMS_HANDLING_ALL = 0b111;   // items from other worlds, our own world and the starting inventory
} // namespace

ApBridge::ApBridge(std::string game, std::string uuid, std::string cert_store)
    : m_game(std::move(game)), m_uuid(std::move(uuid)), m_cert_store(std::move(cert_store))
{
}

ApBridge::~ApBridge()
{
    disconnect();
}

void ApBridge::connect(const std::string& server, const std::string& slot, const std::string& password)
{
    disconnect();
    {
        std::lock_guard lock(m_mutex);
        m_server = server;
        m_slot = slot;
        m_password = password;
        m_slot_data_json.clear();
        m_client = std::make_unique<APClient>(m_uuid, m_game, server, m_cert_store);
        wire_handlers();
        m_status = "connecting";
        push(join({"status", "connecting", server}));
    }
    m_running = true;
    m_thread = std::thread(&ApBridge::run, this);
}

void ApBridge::disconnect()
{
    m_running = false;
    if (m_thread.joinable()) m_thread.join();
    std::lock_guard lock(m_mutex);
    if (m_client)
    {
        m_client.reset();
        m_status = "disconnected";
        push(join({"status", "disconnected"}));
    }
}

void ApBridge::run()
{
    while (m_running)
    {
        {
            std::lock_guard lock(m_mutex);
            if (m_client) m_client->poll();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}

void ApBridge::push(const std::string& line)
{
    m_events.push_back(line);
}

void ApBridge::wire_handlers()
{
    auto* c = m_client.get();
    c->set_socket_connected_handler([this] { push(join({"status", "socket"})); });
    c->set_socket_error_handler([this](const std::string& e) { push(join({"status", "error", e})); });
    c->set_socket_disconnected_handler([this] {
        m_status = "disconnected";
        push(join({"status", "disconnected"}));
    });
    c->set_room_info_handler([this, c] {
        c->ConnectSlot(m_slot, m_password, ITEMS_HANDLING_ALL, {"AP"}, {0, 6, 8});
    });
    c->set_slot_connected_handler([this](const nlohmann::json& slot_data) {
        m_slot_data_json = slot_data.dump();
        m_status = "connected";
        push(join({"status", "connected", m_slot}));
    });
    c->set_slot_refused_handler([this](const std::list<std::string>& errors) {
        std::string why;
        for (const auto& e : errors) why += (why.empty() ? "" : ", ") + e;
        m_status = "refused";
        push(join({"status", "refused", why}));
    });
    c->set_items_received_handler([this, c](const std::list<APClient::NetworkItem>& items) {
        for (const auto& it : items)
        {
            push(join({"item", std::to_string(it.index), std::to_string(it.item), std::to_string(it.location),
                       std::to_string(it.player), std::to_string(it.flags), c->get_item_name(it.item, m_game),
                       c->get_player_alias(it.player)}));
        }
    });
    c->set_location_info_handler([this, c](const std::list<APClient::NetworkItem>& items) {
        for (const auto& it : items)
        {
            const auto& game = c->get_player_game(it.player);
            push(join({"scout", std::to_string(it.location), std::to_string(it.item), std::to_string(it.player),
                       std::to_string(it.flags), c->get_item_name(it.item, game), c->get_player_alias(it.player),
                       game}));
        }
    });
    c->set_location_checked_handler([this](const std::list<int64_t>& locations) {
        for (auto l : locations) push(join({"checked", std::to_string(l)}));
    });
    c->set_print_json_handler([this, c](const APClient::PrintJSONArgs& args) {
        push(join({"message", c->render_json(args.data, APClient::RenderFormat::TEXT), args.type}));
    });
    c->set_bounced_handler([this](const nlohmann::json& packet) {
        std::string tags;
        if (packet.contains("tags"))
            for (const auto& t : packet["tags"]) tags += (tags.empty() ? "" : ",") + t.get<std::string>();
        push(join({"bounce", tags, packet.contains("data") ? packet["data"].dump() : "{}"}));
    });
}

auto ApBridge::take_events() -> std::string
{
    std::lock_guard lock(m_mutex);
    std::string out;
    for (const auto& e : m_events) out += e + '\n';
    m_events.clear();
    return out;
}

void ApBridge::send_checks(const std::vector<int64_t>& locations)
{
    std::lock_guard lock(m_mutex);
    if (m_client) m_client->LocationChecks({locations.begin(), locations.end()});
}

void ApBridge::send_scouts(const std::vector<int64_t>& locations)
{
    std::lock_guard lock(m_mutex);
    if (m_client) m_client->LocationScouts({locations.begin(), locations.end()}, 0);
}

void ApBridge::say(const std::string& text)
{
    std::lock_guard lock(m_mutex);
    if (m_client) m_client->Say(text);
}

void ApBridge::goal()
{
    std::lock_guard lock(m_mutex);
    if (m_client) m_client->StatusUpdate(APClient::ClientStatus::GOAL);
}

void ApBridge::set_tags(const std::string& tags_csv)
{
    std::list<std::string> tags;
    std::stringstream ss(tags_csv);
    for (std::string t; std::getline(ss, t, ',');)
        if (!t.empty()) tags.push_back(t);
    std::lock_guard lock(m_mutex);
    if (m_client) m_client->ConnectUpdate(false, 0, true, tags);
}

void ApBridge::bounce(const std::string& json_data, const std::string& tags_csv)
{
    std::lock_guard lock(m_mutex);
    if (!m_client) return;
    auto data = nlohmann::json::parse(json_data, nullptr, false);
    if (data.is_discarded())                 // not JSON: say so instead of sending an empty bounce
    {
        push(join({"status", "error", "bounce not sent: its data is not JSON"}));
        return;
    }
    std::list<std::string> tags;
    std::stringstream ss(tags_csv);
    for (std::string t; std::getline(ss, t, ',');)
        if (!t.empty()) tags.push_back(t);
    m_client->Bounce(data, {}, {}, tags);
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

auto ApBridge::player_slot() -> int
{
    std::lock_guard lock(m_mutex);
    return m_client ? m_client->get_player_number() : -1;
}
