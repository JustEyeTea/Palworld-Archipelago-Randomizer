-- Items the server sends: what each does on arrival (ITEMS.onItem, on every connection) and its once-per-seed effect
-- (ITEMS.applyItems: points, crates, bundles, a Nomad gift, traps, relics), and opening a Palworld Crate.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "connect and receive", "reconnect does not repeat
-- one-off items", "mailbox off: bundles straight to the bag" and "run style and speed boost: Nomad's hand-overs, and
-- world settings changed only when asked, with a warning".
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
local ap, slotNumber = STATE.ap, STATE.slotNumber
local log, once, onceErr, safe = UTIL.log, UTIL.once, UTIL.onceErr, UTIL.safe
local notify, playerState, writeSave = PLAYER.notify, PLAYER.playerState, SAVE.write

-- A Palworld Crate received: its kind is rolled from the seed's crate weights and the item's index (crates.lua).
local function receiveCrate(index)
    local weights = {}
    for _, k in ipairs(CRATES.KINDS) do weights[k] = slotNumber("options." .. CRATES.WEIGHT_KEYS[k]) end
    local kind = CRATES.receive(ap.seed, index, weights)
    notify("Palworld Crate: it's a " .. CRATES.NAMES[kind] .. "! Open it from the Inventory page when you like.")
end

-- A bundle's items, into the mailbox, or with the mailbox off straight into the bag. False when the bag refused one
-- (it is tried again later).
local function giveBundle(it)
    for _, bundle in ipairs(RECORDS.BUNDLES[it.name]) do
        if MAIL.on() then
            MAIL.add(bundle.id, bundle.n)
        else
            -- Counted and logged as the mailbox does (what a full bag answers is untested). A bundle is one stack.
            local okg, got = pcall(BAG.give, bundle.id, bundle.n)
            if not okg then
                onceErr("give", got, "could not give " .. bundle.id .. ": " .. tostring(got))
                return false
            end
            if got == 0 then return false end
            if got < bundle.n then log("bundle " .. it.name .. ": only " .. got .. " of " .. bundle.n .. " " .. bundle.id .. " went in") end
        end
    end
    return true
end

-- A filler item's once-per-seed effect: a Palworld Crate, tech points or a bundle. False when it could not be applied
-- yet (a bundle the bag refused, with the mailbox off): it is tried again later.
local function giveFiller(ps, id, index)
    local it = DATA.items[id]
    if not it then return true end
    if it.name == "Palworld Crate" then
        receiveCrate(index)
        return true
    end
    local td = ps:GetTechnologyData()
    if it.name == "Tech Points +2" then
        td.TechnologyPoint = td.TechnologyPoint + 2
        safe(function() td:OnRep_TechnologyPoint() end)
    elseif it.name == "Ancient Tech Points +1" then
        td[RECORDS.ANCIENT_POINTS] = td[RECORDS.ANCIENT_POINTS] + 1
        safe(function() td[RECORDS.ANCIENT_ONREP](td) end)
    elseif RECORDS.BUNDLES[it.name] then
        return giveBundle(it)
    end
    return true
end

-- Relics received so far (the Relic Hunt goal), up to item index `upto` (all by default; items are numbered from 0).
function ITEMS.relicCount(upto)
    local n = 0
    for i, id in pairs(ap.items) do
        local it = DATA.items[id]
        if it and it.kind == "relic" and (not upto or i <= upto) then n = n + 1 end
    end
    return n
end

-- State: the items. Forgotten: never. A new seed starts its items from index 0 again, so an index kept from the last
-- seed only means its first "bag is full" notice for that same index is not shown; the item still waits.
local waiting = nil           -- the index of a bundle the bag had no room for (mailbox off): given once there is room

