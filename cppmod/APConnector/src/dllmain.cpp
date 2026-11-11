// APConnector: the UE4SS C++ mod that gives the PalworldArchipelago Lua mod its Archipelago connection, Pal gifts and
// map pictures. When that Lua mod starts, these functions appear as globals in each of its Lua states. Every argument
// is text, and so is every result (the functions marked -> string; the others return nothing).
// register_connection (ap_bridge.hpp):
//   AP_Connect(server, slot_name, password)   start connecting ("archipelago.gg:12345" tries wss then ws)
//   AP_Disconnect()
//   AP_Poll() -> string                  events since the last call, one per line (see ap_bridge.hpp)
//   AP_Check("id,id,...")                send location checks
//   AP_Scout("id,id,...")                ask what locations hold (answers come back as "scout" events)
//   AP_Say(text)                         chat or a server command ("!hint ...")
//   AP_Goal()                            report the goal complete
//   AP_Bounce(json, "Tag,Tag")           send a bounce (Death Link)
//   AP_SetTags("AP,DeathLink")           the connection's tags (which bounces the server sends us)
//   AP_SlotData(path) -> string          a slot_data value by dotted path ("options.tower_count")
//   AP_HintPoints() -> string            "points,cost" (hint points held, cost of a hint), "" when not connected
//   AP_Status() -> string                disconnected | connecting | connected | refused (not used by the Lua mod,
//                                        which follows the status lines)
// register_picture_jobs (image_tools.hpp): each Compose function starts in the background and returns "" (started)
// or "busy". Every error, even a bad argument, comes from its status function, which returns "busy", then once
// "done" or "error: ...", then "". size "" means 2048 (AP_ComposeField: 4096); gamma "" means 1 (no change).
//   AP_ComposeMap(colour, labels, "3,7", out, gamma)   the world map with the locked areas grey; AP_ComposeStatus()
//                                        (the map job's status only)
//   AP_ComposeChart(colour, paper, sea, compass, out, size, gamma)   the explorer's-chart picture; AP_ChartStatus()
//   AP_ComposeFog(chart, mask, default, spec, out, size, stamps, regions)   the chart where unexplored, with the locked
//                                        areas' stamps; AP_FogStatus()
//   AP_ComposeTerritories(labels, areas, walls, style, out, fogart, fog, size)   the Territories overlay and its fog
//                                        picture from the area label map; AP_TerritoriesStatus()
//   AP_ComposeField(field, areas, walls, style, out, fogart, fog, size, colour, gamma)   the same from a distance field
//                                        (smooth borders), in the Territories job slot; AP_TerritoriesStatus()
// register_png_tools (image_tools.hpp), which run at once:
//   AP_SamplePNG(path, u, v) -> string   a PNG's colour at (u, v) in 0..1: "r,g,b,a", or "error: ..."
//   AP_GreyscalePNG(in, out, gamma) -> string   writes a greyscale copy of a PNG ("" on success, else the error)
// register_map_screen (map_screen.hpp):
//   AP_MapScreen(cmd, value) -> string   the world map screen, changed inside the game's own Setup so it never shows
//                                        the game's version first. Commands: "body", "fog", "fogpic", "enable"
//                                        (the screen is left alone until "enable", "1") and "status"; see
//                                        map_screen.hpp for their values
// register_pal_gifts (pal_gift.hpp; what has been tested in game: see pal_gift.cpp):
//   AP_GivePal(species, level, route, options) -> string   gives the player a Pal ("Anubis", "50", "auto", "");
//                                        a report, one step per line, the last
//                                        "result: ok party|ok palbox|pending|busy|fail ..."
//                                        (game thread only, so call it inside ExecuteInGameThread)
//   AP_GivePalPoll() -> string           while a gift is pending, a report ending like AP_GivePal's; else ""
// This file needs Windows and UE4SS, so only CI's Windows build compiles it and no test runs it; what can be tested
// without them lives in ap_bridge.*, event_lines.*, lua_text.*, image_tools.* and pal_gift_logic.*.
#include <Windows.h>

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>

#include "ap_bridge.hpp"
#include "image_tools.hpp"
#include "lua_text.hpp"
#include "map_screen.hpp"
#include "pal_gift.hpp"

using namespace RC;
using lua_text::double_or;
using lua_text::int_or;
using lua_text::parse_ids;

