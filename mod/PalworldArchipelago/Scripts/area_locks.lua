-- Area Locks: walls on the borders of locks whose pass has not arrived, the map that shows them, the open locks the
-- player has visited, and sending the player home from inside a lock still locked. The walls themselves are
-- walls.lua's; this file decides when they act. Wired by main.lua (AREA_LOCKS.configureWalls); its update calls
-- AREA_LOCKS.update.
-- Tests: mod/test/tests/walls.lua, mod/test/tests/world.lua; groups "area locks", "a new world", "another world"
--   (tools/lua_harness.sh, in CI).
local AREA_LOCKS = {}
local ART = require("art")
local CONFIG = require("config")
local PERF = require("perf")
local PLAYER = require("player")
local STATE = require("ap_state")
local UTIL = require("util")
local WALL_HINTS = require("wall_hints")
local WALLS = require("walls")
local WORLD = require("world")
local ap = STATE.ap
local cfg = CONFIG.cfg
local keepAlive, keepInPlace = UTIL.keepAlive, UTIL.keepInPlace
local log, onceErr = UTIL.log, UTIL.onceErr
local notify, playerState = PLAYER.notify, PLAYER.playerState
local SENT_HOME_AFTER = 2       -- looks in a row (one per cycle) inside a lock still locked before going home
local CM_PER_METRE = 100        -- config.txt gives the walls' distances in metres; the game measures in centimetres

local wallsLogged = false     -- the first raising of walls was logged: forgotten never (once a session)
local lockedTicks = 0         -- looks in a row inside a lock still locked: forgotten never (back to 0 outside one)
-- The seed's area_locks option, read once a connection (slot data is fixed for a connection), not every update: each
-- read parses the slot data's JSON in the connector and takes the connector's lock.
local areaLocks = false       -- state: set each connection (AREA_LOCKS.setOn, from applySeedOptions)

-- Sets whether this seed has area locks (each connection).
function AREA_LOCKS.setOn(on)
    areaLocks = on
end

