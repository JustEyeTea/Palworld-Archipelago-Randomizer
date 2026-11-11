// Giving the player a Pal through the game's own functions, called through UE4SS's reflection (ProcessEvent).
//
// Why C++: UE4SS's Lua calls a UFunction with a fixed 0x200-byte stack buffer (UE4SS/include/LuaType/LuaUFunction.hpp,
// DynamicUnrealFunctionData) and writes each parameter at its offset with no bounds check (LuaType/LuaUObject.cpp,
// call_ufunction_from_lua). PalUtility:GetInitializedCharacterSaveParemter's parameters reach 0x3A3, so the call from Lua
// overran the stack and the game died with 0xc0000409 (/GS cookie). Here every call gets a heap
// block of the function's own size, built and torn down through its reflection data, as UE4SS's own delegate Broadcast
// does it (UE4SS/src/LuaType/LuaXDelegateProperty.cpp). Every parameter is found by name and checked to lie inside the
// block; no offset is assumed.
//
// What the routes call (signatures from the 1.0.5 headers; what the bodies do is from reading the 1.0.5 dedicated
// server binary, not the client's):
//   save data   PalUtility:GetInitializedCharacterSaveParemter(pawn, species, None, level, PlayerUId, out, ...)
//   party_debug PalCharacterManager:CreateIndividual(save data, callback) with the callback bound to the party holder's
//               OnSpawnDebugOtomoCallback_ServerInternal. In the server binary that function puts the Pal in its
//               owner's group, gives it the EXP for its level, then adds it to the party: the game's own finisher.
//   party_plain the same with OnSpawnOtomoCallback_ServerInternal (only the add to the party).
//   handle      CreateIndividual with no callback, then AddOtomoHandleToFreeSlot. That returns true whenever the party
//               had room, even if the add failed (server binary), so the party itself is checked afterwards.
//   palbox      PalPlayerController:RequestImportGlobalPalStorageData_ToServer into an empty Palbox slot (the body
//               couldn't be read: the binary has no RTTI). Off in the Hardcore preset (bAllowGlobalPalboxImport).
// Every route checks its result in the party or the Palbox, never by a returned bool. Neither callback checks for a free
// slot, so the party routes refuse a full party first. CreateIndividual refuses to run on a client of a dedicated server
// (it logs "キャラクターの作成リクエストをクライアントから呼ぼうとしました"), so this works in single player and for a
// listen-server host only.
//
// Access violations are not caught: UE4SS ships with SEH off on purpose (ExceptionHandling.hpp), and a fault inside game
// code would leave the game in an unknown state. Safety comes from checking everything before a call. Each report line
// is mirrored into UE4SS.log as it is made, so if the game dies the last "[APConnector] [pal]" line names the step.
//
// Built only by CI (the Unreal headers are private). A party gift works in game; which of the three party routes did
// it isn't recorded, so treat party_plain and handle as untested. The Palbox route is UNTESTED IN GAME. Each UE4SS API
// below is used the way UE4SS's own source uses it; the file cited is where.
#include "pal_gift.hpp"
#include "pal_gift_logic.hpp"
#include "reflect.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UnrealInitializer.hpp>
#pragma warning(disable : 4005)   // as LuaXDelegateProperty.cpp includes them
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#pragma warning(default : 4005)

// Everything sits in its own namespace with the using-directives inside it, so its names hide UE4SS's rather than
// clash with them.
namespace pal_gift_unreal
{
    using namespace RC;
    using namespace RC::Unreal;
    using pal_gift::PendingGift;
    using pal_gift::Report;
    using pal_gift::Request;
    using pal_gift::Route;
    using namespace ap_reflect;


    std::optional<PendingGift> g_pending;

    auto mirror(const std::string& line) -> void
    {
        Output::send<LogLevel::Verbose>(STR("[APConnector] [pal] {}\n"), ensure_str(line));
    }


    // The local player, found fresh on every call: world subsystems and the pawn are remade on every world load, so
    // nothing here is kept between calls.
    struct Player
    {
        UObject* util{};
        UObject* pc{};
        UObject* pawn{};
        UObject* ps{};
        UObject* holder{};   // the party (UPalOtomoHolderComponentBase)
        UObject* cm{};       // UPalCharacterManager
        uint8_t uid[16]{};
        int count{};
        int max{};
    };

