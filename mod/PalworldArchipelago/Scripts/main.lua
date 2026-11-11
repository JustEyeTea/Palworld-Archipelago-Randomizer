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

-- The core update runs every UPDATE_MS (the LoopAsync at the end of this file). Waits are counted in updates;
-- updates() turns seconds into that count.
local updates = UTIL.updates
local WAIT = {
    firstItems = updates(1.5),  -- after connecting, before anything is locked: the first batch of items arrives
    settle = updates(5),        -- after a world loads, before any wall: spawning into a world still loading can crash
    goal = updates(120),        -- the goal waits at most this long for the player to leave the boss's arena
    hintOffer = updates(60),    -- a hint offered at a wall can be taken for this long
    hintAnswer = updates(15),   -- the server's answer to a hint the player asked for is shown if it comes within this
    wallNotice = updates(120),  -- the same wall's notice comes again only after this
    heldNotice = updates(60),   -- notices held through a loading screen show after this even if the player hasn't moved
    deathLate = updates(6),     -- a linked death older than this (received at the title, or loading) is dropped
    ownDeath = updates(15),     -- a death this soon after the link fainted the player came from the link
}
-- The heavier work runs on one update in CYCLE (2.1 s), spread over these phases so no one frame carries it all.
-- isPhase() (below, with the update counter) says which phase this update is.
local CYCLE = 7
local PHASE = {
    records = 0,                -- trap timers, the seed's-world check, the game's records (checks and the goal)
    techScan = 1,               -- other mods' techs, until found
    items = 2,                  -- techs, items, the run style's sync, held notices, Death Link, traps
    areas = 3,                  -- visited areas; sent home from inside a locked area
    wallNotice = 5,             -- the chat notice and hint offer at a locked wall
}
local TECH_SCAN_TRIES = 40      -- one try per cycle until the player's tech data is there: about 84 s
local SENT_HOME_AFTER = 2       -- looks in a row (one per cycle) inside a locked area before the player is sent home

-- Slot data values arrive as text (AP_SlotData): a flag is "1" or "true", a number its digits.
local function slotFlag(path)
    local v = AP_SlotData(path)
    return v == "1" or v == "true"
end
local function slotNumber(path, default) return tonumber(AP_SlotData(path)) or default end

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