namespace
{
    // The Lua mod's folder under ue4ss/Mods. If it differs, nothing is registered and UE4SS.log has no
    // "AP_* functions registered" line.
    constexpr auto LUA_MOD_NAME = STR("PalworldArchipelago");
    // The APWorld's game name (apworld/palworld/__init__.py, game = "Palworld").
    constexpr auto ARCHIPELAGO_GAME = "Palworld";
    // In the data folder (mod_folder()): this installation's client id, kept between sessions.
    constexpr auto CLIENT_ID_FILE = "client_uuid.txt";
    // In the data folder: the CA bundle for wss://, packaged there by .github/workflows/ci.yml.
    constexpr auto CERT_FILE = "cacert.pem";
    // main.dll sits in ue4ss/Mods/APConnector/dlls/; the data folder is APConnector/, so two steps up from the
    // DLL's own path (its file name, then dlls/).
    constexpr int STEPS_UP_TO_DATA_FOLDER = 2;

    // When Lua sends "" for a picture's size or gamma. Sizes are in pixels a side.
    constexpr int DEFAULT_PICTURE_SIZE = 2048;   // the chart, the fog and Territories: the area label map's size
    constexpr int DEFAULT_FIELD_SIZE = 4096;     // ComposeField: the distance field's (area_field*.png) own size
    constexpr double GAMMA_UNCHANGED = 1.0;      // value^1: neither brightened nor darkened
    constexpr double SAMPLE_AT_EDGE = 0.0;       // AP_SamplePNG's u or v when it is not a number

    std::unique_ptr<ApBridge> g_bridge;

