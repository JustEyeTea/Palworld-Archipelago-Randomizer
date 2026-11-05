-- PalworldArchipelago: the Lua core of the mod. The Archipelago connection comes from the APConnector C++ mod, which
-- registers AP_* functions here when this mod starts (see cppmod/APConnector/src/dllmain.cpp).
--  * Technology levels 2+ are a shop: each card shows what its slot holds in the multiworld, researching it spends the
--    points and sends the check, and never unlocks the tech itself. Techs unlock as their items arrive.
--  * Received items: techs, Progressive Spheres, Area Passes, points, bundles (into the mailbox, mailbox.lua), and traps
--    (traps.lua).
--  * Checks: shop slots, levels, captures, alphas, fast-travel points and towers, read from the game's own records.
-- Everything is logged to ue4ss/UE4SS.log with the prefix [PalworldAP].
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local VERSION = "0.13.8"
log("loaded " .. VERSION)

local modDir = (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("[/\\]Scripts[/\\]main%.lua$", ""))
package.path = modDir .. "\\Scripts\\?.lua;" .. package.path
local D = require("ap_data")
local TECHS = require("tech_icons")
local ICONS, STRUCTURES = TECHS.icons, TECHS.structures
local R = require("records")
local WALLS = require("walls")
local MENU = require("menu")
local TECHSCAN = require("techscan")
local MAIL = require("mailbox")
local TRAPS = require("traps")

local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end
-- For errors caught every update: the key drops numbers and addresses (an error naming an object's address would
-- otherwise log anew on each update, three lines a second), and each kind logs at most 20 different errors.
local errKinds = {}
local function onceErr(kind, err, msg)
    local key = kind .. tostring(err):gsub("0x%x+", ""):gsub("%d+", "#")
    if reported[key] then return end
    errKinds[kind] = (errKinds[kind] or 0) + 1
    if errKinds[kind] > 20 then return end
    once(key, msg .. (errKinds[kind] == 20 and " (further errors of this kind are not logged)" or ""))
