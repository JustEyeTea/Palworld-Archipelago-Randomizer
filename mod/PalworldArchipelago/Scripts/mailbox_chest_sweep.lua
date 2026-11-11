-- The mailbox's hidden chest while its window is open: every update, deposits go back to the bag, what the player
-- took comes off the list, and items received meanwhile go into the slots that empty (SWEEP.run). Also the rule that
-- refuses deposits as the window opens (SWEEP.lockPermission). Used by mailbox_chest.lua.
-- Tests: mod/test/tests/mailbox.lua; group "the mailbox" (tools/lua_harness.sh, in CI).
local SWEEP = {}
local P = require("perf")
local UTIL = require("util")
local BAG = require("bag")
local SLOTS = require("mailbox_chest_slots")

-- What mailbox.lua hands over, through mailbox_chest.lua (SWEEP.install): see mailbox_chest.lua.
local env, LIST, once

function SWEEP.install(handedOver)
    env, LIST, once = handedOver, handedOver.list, handedOver.once
end

-- State: none of its own. The chest view is mailbox_chest.lua's, handed to SWEEP.run.

-- While the chest window is open (every update): deposits go back to the bag, and items received meanwhile go in.
-- Deposits are refused first by the game's own rule for what a container accepts (FPalItemPermission: a list of item
-- types and ids; ours names one id no item has). Untested in game: whether a deposit still gets through (the log says
-- so when one does). Whatever does is found by comparing the chest with what the mailbox put in (view.inChest), and
-- goes back by the game's own move to the bag (keeps gear's data and food's freshness); if that does nothing within
-- GAME_MOVE_WAIT, plain items are taken out and given to the bag directly, and gear is left with a note.
--
-- The rule the sweep keeps, for every item id while the view is open: the list's count (M.queue) = view.inChest (put
-- in the chest by the mailbox, not taken) + view.held (did not fit yet). Each place that changes a side changes the
-- other with it: M.add adds to the list and to held (CHEST.received); SLOTS.emptyThenFillChest and fillSlotFromWaiting
-- move from held to inChest; dropTakenFromList takes from inChest and the list; returnByHand adds to both when the bag
-- is full; SLOTS.absorb rebuilds the list from the chest and held as the view closes. For example: 50 Wood shown, the
-- player takes 20; the sweep sees 30 in the chest, so inChest is 30 and the list 30.

local GUID_LIBRARY = "/Script/Engine.Default__KismetGuidLibrary"   -- a new id for each move to the bag
-- Game functions called: GetLastNotEmptyIndex, OnRep_Permission, GetNetworkTransmitter,
-- RequestMoveToContainer_ToServer, NewGuid.
local GAME_MOVE_WAIT = UTIL.updates(0.9)   -- a deposit is given this long to go back by the game's move
local NO_DEPOSITS = "AP_MailboxGivesOnly"   -- the one item id the chest accepts: no item has it
local RANDOM_MAX = 0x7FFFFFFF        -- the largest part of a made-up guid (a positive 32-bit number)

-- The container and each of its slots accept only NO_DEPOSITS, an id no item has: the game refuses deposits.
function SWEEP.lockPermission(container)
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
    local ok, guid = pcall(function() return guidOf(StaticFindObject(GUID_LIBRARY):NewGuid()) end)
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

local function tellDepositReturnedOnce(view, what)
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
    local okId, itemId = pcall(SLOTS.getItemId, slot)
    local okPlain, plain = false, false
    if okId then
        okPlain, plain = pcall(SLOTS.plainId, itemId)
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
local function dropTakenFromList(view, chest)
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
local function returnByHand(view, id, extra, slots)
    once("byhand", "mailbox: the move to the bag did nothing; deposits are returned by hand")
    local back, why = BAG.give(id, extra)
    local left = back
    for k = #slots, 1, -1 do
        if left <= 0 then break end
        local have = slots[k]:GetStackCount()
        local count = math.min(left, have)
        if count == have then
            SLOTS.clear(slots[k])
        else
            SLOTS.put(slots[k], id, have - count)
        end
        left = left - count
    end
    if back >= extra then return false end
    view.inChest[id] = (view.inChest[id] or 0) + (extra - back)
    LIST.addCount(LIST.queue, id, extra - back)
    LIST.tellStays(id, why)
    return true
end

-- One item's deposit: first the game's move, then by hand once that has waited GAME_MOVE_WAIT. Whether the list
-- changed.
local function returnDeposit(view, pawn, chest, id, extra)
    local waited = view.depositUpdates[id] or 0
    once("deposit", "mailbox: a deposit got into the chest (" .. extra .. " " .. id .. "): returning it")
    if waited == 0 then
        askGameToMove(pawn, chest.plainSlots[id], extra)
        tellDepositReturnedOnce(view, BAG.nameOf(id))
    end
    view.depositUpdates[id] = waited + 1
    if waited + 1 <= GAME_MOVE_WAIT then return false end
    local changed = returnByHand(view, id, extra, chest.plainSlots[id])
    view.depositUpdates[id] = nil
    return changed
end

-- Plain items the player put in (more than the mailbox put in) go back to the bag. Whether the list changed, and the
-- set of item ids whose slots were acted on.
local function returnDeposits(view, pawn, chest)
    local changed, handled = false, {}
    for id, count in pairs(chest.plainCount) do
        local extra = count - (view.inChest[id] or 0)
        if extra > 0 then
            handled[id] = true
            changed = returnDeposit(view, pawn, chest, id, extra) or changed
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

-- Gear can only go back by the game's move: asked once; if it is still there after GAME_MOVE_WAIT, the player is
-- asked to take it out.
local function returnGear(view, pawn, gear)
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
            tellDepositReturnedOnce(view, "your " .. gearName(piece))
        elseif waited == GAME_MOVE_WAIT then
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

local function fillSlotFromWaiting(view, slot)
    if not (slot and slot:IsValid() and slot:IsEmpty()) then return end
    SLOTS.putFirstWaiting(slot, view.held, view.inChest)
end

-- Items received while the chest is open go into its empty slots.
local function refillFromWaiting(view, container, chest, handled)
    if #view.held == 0 then return end
    local seen = {}
    for _, index in ipairs(slotsThatMayBeEmpty(container, chest, handled)) do
        if #view.held == 0 then break end
        if not seen[index] then
            seen[index] = true
            P.count("refill")
            fillSlotFromWaiting(view, container:Get(index))
        end
    end
end

-- Keeps the view's chest and the list in step while it is open (see the rule above).
function SWEEP.run(view, pawn)
    local container = SLOTS.containerOf(view.chest)
    local chest = readChest(container)
    local taken = dropTakenFromList(view, chest)
    local returned, handled = returnDeposits(view, pawn, chest)
    returnGear(view, pawn, chest.gear)
    refillFromWaiting(view, container, chest, handled)
    if taken or returned then
        env.save()
    end
end

return SWEEP
