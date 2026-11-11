-- PalworldArchipelago: the Lua core of the mod. The Archipelago connection comes from the APConnector C++ mod, which
-- registers AP_* functions here when this mod starts (see cppmod/APConnector/src/dllmain.cpp).
--  * Technology levels 2+ are a shop: each card shows what its slot holds in the multiworld, researching it spends the
--    points and sends the check, and never unlocks the tech itself. Techs unlock as their items arrive.
--  * Received items: techs, Progressive Spheres, Region and Area Passes, points, bundles (into the mailbox, mailbox.lua), and traps
--    (traps.lua).
--  * Checks: shop slots, levels, captures, alphas, fast-travel points and towers, read from the game's own records.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
local VERSION = "0.14.1-dev.8"

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
package.path = modDir .. "\\Scripts\\?.lua;" .. package.path
local UTIL = require("util")
local CONFIG = require("config")
local log, once, onceErr, safe = UTIL.log, UTIL.once, UTIL.onceErr, UTIL.safe
log("loaded " .. VERSION)
local D = require("ap_data")
local TECHS = require("tech_icons")
local ICONS, STRUCTURES = TECHS.icons, TECHS.structures
local R = require("records")
local WALLS = require("walls")
local POPUP = require("hint_popup")
local DEBUFFS = require("debuffs")
local CRATES = require("crates")
local CWIN = require("crate_window")
local MENU = require("menu")
local TECHSCAN = require("techscan")
local MAIL = require("mailbox")
local BAG = require("bag")
local TRAPS = require("traps")
local SYNC = require("sync")

local CLOCK = require("clock")
local WAIT, PHASE, isPhase = CLOCK.WAIT, CLOCK.PHASE, CLOCK.isPhase
local TECH_SCAN_TRIES = 40      -- one try per cycle until the player's tech data is there: about 84 s
local SENT_HOME_AFTER = 2       -- looks in a row (one per cycle) inside a locked area before the player is sent home

-- Death Link's JSON, both ways: a string's contents escaped for sending, and a string field read back with \" and
-- \\ undone (other clients escape quotes in their causes).
local function jsonText(text)
    local clean = text:gsub("%c", "")
    return (clean:gsub('[\\"]', "\\%0"))
