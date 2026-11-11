// The Archipelago connection, independent of UE4SS and Lua: apclientpp on its own thread, with a small text API the
// Lua mod calls through the UE4SS C++ mod (dllmain.cpp). Method names avoid Unreal macros (check, verify, ensure),
// which UE4SS's headers define in dllmain.cpp. Checked by hand: tools/bridge_test.sh builds test/bridge_test.cpp and
// runs it against a local server. CI does not run it.
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
    // slot_name: the player's name in the multiworld.
    void connect(const std::string& server, const std::string& slot_name, const std::string& password);
    // Closes the connection, if there is one, and pushes "status disconnected".
    void disconnect();

    // Everything that happened since the last call, one event per line, fields separated by tabs:
    //   status   <state> [detail]                          connecting, socket (connected, slot not joined yet),
    //                                                      connected, refused, disconnected, or error (only logged)
    //   item     <index> <item id> <location id> <player number> <flags> <item name> <player name>
    //   scout    <location id> <item id> <player number> <flags> <item name> <player name> <game>
    //   checked  <location id>                             checked elsewhere (co-op, !collect)
    //   message  <text> <type>                             type: PrintJSON's ("Hint", "CommandResult", "" ...)
    //   bounce   <tags> <json>                             Death Link and other bounces
    // Tabs and line breaks inside a field become spaces; an empty field is kept (two tabs in a row).
    // A status's detail: connecting, the server address; connected, the slot name; refused, the server's reasons
    // ("InvalidSlot, InvalidPassword"); error, what went wrong. One error is normal on every connection to a server
    // without TLS (wss is tried first); "... not sent: ..." errors are requests this bridge did not send.
    // <player number> is the player's number in the multiworld, <player name> their alias; <flags> are
    // Archipelago's item flags (1 progression, 2 useful, 4 trap); <tags> are "A,B"; <json> is the bounce's data
    // object ("{}" if none).
    // Built in event_lines.cpp; read by main.lua's on<Kind> handlers (EVENT_HANDLERS).
    auto take_events() -> std::string;

    // Sends location checks.
    void send_checks(const std::vector<int64_t>& locations);
    // Asks what the locations hold; the answers come back as "scout" lines.
    void send_scouts(const std::vector<int64_t>& locations);
    // Sends a chat line or a server command ("!hint ...").
    void say(const std::string& text);
    // Reports the goal complete.
    void goal();
    // Sends a bounce (Death Link) with this data (JSON) to the clients with these tags ("A,B").
    void bounce(const std::string& json_data, const std::string& tags_csv);
    // The connection's tags ("AP,DeathLink"): which bounces the server sends us (ConnectUpdate). Every join and
    // rejoin starts again with JOIN_TAGS ("AP"), so Lua must call this after each "status connected" line.
    void set_tags(const std::string& tags_csv);

    // A value from slot_data by dotted path ("options.tower_count"), as text ("" when absent). JSON for objects.
    auto slot_data(const std::string& path) -> std::string;
    // The stored connection state (see m_status). Used by AP_Status and test/bridge_test.cpp; the Lua mod follows
    // the status lines instead.
    auto status() -> std::string;
    // This player's number in the multiworld, -1 before connect(). Used only by test/bridge_test.cpp.
    auto player_number() -> int;
    // "points,cost": the slot's hint points and what a hint costs ("" when not connected).
    auto hint_points() -> std::string;

  private:
    void run();
    void push(const std::string& line);
    void set_status(const std::string& state);
    void set_status(const std::string& state, const std::string& detail);
    void wire_handlers();
    void wire_connection_handlers();
    void wire_item_handlers();
    void wire_message_handlers();

    std::string m_game, m_uuid, m_cert_store;
    std::string m_slot_name, m_password;
    std::unique_ptr<APClient> m_client;
    // Guards m_client, m_slot_name, m_password, m_events, m_slot_data_json and m_status; poll() runs the handlers
    // under it.
    std::recursive_mutex m_mutex;
    std::vector<std::string> m_events;
    std::string m_slot_data_json;
    // The connection's state, one of four words, each also pushed as a "status" line by set_status():
    //   disconnected  no connection: at the start, after disconnect(), or when the socket drops (apclientpp then
    //                 reconnects by itself and joins the slot again)
    //   connecting    connect() was called; the socket is being opened
    //   connected     the slot joined; checks, scouts, chat and the goal reach the server
    //   refused       the server turned the slot down (the line's detail says why; the player is told)
    // "socket" (the socket opened, the slot not joined yet) and "error" are status lines only, never stored.
    std::string m_status = "disconnected";
    std::atomic<bool> m_running{false};
    std::thread m_thread;
};
