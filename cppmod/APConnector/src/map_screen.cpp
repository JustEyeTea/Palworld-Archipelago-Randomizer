// The world map screen from C++ (see map_screen.hpp). WBP_Map_Body_C:Setup builds the screen: it makes the fog's
// material (a dynamic instance of MI_UI_Menu_MapCloud on Image_MapMask, kept in MaskTextureMaterial, its TargetTexture
// the player's explored mask) and shows the map's picture in Image_MapBody (read from the server pak).
// Lua's hooks on Blueprint functions run late (and touching widgets inside them crashed the client), so Lua set the
// picture on its next update and the game's own showed first. Here a post-callback on the Blueprint VM runs inside the
// same call, on the game thread, before the screen draws: the picture and the fog are set before the first frame.
//
// Hooked the way UE4SS's own mods do it: RegisterProcessLocalScriptFunctionPostCallback (Blueprint calling
// Blueprint) and RegisterProcessInternalPostCallback / RegisterProcessEventPostCallback (calls from native code), as
// EventViewerMod (cppmods/EventViewerMod/src/Middleware.cpp) and LuaMod.cpp (script_hook, process_event_hook)
// register them. Every Blueprint call passes through them, so each compares one pointer and returns. The Setup
// function exists only once its class has loaded; an engine-tick callback (game thread, as EventViewer.cpp's) looks
// for it every SETUP_LOOK_EVERY_FRAMES frames.
//
// It also logs the screen's call order: for the first openings in each world (LOG_BURSTS) the screen's functions in
// the order they run, with the frame number, so a log shows the order if Setup ever stops being the right moment
// (after a game update). In game, Setup ran in the frame the map first opened, just after OnInitialized, and the map
// showed the mod's picture.
// Tests: none; it needs Unreal, so only CI's Windows build compiles it. UE4SS.log's "[APConnector] [map]" lines show
// what it did in game.
#include "map_screen.hpp"
#include "lua_text.hpp"
#include "reflect.hpp"

#include <atomic>
#include <exception>
#include <mutex>
#include <sstream>
#include <unordered_set>
#include <vector>

#include <Unreal/FFrame.hpp>
#include <Unreal/Hooks/Hooks.hpp>

namespace map_screen_unreal
{
    using namespace ap_reflect;

    constexpr auto SETUP_PATH = STR("/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Body.WBP_Map_Body_C:Setup");
    // How often the frame tick looks for Setup: about once a second at 60 fps. Setup's class loads with a world, and
    // the map is first opened well after that.
    constexpr uint64_t SETUP_LOOK_EVERY_FRAMES = 60;
    // Each world's first Setups are logged in full (they show whether the swap worked); after those, one in
    // SETUP_LOG_EVERY, so a long session's log still shows it running.
    constexpr int SETUPS_LOGGED_IN_FULL = 5;
    constexpr int SETUP_LOG_EVERY = 50;
    // The call log: the screen's own functions, each name once per burst of calls (an opening), for the first
    // openings. Counted in bursts, not calls: the first opening alone makes 64 icon calls.
    constexpr int LOG_BURSTS = 8;              // bursts logged per world
    constexpr uint64_t BURST_GAP = 30;         // frames without a call to the screen that end a burst

