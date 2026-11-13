-- The connection to the Archipelago server: connecting (at start-up from config.txt, and from the title menu),
-- the server's events read each update, what a new seed forgets, the seed's options, and when the connection is
-- ready. Wired by main.lua, which calls CONNECTION.readEvents and CONNECTION.markReady every update.
-- Tests: mod/test/tests/core.lua, mod/test/tests/core_loop.lua, mod/test/tests/title_menu.lua; groups
--   "loading the mod" (started offline), "connect and receive", "reconnect does not repeat one-off items",
--   "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local CONNECTION = {}
local AREA_LOCKS = require("area_locks")
local CHECKS = require("checks")
local CLOCK = require("clock")
local CONFIG = require("config")
local CRATES = require("crates")
local DATA = require("ap_data")
local DEATH_LINK = require("death_link")
local GLOW_CHECKS = require("glow_checks")
local ITEMS = require("items")
local MAIL = require("mailbox")
local PERF = require("perf")
local PLAYER = require("player")
local SAVE = require("save")
local SLOT = require("slot_data")
local STATE = require("ap_state")
local RUN_STYLE = require("run_style")
local TECH_LOCK = require("tech_lock")
local TECHSCAN = require("techscan")
local TRAPS = require("traps")
local UTIL = require("util")
local WALL_HINTS = require("wall_hints")
local WALLS = require("walls")
local WORLD = require("world")
local WAIT = CLOCK.WAIT
local ap = STATE.ap
local cfg, writeConfig = CONFIG.cfg, CONFIG.write
local log = UTIL.log
local notify, loadSave = PLAYER.notify, SAVE.load
local sendBoughtAgain, resetGoal = CHECKS.sendBoughtAgain, CHECKS.resetGoal