end
local function safe(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
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
-- The performance probe (perf_log=1; perf.lua). Installed before any hook is registered, so it counts them all.
local P = require("perf")
P.install(cfg, { wallsCount = function() return (WALLS.count()) end, setWalls = function(mode) WALLS.perfMode(mode) end,
                 mailOpen = function() return MAIL.viewOpen() end })
local function writeConfig()
    local f = io.open(modDir .. "\\config.txt", "w")
    if not f then log("could not write config.txt"); return end
    for _, k in ipairs({ "server", "slot", "password", "hint_key", "mailbox", "mailbox_key", "mailbox_view", "mailbox_slots",
                         "test_tools", "perf_log", "perf_no_bp_hooks", "wall_skin", "wall_tiling", "wall_scroll" }) do
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
    goalSent = false,
    world = nil,          -- the world save this seed is played in (its folder name), kept in the save file
}

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
        if n then ap.given = tonumber(n)
        elseif w then ap.world = w
        elseif d then ap.forgiven = tonumber(d)
        elseif not TRAPS.load(line) then MAIL.load(line) end
    end
    local kinds, items = MAIL.count()
    log("save " .. path .. ": items applied up to index " .. ap.given .. "; mailbox " .. items .. " item(s) of " .. kinds
        .. " kind(s); " .. #TRAPS.queue .. " trap(s) waiting; " .. ap.forgiven .. " faint(s) forgiven; world " .. tostring(ap.world))
end
-- Written only when its text changed (it was rewritten every 7th update, 2.1 s, even when nothing had changed: an
-- estimated 0.2-2 ms each time for creating, writing and closing the file; more with antivirus; unmeasured). The text
-- is compared, not ap.given alone: mail that arrives (MAIL.add) is saved only by this write. always: write it anyway
-- (the perf probe's Ctrl+0 replay of the old load).
local lastSave = nil          -- path and text of the last write: the same again is not written
local function writeSave(always)
    local path = saveFile()
    if not path then return end
    -- One write holds everything that must agree: what was applied, and the traps and mailbox items it left.
    local text = "given=" .. ap.given .. "\n" .. (ap.world and ("world=" .. ap.world .. "\n") or "")
        .. "deaths=" .. ap.forgiven .. "\n" .. TRAPS.serialize() .. MAIL.serialize() .. "end\n"
    if not always and lastSave == path .. "\n" .. text then return end
    P.start("save")
    local f = io.open(path .. ".tmp", "w")
    if not f then P.stop("save"); return end
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

local function notify(text)
    log(text)
    R.notify("[Archipelago] " .. text, playerState())
end

-- A seed belongs to one world: the first one the mod sees it played in (kept in the save file as world=). config.txt
-- connects at every start, whatever world is loaded next; in any other world nothing is locked, sent, given or
-- linked, or a vanilla world would have its techs relocked and its records sent as checks. If the world can't be told,
-- the seed is not tied to one (logged above).
local seedWorld = nil         -- whether the world loaded now is the seed's; nil until looked at
local function checkWorld()
    local id = worldId()
    if not id then return true end
    if not ap.world then
        ap.world = id
        writeSave()
        log("world: this seed is played in world " .. id)
        return true
    end
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
local function giveOneOff(ps, id)
    local it = D.items[id]
    if not it then return true end
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
                local okg, got = pcall(MAIL.give, b[1], b[2])
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
local function applyItems(ps)
    local i = ap.given + 1
    while ap.items[i] do
        local id = ap.items[i]
        local it = D.items[id]
        if it and it.kind == "filler" and not giveOneOff(ps, id) then
            if waiting ~= i then
                waiting = i
                notify("Your bag is full: " .. it.name .. " waits until there is room.")
            end
            break
        end
        if waiting == i then waiting = nil; log("bundle " .. it.name .. " given, now the bag has room") end
        if it and it.kind == "trap" then TRAPS.add(it.name, i) end      -- queued: traps.lua paces and fires them
        if it and it.kind == "relic" then
            local need = tonumber(AP_SlotData("relics_needed"))
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
    local goal = GOALS[AP_SlotData("options.goal")] or "towers"
    if goal == "relic_hunt" then
        local have, need = relicCount(), tonumber(AP_SlotData("relics_needed")) or 999
        return have >= need and (have .. " Palpagos Relics found") or nil
    elseif goal == "paldeck" then
        local need = tonumber(AP_SlotData("options.paldeck_count")) or 999
        return found.pals >= need and (found.pals .. " Pals registered") or nil
    elseif goal == "world_tree" then
        return found.beaten.WorldTreeBoss and "the World Tree's boss beaten" or nil
    end
    return found.towers >= (tonumber(AP_SlotData("options.tower_count")) or 99) and (found.towers .. " tower(s) beaten") or nil
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

-- Everything the game's records say is done: levels, captures, alphas, fast travel, towers. The server ignores
-- locations this seed doesn't have (options turned off), so the mod doesn't need to know which are in play.
local function pollRecords(ps)
    local okp, found = pcall(R.progress, ps, D, os.time())
    if not okp then once("records", "records not readable yet (loading?): " .. tostring(found)); return end
    sendChecks(found.locations)
    ap.level, ap.beaten = found.level, found.beaten
    if ap.goalSent then return end
    local done = goalReached(found)
    if done then
        ap.goalSent = true
        AP_Goal()
        notify("Goal complete: " .. done .. "!")
    end
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
do local ART = require("art"); ART.keep, ART.dir = keep, modDir end
do      -- wall skins (test builds; walls.lua): wall_skin=a|b|a3d|b3d|a3d-dense|b3d-dense, wall_tiling=U,V and wall_scroll=U,V in config.txt
    local function pair(s)
        local u, v = (s or ""):match("^%s*([%d.]+)%s*,%s*([-%d.]+)%s*$")
        return u and { tonumber(u), tonumber(v) } or nil
    end
    WALLS.tiling, WALLS.scroll = pair(cfg.wall_tiling), pair(cfg.wall_scroll)
    WALLS.setSkin(cfg.wall_skin)
end

local textures = {}
local function icon(kind, ctx)
    local t = textures[kind]
    if t and t:IsValid() then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not lib or not lib:IsValid() then once("nolib", "KismetRenderingLibrary not found"); return nil end
    local path = modDir .. "\\icons\\" .. kind .. ".png"
    t = lib:ImportFileAsTexture2D(ctx, path)
    if t and t:IsValid() then textures[kind] = t; keep(t) else once("icon" .. kind, "could not load icon " .. path) end
    return t
end

-- A technology's own icon (an asset in the game), for slots that hold one of your techs.
local techTextures = {}
local function techIcon(tech)
    local t = techTextures[tech]
    if t and t:IsValid() then return t end
    local path = ICONS[tech]
    if not path then return nil end
    t = StaticFindObject(path)
    if not t or not t:IsValid() then
        pcall(LoadAsset, path)
        t = StaticFindObject(path)
    end
    if t and t:IsValid() then techTextures[tech] = t; keep(t) else once("techicon" .. tech, "could not load " .. path) end
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
    -- An Area Pass shows its own area's ticket (art/ap-pass-<area>.png, round 2), else the shared one.
    local tex = mine and techIcon(mine)
        or (kind == "area-pass" and require("art").texture("ap-pass-" .. WALLS.slugOf(it.area)))
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
local lazyHooks = {
    -- A slot card looks researched exactly when its slot has been bought, whether or not you own its tech.
    { class = CONTENT, fn = CONTENT .. ":IsUnlocked", cb = function(self, out)
        if not ap.shown then return end        -- no shop card yet (shopCard is false for all): the game's answer
        local tech = self:get().BindedTechnologyName:ToString()
        if not shopCard(tech) then return end
        pcall(function() out:set(bought(tech)) end)
        return bought(tech)
    end },
    -- Tooltips: a slot holding one of your techs shows that tech's own tooltip (set up again for it, a moment later,
    -- outside this hook); other slot cards have none (the card already says what it sends). Hidden by transparency
    -- rather than collapsing: the game makes the tooltip visible again after setting it up.
    { class = INFO, fn = INFO .. ":Setup by Technology Name", cb = function(self, techName)
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
    { class = TREE, fn = TREE .. ":OnUnhoveredAnyTechnology_Internal", cb = function()
        hoveredTech = nil
    end },
    -- The confirm box names what the purchase sends. The game fills its text in slightly after SetupUI, so the text is
    -- re-applied a few times over the first half second (only while it still differs).
    { class = DIALOG, fn = DIALOG .. ":SetupUI", cb = function(self, dialogType, message)
        local tech = hoveredTech
        once("dialogmsg", "first confirm box message: '" .. tostring(safe(function() return message:get():ToString() end)) .. "'")
        if not shopCard(tech) or bought(tech) then return end
        local dialog, text = self:get(), confirmText(tech)
        for _, delay in ipairs({ 0, 50, 150, 300, 500 }) do
            ExecuteWithDelay(delay, function() ExecuteInGameThread(function()
                if not dialog:IsValid() then return end
                local popup = dialog.WBP_CommonPopupWindow
                local msg = safe(function() return popup.BP_PalRichTextBlock_Message:GetText():ToString() end)
                if msg ~= text then pcall(function() popup:SetMainText(FText(text)) end) end
            end) end)
        end
    end },
}
local function registerLazyHooks()
    for _, h in ipairs(lazyHooks) do
        if not h.done then
            local cls = StaticFindObject(h.class)
            if cls and cls:IsValid() then
                h.done = true
                local ok, err = pcall(RegisterHook, h.fn, h.cb)
                log((ok and "hooked " or "could not hook ") .. h.fn .. (ok and "" or (": " .. tostring(err))))
            end
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
    sendChecks({ s.loc })
    ap.checked[s.loc] = true
    refreshTree()
end

local okh, errh = pcall(RegisterHook, "/Script/Pal.PalNetworkPlayerComponent:RequestUnlockTechnology_ToServer",
    function(self, name)
        local tech = name:get():ToString()
        if not D.shop[tech] then return end
        name:set(FName("AP_ShopSlot"))
        -- Ctrl+9 (perf test tools): the confirm box shows the game's own text then, not what the purchase sends, so
        -- a confirm is not a purchase. A check sent cannot be taken back in the multiworld.
        if P.bypass then log("[perf] purchase of " .. tech .. " ignored while the hook bypass (Ctrl+9) is on"); return end
        ExecuteWithDelay(300, function() ExecuteInGameThread(function()
            local ok, err = pcall(buy, tech)
            if not ok then log("buy error: " .. tostring(err)) end
        end) end)
    end)
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
    if s.prereq and not (ap.techs[s.prereq] or D.starters[s.prereq]) then return false end
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
    if r ~= nil and not reported.unlockable then once("unlockable", "slot clickability decided by the mod (first: " .. tech .. " -> " .. tostring(r) .. ")") end
    if tech == hoveredTech and not reported["ask1" .. tech] then once("ask1" .. tech, "click check on " .. tech .. ": unlockable -> " .. tostring(r)) end
    return r
end
local oku, erru = pcall(RegisterHook, "/Script/Pal.PalTechnologyData:IsUnlockableRecipeTechnology", function() end,
    function(self, ...)
        if not ap.shown then return nil end
        local ok, v = pcall(unlockableCheck, self, ...)
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
        local ok, v = pcall(researchedCheck, ...)
        if not ok then once("researchedErr", "researched check error: " .. tostring(v)); return nil end
        return v
    end)
log(okr and "hooked researched checks" or ("could not hook researched checks: " .. tostring(errr)))

------------------------------------------------------------------------------------------------------------------------
local tick = 0
local preloaded = false
local hints = { known = {}, shown = {}, offer = nil, offeredAt = 0, asked = nil,
                key = ((cfg.hint_key or ""):match("^%s*(%w+)%s*$") or "H"):upper() }
local wallsLogged = false
local death = { on = false, wasDead = false, incoming = nil, at = nil, caused = nil }
local DEATH_LATE = 20         -- ticks (6 s): a linked death older than this (received at the title, or while loading) is dropped
local lockedTicks = 0
local wallsWorld, worldTicks = nil, 0
local SETTLE = 17
-- The seed's area_locks option, read once a connection (slot data is fixed for a connection) instead of every update,
-- which parsed the slot data's JSON each time in the connector (estimated 10-50 us and the connector's lock).
local areaLocks = false

-- Archipelago events (see cppmod/APConnector/src/ap_bridge.hpp for the line format).
local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = part end
    return f
end

local function receive(f)
    local index, id, player, flags = tonumber(f[2]), tonumber(f[3]), tonumber(f[5]), tonumber(f[6])
    local name, from = f[7], f[8]
    if ap.items[index] == id then return end
    ap.items[index] = id
    techsVersion = techsVersion + 1
    local it = D.items[id]
    if not it then log("unknown item " .. id .. " (" .. tostring(name) .. ")"); return end
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

local techScan = { report = nil, tries = 0, sent = false }   -- other mods' techs (techscan.lua)

local function resetSeed()
    ap.checked, ap.sent, ap.scouted, ap.items, ap.techs, ap.passes = {}, {}, {}, {}, {}, {}
    ap.given, ap.goalSent, ap.ready, ap.shown = -1, false, false, false     -- items are numbered from 0
    ap.world, seedWorld = nil, nil
    ap.from, ap.forgiven = {}, 0
    MAIL.reset()
    TRAPS.reset()
    techsVersion = techsVersion + 1
    hints.known, hints.shown, hints.offer = {}, {}, nil
    techScan.sent = false
    log("a different seed or slot: progress of the last one forgotten")
end

local function onEvent(line)
    local f = split(line)
    local kind = f[1]
    if kind == "status" then
        log("status: " .. table.concat(f, " ", 2))
        local was = ap.status
        if f[2] == "connected" then
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
            if was ~= "connected" then notify("Connected to Archipelago as " .. cfg.slot) end
            local locks = AP_SlotData("options.area_locks")
            areaLocks = locks == "1" or locks == "true"
            local dl = AP_SlotData("options.death_link")
            death.on = (dl == "1" or dl == "true") and AP_SetTags ~= nil
            if death.on then
                AP_SetTags("AP,DeathLink")
                log("Death Link on: amnesty " .. (tonumber(AP_SlotData("options.death_link_amnesty")) or 0) .. ", "
                    .. ap.forgiven .. " faint(s) forgiven so far")
            end
            local chance = tonumber(AP_SlotData("options.trap_chance")) or 0
            if chance > 0 then log("traps: " .. chance .. "% of filler items are traps in this seed") end
        elseif f[2] == "connecting" then
            if ap.status ~= "connected" then ap.status = "connecting" end
        elseif f[2] == "refused" then
            ap.status = "refused"
            notify("Archipelago refused the connection: " .. tostring(f[3]))
        elseif f[2] == "disconnected" then
            ap.status = "disconnected"
            ap.ready = false
        end
    elseif kind == "item" then
        receive(f)
    elseif kind == "scout" then
        local loc, player = tonumber(f[2]), tonumber(f[4])
        ap.scouted[loc] = { id = tonumber(f[3]), item = f[6], player = f[7], game = f[8], flags = tonumber(f[5]) or 0,
                            own = player == ap.me }
    elseif kind == "checked" then
        ap.checked[tonumber(f[2])] = true
    elseif kind == "bounce" then
        if death.on and (f[2] or ""):find("DeathLink", 1, true) then
            local data = f[3] or ""
            local source = data:match('"source"%s*:%s*"(.-)"') or "someone"
            local cause = data:match('"cause"%s*:%s*"(.-)"')
            if source ~= cfg.slot then death.incoming, death.at = cause and cause ~= "" and cause or (source .. " died."), tick end
        end
    elseif kind == "message" then
        local text, kindOf = tostring(f[2]), f[3]
        log("AP: " .. text)
        if kindOf == "Hint" then
            notify(text)
            -- The finder is told too: a hint for another player's pass that sits in our world is not about our walls.
            local who, pass = text:match("^%[Hint%]: (.-)'s Area Pass: (.-) is at ")
            if pass and who == (ap.slotName or cfg.slot) then hints.known[pass] = text:gsub("^%[Hint%]: ", "") end
        elseif kindOf == "CommandResult" and hints.asked and tick - hints.asked < 50 then
            notify(text)                               -- the server's answer to a hint the player asked for
        end
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Connecting: at start from config.txt, and from the title menu's Archipelago button (menu.lua), which saves it.
local function connectTo(server, slot, password)
    cfg.server, cfg.slot, cfg.password = server, slot, password or ""
    writeConfig()
    log("connecting to " .. server .. " as " .. slot)
    ap.status = "connecting"
    AP_Connect(server, slot, password or "")
end
MENU.install({
    status = function() return ap.status end,
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
    openMailbox = function(context) MAIL.open(context) end,
})
MAIL.install({ notify = notify, save = writeSave, cfg = cfg, connected = function() return ap.status == "connected" end })
TRAPS.install({ notify = notify, save = writeSave,
                announce = function(text) log(text); R.notify(text, playerState()) end,
                sender = function(index) return ap.from[index] end,
                home = function() return WALLS.home end, start = function() return WALLS.start end })
if cfg.server and cfg.server ~= "" and cfg.slot and cfg.slot ~= "" then
    log("connecting to " .. cfg.server .. " as " .. cfg.slot)
    AP_Connect(cfg.server, cfg.slot, cfg.password or "")
else
    log("not connected: use the Archipelago button on the title menu (or set server and slot in config.txt)")
end

-- Hints for Area Passes, bought with the server's hint points (!hint), offered at the walls.
local function wallNotice(area)
    local pass = "Area Pass: " .. area
    if hints.known[area] then return area .. " is sealed. " .. hints.known[area] end
    local text = "The way into " .. area .. " is sealed: it needs " .. pass .. "."
    local points, cost = (AP_HintPoints and AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if not points then return text end
    points, cost = tonumber(points), tonumber(cost)
    hints.offer, hints.offeredAt = area, tick
    -- Both cases say what the player has and what a hint costs (the user, 2026-11-04), with the configured key.
    if points >= cost then
        return text .. " Press " .. hints.key .. " for a hint: you have " .. points .. " points, a hint costs " .. cost .. "."
    end
    return text .. " Not enough points for a hint: you have " .. points .. " points, a hint costs " .. cost .. "."
end
local function askHint()
    local area = hints.offer
    if not area or tick - hints.offeredAt > 200 then return end            -- an offer lasts a minute
    local points, cost = (AP_HintPoints() or ""):match("^(%d+),(%d+)$")
    if points and tonumber(points) < tonumber(cost) then
        notify("Not enough hint points: you have " .. points .. ", a hint costs " .. cost .. ".")
        return
    end
    hints.offer, hints.asked = nil, tick
    AP_Say("!hint Area Pass: " .. area)
    notify("Asking the Archipelago server where Area Pass: " .. area .. " is...")
end
if RegisterKeyBind and Key and Key[hints.key] then
    RegisterKeyBind(Key[hints.key], function()
        ExecuteInGameThread(function()
            local ok, err = pcall(askHint)
            if not ok then log("hint error: " .. tostring(err)) end
        end)
    end)
end

-- Death Link (the slot's death_link option): dying sends a death to everyone linked; a death from them faints the
-- player through the game's own self-kill. A death the link caused is not sent back, and neither counts towards nor
-- resets the amnesty.
local function deathLink(ps)
    if not death.on then return end
    local okd, dead = pcall(function() return ps:IsPlayerDead() end)
    if not okd then return end
    if death.incoming then
        local cause = death.incoming
        death.incoming = nil
        if tick - death.at > DEATH_LATE then
            log("death link received while no player was in the world (" .. (tick - death.at) .. " updates ago): not applied: " .. cause)
        elseif not dead then
            death.caused = tick
            local pc = FindFirstOf("PalPlayerController")
            local ok, err = pcall(function() pc:SelfKillPlayer() end)
            notify("Death Link: " .. cause)
            log("death link received: " .. cause .. (ok and "" or (" (could not faint: " .. tostring(err) .. ")")))
        end
    end
    if dead and not death.wasDead then
        if death.caused and tick - death.caused < 50 then
            log("death link: this death came from the link, not sent back")
        else
            -- Amnesty (slot data options.death_link_amnesty): that many of your own faints are forgiven before one is
            -- sent. The count is kept in the seed's save file, so quitting does not reset it.
            local amnesty = tonumber(AP_SlotData("options.death_link_amnesty")) or 0
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
                AP_Bounce(string.format('{"time":%d,"source":"%s","cause":"%s"}', os.time(), (cfg.slot:gsub('"', "")),
                    (cause:gsub('"', ""))), "DeathLink")
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
        if techScan.tries == 40 then log("tech scan: gave up: " .. tostring(why)) end
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
        if loc and not ap.checked[loc] then locs[#locs + 1] = loc end
    end
    if #locs > 0 then
        sendChecks(locs)
        notify(#locs .. " shop slot(s) can't be bought (another mod removed their techs): their checks were sent.")
    end
end

local function update(ctx)
    tick = tick + 1
    P.start("poll")
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then log("event error: " .. tostring(err) .. " in " .. line) end
    end
    P.stop("poll")
    registerLazyHooks()
    P.start("menu")
    local okm, errm = pcall(MENU.update, ctx)
    P.stop("menu")
    if not okm then onceErr("menu", errm, "menu error: " .. tostring(errm)) end
    P.start("mail")
    local okx, errx = pcall(MAIL.update, ctx)
    P.stop("mail")
    if not okx then onceErr("mail", errx, "mailbox error: " .. tostring(errx)) end
    -- The first batch of items arrives just after the connection; wait a moment before locking anything.
    if ap.status == "connected" and not ap.ready and tick - ap.connectedTick >= 5 then
        ap.ready = true
        ap.shown = true
        local n = 0
        for _ in pairs(ap.items) do n = n + 1 end
        log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
    end
    -- Load the menus' classes up front, so their hooks are in place before the Technology menu first opens (hooked
    -- mid-draw, a bought card could flip to researched and stick on the game's white unlock flash).
    if ap.ready and not preloaded then
        preloaded = true
        ExecuteInGameThread(function()
            for _, h in ipairs(lazyHooks) do
                if not h.done then
                    local ok, err = pcall(LoadAsset, (h.class:gsub("_C$", "")))
                    if not ok then once("preload" .. h.class, "could not preload " .. h.class .. ": " .. tostring(err)) end
                end
            end
        end)
    end
    P.start("cards")
    refreshCards()
    P.stop("cards")
    if not techScan.report and techScan.tries < 40 and tick % 7 == 1 then
        P.start("scan")
        local td = safe(function() local ps = playerState(); return ps and ps:GetTechnologyData() end)
        if td and safe(function() return td:IsValid() end) then scanTechs(td) end
        P.stop("scan")
    end
    if ap.ready and techScan.report and not techScan.sent then sendRemovedSlots() end
    -- Area locks: walls on the borders of areas whose pass has not arrived (only in a seed with area locks on). After a
    -- world loads, nothing happens for SETTLE ticks (5 s): spawning into a world still loading can crash the game.
    if ap.ready then
        local pawn = safe(function() local ps = playerState(); return ps and ps:GetPawn() end)
        local world = pawn and pawn:IsValid() and safe(function() return tostring(pawn:GetAddress()) end)   -- new world, new pawn
        if world ~= wallsWorld then
            wallsWorld, worldTicks = world, 0
            seedWorld = nil                            -- looked at again (every 7th update) before any wall goes up
            WALLS.reset()
            techsSeen = nil                              -- another world's tech list: compare it in full
        end
        worldTicks = worldTicks + 1
        if world and worldTicks >= SETTLE and seedWorld then
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
            if up > 0 and not wallsLogged then wallsLogged = true; log("area locks: raising walls (" .. all .. " border pieces)") end
            -- Walking up to a wall: chat names the pass it needs and where it is if a hint said so, or offers to buy that
            -- hint with the hint key (once per area every 2 minutes).
            if on and tick % 7 == 5 then
                local okn, area = pcall(function()
                    local loc = pawn:K2_GetActorLocation()
                    return WALLS.lockedNear(loc.X, loc.Y, ap.passes)
                end)
                if okn and area and (hints.shown[area] or -1e9) + 400 <= tick then
                    hints.shown[area] = tick
                    notify(wallNotice(area))
                end
            end
            -- A player inside a locked area (loaded there, or past a wall) goes back to the starting area. Not while
            -- Ctrl+7 holds the walls without collision or removed: a player could drift across a border then.
            if on and tick % 7 == 3 and not held then
                local okl, where = pcall(function()
                    local loc = pawn:K2_GetActorLocation()
                    return WALLS.lockedAround(loc.X, loc.Y, ap.passes)
                end)
                lockedTicks = (okl and where) and lockedTicks + 1 or 0
                if lockedTicks >= 2 then
                    lockedTicks = 0
                    local h = WALLS.home
                    local okt, errt = pcall(function()
                        pawn:K2_TeleportTo({ X = h[1], Y = h[2], Z = h[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
                    end)
                    log("inside locked " .. tostring(where) .. ": sent home" .. (okt and "" or (" FAILED: " .. tostring(errt))))
                    notify(tostring(where) .. " is locked until its Area Pass arrives. Back to " .. WALLS.start .. ".")
                end
            end
        end
    end
    -- The work of every 7th update, in two phases so no one frame carries all of it (6dd356e did it all in one: an
    -- estimated 2-12 ms, unmeasured). First the traps' clock, the world check and the records; two updates later the
    -- techs, items, Death Link and traps, in the seed's world only (as that check found it).
    if tick % 7 == 0 then
        P.start("e7")
        local ps = playerState()
        local pawn = ps and safe(function() return ps:GetPawn() end)
        -- A running Slow Trap or Fool Trap ends on time whether or not the connection is up.
        local okk, errk = pcall(TRAPS.tick, { tick = tick, pawn = pawn })
        if not okk then onceErr("trapsk", errk, "traps error: " .. tostring(errk)) end
        if ps and ap.ready then seedWorld = checkWorld() end
        if ps and ap.ready and seedWorld then
            P.start("rec")
            pollRecords(ps)
            P.stop("rec")
        end
        P.stop("e7")
        if ps and ap.ready then P.records(ps) end
    elseif tick % 7 == 2 and ap.ready and seedWorld then
        local ps = playerState()
        if ps then
            P.start("e7")
            P.start("techs")
            local changed = syncTechs(ps)
            P.stop("techs")
            if changed then refreshTree() end
            applyItems(ps)
            local okdl, errdl = pcall(deathLink, ps)
            if not okdl then onceErr("death", errdl, "death link error: " .. tostring(errdl)) end
            -- Traps fire only once the world has settled (the walls' count), never while fainted or in the mailbox.
            local okt, errt = pcall(function()
                local pawn = safe(function() return ps:GetPawn() end)
                local okd, dead = pcall(function() return ps:IsPlayerDead() end)
                TRAPS.update({ tick = tick, ps = ps, pawn = pawn, settled = wallsWorld ~= nil and worldTicks >= SETTLE,
                               dead = not okd or dead, busy = MAIL.busy() })
            end)
            if not okt then onceErr("traps", errt, "traps error: " .. tostring(errt)) end
            P.stop("e7")
        end
    end
end

-- Ctrl+0 (perf test tools): after each update, the per-update load 6dd356e had and this build no longer has, so one
-- session can compare old and new. Results are thrown away; the game sees nothing it did not see in 6dd356e (the cards
-- are labelled again with the same text). An approximate replay of the cost, not the old code:
local function oldLoad(ctx)
    P.start("legacy")
    FindFirstOf("PalPlayerController")                   -- the menu's own controller lookup
    if ctx.pawn then FindAllOf("WBP_TitleMenu_C") end    -- the title menu, looked for in a world too
    if ap.ready and tick % 7 == 0 then FindAllOf("PalPlayerState") end     -- a second player-state walk
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
    if ap.ready and tick % 7 == 2 then writeSave(true) end   -- the save written whether or not it changed
    P.stop("legacy")
end

LoopAsync(300, function()
    ExecuteInGameThread(function()
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
    end)
    return false
end)

-- Test tools: only with test_tools=1 in config.txt (see test_tools.lua).
if cfg.test_tools == "1" then
    local okt, errt = pcall(function() require("test_tools").install() end)
    if not okt then log("test tools not loaded: " .. tostring(errt)) end
end