    // The folder that holds the mod's data (cacert.pem, the client id): one folder up from this DLL's.
    auto mod_folder() -> std::string
    {
        HMODULE self{};
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(&mod_folder), &self);
        char path[MAX_PATH]{};
        GetModuleFileNameA(self, path, MAX_PATH);
        std::string folder(path);
        for (int step = 0; step < STEPS_UP_TO_DATA_FOLDER; ++step)
        {
            folder = folder.substr(0, folder.find_last_of("\\/"));
        }
        return folder;
    }

    // One UUID per installation, kept next to the mod, so the server recognises this client between sessions.
    auto client_uuid(const std::string& folder) -> std::string
    {
        const auto file = folder + "\\" + CLIENT_ID_FILE;
        if (FILE* f = std::fopen(file.c_str(), "r"))
        {
            char buf[64]{};
            std::fgets(buf, sizeof buf, f);
            std::fclose(f);
            std::string id(buf);
            while (!id.empty() && (id.back() == '\n' || id.back() == '\r'))
            {
                id.pop_back();
            }
            if (!id.empty()) return id;
        }
        std::string id;
        const char* hex = "0123456789abcdef";
        LARGE_INTEGER t{};
        QueryPerformanceCounter(&t);
        unsigned long long seed = t.QuadPart ^ GetCurrentProcessId();
        for (int i = 0; i < 32; ++i)
        {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            id += hex[(seed >> 59) & 15];
        }
        if (FILE* f = std::fopen(file.c_str(), "w"))
        {
            std::fputs(id.c_str(), f);
            std::fclose(f);
        }
        return id;
    }

    // The one connection, made on first use.
    auto bridge() -> ApBridge&
    {
        if (!g_bridge)
        {
            const auto folder = mod_folder();
            g_bridge = std::make_unique<ApBridge>(ARCHIPELAGO_GAME, client_uuid(folder), folder + "\\" + CERT_FILE);
        }
        return *g_bridge;
    }

    // The next argument Lua passed. Each call takes one, left to right, so a body reads its arguments in the
    // header's order, one call per declared name, each in its own statement (C++ leaves the order of two calls
    // inside one call's brackets open). Lua must pass text: anything else reads as "" and stays in place, so every
    // later argument reads as "" too. A registration returns how many values it hands back to Lua: 0, or 1 (text).
    auto next_text_arg(const LuaMadeSimple::Lua& call) -> std::string
    {
        return call.is_string() ? std::string(call.get_string()) : std::string();
    }

    // The location ids Lua sent, as numbers; each part that is not one is reported as a status error line.
    auto location_ids(const std::string& csv) -> std::vector<int64_t>
    {
        const auto list = parse_ids(csv);
        for (const auto& part : list.skipped)
        {
            bridge().report_error("not a location id: " + part);
        }
        return list.numbers;
    }

    // The Archipelago connection (ap_bridge.hpp): connect, poll events, send checks, scouts, chat, the goal, bounces.
    // In this and every register_* below, no exception may leave a function Lua called: it can take the game down.
    void register_connection(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_Connect", [](const LuaMadeSimple::Lua& l) -> int {
            const auto server = next_text_arg(l);
            const auto slot_name = next_text_arg(l);
            const auto password = next_text_arg(l);
            bridge().connect(server, slot_name, password);
            return 0;
        });
        lua.register_function("AP_Disconnect", [](const LuaMadeSimple::Lua&) -> int {
            bridge().disconnect();
            return 0;
        });
        lua.register_function("AP_Poll", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(bridge().take_events());
            return 1;
        });
        lua.register_function("AP_Check", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().send_checks(location_ids(next_text_arg(l)));
            return 0;
        });
        lua.register_function("AP_Scout", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().send_scouts(location_ids(next_text_arg(l)));
            return 0;
        });
        lua.register_function("AP_Say", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().say(next_text_arg(l));
            return 0;
        });
        lua.register_function("AP_Goal", [](const LuaMadeSimple::Lua&) -> int {
            bridge().goal();
            return 0;
        });
        lua.register_function("AP_Bounce", [](const LuaMadeSimple::Lua& l) -> int {
            const auto data = next_text_arg(l);
            const auto tags = next_text_arg(l);
            bridge().bounce(data, tags);
            return 0;
        });
        lua.register_function("AP_SetTags", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().set_tags(next_text_arg(l));
            return 0;
        });
        lua.register_function("AP_SlotData", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(bridge().slot_data(next_text_arg(l)));
            return 1;
        });
        lua.register_function("AP_HintPoints", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(bridge().hint_points());
            return 1;
        });
        lua.register_function("AP_Status", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(bridge().status());
            return 1;
        });
    }

    // The map pictures (image_tools.hpp): each Compose function starts a background job; its status function says
    // how it went.
    void register_picture_jobs(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_ComposeMap", [](const LuaMadeSimple::Lua& l) -> int {
            const auto colour = next_text_arg(l);
            const auto labels = next_text_arg(l);
            const auto locked = next_text_arg(l);
            const auto out = next_text_arg(l);
            const double gamma = double_or(next_text_arg(l), GAMMA_UNCHANGED);
            l.set_string(map_jobs().start([=] { return compose_map(colour, labels, locked, out, gamma); }));
            return 1;
        });
        lua.register_function("AP_ComposeChart", [](const LuaMadeSimple::Lua& l) -> int {
            const auto colour = next_text_arg(l);
            const auto paper = next_text_arg(l);
            const auto sea = next_text_arg(l);
            const auto compass = next_text_arg(l);
            const auto out = next_text_arg(l);
            const int size = int_or(next_text_arg(l), DEFAULT_PICTURE_SIZE);
            const double gamma = double_or(next_text_arg(l), GAMMA_UNCHANGED);
            l.set_string(
                chart_jobs().start([=] { return compose_chart(colour, paper, sea, compass, out, size, gamma); }));
            return 1;
        });
        lua.register_function("AP_ComposeFog", [](const LuaMadeSimple::Lua& l) -> int {
            const auto chart = next_text_arg(l);
            const auto mask = next_text_arg(l);
            const auto default_mask = next_text_arg(l);
            const auto spec = next_text_arg(l);
            const auto out = next_text_arg(l);
            const int size = int_or(next_text_arg(l), DEFAULT_PICTURE_SIZE);
            const auto stamps = next_text_arg(l);
            const auto regions = next_text_arg(l);
            l.set_string(fog_jobs().start(
                [=] { return compose_fog(chart, mask, default_mask, spec, out, size, stamps, regions); }));
            return 1;
        });
        lua.register_function("AP_ComposeTerritories", [](const LuaMadeSimple::Lua& l) -> int {
            const auto labels = next_text_arg(l);
            const auto areas = next_text_arg(l);
            const auto walls = next_text_arg(l);
            const auto style = next_text_arg(l);
            const auto out = next_text_arg(l);
            const auto fogart = next_text_arg(l);
            const auto fog = next_text_arg(l);
            const int size = int_or(next_text_arg(l), DEFAULT_PICTURE_SIZE);
            l.set_string(territory_jobs().start(
                [=] { return compose_territories(labels, areas, walls, style, out, fogart, fog, size); }));
            return 1;
        });
        // In the Territories job slot: the two make the same pictures, so only one may run.
        lua.register_function("AP_ComposeField", [](const LuaMadeSimple::Lua& l) -> int {
            const auto field = next_text_arg(l);
            const auto areas = next_text_arg(l);
            const auto walls = next_text_arg(l);
            const auto style = next_text_arg(l);
            const auto out = next_text_arg(l);
            const auto fogart = next_text_arg(l);
            const auto fog = next_text_arg(l);
            const int size = int_or(next_text_arg(l), DEFAULT_FIELD_SIZE);
            const auto colour = next_text_arg(l);
            const double gamma = double_or(next_text_arg(l), GAMMA_UNCHANGED);
            l.set_string(territory_jobs().start(
                [=] { return compose_field(field, areas, walls, style, out, fogart, fog, size, colour, gamma); }));
            return 1;
        });
        lua.register_function("AP_ComposeStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(map_jobs().status());
            return 1;
        });
        lua.register_function("AP_ChartStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(chart_jobs().status());
            return 1;
        });
        lua.register_function("AP_FogStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(fog_jobs().status());
            return 1;
        });
        lua.register_function("AP_TerritoriesStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(territory_jobs().status());
            return 1;
        });
    }

    // The PNG tools (image_tools.hpp), which run at once, not as background jobs.
    void register_png_tools(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_SamplePNG", [](const LuaMadeSimple::Lua& l) -> int {
            const auto path = next_text_arg(l);
            const double u = double_or(next_text_arg(l), SAMPLE_AT_EDGE);
            const double v = double_or(next_text_arg(l), SAMPLE_AT_EDGE);
            l.set_string(sample_png(path, u, v));
            return 1;
        });
        lua.register_function("AP_GreyscalePNG", [](const LuaMadeSimple::Lua& l) -> int {
            const auto in = next_text_arg(l);
            const auto out = next_text_arg(l);
            const double gamma = double_or(next_text_arg(l), GAMMA_UNCHANGED);
            l.set_string(greyscale_png(in, out, gamma));
            return 1;
        });
    }

    // The world map screen (map_screen.hpp): what it shows, set inside the game's own Setup.
    void register_map_screen(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_MapScreen", [](const LuaMadeSimple::Lua& l) -> int {
            const auto command = next_text_arg(l);
            const auto value = next_text_arg(l);
            l.set_string(map_screen::command(command, value));
            return 1;
        });
    }

    // Giving the player a Pal (pal_gift.hpp); game thread only.
    void register_pal_gifts(const LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_GivePal", [](const LuaMadeSimple::Lua& l) -> int {
            const auto species = next_text_arg(l);
            const auto level = next_text_arg(l);
            const auto route = next_text_arg(l);
            const auto options = next_text_arg(l);
            l.set_string(give_pal(species, level, route, options));
            return 1;
        });
        lua.register_function("AP_GivePalPoll", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(give_pal_poll());
            return 1;
        });
    }

    // Every AP_* function the header lists, into one of the Lua mod's Lua states.
    void register_api(const LuaMadeSimple::Lua& lua)
    {
        register_connection(lua);
        register_picture_jobs(lua);
        register_png_tools(lua);
        register_map_screen(lua);
        register_pal_gifts(lua);
    }
} // namespace