    auto find_player(Report& r, bool verbose) -> Player
    {
        Player p;
        p.util = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/Pal.Default__PalUtility"));
        if (!p.util) throw Fail{"no Default__PalUtility"};
        // Any live controller to start from (FindAllOf as UE4SSProgram.cpp's get_player_controller; class defaults
        // skipped by their flags as USMapGenerator/Generator.cpp does). After a return to title or a world load the old
        // world's controller can stay in the object array, unreachable, until garbage collection runs; it is skipped by
        // the test UE4SS's Lua IsValid makes (LuaType/LuaUObject.hpp), as the Lua side checks IsValid (menu.lua).
        std::vector<UObject*> controllers;
        UObjectGlobals::FindAllOf(STR("PalPlayerController"), controllers);
        UObject* any = nullptr;
        for (UObject* o : controllers)
        {
            if (o && (static_cast<uint32_t>(o->GetObjectFlags()) & (RF_ClassDefaultObject | RF_ArchetypeObject)) == 0 &&
                !o->IsUnreachable())
            {
                any = o;
                break;
            }
        }
        if (!any) throw Fail{"no PalPlayerController (not in a world?)"};
        constexpr auto ctx = STR("WorldContextObject");
        p.pc = call_object(p.util, STR("/Script/Pal.PalUtility:GetLocalPalPlayerController"), ctx, any);
        if (!p.pc) throw Fail{"no local player controller"};
        if (p.pc->IsUnreachable()) throw Fail{"local player controller unreachable (world loading?)"};
        p.pawn = call_object(p.util, STR("/Script/Pal.PalUtility:GetPlayerCharacter"), ctx, p.pc);
        if (!p.pawn) throw Fail{"no player character"};
        if (p.pawn->IsUnreachable()) throw Fail{"player character unreachable (world loading?)"};
        p.ps = call_object(p.util, STR("/Script/Pal.PalUtility:GetLocalPlayerState"), ctx, p.pc);
        if (!p.ps) throw Fail{"no player state"};
        if (p.ps->IsUnreachable()) throw Fail{"player state unreachable (world loading?)"};
        p.holder = call_object(p.util, STR("/Script/Pal.PalUtility:GetOtomoHolderComponent"), ctx, p.pawn);
        if (!p.holder) throw Fail{"no party holder (GetOtomoHolderComponent)"};
        if (p.holder->IsUnreachable()) throw Fail{"party holder unreachable (world loading?)"};
        p.cm = call_object(p.util, STR("/Script/Pal.PalUtility:GetCharacterManager"), ctx, p.pawn);
        if (!p.cm) throw Fail{"no character manager"};

        FProperty* uid = p.ps->GetPropertyByNameInChain(FromCharTypePtr<TCHAR>(STR("PlayerUId")));
        if (!uid || uid->GetSize() != 16) throw Fail{"PalPlayerState.PlayerUId: missing or not 16 bytes"};
        std::memcpy(p.uid, uid->ContainerPtrToValuePtr<void>(p.ps), 16);   // an FGuid: four plain uint32
        if (pal_gift::guid_is_zero(p.uid)) throw Fail{"player UId is zero"};

        p.count = call_int(p.holder, STR("/Script/Pal.PalOtomoHolderComponentBase:GetOtomoCount"));
        p.max = call_int(p.holder, STR("/Script/Pal.PalOtomoHolderComponentBase:GetMaxOtomoNum"));
        if (verbose)
        {
            r.line("ctx: pc=" + name_of(p.pc) + " pawn=" + name_of(p.pawn) + " uid=" + pal_gift::format_guid(p.uid));
            r.line("party: " + std::to_string(p.count) + "/" + std::to_string(p.max));
        }
        return p;
    }

    // The party's slot index holding `handle`, or -1.
    auto party_slot(const Player& p, UObject* handle) -> int
    {
        UObject* container = object_field(p.holder, STR("CharacterContainer"));
        if (!container) return -1;
        UObject* slot = call_object(container, STR("/Script/Pal.PalIndividualCharacterContainer:FindByHandle"), STR("Handle"), handle);
        return slot ? call_int(slot, STR("/Script/Pal.PalIndividualCharacterSlot:GetSlotIndex")) : -1;
    }