    // Kept state. The DLL lives all session, so what is not said to be forgotten is kept until the game closes.
    std::mutex g_lock;                         // guards what Lua sets, g_last and g_unknown_logged
    std::string g_body;                        // the map picture's object path ("" = the game's own); until Lua's next
    std::string g_fog_colour;                  // "r,g,b,a" ("" = the game's own); until Lua's next
    std::string g_fog_picture;                 // the fog picture's object path ("" = none); forgotten when Setup's
                                               // class unloads (forget_fog_picture)
    std::string g_last;                        // what the last Setup did, for the status line
    std::unordered_set<std::string> g_unknown_logged;   // unknown commands already logged
    std::atomic<UFunction*> g_setup{nullptr};  // Setup while its class is loaded; null once it unloads
    std::atomic<UObject*> g_class{nullptr};    // WBP_Map_Body_C, for the call log; null with g_setup
    std::atomic<uint64_t> g_frame{0};          // frames since install
    std::atomic<int> g_setups{0};              // how often Setup ran, all session
    std::atomic<int> g_bodies{0}, g_fog_colours{0}, g_fog_pictures{0};   // how often each was applied
    std::atomic<int> g_logged{0};              // Setups logged since Setup was (last) found
    std::mutex g_call_log_lock;                // guards the call log's burst state below
    std::unordered_set<std::string> g_burst_names;   // the functions logged in this burst
    uint64_t g_burst_frame = 0;                // the frame of the last call to the screen
    int g_bursts = 0;                          // bursts since Setup was (last) found
    std::atomic<bool> g_hooked{false};         // the Blueprint callbacks are registered (once a session)
    std::atomic<bool> g_enabled{false};        // Lua's "enable"; off until Lua turns it on
    std::atomic<int> g_errors{0};              // exceptions the callbacks caught (only the first is logged)

    // A line in UE4SS.log, under "[APConnector] [map]".
    auto say(const std::string& line) -> void
    {
        Output::send<LogLevel::Verbose>(STR("[APConnector] [map] {}\n"), ensure_str(line));
    }

    // An FName property of an object, as text ("?" if it has none of that name, or it is not an FName).
    auto fname_field(UObject* obj, const CharType* field) -> std::string
    {
        FProperty* p = obj->GetPropertyByNameInChain(FromCharTypePtr<TCHAR>(field));
        if (!p || static_cast<size_t>(p->GetSize()) != sizeof(FName)) return "?";   // an FName by its size
        return to_string(p->ContainerPtrToValuePtr<FName>(obj)->ToString());
    }

    // The object a widget's brush shows (Brush.ResourceObject), or null.
    auto brush_resource(UObject* image) -> UObject*
    {
        FProperty* brush = image->GetPropertyByNameInChain(FromCharTypePtr<TCHAR>(STR("Brush")));
        if (!brush) throw Fail{class_of(image) + ".Brush: missing"};
        FProperty* res = member(brush, STR("ResourceObject"));
        if (!res->IsA<FObjectProperty>() || res->GetSize() != sizeof(UObject*))
        {
            throw Fail{"Brush.ResourceObject: not an object"};
        }
        return *reinterpret_cast<UObject**>(brush->ContainerPtrToValuePtr<uint8_t>(image) + res->GetOffset_Internal());
    }

    // Sets the fog material's colour ("r,g,b,a" in linear light).
    auto set_fog_colour(UObject* material, const std::string& rgba) -> void
    {
        struct LinearColor
        {
            float r, g, b, a;
        };
        std::vector<float> parts;
        if (!lua_text::parse_floats(rgba, ',', parts) || parts.size() != 4) throw Fail{"fog colour '" + rgba + "'"};
        const LinearColor c{parts[0], parts[1], parts[2], parts[3]};
        constexpr auto SET_VECTOR = STR("/Script/Engine.MaterialInstanceDynamic:SetVectorParameterValue");
        ReflectedCall call(material, resolve(material, SET_VECTOR));
        *call.at<FName>(call.param(STR("ParameterName"))) = FName(STR("Color"), FNAME_Find);
        *call.at<LinearColor>(call.param(STR("Value"))) = c;
        call.run();
    }

    // Makes an Image widget show `picture` (the map's body or the fog image).
    auto set_image_picture(UObject* image, UObject* picture) -> void
    {
        ReflectedCall call(image, resolve(image, STR("/Script/UMG.Image:SetBrushResourceObject")));
        *call.at<UObject*>(call.param(STR("ResourceObject"))) = picture;
        call.run();
    }

