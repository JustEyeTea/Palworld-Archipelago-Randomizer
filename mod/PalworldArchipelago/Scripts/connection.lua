-- The connection to the Archipelago server: connecting (at start-up from config.txt, and from the title menu),
-- the server's events read each update, what a new seed forgets, the seed's options, and when the connection is
-- ready. Wired by main.lua, which calls CONNECTION.readEvents and CONNECTION.markReady every update.
-- Tests: mod/test/harness.lua (run by tools/lua_harness.sh): groups "connect and receive", "reconnect does not
-- repeat one-off items" and "the title menu's Archipelago menu".
local CONNECTION = {}
local AREA_LOCKS = require("area_locks")
local CHECKS = require("checks")
local CLOCK = require("clock")
local CONFIG = require("config")
local CRATES = require("crates")
local D = require("ap_data")
local DEATH_LINK = require("death_link")
local ITEMS = require("items")
local MAIL = require("mailbox")
local P = require("perf")
local PLAYER = require("player")
local SAVE = require("save")
local STATE = require("ap_state")
local SYNC = require("sync")
local TECH_LOCK = require("tech_lock")
local TECHSCAN = require("techscan")
local TRAPS = require("traps")
local UTIL = require("util")
local WALL_HINTS = require("wall_hints")
local WALLS = require("walls")
local WORLD = require("world")
local WAIT = CLOCK.WAIT
local ap, slotFlag, slotNumber = STATE.ap, STATE.slotFlag, STATE.slotNumber
local cfg, writeConfig = CONFIG.cfg, CONFIG.write
local log = UTIL.log
local notify, loadSave = PLAYER.notify, SAVE.load
local sendBoughtAgain, resetGoal = CHECKS.sendBoughtAgain, CHECKS.resetGoal

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
    WALL_HINTS.resetHints()
    TECHSCAN.resetTechScan()
    log("a different seed or slot: progress of the last one forgotten")
end

-- The seed's options that shape this session: area locks and their cut of the map, the areas beyond the goal, and
-- Death Link; the run style and traps are logged.
local function applySeedOptions()
    AREA_LOCKS.setOn(slotFlag("options.area_locks"))
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
                         message = WALL_HINTS.onMessage }
local function onEvent(line)
    local fields = split(line)
    local handler = EVENT_HANDLERS[fields[1]]
    if handler then handler(table.unpack(fields, 2)) end
end

-- Connecting: at start from config.txt, and from the title menu's Archipelago menu (menu.lua), which saves it.
function CONNECTION.connectTo(server, slot, password)
    cfg.server, cfg.slot, cfg.password = server, slot, password or ""
    writeConfig()
    log("connecting to " .. server .. " as " .. slot)
    STATE.setStatus("connecting")
    AP_Connect(server, slot, password or "")
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
        log("connecting to " .. cfg.server .. " as " .. cfg.slot)
        AP_Connect(cfg.server, cfg.slot, cfg.password or "")
    else
        log("not connected: click the Archipelago banner on the title menu (or set server and slot in config.txt)")
    end
end

-- Everything the server sent since the last update, one event line at a time (onEvent).
function CONNECTION.readEvents()
    P.start("poll")
    for line in AP_Poll():gmatch("[^\n]+") do
        local ok, err = pcall(onEvent, line)
        if not ok then log("event error: " .. tostring(err) .. " in " .. line) end
    end
    P.stop("poll")
end

-- Ready once the first batch of items is in, a moment after connecting: only then is anything locked.
function CONNECTION.markReady()
    if ap.status ~= "connected" or ap.ready or CLOCK.now() - ap.connectedTick < WAIT.firstItems then return end
    ap.ready = true
    ap.shopOpen = true
    local n = 0
    for _ in pairs(ap.items) do n = n + 1 end
    log("ready: " .. n .. " item(s) received, slot " .. tostring(ap.me))
end

return CONNECTION