end
local function jsonField(data, key)
    local _, open = data:find('"' .. key .. '"%s*:%s*"')
    if not open then return nil end
    local out, i = {}, open + 1
    while i <= #data do
        local c = data:sub(i, i)
        if c == '"' then return table.concat(out) end
        if c == "\\" then
            i = i + 1
            c = data:sub(i, i)
        end
        out[#out + 1] = c
        i = i + 1
    end
    return nil
end

if type(AP_Connect) ~= "function" then
    log("APConnector is not installed: no AP_* functions. Install ue4ss/Mods/APConnector and enable it in mods.txt.")
    return
end
CONFIG.install({ dir = modDir })
local cfg, HINT_KEY, writeConfig = CONFIG.cfg, CONFIG.hintKey, CONFIG.write
-- The performance probe (perf_log=1; perf.lua). Installed before any hook is registered, so it counts them all.
local P = require("perf")
P.install(cfg, { wallsCount = function() return (WALLS.count()) end, setWalls = function(mode) WALLS.perfMode(mode) end,
                 mailOpen = function() return MAIL.viewOpen() end })
-- The test tools (test_tools.lua). update() steps their probes every update; they stay idle unless installed, which
-- only test_tools=1 in config.txt does (at the end of this file).
local TEST_TOOLS = require("test_tools")
local STATE = require("ap_state")
local ap, slotFlag, slotNumber = STATE.ap, STATE.slotFlag, STATE.slotNumber
local PLAYER = require("player")
local playerContext, findPlayerState, playerState, notify =
    PLAYER.context, PLAYER.findPlayerState, PLAYER.playerState, PLAYER.notify
WALLS.visited = ap.visited                -- (the same table: the map reads it)

local SAVE = require("save")
SAVE.install({ dir = modDir })
local saveFile, loadSave, writeSave = SAVE.path, SAVE.load, SAVE.write
local TECH_LOCK = require("tech_lock")
TECH_LOCK.install({ dir = modDir })
TECH_LOCK.readLastResearch()
local syncTechs = TECH_LOCK.sync

local WORLD = require("world")

-- One-off effects of items, in index order; each is applied once per seed. False when it could not be applied yet (a
-- bundle the bag refused, with the mailbox off): it is tried again later.
local function giveOneOff(ps, id, index)
    local it = D.items[id]
    if not it then return true end
    if it.name == "Palworld Crate" then
        local weights = {}
        for _, k in ipairs(CRATES.KINDS) do weights[k] = slotNumber("options." .. CRATES.WEIGHT_KEYS[k]) end
        local kind = CRATES.receive(ap.seed, index, weights)
        notify("Palworld Crate: it's a " .. CRATES.NAMES[kind] .. "! Open it from the Inventory page when you like.")
        return true
    end
    local td = ps:GetTechnologyData()
    if it.name == "Tech Points +2" then
        td.TechnologyPoint = td.TechnologyPoint + 2
        safe(function() td:OnRep_TechnologyPoint() end)
    elseif it.name == "Ancient Tech Points +1" then
        td[R.ANCIENT_POINTS] = td[R.ANCIENT_POINTS] + 1
        safe(function() td[R.ANCIENT_ONREP](td) end)
    elseif R.BUNDLES[it.name] then
        for _, b in ipairs(R.BUNDLES[it.name]) do
            if MAIL.on() then
                MAIL.add(b[1], b[2])
            else
                -- Counted and logged as the mailbox does (what a full bag answers is untested). A bundle is one stack.
                local okg, got = pcall(BAG.give, b[1], b[2])
                if not okg then once("give" .. tostring(got), "could not give " .. b[1] .. ": " .. tostring(got)); return false end
                if got == 0 then return false end
                if got < b[2] then log("bundle " .. it.name .. ": only " .. got .. " of " .. b[2] .. " " .. b[1] .. " went in") end
            end
        end
    end
    return true
end

-- Relics received so far (the Relic Hunt goal), up to item index `upto` (all by default; items are numbered from 0).
local function relicCount(upto)
    local n = 0
    for i, id in pairs(ap.items) do
        local it = D.items[id]
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
    while CRATES.pending[1] do
        local e = CRATES.pending[1]
        local okg, got = pcall(BAG.give, e[1], e[2])
        got = okg and got or 0
        if got <= 0 then return end
        e[2] = e[2] - got
        if e[2] <= 0 then table.remove(CRATES.pending, 1) end
        notify("Your bag had room: " .. BAG.nameOf(e[1]) .. " from a crate is in it now.")
    end
end

-- Opening a crate (the Inventory page's Open button: the next one; the crate window's: one of `kind`), its contents
-- rolled from the player's level now. Returns the kind and the contents.
local function openCrate(kind)
    local ps = playerState()
    if not (ps and ps:IsValid()) then notify("Open crates in your world."); return end
    local lv = R.level(ps) or ap.level or 1
    local out
    kind, out = CRATES.openNext(lv, kind)
    if not kind then return end
    local parts = {}
    for _, r in ipairs(out) do
        local name = BAG.nameOf(r.id)
        if r.bag or not MAIL.on() then
            local okg, got = pcall(BAG.give, r.id, r.n)
            got = okg and got or 0
            if got < r.n then CRATES.pending[#CRATES.pending + 1] = { r.id, r.n - got } end
            parts[#parts + 1] = (r.n > 1 and (r.n .. " x ") or "") .. name .. (got < r.n and " (waits for room in your bag)" or " (in your bag)")
        else
            MAIL.add(r.id, r.n)
            parts[#parts + 1] = r.n .. " x " .. name
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
        local id, n, name = g[1], g[2], BAG.nameOf(g[1])
        if g.bag or not MAIL.on() then
            local okg, got = pcall(BAG.give, id, n)
            got = okg and got or 0
            if got < n then CRATES.pending[#CRATES.pending + 1] = { id, n - got } end
            parts[#parts + 1] = (n > 1 and (n .. " x ") or "") .. name .. (got < n and " (waits for room in your bag)" or " (in your bag)")
        else
            MAIL.add(id, n)
            parts[#parts + 1] = n .. " x " .. name .. " (in the mailbox)"
        end
    end
    log("nomad: " .. it.name .. " brought " .. table.concat(parts, ", "))
    notify(it.name .. " brought " .. table.concat(parts, ", ") .. ".")
end

local function applyItems(ps)
    givePending()
    local i = ap.given + 1
    while ap.items[i] do
        local id = ap.items[i]
        local it = D.items[id]
        if it and it.kind == "filler" and not giveOneOff(ps, id, i) then
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
            notify("Palpagos Relic " .. relicCount(i) .. (need and ("/" .. need) or "") .. " found!")
        end
        ap.given = i
        i = i + 1
    end
    writeSave()
end

-- The seed's goal (slot data options.goal: 0 towers, 1 relic hunt, 2 Paldeck, 3 World Tree); what was done, or nil.
local GOALS = { ["0"] = "towers", ["1"] = "relic_hunt", ["2"] = "paldeck", ["3"] = "world_tree" }
local function goalReached(found)
    local number = AP_SlotData("options.goal")
    if number == nil or number == "" then number = "0" end      -- (a seed without the option: the default, towers)
    local goal = GOALS[number]
    if not goal then
        once("goalunknown", "this seed's goal (" .. tostring(number) .. ") is not known to this version of the mod:"
            .. " the goal is not judged or sent")
        return nil
    end
    if goal == "relic_hunt" then
        local have, need = relicCount(), slotNumber("relics_needed", 999)
        return have >= need and (have .. " Palpagos Relics found") or nil
    elseif goal == "paldeck" then
        local need = slotNumber("options.paldeck_count", 999)
        return found.pals >= need and (found.pals .. " Pals registered") or nil
    elseif goal == "world_tree" then
        return found.beaten.WorldTreeBoss and "the World Tree's boss beaten" or nil
    end
    local need = slotNumber("options.tower_count", 99)
    return found.towers >= need and (found.towers .. " tower(s) beaten") or nil
end

------------------------------------------------------------------------------------------------------------------------
-- Checks.
local function sendChecks(locs)
    local fresh = {}
    for _, loc in ipairs(locs) do
        if not ap.checked[loc] and not ap.sent[loc] then
            ap.sent[loc] = true
            fresh[#fresh + 1] = tostring(loc)
        end
    end
    if #fresh > 0 and ap.status == "connected" then
        AP_Check(table.concat(fresh, ","))
        log("sent " .. #fresh .. " check(s): " .. table.concat(fresh, ","))
    end
end
-- Checks the mod sent itself are not in the game's records, so nothing else would send them again: a purchase whose
-- check went into a socket already dead (but not yet noticed) is sent on the next connection. The server ignores a
-- check it already has.
local function sendBoughtAgain()
    local again = {}
    for loc in pairs(ap.bought) do again[#again + 1] = tostring(loc) end
    if #again == 0 then return end
    table.sort(again)
    AP_Check(table.concat(again, ","))
    log("sent " .. #again .. " bought check(s) again on connecting")
end

-- Everything the game's records say is done: levels, captures, alphas, fast travel, towers. The server ignores
-- locations this seed doesn't have (options turned off), so the mod doesn't need to know which are in play.
-- The goal waits for the player to leave the boss's arena (a stage, as for the Teleport Trap): the user, 2026-11-08,
-- beat the tower goal and the release flooded chat mid-arena, the goal line lost in it, before the game took them out
-- of the tower. Sent once a check finds them out of any stage, or WAIT.goal after (never stuck); with the banner.
-- State: the goal. Three flags, in the order they are set: goalWait (reached, waiting for the player to leave the
-- boss's arena), ap.goalSent (sent this connection) and ap.goalShown (banner shown, in the save file). Forgotten:
-- goalWait on a new seed (resetGoal); the two ap flags as ap_state.lua says.
local goalWait = nil          -- { done = what, since = the update it was reached on }
-- Forgets a goal reached in the last seed that was still waiting to be sent.
local function resetGoal()
    goalWait = nil
end
local function pollRecords(ps, tick)
    local okp, found = pcall(R.progress, ps, D, os.time())
    if not okp then once("records", "records not readable yet (loading?): " .. tostring(found)); return end
    sendChecks(found.locations)
    ap.level, ap.beaten = found.level, found.beaten
    if ap.goalSent then return end
    local done = goalReached(found)
    if done and not goalWait then
        goalWait = { done = done, since = tick }
        log("goal reached (" .. done .. "): sent once the player is out of the arena")
    end
    if not goalWait then return end
    local okS, inStage = pcall(function() return ps:IsInStage() end)
    local out = not (okS and inStage)                  -- (not readable: no waiting, as before)
    if not (out or tick - goalWait.since >= WAIT.goal) then return end
    ap.goalSent, done = true, goalWait.done
    goalWait = nil
    AP_Goal()                                          -- (sent again on each connection: the server takes it once)
    log("goal sent: " .. done .. (out and "" or " (still in a stage after 2 minutes)"))
    -- The banner and notice once per seed (kept in the save as goal=shown): 2026-11-08, loading a won world showed the
    -- banner again.
    if ap.goalShown then return end
    ap.goalShown = true
    notify("Goal complete: " .. done .. "!")
    local okb, errb = pcall(POPUP.banner, done, tick)
    if not okb then log("goal banner error: " .. tostring(errb)) end
end

------------------------------------------------------------------------------------------------------------------------
-- The shop: cards relabelled every 300 ms (kit 9's shape: timer relabel plus two post-hooks, never widget work inside
-- Blueprint hooks, which crashed kits 5 and 6).
-- Textures the cards use are kept alive in the game instance's ReferencedObjects for the whole session: otherwise
-- nothing references them once the menu rebuilds its cards, the engine frees them, and the cards go blank grey.
-- State: forgotten never; looked up again when it is no longer valid.
local keptBy = nil         -- the game instance lives all session (skill: GameInstance-owned objects); checked on use
-- Keeps obj alive in place `index` of ReferencedObjects, in place of what was kept there, so a picture that is made
-- again and again keeps one place, not one more each time. Nothing is removed from the list: that is untested from
-- Lua. With no place yet (nil, past the list's end, or in the list of a game instance found before) obj goes at the
-- end. Returns its place.
local function keepInPlace(index, obj)
    if not (keptBy and keptBy:IsValid()) then
        keptBy = FindFirstOf("PalGameInstance") or FindFirstOf("GameInstance")
        index = nil
    end
    local gi = keptBy
    local ok, at = pcall(function()
        local arr = gi.ReferencedObjects
        local n = arr:GetArrayNum()
        local place = (index and index <= n) and index or n + 1
        arr[place] = obj
        return place
    end)
    if not ok then
        once("keep", "could not keep a texture alive: " .. tostring(at))
        return index
    end
    return at
end
local function keep(obj) keepInPlace(nil, obj) end
WALLS.keep, WALLS.keepInPlace = keep, keepInPlace
WALLS.dir = modDir
WALLS.cppOff = cfg.map_cpp == "0"
WALLS.chartOff = cfg.map_chart == "0"
WALLS.iconsOff = cfg.map_icons == "0"
WALLS.regionsOff = cfg.map_regions == "0"
WALLS.mapStyle = cfg.map_style == "chart" and "chart" or "territories"
WALLS.testFogColour = cfg.test_tools == "1"
do local ART = require("art"); ART.keep, ART.dir = keep, modDir end
do      -- wall skins (test builds; walls.lua): wall_skin=a|b|a3d|b3d|a3d-dense|b3d-dense, wall_tiling=U,V and wall_scroll=U,V in config.txt
    local function pair(s)
        local u, v = (s or ""):match("^%s*([%d.]+)%s*,%s*([-%d.]+)%s*$")
        return u and { tonumber(u), tonumber(v) } or nil
    end
    WALLS.tiling, WALLS.scroll = pair(cfg.wall_tiling), pair(cfg.wall_scroll)
    -- wall_radius=<m>: walls stand only this near you (0: everywhere); wall_fade=<near>,<far> in metres (M_APWall walls)
    local radius = tonumber(cfg.wall_radius or "")
    if radius and radius >= 0 then WALLS.radius = radius * 100 end
    local fade = pair(cfg.wall_fade)
    if fade and fade[2] > fade[1] then WALLS.fade = { fade[1] * 100, fade[2] * 100 } end
    WALLS.setSkin(cfg.wall_skin)
end

-- State: forgotten never (each is kept alive in the game instance; one no longer valid is loaded again).
local textures = {}           -- icon kind -> its texture, or false when loading it failed
-- A failed load is remembered as false for the session, so it is not loaded again for every card on every update.
local function icon(kind, ctx)
    local t = textures[kind]
    if t == false then return nil end
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then once("nolib", "KismetRenderingLibrary not found"); return nil end
    local path = modDir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if not (t and t:IsValid()) then
        textures[kind] = false
        log("could not load icon " .. path)
        return nil
    end
    textures[kind] = t
    keep(t)
    return t
end

-- A technology's own icon (an asset in the game), for slots that hold one of your techs.
local techTextures = {}       -- tech id -> its icon's texture, or false when loading it failed (state, as textures)
local function techIcon(tech)
    local t = techTextures[tech]
    if t == false then return nil end                 -- (failed before: see icon)
    if t and t:IsValid() then return t end
    local path = ICONS[tech]
    if not path then return nil end
    t = StaticFindObject(path)
    if not t or not t:IsValid() then
        pcall(LoadAsset, path)
        t = StaticFindObject(path)
    end
    if not (t and t:IsValid()) then
        techTextures[tech] = false
        log("could not load " .. path)
        return nil
    end
    techTextures[tech] = t
    keep(t)
    return t
end

local function iconKind(flags)
    if flags & 1 ~= 0 then return "progression" end
    if flags & 2 ~= 0 then return "useful" end
    return "filler"
end

-- The tech a slot holds when it holds one of your own techs (such cards show that tech as itself).
local function ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local it = r and r.own and D.items[r.id]
    return it and it.kind == "tech" and it.tech or nil
end

-- What a slot sends, as the card names it.
local function rewardText(tech)
    local r = ap.scouted[D.shop[tech].loc]
    if not r then return "Archipelago item" end
    local mine = ownTech(tech)
    if mine then return D.shop[mine].name end
    if r.own then return "Your " .. r.item end
    return r.player .. "'s " .. r.item .. " (" .. r.game .. ")"
end

local function shopCard(tech) return ap.shopOpen and D.shop[tech] ~= nil end
local function bought(tech) return ap.checked[D.shop[tech].loc] == true end

-- The game's own card categories, read off the level-1 cards (never relabelled) so they follow the game's language.
local categories = { structure = "Structures", item = "Items" }    -- state, forgotten never (the game's language)
local function readCategory(card, tech)
    local text = safe(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    if type(text) == "string" and text ~= "" then categories[STRUCTURES[tech] and "structure" or "item"] = text; return true end
    return false
end

-- A card the mod labelled is labelled again only when something says it needs it. 6dd356e set every card's texts,
-- icon and click state on every update (about 11 UE4SS calls a card, an estimated 1-3 ms an update with the menu's
-- 30-80 cards, unmeasured). Now a card is skipped when its tech and what it should show are as last applied AND the
-- card itself still shows it: its name texts, its category, its icon and its click state are read back (cheap reads),
-- which catches the game setting a pooled card up again, or a text block re-applying its own text-table row on a
-- rebuild (issues-log: PalTextBlockBase). Anything that can't be read back counts as changed. Every 10th pass (3 s)
-- relabels every card anyway, as a safety net for anything those reads miss.
-- State: the cards. Forgotten: a card's entry once the card is no longer found (refreshCards), all of them when no
-- card is; readBack never (each is logged once a session).
local labelled = {}           -- card address -> { tech, sig, name, category, tex address, clickable } as last applied
local readBack = {}           -- which read-backs worked (logged once each, for the playtest)
local function noteRead(what, ok)
    if readBack[what] == nil then
        readBack[what] = ok
        log("cards: reading back the " .. what .. (ok and " works" or " does not work (those cards are relabelled every update)"))
    end
end
local function stillShows(card, seen)
    local okt, text = pcall(function() return card.RichText_TechnologyName_Lock:GetText():ToString() end)
    noteRead("name", okt)
    if not okt or text ~= seen.name then return false end
    local oku, unlock = pcall(function() return card.RichText_TechnologyName_Unlock:GetText():ToString() end)
    noteRead("unlocked name", oku)
    if not oku or unlock ~= seen.name then return false end
    local okg, cat = pcall(function() return card.BP_PalTextBlock_Category:GetText():ToString() end)
    noteRead("category", okg)
    if not okg or cat ~= seen.category then return false end
    if seen.tex then
        local oki, res = pcall(function() return tostring(card.Image_Icon.Brush.ResourceObject:GetAddress()) end)
        noteRead("icon", oki)
        if not oki or res ~= seen.tex then return false end
    end
    local okc, on = pcall(function() return card.WBP_PalInvisibleButton:IsInteractionEnabled() end)
    noteRead("click state", okc)
    return okc and on == seen.clickable
end

-- Card header: one of your techs looks like ordinary research (its own category, before and after buying); your
-- other items say "Received" once bought, other players' items "Sent".
local function relabel(card, key, full)
    local tech = card.BindedTechnologyName:ToString()
    -- A level-1 card's category is read until the game has filled it in (it can still be empty as the card is built),
    -- then again only on a full pass or when the card shows another tech.
    if D.starters[tech] and (full or not labelled[key] or labelled[key].tech ~= tech) then
        labelled[key] = readCategory(card, tech) and { tech = tech } or nil
    end
    if not shopCard(tech) then return end
    local sent, mine = bought(tech), ownTech(tech)
    local r = ap.scouted[D.shop[tech].loc]
    local own = r and r.own
    local category = mine and categories[STRUCTURES[mine] and "structure" or "item"]
        or (sent and (own and "Received" or "Sent") or "Archipelago")
    local name = ((sent and not own) and "Sent: " or "") .. rewardText(tech)
    local clickable = not sent or mine ~= nil
    local it = own and D.items[r.id]
    local kind = (it and it.kind == "pass") and "area-pass" or (r and iconKind(r.flags) or "filler")
    -- A Region Pass shows its own region's ticket (art/ap-pass-<region>.png); an Area Pass (Lock Size: areas) its
    -- region's, else the small-pass ticket (ap-pass-region.png, named before the rename); else the shared one.
    local ART = require("art")
    local tex = mine and techIcon(mine)
        or (it and it.name == "Palworld Crate" and ART.texture("ap-crate-palworld"))
        or (kind == "area-pass" and (ART.texture("ap-pass-" .. WALLS.slugOf(WALLS.parentOf(it.area)))
                                     or (it.name:find("^Area Pass") and ART.texture("ap-pass-region"))))
        or icon(kind, card)
    local texAddr = tex and safe(function() return tostring(tex:GetAddress()) end) or nil
    local sig = name .. "\0" .. category .. "\0" .. tostring(clickable) .. "\0" .. tostring(texAddr)
    local seen = labelled[key]
    if not full and seen and seen.tech == tech and seen.sig == sig and stillShows(card, seen) then
        P.count("cardsSkipped")
        return
    end
    P.count("cards")
    -- A bought card does nothing when clicked (the game is told it cannot be researched). One showing your own tech
    -- stays interactive so its tooltip still works; the others are switched off outright.
    safe(function() card.WBP_PalInvisibleButton:SetIsInteractionEnabled(clickable) end)
    local text = FText(name)
    safe(function() card.RichText_TechnologyName_Lock:SetText(text) end)
    safe(function() card.RichText_TechnologyName_Unlock:SetText(text) end)
    safe(function() card.BP_PalTextBlock_Category:SetText(FText(category)) end)
    if tex then safe(function() card.Image_Icon:SetBrushFromTexture(tex, false) end) end
    labelled[key] = { tech = tech, sig = sig, name = name, category = category, tex = texAddr, clickable = clickable }
end

-- State: forgotten never (cardPasses counts the session's passes); lastCards is replaced every update.
local cardPasses = 0          -- card passes so far: every 10th relabels every card
local lastCards = nil         -- this update's cards (the Ctrl+0 old-load replay relabels them again)
local function refreshCards(full)
    local cards = FindAllOf("WBP_MainMenu_Technology_Content_C")
    lastCards = cards
    if not cards then labelled = {}; return end
    cardPasses = cardPasses + 1
    full = full or cardPasses % 10 == 0
    local current = {}
    for _, card in ipairs(cards) do
        if card:IsValid() then
            local key = safe(function() return tostring(card:GetAddress()) end) or card
            current[#current + 1] = key
            local ok, err = pcall(relabel, card, key, full)
            if not ok then once("relabel", "relabel error: " .. tostring(err)) end
        end
    end
    local kept = {}           -- cards gone are forgotten
    for _, key in ipairs(current) do kept[key] = labelled[key] end
    labelled = kept
end

local function refreshTree()
    local tree = FindFirstOf("WBP_MainMenu_Technology_00_C")
    if tree and tree:IsValid() then safe(function() tree:UpdateAllTechnologyButton() end) end
    refreshCards(true)
end

-- The game's classes the shop hooks: a tech card, the tooltip, the confirm box and the tech tree.
local SHOP_CLASS = {
    card = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content"
        .. ".WBP_MainMenu_Technology_Content_C",
    tooltip = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo"
        .. ".WBP_InventoryEquipment_ItemInfo_C",
    dialog = "/Game/Pal/Blueprint/UI/Dialog/WBP_PalDialog.WBP_PalDialog_C",
    tree = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00"
        .. ".WBP_MainMenu_Technology_00_C",
}
-- State: the shop's hover hand-off, between four hooks and a deferred call, in this order:
--   1. The pointer goes onto a slot card: tooltipSetup sets hoveredTech and hides the tooltip.
--   2. If the slot holds one of your own techs, on the next frame (tooltipSetup's ExecuteInGameThread) retarget is
--      set to that tech and the tooltip is set up again for it.
--   3. tooltipSetup runs again, sees retarget, shows the tooltip and clears retarget.
--   4. A click: canResearch and isResearched answer for hoveredTech only, and confirmBoxSetup reads hoveredTech to
--      name what the purchase sends.
--   5. The pointer leaves the card: cardUnhovered clears hoveredTech (updateWindows also clears it once the main
--      menu is closed, as the un-hover event may not come then).
-- hoveredTech is set whenever the game sets a tooltip up, for any tech, not only for the card under the pointer.
local hoveredTech = nil       -- the tech whose tooltip was set up last: a confirm box opened then came from its card
local retarget = nil          -- the tech a tooltip is being set up again for (step 2), until step 3 uses it

local function confirmText(tech)
    local s = D.shop[tech]
    return "Buy " .. rewardText(tech) .. " for " .. s.cost .. (s.ancient and " Ancient" or "") .. " Technology Point(s)?"
end

-- Blueprint hooks can only be registered once their class has loaded (when a menu first opens). UE4SS runs the FIRST
-- callback AFTER a Blueprint function, so these change what the function produced.
-- Work for the next updates, on the game thread (soon.lua: ExecuteWithDelay's callbacks ran Lua off-thread).
local SOON = require("soon")
local later = SOON.later

-- The core update never runs inside a hook. UE4SS can run its game-thread queue from inside a hook (a log showed the
-- update's player lookup nested inside IsUnlockRecipeTechnology's hook, under a:get(); FindAllOf then got a bad
-- argument and UE4SS logged "Ref was not function"), and an update inside a Blueprint hook would do widget work there,
-- which crashes the game. So every hook callback runs through guarded(), and an update that finds itself inside one
-- skips its turn. (The other way round is ordinary: the update refreshing the tech tree asks these hooks.)
-- State: each is true only while a hook callback or an update runs.
local inHook, inTick = false, false
local function guarded(fn, ...)
    local was = inHook
    inHook = true
    local ok, v = pcall(fn, ...)
    inHook = was
    return ok, v
end
-- A hook callback run through guarded(). An error is logged once under the hook's name, and the game's own result
-- stands. Handed to menu.lua and mailbox.lua for their hooks too.
local function guardedHook(name, cb)
    return function(...)
        local ok, v = guarded(cb, ...)
        if ok then return v end
        once("hookerr" .. name, "hook " .. name .. " error: " .. tostring(v))
    end
end

-- A slot card looks researched exactly when its slot has been bought, whether or not you own its tech.
local function cardLooksResearched(self, out)
    if not ap.shopOpen then return end     -- no shop card yet (shopCard is false for all): the game's answer
    local tech = self:get().BindedTechnologyName:ToString()
    if not shopCard(tech) then return end
    pcall(function() out:set(bought(tech)) end)
    return bought(tech)
end
-- Tooltips: a slot holding one of your techs shows that tech's own tooltip (set up again for it, a moment later,
-- outside this hook); other slot cards have none (the card already says what it sends). Hidden by transparency
-- rather than collapsing: the game makes the tooltip visible again after setting it up.
local function tooltipSetup(self, techName)
    local tech = techName:get():ToString()
    local info = self:get()
    if retarget == tech then
        retarget = nil
        -- Its prerequisite / tower note does not apply here: the item unlocks the tech outright.
        pcall(function() info.WBP_InventoryEquipment_ItemInfo_Caution:SetVisibility(1) end)   -- Collapsed
        pcall(function() info:SetRenderOpacity(1.0) end)
        return
    end
    hoveredTech = tech
    local mine = shopCard(tech) and ownTech(tech)
    pcall(function() info:SetRenderOpacity((shopCard(tech) or mine) and 0.0 or 1.0) end)
    if not mine then return end
    ExecuteInGameThread(function()
        if not info:IsValid() or hoveredTech ~= tech then return end
        retarget = mine
        local ok, err = pcall(function() info["Setup by Technology Name"](info, FName(mine), false, techIcon(mine)) end)
        if not ok then retarget = nil; once("retarget", "could not show the tooltip of " .. mine .. ": " .. tostring(err)) end
    end)
end
-- Leaving a card forgets it, so a later dialog (Return to Title...) is not mistaken for a purchase.
local function cardUnhovered()
    hoveredTech = nil
end
-- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
-- applied on the next frame and again on the next two updates (only while it still differs): about the first
-- half second, as the five ExecuteWithDelay re-applies did, all on the game thread.
local function confirmBoxSetup(self, dialogType, message)
    local tech = hoveredTech
    once("dialogmsg", "first confirm box message: '" .. tostring(safe(function() return message:get():ToString() end)) .. "'")
    if not shopCard(tech) or bought(tech) then return end
    local dialog, text = self:get(), confirmText(tech)
    local function apply()
        if not dialog:IsValid() then return end
        local popup = dialog.WBP_CommonPopupWindow
        local msg = safe(function() return popup.BP_PalRichTextBlock_Message:GetText():ToString() end)
        if msg ~= text then pcall(function() popup:SetMainText(FText(text)) end) end
    end
    ExecuteInGameThread(apply)                      -- (from this hook, on the game thread: the next frame)
    later(1, apply)
    later(2, apply)
end

-- Buying: the request is rewritten so the game unlocks nothing; the mod charges the points and sends the check.
local function buy(tech)
    local s = D.shop[tech]
    local ps = playerState()
    if not ps then return end
    if ap.status ~= "connected" or not ap.ready then
        notify("Not connected to Archipelago: nothing bought.")
        return
    end
    if WORLD.seedWorld() == false then
        notify("This is not the world this Archipelago seed is played in: nothing bought.")
        return
    end
    if bought(tech) then return end
    local td = ps:GetTechnologyData()
    local field = s.ancient and R.ANCIENT_POINTS or "TechnologyPoint"
    local before = td[field]
    if before < s.cost then
        log("buy " .. tech .. ": not enough points (" .. before .. " < " .. s.cost .. ")")
        return
    end
    td[field] = before - s.cost
    safe(function() td[s.ancient and R.ANCIENT_ONREP or "OnRep_TechnologyPoint"](td) end)
    log(string.format("BOUGHT %s for %d %s: %d -> %d, sends %s", tech, s.cost, field, before, td[field], rewardText(tech)))
    ap.bought[s.loc] = true
    sendChecks({ s.loc })
    ap.checked[s.loc] = true
    refreshTree()
end

-- A research request for a shop slot: the game is asked for a slot no tech has, and the purchase runs on the next
-- update, outside this hook.
local function researchRequested(self, name)
    local tech = name:get():ToString()
    if not D.shop[tech] then return end
    name:set(FName("AP_ShopSlot"))
    -- Ctrl+9 (perf test tools): the confirm box shows the game's own text then, not what the purchase sends, so
    -- a confirm is not a purchase. A check sent cannot be taken back in the multiworld.
    if P.bypass then log("[perf] purchase of " .. tech .. " ignored while the hook bypass (Ctrl+9) is on"); return end
    later(1, function()                             -- the next update (within 300 ms), on the game thread
        local ok, err = pcall(buy, tech)
        if not ok then log("buy error: " .. tostring(err)) end
    end)
end

-- Whether a slot can be bought, asked by the game before it opens the confirm box. A bought slot never can. A slot
-- whose tech you already own (from its item) is judged here, as the game refuses anything already unlocked: your
-- level, points, and the slot's own prerequisite / tower / lab research. Otherwise the game's answer stands (nil).
local function slotUnlockable(td, tech)
    local s = D.shop[tech]
    if bought(tech) then return false end
    if not ap.techs[tech] then return nil end
    if ap.level < s.level then return false end
    if (td[s.ancient and R.ANCIENT_POINTS or "TechnologyPoint"] or 0) < s.cost then return false end
    local p = s.prereq
    -- A prerequisite the seed leaves as normal research is met once the player has researched it in the game.
    if p and not (ap.techs[p] or D.starters[p] or (D.research[p] and TECH_LOCK.researchedNow(p))) then return false end
    if s.tower and not ap.beaten[s.tower] then return false end
    if s.research then
        local ok, yes = pcall(function() return td:IsLabResearchRequirementSatisfied(FName(s.research)) end)
        if not (ok and yes) then return false end
    end
    return true
end
-- UE4SS hands the after-callback the function's result before its parameters (seen in 1.0.5: a plain boolean, then the
-- name), so the name is found by what it is rather than where it is.
local function techArg(...)
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "userdata" or type(a) == "table" then
            local ok, s = pcall(function() return a:get():ToString() end)
            if ok and type(s) == "string" then return s end
        end
    end
end
-- Whether a slot can be bought (the after-callback of IsUnlockableRecipeTechnology). The tech menu asks this (and
-- the next hook) about 25 times for each card it builds or refreshes, and twice for all 588 techs on a filter. The
-- early returns give exactly what the full check gives in that case (nothing is a shop card before ap.shopOpen; the
-- next hook answers only for the hovered card), and the checks are module-level functions, so no closure is made
-- per call.
local function canResearch(self, ...)
    if not ap.shopOpen then return nil end
    local tech = techArg(...)
    if not tech or not shopCard(tech) then return nil end
    local r = slotUnlockable(self:get(), tech)
    if r ~= nil and not UTIL.said("unlockable") then once("unlockable", "slot clickability decided by the mod (first: " .. tech .. " -> " .. tostring(r) .. ")") end
    if tech == hoveredTech and not UTIL.said("ask1" .. tech) then
        -- Left to the game (nil): its own answer too, the first plain boolean UE4SS hands the after-callback (2026-11-05:
        -- Direhowl's Saddled Harness stayed greyed with no gate in our data or the game's table).
        local game
        if r == nil then for i = 1, select("#", ...) do if type((select(i, ...))) == "boolean" then game = select(i, ...); break end end end
        once("ask1" .. tech, "click check on " .. tech .. ": unlockable -> " .. tostring(r) .. (r == nil and (" (the game says " .. tostring(game) .. ")") or ""))
    end
    return r
end

-- Whether a tech is already researched (the after-callback of IsUnlockRecipeTechnology). The click also asks this,
-- and stops if it is. For an unbought slot whose tech you own, that one question is answered "not yet" while the
-- pointer is on its card; everywhere else (crafting, building) the game's answer stands.
local function isResearched(self, ...)
    if hoveredTech == nil then return nil end      -- answers only for the card under the pointer
    local tech = techArg(...)
    if not tech or tech ~= hoveredTech or not shopCard(tech) then return nil end
    if bought(tech) or not ap.techs[tech] then return nil end
    once("ask2" .. tech, "click check on " .. tech .. ": already researched -> answered not yet")
    return false
end

-- The shop's seven hooks. Every callback runs through guardedHook (so no core update runs inside it), registered
-- by one of two functions: a Blueprint class (`native` nil) can be hooked only once it has loaded, when a menu
-- first opens (registerLazyHooks, every update); the three native classes exist at load (registerNativeHooks).
-- UE4SS runs the first callback of a Blueprint hook AFTER the function, so those change what it produced; a native
-- hook marked `after` changes the result through RegisterHook's second callback.
local SHOP_HOOKS = {
    { path = SHOP_CLASS.card .. ":IsUnlocked", cb = cardLooksResearched },
    { path = SHOP_CLASS.tooltip .. ":Setup by Technology Name", cb = tooltipSetup },
    { path = SHOP_CLASS.tree .. ":OnUnhoveredAnyTechnology_Internal", cb = cardUnhovered },
    { path = SHOP_CLASS.dialog .. ":SetupUI", cb = confirmBoxSetup },
    { path = "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer", cb = researchRequested,
      native = true },
    { path = "/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology", cb = canResearch, native = true,
      after = true },
    { path = "/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", cb = isResearched, native = true,
      after = true },
}
-- A hook's function name, the part of its path after the colon: what its log lines and error keys name.
local function hookName(h)
    return h.path:match("[^:]+$")
end
-- Each Blueprint hook is registered once its class has loaded (UTIL.hookWhenLoaded retries while it loads).
local function registerLazyHooks()
    for _, h in ipairs(SHOP_HOOKS) do
        if not h.native and not h.done then
            h.guarded = h.guarded or guardedHook(hookName(h), h.cb)
            h.done = UTIL.hookWhenLoaded(h.path, h.guarded, "shop")
        end
    end
end
-- The native hooks, registered once at start-up, each logged as UTIL.hookWhenLoaded logs a Blueprint hook.
local function registerNativeHooks()
    for _, h in ipairs(SHOP_HOOKS) do
        if h.native then
            local callback = guardedHook(hookName(h), h.cb)
            local ok, err
            if h.after then
                ok, err = pcall(RegisterHook, h.path, function() end, callback)
            else
                ok, err = pcall(RegisterHook, h.path, callback)
            end
            if ok then
                log("shop: hooked " .. hookName(h))
            else
                log("shop: could not hook " .. hookName(h) .. ": " .. tostring(err))
            end
        end
    end
end
registerNativeHooks()

------------------------------------------------------------------------------------------------------------------------
-- State of the menus' preload, the hints at walls, Death Link, the area locks and the world.
local preloaded = false       -- the shop's menu classes were loaded once ready: forgotten never (once a session)
-- State: hints at walls. Forgotten: known, shown and offer on a new seed (resetHints); key never.
local hints = {
    known = {},               -- area -> the server's hint sentence for that area's pass (onMessage)
    shown = {},               -- area -> the update that area's wall notice was last shown on (noticeLockedWall)
    offer = nil,              -- the area whose hint the player may ask for now (wallNotice; askHint takes it)
    offeredAt = 0,            -- the update the offer was made on: it lasts WAIT.hintOffer
    asked = nil,              -- the update the player last asked for a hint on: the server's answer is shown within
                              -- WAIT.hintAnswer (onMessage)
    key = HINT_KEY,           -- the key that asks (config.txt's hint_key)
}
-- Forgets the last seed's hints, the times their notices were shown and an offer still open.
local function resetHints()
    hints.known, hints.shown, hints.offer = {}, {}, nil
end
local wallsLogged = false     -- the first raising of walls was logged: forgotten never (once a session)
-- State: Death Link. Forgotten: never. `on` is set each connection; the route that worked stays for the session,
-- whatever the seed, and a death in flight belongs to whoever plays now.
local death = {
    on = false,               -- the seed has Death Link on (applySeedOptions)
    wasDead = false,          -- the player was dead at the last look: a new death is the change to dead
    incoming = nil,           -- the cause of a death received from the link, until it is applied or dropped
    at = nil,                 -- the update that death was received on (it is dropped after WAIT.deathLate)
    caused = nil,             -- the update the link last fainted the player on: a death soon after is not sent back
    pending = nil,            -- the cause of a faint just tried: the next look checks it worked
    route = 1,                -- which of ROUTES faints the player (the first that works)
}
local lockedTicks = 0         -- looks in a row inside a locked area: forgotten never (back to 0 outside one)
-- Notices that would come while the loading screen is still up (Speed Boost's, 2026-11-07 test: sent 2 s after the world
-- loaded, before the player could see it; they found it later in chat): held until the player's character has moved
-- MOVED_CM from where it first stood in this world, or WAIT.heldNotice has passed, then shown. Dropped if the world
-- changes first.
-- State: forgotten when the world changes (the held notices are dropped, not shown).
local heldNotices = {
    list = {},                -- the notices held, in order
    world = nil,              -- the world they were held in
    from = nil,               -- { X, Y }: where the player's character first stood in that world
}
local MOVED_CM = 300
local function noticeLater(msg)
    local held = heldNotices
    if held.world ~= WORLD.key() then held.list, held.world, held.from = {}, WORLD.key(), nil end
    held.list[#held.list + 1] = msg
end
local function showLater(pawn)
    local held = heldNotices
    if #held.list == 0 then return end
    if held.world ~= WORLD.key() then
        held.list, held.from = {}, nil
        return
    end
    local ok, at = pcall(function() return pawn:K2_GetActorLocation() end)
    local moved = false
    if ok and at and at.X then
        if not held.from then held.from = { X = at.X, Y = at.Y } end
        local dx, dy = at.X - held.from.X, at.Y - held.from.Y
        moved = dx * dx + dy * dy >= MOVED_CM * MOVED_CM
    end
    if moved or WORLD.age() >= WAIT.settle + WAIT.heldNotice then
        for _, msg in ipairs(held.list) do notify(msg) end
        local why = moved and "the player moved" or "a minute in the world"
        log("held notice(s) shown (" .. why .. "): " .. #held.list)
        held.list, held.from = {}, nil
    end
end
-- The seed's area_locks option, read once a connection (slot data is fixed for a connection) instead of every update,
-- which parsed the slot data's JSON each time in the connector (estimated 10-50 us and the connector's lock).
local areaLocks = false       -- state: set each connection (applySeedOptions)

-- Server events: one line each from AP_Poll, fields separated by tabs. The kinds and their fields, in order, are
-- defined in cppmod/APConnector/src/ap_bridge.hpp (take_events); each handler below takes them by name, in that order.
local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = part end
    return f
end

-- item <index> <item id> <location id> <player slot> <flags> <item name> <player name>
local function onItem(indexText, itemText, _locationText, playerText, _flagsText, name, from)
    local index, id, player = tonumber(indexText), tonumber(itemText), tonumber(playerText)
    if ap.items[index] == id then return end
    ap.items[index] = id
    TECH_LOCK.techsChanged()
    local it = D.items[id]
    if not it then
        log("unknown item " .. id .. " (" .. tostring(name) .. ")")
        return
    end
    if it.kind == "tech" then
        ap.techs[it.tech] = true
    elseif it.kind == "progressive" then
        local n = 0
        for _, v in pairs(ap.items) do if v == id then n = n + 1 end end
        for k = 1, math.min(n, #D.spheres) do ap.techs[D.spheres[k]] = true end
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

-- scout <location id> <item id> <player slot> <flags> <item name> <player name> <game>
local function onScout(locationText, itemText, playerText, flagsText, itemName, playerName, game)
    ap.scouted[tonumber(locationText)] = { id = tonumber(itemText), item = itemName, player = playerName, game = game,
                                           flags = tonumber(flagsText) or 0, own = tonumber(playerText) == ap.me }
end

-- checked <location id>: checked elsewhere (co-op, !collect)
local function onChecked(locationText)
    ap.checked[tonumber(locationText)] = true
end

-- bounce <tags> <json>: a Death Link from another player faints this one at the next items phase (deathLink).
local function onBounce(tags, json)
    if not (death.on and (tags or ""):find("DeathLink", 1, true)) then return end
    local data = json or ""
    local source = jsonField(data, "source") or "someone"
    local cause = jsonField(data, "cause")
    if source == cfg.slot then return end
    death.incoming, death.at = cause and cause ~= "" and cause or (source .. " died."), CLOCK.now()
end

-- message <text> <type>: chat; hints are shown, and a hint for one of our passes is kept for its wall's notice.
local function onMessage(textField, kindOf)
    local text = tostring(textField)
    log("AP: " .. text)
    if kindOf == "Hint" then
        notify(text)
        -- The finder is told too: a hint for another player's pass that sits in our world is not about our walls.
        local who, pass = text:match("^%[Hint%]: (.-)'s %a+ Pass: (.-) is at ")       -- Area or Region Pass
        if pass and who == (ap.slotName or cfg.slot) then hints.known[pass] = text:gsub("^%[Hint%]: ", "") end
    elseif kindOf == "CommandResult" and hints.asked and CLOCK.now() - hints.asked < WAIT.hintAnswer then
        notify(text)                               -- the server's answer to a hint the player asked for
    end
end

-- State: other mods' techs (techscan.lua). Forgotten: report and tries never (other mods do not change while the game
-- runs, so one scan a session is enough); sent on a new seed (resetTechScan), whose slots are other checks.
local techScan = {
    report = nil,             -- what the scan found, once it ran
    tries = 0,                -- scans tried this session (until the player's tech data is there)
    sent = false,             -- the checks of slots whose tech another mod removed were sent for this seed
}
-- Lets the removed slots' checks be sent again for a new seed.
local function resetTechScan()
    techScan.sent = false
end

-- Forgets everything tied to the last seed: a different seed or slot connected. One call per topic; what each forgets
-- is written at its state.
local function resetSeed()
    STATE.forgetSeed()
    WALLS.visited = ap.visited                -- (the new table: the map reads it)
    CRATES.reset()
    SYNC.reset()
    MAIL.reset()
    TRAPS.reset()
    TECH_LOCK.techsChanged()
    resetGoal()
    WORLD.resetSeedWorld()
    resetHints()
    resetTechScan()
    log("a different seed or slot: progress of the last one forgotten")
end

-- The seed's options that shape this session: area locks and their cut of the map, the areas beyond the goal, and
-- Death Link; the run style and traps are logged.
local function applySeedOptions()
    areaLocks = slotFlag("options.area_locks")
    -- The seed's cut of the map (options.lock_size: 0 the 15 regions, 1 the 75 areas). Seeds made before the rename
    -- send options.area_size, with the same numbers; older seeds send neither. WALLS still names the 75-area cut
    -- "regions".
    local size = AP_SlotData("options.lock_size")
    local useAreas                                  -- true: the 75 areas; false: the 15 regions
    if size ~= nil and size ~= "" then
        useAreas = size == "1" or size == "areas"
    else                                            -- a seed made before the rename
        local old = AP_SlotData("options.area_size")
        useAreas = old == "1" or old == "regions"
    end
    WALLS.setLayout(useAreas and "regions" or "areas")
    -- Areas beyond the goal (options.beyond_goal: 0 locked, 1 passes, 2 open; beyond_goal_areas): their passes are not
    -- in this seed. Locked, their walls stay up for good; open, they are open from the start.
    ap.beyond = {}
    local nBeyond = 0
    for area in AP_SlotData("beyond_goal_areas"):gmatch("[^|]+") do ap.beyond[area], nBeyond = true, nBeyond + 1 end
    local mode = AP_SlotData("options.beyond_goal")
    ap.beyondOpen = mode == "2" or mode == "open"
    if ap.beyondOpen then for area in pairs(ap.beyond) do ap.passes[area] = true end end
    WALLS.setBeyond(ap.beyondOpen and {} or ap.beyond)    -- sealed walls and stamps (open ones come down)
    if nBeyond > 0 then
        log("areas beyond the goal: " .. nBeyond .. (ap.beyondOpen and ", open from the start" or ", sealed for good"))
    end
    death.on = slotFlag("options.death_link") and AP_SetTags ~= nil
    if death.on then
        AP_SetTags("AP,DeathLink")
        log("Death Link on: amnesty " .. slotNumber("options.death_link_amnesty", 0) .. ", "
            .. ap.forgiven .. " faint(s) forgiven so far")
    end
    local style = SYNC.style(AP_SlotData)
    if style ~= 0 then log("run style: " .. SYNC.NAMES[style] .. " (techs also hand over what they make)") end
    if SYNC.boost(AP_SlotData) then
        log("speed boost: on (this seed changes the world's EXP, work speed and gathering)")
    end
    local chance = slotNumber("options.trap_chance", 0)
    if chance > 0 then log("traps: " .. chance .. "% of filler items are traps in this seed") end
end

-- Connected (again): the slot, the seed and its save, the techs left as research, what each shop slot holds, and the
-- seed's options. `was` is the status before.
local function onConnected(was)
    STATE.setStatus("connected")
    ap.connectedTick = CLOCK.now()
    ap.me = tonumber(AP_SlotData("slot"))
    local seed = AP_SlotData("seed")
    if seed ~= "" and (seed ~= ap.seed or cfg.slot ~= ap.slotName) then
        if ap.seed then resetSeed() end            -- another seed or slot: nothing of the last one carries over
        ap.seed, ap.slotName = seed, cfg.slot
        loadSave()
    end
    local research = AP_SlotData("research_techs")
    TECH_LOCK.setResearch(research)
    TECH_LOCK.keepResearch(research)
    local locs = {}
    for _, slot in pairs(D.shop) do locs[#locs + 1] = tostring(slot.loc) end
    AP_Scout(table.concat(locs, ","))
    ap.sent = {}
    ap.goalSent = false                    -- a goal sent on a connection that was already dead goes again
    sendBoughtAgain()
    if was ~= "connected" then notify("Connected to Archipelago as " .. cfg.slot) end
    applySeedOptions()
end

-- status <state> [detail]: connecting, socket, connected, refused, disconnected, or error (only logged)
local function onStatus(state, detail)
    log("status: " .. (state or "") .. (detail and (" " .. detail) or ""))
    if state == "connected" then
        onConnected(ap.status)
    elseif state == "connecting" then
        if ap.status ~= "connected" then STATE.setStatus("connecting") end
    elseif state == "refused" then
        STATE.setStatus("refused")
        notify("Archipelago refused the connection: " .. tostring(detail))
    elseif state == "disconnected" then
        STATE.setStatus("disconnected")
        ap.ready = false
    end
end

local EVENT_HANDLERS = { status = onStatus, item = onItem, scout = onScout, checked = onChecked, bounce = onBounce,
                         message = onMessage }
local function onEvent(line)
    local fields = split(line)
    local handler = EVENT_HANDLERS[fields[1]]
    if handler then handler(table.unpack(fields, 2)) end
end

------------------------------------------------------------------------------------------------------------------------
-- Connecting: at start from config.txt, and from the title menu's Archipelago menu (menu.lua), which saves it.
local function connectTo(server, slot, password)
    cfg.server, cfg.slot, cfg.password = server, slot, password or ""
    writeConfig()
    log("connecting to " .. server .. " as " .. slot)
    STATE.setStatus("connecting")
    AP_Connect(server, slot, password or "")
end
MENU.install({
    status = function() return ap.status end,
    servers = CONFIG.servers,
    rememberServer = CONFIG.rememberServer,
    server = function() return cfg.server or "" end,
    slot = function() return cfg.slot or "" end,
    password = function() return cfg.password or "" end,
    connect = connectTo,
    disconnect = function()
        AP_Disconnect()
        STATE.setStatus("disconnected")
        ap.ready = false
        log("disconnected by the player")
        notify("Disconnected from Archipelago.")
    end,
    mailboxLabel = MAIL.label,
    crateLabel = CRATES.label,
    openCrate = function() local ok, err = pcall(openCrate); if not ok then log("crate error: " .. tostring(err)) end end,
    openMailbox = function() MAIL.open() end,
    guardedHook = guardedHook,
})
MAIL.install({ notify = notify, save = writeSave, cfg = cfg, connected = function() return ap.status == "connected" end,
               guardedHook = guardedHook })
CWIN.install({ chestWidget = function() return MAIL.chestWidget() end,
               openCrate = function(kind)
                   local ok, k, out = pcall(openCrate, kind)
                   if not ok then log("crate error: " .. tostring(k)); return nil end
                   return k, out
               end })
TRAPS.install({ notify = notify, save = writeSave,
                announce = function(text) log(text); R.notify(text, playerState()) end,
                sender = function(index) return ap.from[index] end,
                home = function() return WALLS.home end, start = function() return WALLS.start end })
if cfg.server and cfg.server ~= "" and cfg.slot and cfg.slot ~= "" then
    log("connecting to " .. cfg.server .. " as " .. cfg.slot)
    AP_Connect(cfg.server, cfg.slot, cfg.password or "")
else
    log("not connected: click the Archipelago banner on the title menu (or set server and slot in config.txt)")
end

-- Hints for Region and Area Passes, bought with the server's hint points (!hint), offered at the walls.
-- Returns the chat line, and what the hint pop-up shows (hint_popup.lua: two short lines and the points bar).
local function wallNotice(area)
    if ap.beyond and ap.beyond[area] then
        return area .. " is beyond this seed's goal: its walls stay up.",
            { title = area .. " is beyond the goal", line = "Its walls stay up for good." }
    end
    local pass = WALLS.passName(area)
    if hints.known[area] then
        local where, world = hints.known[area]:match(" is at (.-) in (.-)'s World")
        return area .. " is sealed. " .. hints.known[area],
            { title = area .. " is sealed", line = where and ("Its pass is at " .. where .. " (" .. world .. ")")
                                                     or hints.known[area]:sub(1, 60), ready = true }
    end
    local text = "The way into " .. area .. " is sealed: it needs " .. pass .. "."
    local points, cost = (AP_HintPoints and AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if not points then return text, { title = area .. " is sealed", line = "It needs " .. pass .. "." } end
    points, cost = tonumber(points), tonumber(cost)
    hints.offer, hints.offeredAt = area, CLOCK.now()
    -- Both cases say what the player has and what a hint costs (the user, 2026-11-04), with the configured key.
    if points >= cost then
        return text .. " Press " .. hints.key .. " for a hint: you have " .. points .. " points, a hint costs " .. cost .. ".",
            { title = area .. " is sealed", line = hints.key .. " for a hint: " .. points .. " points, a hint costs " .. cost,
              have = points, cost = cost, ready = true }
    end
    return text .. " Not enough points for a hint: you have " .. points .. " points, a hint costs " .. cost .. ".",
        { title = area .. " is sealed", line = "Not enough points for a hint: " .. points .. " of " .. cost,
          have = points, cost = cost, ready = false }
end
local function askHint()
    local area = hints.offer
    if not area or CLOCK.now() - hints.offeredAt > WAIT.hintOffer then return end
    local points, cost = (AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if points and tonumber(points) < tonumber(cost) then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, CLOCK.now()
    AP_Say("!hint " .. WALLS.passName(area))
    notify("Asking the Archipelago server where " .. WALLS.passName(area) .. " is...")
end
-- Key binds run off the game thread: they only hand over a function made here, once (no new function there).
local function hintKey()
    if WORLD.takeYes() then return end
    local ok, err = pcall(askHint)
    if not ok then log("hint error: " .. tostring(err)) end
end
if RegisterKeyBind and Key and Key[hints.key] then
    RegisterKeyBind(Key[hints.key], function() ExecuteInGameThread(hintKey) end)
end

-- Death Link (the slot's death_link option): dying sends a death to everyone linked; a death from them faints the
-- player. A death the link caused is not sent back, and neither counts towards nor resets the amnesty.
-- How it faints (the user, 2026-11-06: a linked death killed them but dropped nothing, unlike a normal death). The
-- game's self-kill (PalPlayerController:SelfKillPlayer) dies as EPalDeadType Sucide and skips the world's Death Penalty.
-- dev.17 test (2026-11-07): DamageReactionComponent_ProcessDeath_ToServer_ToSelfPlayer did not faint the player at all.
-- So, in order, each tried until one works, and the one that worked kept for the session (death.route):
--   1. "poison": lethal slip damage through the player's own damage component (SlipDamage, EPalDeadType Poison 5,
--      shield ignored and cleared), an ordinary death to the game, so its Death Penalty should apply. UNTESTED.
--   2. "penalty drop": the Death Penalty manager's own DropDeathPenaltyChest(player) (the bag on the ground), then the
--      self-kill; skipped when the world's Death Penalty is None (the drop might not check it itself). UNTESTED.
--   3. "self-kill": nothing dropped, but the death is never lost.
-- A route that ran without error is checked at the next run (~2 s): still alive means it failed, and the next is tried.
local ROUTES = { "poison", "penalty drop", "self-kill" }
local function deathPenalty(ps)                       -- the world's EPalOptionWorldDeathPenalty (0 None), or nil
    local ok, v = pcall(function()
        return tonumber(StaticFindObject("/Script/Pal.Default__PalUtility"):GetOptionSubsystem(ps).OptionWorldSettings.DeathPenalty)
    end)
    return ok and v or nil
end
local function faint(route, ps)
    local frame = PLAYER.frame()
    local pc = (frame and frame.pc) or FindFirstOf("PalPlayerController")   -- this update's controller (playerContext)
    if route == 1 then
        local pawn = pc:K2_GetPawn()
        pawn.DamageReactionComponent:SlipDamage(999999, true, 5, true)
    elseif route == 2 then
        local penalty = deathPenalty(ps)
        if penalty == 0 then
            log("death link: the world's Death Penalty is None: nothing to drop")
        else
            local pawn = pc:K2_GetPawn()
            StaticFindObject("/Script/Pal.Default__PalUtility"):GetDeathPenaltyManager(ps):DropDeathPenaltyChest(pawn)
            log("death link: dropped the Death Penalty's bag (the world's Death Penalty " .. tostring(penalty) .. ")")
        end
        pc:SelfKillPlayer()
    else
        pc:SelfKillPlayer()
    end
end
-- Faints by death.route; a route that errors falls to the next at once. Returns ok, error, the route's name.
local function faintNow(ps)
    local ok, err
    while true do
        ok, err = pcall(faint, death.route, ps)
        if ok or death.route >= #ROUTES then break end
        log("death link: " .. ROUTES[death.route] .. " failed: " .. tostring(err) .. "; trying " .. ROUTES[death.route + 1])
        death.route = death.route + 1
    end
    return ok, err, ROUTES[death.route]
end
local function deathLink(ps)
    if not death.on then return end
    local okd, dead = pcall(function() return ps:IsPlayerDead() end)
    if not okd then return end
    if death.pending then
        local cause = death.pending
        death.pending = nil
        if dead then
            once("dlworked" .. death.route, "death link: the " .. ROUTES[death.route] .. " worked")
        elseif death.route < #ROUTES then
            local failed = ROUTES[death.route]
            death.route = death.route + 1
            death.caused = CLOCK.now()
            local ok, err, how = faintNow(ps)
            if ok and death.route < #ROUTES then death.pending = cause end
            log("death link: the " .. failed .. " did not faint the player; used the " .. how .. ": " .. cause
                .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
            return
        end
    end
    -- An incoming death waits for a settled world with a character (as the traps do), then counts as late.
    local character = safe(function() return ps:GetPawn() end)
    local settled = WORLD.settled() and character and character:IsValid()
    if death.incoming and (settled or CLOCK.now() - death.at > WAIT.deathLate) then
        local cause = death.incoming
        death.incoming = nil
        if CLOCK.now() - death.at > WAIT.deathLate then
            log("death link received while no player was in the world (" .. (CLOCK.now() - death.at) .. " updates ago): not applied: " .. cause)
        elseif not dead then
            death.caused = CLOCK.now()
            local ok, err, how = faintNow(ps)
            if ok and death.route < #ROUTES then death.pending = cause end
            notify("Death Link: " .. cause)
            log("death link received: " .. cause .. " (" .. how .. ")" .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
        end
    end
    if dead and not death.wasDead then
        if death.caused and CLOCK.now() - death.caused < WAIT.ownDeath then
            log("death link: this death came from the link, not sent back")
        else
            -- Amnesty (slot data options.death_link_amnesty): that many of your own faints are forgiven before one is
            -- sent. The count is kept in the seed's save file, so quitting does not reset it.
            local amnesty = slotNumber("options.death_link_amnesty", 0)
            if ap.forgiven < amnesty then
                ap.forgiven = ap.forgiven + 1
                writeSave()
                local left = amnesty - ap.forgiven
                notify(left > 0 and string.format("Death Link: faint forgiven (%d more before one is sent).", left)
                                 or "Death Link: faint forgiven. The next one is sent to the multiworld.")
                log(string.format("death link: forgiven %d of %d", ap.forgiven, amnesty))
            else
                ap.forgiven = 0
                writeSave()
                local cause = cfg.slot .. " fainted in Palworld."
                AP_Bounce(string.format('{"time":%d,"source":"%s","cause":"%s"}', os.time(), jsonText(cfg.slot),
                    jsonText(cause)), "DeathLink")
                notify("Death Link: your death was sent to the multiworld.")
                log("death link sent")
            end
        end
    end
    death.wasDead = dead
end

-- Other mods' techs (techscan.lua): read once a session, as soon as the player's tech data is there. Their own techs stay
-- normal research; the report goes to the log and mod_techs.txt.
local function scanTechs(td)
    techScan.tries = techScan.tries + 1
    local ok, report, why = pcall(TECHSCAN.scan, td, D)
    if not ok then
        techScan.tries = math.huge
        log("tech scan error: " .. tostring(report))
        return
    end
    if not report then
        if techScan.tries == TECH_SCAN_TRIES then log("tech scan: gave up: " .. tostring(why)) end
        return
    end
    techScan.report = report
    local lines = TECHSCAN.lines(report)
    for _, l in ipairs(lines) do log(l) end
    local f = io.open(modDir .. "\\mod_techs.txt", "w")
    if f then
        f:write("# PalworldArchipelago " .. VERSION .. ": techs other mods added, changed or removed (vanilla is 1.0.5)\n",
                table.concat(lines, "\n"), "\n")
        f:close()
    end
    if #report.added > 0 then notify(#report.added .. " tech(s) from other mods: they stay normal research.") end
    if #report.warn > 0 then
        notify(#report.warn .. " shop tech(s) moved to much higher levels by other mods; this seed's logic expects vanilla levels.")
    end
end

-- A shop slot whose tech another mod removed can never be bought: send its check, so no one waits on it forever.
-- Once a seed, as soon as the scan has found them and the connection is ready.
local function sendRemovedSlots()
    if not (ap.ready and techScan.report and not techScan.sent) then return end
    techScan.sent = true
    local locs = {}
    for _, id in ipairs(techScan.report.removed) do
        local loc = D.shop[id] and D.shop[id].loc            -- (a tech this seed leaves as research has no check)
        if loc and not ap.checked[loc] then
            locs[#locs + 1] = loc
            ap.bought[loc] = true
        end
    end
    if #locs > 0 then
        sendChecks(locs)
        notify(#locs .. " shop slot(s) can't be bought (another mod removed their techs): their checks were sent.")
    end
end

-- The parts of one update, in the order update() runs them.

-- The modules that keep their own timers: the test tools' probes, the hint pop-up, the debuff icons.
local function stepSmallModules()
    local oktt, errtt = pcall(TEST_TOOLS.update)
    if not oktt then onceErr("testtools", errtt, "test tools error: " .. tostring(errtt)) end
    local okp, errp = pcall(POPUP.tick, CLOCK.now())
    if not okp then onceErr("popup", errp, "hint pop-up error: " .. tostring(errp)) end
    local okdb, errdb = pcall(DEBUFFS.tick, CLOCK.now())
    if not okdb then once("debuffs" .. tostring(errdb), "debuffs error: " .. tostring(errdb)) end
end

-- Everything the server sent since the last update, one event line at a time (onEvent).
local function readEvents()
    P.start("poll")
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then log("event error: " .. tostring(err) .. " in " .. line) end
    end
    P.stop("poll")
end

-- The title and Esc menus, the mailbox and the crate window.
local function updateWindows(ctx)
    P.start("menu")
    local okm, errm = pcall(MENU.update, ctx)
    -- The un-hover event may not come when the menu closes under the pointer: a card can't be hovered with no menu.
    if hoveredTech and MENU.mainMenuUp() == false then hoveredTech = nil end
    P.stop("menu")
    if not okm then onceErr("menu", errm, "menu error: " .. tostring(errm)) end
    P.start("mail")
    local okx, errx = pcall(MAIL.update, ctx)
    local okw, errw = pcall(CWIN.update)
    if not okw then once("cwin" .. tostring(errw), "crate window error: " .. tostring(errw)) end
    P.stop("mail")
    if not okx then onceErr("mail", errx, "mailbox error: " .. tostring(errx)) end
end

-- Ready once the first batch of items is in, a moment after connecting: only then is anything locked.
local function markReady()
    if ap.status ~= "connected" or ap.ready or CLOCK.now() - ap.connectedTick < WAIT.firstItems then return end
    ap.ready = true
    ap.shopOpen = true
    local n = 0
    for _ in pairs(ap.items) do n = n + 1 end
    log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
end

-- Load the menus' classes up front, once ready, so their hooks are in place before the Technology menu first opens
-- (hooked mid-draw, a bought card could flip to researched and stick on the game's white unlock flash).
local function preloadMenuClasses()
    if not ap.ready or preloaded then return end
    preloaded = true
    ExecuteInGameThread(function()
        for _, h in ipairs(SHOP_HOOKS) do
            if not h.native and not h.done then
                local class = h.path:gsub(":.*$", "")          -- the hook's "<class path>:<function>"
                local ok, err = pcall(LoadAsset, (class:gsub("_C$", "")))
                if not ok then once("preload" .. class, "could not preload " .. class .. ": " .. tostring(err)) end
            end
        end
    end)
end

-- The tech-scan phase: other mods' techs, once per cycle until the player's tech data is there.
local function phaseTechScan()
    if techScan.report or techScan.tries >= TECH_SCAN_TRIES then return end
    P.start("scan")
    local td = safe(function() local ps = playerState(); return ps and ps:GetTechnologyData() end)
    if td and safe(function() return td:IsValid() end) then scanTechs(td) end
    P.stop("scan")
    sendRemovedSlots()                             -- (in the update the scan found them)
end


-- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that hint
-- with the hint key (once per area every WAIT.wallNotice).
local function noticeLockedWall(pawn)
    local okn, area = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        return WALLS.lockedNear(loc.X, loc.Y, ap.passes)
    end)
    if not (okn and area) or (hints.shown[area] or -1e9) + WAIT.wallNotice > CLOCK.now() then return end
    hints.shown[area] = CLOCK.now()
    local line, info = wallNotice(area)
    notify(line)
    local okp, errp = pcall(POPUP.show, info, CLOCK.now())
    if not okp then log("hint pop-up error: " .. tostring(errp)) end
end

-- The open areas the player stands in, remembered for the map (an unlocked area not yet visited shows an open stamp).
local function rememberVisited(pawn)
    local okv, here = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        return WALLS.areaAt(loc.X, loc.Y)
    end)
    if not (okv and here) or ap.visited[here] or here == "Open sea" then return end
    if here == WALLS.start or ap.passes[here] then
        ap.visited[here] = true
        log("visited " .. here)
    end
end

-- A player inside a locked area (loaded there, or past a wall) for SENT_HOME_AFTER looks in a row goes back to the
-- starting area.
local function sendHomeIfLocked(pawn)
    local okl, where = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        return WALLS.lockedAround(loc.X, loc.Y, ap.passes)
    end)
    lockedTicks = (okl and where) and lockedTicks + 1 or 0
    if lockedTicks < SENT_HOME_AFTER then return end
    lockedTicks = 0
    local h = WALLS.home
    local okt, errt = pcall(function()
        pawn:K2_TeleportTo({ X = h[1], Y = h[2], Z = h[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    log("inside locked " .. tostring(where) .. ": sent home" .. (okt and "" or (" FAILED: " .. tostring(errt))))
    notify(tostring(where) .. ((ap.beyond and ap.beyond[where]) and " is beyond this seed's goal."
        or " is locked until its pass arrives.") .. " Back to " .. WALLS.start .. ".")
end

-- Area locks: walls on the borders of areas whose pass has not arrived (only in a seed with area locks on), and the
-- map. Nothing happens for WAIT.settle after a world loads: spawning into a world still loading can crash the game.
local function updateAreaLocks(pawn)
    if WORLD.key() and WORLD.seedWorld() == false then
        pcall(WALLS.mapOff)                        -- (C++ would show the seed's map here)
    end
    if not (WORLD.settled() and WORLD.seedWorld()) then return end
    local on = areaLocks
    -- Ctrl+7 (perf test tools) can hold the walls in a test state: nothing is raised, lowered or checked then.
    local held = P.walls ~= "full"
    P.start("walls")
    if not held then
        local ok, err = pcall(WALLS.update, on, ap.passes, pawn)
        if not ok then onceErr("walls", err, "walls error: " .. tostring(err)) end
    end
    P.stop("walls")
    P.start("map")
    local ok, err = pcall(WALLS.updateMap, on, ap.passes, pawn)
    P.stop("map")
    if not ok then onceErr("map", err, "map error: " .. tostring(err)) end
    local up, all = WALLS.count()
    if up > 0 and not wallsLogged then
        wallsLogged = true
        log("area locks: raising walls (" .. all .. " border pieces)")
    end
end

-- Whether the area locks act on the player this update: ready (a pawn was read), in the seed's world once it has
-- settled, and with area locks on. Inside a stage (a dungeon, a tower's arena) the map position says nothing about
-- the area the player entered it from: no notice, no visit and no sending home there.
local function areaLocksApply(pawn)
    if not (pawn and WORLD.settled() and WORLD.seedWorld() and areaLocks) then return false end
    local okS, inStage = pcall(function() return playerState():IsInStage() end)
    return not (okS and inStage)
end

-- The areas phase: the open areas the player stands in, and sending the player home from inside a locked one.
local function phaseAreas(pawn)
    if not areaLocksApply(pawn) then return end
    rememberVisited(pawn)
    -- Not while Ctrl+7 holds the walls without collision or removed: a player could drift across a border then.
    if P.walls == "full" then sendHomeIfLocked(pawn) end
end

-- The wall-notice phase: the chat notice and hint offer at a locked wall the player walks up to.
local function phaseWallNotice(pawn)
    if not areaLocksApply(pawn) then return end
    noticeLockedWall(pawn)
end

-- The records phase: trap timers, the seed's-world check, the game's records (checks and the goal).
local function phaseRecords()
    P.start("e7")
    local ps = playerState()
    local pawn = ps and safe(function() return ps:GetPawn() end)
    -- A running Slow Trap or Fool Trap ends on time whether or not the connection is up.
    local okk, errk = pcall(TRAPS.tick, { tick = CLOCK.now(), pawn = pawn })
    if not okk then onceErr("trapsk", errk, "traps error: " .. tostring(errk)) end
    if ps and ap.ready then WORLD.checkWorld(ps) end
    if ps and ap.ready and WORLD.seedWorld() then
        P.start("rec")
        pollRecords(ps, CLOCK.now())
        P.stop("rec")
    end
    P.stop("e7")
    if ps and ap.ready then P.records(ps) end
end

-- The items phase, in the seed's world only: techs and items; once the world has settled, the run style's sync and the
-- held notices; Death Link; traps.
local function phaseItems()
    if not (ap.ready and WORLD.seedWorld()) then return end
    local ps = playerState()
    if not ps then return end
    P.start("e7")
    P.start("techs")
    local changed = syncTechs(ps)
    P.stop("techs")
    if changed then refreshTree() end
    local td = safe(function() return ps:GetTechnologyData() end)
    if td and td:IsValid() then applyItems(ps) end    -- (items wait while the tech data is still loading)
    if WORLD.settled() then
        local oks, news = pcall(SYNC.apply, ps, AP_SlotData, WORLD.key(), noticeLater)
        if not oks then
            onceErr("sync", news, "sync error: " .. tostring(news))
        elseif news then
            writeSave()
        end
        local okl, errl = pcall(showLater, safe(function() return ps:GetPawn() end))
        if not okl then onceErr("later", errl, "notice error: " .. tostring(errl)) end
    end
    local okdl, errdl = pcall(deathLink, ps)
    if not okdl then onceErr("death", errdl, "death link error: " .. tostring(errdl)) end
    -- Traps fire only once the world has settled (the walls' count), never while fainted or in the mailbox.
    local okt, errt = pcall(function()
        local pawn = safe(function() return ps:GetPawn() end)
        local okd, dead = pcall(function() return ps:IsPlayerDead() end)
        -- (Not WORLD.settled(): a pawn that is there but not valid makes the key false, which counts as settled here.)
        TRAPS.update({ tick = CLOCK.now(), ps = ps, pawn = pawn, settled = WORLD.key() ~= nil and WORLD.age() >= WAIT.settle,
                       dead = not okd or dead, busy = MAIL.busy() })
    end)
    if not okt then onceErr("traps", errt, "traps error: " .. tostring(errt)) end
    P.stop("e7")
end

-- Which function runs in which phase of the cycle. This table is the whole schedule: to add timed work, add a phase to
-- PHASE (clock.lua) and a row here. Each function tests for itself whether it may run (connected, world settled).
-- Two of the seven updates in a cycle carry no phase.
local PHASE_STEPS = {
    [PHASE.records] = phaseRecords,         -- trap timers, the seed's-world check, the game's records
    [PHASE.techScan] = phaseTechScan,       -- other mods' techs, until found
    [PHASE.items] = phaseItems,             -- techs, items, held notices, Death Link, traps
    [PHASE.areas] = phaseAreas,             -- visited areas; sent home from inside a locked area
    [PHASE.wallNotice] = phaseWallNotice,   -- the chat notice and hint offer at a locked wall
}

-- Runs this update's phase, if it has one. `pawn` is the one the world step read (nil before ready).
local function runPhase(pawn)
    local step = PHASE_STEPS[CLOCK.now() % CLOCK.CYCLE]
    if step then
        step(pawn)
    end
end

-- One core update (coreTick, every UPDATE_MS on the game thread): what runs every time, then this update's phase.
local function update(ctx)
    CLOCK.advance()
    SOON.run()
    stepSmallModules()
    readEvents()
    registerLazyHooks()
    updateWindows(ctx)
    markReady()
    preloadMenuClasses()
    P.start("cards")
    refreshCards()
    P.stop("cards")
    sendRemovedSlots()
    local pawn = nil
    if ap.ready then
        pawn = WORLD.note()
        updateAreaLocks(pawn)
    end
    runPhase(pawn)
end

-- Ctrl+0 (perf test tools): after each update, the per-update load 6dd356e had and this build no longer has, so one
-- session can compare old and new. Results are thrown away; the game sees nothing it did not see in 6dd356e (the cards
-- are labelled again with the same text). An approximate replay of the cost, not the old code:
local function oldLoad(ctx)
    P.start("legacy")
    FindFirstOf("PalPlayerController")                   -- the menu's own controller lookup
    if ctx.pawn then FindAllOf("WBP_TitleMenu_C") end    -- the title menu, looked for in a world too
    if ap.ready and isPhase(PHASE.records) then FindAllOf("PalPlayerState") end     -- a second player-state walk
    if MAIL.viewOpen() then                              -- the chest view's own player and window lookups
        FindFirstOf("PalPlayerController")
        FindAllOf("PalPlayerState")
        FindAllOf("WBP_ItemChest_C")
    end
    if WALLS.mapShown() then FindFirstOf("PalGameInstance") end
    AP_SlotData("options.area_locks")
    WALLS.oldSweep()                                     -- every raised piece checked every update
    for _, card in ipairs(lastCards or {}) do            -- every card labelled every update
        if card:IsValid() then
            local key = safe(function() return tostring(card:GetAddress()) end) or card
            pcall(relabel, card, key, true)
        end
    end
    if ap.ready and isPhase(PHASE.items) then writeSave(true) end   -- the save written whether or not it changed
    P.stop("legacy")
end

-- The core update, on the game thread. LoopAsync's callback runs on another thread over the same Lua state, so it does
-- nothing there but hand over this function, made once (2026-11-08: two crashes with the 08E98397 stack came from a
-- 33 ms loop that ran Lua on that thread; building a new closure there every time is the same risk, smaller).
local function coreTickBody()
    -- Ctrl+8 (perf test tools) pauses the whole update, the controller walk included, so the pause takes away
    -- all of the mod's per-update work. That walk is timed as "ctx" and counted in the update's "lua" time.
    local ran = not P.paused
    local ctx = nil
    if ran then
        P.start("ctx")
        local okc, c = pcall(playerContext)
        if okc then ctx = c else onceErr("context", c, "player lookup error: " .. tostring(c)) end
    end
    ctx = ctx or { playerState = findPlayerState }
    PLAYER.setFrame(ctx)
    P.frameBegin(ctx, ran and P.stop("ctx") or nil)
    if ran then
        local ok, err = pcall(update, ctx)
        if not ok then onceErr("update", err, "update error: " .. tostring(err)) end
        if P.legacy then pcall(oldLoad, ctx) end
        P.world(ctx)
    end
    PLAYER.setFrame(nil)
    P.frameEnd(ran)
end
-- The engine's frame number, or nil when it can't be read. The timer hands one update to the game thread every
-- UPDATE_MS whether or not the last has run, so after a stall (a world loading) the queued ones arrive in one frame.
local kismet = nil
local function engineFrame()
    if not (kismet and kismet:IsValid()) then
        kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end
    if not kismet then return nil end
    local ok, n = pcall(function() return kismet:GetFrameCount() end)
    return ok and tonumber(n) or nil
end
local lastFrame = nil         -- the engine frame the last update ran in
-- Never inside a research hook, nor inside itself (see guarded(), above the research hooks), and at most once a frame:
-- waits are counted in updates, and updates run back to back would use them up with no time passing.
local function coreTick()
    if inHook or inTick then
        once("nested", "update skipped: it came inside a hook or itself (UE4SS ran it nested)")
        return
    end
    local f = engineFrame()
    if f and f == lastFrame then return end
    lastFrame = f
    inTick = true
    local ok, err = pcall(coreTickBody)
    inTick = false
    if not ok then onceErr("coreTick", err, "update error: " .. tostring(err)) end
end
-- What a world change forgets, in this order: whether this world is the seed's (looked at again in the records phase
-- before any wall goes up; a yes is for the world it was asked in), the pop-up or goal banner (it went with the old
-- world's HUD), the walls, and the skip of the tech list's comparison (another world's list is compared in full).
WORLD.onChange(WORLD.resetSeedWorld)
WORLD.onChange(POPUP.forget)
WORLD.onChange(WALLS.reset)
WORLD.onChange(TECH_LOCK.forgetSeen)

-- Every UPDATE_MS (the harness's thread-rule check reads this loop: keep its shape).
LoopAsync(UTIL.UPDATE_MS, function()
    ExecuteInGameThread(coreTick)
    return false
end)

-- Test tools: only with test_tools=1 in config.txt (see test_tools.lua).
if cfg.test_tools == "1" then
    local okt, errt = pcall(TEST_TOOLS.install)
    if not okt then log("test tools not loaded: " .. tostring(errt)) end
end
