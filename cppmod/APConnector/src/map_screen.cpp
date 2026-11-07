// The world map screen from C++ (see map_screen.hpp). WBP_Map_Body_C:Setup builds the screen: it makes the fog's
// material (a dynamic instance of MI_UI_Menu_MapCloud on Image_MapMask, kept in MaskTextureMaterial, its TargetTexture
// the player's explored mask) and shows the map's picture in Image_MapBody (2026-11-06 research, from the server pak).
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
// A PROBE TOO: it logs the screen's functions in the order they run with the frame number, so a build knows the right
// moment if Setup is not it. dev.16 (2026-11-07, first run in game): the class was found at world load, Setup ran (twice,
// "script" route) in the frame the map first opened, just after OnInitialized, and nothing crashed; but Lua had not
// switched this on yet, so it changed nothing. Still open: does Setup run again at a later opening, and does a change
// made here show from the first frame?
#include "map_screen.hpp"
#include "reflect.hpp"

#include <atomic>
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
    // (dev.16 log, 2026-11-07: a flat 80-call limit was used up by the first opening's 64 icon calls, so it could not
    // tell whether Setup runs again when the map is opened a second time.)
    constexpr int LOG_BURSTS = 8;              // bursts logged per session
    constexpr uint64_t BURST_GAP = 30;         // frames without a call to the screen that end a burst

    std::mutex g_lock;                         // guards what Lua sets and the counters' text
    std::string g_body;                        // the picture's object path ("" = the game's own)
    std::string g_fog;                         // "r,g,b,a" ("" = the game's own)
    std::string g_fogpic;                      // the fog picture's object path (the explorer's chart; "" = none)
    std::string g_last;                        // what the last Setup did

    std::atomic<UFunction*> g_setup{nullptr};
    std::atomic<UObject*> g_class{nullptr};    // WBP_Map_Body_C, for logging its functions
    std::atomic<uint64_t> g_frame{0};
    std::atomic<int> g_setups{0}, g_bodies{0}, g_fogs{0}, g_fogpics{0};
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
            // Only the main world's map: the World Tree has a screen of its own (T_TreeMap), as walls.lua checks.
            if (!body.empty() && image && shown_name.find("T_WorldMap") != std::string::npos)
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
            if (!fogpic.empty() && mask_image && map.find("Main") != std::string::npos)
            {
                const StringType path = ensure_str(fogpic);
                UObject* picture = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, path.c_str());
                if (!picture) throw Fail{"the fog picture " + fogpic + " was not found"};
                set_body(mask_image, picture);
                ++g_fogpics;
                did << "; showed the chart fog";
            }
            else if (!fog.empty() && material)
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
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_last = did.str();
        }
        if (n <= 5 || n % 50 == 0) say(did.str());
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

    // Every Blueprint call: Setup is acted on; the probe logs the map screen's own functions in the order they run.
    auto seen(UObject* context, UFunction* fn, const char* route) -> void
    {
        if (!fn) return;
        if (fn == g_setup.load(std::memory_order_relaxed) && g_enabled.load(std::memory_order_relaxed)) on_setup(context, route);
        UObject* cls = g_class.load(std::memory_order_relaxed);
        if (cls && fn->GetOuterPrivate() == cls) probe(fn, route);
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

    // Game thread, every frame: counts frames, and until it is found looks for Setup every 60.
    auto tick() -> void
    {
        const uint64_t frame = ++g_frame;
        if (g_hooked.load(std::memory_order_relaxed) || frame % 60 != 0) return;
        auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, SETUP_PATH);
        if (!fn) return;
        g_class = fn->GetOuterPrivate();
        g_setup = fn;
        const Hook::FCallbackOptions options{false, true, STR("APConnector"), STR("MapScreen")};
        Hook::RegisterProcessLocalScriptFunctionPostCallback(&script_post, options);
        Hook::RegisterProcessInternalPostCallback(&script_post, options);
        Hook::RegisterProcessEventPostCallback(&event_post, options);
        g_hooked = true;
        say("hooked " + to_string(fn->GetFullName()) + " at frame " + std::to_string(frame));
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
        Hook::RegisterEngineTickPreCallback([](auto&, auto*, float, bool) { tick(); },
                                            {false, true, STR("APConnector"), STR("MapScreenTick")});
        say("waiting for the map screen's class");
    }
} // namespace map_screen