    // The object at an object path Lua gave; a Fail naming `what` if there is none.
    auto find_picture(const std::string& path, const std::string& what) -> UObject*
    {
        const StringType wide = ensure_str(path);
        UObject* picture = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, wide.c_str());
        if (!picture) throw Fail{what + " " + path + " was not found"};
        return picture;
    }

    // What Lua set, copied under the lock so a Setup can use it without holding the lock.
    struct LuaSettings
    {
        std::string body, fog_colour, fog_picture;
    };
    auto settings_now() -> LuaSettings
    {
        std::lock_guard<std::mutex> guard(g_lock);
        return {g_body, g_fog_colour, g_fog_picture};
    }

    // The screen as the game's Setup left it.
    struct Screen
    {
        UObject* widget;
        bool main_map;                 // the main world's map, not the World Tree's
        UObject* body;                 // Image_MapBody, or null
        std::string shown;             // what it shows, or "none"
    };

    // Reads the screen, and adds its map and picture to `did`.
    auto describe_screen(UObject* widget, std::ostringstream& did) -> Screen
    {
        const std::string map = fname_field(widget, STR("MapName"));
        did << " map " << map;
        Screen s{widget, false, object_field(widget, STR("Image_MapBody")), "none"};
        UObject* shown = s.body ? brush_resource(s.body) : nullptr;
        if (shown)
        {
            s.shown = to_string(shown->GetFullName());
        }
        did << ", showing " << s.shown;
        // Only the main world's map: the World Tree has a screen of its own (MapName "Tree"), which also shows
        // T_WorldMap while it is set up, so the picture's name alone can't tell the two apart.
        s.main_map = map.find("Main") != std::string::npos;
        return s;
    }

    // The mod's map picture in place of the game's T_WorldMap, on the main world's map only.
    auto show_mod_picture(const Screen& s, const LuaSettings& lua, std::ostringstream& did) -> void
    {
        if (lua.body.empty() || !s.body || !s.main_map || s.shown.find("T_WorldMap") == std::string::npos) return;
        set_image_picture(s.body, find_picture(lua.body, "the mod's picture"));
        ++g_bodies;
        did << "; set the mod's picture";
    }

    // The fog, on the main world's map only: the mod's fog picture in the fog image in place of the game's material
    // (the chart or the Territories' fog art where unexplored, clear where explored), else the fog colour on the
    // game's material.
    auto show_fog(const Screen& s, const LuaSettings& lua, std::ostringstream& did) -> void
    {
        UObject* material = object_field(s.widget, STR("MaskTextureMaterial"));
        did << "; fog " << (material ? class_of(material) + " " + name_of(material) : std::string("none"));
        UObject* mask_image = object_field(s.widget, STR("Image_MapMask"));
        if (!lua.fog_picture.empty() && mask_image && s.main_map)
        {
            set_image_picture(mask_image, find_picture(lua.fog_picture, "the fog picture"));
            ++g_fog_pictures;
            did << "; showed the fog picture";
        }
        else if (!lua.fog_colour.empty() && material && s.main_map)
        {
            set_fog_colour(material, lua.fog_colour);
            ++g_fog_colours;
            did << " coloured " << lua.fog_colour;
        }
    }

    // Keeps what a Setup did for the status line, and logs it: each world's first SETUPS_LOGGED_IN_FULL, then one in
    // SETUP_LOG_EVERY.
    auto record_setup(const std::string& did, int n) -> void
    {
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_last = did;
        }
        if (++g_logged <= SETUPS_LOGGED_IN_FULL || n % SETUP_LOG_EVERY == 0)
        {
            say(did);
        }
    }

    // After the game's Setup, inside the same call: the map's picture and the fog, before the screen draws.
    auto on_setup(UObject* screen, const char* route) -> void
    {
        const int n = ++g_setups;
        const LuaSettings lua = settings_now();
        std::ostringstream did;
        did << "Setup #" << n << " (" << route << ", frame " << g_frame.load() << ")";
        try
        {
            const Screen s = describe_screen(screen, did);
            show_mod_picture(s, lua, did);
            show_fog(s, lua, did);
        }
        catch (const Fail& f)
        {
            did << "; FAILED: " << f.reason;
        }
        catch (const std::exception& e)
        {
            did << "; FAILED: exception " << e.what();
        }
        record_setup(did.str(), n);
    }

    // One of the screen's own functions ran: logged the first time its name shows up in this burst of calls.
    auto log_screen_call(UFunction* fn, const char* route) -> void
    {
        const uint64_t frame = g_frame.load(std::memory_order_relaxed);
        std::lock_guard<std::mutex> guard(g_call_log_lock);
        if (g_bursts == 0 || frame > g_burst_frame + BURST_GAP)
        {
            ++g_bursts;
            g_burst_names.clear();
            if (g_bursts <= LOG_BURSTS)
            {
                say("burst " + std::to_string(g_bursts) + " of the screen's calls from frame " + std::to_string(frame));
            }
        }
        g_burst_frame = frame;
        if (g_bursts > LOG_BURSTS) return;
        const std::string name = to_string(fn->GetName());
        if (g_burst_names.insert(name).second)
        {
            say("frame " + std::to_string(frame) + ": " + name + " (" + route + ")");
        }
    }

    // An exception from a callback the game called (every Blueprint call, every frame) would take the game down, so
    // the callbacks catch it here and log the first one; the rest are counted in silence.
    auto caught(const char* where, const std::exception& e) -> void
    {
        if (++g_errors == 1)
        {
            say(std::string("error in ") + where + " (later ones not logged): " + e.what());
        }
    }

    // Every Blueprint call: Setup is acted on; the screen's own functions go to the call log.
    auto seen(UObject* context, UFunction* fn, const char* route) -> void
    {
        if (!fn) return;
        try
        {
            const bool setup = fn == g_setup.load(std::memory_order_relaxed);
            if (setup && g_enabled.load(std::memory_order_relaxed))
            {
                on_setup(context, route);
            }
            UObject* cls = g_class.load(std::memory_order_relaxed);
            if (cls && fn->GetOuterPrivate() == cls)
            {
                log_screen_call(fn, route);
            }
        }
        catch (const std::exception& e)
        {
            caught("the Blueprint callback", e);
        }
    }

    // The callback for a Blueprint function a Blueprint (or native code) called: hands the function to seen().
    auto script_post(Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) -> void
    {
        UFunction* fn = stack.Node();
        if (!fn)
        {
            fn = stack.CurrentNativeFunction();
        }
        seen(context, fn, "script");
    }

    // The callback for ProcessEvent (a call from native code): hands the function to seen().
    auto event_post(Hook::TCallbackIterationData<void>&, UObject* context, UFunction* fn, void*) -> void
    {
        seen(context, fn, "event");
    }

    // The last world's screen went: its fog picture shows that world's explored areas and lock stamps, and the texture
    // stays findable (Lua keeps it alive), so it is forgotten until Lua hands over the new world's.
    auto forget_fog_picture() -> void
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_fog_picture.empty()) return;
        say("forgot the last world's fog picture " + g_fog_picture);
        g_fog_picture.clear();
    }

    // Registers the Blueprint callbacks; once, when Setup is first found.
    auto hook_blueprint_calls(UFunction* setup, uint64_t frame) -> void
    {
        const Hook::FCallbackOptions options{false, true, STR("APConnector"), STR("MapScreen")};
        Hook::RegisterProcessLocalScriptFunctionPostCallback(&script_post, options);
        Hook::RegisterProcessInternalPostCallback(&script_post, options);
        Hook::RegisterProcessEventPostCallback(&event_post, options);
        g_hooked = true;
        say("hooked " + to_string(setup->GetFullName()) + " at frame " + std::to_string(frame));
    }

    // Game thread, every frame: counts frames, and every SETUP_LOOK_EVERY_FRAMES looks for Setup: the first time to
    // hook the Blueprint VM, then to follow it. The screen's class goes with a world and is loaded anew with the next
    // (Return to title, then a world load), so Setup becomes a new object and a pointer kept from the first world
    // would never match again. The callbacks are registered once; only the pointer they compare against changes.
    auto tick() -> void
    {
        const uint64_t frame = ++g_frame;
        if (frame % SETUP_LOOK_EVERY_FRAMES != 0) return;
        auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, SETUP_PATH);
        UFunction* const before = g_setup.load(std::memory_order_relaxed);
        if (fn == before) return;
        // Forgotten when the old Setup goes, not when a new one is found: Lua may hand over the new world's picture
        // before the new world's screen class loads.
        if (before)
        {
            forget_fog_picture();
        }
        if (!fn)                                   // (the class unloaded, as at Return to title)
        {
            g_setup = nullptr;
            g_class = nullptr;
            say("Setup gone (its class unloaded) at frame " + std::to_string(frame));
            return;
        }
        g_class = fn->GetOuterPrivate();
        g_setup = fn;
        g_logged = 0;
        {
            std::lock_guard<std::mutex> guard(g_call_log_lock);
            g_bursts = 0;                          // (the new world's first openings are logged too)
        }
        if (!g_hooked.load(std::memory_order_relaxed))
        {
            hook_blueprint_calls(fn, frame);
        }
        else
        {
            say("found Setup again (its class loaded anew) at frame " + std::to_string(frame));
        }
    }

    // Keeps a path Lua set, logging it when it changed. `what` names it in the log, `none` says what "" means.
    auto set_kept(std::string& kept, const std::string& value, const std::string& what, const std::string& none)
        -> void
    {
        if (value != kept)
        {
            say(what + ": " + (value.empty() ? none : value));
        }
        kept = value;
    }

    // The status line (map_screen.hpp). The caller holds g_lock.
    auto status_line() -> std::string
    {
        std::ostringstream s;
        s << (g_enabled ? "" : "OFF; ") << (g_hooked ? "hooked" : "not hooked yet") << "; Setup ran " << g_setups
          << "x, picture set " << g_bodies << "x, fog colour set " << g_fog_colours << "x, fog picture shown "
          << g_fog_pictures << "x" << (g_last.empty() ? "" : "; last: " + g_last);
        return s.str();
    }
} // namespace map_screen_unreal

