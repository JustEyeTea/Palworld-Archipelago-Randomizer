-- The mailbox's hidden chest: without the LogicMod, the mailbox is the game's own chest window on a chest of its own,
-- made once per world far outside the map and deep underground (mailbox_slots, default 300 slots) and kept from
-- decaying; its window opened on it and followed until the player closes it. Its parts, each in its own file: the
-- slots filled and emptied (mailbox_chest_slots.lua), the sweep while the window is open (mailbox_chest_sweep.lua) and
-- the window's heading (mailbox_chest_heading.lua). Wired by mailbox.lua.
-- Tests: mod/test/tests/mailbox.lua; group "the mailbox" (tools/lua_harness.sh, in CI).
local CHEST = {}
local UTIL = require("util")
local BAG = require("bag")
local log = UTIL.log
-- The chest's parts, each called by its own name: its slots filled and emptied, the sweep while its window is open,
-- and the window's heading.
local SLOTS = require("mailbox_chest_slots")
local SWEEP = require("mailbox_chest_sweep")
local HEADING = require("mailbox_chest_heading")

-- What mailbox.lua hands over (CHEST.install), here and to the parts.
--   list                  the mailbox module: its queue, addCount, removeCount, tellStays and TITLE
--   once(key, msg)        the mailbox's log-once for this world (the parts use it)
--   notify(text)          shows a line to the player
--   save()                writes the mod's save file
--   cfg                   config.txt's values (mailbox_slots)
local env, LIST

function CHEST.install(handedOver)
    env, LIST = handedOver, handedOver.list
    SLOTS.install(handedOver)
    SWEEP.install(handedOver)
    HEADING.install(handedOver)
end

local CHEST_GAME = {
    chestId = "ItemChest_04",                             -- the map object the chest is made as (a big chest)
    chestBlueprint = "/Game/Pal/Blueprint/MapObject/BuildObject/BP_BuildObject_ItemChest_04",
    blueprintName = "BP_BuildObject_ItemChest_04",
    templateSuffix = "_C:PalMapObjectItemChestParameter_GEN_VARIABLE",   -- its item-chest component's template
    chestModelClass = "PalMapObjectItemChestModel",       -- every chest in the world
    chestParameterClass = "PalMapObjectItemChestParameterComponent",   -- what sets a chest's size (SlotNum)
    mapObjectParameter = "/Script/Pal.PalHUDDispatchParameter_MapObject",
    chestWindowClass = "WBP_ItemChest_C",                 -- the chest window itself (followed when the HUD id can't)
}
-- Game functions called: GetMapObjectManager, RequestSpawnMapObjectByPlayer_Server, FindModel, GetModelInstanceId,
-- RequestLockPrivate_ServerInternal, GetLocalPlayerID, GetActor, CreateDispatchParameterForK2Node, ShowCommonUI.
local CHEST_WAIT = {
    chestAppears = UTIL.updates(6),     -- a new chest is given this long to appear before giving up
    followView = UTIL.updates(2),       -- how long to find out how to tell the chest window has closed
}
local HIDDEN_SPOT = { X = -1050000, Y = 700000, Z = -40000 }   -- cm: beyond the map's far corner, 400 m underground
local NO_ROTATION = { Pitch = 0, Yaw = 0, Roll = 0 }
local CHEST_NEAR_CM = 200            -- a chest this near the hidden spot is ours: the game may place it a little off
local SLOTS_MIN = 54                 -- ItemChest_04's own size: the mailbox's chest is never smaller
local SLOTS_DEFAULT = 300            -- without mailbox_slots in config.txt
local SLOTS_MAX = 2000               -- a sane top for mailbox_slots (each slot is swept while the window is open)
local ITEM_CHEST_WINDOW = 7          -- EPalWidgetBlueprintType ItemChest
local DAMAGE_NONE = 2                -- EPalMapObjectDamagableType NoDamage

-- State: the chest view (the chest window the mailbox opened). Forgotten: when it closes (CHEST.close()), on a new
-- world (CHEST.forget()), on a new seed (CHEST.forget()). Its fields are listed in newView(). The other parts are
-- handed it (SLOTS.absorb, SWEEP.run, HEADING.dress).
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
    local okCount, slots = pcall(function() return SLOTS.containerOf(chest):Num() end)
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

-- Opens the game's chest window on the hidden chest, emptied of copies and filled from the list.
function CHEST.open(chest, pawn)
    harden(chest, pawn)
    pcall(SWEEP.lockPermission, SLOTS.containerOf(chest))
    local held, slots, placed, inChest = SLOTS.emptyThenFillChest(chest)
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
-- the same, and the next open's SLOTS.emptyThenFillChest removes the copies left in it.
function CHEST.close()
    local ok, err = pcall(SLOTS.absorb, view)
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
        local ok, err = pcall(SWEEP.run, view, (BAG.player()))
        if not ok then
            UTIL.onceErr("mailbox sweep", err, "mailbox: sweep error: " .. tostring(err))
        end
    end
    -- The chest widget is looked for only when its answer is used: while how the view is followed is not known yet
    -- and the id does not show it, or when it is followed by the widget. Not once it can't be followed ("unknown"):
    -- any chest window shown then is the player's own, which must keep its heading.
    local byId = chestOpenById()
    local byWidget = false
    if (view.how == nil and not byId) or view.how == "widget" then
        byWidget = chestWindowShown()
    end
    -- (not while it closes: there is no heading then)
    if byId or byWidget then
        pcall(HEADING.dress, view)
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

return CHEST
