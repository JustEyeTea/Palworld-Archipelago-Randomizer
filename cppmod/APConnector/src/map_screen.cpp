// The world map screen from C++ (see map_screen.hpp). WBP_Map_Body_C:Setup builds the screen: it makes the fog's
// material (a dynamic instance of MI_UI_Menu_MapCloud on Image_MapMask, kept in MaskTextureMaterial, its TargetTexture
// the player's explored mask) and shows the map's picture in Image_MapBody (read from the server pak).
// Lua's hooks on Blueprint functions run late (and touching widgets inside them crashed the client), so Lua set the
// picture on its next update and the game's own showed first. Here a post-callback on the Blueprint VM runs inside the
// same call, on the game thread, before the screen draws: the picture and the fog colour are set before the first frame.
//
// Hooked the way UE4SS's own mods do it: RegisterProcessLocalScriptFunctionPostCallback (Blueprint calling Blueprint)
// and RegisterProcessInternalPostCallback / RegisterProcessEventPostCallback (calls from native code), as EventViewerMod
// (cppmods/EventViewerMod/src/Middleware.cpp) and LuaMod.cpp (script_hook, process_event_hook) register them. Every
// Blueprint call passes through them, so each compares one pointer and returns. The Setup function exists only once
// its class has loaded; an engine-tick callback (game thread, as EventViewer.cpp's) looks for it every 60 frames.
//
// A probe too: for the first openings in each world (LOG_BURSTS) it logs the screen's functions in the order they run,
// with the frame number, so a log shows the order if Setup ever stops being the right moment (after a game update).
// In game, Setup ran in the frame the map first opened, just after OnInitialized, and the map showed the mod's picture.
#include "map_screen.hpp"
#include "reflect.hpp"

#include <atomic>
#include <exception>
#include <mutex>
#include <sstream>
#include <unordered_set>

#include <Unreal/FFrame.hpp>
#include <Unreal/Hooks/Hooks.hpp>

namespace map_screen_unreal
{
    using namespace ap_reflect;

    constexpr auto SETUP_PATH = STR("/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Body.WBP_Map_Body_C:Setup");
    // The probe: the screen's own functions, each name once per burst of calls (an opening), for the first openings.
    // Counted in bursts, not calls: the first opening alone makes 64 icon calls.
    constexpr int LOG_BURSTS = 8;              // bursts logged per session
    constexpr uint64_t BURST_GAP = 30;         // frames without a call to the screen that end a burst

    std::mutex g_lock;                         // guards what Lua sets and the counters' text
    std::string g_body;                        // the picture's object path ("" = the game's own)
    std::string g_fog;                         // "r,g,b,a" ("" = the game's own)
    std::string g_fogpic;                      // the fog picture's object path (the explorer's chart; "" = none);
                                               // forgotten when Setup's class unloads (forget_fog_picture)
    std::string g_last;                        // what the last Setup did

    std::atomic<UFunction*> g_setup{nullptr};
    std::atomic<UObject*> g_class{nullptr};    // WBP_Map_Body_C, for logging its functions
    std::atomic<uint64_t> g_frame{0};
    std::atomic<int> g_setups{0}, g_bodies{0}, g_fogs{0}, g_fogpics{0};
    std::atomic<int> g_logged{0};              // Setups logged in detail since Setup was (last) found
    std::mutex g_probe_lock;                   // guards the probe's burst state below
    std::unordered_set<std::string> g_burst_names;
    uint64_t g_burst_frame = 0;
    int g_bursts = 0;
    std::atomic<bool> g_hooked{false};
    std::atomic<bool> g_enabled{false};        // off until Lua turns it on (config.txt map_cpp=0 keeps it off)

