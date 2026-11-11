-- The Archipelago mailbox: items received from the multiworld wait here until the player takes them, instead of
-- landing in the bag mid-fight. The list is the mod's own, kept in the save file, with no limit. It opens from the
-- "Archipelago Mailbox" button on the Esc menu and the Inventory page (menu.lua), or an optional key (mailbox_key).
-- config.txt: mailbox=0 gives items straight to the bag; mailbox_view=chest skips the LogicMod's window.
-- Tests: mod/test/harness.lua, groups "the mailbox" and "mailbox off: bundles straight to the bag" (lua_harness.sh).
local M = {}
local P = require("perf")
local UTIL = require("util")
local WIDGETS = require("widgets")
local BAG = require("bag")
local log = UTIL.log
-- The window's, the chest's and the list's lines are logged once a world (forgetOnWorldChange() forgets them); the
-- bag's (bag.lua) once a session, since the bag is also used with the mailbox off.
local once, forgetOnce = UTIL.onceForgettable()

local WINDOW = require("mailbox_window")
local CHEST = {}                        -- the section below: the hidden chest
local LIST = M                          -- the list's functions, as the window and the chest sections use them

-- The name the player sees, on the buttons, the LogicMod window and the chest window's heading.
M.TITLE = "Archipelago Mailbox"

-- What main.lua hands over (M.install).
--   notify(text)          shows a line to the player
--   save()                writes the mod's save file
--   cfg                   config.txt's values (mailbox, mailbox_view, mailbox_slots, mailbox_key)
--   connected()           whether the connection to Archipelago is up
--   guardedHook(name, fn) optional: a hook callback that no update can run inside
local env

------------------------------------------------------------------------------------------------------------------------
-- The hidden chest: without the LogicMod, the mailbox is the game's own chest window on a chest of its own. The chest
-- (mailbox_slots, default 300 slots) is made once per world far outside the map and deep underground, kept from
-- decaying, filled from the list as its window opens and emptied back into the list as it closes. It only gives:
-- what the player puts in goes back to the bag, and items received while it is open appear in it.

