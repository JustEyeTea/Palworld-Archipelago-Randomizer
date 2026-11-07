// APConnector: the UE4SS C++ mod that gives the PalworldArchipelago Lua mod its Archipelago connection. When that Lua
// mod starts, these functions appear as globals in each of its Lua states (all text in, text out):
//   AP_Connect(server, slot, password)   start connecting ("archipelago.gg:12345" tries wss then ws)
//   AP_Disconnect()
//   AP_Poll() -> string                  events since the last call, one per line (see ap_bridge.hpp)
//   AP_Check("id,id,...")                send location checks
//   AP_Scout("id,id,...")                ask what locations hold (answers come back as "scout" events)
//   AP_Say(text)                         chat or a server command ("!hint ...")
//   AP_Goal()                            report the goal complete
//   AP_Bounce(json, "Tag,Tag")           send a bounce (Death Link)
//   AP_SetTags("AP,DeathLink")           the connection's tags (which bounces the server sends us)
//   AP_SlotData(path) -> string          a slot_data value by dotted path ("options.tower_count")
//   AP_Status() -> string                disconnected | connecting | connected | refused
//   AP_HintPoints() -> string            "points,cost" (hint points held, cost of a hint), "" when not connected
//   AP_GreyscalePNG(in, out, gamma) -> string   writes a greyscale copy of a PNG ("" on success, else the error)
//   AP_ComposeMap(colour, labels, "3,7", out, gamma) -> string   starts composing the world map (locked areas grey) in
//                                        the background: "" started, "busy", or an error
//   AP_ComposeStatus() -> string         "busy", "done" (once, when finished), "error: ..." or ""
//   AP_GivePal(species, level, route, options) -> string   gives the player a Pal ("Anubis", "50", "auto", ""); a report,
//                                        one step per line, the last "result: ok party|ok palbox|pending|busy|fail ..."
//                                        (see pal_gift.cpp; game thread only, so call it inside ExecuteInGameThread)
//   AP_GivePalPoll() -> string           while a gift is pending, a report ending like AP_GivePal's; else ""
//   (AP_GivePal and AP_GivePalPoll are untested in game.)
//   AP_ComposeChart(colour, paper, sea, compass, out, size, gamma) -> string   starts drawing the explorer's-chart
//                                        picture of the map in the background ("" started, "busy", or an error)
//   AP_ChartStatus() -> string           "busy", "done" (once), "error: ..." or ""
//   AP_ComposeFog(chart, mask, default, spec, out, size, stamps) -> string   starts the fog picture (the chart where
//                                        unexplored, the locked areas' stamps on it; image_tools.hpp)
//   AP_FogStatus() -> string             as AP_ChartStatus (chart and fog untested in game)
//   AP_SamplePNG(path, u, v) -> string   a PNG's colour at (u, v) in 0..1: "r,g,b,a", or "error: ..."
//   AP_MapScreen(cmd, value) -> string  the world map screen, changed inside the game's own Setup so it never shows the
//                                        game's version first: "body", path / "fog", "r,g,b,a" / "status" (map_screen.hpp;
//                                        untested in game)
#include <Windows.h>

#include <cstdio>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Mod/CppUserModBase.hpp>

#include "ap_bridge.hpp"
#include "image_tools.hpp"
#include "map_screen.hpp"
#include "pal_gift.hpp"

using namespace RC;

namespace
{
    constexpr auto LUA_MOD_NAME = STR("PalworldArchipelago");
    std::unique_ptr<ApBridge> g_bridge;