-- Gear and accessories from a crate go straight to the bag (the mailbox chest can't hold per-item data); what the
-- bag refused is tried again here, every applying update.
local function givePending()
    CRATES.retryBag(function(id, n)
        local okg, got = pcall(BAG.give, id, n)
        got = okg and got or 0
        if got > 0 then
            notify("Your bag had room: " .. BAG.nameOf(id) .. " from a crate is in it now.")
        end
        return got
    end)
end

-- Opening a crate (the Inventory page's Open button: the next one; the crate window's: one of `kind`), its contents
-- rolled from the player's level now. Returns the kind and the contents.
function ITEMS.openCrate(kind)
    local ps = playerState()
    if not (ps and ps:IsValid()) then notify("Open crates in your world."); return end
    local lv = RECORDS.level(ps) or ap.level or 1
    local out
    kind, out = CRATES.openNext(lv, kind)
    if not kind then return end
    local parts = {}
    for _, row in ipairs(out) do
        local name = BAG.nameOf(row.id)
        if row.bag or not MAIL.on() then
            local okg, got = pcall(BAG.give, row.id, row.n)
            got = okg and got or 0
            if got < row.n then CRATES.holdForBag(row.id, row.n - got) end
            parts[#parts + 1] = (row.n > 1 and (row.n .. " x ") or "") .. name .. (got < row.n and " (waits for room in your bag)" or " (in your bag)")
        else
            MAIL.add(row.id, row.n)
            parts[#parts + 1] = row.n .. " x " .. name
        end
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
    for _, g in ipairs(gifts) do
        local id, n, name = g.id, g.n, BAG.nameOf(g.id)
        if g.bag or not MAIL.on() then
            local okg, got = pcall(BAG.give, id, n)
            got = okg and got or 0
            if got < n then CRATES.holdForBag(id, n - got) end
            parts[#parts + 1] = (n > 1 and (n .. " x ") or "") .. name .. (got < n and " (waits for room in your bag)" or " (in your bag)")
        else
            MAIL.add(id, n)
            parts[#parts + 1] = n .. " x " .. name .. " (in the mailbox)"
        end
    end
    log("nomad: " .. it.name .. " brought " .. table.concat(parts, ", "))
    notify(it.name .. " brought " .. table.concat(parts, ", ") .. ".")
end

-- What each kind of item does, and where. An item's kind is DATA.items[id].kind.
--   kind          on arrival, on every connection (ITEMS.onItem)     once per seed, in index order (ITEMS.applyItems)
--   tech          unlocks its tech (ap.techs)                        Nomad only: hands over what it makes (giveTechGift)
--   progressive   unlocks the techs of every sphere tier received    -
--   pass          opens its area or region (ap.passes)               -
--   trap          keeps who sent it (ap.from)                        queued for traps.lua to fire (TRAPS.add)
--   relic         -                                                  the "Palpagos Relic n/m found!" notice
--   filler        -                                                  its effect (giveFiller): a crate, points, a bundle
-- Every kind but a trap also says "Received ..." in chat when it is new (its index is past ap.given).
-- Applies each received item's once-per-seed effect, in index order from ap.given + 1, after retrying what the bag
-- refused; it stops at a bundle the bag has no room for.
function ITEMS.applyItems(ps)
    givePending()
    local i = ap.given + 1
    while ap.items[i] do
        local id = ap.items[i]
        local it = DATA.items[id]
        if it and it.kind == "filler" and not giveFiller(ps, id, i) then
            if waiting ~= i then
                waiting = i
                notify("Your bag is full: " .. it.name .. " waits until there is room.")
            end
            break
        end
        if waiting == i then waiting = nil; log("bundle " .. it.name .. " given, now the bag has room") end
        if it and it.kind == "tech" then giveTechGift(it) end
        if it and it.kind == "trap" then TRAPS.add(it.name, i) end      -- queued: traps.lua paces and fires them
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
        for _, v in pairs(ap.items) do if v == id then n = n + 1 end end
        for k = 1, math.min(n, #DATA.spheres) do ap.techs[DATA.spheres[k]] = true end
    elseif it.kind == "pass" then
        ap.passes[it.area] = true
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
