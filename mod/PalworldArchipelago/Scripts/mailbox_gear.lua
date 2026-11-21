-- The mailbox's gear (crate and Nomad gear, M.gear) once it is handed out: where each piece went. The game makes it
-- in the bag by its own AddItem, which gives it its per-item data, and may put it straight into an empty equipment
-- slot instead, but only after AddItem returns (in game, right after the call neither the bag nor the slot held it).
-- So where it went is read SETTLE_WAIT later: worn (the player is told "now equipped"), or in the bag, from where a
-- piece is moved on into the mailbox's chest window when that is open (mailbox_chest_gear.lua), so the player sees it
-- there. Wired by mailbox.lua.
-- Tests: mod/test/tests/crates_run_style.lua; groups "crate and Nomad gear waits in the mailbox, out of its hidden
--   chest" and "crate gear shows in the mailbox's chest" (tools/lua_harness.sh, in CI).
local GEAR = {}
local UTIL = require("util")
local BAG = require("bag")
local CHEST = require("mailbox_chest")
local SLOTS = require("mailbox_chest_slots")
local log = UTIL.log

local SETTLE_WAIT = UTIL.updates(0.5)   -- given gear is read this long after AddItem: the game places it in between

-- What mailbox.lua hands over (GEAR.install): notify(text).
local env

function GEAR.install(handedOver)
    env = handedOver
end

-- State: the gear given and not yet settled. Forgotten: on a new world or a new seed (GEAR.forget()).
-- { id, n = how many were given, before = BAG.held before, bagBefore = the bag's pieces of it before (piece key ->
--   true; nil when the bag could not be read), updates = updates since }
local landing = {}

-- The pieces of one gear item in the bag now: piece key -> its bag slot.
local function piecesInBag(id)
    local pieces = {}
    local container = BAG.bagContainer()
    for index = 0, SLOTS.lastUsedIndex(container) do
        local slot = container:Get(index)
        if slot and slot:IsValid() and not slot:IsEmpty() and slot:GetItemId().StaticId:ToString() == id then
            local key = SLOTS.pieceKey(slot:GetItemId())
            if key then
                pieces[key] = slot
            end
        end
    end
    return pieces
end

-- What the player holds of a gear item before it is given (handed back to GEAR.given).
function GEAR.noteBefore(id)
    local ok, pieces = pcall(piecesInBag, id)
    local bagBefore = nil
    if ok then
        bagBefore = {}
        for key in pairs(pieces) do
            bagBefore[key] = true
        end
    end
    return { id = id, before = BAG.held(id), bagBefore = bagBefore }
end

-- `n` of the gear noted were given: where they went is read SETTLE_WAIT from now.
function GEAR.given(noted, n)
    noted.n, noted.updates = n, 0
    landing[#landing + 1] = noted
end

-- The bag's pieces of a given item that were not there before it was given.
local function newPieces(given)
    if not given.bagBefore then return {} end
    local ok, pieces = pcall(piecesInBag, given.id)
    if not ok then return {} end
    local new = {}
    for key, slot in pairs(pieces) do
        if not given.bagBefore[key] then
            new[#new + 1] = slot
        end
    end
    return new
end

-- How many of a given item the game put in an equipment slot (the slots wear more of it than before). Logged once a
-- session when the bag and the slots together gained fewer than were given: the game said it took them, but they are
-- in neither (what bag.lua checks for plain items right after the call).
local function wornSince(given)
    local now = BAG.held(given.id)
    if not (now and given.before) then return 0 end
    local worn = math.max(0, now.worn - given.before.worn)
    local bag = math.max(0, now.bag - given.before.bag)
    if worn + bag < given.n then
        UTIL.once("gearnowhere", "mailbox: " .. given.n .. " " .. given.id .. " given, but the bag and equipment slots "
            .. "gained " .. (worn + bag))
    end
    return math.min(given.n, worn)
end

-- Where one given item went: its names added to `where.equipped`, `where.inBag`, or counted in `where.moving` (on
-- into the chest window, which tells the player itself when it arrives).
local function place(given, where)
    local name = BAG.nameOf(given.id)
    local worn = wornSince(given)
    for _ = 1, worn do
        where.equipped[#where.equipped + 1] = name
    end
    local left = given.n - worn
    for _, slot in ipairs(newPieces(given)) do
        if left > 0 and CHEST.showGear(slot, given.id) then
            left, where.moving = left - 1, where.moving + 1
        end
    end
    for _ = 1, left do
        where.inBag[#where.inBag + 1] = name
    end
end

-- What the player is told of the gear placed: the names in the bag, and those the game put in an equipment slot.
local function gearPlacedLine(where)
    local parts = {}
    if #where.inBag > 0 then
        parts[#parts + 1] = "now in your bag: " .. table.concat(where.inBag, ", ")
    end
    if #where.equipped > 0 then
        parts[#parts + 1] = "now equipped: " .. table.concat(where.equipped, ", ")
    end
    return "From your mailbox, " .. table.concat(parts, "; ") .. "."
end

-- Every update: the gear given SETTLE_WAIT ago is placed (an equipment slot, the bag, or on into the chest window),
-- and the player told where.
function GEAR.settle()
    if #landing == 0 then return end
    local still, where = {}, { equipped = {}, inBag = {}, moving = 0 }
    for _, given in ipairs(landing) do
        given.updates = given.updates + 1
        if given.updates < SETTLE_WAIT then
            still[#still + 1] = given
        else
            place(given, where)
        end
    end
    landing = still
    if #where.equipped + #where.inBag + where.moving == 0 then return end
    log("mailbox: gear placed: in the bag " .. table.concat(where.inBag, ", ") .. "; equipped "
        .. table.concat(where.equipped, ", ") .. "; " .. where.moving .. " moving into the chest")
    if #where.equipped + #where.inBag > 0 then
        env.notify(gearPlacedLine(where))
    end
end

-- Forgets the gear not yet placed (a new world or a new seed: it was given in the old one).
function GEAR.forget()
    landing = {}
end

return GEAR
