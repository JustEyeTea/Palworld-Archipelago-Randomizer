-- Items the server sends: what each does on arrival (ITEMS.onItem, on every connection) and its once-per-seed effect
-- (ITEMS.applyItems: points, crates, bundles, a Nomad gift, traps, relics), and opening a Palworld Crate.
-- Tests: mod/test/tests/core.lua, mod/test/tests/core_loop.lua,
--   mod/test/tests/crates_run_style.lua; groups "connect and receive", "reconnect does not repeat one-off items",
--   "run style and speed boost: Nomad's hand-overs, and world settings changed only when asked, with a warning"
--   (tools/lua_harness.sh, in CI).
local ITEMS = {}
local BAG = require("bag")
local CRATES = require("crates")
local DATA = require("ap_data")
local MAIL = require("mailbox")
local PLAYER = require("player")
local RECORDS = require("records")
local SAVE = require("save")
local STATE = require("ap_state")
local SYNC = require("sync")
local TECH_LOCK = require("tech_lock")
local TRAPS = require("traps")
local UTIL = require("util")
local WORLD = require("world")
local ap, slotNumber = STATE.ap, STATE.slotNumber
local log, once, onceErr, safe = UTIL.log, UTIL.once, UTIL.onceErr, UTIL.safe
local notify, playerState, writeSave = PLAYER.notify, PLAYER.playerState, SAVE.write

-- Puts up to n of item `id` in the bag and returns how many went in (what a full bag answers is untested in game).
-- An error is logged once, with the item's id, and counts as none in.
local function giveToBag(id, n)
    local okg, got = pcall(BAG.give, id, n)
    if okg then return got end
    onceErr("give", got, "could not give " .. id .. ": " .. tostring(got))
    return 0
end

-- Hands n of item `id` over: into the bag when `toBag` (what does not fit waits for room, CRATES.holdForBag), else into
-- the mailbox. Returns its part of the chat line, such as "2 x Wood (in your bag)".
local function handOver(id, n, toBag)
    local name = BAG.nameOf(id)
    if not toBag then
        MAIL.add(id, n)
        return n .. " x " .. name .. " (in the mailbox)"
    end
    local got = giveToBag(id, n)
    if got < n then
        CRATES.holdForBag(id, n - got)
    end
    local count = n > 1 and (n .. " x ") or ""
    return count .. name .. (got < n and " (waits for room in your bag)" or " (in your bag)")
end

-- A Palworld Crate received: its kind is rolled from the seed's crate weights and the item's index (crates.lua).
local function receiveCrate(index)
    local weights = {}
    for _, k in ipairs(CRATES.KINDS) do
        weights[k] = slotNumber("options." .. CRATES.WEIGHT_KEYS[k])
    end
    local kind = CRATES.receive(ap.seed, index, weights)
    notify("Palworld Crate: it's a " .. CRATES.NAMES[kind] .. "! Open it from the Inventory page when you like.")
end

-- Each filler bundle's items: { { id = item id (a DT_ItemDataTable row), n = count } }, by the item's name.
local BUNDLES = {
    ["Wood Bundle"] = { { id = "Wood", n = 50 } },
    ["Stone Bundle"] = { { id = "Stone", n = 50 } },
    ["Paldium Bundle"] = { { id = "Pal_crystal_S", n = 20 } },
    ["Ingot Bundle"] = { { id = "CopperIngot", n = 10 } },
    ["Sphere Bundle"] = { { id = "PalSphere", n = 5 } },
    ["Food Bundle"] = { { id = "Baked_Berries", n = 10 } },
}

-- A bundle's items, into the mailbox.
local function giveBundle(_, it)
    for _, bundle in ipairs(BUNDLES[it.name]) do
        MAIL.add(bundle.id, bundle.n)
    end
end

