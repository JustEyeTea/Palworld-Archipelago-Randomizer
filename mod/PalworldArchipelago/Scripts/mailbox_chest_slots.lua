-- The mailbox's hidden chest, its slots: emptied of copies and filled from the list as its window opens
-- (SLOTS.emptyThenFillChest), and emptied back into the list as it closes (SLOTS.absorb). Used by mailbox_chest.lua
-- and mailbox_chest_sweep.lua.
-- The list (the mod's save file) is the truth, and a take leaves it at once, while the item in the bag is kept only by
-- the game's next world save: an item taken just before a crash is in neither save. That loss is chosen over the
-- other order, which would give it twice.
-- Tests: mod/test/tests/mailbox.lua; group "the mailbox" (tools/lua_harness.sh, in CI).
local SLOTS = {}
local UTIL = require("util")
local BAG = require("bag")
local log = UTIL.log

-- What mailbox.lua hands over, through mailbox_chest.lua (SLOTS.install): the list (see mailbox_chest.lua).
local LIST

function SLOTS.install(handedOver)
    LIST = handedOver.list
end

-- State: none of its own. The chest view is mailbox_chest.lua's, handed to SLOTS.absorb.

-- Game functions called on the chest's slots: GetItemContainerModule, GetContainer, OnRep_ItemId, OnRep_StackCount.

-- A chest's item container: its slots.
function SLOTS.containerOf(chest)
    return chest:GetItemContainerModule():GetContainer()
end

-- Whether an item id has no per-item data (gear, eggs and the like have it).
function SLOTS.plainId(itemId)
    local perItem = itemId.DynamicId.LocalIdInCreatedWorld
    return perItem.A == 0 and perItem.B == 0 and perItem.C == 0 and perItem.D == 0
end

function SLOTS.getItemId(slot)
    return slot:GetItemId()
end

local function isPlain(slot)
    local ok, itemId = pcall(SLOTS.getItemId, slot)
    if not ok then return false end
    local okPlain, plain = pcall(SLOTS.plainId, itemId)
    return okPlain and plain
end

-- Puts `count` of an item in a slot. When its item id can't be changed in place, the whole id is replaced.
function SLOTS.put(slot, id, count)
    if not pcall(function() slot.ItemId.StaticId = FName(id) end) then
        UTIL.took("mailbox: a slot's item id", "set whole (its StaticId could not be set alone)")
        slot.ItemId = { StaticId = FName(id), DynamicId = slot.ItemId.DynamicId }
    end
    slot.StackCount = count
    pcall(function() slot:OnRep_ItemId() end)
    pcall(function() slot:OnRep_StackCount() end)
end

-- Empties a slot; whether it is empty now.
function SLOTS.clear(slot)
    pcall(function() SLOTS.put(slot, "None", 0) end)
    local ok, empty = pcall(function() return slot:IsEmpty() end)
    return ok and empty
end

-- Puts the first entry still waiting into an empty slot, as much as one stack holds, and counts it as in the chest.
function SLOTS.putFirstWaiting(slot, waiting, inChest)
    local entry = waiting[1]
    local count = math.min(entry.n, BAG.maxStack(entry.id))
    SLOTS.put(slot, entry.id, count)
    inChest[entry.id] = (inChest[entry.id] or 0) + count
    entry.n = entry.n - count
    if entry.n <= 0 then
        table.remove(waiting, 1)
    end
end

-- Empties the chest of plain items, then fills it from the list. Plain items in this chest are only ever copies of the
-- list (a view that never closed, or a world save older than the mod's save after a crash): the list is the truth.
-- Returns the list entries that did not fit, the chest's slot count, the slots filled, and item id -> count put in.
function SLOTS.emptyThenFillChest(chest)
    local container = SLOTS.containerOf(chest)
    local waiting, inChest = {}, {}
    for _, entry in ipairs(LIST.queue) do
        waiting[#waiting + 1] = { id = entry.id, n = entry.n }
    end
    local slots, placed = container:Num(), 0
    for index = 0, slots - 1 do
        local slot = container:Get(index)
        if slot and slot:IsValid() then
            if not slot:IsEmpty() and isPlain(slot) then
                SLOTS.clear(slot)
            end
            if #waiting > 0 and slot:IsEmpty() then
                SLOTS.putFirstWaiting(slot, waiting, inChest)
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
local function listAfterClosing(view, stacks)
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

-- The view's chest's plain items back into the list, and the chest emptied. The list is set before any slot is
-- cleared: a slot left uncleared is a copy, which the next SLOTS.emptyThenFillChest removes.
function SLOTS.absorb(view)
    assert(view.chest:IsValid(), "the chest is gone")
    local stacks, plainSlots = plainStacksIn(SLOTS.containerOf(view.chest))
    local list, extra = listAfterClosing(view, stacks)
    LIST.queue = list
    for _, slot in ipairs(plainSlots) do
        SLOTS.clear(slot)
    end
    for _, entry in ipairs(extra) do
        returnLastMomentDeposit(entry)
    end
end

return SLOTS
