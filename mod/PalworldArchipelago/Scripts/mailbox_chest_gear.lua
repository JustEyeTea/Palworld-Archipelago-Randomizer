-- The mailbox's hidden chest, its gear: a piece of gear the mailbox handed to the bag is moved on into an empty slot
-- of the chest by the game's own move (which keeps the piece's per-item data, as no slot write by the mod could), so
-- the player sees it in the mailbox and takes it out; the pieces the player leaves there go back to the bag as the
-- window closes. The sweep leaves the mailbox's own pieces alone (view.gearMine). Used by mailbox_chest.lua.
-- Untested in game: whether the game's move puts a piece from the bag into the chest at all (if it does nothing within
-- MOVE_IN_WAIT, the piece stays in the bag and the player is told so).
-- Tests: mod/test/tests/crates_run_style.lua; group "crate gear shows in the mailbox's chest" (tools/lua_harness.sh,
--   in CI).
local CGEAR = {}
local UTIL = require("util")
local BAG = require("bag")
local SLOTS = require("mailbox_chest_slots")
local SWEEP = require("mailbox_chest_sweep")
local log = UTIL.log

local MOVE_IN_WAIT = SWEEP.GAME_MOVE_WAIT   -- a piece is given this long to arrive by the game's move
-- What the player is told whenever gear arrives: what is left in the mailbox does not stay there.
local LEFT_GEAR_WARNING = "Gear you leave in the mailbox goes to your bag when you close it."

-- What mailbox_chest.lua hands over (CGEAR.install): see mailbox_chest.lua.
local env, once

function CGEAR.install(handedOver)
    env, once = handedOver, handedOver.once
end

-- State: none of its own. The chest view is mailbox_chest.lua's: its gearMoving (the moves asked for, followed until
-- the piece arrives) and gearMine (piece key -> "moving" or "shown": the pieces that are the mailbox's own).

-- The first empty slot of the chest no move is headed for yet, or nil when the chest is full.
local function freeSlot(view, container)
    local headedFor = {}
    for _, move in ipairs(view.gearMoving) do
        headedFor[move.slot] = true
    end
    for index = 0, container:Num() - 1 do
        local slot = container:Get(index)
        if slot and slot:IsValid() and slot:IsEmpty() and not headedFor[slot] then return slot end
    end
    return nil
end

-- The item ids the chest's container lets in now: those of the moves still under way.
local function idsMovingIn(view)
    local ids, seen = {}, {}
    for _, move in ipairs(view.gearMoving) do
        if not seen[move.id] then
            seen[move.id] = true
            ids[#ids + 1] = move.id
        end
    end
    return ids
end

-- Asks the game to move a piece of gear (item `id`, in the bag's slot `bagSlot`) into an empty slot of the chest; the
-- container and that slot let the item in until the move is settled (CGEAR.follow). Whether the move was asked.
function CGEAR.moveIn(view, pawn, bagSlot, id)
    local container = SLOTS.containerOf(view.chest)
    local target = freeSlot(view, container)
    if not target then
        once("gearfull", "mailbox: no empty slot for gear in the chest; it stays in the bag")
        return false
    end
    local key = SLOTS.pieceKey(bagSlot:GetItemId())
    view.gearMoving[#view.gearMoving + 1] = { id = id, key = key, slot = target, updates = 0 }
    view.gearMine[key] = "moving"
    SWEEP.accept(container, idsMovingIn(view))
    SWEEP.accept(target, { id })
    SWEEP.moveToSlot(pawn, bagSlot, target)
    log("mailbox: gear moving from the bag into the chest: " .. id .. " (" .. key .. ")")
    return true
end

-- Whether a move's piece is in its slot now.
local function arrived(move)
    if move.slot:IsEmpty() then return false end
    local ok, key = pcall(function() return SLOTS.pieceKey(move.slot:GetItemId()) end)
    return ok and key == move.key
end

-- A move settled: its slot refuses deposits again, and the piece is the mailbox's (it arrived) or the bag's (it did
-- not). The name goes on the list the player is told.
local function settleMove(view, move, came, shown, stayed)
    SWEEP.accept(move.slot, {})
    local names = came and shown or stayed
    names[#names + 1] = BAG.nameOf(move.id)
    if came then
        view.gearMine[move.key] = "shown"
        return
    end
    view.gearMine[move.key] = nil
    log("mailbox: the move of " .. move.id .. " into the chest did nothing within " .. MOVE_IN_WAIT
        .. " updates; it stays in the bag")
end

-- Every update while the view is open, before the sweep: the moves asked for, settled once the piece is in its slot
-- or MOVE_IN_WAIT has passed, and the player told where each piece is.
function CGEAR.follow(view)
    if #view.gearMoving == 0 then return end
    local underWay, shown, stayed = {}, {}, {}
    for _, move in ipairs(view.gearMoving) do
        move.updates = move.updates + 1
        local came = arrived(move)
        if came or move.updates > MOVE_IN_WAIT then
            settleMove(view, move, came, shown, stayed)
        else
            underWay[#underWay + 1] = move
        end
    end
    view.gearMoving = underWay
    SWEEP.accept(SLOTS.containerOf(view.chest), idsMovingIn(view))
    if #shown > 0 then
        env.notify("In your mailbox: " .. table.concat(shown, ", ") .. ". " .. LEFT_GEAR_WARNING)
    end
    if #stayed > 0 then
        env.notify("From your mailbox, now in your bag: " .. table.concat(stayed, ", ") .. ".")
    end
end

-- Whether a chest slot holds one of the mailbox's own pieces of gear.
local function holdsMailboxPiece(view, slot)
    if not (slot and slot:IsValid()) or slot:IsEmpty() then return false end
    local ok, key = pcall(function() return SLOTS.pieceKey(slot:GetItemId()) end)
    return ok and key ~= nil and view.gearMine[key] ~= nil
end

-- As the window closes: the mailbox's pieces the player left in the chest are moved to the bag by the game's move.
-- A piece the move does not take stays in the chest, where the next open's sweep returns it like any deposit.
function CGEAR.sendLeftToBag(view, pawn)
    local container = SLOTS.containerOf(view.chest)
    local sent = {}
    for index = 0, SLOTS.lastUsedIndex(container) do
        local slot = container:Get(index)
        if holdsMailboxPiece(view, slot) then
            local name = BAG.nameOf(slot:GetItemId().StaticId:ToString())
            local moved, err = pcall(SWEEP.moveToBag, pawn, slot, slot:GetStackCount())
            if moved then
                sent[#sent + 1] = name
            else
                log("mailbox: could not send left gear to the bag: " .. tostring(err))
            end
        end
    end
    if #sent == 0 then return end
    log("mailbox: gear left in the chest sent to the bag: " .. table.concat(sent, ", "))
    env.notify("Gear you left in the mailbox went to your bag: " .. table.concat(sent, ", ") .. ".")
end

return CGEAR