-- config.txt: server=archipelago.gg:12345 / slot=YourName / password=
local function readConfig()
    local cfg = {}
    local f = io.open(modDir .. "\\config.txt", "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then cfg[k] = v end
    end
    f:close()
    return cfg
end

if type(AP_Connect) ~= "function" then
    log("APConnector is not installed: no AP_* functions. Install ue4ss/Mods/APConnector and enable it in mods.txt.")
    return
end
local cfg = readConfig()
-- The key that asks for a hint at a sealed wall, and says yes to tying a seed to a world with progress.
local HINT_KEY = ((cfg.hint_key or ""):match("^%s*(%w+)%s*$") or "H"):upper()
if Key and Key[HINT_KEY] == nil then
    log("hint_key=" .. HINT_KEY .. " is not a key UE4SS knows: using H")
    HINT_KEY = "H"
end
-- The performance probe (perf_log=1; perf.lua). Installed before any hook is registered, so it counts them all.
local P = require("perf")
P.install(cfg, { wallsCount = function() return (WALLS.count()) end, setWalls = function(mode) WALLS.perfMode(mode) end,
                 mailOpen = function() return MAIL.viewOpen() end })
-- The test tools (test_tools.lua). update() steps their probes every update; they stay idle unless installed, which
-- only test_tools=1 in config.txt does (at the end of this file).
local TEST_TOOLS = require("test_tools")
-- Every key config.txt can hold. The title menu rewrites the file with these keys only (comments are not kept), so a
-- new setting must be listed here or it is lost the next time the player connects from the menu. The harness checks
-- that every cfg.<key> the mod reads is listed.
local CONFIG_KEYS = {
    "server", "slot", "password", "servers", "hint_key",
    "mailbox", "mailbox_key", "mailbox_view", "mailbox_slots",
    "test_tools", "perf_log", "perf_no_bp_hooks",
    "wall_skin", "wall_tiling", "wall_scroll", "wall_radius", "wall_fade",
    "map_cpp", "map_chart", "map_icons", "map_regions", "map_style",
}
local function writeConfig()
    local f = io.open(modDir .. "\\config.txt", "w")
    if not f then
        log("could not write config.txt")
        return
    end
    for _, k in ipairs(CONFIG_KEYS) do
        if cfg[k] then f:write(k .. "=" .. cfg[k] .. "\n") end
    end
    f:close()
end

-- tech id <-> shop slot
local SLOT_TECH = {}
for tech, s in pairs(D.shop) do SLOT_TECH[s.loc] = tech end
-- Bumped whenever what syncTechs compares against changes (the techs items unlocked, or which techs are the shop's),
-- so it can skip the comparison while neither that nor the game's list has changed.
local techsVersion = 0

-- Techs a seed leaves as normal research (slot data research_techs, e.g. décor with tech_checks no_decor): they leave
-- D.shop for D.research, so nothing locks, labels or sends them. Set again on every connection.
D.research = {}
local function setResearch(list)
    for tech, s in pairs(D.research) do D.shop[tech], SLOT_TECH[s.loc] = s, tech end
    D.research = {}
    techsVersion = techsVersion + 1
    for tech in (list or ""):gmatch("[^,]+") do
        local s = D.shop[tech]
        if s then D.research[tech], D.shop[tech], SLOT_TECH[s.loc] = s, nil, nil end
    end
    local n = 0
    for _ in pairs(D.research) do n = n + 1 end
    if n > 0 then log(n .. " tech(s) are normal research in this seed (not checks)") end
end
-- The last seed's list is kept in research.txt, so its normal-research techs can be researched before the first
-- connection of a session too (the server down, or playing before connecting).
local function keepResearch(list)
    local f = io.open(modDir .. "\\research.txt", "w")
    if not f then log("could not write research.txt"); return end
    f:write((list or "") .. "\n")
    f:close()
end
do
    local f = io.open(modDir .. "\\research.txt", "r")
    if f then
        setResearch(f:read("l"))
        f:close()
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Archipelago state. The server is the truth: on every connection it sends all items received so far and every
-- location already checked, so most of this is rebuilt each time. Only one-off effects (points, bundles, traps) need
-- memory: the index of the last item applied, the mailbox's contents, the traps still to fire and the Death Link amnesty
-- count, kept per seed and slot in a save file next to the mod.
local ap = {
    status = "disconnected",
    ready = false,        -- connected and the first batch of items is in: safe to lock techs
    shown = false,        -- the shop has been labelled at least once (cards keep their labels through reconnects)
    connectedTick = nil,
    me = nil,             -- our slot number
    seed = nil,
    checked = {},         -- location id -> true
    bought = {},          -- location id -> true: checks the mod sent itself (purchases, removed slots), not read
                          -- from the game's records; sent again on every connection and kept in the save file
    sent = {},            -- location id -> true: sent this session (waiting for the server to confirm)
    scouted = {},         -- location id -> { item, player, game, flags, own }
    items = {},           -- index -> item id, every item received
    techs = {},           -- tech id -> true: unlocked by an item
    passes = {},          -- area -> true
    level = 0,            -- the player's level, as last read
    beaten = {},          -- tower boss type -> true
    given = -1,           -- highest item index whose one-off effect has been applied
    from = {},            -- index -> the player who sent a trap item (nil: found in our own world)
    forgiven = 0,         -- own faints forgiven since a death was last sent (Death Link amnesty; in the save file)
    visited = {},         -- area -> true: open areas the player has stood in (the map's open stamps; in the save file)
    goalSent = false,     -- sent on this connection (cleared on connecting, so a goal lost on the wire goes again)
    goalShown = false,    -- the goal's banner and notice have been shown (once per seed; in the save file)
    world = nil,          -- the world save this seed is played in (its folder name), kept in the save file
    slotName = nil,       -- the slot whose progress is in memory, set with the seed on connecting (names the save)
    beyond = {},          -- area -> true: beyond the seed's goal (slot data beyond_goal_areas)
    beyondOpen = false,   -- those areas are open from the start (options.beyond_goal: open), else sealed for good
}
WALLS.visited = ap.visited                -- (the same table: the map reads it)

-- The save file holds one "kind=value" line each, written in this order (loadSave hands each line to its owner):
--   given=12                  the last item index whose one-off effect was applied (items are numbered from 0)
--   world=<folder>            the world save this seed is played in (checkWorld)
--   deaths=1                  own faints forgiven since a death was last sent (Death Link amnesty)
--   goal=shown                the goal's banner and notice have been shown
--   bought=123,456            checks the mod sent itself (ap.bought): sent again on connecting
--   visited=Area|Area         open areas the player has stood in (the map's open stamps)
--   traps=Slow Trap|14,...    traps.lua: traps still to fire, each with its item index
--   mail=id:n,...             mailbox.lua: the mailbox's items
--   crates=kind,... and cratebag=id:n,...    crates.lua: unopened crates; crate gear the bag refused
--   syncbase=Field:value,...  sync.lua: the world's own rates from before the run style changed them
--   end                       the last line: the file was written whole
-- Named after the slot whose progress is in memory (set with the seed on connecting), not cfg.slot: the title menu
-- changes that before the server has said yes, and a refused slot must not get this one's progress.
local function saveFile()
    if not ap.seed then return nil end
    return modDir .. "\\save-" .. ap.seed .. "-" .. (ap.slotName:gsub("[^%w_%-]", "_")) .. ".txt"
end
-- The file is written whole to save-...txt.tmp, then put in place, and ends with "end": a write cut short (a crash, a
-- power cut) leaves either the old file or a complete .tmp, never half a file. Older saves have no "end" line.
local function readSave(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines, complete = {}, false
    for line in f:lines() do
        if line == "end" then complete = true else lines[#lines + 1] = line end
    end
    f:close()
    return lines, complete
end
local function loadSave()
    local path = saveFile()
    if not path then return end
    local lines, complete = readSave(path)
    local tmp, tmpComplete = readSave(path .. ".tmp")
    if tmp and tmpComplete and not complete then
        log("save " .. path .. ": " .. (lines and "incomplete" or "missing") .. "; using the copy written last (.tmp)")
        lines = tmp
    end
    if not lines then return end
    for _, line in ipairs(lines) do
        local n = line:match("^given=(%-?%d+)")
        local w = line:match("^world=(.+)$")
        local d = line:match("^deaths=(%d+)")
        local v = line:match("^visited=(.*)$")
        local b = line:match("^bought=(.*)$")
        if line == "goal=shown" then
            ap.goalShown = true
        elseif n then
            ap.given = tonumber(n)
        elseif w then
            ap.world = w
        elseif d then
            ap.forgiven = tonumber(d)
        elseif v then
            for area in v:gmatch("[^|]+") do ap.visited[area] = true end
        elseif b then
            for loc in b:gmatch("%d+") do ap.bought[tonumber(loc)], ap.checked[tonumber(loc)] = true, true end
        elseif not TRAPS.load(line) and not CRATES.load(line) and not SYNC.load(line) then
            MAIL.load(line)
        end
    end
    local kinds, items = MAIL.count()
    log("save " .. path .. ": items applied up to index " .. ap.given .. "; " .. CRATES.count() .. " crate(s); mailbox "
        .. items .. " item(s) of " .. kinds .. " kind(s); " .. #TRAPS.queue .. " trap(s) waiting; " .. ap.forgiven
        .. " faint(s) forgiven; world " .. tostring(ap.world))
end
-- Written only when its text changed (it was rewritten every 7th update, 2.1 s, even when nothing had changed: an
-- estimated 0.2-2 ms each time for creating, writing and closing the file; more with antivirus; unmeasured). The text
-- is compared, not ap.given alone: mail that arrives (MAIL.add) is saved only by this write. always: write it anyway
-- (the perf probe's Ctrl+0 replay of the old load).
local lastSave = nil          -- path and text of the last write: the same again is not written
local saveWarned = false      -- the player was told the save file can't be written (once a session)
local notify                  -- a notice in the game's chat (defined with the game side, below)
local function writeSave(always)
    local path = saveFile()
    if not path then return end
    -- One write holds everything that must agree: what was applied, and the traps and mailbox items it left.
    local been = {}
    for area in pairs(ap.visited) do been[#been + 1] = area end
    table.sort(been)
    local bought = {}
    for loc in pairs(ap.bought) do bought[#bought + 1] = loc end
    table.sort(bought)
    local text = table.concat({
        "given=" .. ap.given .. "\n",
        ap.world and ("world=" .. ap.world .. "\n") or "",
        "deaths=" .. ap.forgiven .. "\n",
        ap.goalShown and "goal=shown\n" or "",
        #been > 0 and ("visited=" .. table.concat(been, "|") .. "\n") or "",
        #bought > 0 and ("bought=" .. table.concat(bought, ",") .. "\n") or "",
        TRAPS.serialize(), MAIL.serialize(), CRATES.serialize(), SYNC.serialize(),
        "end\n",
    })
    if not always and lastSave == path .. "\n" .. text then return end
    P.start("save")
    local f, errOpen = io.open(path .. ".tmp", "w")
    if not f then
        P.stop("save")
        if not saveWarned then
            saveWarned = true
            log("could not write " .. path .. ".tmp: " .. tostring(errOpen))
            notify("Can't write the mod's save file: items you receive will be given again next time."
                .. " Check that the game may write to its Mods folder.")
        end
        return
    end
    local okw = f:write(text)
    f:close()
    if not okw then P.stop("save"); once("savewrite", "could not write " .. path .. ".tmp"); return end
    os.remove(path)                                   -- (Windows will not rename over a file)
    local okr, err = os.rename(path .. ".tmp", path)
    P.stop("save")
    if not okr then once("saverename", "could not put the save in place: " .. tostring(err)); return end
    lastSave = path .. "\n" .. text
    P.count("save")
end

------------------------------------------------------------------------------------------------------------------------
-- The game side.
local function findPlayerState()
    local all = FindAllOf("PalPlayerState")
    if not all then return nil end
    for _, ps in ipairs(all) do if ps:IsValid() then return ps end end
end
-- The player for this update. Each FindAllOf walks the whole object array (UE4SS has no class index; an estimated
-- 2-15 ms per walk, unmeasured), and 6dd356e made one to four for the same player in one update (menu, mailbox, walls,
-- every 7th update). Now: one controller walk per update, and one player-state walk the first time something asks.
-- The choice is the one each lookup made before: the first live, non-default controller (FindFirstOf skips the class
-- default object; FindAllOf does not, hence the name test, as mailbox.lua's world key did), the first valid state.
-- It lives for one update only (frame is cleared after it), so nothing kept goes stale across a world change.
local frame = nil
local function liveKey(pc)
    if not pc:IsValid() then return nil end
    local okn, n = pcall(function() return pc:GetFullName() end)
    if okn and tostring(n):find("Default__", 1, true) then return nil end
    return tostring(pc:GetAddress())
end
local function playerContext()
    local ctx = {}
    for _, pc in ipairs(FindAllOf("PalPlayerController") or {}) do
        local ok, key = pcall(liveKey, pc)
        if ok and key then ctx.pc, ctx.worldKey = pc, key; break end
    end
    if ctx.pc then
        local ok, pawn = pcall(function() return ctx.pc:K2_GetPawn() end)
        ctx.hasPawn = ok and pawn ~= nil              -- menu.lua's old in-world test (UE4SS hands back an object, valid or not)
        local okv, valid = pcall(function() return pawn:IsValid() end)
        ctx.pawn = ok and okv and valid and pawn or nil
    end
    local looked, ps = false, nil
    ctx.playerState = function()
        if not looked then looked, ps = true, findPlayerState() end
        return ps
    end
    return ctx
end
local function playerState()
    if frame then return frame.playerState() end
    return findPlayerState()
end

-- Which world save is loaded: the game instance's selected world folder (PalGameInstance, a pure UFunction returning
-- an FString). Untested from Lua: its first answer is logged. Nil when it can't be read.
local function worldId()
    local gi = FindFirstOf("PalGameInstance")
    if not gi or not gi:IsValid() then return nil end
    local ok, v = pcall(function() return gi:GetSelectedWorldSaveDirectoryName() end)
    local okt, id = pcall(function() return type(v) == "string" and v or v:ToString() end)
    id = ok and okt and type(id) == "string" and id or nil
    once("worldid", "world save folder: " .. tostring(id) .. (ok and "" or (" (" .. tostring(v) .. ")")))
    return id ~= "" and id or nil
end

local function arrayNames(arr)
    local out = {}
    arr:ForEach(function(_, e) out[#out + 1] = e:get():ToString() end)
    return out
end

-- The techs items have unlocked, and nothing else from the shop. Level-1 techs and anything outside the shop are left
-- alone. Runs only once the connection is ready, so playing offline never relocks anything.
-- The whole list was read and compared every 7th update (estimated 0.3-1.2 ms, unmeasured). It is skipped while the
-- game's list has the same length and techsVersion is unchanged since a comparison that changed nothing: the game adds
-- techs to the list, so a new one changes its length. Every 15th poll (about 30 s) compares in full regardless. The
-- skip is tied to the TechnologyData it was taken from (another world loaded with the same seed and an equally long
-- list must be compared at once, as 6dd356e did within 2.1 s), and it is forgotten on a world change as well.
local techsSeen, techPolls = nil, 0
local researchedNow = {}      -- tech -> true: the world's researched list at the last full read (prerequisites)
local function syncTechs(ps)
    local td = ps:GetTechnologyData()
    if not td or not td:IsValid() then return end   -- still loading into the world
    local arr = td.UnlockedTechnologyNameArray
    techPolls = techPolls + 1
    local okNum, num = pcall(function() return arr:GetArrayNum() end)
    if not okNum then num = nil end
    local okAddr, addr = pcall(function() return tostring(td:GetAddress()) end)
    if not okAddr then addr = nil end
    if num and addr and techsSeen and techsSeen.version == techsVersion and techsSeen.num == num and techsSeen.td == addr
        and techPolls % 15 ~= 0 then
        return false
    end
    techsSeen = nil
    local okNames, names = pcall(arrayNames, arr)
    if not okNames then return end                    -- not readable this moment (seen as the menu first opens)
    P.count("techs", #names)
    local keep, have, changed = {}, {}, false
    for _, n in ipairs(names) do
        have[n] = true
        if D.shop[n] and not ap.techs[n] then
            changed = true
            log("locked " .. n .. " (its item has not arrived)")
        else
            keep[#keep + 1] = n
        end
    end
    researchedNow = have
    for tech in pairs(ap.techs) do
        if not have[tech] then
            keep[#keep + 1] = tech
            changed = true
            log("unlocked " .. tech)
        end
    end
    if changed then
        arr:Empty()
        for i, n in ipairs(keep) do arr[i] = FName(n) end
        safe(function() td:OnRep_UnlockedTechnologyNameArray() end)
    elseif num and addr then
        techsSeen = { version = techsVersion, num = num, td = addr }
    end
    return changed
end

function notify(text)                          -- (the local declared above writeSave)
    log(text)
    R.notify("[Archipelago] " .. text, playerState())
end

-- A seed belongs to one world: the first one the mod sees it played in (kept in the save file as world=). config.txt
-- connects at every start, whatever world is loaded next; in any other world nothing is locked, sent, given or
-- linked, or a vanilla world would have its techs relocked and its records sent as checks. If the world can't be told,
-- the seed is not tied to one (logged above).
-- A world that already has shop techs researched is tied only after the player says yes (the hint key): tying it
-- locks those techs again, and the points spent on them do not come back.
local seedWorld = nil         -- whether the world loaded now is the seed's; nil until looked at
local worldAsk = nil          -- { id = world folder, yes = pressed }: a world with progress, asked about
-- The researched techs of the loaded world that tying a seed to it would lock (nil: not readable yet).
local function techsToRelock(ps)
    local ok, names = pcall(function()
        local td = ps:GetTechnologyData()
        if not td or not td:IsValid() then error("no tech data yet") end
        return arrayNames(td.UnlockedTechnologyNameArray)
    end)
    if not ok then return nil end
    local relock = 0
    for _, n in ipairs(names) do
        if D.shop[n] and not ap.techs[n] then relock = relock + 1 end
    end
    return relock
end
-- Ties the seed to the loaded world when the world is new, or the player said yes. False while asking.
local function tieWorld(ps, id)
    if not (worldAsk and worldAsk.id == id and worldAsk.yes) then
        local relock = techsToRelock(ps)
        if not relock then return false end
        if relock > 0 then
            if not (worldAsk and worldAsk.id == id) then
                worldAsk = { id = id, yes = false }
                log("world: " .. id .. " has " .. relock .. " researched shop tech(s);"
                    .. " asking before tying the seed to it")
                notify("This world already has progress: " .. relock .. " researched tech(s) would be locked again"
                    .. " and its records sent as checks. Load a new world for this seed, or press " .. HINT_KEY
                    .. " to play the seed here anyway.")
            end
            return false
        end
    end
    worldAsk = nil
    ap.world = id
    writeSave()
    log("world: this seed is played in world " .. id)
    return true
end
local function checkWorld(ps)
    local id = worldId()
    if not id and ap.world then
        once("worldunread", "world: the loaded world's folder can't be read, so it is not taken as this seed's ("
            .. ap.world .. ")")
        return false
    end
    if not id then return true end                 -- a seed with no world yet: not tied to one (logged in worldId)
    if not ap.world then return tieWorld(ps, id) end
    if id == ap.world then return true end
    if seedWorld ~= false then
        log("world: " .. id .. " is not this seed's world (" .. ap.world .. "): nothing is locked, sent or given here"
            .. " (to move the seed to this world, delete the world= line from " .. tostring(saveFile()) .. ")")
        notify("This is not the world this Archipelago seed is played in: nothing is locked, sent or given here.")
    end
    return false
end

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
local goalWait = nil                     -- { done = what, since = tick }
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
local keptBy = nil         -- the game instance lives all session (skill: GameInstance-owned objects); checked on use
local function keep(obj)
    if not (keptBy and keptBy:IsValid()) then keptBy = FindFirstOf("PalGameInstance") or FindFirstOf("GameInstance") end
    local gi = keptBy
    local ok, err = pcall(function()
        local arr = gi.ReferencedObjects
        arr[arr:GetArrayNum() + 1] = obj
    end)
    if not ok then once("keep", "could not keep a texture alive: " .. tostring(err)) end
end
WALLS.keep = keep
WALLS.dir = modDir
WALLS.cppOff = cfg.map_cpp == "0"
WALLS.chartOff = cfg.map_chart == "0"
WALLS.iconsOff = cfg.map_icons == "0"
WALLS.regionsOff = cfg.map_regions == "0"
WALLS.mapStyle = cfg.map_style == "chart" and "chart" or "territories"
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

local textures = {}
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
local techTextures = {}
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

local function shopCard(tech) return ap.shown and D.shop[tech] ~= nil end
local function bought(tech) return ap.checked[D.shop[tech].loc] == true end

-- The game's own card categories, read off the level-1 cards (never relabelled) so they follow the game's language.
local categories = { structure = "Structures", item = "Items" }
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

local cardPasses = 0
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

local CONTENT = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_Content.WBP_MainMenu_Technology_Content_C"
local INFO = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/InventoryEquipment/WBP_InventoryEquipment_ItemInfo.WBP_InventoryEquipment_ItemInfo_C"
local DIALOG = "/Game/Pal/Blueprint/UI/Dialog/WBP_PalDialog.WBP_PalDialog_C"
local TREE = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Technology/WBP_MainMenu_Technology_00.WBP_MainMenu_Technology_00_C"
local hoveredTech = nil   -- the card under the pointer: a confirm box opened while it is set came from that card
local retarget = nil      -- the tech a tooltip is being set up again for (see the tooltip hook)

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

local lazyHooks = {
    -- A slot card looks researched exactly when its slot has been bought, whether or not you own its tech.
    { fn = CONTENT .. ":IsUnlocked", cb = function(self, out)
        if not ap.shown then return end        -- no shop card yet (shopCard is false for all): the game's answer
        local tech = self:get().BindedTechnologyName:ToString()
        if not shopCard(tech) then return end
        pcall(function() out:set(bought(tech)) end)
        return bought(tech)
    end },
    -- Tooltips: a slot holding one of your techs shows that tech's own tooltip (set up again for it, a moment later,
    -- outside this hook); other slot cards have none (the card already says what it sends). Hidden by transparency
    -- rather than collapsing: the game makes the tooltip visible again after setting it up.
    { fn = INFO .. ":Setup by Technology Name", cb = function(self, techName)
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
    end },
    -- Leaving a card forgets it, so a later dialog (Return to Title...) is not mistaken for a purchase.
    { fn = TREE .. ":OnUnhoveredAnyTechnology_Internal", cb = function()
        hoveredTech = nil
    end },
    -- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
    -- applied on the next frame and again on the next two updates (only while it still differs): about the first
    -- half second, as the five ExecuteWithDelay re-applies did, all on the game thread.
    { fn = DIALOG .. ":SetupUI", cb = function(self, dialogType, message)
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
    end },
}
-- Each is registered once its class has loaded (UTIL.hookWhenLoaded retries while it loads), through guardedHook.
local function registerLazyHooks()
    for _, h in ipairs(lazyHooks) do
        if not h.done then
            h.guarded = h.guarded or guardedHook(h.fn, h.cb)
            h.done = UTIL.hookWhenLoaded(h.fn, h.guarded, "shop")
        end
    end
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
    if seedWorld == false then
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

local okh, errh = pcall(RegisterHook, "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer",
    guardedHook("RequestUnlockTechnology_ToServer", function(self, name)
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
    end))
log(okh and "hooked research requests" or ("could not hook research requests: " .. tostring(errh)))

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
    if p and not (ap.techs[p] or D.starters[p] or (D.research[p] and researchedNow[p])) then return false end
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
-- The tech menu asks this (and the next hook) about 25 times for each card it builds or refreshes, and twice for all
-- 588 techs on a filter (hooks review, 2026-11-04). The early returns give exactly what the full check gives in that
-- case (nothing is a shop card before ap.shown; the next hook answers only for the hovered card), and the checks are
-- module-level functions, so no closure is made per call.
local function unlockableCheck(self, ...)
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
local oku, erru = pcall(RegisterHook, "/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology", function() end,
    function(self, ...)
        if not ap.shown then return nil end
        local ok, v = guarded(unlockableCheck, self, ...)
        if not ok then once("unlockableErr", "research check error: " .. tostring(v)); return nil end
        return v
    end)
log(oku and "hooked research checks" or ("could not hook research checks: " .. tostring(erru)))

-- The click also asks whether the tech is already researched, and stops if it is. For an unbought slot whose tech you
-- own, that one question is answered "not yet" while the pointer is on its card; everywhere else (crafting, building)
-- the game's answer stands.
local function researchedCheck(...)
    local tech = techArg(...)
    if not tech or tech ~= hoveredTech or not shopCard(tech) then return nil end
    if bought(tech) or not ap.techs[tech] then return nil end
    once("ask2" .. tech, "click check on " .. tech .. ": already researched -> answered not yet")
    return false
end
local okr, errr = pcall(RegisterHook, "/Script/Pal.PalTechnologyData:IsUnlockRecipeTechnology", function() end,
    function(self, ...)
        if hoveredTech == nil then return nil end      -- answers only for the card under the pointer
        local ok, v = guarded(researchedCheck, ...)
        if not ok then once("researchedErr", "researched check error: " .. tostring(v)); return nil end
        return v
    end)
log(okr and "hooked researched checks" or ("could not hook researched checks: " .. tostring(errr)))

------------------------------------------------------------------------------------------------------------------------
local tick = 0
local function isPhase(phase) return tick % CYCLE == phase end
local preloaded = false
local hints = { known = {}, shown = {}, offer = nil, offeredAt = 0, asked = nil,
                key = HINT_KEY }
local wallsLogged = false
local death = { on = false, wasDead = false, incoming = nil, at = nil, caused = nil, pending = nil, route = 1 }
local lockedTicks = 0
local wallsWorld, worldTicks = nil, 0
-- Notices that would come while the loading screen is still up (Speed Boost's, 2026-11-07 test: sent 2 s after the world
-- loaded, before the player could see it; they found it later in chat): held until the player's character has moved
-- MOVED_CM from where it first stood in this world, or WAIT.heldNotice has passed, then shown. Dropped if the world
-- changes first.
local heldNotices = { list = {}, world = nil, from = nil }
local MOVED_CM = 300
local function noticeLater(msg)
    local held = heldNotices
    if held.world ~= wallsWorld then held.list, held.world, held.from = {}, wallsWorld, nil end
    held.list[#held.list + 1] = msg
end
local function showLater(pawn)
    local held = heldNotices
    if #held.list == 0 then return end
    if held.world ~= wallsWorld then
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
    if moved or worldTicks >= WAIT.settle + WAIT.heldNotice then
        for _, msg in ipairs(held.list) do notify(msg) end
        local why = moved and "the player moved" or "a minute in the world"
        log("held notice(s) shown (" .. why .. "): " .. #held.list)
        held.list, held.from = {}, nil
    end
end
-- The seed's area_locks option, read once a connection (slot data is fixed for a connection) instead of every update,
-- which parsed the slot data's JSON each time in the connector (estimated 10-50 us and the connector's lock).
local areaLocks = false

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
    techsVersion = techsVersion + 1
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
    death.incoming, death.at = cause and cause ~= "" and cause or (source .. " died."), tick
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
    elseif kindOf == "CommandResult" and hints.asked and tick - hints.asked < WAIT.hintAnswer then
        notify(text)                               -- the server's answer to a hint the player asked for
    end
end

local techScan = { report = nil, tries = 0, sent = false }   -- other mods' techs (techscan.lua)

local function resetSeed()
    ap.checked, ap.sent, ap.scouted, ap.items, ap.techs, ap.passes = {}, {}, {}, {}, {}, {}
    ap.bought = {}
    CRATES.reset()
    SYNC.reset()
    ap.given, ap.goalSent, ap.ready, ap.shown = -1, false, false, false     -- items are numbered from 0
    ap.goalShown = false
    goalWait = nil
    ap.world, seedWorld, worldAsk = nil, nil, nil
    ap.from, ap.forgiven = {}, 0
    ap.visited = {}
    WALLS.visited = ap.visited
    MAIL.reset()
    TRAPS.reset()
    techsVersion = techsVersion + 1
    hints.known, hints.shown, hints.offer = {}, {}, nil
    techScan.sent = false
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
    ap.status = "connected"
    ap.connectedTick = tick
    ap.me = tonumber(AP_SlotData("slot"))
    local seed = AP_SlotData("seed")
    if seed ~= "" and (seed ~= ap.seed or cfg.slot ~= ap.slotName) then
        if ap.seed then resetSeed() end            -- another seed or slot: nothing of the last one carries over
        ap.seed, ap.slotName = seed, cfg.slot
        loadSave()
    end
    local research = AP_SlotData("research_techs")
    setResearch(research)
    keepResearch(research)
    local locs = {}
    for loc in pairs(SLOT_TECH) do locs[#locs + 1] = tostring(loc) end
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
        if ap.status ~= "connected" then ap.status = "connecting" end
    elseif state == "refused" then
        ap.status = "refused"
        notify("Archipelago refused the connection: " .. tostring(detail))
    elseif state == "disconnected" then
        ap.status = "disconnected"
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
    ap.status = "connecting"
    AP_Connect(server, slot, password or "")
end
-- The servers the title menu's Archipelago menu offers (the user, 2026-11-07: archipelago.gg always, and any server
-- connected to before; host names only, since an archipelago.gg room's port changes with every room). Kept in
-- config.txt as servers=host,host.
local DEFAULT_SERVER = "archipelago.gg"
local function hostOf(server) return ((server or ""):match("^%s*([^:%s]+)") or ""):lower() end
local function servers()
    local list, seen = { DEFAULT_SERVER }, { [DEFAULT_SERVER] = true }
    for host in ((cfg.servers or "") .. "," .. hostOf(cfg.server)):gmatch("[^,%s]+") do
        host = host:lower()
        if not seen[host] then seen[host] = true; list[#list + 1] = host end
    end
    return list
end
local function rememberServer(server)
    local host = hostOf(server)
    if host == "" or host == DEFAULT_SERVER then return end
    for h in (cfg.servers or ""):gmatch("[^,%s]+") do if h:lower() == host then return end end
    cfg.servers = (cfg.servers and cfg.servers ~= "") and (cfg.servers .. "," .. host) or host
    writeConfig()
    log("servers: remembered " .. host)
end
MENU.install({
    status = function() return ap.status end,
    servers = servers,
    rememberServer = rememberServer,
    server = function() return cfg.server or "" end,
    slot = function() return cfg.slot or "" end,
    password = function() return cfg.password or "" end,
    connect = connectTo,
    disconnect = function()
        AP_Disconnect()
        ap.status, ap.ready = "disconnected", false
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
    hints.offer, hints.offeredAt = area, tick
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
    if not area or tick - hints.offeredAt > WAIT.hintOffer then return end
    local points, cost = (AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if points and tonumber(points) < tonumber(cost) then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, tick
    AP_Say("!hint " .. WALLS.passName(area))
    notify("Asking the Archipelago server where " .. WALLS.passName(area) .. " is...")
end
-- Key binds run off the game thread: they only hand over a function made here, once (no new function there).
local function hintKey()
    if worldAsk and not worldAsk.yes then
        worldAsk.yes = true
        log("world: the player said yes to playing this seed in " .. worldAsk.id)
        return
    end
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
            death.caused = tick
            local ok, err, how = faintNow(ps)
            if ok and death.route < #ROUTES then death.pending = cause end
            log("death link: the " .. failed .. " did not faint the player; used the " .. how .. ": " .. cause
                .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
            return
        end
    end
    -- An incoming death waits for a settled world with a character (as the traps do), then counts as late.
    local character = safe(function() return ps:GetPawn() end)
    local settled = wallsWorld and worldTicks >= WAIT.settle and character and character:IsValid()
    if death.incoming and (settled or tick - death.at > WAIT.deathLate) then
        local cause = death.incoming
        death.incoming = nil
        if tick - death.at > WAIT.deathLate then
            log("death link received while no player was in the world (" .. (tick - death.at) .. " updates ago): not applied: " .. cause)
        elseif not dead then
            death.caused = tick
            local ok, err, how = faintNow(ps)
            if ok and death.route < #ROUTES then death.pending = cause end
            notify("Death Link: " .. cause)
            log("death link received: " .. cause .. " (" .. how .. ")" .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
        end
    end
    if dead and not death.wasDead then
        if death.caused and tick - death.caused < WAIT.ownDeath then
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
local function sendRemovedSlots()
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
    local okp, errp = pcall(POPUP.tick, tick)
    if not okp then onceErr("popup", errp, "hint pop-up error: " .. tostring(errp)) end
    local okdb, errdb = pcall(DEBUFFS.tick, tick)
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
    if ap.status ~= "connected" or ap.ready or tick - ap.connectedTick < WAIT.firstItems then return end
    ap.ready = true
    ap.shown = true
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
        for _, h in ipairs(lazyHooks) do
            if not h.done then
                local class = h.fn:gsub(":.*$", "")          -- the hook's "<class path>:<function>"
                local ok, err = pcall(LoadAsset, (class:gsub("_C$", "")))
                if not ok then once("preload" .. class, "could not preload " .. class .. ": " .. tostring(err)) end
            end
        end
    end)
end

-- Other mods' techs, once per cycle in the tech-scan phase until the player's tech data is there.
local function scanOtherModsTechs()
    if techScan.report or techScan.tries >= TECH_SCAN_TRIES or not isPhase(PHASE.techScan) then return end
    P.start("scan")
    local td = safe(function() local ps = playerState(); return ps and ps:GetTechnologyData() end)
    if td and safe(function() return td:IsValid() end) then scanTechs(td) end
    P.stop("scan")
end

-- A new world (a new pawn): everything tied to the old one is looked at again.
local function noteWorldChange(world)
    wallsWorld, worldTicks = world, 0
    seedWorld = nil                                -- looked at again (records phase) before any wall goes up
    worldAsk = nil                                 -- (a yes is for the world it was asked in)
    POPUP.forget()                                 -- (the pop-up or goal banner went with the old world's HUD)
    WALLS.reset()
    techsSeen = nil                                -- another world's tech list: compare it in full
end

-- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that hint
-- with the hint key (once per area every WAIT.wallNotice).
local function noticeLockedWall(pawn)
    local okn, area = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        return WALLS.lockedNear(loc.X, loc.Y, ap.passes)
    end)
    if not (okn and area) or (hints.shown[area] or -1e9) + WAIT.wallNotice > tick then return end
    hints.shown[area] = tick
    local line, info = wallNotice(area)
    notify(line)
    local okp, errp = pcall(POPUP.show, info, tick)
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
local function updateAreaLocks()
    local pawn = safe(function() local ps = playerState(); return ps and ps:GetPawn() end)
    -- A new world brings a new pawn, so the pawn's address names the world.
    local world = pawn and pawn:IsValid() and safe(function() return tostring(pawn:GetAddress()) end)
    if world ~= wallsWorld then noteWorldChange(world) end
    worldTicks = worldTicks + 1
    if not (world and worldTicks >= WAIT.settle and seedWorld) then return end
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
    if not on then return end
    -- Inside a stage (a dungeon, a tower's arena) the map position says nothing about the area the player entered it
    -- from: no notice, no visit and no sending home there.
    local okS, inStage = pcall(function() return playerState():IsInStage() end)
    if okS and inStage then return end
    if isPhase(PHASE.wallNotice) then noticeLockedWall(pawn) end
    if isPhase(PHASE.areas) then
        rememberVisited(pawn)
        -- Not while Ctrl+7 holds the walls without collision or removed: a player could drift across a border then.
        if not held then sendHomeIfLocked(pawn) end
    end
end

-- The records phase: trap timers, the seed's-world check, the game's records (checks and the goal).
local function phaseRecords()
    P.start("e7")
    local ps = playerState()
    local pawn = ps and safe(function() return ps:GetPawn() end)
    -- A running Slow Trap or Fool Trap ends on time whether or not the connection is up.
    local okk, errk = pcall(TRAPS.tick, { tick = tick, pawn = pawn })
    if not okk then onceErr("trapsk", errk, "traps error: " .. tostring(errk)) end
    if ps and ap.ready then seedWorld = checkWorld(ps) end
    if ps and ap.ready and seedWorld then
        P.start("rec")
        pollRecords(ps, tick)
        P.stop("rec")
    end
    P.stop("e7")
    if ps and ap.ready then P.records(ps) end
end

-- The items phase, in the seed's world only: techs and items; once the world has settled, the run style's sync and the
-- held notices; Death Link; traps.
local function phaseItems()
    local ps = playerState()
    if not ps then return end
    P.start("e7")
    P.start("techs")
    local changed = syncTechs(ps)
    P.stop("techs")
    if changed then refreshTree() end
    local td = safe(function() return ps:GetTechnologyData() end)
    if td and td:IsValid() then applyItems(ps) end    -- (items wait while the tech data is still loading)
    if wallsWorld and worldTicks >= WAIT.settle then
        local oks, news = pcall(SYNC.apply, ps, AP_SlotData, wallsWorld, noticeLater)
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
        TRAPS.update({ tick = tick, ps = ps, pawn = pawn, settled = wallsWorld ~= nil and worldTicks >= WAIT.settle,
                       dead = not okd or dead, busy = MAIL.busy() })
    end)
    if not okt then onceErr("traps", errt, "traps error: " .. tostring(errt)) end
    P.stop("e7")
end

-- One core update (coreTick, every UPDATE_MS on the game thread): what runs every time, then this update's phase.
local function update(ctx)
    tick = tick + 1
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
    scanOtherModsTechs()
    if ap.ready and techScan.report and not techScan.sent then sendRemovedSlots() end
    if ap.ready then updateAreaLocks() end
    if isPhase(PHASE.records) then
        phaseRecords()
    elseif isPhase(PHASE.items) and ap.ready and seedWorld then
        phaseItems()
    end
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
    frame = ctx
    P.frameBegin(ctx, ran and P.stop("ctx") or nil)
    if ran then
        local ok, err = pcall(update, ctx)
        if not ok then onceErr("update", err, "update error: " .. tostring(err)) end
        if P.legacy then pcall(oldLoad, ctx) end
        P.world(ctx)
    end
    frame = nil
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
-- Every UPDATE_MS (the number stays a literal: the harness reads it).
LoopAsync(300, function()
    ExecuteInGameThread(coreTick)
    return false
end)

-- Test tools: only with test_tools=1 in config.txt (see test_tools.lua).
if cfg.test_tools == "1" then
    local okt, errt = pcall(TEST_TOOLS.install)
    if not okt then log("test tools not loaded: " .. tostring(errt)) end
end
