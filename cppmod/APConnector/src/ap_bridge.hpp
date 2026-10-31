// The Archipelago connection, independent of UE4SS and Lua: apclientpp on its own thread, with a small text API the
// Lua mod calls through the UE4SS C++ mod (dllmain.cpp). Tested on Linux by test/bridge_test.cpp against a live server.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class APClient;

class ApBridge
{
  public:
    // cert_store: path to a CA bundle (cacert.pem) for wss://; empty uses the system's store.
    explicit ApBridge(std::string game, std::string uuid, std::string cert_store = "");
    ~ApBridge();

    // Starts (or restarts) a connection. server: "archipelago.gg:12345" (tries wss, then ws) or a full ws(s):// uri.
    void connect(const std::string& server, const std::string& slot, const std::string& password);
    void disconnect();

    // Everything that happened since the last call, one event per line, fields separated by tabs:
    //   status   <state> [detail]                          disconnected | connecting | connected | refused | error
    //   item     <index> <item id> <location id> <player slot> <flags> <item name> <player name>
    //   scout    <location id> <item id> <player slot> <flags> <item name> <player name> <game>
    //   checked  <location id>                             checked elsewhere (co-op, !collect)
    //   message  <text>
    //   bounce   <tags> <json>                             Death Link and other bounces, raw
    auto take_events() -> std::string;

    void check(const std::vector<int64_t>& locations);
    void scout(const std::vector<int64_t>& locations);
    void say(const std::string& text);
    void goal();
    void bounce(const std::string& json_data, const std::string& tags_csv);

    // A value from slot_data by dotted path ("options.tower_count"), as text ("" when absent). JSON for objects.
    auto slot_data(const std::string& path) -> std::string;
    auto status() -> std::string;
    auto player_slot() -> int;

  private:
    void run();
    void push(const std::string& line);
    void wire_handlers();

    std::string m_game, m_uuid, m_cert_store;
    std::string m_server, m_slot, m_password;
    std::unique_ptr<APClient> m_client;
    std::recursive_mutex m_mutex;          // guards m_client, m_events, m_slot_data; poll() runs callbacks under it
    std::vector<std::string> m_events;
    std::string m_slot_data_json;
    std::string m_status = "disconnected";
    std::atomic<bool> m_running{false};
    std::thread m_thread;
};