-- Server events: one line each from AP_Poll, fields separated by tabs. The kinds and their fields, in order, are
-- defined in cppmod/APConnector/src/ap_bridge.hpp (take_events); each handler below takes them by name, in that order.
local function split(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do
        f[#f + 1] = part
    end
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



-- Forgets everything tied to the last seed: a different seed or slot (`seed`, `slot`) connected. One call per topic;
-- what each forgets is written at its state.
local function resetSeed(seed, slot)
    STATE.forgetSeed()
    WALLS.setVisited(ap.visited)              -- (the new table: the map reads it)
    CRATES.reset()
    RUN_STYLE.reset()
    MAIL.reset()
    TRAPS.reset()
    TECH_LOCK.techsChanged()
    resetGoal()
    WORLD.resetSeedWorld()
    WALL_HINTS.resetHints()
    TECHSCAN.resetTechScan()
    log("a different seed or slot (seed " .. tostring(ap.seed) .. ", slot " .. tostring(ap.slotName) .. " -> seed "
        .. tostring(seed) .. ", slot " .. tostring(slot) .. "): progress of the last one forgotten")
end

-- The seed's cut of the map (options.lock_size: 0 the 15 regions, 1 the 75 areas). Seeds made before the option was
-- renamed send options.area_size, with the same numbers (its values were "areas" for the 15 and "regions" for the 75);
-- older seeds send neither. WALLS names each cut as Lock Size does.
local function applyLockSize()
    local size = SLOT.text("options.lock_size")
    local useAreas                                  -- true: the 75 areas; false: the 15 regions
    if size ~= nil and size ~= "" then
        useAreas = size == "1" or size == "areas"
    else                                            -- a seed made before the rename
        local old = SLOT.text("options.area_size")
        useAreas = old == "1" or old == "regions"
    end
    WALLS.setLayout(useAreas and "areas" or "regions")
end

-- Locks beyond the goal (options.beyond_goal: 0 locked, 1 passes, 2 open; beyond_goal_areas): their passes are not in
-- this seed. Locked, their walls stay up for good; open, they are open from the start.
local function applyBeyondGoal()
    ap.beyond = {}
    local nBeyond = 0
    for lock in SLOT.text("beyond_goal_areas"):gmatch("[^|]+") do
        ap.beyond[lock], nBeyond = true, nBeyond + 1
    end
    local mode = SLOT.text("options.beyond_goal")
    ap.beyondOpen = mode == "2" or mode == "open"
    if ap.beyondOpen then
        for lock in pairs(ap.beyond) do
            ap.passes[lock] = true
        end
    end
    WALLS.setBeyond(ap.beyondOpen and {} or ap.beyond)    -- sealed walls and stamps (open ones come down)
    if nBeyond > 0 then
        log("areas beyond the goal: " .. nBeyond .. (ap.beyondOpen and ", open from the start" or ", sealed for good"))
    end
end

-- The options that are only logged: the run style, Speed Boost and traps.
local function logRunOptions()
    local style = RUN_STYLE.style(SLOT.text)
    if style ~= 0 then
        log("run style: " .. RUN_STYLE.NAMES[style] .. " (techs also hand over what they make)")
    end
    if RUN_STYLE.boost(SLOT.text) then
        log("speed boost: on (this seed changes the world's EXP, work speed and gathering)")
    end
    local chance = SLOT.number("options.trap_chance", 0)
    if chance > 0 then
        log("traps: " .. chance .. "% of filler items are traps in this seed")
    end
end

-- The seed's options that shape this session: Area Locks and their cut of the map, the locks beyond the goal, Death
-- Link, and whether fast-travel statues are checks (their glow); the run style and traps are logged.
local function applySeedOptions()
    AREA_LOCKS.setOn(SLOT.flag("options.area_locks"))
    applyLockSize()
    applyBeyondGoal()
    DEATH_LINK.applyOption()
    GLOW_CHECKS.setFastTravelChecks(SLOT.text("options.fast_travel_checks"))
    CHECKS.logSeedGoal()
    logRunOptions()
end

-- Connected (again): the slot, the seed and its save, the techs left as research, what each shop slot holds, and the
-- seed's options. `was` is the status before.
local function onConnected(was)
    STATE.setStatus("connected")
    ap.connectedTick = CLOCK.now()
    ap.me = tonumber(SLOT.text("slot"))
    local seed = SLOT.text("seed")
    if seed ~= "" and (seed ~= ap.seed or cfg.slot ~= ap.slotName) then
        if ap.seed then    -- another seed or slot: nothing of the last one carries over
            resetSeed(seed, cfg.slot)
        end
        ap.seed, ap.slotName = seed, cfg.slot
        loadSave()
    end
    local research = SLOT.text("research_techs")
    TECH_LOCK.setResearch(research)
    TECH_LOCK.keepResearch(research)
    local locs = {}
    for _, slot in pairs(DATA.shop) do
        locs[#locs + 1] = tostring(slot.loc)
    end
    AP_Scout(table.concat(locs, ","))
    ap.sent = {}
    ap.goalSent = false                    -- a goal sent on a connection that was already dead goes again
    sendBoughtAgain()
    if was ~= "connected" then
        notify("Connected to Archipelago as " .. cfg.slot)
    end
    applySeedOptions()
end

-- status <state> [detail]: connecting, socket, connected, refused, disconnected, or error (only logged)
local function onStatus(state, detail)
    log("status: " .. (state or "") .. (detail and (" " .. detail) or ""))
    if state == "connected" then
        onConnected(ap.status)
    elseif state == "connecting" then
        if ap.status ~= "connected" then
            STATE.setStatus("connecting")
        end
    elseif state == "refused" then
        STATE.setStatus("refused")
        notify("Archipelago refused the connection: " .. tostring(detail))
    elseif state == "disconnected" then
        STATE.setStatus("disconnected")
        ap.ready = false
    end
end

local EVENT_HANDLERS = { status = onStatus, item = ITEMS.onItem, scout = onScout, checked = onChecked,
                         bounce = DEATH_LINK.onBounce, message = WALL_HINTS.onMessage }
-- Hands one event line to its kind's handler, the fields after the kind as its arguments.
local function onEvent(line)
    local fields = split(line)
    local handler = EVENT_HANDLERS[fields[1]]
    if handler then
        handler(table.unpack(fields, 2))
    end
end

-- Connecting: at start from config.txt, and from the title menu's Archipelago menu (menu.lua), which saves it.
-- Asks the connector to connect, and says so: the one way the mod connects.
local function connect(server, slot, password)
    log("connecting to " .. server .. " as " .. slot)
    STATE.setStatus("connecting")
    AP_Connect(server, slot, password or "")
end

-- Connects to what the title menu gives, and keeps it in config.txt.
function CONNECTION.connectTo(server, slot, password)
    cfg.server, cfg.slot, cfg.password = server, slot, password or ""
    writeConfig()
    connect(server, slot, password)
end
-- Disconnects at the player's asking (the title menu's Disconnect).
function CONNECTION.disconnect()
    AP_Disconnect()
    STATE.setStatus("disconnected")
    ap.ready = false
    log("disconnected by the player")
    notify("Disconnected from Archipelago.")
end

-- Connects at start-up to the server and slot config.txt names, if it names both.
function CONNECTION.connectFromConfig()
    if cfg.server and cfg.server ~= "" and cfg.slot and cfg.slot ~= "" then
        connect(cfg.server, cfg.slot, cfg.password)
    else
        log("not connected: click the Archipelago banner on the title menu (or set server and slot in config.txt)")
    end
end

-- Everything the server sent since the last update, one event line at a time (onEvent).
function CONNECTION.readEvents()
    PERF.start("poll")
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then
            log("event error: " .. tostring(err) .. " in " .. line)
        end
    end
    PERF.stop("poll")
end

-- Not connected, the seed in memory follows the loaded world: when worlds.txt knows its seed (SAVE.seedOfWorld) and
-- that is not the one in memory, that seed's save is loaded and the shop opens, so a purchase is queued in its save
-- and sent on connecting, as with a dropped connection. Nothing else runs offline: no item is applied and no tech
-- locked (both need the server's items), and the game's records are sent on connecting. Connecting to another seed
-- later resets this one as usual; what was queued for it stays in its save until it connects again. The research
-- techs stay the last connected seed's (research.txt). Untested in game.
-- Looked at once per pawn (a world load brings a new one), so a world with no known seed costs one look.
local offlinePawn = nil       -- state: the pawn the loaded world's seed was last looked up for. Forgotten never
function CONNECTION.knowSeedOffline()
    local pawn = PLAYER.playerPawn()
    local key = pawn and pawn:IsValid() and UTIL.addr(pawn)
    if not key or key == offlinePawn then return end
    offlinePawn = key
    local world = WORLD.folder()
    if not world then return end
    local seed, slot = SAVE.seedOfWorld(world)
    if not seed or (seed == ap.seed and slot == ap.slotName) then return end
    if ap.seed then
        resetSeed(seed, slot)
    end
    ap.seed, ap.slotName = seed, slot
    loadSave()
    ap.shopOpen = true
    log("not connected: world " .. world .. " is played with seed " .. seed .. " as " .. slot .. " (worlds.txt);"
        .. " its save is loaded, and shop slots bought now are sent on connecting")
end

-- Ready once the first batch of items is in, a moment after connecting: only then is anything locked.
function CONNECTION.markReady()
    if ap.status ~= "connected" or ap.ready or CLOCK.now() - ap.connectedTick < WAIT.firstItems then return end
    ap.ready = true
    ap.shopOpen = true
    local n = 0
    for _ in pairs(ap.items) do
        n = n + 1
    end
    log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
end

return CONNECTION