local CHEST_GAME = {
    chestId = "ItemChest_04",                             -- the map object the chest is made as (a big chest)
    chestBlueprint = "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04",
    blueprintName = "BP_BuildObject_ItemChest_04",
    templateSuffix = "_C:PalMapObjectItemChestParameter_GEN_VARIABLE",   -- its item-chest component's template
    chestModelClass = "PalMapObjectItemChestModel",       -- every chest in the world
    chestParameterClass = "PalMapObjectItemChestParameterComponent",   -- what sets a chest's size (SlotNum)
    mapObjectParameter = "/Script/Pal.PalHUDDispatchParameter_MapObject",
    guidLibrary = "/Script/Engine.Default__KismetGuidLibrary",   -- a new id for each move to the bag
    chestWindowClass = "WBP_ItemChest_C",                 -- the chest window itself (followed when the HUD id can't)
    chestMenuClass = "WBP_IngameMenu_Chest_C",            -- the part of it that holds the heading
    chestMenu = "WBP_IngameMenu_Chest",                   -- that part, as a field of the HUD's widget
    heading = "Text_TargetContainerName",                 -- the chest window's heading
    emblemArt = "ap-mailbox-emblem-64",                   -- art/ap-mailbox-emblem-64.png beside the heading
}
-- Game functions called: GetMapObjectManager, RequestSpawnMapObjectByPlayer_Server, FindModel, GetModelInstanceId,
-- RequestLockPrivate_ServerInternal, GetLocalPlayerID, GetActor, GetItemContainerModule, GetContainer,
-- GetLastNotEmptyIndex, OnRep_Permission, OnRep_ItemId, OnRep_StackCount, CreateDispatchParameterForK2Node,
-- ShowCommonUI, GetNetworkTransmitter, RequestMoveToContainer_ToServer, NewGuid.
local CHEST_WAIT = {
    chestAppears = UTIL.updates(6),     -- a new chest is given this long to appear before giving up
    followView = UTIL.updates(2),       -- how long to find out how to tell the chest window has closed
    gameMove = UTIL.updates(0.9),       -- a deposit is given this long to go back by the game's move
}
local HIDDEN_SPOT = { X = -1050000, Y = 700000, Z = -40000 }   -- cm: beyond the map's far corner, 400 m underground
local NO_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local CHEST_NEAR_CM = 200            -- a chest this near the hidden spot is ours: the game may place it a little off
local SLOTS_MIN = 54                 -- ItemChest_04's own size: the mailbox's chest is never smaller
local SLOTS_DEFAULT = 300            -- without mailbox_slots in config.txt
local SLOTS_MAX = 2000               -- a sane top for mailbox_slots (each slot is swept while the window is open)
local ITEM_CHEST_WINDOW = 7          -- EPalWidgetBlueprintType ItemChest
local DAMAGE_NONE = 2                -- EPalMapObjectDamagableType NoDamage
local NO_DEPOSITS = "AP_MailboxGivesOnly"   -- the one item id the chest accepts: no item has it
local RANDOM_MAX = 0x7FFFFFFF        -- the largest part of a made-up guid (a positive 32-bit number)
local EMBLEM_SIZE = 32               -- the emblem's side beside the heading, in the window's units
local EMBLEM_GAP = 8                 -- between the heading and the emblem
local HEADING_ROW_LEVELS = 3         -- how far above the heading the row it sits in is looked for

-- State: the chest view (the chest window the mailbox opened). Forgotten: when it closes (closeView()), on a new
-- world (CHEST.forget()), on a new seed (CHEST.forget()). Its fields are listed in newView().
local view = nil
-- State: the hidden chest being made. Forgotten: when it appears or the wait is over, on a new world or a new seed
-- (stopSpawning()).
-- { updates = updates since it was asked for, templates = list of { component, slotsBefore }: the chest templates
-- whose size was raised while it is made, put back by stopSpawning() }
local spawning = nil

-- A new chest view's record, with every field it has.
local function newView(id, hud, chest, held, inChest)
    return {
        id = id,                -- the HUD's id for the chest window
        hud = hud,              -- the HUD service that showed it
        chest = chest,          -- the hidden chest (its map object model)
        held = held,            -- list entries { id, n } not in the chest yet (it was full): they go in as slots empty
        inChest = inChest,      -- item id -> how many the mailbox put in the chest that the player has not taken
        depositUpdates = {},    -- item id -> updates a deposit of it has waited for the game's move to the bag
        gearUpdates = {},       -- a piece of gear's key ("slot:id") -> updates it has waited for the game's move
        told = false,           -- the player was told that deposits go back to the bag
        emblem = false,         -- the emblem was tried beside the heading (once a view)
        updatesOpen = 0,        -- updates since it opened
        how = nil,              -- how its closing is seen: "id" (the HUD's id), "widget", or "unknown" (it can't be)
    }
end

local function containerOf(chest)
    return chest:GetItemContainerModule():GetContainer()
end

-- The hidden chest, if the world has it: the chest at the hidden spot.
function CHEST.find()
    for _, model in ipairs(FindAllOf(CHEST_GAME.chestModelClass) or {}) do
        local ok, at = pcall(function() return model:GetTransform().Translation end)
        if ok and at and model:IsValid() then
            local distanceSquared = (at.X - HIDDEN_SPOT.X) ^ 2 + (at.Y - HIDDEN_SPOT.Y) ^ 2 + (at.Z - HIDDEN_SPOT.Z) ^ 2
            if distanceSquared < CHEST_NEAR_CM ^ 2 then return model end
        end
    end
end

-- The chest's size is its Blueprint's item-chest component's SlotNum (54 on ItemChest_04, in the template
-- PalMapObjectItemChestParameter_GEN_VARIABLE): raised on the templates while ours is made, then put back, so chests
-- the player builds stay as they are. Three lookups: the template by path, the components found, then every object.
local function chestTemplates()
    pcall(LoadAsset, CHEST_GAME.chestBlueprint .. "." .. CHEST_GAME.blueprintName)
    local found, seen = {}, {}   -- the templates found; their full names, so none is raised twice
    local function consider(component)
        if not component then return end
        local ok, name = pcall(function() return component:GetFullName() end)
        if not (ok and name:find(CHEST_GAME.blueprintName, 1, true)) or seen[name] then return end
        if not (name:find("GEN_VARIABLE", 1, true) or name:find("Default__", 1, true)) then return end
        seen[name] = true
        found[#found + 1] = component
    end
    local function considerIfChestParameter(object)
        local ok, className = pcall(function() return object:GetClass():GetFName():ToString() end)
        if ok and className == CHEST_GAME.chestParameterClass then
            consider(object)
        end
    end
    local blueprint = CHEST_GAME.chestBlueprint .. "." .. CHEST_GAME.blueprintName
    consider(StaticFindObject(blueprint .. CHEST_GAME.templateSuffix))
    local byPath = #found
    for _, component in ipairs(FindAllOf(CHEST_GAME.chestParameterClass) or {}) do
        consider(component)
    end
    local byClass = #found - byPath
    if #found == 0 and ForEachUObject then
        ForEachUObject(considerIfChestParameter)
    end
    UTIL.took("mailbox: the chest templates", byPath .. " by path, " .. byClass .. " by FindAllOf, "
        .. (#found - byPath - byClass) .. " by a walk over every object")
    return found
end

-- Raises every chest template to `slots`; the ones raised, with their size before.
local function raiseTemplates(slots)
    local raised = {}
    for _, component in ipairs(chestTemplates()) do
        local okRead, slotsBefore = pcall(function() return component.SlotNum end)
        if okRead and pcall(function() component.SlotNum = slots end) then
            raised[#raised + 1] = { component = component, slotsBefore = slotsBefore }
        end
    end
    return raised
end

local function restoreTemplates(templates)
    for _, template in ipairs(templates) do
        pcall(function() template.component.SlotNum = template.slotsBefore end)
    end
end

-- Ends the making of the hidden chest: the templates first get their size back, then it is forgotten.
local function stopSpawning()
    if not spawning then return end
    restoreTemplates(spawning.templates)
    spawning = nil
end

-- Asks the game for the hidden chest, its templates raised to the size config.txt asks for.
function CHEST.startMaking(pawn, playerState)
    local manager = BAG.palUtility():GetMapObjectManager(pawn)
    local slots = math.max(SLOTS_MIN, math.min(tonumber(env.cfg.mailbox_slots) or SLOTS_DEFAULT, SLOTS_MAX))
    spawning = { updates = 0, templates = raiseTemplates(slots) }
    log("mailbox: making the hidden chest (" .. slots .. " slots asked; " .. #spawning.templates
        .. " template(s) raised)")
    local ok, answer = pcall(function()
        return manager:RequestSpawnMapObjectByPlayer_Server(FName(CHEST_GAME.chestId), HIDDEN_SPOT, NO_ROTATION,
            playerState.PlayerUId)
    end)
    log(ok and ("mailbox: chest spawn asked, the game answered " .. tostring(answer))
        or ("mailbox: the chest spawn failed: " .. tostring(answer)))
end

-- Whether the hidden chest is being made.
function CHEST.making()
    return spawning ~= nil
end

-- Follows the chest being made, once an update: "made" when it appeared, "failed" when the wait is over without it,
-- nil while it is still awaited (or nothing is being made).
function CHEST.followMaking()
    if not spawning then return nil end
    spawning.updates = spawning.updates + 1
    local chest = CHEST.find()
    if not chest and spawning.updates < CHEST_WAIT.chestAppears then return nil end
    stopSpawning()
    if not chest then
        log("mailbox: no chest appeared at the hidden spot")
        return "failed"
    end
    local okCount, slots = pcall(function() return containerOf(chest):Num() end)
    log("mailbox: hidden chest made: " .. tostring(okCount and slots or "?") .. " slots")
    return "made"
end

-- Kept out of reach and from decaying (ItemChest_04 loses 0.15 HP/s outside a base), locked to the player, unseen.
local function harden(chest, pawn)
    pcall(function()
        local model = BAG.palUtility():GetMapObjectManager(pawn):FindModel(chest:GetModelInstanceId())
        model.DeteriorationDamage = 0
        model.DamagableType = DAMAGE_NONE
    end)
    pcall(function() chest:RequestLockPrivate_ServerInternal(BAG.palUtility():GetLocalPlayerID(pawn)) end)
    pcall(function()
        local actor = chest:GetActor()
        if actor and actor:IsValid() then
            actor:SetActorHiddenInGame(true)
            actor:SetActorEnableCollision(false)
        end
    end)
end

-- Whether an item id has no per-item data (gear, eggs and the like have it).
local function plainId(itemId)
    local perItem = itemId.DynamicId.LocalIdInCreatedWorld
    return perItem.A == 0 and perItem.B == 0 and perItem.C == 0 and perItem.D == 0
end

local function getItemId(slot)
    return slot:GetItemId()
end

local function isPlain(slot)
    local ok, itemId = pcall(getItemId, slot)
    if not ok then return false end
    local okPlain, plain = pcall(plainId, itemId)
    return okPlain and plain
end

-- Puts `count` of an item in a slot. When its item id can't be changed in place, the whole id is replaced.
local function put(slot, id, count)
    if not pcall(function() slot.ItemId.StaticId = FName(id) end) then
        UTIL.took("mailbox: a slot's item id", "set whole (its StaticId could not be set alone)")
        slot.ItemId = { StaticId = FName(id), DynamicId = slot.ItemId.DynamicId }
    end
    slot.StackCount = count
    pcall(function() slot:OnRep_ItemId() end)
    pcall(function() slot:OnRep_StackCount() end)
end

-- Empties a slot; whether it is empty now.
local function clear(slot)
    pcall(function() put(slot, "None", 0) end)
    local ok, empty = pcall(function() return slot:IsEmpty() end)
    return ok and empty
end

-- Puts the first entry still waiting into an empty slot, as much as one stack holds, and counts it as in the chest.
local function putFirstWaiting(slot, waiting, inChest)
    local entry = waiting[1]
    local count = math.min(entry.n, BAG.maxStack(entry.id))
    put(slot, entry.id, count)
    inChest[entry.id] = (inChest[entry.id] or 0) + count
    entry.n = entry.n - count
    if entry.n <= 0 then
        table.remove(waiting, 1)
    end
end

-- Empties the chest of plain items, then fills it from the list. Plain items in this chest are only ever copies of the
-- list (a view that never closed, or a world save older than the mod's save after a crash): the list is the truth.
-- Returns the list entries that did not fit, the chest's slot count, the slots filled, and item id -> count put in.
local function emptyThenFillChest(chest)
    local container = containerOf(chest)
    local waiting, inChest = {}, {}
    for _, entry in ipairs(LIST.queue) do
        waiting[#waiting + 1] = { id = entry.id, n = entry.n }
    end
    local slots, placed = container:Num(), 0
    for index = 0, slots - 1 do
        local slot = container:Get(index)
        if slot and slot:IsValid() then
            if not slot:IsEmpty() and isPlain(slot) then
                clear(slot)
            end
            if #waiting > 0 and slot:IsEmpty() then
                putFirstWaiting(slot, waiting, inChest)
                placed = placed + 1
            end
        end
    end
    return waiting, slots, placed, inChest
end

-- The chest's plain items as a list of { id, n }, and the slots that hold them.
local function plainStacksIn(container)
    local stacks, plainSlots = {}, {}
    for index = 0, container:Num() - 1 do
        local slot = container:Get(index)
        if slot and slot:IsValid() and not slot:IsEmpty() and isPlain(slot) then
            local id, count = slot:GetItemId().StaticId:ToString(), slot:GetStackCount()
            if count > 0 then
                LIST.addCount(stacks, id, count)
                plainSlots[#plainSlots + 1] = slot
            end
        end
    end
    return stacks, plainSlots
end

-- The list once the chest closes: what is in the chest, up to what the mailbox put in, then what never fitted. More of
-- an item than the mailbox put in is a deposit the sweep had not returned yet: it is returned as `extra`.
local function listAfterClosing(stacks)
    local list, extra = {}, {}
    for _, entry in ipairs(stacks) do
        local keep = math.min(entry.n, view.inChest[entry.id] or 0)
        if keep > 0 then
            LIST.addCount(list, entry.id, keep)
        end
        if entry.n > keep then
            extra[#extra + 1] = { id = entry.id, n = entry.n - keep }
        end
    end
    for _, entry in ipairs(view.held) do
        LIST.addCount(list, entry.id, entry.n)
    end
    return list, extra
end

-- A deposit put in just before closing goes to the bag; what the bag refuses stays in the list, so nothing is lost.
local function returnLastMomentDeposit(entry)
    local back = BAG.give(entry.id, entry.n)
    if back < entry.n then
        LIST.addCount(LIST.queue, entry.id, entry.n - back)
    end
    log("mailbox: " .. entry.n .. " " .. entry.id .. " put in at the last moment went back to the bag (" .. back
        .. " fitted)")
end

-- The chest's plain items back into the list, and the chest emptied. The list is set before any slot is cleared: a
-- slot left uncleared is a copy, which the next emptyThenFillChest removes.
local function absorb()
    assert(view.chest:IsValid(), "the chest is gone")
    local stacks, plainSlots = plainStacksIn(containerOf(view.chest))
    local list, extra = listAfterClosing(stacks)
    LIST.queue = list
    for _, slot in ipairs(plainSlots) do
        clear(slot)
    end
    for _, entry in ipairs(extra) do
        returnLastMomentDeposit(entry)
    end
end

------------------------------------------------------------------------------------------------------------------------
-- While the chest window is open (every update): deposits go back to the bag, items received meanwhile go in, and the
-- heading names the mailbox.
-- Deposits are refused first by the game's own rule for what a container accepts (FPalItemPermission: a list of item
-- types and ids; ours names one id no item has). Untested in game: whether a deposit still gets through (the log says
-- so when one does). Whatever does is found by comparing the chest with what the mailbox put in (view.inChest), and
-- goes back by the game's own move to the bag (keeps gear's data and food's freshness); if that does nothing within
-- CHEST_WAIT.gameMove, plain items are taken out and given to the bag directly, and gear is left with a note.
--
-- The rule the sweep keeps, for every item id while the view is open: the list's count (M.queue) = view.inChest (put
-- in the chest by the mailbox, not taken) + view.held (did not fit yet). Each place that changes a side changes the
-- other with it: M.add adds to the list and to held (CHEST.received); emptyThenFillChest and fillSlotFromWaiting move
-- from held to inChest; dropTakenFromList takes from inChest and the list; returnByHand adds to both when the bag is
-- full; absorb rebuilds the list from the chest and held as the view closes. For example: 50 Wood shown, the player
-- takes 20; the sweep sees 30 in the chest, so inChest is 30 and the list 30.

local function lockPermission(container)
    local function lock(permission)
        permission.PermissionTypeA:Empty()
        permission.PermissionTypeB:Empty()
        permission.PermissionItemStaticIds:Empty()
        permission.PermissionItemStaticIds[1] = FName(NO_DEPOSITS)
    end
    local okContainer, errContainer = pcall(function() lock(container.Permission) end)
    pcall(function() container:OnRep_Permission() end)
    local locked = 0
    for index = 0, container:Num() - 1 do
        local slot = container:Get(index)
        if slot and pcall(function() lock(slot.Permission) end) then
            locked = locked + 1
            pcall(function() slot:OnRep_Permission() end)
        end
    end
    local containerSaid = okContainer and "set" or ("not set (" .. tostring(errContainer) .. ")")
    once("permission", "mailbox: deposits refused by permission: container " .. containerSaid .. ", " .. locked
        .. " slot(s)")
end

local function guidOf(guid)
    return { A = guid.A, B = guid.B, C = guid.C, D = guid.D }
end

-- A new guid from the game, or a made-up one when the game's NewGuid fails.
local function newGuid()
    local ok, guid = pcall(function() return guidOf(StaticFindObject(CHEST_GAME.guidLibrary):NewGuid()) end)
    if ok and guid and guid.A then return guid end
    once("newguid", "mailbox: a move's guid is made up: the game's NewGuid failed (" .. tostring(guid) .. ")")
    return { A = math.random(1, RANDOM_MAX), B = math.random(1, RANDOM_MAX), C = math.random(1, RANDOM_MAX),
             D = math.random(1, RANDOM_MAX) }
end

-- Asks the game to move `count` from a chest slot to the player's bag (the game's own move keeps the item's data).
local function moveToBag(pawn, slot, count)
    local _, playerState = BAG.player()
    local bag = guidOf(playerState:GetInventoryData().MyInventoryInfo.CommonContainerId.ID)
    local slotId = slot:GetSlotId()
    local from = { SlotId = { ContainerId = { ID = guidOf(slotId.ContainerId.ID) }, SlotIndex = slotId.SlotIndex },
                   Num = count }
    local transmitter = BAG.palUtility():GetNetworkTransmitter(pawn)
    local item = transmitter.Item
    if item and item:IsValid() then
        UTIL.took("mailbox: the network transmitter's item part", "its Item field")
    else
        UTIL.took("mailbox: the network transmitter's item part", "GetItem()")
        item = transmitter:GetItem()
    end
    item:RequestMoveToContainer_ToServer(newGuid(), { ID = bag }, { from })
end

local function tellDepositReturnedOnce(what)
    if view.told then return end
    view.told = true
    env.notify("The mailbox only hands items out: " .. what .. " went back to your bag.")
end

-- One slot read into `chest` (see readChest).
local function readSlot(chest, slot, index)
    if slot:IsEmpty() then
        chest.maybeEmpty[#chest.maybeEmpty + 1] = index
        return
    end
    local okId, itemId = pcall(getItemId, slot)
    local okPlain, plain = false, false
    if okId then
        okPlain, plain = pcall(plainId, itemId)
    end
    if okPlain and plain then
        local id = itemId.StaticId:ToString()
        chest.plainCount[id] = (chest.plainCount[id] or 0) + slot:GetStackCount()
        chest.plainSlots[id] = chest.plainSlots[id] or {}
        chest.plainSlots[id][#chest.plainSlots[id] + 1] = slot
        chest.slotIndex[slot] = index
        return
    end
    -- Gear is returned piece by piece: its key is its slot and its own id.
    local okKey, ownId = false, nil
    if okId then
        okKey, ownId = pcall(function()
            local perItem = itemId.DynamicId.LocalIdInCreatedWorld
            return perItem.A .. "-" .. perItem.B .. "-" .. perItem.C .. "-" .. perItem.D
        end)
    end
    chest.gear[#chest.gear + 1] = { slot = slot, index = index, key = index .. ":" .. (okKey and ownId or "?") }
end

-- What the chest holds now, read once per slot up to the last one in use.
local function readChest(container)
    local okLast, last = pcall(function() return container:GetLastNotEmptyIndex() end)
    last = (okLast and type(last) == "number") and last or (container:Num() - 1)
    local chest = {
        plainCount = {},        -- item id -> how many of it the chest holds (plain items only)
        plainSlots = {},        -- item id -> its slots, in slot order (the newest stacks last)
        slotIndex = {},         -- a plain item's slot -> its index
        gear = {},              -- the pieces of gear: { slot, index, key }
        maybeEmpty = {},        -- indexes of slots seen empty
        lastUsedSlot = last,    -- the last slot index in use; every slot after it is empty
    }
    P.count("sweep", last + 1)
    for index = 0, last do
        local slot = container:Get(index)
        if slot and slot:IsValid() then
            readSlot(chest, slot, index)
        end
    end
    return chest
end

-- Taken out: off the list at once, so the list always matches the chest. A view dropped without closing (a world
-- change, a quit) then leaves nothing taken on the list for the next fill to give again. Whether the list changed.
local function dropTakenFromList(chest)
    local changed = false
    for id, shown in pairs(view.inChest) do
        local now = chest.plainCount[id] or 0
        if now < shown then
            view.inChest[id] = now
            LIST.removeCount(LIST.queue, id, shown - now)
            changed = true
        end
    end
    return changed
end

-- Asks the game to move a deposit of `extra` back to the bag, from the newest stacks first.
local function askGameToMove(pawn, slots, extra)
    local left = extra
    for k = #slots, 1, -1 do
        if left <= 0 then break end
        local count = math.min(left, slots[k]:GetStackCount())
        local ok, err = pcall(moveToBag, pawn, slots[k], count)
        if not ok then
            once("moveerr", "mailbox: the move to the bag failed: " .. tostring(err))
            break
        end
        left = left - count
    end
end

-- The game's move did nothing: the deposit is taken out of its slots and given to the bag directly. What the bag
-- refuses stays as mailbox items. Whether the list changed.
local function returnByHand(id, extra, slots)
    once("byhand", "mailbox: the move to the bag did nothing; deposits are returned by hand")
    local back, why = BAG.give(id, extra)
    local left = back
    for k = #slots, 1, -1 do
        if left <= 0 then break end
        local have = slots[k]:GetStackCount()
        local count = math.min(left, have)
        if count == have then
            clear(slots[k])
        else
            put(slots[k], id, have - count)
        end
        left = left - count
    end
    if back >= extra then return false end
    view.inChest[id] = (view.inChest[id] or 0) + (extra - back)
    LIST.addCount(LIST.queue, id, extra - back)
    LIST.tellStays(id, why)
    return true
end

-- One item's deposit: first the game's move, then by hand once that has waited CHEST_WAIT.gameMove. Whether the list
-- changed.
local function returnDeposit(pawn, chest, id, extra)
    local waited = view.depositUpdates[id] or 0
    once("deposit", "mailbox: a deposit got into the chest (" .. extra .. " " .. id .. "): returning it")
    if waited == 0 then
        askGameToMove(pawn, chest.plainSlots[id], extra)
        tellDepositReturnedOnce(BAG.nameOf(id))
    end
    view.depositUpdates[id] = waited + 1
    if waited + 1 <= CHEST_WAIT.gameMove then return false end
    local changed = returnByHand(id, extra, chest.plainSlots[id])
    view.depositUpdates[id] = nil
    return changed
end

-- Plain items the player put in (more than the mailbox put in) go back to the bag. Whether the list changed, and the
-- set of item ids whose slots were acted on.
local function returnDeposits(pawn, chest)
    local changed, handled = false, {}
    for id, count in pairs(chest.plainCount) do
        local extra = count - (view.inChest[id] or 0)
        if extra > 0 then
            handled[id] = true
            changed = returnDeposit(pawn, chest, id, extra) or changed
        else
            if (view.depositUpdates[id] or 0) > 0 then
                once("moved", "mailbox: a deposit went back to the bag by the game's move")
            end
            view.depositUpdates[id] = nil
        end
    end
    return changed, handled
end

local function gearName(piece)
    return BAG.nameOf(piece.slot:GetItemId().StaticId:ToString())
end

-- Gear can only go back by the game's move: asked once; if it is still there after CHEST_WAIT.gameMove, the player is
-- asked to take it out.
local function returnGear(pawn, gear)
    local gearUpdates = {}                    -- only the pieces in the chest now
    for _, piece in ipairs(gear) do
        gearUpdates[piece.key] = view.gearUpdates[piece.key]
    end
    view.gearUpdates = gearUpdates
    for _, piece in ipairs(gear) do
        local waited = view.gearUpdates[piece.key] or 0
        if waited == 0 then
            once("geardeposit", "mailbox: gear got into the chest: returning it")
            local ok, err = pcall(moveToBag, pawn, piece.slot, piece.slot:GetStackCount())
            if not ok then
                once("moveerr", "mailbox: the move to the bag failed: " .. tostring(err))
            end
            tellDepositReturnedOnce("your " .. gearName(piece))
        elseif waited == CHEST_WAIT.gameMove then
            env.notify("Take your " .. gearName(piece) .. " back out of the mailbox: it can't return it.")
        end
        view.gearUpdates[piece.key] = waited + 1
    end
end

-- The slots that may be empty now, in order: those seen empty, those the deposit handling acted on (by the game's
-- move or by hand), and those past the last one in use. Visiting only these spares a walk over every slot.
local function slotsThatMayBeEmpty(container, chest, handled)
    local maybe = chest.maybeEmpty
    for id in pairs(handled) do
        for _, slot in ipairs(chest.plainSlots[id]) do
            maybe[#maybe + 1] = chest.slotIndex[slot]
        end
    end
    for _, piece in ipairs(chest.gear) do
        maybe[#maybe + 1] = piece.index
    end
    for index = chest.lastUsedSlot + 1, container:Num() - 1 do
        maybe[#maybe + 1] = index
    end
    table.sort(maybe)
    return maybe
end

local function fillSlotFromWaiting(slot)
    if not (slot and slot:IsValid() and slot:IsEmpty()) then return end
    putFirstWaiting(slot, view.held, view.inChest)
end

-- Items received while the chest is open go into its empty slots.
local function refillFromWaiting(container, chest, handled)
    if #view.held == 0 then return end
    local seen = {}
    for _, index in ipairs(slotsThatMayBeEmpty(container, chest, handled)) do
        if #view.held == 0 then break end
        if not seen[index] then
            seen[index] = true
            P.count("refill")
            fillSlotFromWaiting(container:Get(index))
        end
    end
end

-- Keeps the chest and the list in step while the view is open (see the rule above).
local function sweep(pawn)
    local container = containerOf(view.chest)
    local chest = readChest(container)
    local taken = dropTakenFromList(chest)
    local returned, handled = returnDeposits(pawn, chest)
    returnGear(pawn, chest.gear)
    refillFromWaiting(container, chest, handled)
    if taken or returned then
        env.save()
    end
end

-- The mailbox emblem (art/ap-mailbox-emblem-64.png) beside the heading, once a view, only where the heading sits in a
-- horizontal box within HEADING_ROW_LEVELS above it (it sits in a SizeBox; the row is further up); the chain of
-- parents is logged either way. Untested in game: whether the emblem shows beside the heading.
local function addEmblemOnce(heading)
    if view.emblem then return end
    view.emblem = true
    local row, widget, chain = nil, heading, {}
    for _ = 1, HEADING_ROW_LEVELS do
        local okParent, parent = pcall(function() return widget:GetParent() end)
        if not (okParent and parent and parent:IsValid()) then break end
        local okName, kind = pcall(function()
            return parent:GetFName():ToString() .. ":" .. parent:GetClass():GetFName():ToString()
        end)
        chain[#chain + 1] = okName and kind or "?"
        if okName and kind:find(":HorizontalBox$") then
            row = parent
            break
        end
        widget = parent
    end
    if not row then
        log("mailbox: no row above the heading (" .. table.concat(chain, " < ") .. "); no emblem")
        return
    end
    local box = require("art").box(row, CHEST_GAME.emblemArt, EMBLEM_SIZE, EMBLEM_SIZE)
    if not box then return end
    local slot = row:AddChild(box)
    pcall(function() slot:SetVerticalAlignment(WIDGETS.VALIGN.center) end)
    pcall(function() slot:SetPadding({ Left = EMBLEM_GAP, Top = 0, Right = 0, Bottom = 0 }) end)
    log("mailbox: emblem added beside the heading (" .. table.concat(chain, " < ") .. ")")
end

-- Whether a widget answers as valid. An IsValid that raises counts as valid too: the heading is there, Lua just
-- can't ask it.
local function answersValid(widget)
    return widget and select(2, pcall(function() return widget:IsValid() end))
end

-- The chest window's heading, and whether it was found through the mailbox's own HUD widget (chests share the window
-- class, so only that one is surely ours); else any chest window's heading that shows.
local function findHeading()
    local heading = nil
    pcall(function() heading = view.hud:GetWidget(view.id)[CHEST_GAME.chestMenu][CHEST_GAME.heading] end)
    if answersValid(heading) then
        UTIL.took("mailbox: the chest window's heading", "found by the HUD's id")
        return heading, true
    end
    for _, widget in ipairs(FindAllOf(CHEST_GAME.chestMenuClass) or {}) do
        local ok, found = pcall(function()
            return widget:IsValid() and widget:IsVisible() and widget[CHEST_GAME.heading]
        end)
        if ok and found then
            UTIL.took("mailbox: the chest window's heading", "found by its class " .. CHEST_GAME.chestMenuClass)
            return found, false
        end
    end
    return nil, false
end

-- Sets the heading to the mailbox's name. The heading is bound to the game's text table, which puts its own text back
-- when the window rebuilds: it is unbound first.
local function nameTheChestWindow(heading)
    local okRead, now = pcall(function() return heading:GetText():ToString() end)
    if okRead and now == LIST.TITLE then return end
    pcall(function() heading.IsAutoTextSetWhenWidgetRebuilt = false end)
    pcall(function() heading.BindTextDatatableHandle.RowName = FName("None") end)
    pcall(function() heading:SetText(FText(LIST.TITLE)) end)
    once("heading", "mailbox: chest window heading was '" .. tostring(okRead and now or "?") .. "'; set to ours")
end

-- The heading named, and the emblem beside it where the window is surely the mailbox's.
local function dressChestWindow()
    local heading, ours = findHeading()
    if ours then
        local ok, err = pcall(addEmblemOnce, heading)
        if not ok then
            once("emblem", "mailbox: emblem error: " .. tostring(err))
        end
    end
    if not heading then
        once("noheading", "mailbox: no chest window heading found")
        return
    end
    nameTheChestWindow(heading)
end

-- Opens the game's chest window on the hidden chest, emptied of copies and filled from the list.
function CHEST.open(chest, pawn)
    harden(chest, pawn)
    pcall(lockPermission, containerOf(chest))
    local held, slots, placed, inChest = emptyThenFillChest(chest)
    local hud = BAG.palUtility():GetHUDService(pawn)
    local parameter = hud:CreateDispatchParameterForK2Node(pawn, StaticFindObject(CHEST_GAME.mapObjectParameter))
    parameter.MapObjectConcreteModel = chest
    local id = hud:ShowCommonUI(ITEM_CHEST_WINDOW, parameter)
    view = newView(id, hud, chest, held, inChest)
    log("mailbox: chest view open (" .. slots .. " slots, " .. placed .. " filled, " .. #held
        .. " kind(s) waiting behind)")
    if #held > 0 then
        env.notify("The mailbox shows " .. placed .. " stacks at a time: take some to see the rest.")
    end
end

-- Whether the HUD still has the chest window by the id it gave.
local function chestOpenById()
    local open = false
    pcall(function()
        local widget = view.hud:GetWidget(view.id)
        open = widget ~= nil and widget:IsValid()
    end)
    return open
end

-- Whether any chest window shows (an object-array walk: only done when its answer is used).
local function chestWindowShown()
    for _, widget in ipairs(FindAllOf(CHEST_GAME.chestWindowClass) or {}) do
        local ok, showing = pcall(function()
            return widget:IsValid() and widget:IsVisible() and (widget:IsInViewport() or widget:GetParent() ~= nil)
        end)
        if ok and showing then return true end
    end
    return false
end

-- Empties the chest back into the list and forgets the view. When the chest can't be read, the view is forgotten all
-- the same, and the next open's emptyThenFillChest removes the copies left in it.
function CHEST.close()
    local ok, err = pcall(absorb)
    if not ok then
        log("mailbox: could not empty the chest (" .. tostring(err) .. "); it is emptied on the next open")
        view = nil
        return
    end
    view = nil
    env.save()
    log("mailbox: chest view closed; " .. #LIST.queue .. " kind(s) in the mailbox")
end

-- How the view's closing will be seen, once that is known: the HUD's id, else the chest window widget; if neither
-- shows it open within CHEST_WAIT.followView, it can't be followed and is never emptied early (the next open settles
-- it first).
local function settleHowFollowed(byId, byWidget)
    if byId then
        view.how = "id"
    elseif byWidget then
        view.how = "widget"
    elseif view.updatesOpen >= CHEST_WAIT.followView then
        view.how = "unknown"
    end
    if not view.how then return end
    local okClass, class = pcall(function() return view.hud:GetWidget(view.id):GetClass():GetFName():ToString() end)
    log("mailbox: chest window followed by " .. view.how .. (okClass and (" (" .. tostring(class) .. ")") or ""))
end

-- Every update while the view is open: the sweep, the heading, and whether the player has closed it.
function CHEST.followView()
    if not view then return end
    view.updatesOpen = view.updatesOpen + 1
    if view.chest:IsValid() then
        local ok, err = pcall(sweep, (BAG.player()))
        if not ok then
            UTIL.onceErr("mailbox sweep", err, "mailbox: sweep error: " .. tostring(err))
        end
    end
    -- The chest widget is looked for only when its answer is used: the id says it is not open, or the view is
    -- followed by the widget.
    local byId = chestOpenById()
    local byWidget = false
    if not byId or view.how == "widget" then
        byWidget = chestWindowShown()
    end
    -- (not while it closes: there is no heading then)
    if byId or byWidget then
        pcall(dressChestWindow)
    end
    if not view.how then
        settleHowFollowed(byId, byWidget)
    end
    if (view.how == "id" and not byId) or (view.how == "widget" and not byWidget) then
        CHEST.close()
    end
end

-- Whether a chest view is open.
function CHEST.viewing()
    return view ~= nil
end

-- Whether a chest view is open that can be followed (its closing is seen, or not yet known).
function CHEST.followable()
    return view ~= nil and view.how ~= "unknown"
end

-- Whether a chest view is open that can't be followed: it waits for the next open to settle it.
function CHEST.lost()
    return view ~= nil and view.how == "unknown"
end

-- An item received while the view is open: it waits behind, to go into the chest as a slot empties.
function CHEST.received(id, count)
    if view then
        LIST.addCount(view.held, id, count)
    end
end

-- The chest window the mailbox has open (crate_window.lua draws over it), or nil.
function CHEST.widget()
    if not view then return nil end
    local ok, widget = pcall(function() return view.hud:GetWidget(view.id) end)
    return ok and widget or nil
end

-- Forgets the view and the chest being made (a new world or a new seed: they belong to the old one). A view not yet
-- settled leaves copies in the chest, which the next open removes.
function CHEST.forget()
    stopSpawning()
    view = nil
end

------------------------------------------------------------------------------------------------------------------------
-- The list and the save file (the line mail=Wood:50,Stone:50, in the mod's per-seed save).

-- The mailbox's states, as the player sees them, and the moves between them. Every state but "closed" is held in the
-- records named; mailboxState() says which one the mailbox is in.
--   closed      nothing is open                       (openAsked false, no window, no view, nothing being made)
--   asked       an open was asked for; it waits WAIT.menuCloses for the game's menu to close (openAsked)
--   window      the LogicMod's window is up            (mailbox_window: the window record)
--   making      the hidden chest is being made, up to CHEST_WAIT.chestAppears (mailbox_chest: spawning; openAsked)
--   opening     the chest window is up, how to see it close not yet known (mailbox_chest: view, how nil)
--   viewing     the chest window is up and followed by the HUD's id or its widget (view.how "id" or "widget")
--   lost        the chest window can't be followed: left alone until the next open settles it (view.how "unknown")
-- The moves:
--   closed -> asked       M.open (a button or the key)
--   asked -> window       the wait is over and the LogicMod's window opened (tryWindow)
--   asked -> opening      the wait is over and the hidden chest was found (tryChest)
--   asked -> making       the wait is over and the world has no hidden chest yet (tryChest)
--   asked -> closed       the wait is over and there is no player (tryOpen)
--   making -> opening     the chest appeared: the same update goes on to open it (followChestBeingMade, tryOpen)
--   making -> closed      no chest within CHEST_WAIT.chestAppears: everything goes to the bag (followChestBeingMade)
--   window -> closed      the HUD no longer has the window (WINDOW.follow)
--   opening -> viewing    the HUD's id or the widget shows it open (CHEST.followView)
--   opening -> lost       neither did within CHEST_WAIT.followView (CHEST.followView)
--   viewing -> closed     the player closed it: the chest is emptied into the list (CHEST.close)
--   lost -> asked         only through a new M.open; the view is settled first (settleLostView)
--   any -> closed         a new world (forgetOnWorldChange) or a new seed (M.reset)
-- Not obvious: while asked, nothing else in updateMailbox runs (no sweep, no spawn count, no window-gone test), and
-- M.open is allowed while making and lost, so a key press then pauses them for the wait. In lost, the sweep still runs
-- every update and M.busy() answers false.

local WAIT = {
    menuCloses = UTIL.updates(0.6),   -- after an open is asked, so the game's menu closes first
}

-- State: the list. Forgotten: on a new seed (M.reset()); kept in the save file.
M.queue = {}                  -- { { id = static item id, n = count } } in arrival order, one entry per item
-- State: the opening. Forgotten: on a new world (forgetOnWorldChange()), on a new seed (M.reset()).
local openAsked = false       -- an open was asked for and is not done yet
local updatesToWait = 0       -- updates left before an asked open is tried (the menu closes first)
-- State. Forgotten: never (it is how a new world is seen).
local world = nil             -- the player controller's address: a new one means a new world (or the title)
-- State. Forgotten: never (the player is told once a session).
local tipped = false          -- the player was told where items wait

-- Adds `count` of an item to a list of { id, n }, to its entry if it has one.
function M.addCount(list, id, count)
    for _, entry in ipairs(list) do
        if entry.id == id then
            entry.n = entry.n + count
            return
        end
    end
    list[#list + 1] = { id = id, n = count }
end

-- Takes `count` of an item off a list of { id, n }; an entry that reaches 0 goes.
function M.removeCount(list, id, count)
    for index, entry in ipairs(list) do
        if entry.id == id then
            entry.n = entry.n - count
            if entry.n <= 0 then
                table.remove(list, index)
            end
            return
        end
    end
end

-- Whether the mailbox is on (config.txt mailbox=0 turns it off).
function M.on()
    return env.cfg.mailbox ~= "0"
end

-- How many kinds of item wait, and how many items in all.
function M.count()
    local kinds, items = 0, 0
    for _, entry in ipairs(M.queue) do
        kinds = kinds + 1
        items = items + entry.n
    end
    return kinds, items
end

-- Which of the states above the mailbox is in.
local function mailboxState()
    if WINDOW.isOpen() then return "window" end
    if CHEST.making() then return "making" end
    if CHEST.lost() then return "lost" end
    if CHEST.viewing() then return "viewing" end
    if openAsked then return "asked" end
    return "closed"
end

-- The mailbox is open or opening (its window, the chest view, or the hidden chest still being made): traps wait. A
-- chest view that could not be followed does not count: it stays until the next open, which could hold every trap
-- back for the rest of the session.
function M.busy()
    local state = mailboxState()
    return state ~= "closed" and (state ~= "lost" or openAsked)
end

-- The buttons' label. The count is the kinds waiting (a stack each in the chest), not the items: one crate's gold
-- alone is thousands of coins.
function M.label()
    local kinds = M.count()
    return M.TITLE .. (kinds > 0 and (" (" .. kinds .. ")") or "")
end

-- An item received: it waits in the list (and in the chest's waiting line while the chest view is open).
function M.add(id, count)
    M.addCount(M.queue, id, count)
    CHEST.received(id, count)
    if not tipped then
        tipped = true
        -- Only the Esc route: the Inventory page's button is untested in game.
        env.notify("Items you receive wait in your Archipelago Mailbox: Esc menu > Archipelago Mailbox.")
    end
end

-- The mailbox's lines for the save file.
function M.serialize()
    local parts = {}
    for _, entry in ipairs(M.queue) do
        parts[#parts + 1] = entry.id .. ":" .. entry.n
    end
    return "mail=" .. table.concat(parts, ",") .. "\n"
end

-- One line of the save file; true if it was the mailbox's.
function M.load(line)
    local list = line:match("^mail=(.*)$")
    if not list then return false end
    if CHEST.viewing() then return true end           -- a chest view is open: the list in memory is newer
    M.queue = {}
    for id, count in list:gmatch("([^:,]+):(%d+)") do
        M.addCount(M.queue, id, tonumber(count))
    end
    return true
end

-- Forgets the last seed's list and whatever was open.
function M.reset()
    M.queue, openAsked = {}, false
    WINDOW.forget()
    CHEST.forget()
end

-- Tells the player an item stays in the mailbox because the bag is full; any other reason is only logged.
function M.tellStays(id, why)
    if why == "full" then
        env.notify("Your bag is full: " .. BAG.nameOf(id) .. " stays in the mailbox.")
        return
    end
    log("mailbox: " .. id .. " stays in the mailbox: " .. tostring(why))
end

-- Takes one item's whole entry into the bag; how many went in. What the bag refuses stays in the list.
function M.take(id)
    for index, entry in ipairs(M.queue) do
        if entry.id == id then
            local got, why = BAG.give(id, entry.n)
            entry.n = entry.n - got
            if entry.n <= 0 then
                table.remove(M.queue, index)
            end
            if got == 0 then
                M.tellStays(id, why)
            end
            env.save()
            return got
        end
    end
    return 0
end

-- Takes everything into the bag; how many items went in, and how many are left.
function M.takeAll()
    local took, left = 0, 0
    for _, entry in ipairs({ table.unpack(M.queue) }) do
        local count = entry.n
        local got = M.take(entry.id)
        took = took + got
        left = left + (count - got)
    end
    return took, left
end

-- Asks for the mailbox to open; it opens on a later update, once the menu the player clicked in has closed.
function M.open()
    if not M.on() then
        env.notify("The mailbox is off (mailbox=0 in config.txt): items go straight to your bag.")
        return
    end
    if not env.connected() and #M.queue == 0 then
        env.notify("Connect to Archipelago to see your mailbox.")
        return
    end
    -- Already open (the key pressed again): nothing to do; asking again would reopen it as soon as it closes. A chest
    -- view that can't be followed is the exception: a new open is what settles it.
    if WINDOW.isOpen() or CHEST.followable() then return end
    openAsked, updatesToWait = true, WAIT.menuCloses
end

-- A new world (or the title): what was open or asked for belongs to the old one.
local function forgetOnWorldChange(ctx)
    local worldNow
    if ctx then
        worldNow = ctx.worldKey
    else
        worldNow = BAG.worldKey()
    end
    if worldNow == world then return end
    local state = mailboxState()
    if world and state ~= "closed" then
        log("mailbox: the world changed; " .. (CHEST.viewing() and "the open chest view is settled on the next open"
            or "dropped what was open"))
    end
    CHEST.forget()
    WINDOW.forget()
    openAsked = false
    forgetOnce()
    world = worldNow
end

-- The hidden chest is being made: when it appears, the open goes on in this same update (tryOpen); when it never
-- does, everything goes to the bag.
local function followChestBeingMade()
    if CHEST.followMaking() ~= "failed" then return end
    local took, left = M.takeAll()
    env.notify("The mailbox chest could not be made: " .. took .. " item(s) went to your bag"
        .. (left > 0 and (", " .. left .. " stay in the mailbox") or "") .. ".")
    openAsked = false
end

-- A chest view that can't be followed is settled (emptied into the list) when a new open is asked for.
local function settleLostView()
    if openAsked and CHEST.lost() then
        CHEST.close()
    end
end

-- The LogicMod's window, if it is installed; whether it opened. When it fails, the chest is used in its place.
local function tryWindow(pawn)
    if not WINDOW.available(env.cfg) then return false end
    openAsked = false
    local ok, err = pcall(WINDOW.open, pawn)
    if ok then return true end
    log("mailbox: the LogicMod window failed (" .. tostring(err) .. "); using the chest")
    WINDOW.forget()
    openAsked = true          -- the chest opens in its place, once it is found or made
    return false
end

-- The chest window on the hidden chest, or the chest made first when the world has none.
local function tryChest(pawn, playerState)
    local chest = CHEST.find()
    if not chest then
        CHEST.startMaking(pawn, playerState)
        return
    end
    openAsked = false
    local ok, err = pcall(CHEST.open, chest, pawn)
    if not ok then
        log("mailbox: could not open the chest: " .. tostring(err))
    end
end

-- Opens what was asked for, once nothing else is open.
local function tryOpen()
    if not openAsked or CHEST.making() or CHEST.viewing() or WINDOW.isOpen() then return end
    local pawn, playerState = BAG.player()
    if not pawn or not playerState then
        log("mailbox: no " .. (pawn and "player state" or "player pawn") .. " to open the mailbox for; not opened")
        openAsked = false
        return
    end
    if tryWindow(pawn) then return end
    tryChest(pawn, playerState)
end

-- One update of the mailbox, as a list of steps in order.
local function updateMailbox(ctx)
    forgetOnWorldChange(ctx)
    WINDOW.hookButtons()
    WINDOW.runClicks()
    -- While an open waits for the menu to close, nothing below runs.
    if openAsked and updatesToWait > 0 then
        updatesToWait = updatesToWait - 1
        return
    end
    WINDOW.follow()
    CHEST.followView()
    followChestBeingMade()
    settleLostView()
    tryOpen()
end

-- Called from the mod's update loop (game thread). ctx: this update's player from main.lua ({ pc, pawn, worldKey,
-- playerState() }); used for this one update only.
function M.update(ctx)
    BAG.useFrame(ctx)
    local ok, err = pcall(updateMailbox, ctx)
    BAG.useFrame(nil)
    if not ok then
        error(err, 0)
    end
end

-- Whether the chest view is open (for the perf probe's state field).
function M.viewOpen()
    return CHEST.viewing()
end

-- The chest window the mailbox has open (crate_window.lua draws over it), or nil.
function M.chestWidget()
    return CHEST.widget()
end

-- main.lua's bundles, crates and Nomad gifts use the bag through these (the bag section above).
M.give = BAG.give
M.nameOf = BAG.nameOf

-- Takes what main.lua hands over (see env above) and binds the mailbox key, if config.txt names one.
function M.install(handedOver)
    env = handedOver
    local parts = { list = M, once = once, notify = env.notify, save = env.save, cfg = env.cfg,
                    guardedHook = env.guardedHook }
    WINDOW.install(parts)
    local key = ((env.cfg.mailbox_key or ""):match("^%s*(%w+)%s*$") or ""):upper()
    if key == "" or not (RegisterKeyBind and Key and Key[key]) then return end
    -- A key bind runs off the game thread: it only hands over this function, made once.
    local function mailboxKey()
        local ok, err = pcall(M.open)
        if not ok then
            log("mailbox key error: " .. tostring(err))
        end
    end
    RegisterKeyBind(Key[key], function() ExecuteInGameThread(mailboxKey) end)
    log("mailbox key: " .. key)
end

return M
