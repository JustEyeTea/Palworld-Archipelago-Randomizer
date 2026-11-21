// Giving the player a Pal through the game's own functions, called through UE4SS's reflection (ProcessEvent).
//
// Why C++: UE4SS's Lua calls a UFunction with a fixed 0x200-byte stack buffer (UE4SS/include/LuaType/LuaUFunction.hpp,
// DynamicUnrealFunctionData) and writes each parameter at its offset with no bounds check (LuaType/LuaUObject.cpp,
// call_ufunction_from_lua). PalUtility:GetInitializedCharacterSaveParemter's parameters reach 0x3A3, so the call from
// Lua overran the stack and the game died with 0xc0000409 (/GS cookie). Here every call gets a heap block of the
// function's own size, built and torn down through its reflection data, as UE4SS's own delegate Broadcast does it
// (UE4SS/src/LuaType/LuaXDelegateProperty.cpp). Every parameter is found by name and checked to lie inside the
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
// Every route checks its result in the party or the Palbox, never by a returned bool. Neither callback checks for a
// free slot, so the party routes refuse a full party first. CreateIndividual refuses to run on a client of a dedicated
// server (it logs "キャラクターの作成リクエストをクライアントから呼ぼうとしました"), so this works in single player
// and for a listen-server host only.
//
// Access violations are not caught: UE4SS ships with SEH off on purpose (ExceptionHandling.hpp), and a fault inside
// game code would leave the game in an unknown state. Safety comes from checking everything before a call. Each
// report line is mirrored into UE4SS.log as it is made, so if the game dies the last "[APConnector] [pal]" line names
// the step.
//
// A party gift works in game; which of the three party routes did it isn't recorded, so treat party_plain and handle
// as untested in game. The Palbox route is untested in game. Each UE4SS API below is used the way UE4SS's own source
// uses it; the file cited is where.
// Tests: none here (it needs Unreal; only CI's Windows build compiles it). The Unreal-free half is pal_gift_logic.*,
// tested by test/pal_gift_test.cpp.
#include "pal_gift.hpp"
#include "pal_gift_logic.hpp"
#include "reflect.hpp"

#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Everything sits in its own namespace with the using-directives inside it, so its names hide UE4SS's rather than
// clash with them.
namespace pal_gift_unreal
{
    using namespace RC;
    using namespace RC::Unreal;
    using pal_gift::fail_result;
    using pal_gift::GUID_BYTES;
    using pal_gift::PendingGift;
    using pal_gift::PlayerAtPoll;
    using pal_gift::Report;
    using pal_gift::Request;
    using pal_gift::RESULT_BUSY;
    using pal_gift::RESULT_OK_PALBOX;
    using pal_gift::RESULT_OK_PARTY;
    using pal_gift::RESULT_PENDING;
    using pal_gift::Route;
    using namespace ap_reflect;

    // The one gift the game had not finished when AP_GivePal returned, if any: one at a time, so give() answers busy
    // while it is here. Set by keep_pending; forgotten when poll() ends it (end_gift). The DLL outlives a Lua mod
    // restart, and so does this.
    std::optional<PendingGift> g_pending;

    // Mirrors a report line into UE4SS.log, under "[APConnector] [pal]".
    auto mirror(const std::string& line) -> void
    {
        Output::send<LogLevel::Verbose>(STR("[APConnector] [pal] {}\n"), ensure_str(line));
    }

    // The argument name of every PalUtility lookup below.
    constexpr auto WORLD_CONTEXT = STR("WorldContextObject");

    // The local player, found fresh on every call: world subsystems and the pawn are remade on every world load, so
    // nothing here is kept between calls.
    struct Player
    {
        UObject* util{};               // PalUtility's class default object, which the lookups are called on
        UObject* controller{};
        UObject* pawn{};
        UObject* player_state{};
        UObject* party{};              // the party holder (UPalOtomoHolderComponentBase)
        UObject* character_manager{};  // UPalCharacterManager
        uint8_t uid[GUID_BYTES]{};     // PalPlayerState.PlayerUId
        int party_count{};
        int party_max{};
    };

