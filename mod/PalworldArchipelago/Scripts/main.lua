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
local DEATH_LINK = require("death_link")
local HELD = require("held_notices")

local ITEMS = require("items")
local applyItems, openCrate = ITEMS.applyItems, ITEMS.openCrate

local CHECKS = require("checks")
local sendChecks, sendBoughtAgain, resetGoal, pollRecords =
    CHECKS.sendChecks, CHECKS.sendBoughtAgain, CHECKS.resetGoal, CHECKS.pollRecords

local keep, keepInPlace = UTIL.keep, UTIL.keepInPlace
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

local SHOP_CARDS = require("shop_cards")
SHOP_CARDS.install({ dir = modDir })
local refreshTree = SHOP_CARDS.refreshTree
local SHOP = require("shop")
local SOON = require("soon")
local guardedHook = UTIL.guardedHook
local inTick = false          -- state: true only while an update runs

SHOP.registerNativeHooks()

------------------------------------------------------------------------------------------------------------------------
-- State of the menus' preload, the hints at walls, Death Link, the area locks and the world.
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
local lockedTicks = 0         -- looks in a row inside a locked area: forgotten never (back to 0 outside one)
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

-- scout <location id> <item id> <player slot> <flags> <item name> <player name> <game>
local function onScout(locationText, itemText, playerText, flagsText, itemName, playerName, game)
    ap.scouted[tonumber(locationText)] = { id = tonumber(itemText), item = itemName, player = playerName, game = game,
                                           flags = tonumber(flagsText) or 0, own = tonumber(playerText) == ap.me }
end

-- checked <location id>: checked elsewhere (co-op, !collect)
local function onChecked(locationText)
    ap.checked[tonumber(locationText)] = true
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
    DEATH_LINK.applyOption()
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

local EVENT_HANDLERS = { status = onStatus, item = ITEMS.onItem, scout = onScout, checked = onChecked, bounce = DEATH_LINK.onBounce,
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
    if SHOP.hovered() and MENU.mainMenuUp() == false then SHOP.forgetHover() end
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
        local oks, news = pcall(SYNC.apply, ps, AP_SlotData, WORLD.key(), HELD.noticeLater)
        if not oks then
            onceErr("sync", news, "sync error: " .. tostring(news))
        elseif news then
            writeSave()
        end
        local okl, errl = pcall(HELD.showLater, safe(function() return ps:GetPawn() end))
        if not okl then onceErr("later", errl, "notice error: " .. tostring(errl)) end
    end
    local okdl, errdl = pcall(DEATH_LINK.step, ps)
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
    SHOP.registerLazyHooks()
    updateWindows(ctx)
    markReady()
    SHOP.preloadMenuClasses()
    P.start("cards")
    SHOP_CARDS.refreshCards()
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
    for _, card in ipairs(SHOP_CARDS.lastCards() or {}) do   -- every card labelled every update
        if card:IsValid() then
            local key = safe(function() return tostring(card:GetAddress()) end) or card
            pcall(SHOP_CARDS.relabel, card, key, true)
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
-- Never inside a research hook, nor inside itself (see UTIL.guarded), and at most once a frame:
-- waits are counted in updates, and updates run back to back would use them up with no time passing.
local function coreTick()
    if UTIL.insideHook() or inTick then
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