class APConnector : public CppUserModBase
{
  public:
    APConnector()
    {
        ModName = STR("APConnector");
        ModVersion = STR("0.1.0");    // the connector's own version (UE4SS's mod list); the mod's is main.lua's VERSION
        ModDescription = STR("Archipelago connection for the Palworld Archipelago mod");
        ModAuthors = STR("JustEyeTea");
        Output::send<LogLevel::Verbose>(STR("[APConnector] loaded\n"));
    }

    ~APConnector() override
    {
        g_bridge.reset();
    }

    // Once Unreal is up: hooks the world map screen.
    auto on_unreal_init() -> void override
    {
        map_screen::install();
    }

    // Each time a Lua mod starts: gives the Archipelago Lua mod's Lua states the AP_* functions.
    auto on_lua_start(StringViewType mod_name, LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua,
                      LuaMadeSimple::Lua& async_lua, LuaMadeSimple::Lua* hook_lua) -> void override
    {
        if (mod_name != LUA_MOD_NAME) return;
        register_api(lua);
        register_api(main_lua);
        register_api(async_lua);
        if (hook_lua)
        {
            register_api(*hook_lua);
        }
        Output::send<LogLevel::Verbose>(STR("[APConnector] AP_* functions registered for {}\n"), mod_name);
    }
};

#define AP_CONNECTOR_API __declspec(dllexport)
extern "C"
{
    // UE4SS calls this to load the mod.
    AP_CONNECTOR_API CppUserModBase* start_mod()
    {
        return new APConnector();
    }

    // UE4SS calls this to unload it.
    AP_CONNECTOR_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