    auto palbox_slot_handle(UObject* storage, int index) -> UObject*
    {
        ReflectedCall c(storage, find_function(STR("/Script/Pal.PalPlayerDataPalStorage:GetSlotBySlotIndex")));
        *c.at<int32_t>(c.param(STR("SlotIndex"))) = index;
        c.run();
        UObject* slot = *c.at<UObject*>(c.param(STR("ReturnValue")));
        return slot ? call_object(slot, STR("/Script/Pal.PalIndividualCharacterSlot:GetHandle")) : nullptr;
    }

    // The new Pal's id (FPalInstanceID: PlayerUId, InstanceId, DebugName). Only the two GUIDs are kept: plain bytes, so
    // the pending gift owns no engine string.
    struct NewId
    {
        bool ready{};
        uint8_t player[16]{};
        uint8_t instance[16]{};
    };

    auto read_id(UObject* handle) -> NewId
    {
        NewId id;
        ReflectedCall c(handle, find_function(STR("/Script/Pal.PalIndividualCharacterHandle:GetIndividualID")));
        c.run();
        FProperty* ret = c.param(STR("ReturnValue"));
        FProperty* player = member(ret, STR("PlayerUId"));
        FProperty* instance = member(ret, STR("InstanceId"));
        if (player->GetSize() != 16 || instance->GetSize() != 16) throw Fail{"FPalInstanceID: GUIDs not 16 bytes"};
        std::memcpy(id.player, c.ptr(ret) + player->GetOffset_Internal(), 16);
        std::memcpy(id.instance, c.ptr(ret) + instance->GetOffset_Internal(), 16);
        id.ready = !pal_gift::guid_is_zero(id.instance);
        return id;
    }

    // The handle for a kept id, through the manager (never a handle pointer kept from an earlier tick). DebugName is left
    // empty; UNCONFIRMED that the game's lookup ignores it (if not, the poll falls back on the party count).
    auto handle_by_id(const Player& p, const PendingGift& g) -> UObject*
    {
        ReflectedCall c(p.cm, find_function(STR("/Script/Pal.PalCharacterManager:GetIndividualHandle")));
        FProperty* id = c.param(STR("ID"));
        FProperty* player = member(id, STR("PlayerUId"));
        FProperty* instance = member(id, STR("InstanceId"));
        if (player->GetSize() != 16 || instance->GetSize() != 16) throw Fail{"FPalInstanceID: GUIDs not 16 bytes"};
        std::memcpy(c.ptr(id) + player->GetOffset_Internal(), g.id_player, 16);
        std::memcpy(c.ptr(id) + instance->GetOffset_Internal(), g.id_instance, 16);
        c.run();
        return *c.at<UObject*>(c.param(STR("ReturnValue")));
    }

    // Shared first step: the Pal's save data, made by the game (PalUtility:GetInitializedCharacterSaveParemter, sic).
    // The returned call holds it in its outParameter until the route has copied it out.
    auto make_save_data(const Player& p, const Request& q, Report& r, FProperty*& out) -> std::unique_ptr<ReflectedCall>
    {
        // FNAME_Find: a name the game has never made can't be a Pal, and comes back None (UE4SSProgram.cpp uses Find too).
        const FName species(ensure_str(q.species), FNAME_Find);
        if (species == NAME_None) throw Fail{"unknown species '" + q.species + "' (no such name)"};

        auto call = std::make_unique<ReflectedCall>(p.util, find_function(STR("/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter")));
        *call->at<UObject*>(call->param(STR("WorldContextObject"))) = p.pawn;
        *call->at<FName>(call->param(STR("CharacterID"))) = species;
        *call->at<FName>(call->param(STR("UniqueNPCID"))) = NAME_None;
        *call->at<int32_t>(call->param(STR("Level"))) = q.level;
        FProperty* owner = call->param(STR("OwnerPlayerUId"));
        if (owner->GetSize() != 16) throw Fail{"OwnerPlayerUId: not 16 bytes"};
        std::memcpy(call->ptr(owner), p.uid, 16);
        call->set_bool(call->param(STR("DisableRandomPassiveSkill")), q.nopassive);
        call->set_bool(call->param(STR("RarePalAble")), q.rare);
        out = call->param(STR("outParameter"));
        if (!CastField<FStructProperty>(out)) throw Fail{"outParameter: not a struct"};
        r.line("savedata: calling, parms=" + hex_size(call->size()));
        call->run();
        if (!call->get_bool(call->param(STR("ReturnValue")))) throw Fail{"savedata returned false (unknown species?)"};

        // Read back what the game filled in (FName CharacterID, uint8 Level in 1.0.5).
        FProperty* cid = member(out, STR("CharacterID"));
        FProperty* lvl = member(out, STR("Level"));
        std::string got_id = "?", got_level = "?";
        if (static_cast<size_t>(cid->GetSize()) == sizeof(FName))
        {
            got_id = to_string(reinterpret_cast<FName*>(call->ptr(out) + cid->GetOffset_Internal())->ToString());
        }
        if (lvl->GetSize() == 1) got_level = std::to_string(*(call->ptr(out) + lvl->GetOffset_Internal()));
        const bool same = got_id == q.species && got_level == std::to_string(q.level);
        r.line(std::string("savedata: ") + (same ? "ok" : "warn") + " CharacterID=" + got_id + " Level=" + got_level);
        return call;
    }