namespace map_screen
{
    auto command(const std::string& cmd, const std::string& value) -> std::string
    {
        using namespace map_screen_unreal;
        std::lock_guard<std::mutex> guard(g_lock);
        if (cmd == "body")
        {
            set_kept(g_body, value, "the mod's picture", "none");
            return "";
        }
        if (cmd == "fog")
        {
            set_kept(g_fog_colour, value, "fog colour", "the game's own");
            return "";
        }
        if (cmd == "fogpic")
        {
            set_kept(g_fog_picture, value, "the fog picture", "none");
            return "";
        }
        if (cmd == "enable")
        {
            g_enabled = value == "1";
            // Lua switches it off for either reason; MAP_FOG.mapOff logs the second ("switched off, the game's own
            // map here").
            const char* off = "off (config.txt map_cpp=0, or a world or seed without the mod's map)";
            say(std::string("changing the map screen: ") + (g_enabled ? "on" : off));
            return "";
        }
        if (cmd == "status") return status_line();
        // Lua reads only the status's answer, so a misspelt command would otherwise leave no trace.
        if (g_unknown_logged.insert(cmd).second)
        {
            say("unknown command '" + cmd + "' (value '" + value + "') ignored");
        }
        return "unknown command " + cmd;
    }

    auto install() -> void
    {
        using namespace map_screen_unreal;
        Hook::RegisterEngineTickPreCallback(
                [](auto&, auto*, float, bool) {
                    try
                    {
                        tick();
                    }
                    catch (const std::exception& e)
                    {
                        caught("the frame tick", e);
                    }
                },
                {false, true, STR("APConnector"), STR("MapScreenTick")});
        say("waiting for the map screen's class");
    }
} // namespace map_screen