-- Hands the walls, the map and the wall skins their settings from config.txt, and the walls and the art what keeps
-- their textures alive (start-up). `dir` is the mod's folder.
function AREA_LOCKS.configureWalls(dir)
    local settings = {
        keepAlive = keepAlive, keepInPlace = keepInPlace, dir = dir,
        visited = ap.visited,                 -- (the same table: the map reads it)
        cppOff = cfg.map_cpp == "0",
        chartOff = cfg.map_chart == "0",
        iconsOff = cfg.map_icons == "0",
        chartBordersOff = cfg.map_regions == "0",       -- (config.txt's key keeps its name)
        mapStyle = cfg.map_style == "chart" and "chart" or "territories",
        testFogColour = cfg.test_tools == "1",
    }
    -- wall skins (wall_skins.lua): wall_skin=paws|area|red, wall_tiling=U,V and wall_scroll=U,V in config.txt. A
    -- setting that is not two numbers is said once and left out, so its default stands.
    local function pair(key)
        local text = cfg[key]
        if not text then return nil end
        local u, v = text:match("^%s*([%d.]+)%s*,%s*([-%d.]+)%s*$")
        local first, second = tonumber(u), tonumber(v)
        if first and second then return { first, second } end
        log("config.txt: " .. key .. "=" .. text .. " is not two numbers (as 15,25); its default is used")
        return nil
    end
    settings.tiling, settings.scroll = pair("wall_tiling"), pair("wall_scroll")
    -- wall_radius=<m>: walls stand only this near you (0: everywhere); wall_fade=<near>,<far> in metres (M_APWall
    -- walls)
    local radius = tonumber(cfg.wall_radius or "")
    if radius and radius >= 0 then
        settings.radius = radius * CM_PER_METRE
    end
    local fade = pair("wall_fade")
    local near, far = fade and fade[1], fade and fade[2]
    if fade and far > near then
        settings.fade = { near * CM_PER_METRE, far * CM_PER_METRE }
    end
    WALLS.install(settings)
    ART.install({ dir = dir })
    WALLS.setSkin(cfg.wall_skin)
end

-- The open locks the player stands in, remembered for the map (an unlocked lock not yet visited shows an open stamp).
local function rememberVisited(pawn)
    local x, y = PLAYER.pawnXY(pawn)
    if not x then return end
    local okv, here = pcall(WALLS.lockAt, x, y)
    if not (okv and here) or ap.visited[here] or here == "Open sea" then return end
    if here == WALLS.start or ap.passes[here] then
        ap.visited[here] = true
        log("visited " .. here)
    end
end

-- A player inside a lock still locked (loaded there, or past a wall) for SENT_HOME_AFTER looks in a row goes back to
-- the starting lock.
local function sendHomeIfLocked(pawn)
    local x, y = PLAYER.pawnXY(pawn)
    local okl, where = false, nil
    if x then
        okl, where = pcall(WALLS.lockedAround, x, y, ap.passes)
    end
    lockedTicks = (okl and where) and lockedTicks + 1 or 0
    if lockedTicks < SENT_HOME_AFTER then return end
    lockedTicks = 0
    local home = WALLS.homeLocation()
    local okt, errt = pcall(function()
        pawn:K2_TeleportTo(home, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    log("inside locked " .. tostring(where) .. ": sent home" .. (okt and "" or (" FAILED: " .. tostring(errt))))
    notify(tostring(where) .. ((ap.beyond and ap.beyond[where]) and " is beyond this seed's goal."
        or " is locked until its pass arrives.") .. " Back to " .. WALLS.start .. ".")
end

-- Area Locks: walls on the borders of locks whose pass has not arrived (only in a seed with Area Locks on), and the
-- map. Nothing happens for WAIT.settle after a world loads: spawning into a world still loading can crash the game.
function AREA_LOCKS.update(pawn)
    if WORLD.key() and WORLD.seedWorld() == false then
        pcall(WALLS.mapOff)                        -- (C++ would show the seed's map here)
    end
    if not (WORLD.settled() and WORLD.seedWorld()) then return end
    local on = areaLocks
    -- Ctrl+7 (perf test tools) can hold the walls in a test state: nothing is raised, lowered or checked then.
    local held = PERF.walls ~= "full"
    PERF.start("walls")
    if not held then
        local ok, err = pcall(WALLS.update, on, ap.passes, pawn)
        if not ok then
            onceErr("walls", err, "walls error: " .. tostring(err))
        end
    end
    PERF.stop("walls")
    PERF.start("map")
    local ok, err = pcall(WALLS.updateMap, on, ap.passes, pawn)
    PERF.stop("map")
    if not ok then
        onceErr("map", err, "map error: " .. tostring(err))
    end
    local up, all = WALLS.count()
    if up > 0 and not wallsLogged then
        wallsLogged = true
        log("area locks: raising walls (" .. all .. " border pieces)")
    end
end

-- Whether the area locks act on the player this update: ready (a pawn was read), in the seed's world once it has
-- settled, and with area locks on. Inside a stage (a dungeon, a tower's arena) the map position says nothing about
-- the lock the player entered it from: no notice, no visit and no sending home there.
local function areaLocksApply(pawn)
    if not (pawn and WORLD.settled() and WORLD.seedWorld() and areaLocks) then return false end
    local okS, inStage = pcall(function() return playerState():IsInStage() end)
    return not (okS and inStage)
end

-- The locks phase: the open locks the player stands in, and sending the player home from inside a locked one.
function AREA_LOCKS.phaseLocks(pawn)
    if not areaLocksApply(pawn) then return end
    rememberVisited(pawn)
    -- Not while Ctrl+7 holds the walls without collision or removed: a player could drift across a border then.
    if PERF.walls == "full" then
        sendHomeIfLocked(pawn)
    end
end

-- The wall-notice phase: the chat notice and hint offer at a locked wall the player walks up to.
function AREA_LOCKS.phaseWallNotice(pawn)
    if not areaLocksApply(pawn) then return end
    WALL_HINTS.noticeLockedWall(pawn)
end

return AREA_LOCKS