-- Two tech points (the "Tech Points +2" item's TechnologyPoint).
local function addTechPoints(ps)
    local td = ps:GetTechnologyData()
    td.TechnologyPoint = td.TechnologyPoint + 2
    safe(function() td:OnRep_TechnologyPoint() end)
end

-- One ancient tech point (the "Ancient Tech Points +1" item).
local function addAncientPoint(ps)
    local td = ps:GetTechnologyData()
    td[TECH_LOCK.ANCIENT_POINTS] = td[TECH_LOCK.ANCIENT_POINTS] + 1
    safe(function() td[TECH_LOCK.ANCIENT_ONREP](td) end)
end

-- Each filler item's once-per-seed effect, by the item's name as apworld/palworld/data.py gives it (the generated
-- ap_data.lua carries it); a bundle's effect is giveBundle, for every name in BUNDLES. Each takes
-- (ps, it, index).
local FILLER_EFFECTS = {
    ["Palworld Crate"] = function(_, _, index)
        receiveCrate(index)
    end,
    ["Tech Points +2"] = addTechPoints,
    ["Ancient Tech Points +1"] = addAncientPoint,
}

-- A filler item's once-per-seed effect: a Palworld Crate, tech points or a bundle. A name with no effect is logged and
-- counted as given, so the items after it still come.
local function giveFiller(ps, id, index)
    local it = DATA.items[id]
    if not it then return end
    local effect = FILLER_EFFECTS[it.name] or (BUNDLES[it.name] and giveBundle)
    if not effect then
        once("filler " .. it.name, "item " .. it.name .. ": no effect known to this version of the mod, nothing given")
        return
    end
    effect(ps, it, index)
end

-- Relics received so far (the Relic Hunt goal), up to item index `upto` (all by default; items are numbered from 0).
function ITEMS.relicCount(upto)
    local n = 0
    for i, id in pairs(ap.items) do
        local it = DATA.items[id]
        if it and it.kind == "relic" and (not upto or i <= upto) then
            n = n + 1
        end
    end
    return n
end

-- Gear and accessories from a crate go straight to the bag (the mailbox chest can't hold per-item data); what the
-- bag refused is tried again here, every applying update.
local function givePending()
    CRATES.retryBag(function(id, n)
        local got = giveToBag(id, n)
        if got > 0 then
            notify("Your bag had room: " .. BAG.nameOf(id) .. " from a crate is in it now.")
        end
        return got
    end)
end

-- Opening a crate (the Inventory page's Open button: the next one; the crate window's: one of `kind`), its contents
-- rolled from the player's level now. Returns the kind and the contents. In a world that is not the seed's nothing
-- opens: the crate's contents would leave the seed for that world's bag.
function ITEMS.openCrate(kind)
    if WORLD.seedWorld() == false then
        notify("Your crates open only in the world this seed is played in.")
        return
    end
    local ps = playerState()
    if not (ps and ps:IsValid()) then
        notify("Open crates in your world.")
        return
    end
    local lv = RECORDS.level(ps) or ap.level or 1
    local out
    kind, out = CRATES.openNext(lv, kind)
    if not kind then return end
    local parts = {}
    for _, row in ipairs(out) do
        parts[#parts + 1] = handOver(row.id, row.n, row.bag)
    end
    log("crate: opened a " .. CRATES.NAMES[kind] .. " at level " .. lv .. ": " .. table.concat(parts, ", ")
        .. "; " .. CRATES.count() .. " left")
    notify("Opened a " .. CRATES.NAMES[kind] .. ": " .. table.concat(parts, ", ") .. ".")
    writeSave()
    return kind, out
end

-- Run Style "Nomad": a received tech also hands over what it makes (sync.lua). Gear goes to the bag, like a
-- crate's (what the bag refuses waits with the crates' and is tried again); a stack goes to the mailbox. The recipe
-- unlocks as in every style, so a hand-over that fails still leaves the tech.
local function giveTechGift(it)
    local gifts = SYNC.gifts(AP_SlotData, it.tech)
    if not gifts then return end
    local parts = {}
    for _, gift in ipairs(gifts) do
        parts[#parts + 1] = handOver(gift.id, gift.n, gift.bag)
    end
    log("nomad: " .. it.name .. " brought " .. table.concat(parts, ", "))
    notify(it.name .. " brought " .. table.concat(parts, ", ") .. ".")
end

-- What each kind of item does, and where. An item's kind is DATA.items[id].kind.
--   kind         on arrival, on every connection (ITEMS.onItem)   once per seed, in index order (ITEMS.applyItems)
--   tech         unlocks its tech (ap.techs)                      Nomad only: hands over what it makes (giveTechGift)
--   progressive  unlocks the techs of every sphere tier received  -
--   pass         opens its lock (ap.passes)                       -
--   trap         keeps who sent it (ap.from)                      queued for traps.lua to fire (TRAPS.add)
--   relic        -                                                the "Palpagos Relic n/m found!" notice
--   filler       -                                                its effect (giveFiller): a crate, points, a bundle
-- Every kind but a trap also says "Received ..." in chat when it is new (its index is past ap.given).
-- Applies each received item's once-per-seed effect, in index order from ap.given + 1, after retrying the gear the bag
-- refused (from crates and Nomad gifts).
function ITEMS.applyItems(ps)
    givePending()
    local i = ap.given + 1
    while ap.items[i] do
        local id = ap.items[i]
        local it = DATA.items[id]
        if it and it.kind == "filler" then
            giveFiller(ps, id, i)
        end
        if it and it.kind == "tech" then
            giveTechGift(it)
        end
        if it and it.kind == "trap" then    -- queued: traps.lua paces and fires them
            TRAPS.add(it.name, i)
        end
        if it and it.kind == "relic" then
            local need = slotNumber("relics_needed")
            notify("Palpagos Relic " .. ITEMS.relicCount(i) .. (need and ("/" .. need) or "") .. " found!")
        end
        ap.given = i
        i = i + 1
    end
    writeSave()
end

-- item <index> <item id> <location id> <player slot> <flags> <item name> <player name>
function ITEMS.onItem(indexText, itemText, _locationText, playerText, _flagsText, name, from)
    local index, id, player = tonumber(indexText), tonumber(itemText), tonumber(playerText)
    if ap.items[index] == id then return end
    ap.items[index] = id
    TECH_LOCK.techsChanged()
    local it = DATA.items[id]
    if not it then
        log("unknown item " .. id .. " (" .. tostring(name) .. ")")
        return
    end
    if it.kind == "tech" then
        ap.techs[it.tech] = true
    elseif it.kind == "progressive" then
        local n = 0
        for _, v in pairs(ap.items) do
            if v == id then
                n = n + 1
            end
        end
        for k = 1, math.min(n, #DATA.spheres) do
            ap.techs[DATA.spheres[k]] = true
        end
    elseif it.kind == "pass" then
        ap.passes[it.lock] = true
    elseif it.kind == "trap" then
        -- No "Received" line: the trap names itself when it fires (and a Fool Trap must not give itself away).
        ap.from[index] = player ~= ap.me and from or nil
        return
    end
    if index > ap.given then
        notify("Received " .. name .. (player ~= ap.me and (" from " .. from) or ""))
    end
end

return ITEMS