    // Keeps a gift the game hasn't finished, for poll() to look for. Returns the report's result, "pending".
    auto keep_pending(PendingGift g, const Player& p) -> std::string
    {
        g.count_before = p.count;
        g.controller = reinterpret_cast<uintptr_t>(p.pc);
        g_pending = g;
        return "pending";
    }

    // The new Pal, made by the game's CreateIndividual from its save data. For the party_* routes, the party's callback
    // is bound as the finisher (nullptr: no callback). Returns the new Pal's handle.
    auto create_individual(const Player& p, const Request& q, const CharType* callback, Report& r) -> UObject*
    {
        FProperty* out{};
        auto save = make_save_data(p, q, r, out);   // freed last: CreateIndividual copies it by value (server binary)
        ReflectedCall c(p.cm, find_function(STR("/Script/Pal.PalCharacterManager:CreateIndividual")));
        FProperty* init = c.param(STR("InitParameter"));
        copy_struct(init, c.ptr(init), out, save->ptr(out));
        if (callback)
        {
            // The delegate FIndividualIDCallback(FPalInstanceID ID) bound by name to the holder's UFunction of the
            // same shape, as XMulticastDelegateProperty's Add binds one (LuaXDelegateProperty.cpp). Without a
            // callback it stays as InitializeStruct left it: unbound.
            FProperty* cb = c.param(STR("spawnCallback"));
            if (!CastField<FDelegateProperty>(cb)) throw Fail{"spawnCallback: not a delegate"};
            c.at<FScriptDelegate>(cb)->BindUFunction(p.holder, FName(callback, FNAME_Add));
        }
        r.line("create: calling, parms=" + hex_size(c.size()) + " callback=" +
               (callback ? to_string(callback) : "none (unbound)"));
        c.run();
        UObject* handle = *c.at<UObject*>(c.param(STR("ReturnValue")));
        if (!handle) throw Fail{"CreateIndividual returned null (not authority? dedicated-server client?)"};
        return handle;
    }

    auto give_to_party(const Player& p, const Request& q, Route route, Report& r) -> std::string
    {
        if (p.count >= p.max) throw Fail{"party full (" + std::to_string(p.count) + "/" + std::to_string(p.max) + ")"};
        const CharType* callback = route == Route::PartyDebug   ? STR("OnSpawnDebugOtomoCallback_ServerInternal")
                                   : route == Route::PartyPlain ? STR("OnSpawnOtomoCallback_ServerInternal")
                                                                : nullptr;
        if (callback && !p.holder->GetFunctionByNameInChain(FromCharTypePtr<TCHAR>(callback)))   // as BPMods.cpp
        {
            throw Fail{"callback " + to_string(callback) + " missing on " + class_of(p.holder)};
        }

        UObject* handle = create_individual(p, q, callback, r);
        const NewId id = read_id(handle);
        r.line("create: handle=" + name_of(handle) + " id=" + pal_gift::format_guid(id.player) + "/" +
               pal_gift::format_guid(id.instance));
        if (!id.ready) r.line("create: id not ready");

        bool added = false;
        if (route == Route::Handle)
        {
            // Adding a handle the game hasn't finished making would put an empty handle in the party (what the game
            // does then is unknown), so the handle route stops here without an id.
            if (!id.ready) throw Fail{"no id after create (the handle route adds only a made Pal; nothing added)"};
            ReflectedCall a(p.holder, find_function(STR("/Script/Pal.PalOtomoHolderComponentBase:AddOtomoHandleToFreeSlot")));
            *a.at<UObject*>(a.param(STR("Handle"))) = handle;
            a.run();
            added = a.get_bool(a.param(STR("ReturnValue")));
            r.line(added ? "add: true" : "add: false (party full by the game's count)");
        }

        const int now = call_int(p.holder, STR("/Script/Pal.PalOtomoHolderComponentBase:GetOtomoCount"));
        const int slot = id.ready ? party_slot(p, handle) : -1;
        r.line("check: party " + std::to_string(now) + "/" + std::to_string(p.max) +
               ", FindByHandle=" + (slot >= 0 ? "slot " + std::to_string(slot) : std::string("none")));
        if (slot >= 0) return "ok party";
        if (added) r.line("add: true but FindByHandle found nothing (the bool only means the party had room)");
        if (!id.ready && now > p.count)
        {
            r.line("check: the party grew, no id to match it by");
            return "ok party";
        }

        // Not there yet: the callback may run later (whether it runs inside CreateIndividual is only inferred).
        PendingGift g;
        g.route = route;
        g.has_id = id.ready;
        std::memcpy(g.id_player, id.player, 16);
        std::memcpy(g.id_instance, id.instance, 16);
        return keep_pending(g, p);
    }