    // `obj` if it is there and live; else a Fail naming `what`. An unreachable object is one left from the last world
    // until garbage collection runs (the test UE4SS's Lua IsValid makes, LuaType/LuaUObject.hpp).
    auto live(UObject* obj, const std::string& what) -> UObject*
    {
        if (!obj) throw Fail{"no " + what};
        if (obj->IsUnreachable()) throw Fail{what + " unreachable (world loading?)"};
        return obj;
    }

    // PalUtility and the local player controller, into player.util and player.controller.
    auto find_controller(Player& player) -> void
    {
        constexpr auto UTILITY = STR("/Script/Pal.Default__PalUtility");
        player.util = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, UTILITY);
        if (!player.util) throw Fail{"no Default__PalUtility"};
        // Any live controller to start from (FindAllOf as UE4SSProgram.cpp's get_player_controller; class defaults
        // skipped by their flags as USMapGenerator/Generator.cpp does). After a return to title or a world load the
        // old world's controller can stay in the object array, unreachable, until garbage collection runs; it is
        // skipped, as the Lua side checks IsValid (menu.lua).
        std::vector<UObject*> controllers;
        UObjectGlobals::FindAllOf(STR("PalPlayerController"), controllers);
        UObject* any = nullptr;
        for (UObject* o : controllers)
        {
            const bool defaults = o && (static_cast<uint32_t>(o->GetObjectFlags()) &
                                        (RF_ClassDefaultObject | RF_ArchetypeObject)) != 0;
            if (o && !defaults && !o->IsUnreachable())
            {
                any = o;
                break;
            }
        }
        if (!any) throw Fail{"no PalPlayerController (not in a world?)"};
        constexpr auto GET_CONTROLLER = STR("/Script/Pal.PalUtility:GetLocalPalPlayerController");
        player.controller = live(call_object(player.util, GET_CONTROLLER, WORLD_CONTEXT, any),
                                 "local player controller");
    }

    // The player's pawn and what is found from it: the party holder and the character manager. While the player has
    // no pawn (fainted, respawning) these are missing, but the controller is the same.
    auto find_pawn_parts(Player& player) -> void
    {
        auto lookup = [&](const CharType* fn, UObject* from) {
            return call_object(player.util, fn, WORLD_CONTEXT, from);
        };
        player.pawn = live(lookup(STR("/Script/Pal.PalUtility:GetPlayerCharacter"), player.controller),
                           "player character");
        player.party = live(lookup(STR("/Script/Pal.PalUtility:GetOtomoHolderComponent"), player.pawn),
                            "party holder (GetOtomoHolderComponent)");
        player.character_manager = live(lookup(STR("/Script/Pal.PalUtility:GetCharacterManager"), player.pawn),
                                        "character manager");
    }

    // The player state and the player's UId (an FGuid: four plain uint32), into player_state and uid.
    auto find_player_state(Player& player) -> void
    {
        constexpr auto GET_STATE = STR("/Script/Pal.PalUtility:GetLocalPlayerState");
        player.player_state = live(call_object(player.util, GET_STATE, WORLD_CONTEXT, player.controller),
                                   "player state");
        FProperty* uid = player.player_state->GetPropertyByNameInChain(FromCharTypePtr<TCHAR>(STR("PlayerUId")));
        if (!uid || uid->GetSize() != GUID_BYTES) throw Fail{"PalPlayerState.PlayerUId: missing or not 16 bytes"};
        std::memcpy(player.uid, uid->ContainerPtrToValuePtr<void>(player.player_state), GUID_BYTES);
        if (pal_gift::guid_is_zero(player.uid)) throw Fail{"player UId is zero"};
    }

    // How many Pals the party holds now, and how many it can.
    auto read_party(Player& player) -> void
    {
        player.party_count = call_int(player.party, STR("/Script/Pal.PalOtomoHolderComponentBase:GetOtomoCount"));
        player.party_max = call_int(player.party, STR("/Script/Pal.PalOtomoHolderComponentBase:GetMaxOtomoNum"));
    }

    // The local player in full, found fresh; verbose adds the player and the party to the report.
    auto find_player(Report& report, bool verbose) -> Player
    {
        Player player;
        find_controller(player);
        find_pawn_parts(player);
        find_player_state(player);
        read_party(player);
        if (verbose)
        {
            report.line("ctx: pc=" + name_of(player.controller) + " pawn=" + name_of(player.pawn) +
                        " uid=" + pal_gift::format_guid(player.uid));
            report.line("party: " + std::to_string(player.party_count) + "/" + std::to_string(player.party_max));
        }
        return player;
    }

    // "slot N", or "none" for -1: a report line's FindByHandle part.
    auto slot_text(int slot) -> std::string
    {
        return slot >= 0 ? "slot " + std::to_string(slot) : std::string("none");
    }

    // The party's slot index holding `handle`, or -1.
    auto party_slot(const Player& player, UObject* handle) -> int
    {
        UObject* container = object_field(player.party, STR("CharacterContainer"));
        if (!container) return -1;
        constexpr auto FIND_BY_HANDLE = STR("/Script/Pal.PalIndividualCharacterContainer:FindByHandle");
        UObject* slot = call_object(container, FIND_BY_HANDLE, STR("Handle"), handle);
        return slot ? call_int(slot, STR("/Script/Pal.PalIndividualCharacterSlot:GetSlotIndex")) : -1;
    }

    // The local player's Palbox data (PalUtility:GetLocalPalStorageData), or null.
    auto palbox_storage(const Player& player) -> UObject*
    {
        return call_object(player.util, STR("/Script/Pal.PalUtility:GetLocalPalStorageData"), WORLD_CONTEXT,
                           player.controller);
    }

    // The Pal in Palbox slot `index` (its handle), or null while the slot is empty.
    auto palbox_slot_handle(UObject* storage, int index) -> UObject*
    {
        ReflectedCall call(storage, find_function(STR("/Script/Pal.PalPlayerDataPalStorage:GetSlotBySlotIndex")));
        *call.at<int32_t>(call.param(STR("SlotIndex"))) = index;
        call.run();
        UObject* slot = *call.at<UObject*>(call.param(STR("ReturnValue")));
        return slot ? call_object(slot, STR("/Script/Pal.PalIndividualCharacterSlot:GetHandle")) : nullptr;
    }

    // The new Pal's id (FPalInstanceID: PlayerUId, InstanceId, DebugName). Only the two GUIDs are kept: plain bytes, so
    // the pending gift owns no engine string.
    struct NewId
    {
        bool ready{};
        uint8_t player[GUID_BYTES]{};
        uint8_t instance[GUID_BYTES]{};
    };

    // An FPalInstanceID property's two GUID members, checked to be GUIDs.
    struct InstanceIdMembers
    {
        FProperty* player;
        FProperty* instance;
    };
    auto instance_id_members(FProperty* id) -> InstanceIdMembers
    {
        const InstanceIdMembers members{member(id, STR("PlayerUId")), member(id, STR("InstanceId"))};
        if (members.player->GetSize() != GUID_BYTES || members.instance->GetSize() != GUID_BYTES)
        {
            throw Fail{"FPalInstanceID: GUIDs not 16 bytes"};
        }
        return members;
    }

    // The id of the Pal a handle holds; not `ready` while the game has not made it yet (its InstanceId is zero).
    auto read_id(UObject* handle) -> NewId
    {
        NewId id;
        ReflectedCall call(handle, find_function(STR("/Script/Pal.PalIndividualCharacterHandle:GetIndividualID")));
        call.run();
        FProperty* ret = call.param(STR("ReturnValue"));
        const InstanceIdMembers members = instance_id_members(ret);
        std::memcpy(id.player, call.ptr(ret) + members.player->GetOffset_Internal(), GUID_BYTES);
        std::memcpy(id.instance, call.ptr(ret) + members.instance->GetOffset_Internal(), GUID_BYTES);
        id.ready = !pal_gift::guid_is_zero(id.instance);
        return id;
    }

    // The handle for a kept id, through the manager (never a handle pointer kept from an earlier tick). DebugName is
    // left empty; untested in game that the lookup ignores it. If it does not, every party gift with an id ends in
    // "fail timeout" though the Pal arrived (the party count is not used once there is an id): fix the lookup then.
    auto handle_by_id(const Player& player, const PendingGift& gift) -> UObject*
    {
        constexpr auto GET_HANDLE = STR("/Script/Pal.PalCharacterManager:GetIndividualHandle");
        ReflectedCall call(player.character_manager, find_function(GET_HANDLE));
        FProperty* id = call.param(STR("ID"));
        const InstanceIdMembers members = instance_id_members(id);
        std::memcpy(call.ptr(id) + members.player->GetOffset_Internal(), gift.id_player, GUID_BYTES);
        std::memcpy(call.ptr(id) + members.instance->GetOffset_Internal(), gift.id_instance, GUID_BYTES);
        call.run();
        return *call.at<UObject*>(call.param(STR("ReturnValue")));
    }

    // Reads back what the game filled in the save data (FName CharacterID, uint8 Level in 1.0.5) and reports whether
    // it is what was asked for.
    auto check_save_data(ReflectedCall& call, FProperty* out, const Request& request, Report& report) -> void
    {
        FProperty* cid = member(out, STR("CharacterID"));
        FProperty* lvl = member(out, STR("Level"));
        std::string got_id = "?", got_level = "?";
        if (static_cast<size_t>(cid->GetSize()) == sizeof(FName))
        {
            got_id = to_string(reinterpret_cast<FName*>(call.ptr(out) + cid->GetOffset_Internal())->ToString());
        }
        if (lvl->GetSize() == 1)
        {
            got_level = std::to_string(*(call.ptr(out) + lvl->GetOffset_Internal()));
        }
        const bool same = got_id == request.species && got_level == std::to_string(request.level);
        report.line(std::string("savedata: ") + (same ? "ok" : "warn") + " CharacterID=" + got_id +
                    " Level=" + got_level);
    }

    // Shared first step: the Pal's save data, made by the game (PalUtility:GetInitializedCharacterSaveParemter, sic).
    // The returned call holds it in its outParameter until the route has copied it out.
    auto make_save_data(const Player& player, const Request& request, Report& report, FProperty*& out)
        -> std::unique_ptr<ReflectedCall>
    {
        // FNAME_Find: a name the game has never made can't be a Pal, and comes back None (UE4SSProgram.cpp uses Find
        // too).
        const FName species(ensure_str(request.species), FNAME_Find);
        if (species == NAME_None) throw Fail{"unknown species '" + request.species + "' (no such name)"};

        constexpr auto SAVE_DATA = STR("/Script/Pal.PalUtility:GetInitializedCharacterSaveParemter");
        auto call = std::make_unique<ReflectedCall>(player.util, find_function(SAVE_DATA));
        *call->at<UObject*>(call->param(STR("WorldContextObject"))) = player.pawn;
        *call->at<FName>(call->param(STR("CharacterID"))) = species;
        *call->at<FName>(call->param(STR("UniqueNPCID"))) = NAME_None;
        *call->at<int32_t>(call->param(STR("Level"))) = request.level;
        FProperty* owner = call->param(STR("OwnerPlayerUId"));
        if (owner->GetSize() != GUID_BYTES) throw Fail{"OwnerPlayerUId: not 16 bytes"};
        std::memcpy(call->ptr(owner), player.uid, GUID_BYTES);
        call->set_bool(call->param(STR("DisableRandomPassiveSkill")), request.nopassive);
        call->set_bool(call->param(STR("RarePalAble")), request.rare);
        out = call->param(STR("outParameter"));
        if (!CastField<FStructProperty>(out)) throw Fail{"outParameter: not a struct"};
        report.line("savedata: calling, parms=" + hex_size(call->size()));
        call->run();
        if (!call->get_bool(call->param(STR("ReturnValue")))) throw Fail{"savedata returned false (unknown species?)"};
        check_save_data(*call, out, request, report);
        return call;
    }

    // Keeps a gift the game hasn't finished, for poll() to look for. Returns the report's result, "pending".
    auto keep_pending(PendingGift gift, const Player& player) -> std::string
    {
        gift.count_before = player.party_count;
        gift.controller = reinterpret_cast<uintptr_t>(player.controller);
        g_pending = gift;
        return RESULT_PENDING;
    }

    // The new Pal, made by the game's CreateIndividual from its save data. For the party_* routes, the party's callback
    // is bound as the finisher (nullptr: no callback). Returns the new Pal's handle.
    auto create_individual(const Player& player, const Request& request, const CharType* callback, Report& report)
        -> UObject*
    {
        FProperty* out{};
        auto save = make_save_data(player, request, report, out);   // freed last: CreateIndividual copies it by value
        constexpr auto CREATE = STR("/Script/Pal.PalCharacterManager:CreateIndividual");
        ReflectedCall call(player.character_manager, find_function(CREATE));
        FProperty* init = call.param(STR("InitParameter"));
        copy_struct(init, call.ptr(init), out, save->ptr(out));
        if (callback)
        {
            // The delegate FIndividualIDCallback(FPalInstanceID ID) bound by name to the holder's UFunction of the
            // same shape, as XMulticastDelegateProperty's Add binds one (LuaXDelegateProperty.cpp). Without a
            // callback it stays as InitializeStruct left it: unbound.
            FProperty* cb = call.param(STR("spawnCallback"));
            if (!CastField<FDelegateProperty>(cb)) throw Fail{"spawnCallback: not a delegate"};
            call.at<FScriptDelegate>(cb)->BindUFunction(player.party, FName(callback, FNAME_Add));
        }
        report.line("create: calling, parms=" + hex_size(call.size()) + " callback=" +
                    (callback ? to_string(callback) : "none (unbound)"));
        call.run();
        UObject* handle = *call.at<UObject*>(call.param(STR("ReturnValue")));
        if (!handle) throw Fail{"CreateIndividual returned null (not authority? dedicated-server client?)"};
        return handle;
    }

    // The party holder's callback a party route binds as the finisher; nullptr for the handle route.
    auto callback_for(const Player& player, Route route) -> const CharType*
    {
        const CharType* callback = route == Route::PartyDebug   ? STR("OnSpawnDebugOtomoCallback_ServerInternal")
                                   : route == Route::PartyPlain ? STR("OnSpawnOtomoCallback_ServerInternal")
                                                                : nullptr;
        if (callback && !player.party->GetFunctionByNameInChain(FromCharTypePtr<TCHAR>(callback)))   // as BPMods.cpp
        {
            throw Fail{"callback " + to_string(callback) + " missing on " + class_of(player.party)};
        }
        return callback;
    }

    // The handle route's add: the made Pal into a free party slot. Whether the game said it had room (not that the
    // Pal is there).
    auto add_by_handle(const Player& player, UObject* handle, const NewId& id, Report& report) -> bool
    {
        // Adding a handle the game hasn't finished making would put an empty handle in the party (what the game does
        // then is unknown), so the handle route stops here without an id.
        if (!id.ready) throw Fail{"no id after create (the handle route adds only a made Pal; nothing added)"};
        constexpr auto ADD = STR("/Script/Pal.PalOtomoHolderComponentBase:AddOtomoHandleToFreeSlot");
        ReflectedCall call(player.party, find_function(ADD));
        *call.at<UObject*>(call.param(STR("Handle"))) = handle;
        call.run();
        const bool added = call.get_bool(call.param(STR("ReturnValue")));
        report.line(added ? "add: true" : "add: false (party full by the game's count)");
        return added;
    }

    // Whether the new Pal is in the party now: by its id, or without one by the party having grown.
    auto in_party_now(const Player& player, UObject* handle, const NewId& id, bool added, Report& report) -> bool
    {
        const int now = call_int(player.party, STR("/Script/Pal.PalOtomoHolderComponentBase:GetOtomoCount"));
        const int slot = id.ready ? party_slot(player, handle) : -1;
        report.line("check: party " + std::to_string(now) + "/" + std::to_string(player.party_max) +
                    ", FindByHandle=" + slot_text(slot));
        if (slot >= 0) return true;
        if (added)
        {
            report.line("add: true but FindByHandle found nothing (the bool only means the party had room)");
        }
        if (!pal_gift::arrived_by_count(id.ready, player.party_count, now)) return false;
        report.line("check: the party grew, no id to match it by");
        return true;
    }

    // Makes the Pal by a party route and checks the party; keeps it pending if it is not there yet.
    auto give_to_party(const Player& player, const Request& request, Route route, Report& report) -> std::string
    {
        if (player.party_count >= player.party_max)
        {
            const std::string party = std::to_string(player.party_count) + "/" + std::to_string(player.party_max);
            throw Fail{"party full (" + party + ")"};
        }
        UObject* handle = create_individual(player, request, callback_for(player, route), report);
        const NewId id = read_id(handle);
        report.line("create: handle=" + name_of(handle) + " id=" + pal_gift::format_guid(id.player) + "/" +
                    pal_gift::format_guid(id.instance));
        if (!id.ready)
        {
            report.line("create: id not ready");
        }
        const bool added = route == Route::Handle && add_by_handle(player, handle, id, report);
        if (in_party_now(player, handle, id, added, report)) return RESULT_OK_PARTY;

        // Not there yet: the callback may run later (whether it runs inside CreateIndividual is only inferred).
        PendingGift gift;
        gift.route = route;
        gift.has_id = id.ready;
        std::memcpy(gift.id_player, id.player, GUID_BYTES);
        std::memcpy(gift.id_instance, id.instance, GUID_BYTES);
        return keep_pending(gift, player);
    }

    // Makes the Pal by the Global Palbox import into an empty Palbox slot and checks the slot; keeps it pending if it
    // is not there yet.
    auto give_to_palbox(const Player& player, const Request& request, Report& report) -> std::string
    {
        UObject* storage = palbox_storage(player);
        if (!storage) throw Fail{"no palbox data"};
        UObject* box = object_field(storage, STR("TargetContainer"));
        if (!box) throw Fail{"no palbox data (no TargetContainer)"};
        UObject* empty = call_object(box, STR("/Script/Pal.PalIndividualCharacterContainer:FindEmptySlot"));
        if (!empty) throw Fail{"palbox full"};
        const int index = call_int(empty, STR("/Script/Pal.PalIndividualCharacterSlot:GetSlotIndex"));
        report.line("palbox: empty slot " + std::to_string(index));

        FProperty* out{};
        auto save = make_save_data(player, request, report, out);
        {
            // FPalGlobalPalStorageSaveParameter { SaveParameter, InstanceId }: the save data goes in SaveParameter;
            // InstanceId stays zero (untested in game that zero means "make a new one"). ImportOption.bOverwriteData
            // stays false as InitializeStruct made it.
            constexpr auto IMPORT = STR("/Script/Pal.PalPlayerController:RequestImportGlobalPalStorageData_ToServer");
            ReflectedCall call(player.controller, find_function(IMPORT));
            FProperty* imp = call.param(STR("ImportParameter"));
            FProperty* sp = member(imp, STR("SaveParameter"));
            copy_struct(sp, call.ptr(imp) + sp->GetOffset_Internal(), out, save->ptr(out));
            *call.at<int32_t>(call.param(STR("TargetSlotIndex"))) = index;
            call.param(STR("ImportOption"));   // present and inside the block
            report.line("import: calling, parms=" + hex_size(call.size()) + " slot=" + std::to_string(index) +
                        " InstanceId=zero bOverwriteData=false");
            call.run();
        }
        save.reset();

        UObject* handle = palbox_slot_handle(storage, index);
        report.line("check: palbox slot " + std::to_string(index) + " handle=" + name_of(handle));
        if (handle) return RESULT_OK_PALBOX;
        PendingGift gift;
        gift.route = Route::Palbox;
        gift.slot_index = index;
        return keep_pending(gift, player);
    }

    // AP_GivePal: reads the request, finds the player, picks the route and gives the Pal (pal_gift.hpp).
    auto give(const std::string& species, const std::string& level, const std::string& route,
              const std::string& options) -> std::string
    {
        Report report(mirror);
        try
        {
            report.line("route=" + route + " species=" + species + " level=" + level + " options=" + options);
            // Busy before anything else: Lua takes a fail as the end of a gift, and the earlier one is still pending
            // here. Lua answers busy by polling the earlier gift to its end (test_tools.lua), which also drains one
            // left from before a Lua mod restart (this DLL outlives one).
            if (g_pending) return report.finish(RESULT_BUSY);
            if (!on_game_thread())
            {
                return report.finish(fail_result("not on the game thread (call inside ExecuteInGameThread)"));
            }
            Request request;
            const std::string bad = pal_gift::parse_request(species, level, route, options, request);
            if (!bad.empty()) return report.finish(fail_result(bad));

            const Player player = find_player(report, true);
            const Route taken = pal_gift::choose_route(request.route, player.party_count, player.party_max);
            if (taken != request.route)
            {
                report.line(std::string("route: auto -> ") + pal_gift::route_name(taken));
            }
            const std::string result = taken == Route::Palbox ? give_to_palbox(player, request, report)
                                                              : give_to_party(player, request, taken, report);
            return report.finish(result);
        }
        catch (const Fail& f)
        {
            return report.finish(fail_result(f.reason));
        }
        catch (const std::exception& e)
        {
            return report.finish(fail_result(std::string("exception: ") + e.what()));
        }
    }

    // Where the player stands for this poll (pal_gift_logic.hpp, PlayerAtPoll), with `player` filled when Here; else
    // the reason in `why`. The controller is compared, not the pawn: a player who faints gets a new pawn in the same
    // world, where the game can still finish the gift; a world load makes a new controller.
    auto player_at_poll(const PendingGift& gift, Player& player, std::string& why) -> PlayerAtPoll
    {
        try
        {
            find_controller(player);
            if (reinterpret_cast<uintptr_t>(player.controller) != gift.controller)
            {
                why = "world changed (another player controller), gift dropped";
                return PlayerAtPoll::Gone;
            }
        }
        catch (const Fail& f)
        {
            why = "player not found, gift dropped (" + f.reason + ")";
            return PlayerAtPoll::Gone;
        }
        try
        {
            find_pawn_parts(player);
        }
        catch (const Fail& f)
        {
            why = "no pawn to look from yet (" + f.reason + "), the gift is kept";
            return PlayerAtPoll::BetweenPawns;
        }
        try
        {
            find_player_state(player);
            read_party(player);
        }
        catch (const Fail& f)
        {
            why = "player not found, gift dropped (" + f.reason + ")";
            return PlayerAtPoll::Gone;
        }
        return PlayerAtPoll::Here;
    }

    // What one poll found: whether the gift's Pal is there yet, and what was looked at, for the report.
    struct Sighting
    {
        bool seen{};
        std::string what;
    };

    // Is the pending Palbox gift in its slot yet?
    auto look_in_palbox(const Player& player, const PendingGift& gift) -> Sighting
    {
        UObject* storage = palbox_storage(player);
        UObject* handle = storage ? palbox_slot_handle(storage, gift.slot_index) : nullptr;
        return {handle != nullptr, "palbox slot " + std::to_string(gift.slot_index) + " handle=" + name_of(handle)};
    }

    // Is the pending party gift in the party yet? By its id when the create gave one, else by the party having grown.
    auto look_in_party(const Player& player, const PendingGift& gift) -> Sighting
    {
        int slot = -1;
        if (gift.has_id)
        {
            UObject* handle = handle_by_id(player, gift);
            slot = handle ? party_slot(player, handle) : -1;
        }
        Sighting s;
        s.seen = slot >= 0;
        s.what = "party " + std::to_string(player.party_count) + "/" + std::to_string(player.party_max) +
                 (gift.has_id ? ", FindByHandle=" + slot_text(slot) : std::string(", no id"));
        if (!s.seen && pal_gift::arrived_by_count(gift.has_id, gift.count_before, player.party_count))
        {
            s.seen = true;
            s.what += ", the party grew (matched by count only)";
        }
        return s;
    }

    // What a poll finds of the gift: its Pal looked for where the player stands Here; elsewhere nothing, with `why`.
    auto look_for_gift(const PendingGift& gift, PlayerAtPoll where, const Player& player, const std::string& why)
        -> Sighting
    {
        if (where != PlayerAtPoll::Here) return {false, why};
        return gift.route == Route::Palbox ? look_in_palbox(player, gift) : look_in_party(player, gift);
    }

    // Ends the pending gift: forgets it, and finishes the report with `result`.
    auto end_gift(Report& report, const std::string& result) -> std::string
    {
        g_pending.reset();
        return report.finish(result);
    }

    // AP_GivePalPoll: looks for the pending gift once (pal_gift.hpp).
    auto poll() -> std::string
    {
        if (!g_pending) return "";
        Report report(mirror);
        try
        {
            // Not a fail: Lua takes every fail as the end of the gift, and the gift is kept. Not counted as a poll.
            if (!on_game_thread())
            {
                report.line("poll: not on the game thread (call inside ExecuteInGameThread); the gift is kept");
                return report.finish(RESULT_PENDING);
            }
            PendingGift& gift = *g_pending;
            report.line("poll " + std::to_string(gift.polls + 1) + " route=" + pal_gift::route_name(gift.route));
            Player player;
            std::string why;
            const PlayerAtPoll where = player_at_poll(gift, player, why);
            const Sighting found = look_for_gift(gift, where, player, why);
            report.line("check: " + found.what);
            const Route route = gift.route;
            switch (pal_gift::next_poll(gift, where, found.seen))
            {
            case pal_gift::PollVerdict::Ok:
                return end_gift(report, route == Route::Palbox ? RESULT_OK_PALBOX : RESULT_OK_PARTY);
            case pal_gift::PollVerdict::Timeout:
                return end_gift(report, fail_result("timeout (" + found.what + ")"));
            case pal_gift::PollVerdict::Dropped:
                return end_gift(report, fail_result(why));
            case pal_gift::PollVerdict::Wait:
                break;
            }
            return report.finish(RESULT_PENDING);
        }
        catch (const Fail& f)
        {
            return end_gift(report, fail_result(f.reason));
        }
        catch (const std::exception& e)
        {
            return end_gift(report, fail_result(std::string("exception: ") + e.what()));
        }
    }
} // namespace pal_gift_unreal

auto give_pal(const std::string& species, const std::string& level, const std::string& route,
              const std::string& options) -> std::string
{
    return pal_gift_unreal::give(species, level, route, options);
}

auto give_pal_poll() -> std::string
{
    return pal_gift_unreal::poll();
}