    // This DLL sits in ue4ss/Mods/APConnector/dlls/main.dll; its data (cacert.pem, the client UUID) one folder up.
    auto mod_folder() -> std::string
    {
        HMODULE self{};
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(&mod_folder), &self);
        char path[MAX_PATH]{};
        GetModuleFileNameA(self, path, MAX_PATH);
        std::string p(path);
        for (int up = 0; up < 2; ++up) p = p.substr(0, p.find_last_of("\\/"));
        return p;
    }

    // One UUID per installation, kept next to the mod, so the server recognises this client between sessions.
    auto client_uuid(const std::string& folder) -> std::string
    {
        const auto file = folder + "\\client_uuid.txt";
        if (FILE* f = std::fopen(file.c_str(), "r"))
        {
            char buf[64]{};
            std::fgets(buf, sizeof buf, f);
            std::fclose(f);
            std::string id(buf);
            while (!id.empty() && (id.back() == '\n' || id.back() == '\r')) id.pop_back();
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

    auto bridge() -> ApBridge&
    {
        if (!g_bridge)
        {
            const auto folder = mod_folder();
            g_bridge = std::make_unique<ApBridge>("Palworld", client_uuid(folder), folder + "\\cacert.pem");
        }
        return *g_bridge;
    }

    auto ids(std::string_view csv) -> std::vector<int64_t>
    {
        std::vector<int64_t> out;
        std::stringstream ss{std::string(csv)};
        for (std::string part; std::getline(ss, part, ',');)
        {
            if (!part.empty()) out.push_back(std::stoll(part));
        }
        return out;
    }

    auto arg(const LuaMadeSimple::Lua& lua) -> std::string
    {
        return lua.is_string() ? std::string(lua.get_string()) : std::string();
    }

    void register_api(LuaMadeSimple::Lua& lua)
    {
        lua.register_function("AP_Connect", [](const LuaMadeSimple::Lua& l) -> int {
            const auto server = arg(l), slot = arg(l), password = arg(l);
            bridge().connect(server, slot, password);
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
            bridge().send_checks(ids(arg(l)));
            return 0;
        });
        lua.register_function("AP_Scout", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().send_scouts(ids(arg(l)));
            return 0;
        });
        lua.register_function("AP_Say", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().say(arg(l));
            return 0;
        });
        lua.register_function("AP_Goal", [](const LuaMadeSimple::Lua&) -> int {
            bridge().goal();
            return 0;
        });
        lua.register_function("AP_Bounce", [](const LuaMadeSimple::Lua& l) -> int {
            const auto data = arg(l), tags = arg(l);
            bridge().bounce(data, tags);
            return 0;
        });
        lua.register_function("AP_SetTags", [](const LuaMadeSimple::Lua& l) -> int {
            bridge().set_tags(arg(l));
            return 0;
        });
        lua.register_function("AP_SlotData", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(bridge().slot_data(arg(l)));
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
        lua.register_function("AP_ComposeMap", [](const LuaMadeSimple::Lua& l) -> int {
            const auto colour = arg(l), labels = arg(l), locked = arg(l), out = arg(l), gamma = arg(l);
            double g = 1.0;
            try { g = std::stod(gamma); } catch (...) {}
            l.set_string(compose_map_start(colour, labels, locked, out, g));
            return 1;
        });
        lua.register_function("AP_ComposeStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(compose_map_status());
            return 1;
        });
        lua.register_function("AP_ComposeChart", [](const LuaMadeSimple::Lua& l) -> int {
            const auto colour = arg(l), paper = arg(l), sea = arg(l), compass = arg(l), out = arg(l), size = arg(l), gamma = arg(l);
            int s = 2048;
            double g = 1.0;
            try { s = std::stoi(size); } catch (...) {}
            try { g = std::stod(gamma); } catch (...) {}
            l.set_string(chart_jobs().start([=] { return compose_chart(colour, paper, sea, compass, out, s, g); }));
            return 1;
        });
        lua.register_function("AP_ChartStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(chart_jobs().status());
            return 1;
        });
        lua.register_function("AP_ComposeFog", [](const LuaMadeSimple::Lua& l) -> int {
            const auto chart = arg(l), mask = arg(l), def = arg(l), spec = arg(l), out = arg(l), size = arg(l), stamps = arg(l);
            int s = 2048;
            try { s = std::stoi(size); } catch (...) {}
            l.set_string(fog_jobs().start([=] { return compose_fog(chart, mask, def, spec, out, s, stamps); }));
            return 1;
        });
        lua.register_function("AP_FogStatus", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(fog_jobs().status());
            return 1;
        });
        lua.register_function("AP_SamplePNG", [](const LuaMadeSimple::Lua& l) -> int {
            const auto path = arg(l), u = arg(l), v = arg(l);
            double fu = 0, fv = 0;
            try { fu = std::stod(u); fv = std::stod(v); } catch (...) {}
            l.set_string(sample_png(path, fu, fv));
            return 1;
        });
        lua.register_function("AP_GreyscalePNG", [](const LuaMadeSimple::Lua& l) -> int {
            const auto in = arg(l), out = arg(l), gamma = arg(l);
            double g = 1.0;
            try { g = std::stod(gamma); } catch (...) {}
            l.set_string(greyscale_png(in, out, g));
            return 1;
        });
        lua.register_function("AP_GivePal", [](const LuaMadeSimple::Lua& l) -> int {
            const auto species = arg(l), level = arg(l), route = arg(l), options = arg(l);
            l.set_string(give_pal(species, level, route, options));
            return 1;
        });
        lua.register_function("AP_GivePalPoll", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_string(give_pal_poll());
            return 1;
        });
        lua.register_function("AP_MapScreen", [](const LuaMadeSimple::Lua& l) -> int {
            const auto cmd = arg(l), value = arg(l);
            l.set_string(map_screen::command(cmd, value));
            return 1;
        });
    }
} // namespace

class APConnector : public CppUserModBase
{
  public:
    APConnector()
    {
        ModName = STR("APConnector");
        ModVersion = STR("0.1.0");
        ModDescription = STR("Archipelago connection for the Palworld Archipelago mod");
        ModAuthors = STR("JustEyeTee");
        Output::send<LogLevel::Verbose>(STR("[APConnector] loaded\n"));
    }

    ~APConnector() override
    {
        g_bridge.reset();
    }

    auto on_unreal_init() -> void override
    {
        map_screen::install();
    }

    auto on_lua_start(StringViewType mod_name, LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua,
                      LuaMadeSimple::Lua& async_lua, LuaMadeSimple::Lua* hook_lua) -> void override
    {
        if (mod_name != LUA_MOD_NAME) return;
        register_api(lua);
        register_api(main_lua);
        register_api(async_lua);
        if (hook_lua) register_api(*hook_lua);
        Output::send<LogLevel::Verbose>(STR("[APConnector] AP_* functions registered for {}\n"), mod_name);
    }
};

#define AP_CONNECTOR_API __declspec(dllexport)
extern "C"
{
    AP_CONNECTOR_API CppUserModBase* start_mod()
    {
        return new APConnector();
    }

    AP_CONNECTOR_API void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