    auto say(const std::string& line) -> void
    {
        Output::send<LogLevel::Verbose>(STR("[APConnector] [map] {}\n"), ensure_str(line));
    }

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
        if (!res->IsA<FObjectProperty>() || res->GetSize() != sizeof(UObject*)) throw Fail{"Brush.ResourceObject: not an object"};
        return *reinterpret_cast<UObject**>(brush->ContainerPtrToValuePtr<uint8_t>(image) + res->GetOffset_Internal());
    }

    auto set_fog(UObject* material, const std::string& rgba) -> void
    {
        struct LinearColor
        {
            float r, g, b, a;
        } c{};
        if (std::sscanf(rgba.c_str(), "%f,%f,%f,%f", &c.r, &c.g, &c.b, &c.a) != 4) throw Fail{"fog colour '" + rgba + "'"};
        ReflectedCall call(material, resolve(material, STR("/Script/Engine.MaterialInstanceDynamic:SetVectorParameterValue")));
        *call.at<FName>(call.param(STR("ParameterName"))) = FName(STR("Color"), FNAME_Find);
        *call.at<LinearColor>(call.param(STR("Value"))) = c;
        call.run();
    }

    auto set_body(UObject* image, UObject* picture) -> void
    {
        ReflectedCall call(image, resolve(image, STR("/Script/UMG.Image:SetBrushResourceObject")));
        *call.at<UObject*>(call.param(STR("ResourceObject"))) = picture;
        call.run();
    }

    // After the game's Setup, inside the same call: the map's picture and the fog colour, before the screen draws.
    auto on_setup(UObject* screen, const char* route) -> void
    {
        const int n = ++g_setups;
        std::string body, fog, fogpic;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            body = g_body;
            fog = g_fog;
            fogpic = g_fogpic;
        }
        std::ostringstream did;
        did << "Setup #" << n << " (" << route << ", frame " << g_frame.load() << ")";
        try
        {
            const std::string map = fname_field(screen, STR("MapName"));
            did << " map " << map;
            UObject* image = object_field(screen, STR("Image_MapBody"));
            UObject* shown = image ? brush_resource(image) : nullptr;
            const std::string shown_name = shown ? to_string(shown->GetFullName()) : std::string("none");
            did << ", showing " << shown_name;
            // Only the main world's map: the World Tree has a screen of its own (MapName "Tree"), which also shows
            // T_WorldMap while it is set up, so the picture's name alone can't tell the two apart.
            const bool main_map = map.find("Main") != std::string::npos;
            if (!body.empty() && image && main_map && shown_name.find("T_WorldMap") != std::string::npos)
            {
                const StringType path = ensure_str(body);
                UObject* picture = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, path.c_str());
                if (!picture) throw Fail{"the mod's picture " + body + " was not found"};
                set_body(image, picture);
                ++g_bodies;
                did << "; set the mod's picture";
            }
            UObject* material = object_field(screen, STR("MaskTextureMaterial"));
            did << "; fog " << (material ? class_of(material) + " " + name_of(material) : std::string("none"));
            UObject* mask_image = object_field(screen, STR("Image_MapMask"));
            // The explorer's chart: the fog image shows the mod's fog picture (the chart where unexplored, clear where
            // explored) in place of the game's material, on the main world's map only.
            if (!fogpic.empty() && mask_image && main_map)
            {
                const StringType path = ensure_str(fogpic);
                UObject* picture = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, path.c_str());
                if (!picture) throw Fail{"the fog picture " + fogpic + " was not found"};
                set_body(mask_image, picture);
                ++g_fogpics;
                did << "; showed the chart fog";
            }
            else if (!fog.empty() && material && main_map)
            {
                set_fog(material, fog);
                ++g_fogs;
                did << " coloured " << fog;
            }
        }
        catch (const Fail& f)
        {
            did << "; FAILED: " << f.reason;
        }
        catch (const std::exception& e)
        {
            did << "; FAILED: exception " << e.what();
        }
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_last = did.str();
        }
        if (++g_logged <= 5 || n % 50 == 0) say(did.str());
    }

    // One of the screen's own functions ran: logged the first time its name shows up in this burst of calls.
    auto probe(UFunction* fn, const char* route) -> void
    {
        const uint64_t frame = g_frame.load(std::memory_order_relaxed);
        std::lock_guard<std::mutex> guard(g_probe_lock);
        if (g_bursts == 0 || frame > g_burst_frame + BURST_GAP)
        {
            ++g_bursts;
            g_burst_names.clear();
            if (g_bursts <= LOG_BURSTS) say("burst " + std::to_string(g_bursts) + " of the screen's calls from frame " + std::to_string(frame));
        }
        g_burst_frame = frame;
        if (g_bursts > LOG_BURSTS) return;
        const std::string name = to_string(fn->GetName());
        if (g_burst_names.insert(name).second) say("frame " + std::to_string(frame) + ": " + name + " (" + route + ")");
    }

    // An exception from a callback the game called (every Blueprint call, every frame) would take the game down, so
    // the callbacks catch it here and log the first one; the rest are counted in silence.
    std::atomic<int> g_errors{0};
    auto caught(const char* where, const std::exception& e) -> void
    {
        if (++g_errors == 1) say(std::string("error in ") + where + " (later ones not logged): " + e.what());
    }

    // Every Blueprint call: Setup is acted on; the probe logs the map screen's own functions in the order they run.
    auto seen(UObject* context, UFunction* fn, const char* route) -> void
    {
        if (!fn) return;
        try
        {
            const bool setup = fn == g_setup.load(std::memory_order_relaxed);
            if (setup && g_enabled.load(std::memory_order_relaxed)) on_setup(context, route);
            UObject* cls = g_class.load(std::memory_order_relaxed);
            if (cls && fn->GetOuterPrivate() == cls) probe(fn, route);
        }
        catch (const std::exception& e)
        {
            caught("the Blueprint callback", e);
        }
    }

    auto script_post(Hook::TCallbackIterationData<void>&, UObject* context, FFrame& stack, void*) -> void
    {
        UFunction* fn = stack.Node();
        if (!fn) fn = stack.CurrentNativeFunction();
        seen(context, fn, "script");
    }

    auto event_post(Hook::TCallbackIterationData<void>&, UObject* context, UFunction* fn, void*) -> void
    {
        seen(context, fn, "event");
    }

    // The last world's screen went: its fog picture shows that world's explored areas and lock stamps, and the texture
    // stays findable (Lua keeps it alive), so it is forgotten until Lua hands over the new world's.
    auto forget_fog_picture() -> void
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_fogpic.empty()) return;
        say("forgot the last world's fog picture " + g_fogpic);
        g_fogpic.clear();
    }

    // Game thread, every frame: counts frames, and every 60 looks for Setup: the first time to hook the Blueprint VM, then
    // to follow it. The screen's class goes with a world and is loaded anew with the next (Return to title, then a
    // world load), so Setup becomes a new object and a pointer kept from the first world would never match again. The
    // callbacks are registered once; only the pointer they compare against changes.
    auto tick() -> void
    {
        const uint64_t frame = ++g_frame;
        if (frame % 60 != 0) return;
        auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, SETUP_PATH);
        UFunction* const before = g_setup.load(std::memory_order_relaxed);
        if (fn == before) return;
        // Forgotten when the old Setup goes, not when a new one is found: Lua may hand over the new world's picture
        // before the new world's screen class loads.
        if (before) forget_fog_picture();
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
            std::lock_guard<std::mutex> guard(g_probe_lock);
            g_bursts = 0;                          // (the new world's first openings are probed too)
        }
        if (!g_hooked.load(std::memory_order_relaxed))
        {
            const Hook::FCallbackOptions options{false, true, STR("APConnector"), STR("MapScreen")};
            Hook::RegisterProcessLocalScriptFunctionPostCallback(&script_post, options);
            Hook::RegisterProcessInternalPostCallback(&script_post, options);
            Hook::RegisterProcessEventPostCallback(&event_post, options);
            g_hooked = true;
            say("hooked " + to_string(fn->GetFullName()) + " at frame " + std::to_string(frame));
        }
        else
            say("found Setup again (its class loaded anew) at frame " + std::to_string(frame));
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
            if (value != g_body) say("the mod's picture: " + (value.empty() ? std::string("none") : value));
            g_body = value;
            return "";
        }
        if (cmd == "fog")
        {
            if (value != g_fog) say("fog colour: " + (value.empty() ? std::string("the game's own") : value));
            g_fog = value;
            return "";
        }
        if (cmd == "fogpic")
        {
            if (value != g_fogpic) say("the chart fog: " + (value.empty() ? std::string("none") : value));
            g_fogpic = value;
            return "";
        }
        if (cmd == "enable")
        {
            g_enabled = value == "1";
            say(std::string("changing the map screen: ") + (g_enabled ? "on" : "off (config.txt map_cpp=0)"));
            return "";
        }
        if (cmd == "status")
        {
            std::ostringstream s;
            s << (g_enabled ? "" : "OFF; ") << (g_hooked ? "hooked" : "not hooked yet") << "; Setup ran " << g_setups << "x, picture set " << g_bodies
              << "x, fog set " << g_fogs << "x, chart fog " << g_fogpics << "x" << (g_last.empty() ? "" : "; last: " + g_last);
            return s.str();
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