    auto give_to_palbox(const Player& p, const Request& q, Report& r) -> std::string
    {
        UObject* storage = call_object(p.util, STR("/Script/Pal.PalUtility:GetLocalPalStorageData"), STR("WorldContextObject"), p.pc);
        if (!storage) throw Fail{"no palbox data"};
        UObject* box = object_field(storage, STR("TargetContainer"));
        if (!box) throw Fail{"no palbox data (no TargetContainer)"};
        UObject* empty = call_object(box, STR("/Script/Pal.PalIndividualCharacterContainer:FindEmptySlot"));
        if (!empty) throw Fail{"palbox full"};
        const int index = call_int(empty, STR("/Script/Pal.PalIndividualCharacterSlot:GetSlotIndex"));
        r.line("palbox: empty slot " + std::to_string(index));

        FProperty* out{};
        auto save = make_save_data(p, q, r, out);
        {
            // FPalGlobalPalStorageSaveParameter { SaveParameter, InstanceId }: the save data goes in SaveParameter;
            // InstanceId stays zero (UNCONFIRMED that zero means "make a new one"). ImportOption.bOverwriteData stays
            // false as InitializeStruct made it.
            ReflectedCall c(p.pc, find_function(STR("/Script/Pal.PalPlayerController:RequestImportGlobalPalStorageData_ToServer")));
            FProperty* imp = c.param(STR("ImportParameter"));
            FProperty* sp = member(imp, STR("SaveParameter"));
            copy_struct(sp, c.ptr(imp) + sp->GetOffset_Internal(), out, save->ptr(out));
            *c.at<int32_t>(c.param(STR("TargetSlotIndex"))) = index;
            c.param(STR("ImportOption"));   // present and inside the block
            r.line("import: calling, parms=" + hex_size(c.size()) + " slot=" + std::to_string(index) +
                   " InstanceId=zero bOverwriteData=false");
            c.run();
        }
        save.reset();

        UObject* handle = palbox_slot_handle(storage, index);
        r.line("check: palbox slot " + std::to_string(index) + " handle=" + name_of(handle));
        if (handle) return "ok palbox";
        PendingGift g;
        g.route = Route::Palbox;
        g.slot_index = index;
        return keep_pending(g, p);
    }

    auto give(const std::string& species, const std::string& level, const std::string& route, const std::string& options)
            -> std::string
    {
        Report r(mirror);
        try
        {
            r.line("route=" + route + " species=" + species + " level=" + level + " options=" + options);
            // Busy before anything else: Lua takes a fail as the end of a gift, and the earlier one is still pending
            // here. Lua answers busy by polling the earlier gift to its end (test_tools.lua), which also drains one left
            // from before a Lua mod restart (this DLL outlives one).
            if (g_pending) return r.finish("busy");
            if (!on_game_thread()) return r.finish("fail not on the game thread (call inside ExecuteInGameThread)");
            Request q;
            if (auto bad = pal_gift::parse_request(species, level, route, options, q); !bad.empty()) return r.finish("fail " + bad);

            const Player p = find_player(r, true);
            const Route taken = pal_gift::choose_route(q.route, p.count, p.max);
            if (taken != q.route) r.line(std::string("route: auto -> ") + pal_gift::route_name(taken));
            return r.finish(taken == Route::Palbox ? give_to_palbox(p, q, r) : give_to_party(p, q, taken, r));
        }
        catch (const Fail& f)
        {
            return r.finish("fail " + f.reason);
        }
        catch (const std::exception& e)
        {
            return r.finish(std::string("fail exception: ") + e.what());
        }
    }

    // The player now, if the pending gift can still arrive; nullopt, with the report's fail reason in `why`, when there
    // is no player or the world changed. The controller is compared, not the pawn: a player who dies gets a new pawn in
    // the same world, where the game can still finish the gift; a world load makes a new controller.
    auto player_for_poll(Report& r, const PendingGift& g, std::string& why) -> std::optional<Player>
    {
        Player p;
        try
        {
            p = find_player(r, false);
        }
        catch (const Fail& f)
        {
            why = "player not found, gift dropped (" + f.reason + ")";
            return std::nullopt;
        }
        if (reinterpret_cast<uintptr_t>(p.pc) != g.controller)
        {
            why = "world changed (another player controller), gift dropped";
            return std::nullopt;
        }
        return p;
    }

    // What one poll found: whether the gift's Pal is there yet, and what was looked at, for the report.
    struct Sighting
    {
        bool seen{};
        std::string what;
    };

    // Is the pending Palbox gift in its slot yet?
    auto look_in_palbox(const Player& p, const PendingGift& g) -> Sighting
    {
        UObject* storage = call_object(p.util, STR("/Script/Pal.PalUtility:GetLocalPalStorageData"),
                                       STR("WorldContextObject"), p.pc);
        UObject* handle = storage ? palbox_slot_handle(storage, g.slot_index) : nullptr;
        return {handle != nullptr, "palbox slot " + std::to_string(g.slot_index) + " handle=" + name_of(handle)};
    }

    // Is the pending party gift in the party yet? By its id when the create gave one, else by the party having grown.
    auto look_in_party(const Player& p, const PendingGift& g) -> Sighting
    {
        int slot = -1;
        if (g.has_id)
        {
            UObject* handle = handle_by_id(p, g);
            slot = handle ? party_slot(p, handle) : -1;
        }
        Sighting s;
        s.seen = slot >= 0;
        s.what = "party " + std::to_string(p.count) + "/" + std::to_string(p.max) +
                 (g.has_id ? ", FindByHandle=" + (slot >= 0 ? "slot " + std::to_string(slot) : std::string("none"))
                           : std::string(", no id"));
        if (!s.seen && p.count > g.count_before)
        {
            s.seen = true;
            s.what += ", the party grew (matched by count only)";
        }
        return s;
    }

    auto poll() -> std::string
    {
        if (!g_pending) return "";
        Report r(mirror);
        try
        {
            // Not a fail: Lua takes every fail as the end of the gift, and the gift is kept. Not counted as a poll.
            if (!on_game_thread())
            {
                r.line("poll: not on the game thread (call inside ExecuteInGameThread); the gift is kept");
                return r.finish("pending");
            }
            PendingGift& g = *g_pending;
            r.line("poll " + std::to_string(g.polls + 1) + " route=" + pal_gift::route_name(g.route));
            std::string why;
            const std::optional<Player> p = player_for_poll(r, g, why);
            if (!p)
            {
                g_pending.reset();
                return r.finish("fail " + why);
            }

            const Sighting found = g.route == Route::Palbox ? look_in_palbox(*p, g) : look_in_party(*p, g);
            r.line("check: " + found.what);
            const Route route = g.route;
            switch (pal_gift::next_poll(g, found.seen))
            {
            case pal_gift::PollVerdict::Ok:
                g_pending.reset();
                return r.finish(route == Route::Palbox ? "ok palbox" : "ok party");
            case pal_gift::PollVerdict::Timeout:
                g_pending.reset();
                return r.finish("fail timeout (" + found.what + ")");
            case pal_gift::PollVerdict::Wait:
                break;
            }
            return r.finish("pending");
        }
        catch (const Fail& f)
        {
            g_pending.reset();
            return r.finish("fail " + f.reason);
        }
        catch (const std::exception& e)
        {
            g_pending.reset();
            return r.finish(std::string("fail exception: ") + e.what());
        }
    }
} // namespace pal_gift_unreal

auto give_pal(const std::string& species, const std::string& level, const std::string& route, const std::string& options)
        -> std::string
{
    return pal_gift_unreal::give(species, level, route, options);
}

auto give_pal_poll() -> std::string
{
    return pal_gift_unreal::poll();
}
