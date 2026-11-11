-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red grid by the World Tree gate) stretched into
-- pieces along every border between locked parts of the map; a piece stays up while either part it separates is locked.
-- This file keeps the pieces (raising, hiding, opening, forgetting) and is the table main.lua sees (W). Its parts:
-- areas.lua (the cut of the map, what is open), wall_skins.lua (the looks), map_picture, map_icons, map_fog (the map).
-- Tests: mod/test/harness.lua, groups "area locks" and "the world map".
-- W, the table main.lua sees. Its fields:
--   set by main.lua (config.txt, slot data): keep, keepInPlace, dir, radius, fade, tiling, scroll, mapStyle, cppOff,
--     testFogColour, chartOff, iconsOff, regionsOff, visited (main.lua's own set), and beyond (through setBeyond);
--     each part sets its own defaults at install
--   called by main.lua and its other modules: update, updateMap, reset, setLayout, setBeyond, setSkin, cycleSkin,
--     perfMode, count, lockedNear, lockedAround, areaAt, passName, parentOf, slugOf, mapShown, mapOff, oldSweep;
--     read: layout (the cut's name), start, home, SKINS
--   for the harness only: segDist, stampSize, worldAt, linearOf, modAsset, pieceSkin, AREA_COLOURS
local W = {}
W.layout = "areas"
-- walls.lua is made of parts, one topic each. Each keeps state for this copy of walls.lua: the game loads walls.lua
-- once, and the harness loads it again (dofile) for each test that wants a fresh start, so each part is loaded afresh
-- with it (require alone would hand back the copy already loaded).
local function freshPart(name)
    package.loaded[name] = nil
    return require(name)
end
local AREAS = freshPart("areas")
AREAS.install(W)
local WALL_SKINS = freshPart("wall_skins")
local MAP_PICTURE = freshPart("map_picture")
local MAP_ICONS = freshPart("map_icons")
local MAP_FOG = freshPart("map_fog")
local layout, isOpen = AREAS.layout, AREAS.isOpen
W.passName, W.areaAt, W.lockedAround, W.parentOf = AREAS.passName, AREAS.areaAt, AREAS.lockedAround, AREAS.parentOf
W.setBeyond, W.slugOf = AREAS.setBeyond, AREAS.slugOf
W.start, W.home = layout.start, layout.map.home
local P = require("perf")
local UTIL = require("util")
local log = UTIL.log
local once = UTIL.onceIn("walls")

local WALL = "/Game/Pal/Blueprint/System/Volume/BP_PalBlockingVolume.BP_PalBlockingVolume_C"
local WALL_CLASS = "BP_PalBlockingVolume_C"     -- the same class by the short name FindAllOf takes
-- Sizes of one wall piece, all in centimetres (the game's unit).
local SPAWN_ALWAYS = 1        -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn: a piece goes up wherever it stands
local MIN_SCALE = 0.01        -- the height scale a shrinking piece ends at (never 0)
local CUBE_CM = 100           -- the blocking cube's side at scale 1: a piece's scale is its size / CUBE_CM
local THICK_CM = 400          -- 4 m thick, so nothing fast slips through
local HEIGHT_CM = 300000      -- 3 km tall: from 1 km below sea level to 2 km above
local MID_Z_CM = 50000        -- the piece's middle, 500 m above sea level: halfway between those two
local PER_TICK = 30           -- pieces raised or taken down per update, to spread the work
local SHRINK_S = 2.0          -- an opened wall (not a dissolving one) shrinks away over 2 s of the game's clock
-- Every piece is raised at world load, as before; only those near the player are shown (the user, 2026-11-08: fewer
-- walls drawn, more FPS, and "let the borders load in at the beginning"): shown within W.radius, hidden (the game's
-- own SetActorHiddenInGame; collision stays) past W.radius + HIDE_MARGIN, so a piece at the edge doesn't flicker.
-- dev.41-42 raised and destroyed pieces as the player moved; dev.42 crashed at a wall (a dead object called), and
-- spawning and destroying all the time only makes more dead objects. 0: every piece shown.
W.radius = 7500               -- 75 m (config wall_radius, in metres)
local HIDE_MARGIN = 2500      -- 25 m
local VIS_PER_TICK = 120      -- pieces shown or hidden an update (a teleport changes many at once)
local hiddenAt = {}           -- piece -> true while hidden by distance

local raised = {}             -- piece index -> wall actor
local lastPasses, lastPawn = nil, nil   -- what main.lua handed W.update last: new pieces are dressed for those
                                        -- passes, and the glow follows that pawn
local raisedAt = {}           -- piece index -> its actor's address, to tell it is still there without calling it
local nRaised = 0             -- how many raised holds (counted as it changes: W.count ran every update)
local cls, gs = nil, nil
-- Each piece's direction, worked out once (lockedNear did it for every raised piece every 7th update).
local trig = {}
local function buildTrig()
    trig = {}
    for i, w in ipairs(layout.walls) do
        local yaw = math.rad(w[4])
        trig[i] = { math.cos(yaw), math.sin(yaw) }
    end
end
buildTrig()


-- The wall class (and the walls' material) are kept loaded for the whole session through W.keep (set by the core):
-- left alone, the game frees them on the way back to the title, and reloading them while a world loads in was the
-- likely cause of a crash on re-entering a world.
W.keep = function() end
-- The core's keepInPlace(place, obj): keeps obj in place of what was kept at that place; returns the place.
W.keepInPlace = function(place) return place end
local function ready()
    if cls and cls:IsValid() and gs and gs:IsValid() then return true end
    pcall(LoadAsset, (WALL:gsub("_C$", "")))
    cls = StaticFindObject(WALL)
    gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if cls and cls:IsValid() then W.keep(cls) end
    return cls ~= nil and cls:IsValid() and gs ~= nil and gs:IsValid()
end
-- What ready() did not find, for the log: the wall class (a game update could rename it) or the spawning library.
local function missingForWalls()
    if not (cls and cls:IsValid()) then
        return "the wall class " .. WALL
    end
    return "GameplayStatics"
end

-- Forgets piece i was raised, with its look: a new actor raised for it starts shown and undressed.
local function forget(i)
    if raised[i] then raised[i], nRaised = nil, nRaised - 1 end
    raisedAt[i] = nil
    WALL_SKINS.forget(i)
    hiddenAt[i] = nil
end
local opening = {}            -- the pieces opening: { actor, scale X, scale Y, started (game s), addr = its address,
                              -- dissolving, mid = its dissolving material, collisionOff, steps }
-- The addresses of the walls the game still has. FindAllOf lists live objects only, so a wall of a world that is gone
-- is told apart without calling it (IsValid included: its memory may be freed).
local function liveWallAddresses()
    local live = {}
    for _, a in ipairs(FindAllOf(WALL_CLASS) or {}) do
        local addr = UTIL.addr(a)
        if addr then
            live[addr] = true
        end
    end
    return live
end
-- A new world (another save, back from the title): its walls are gone with the old one; start over. Only walls that
-- are really gone are forgotten, opening ones too: the core's world key is the pawn, which also changes (or reads nil
-- for a moment) in the same world, and a wall forgotten while still standing could never be taken down.
function W.reset()
    lastPawn = nil                                             -- (the glow's pawn: the core hands the new one over)
    WALL_SKINS.dropCaches()
    MAP_FOG.resetMapShown()
    MAP_FOG.resetMaskReads()
    local live = liveWallAddresses()
    for i in pairs(raised) do
        if not live[raisedAt[i]] then
            forget(i)
        end
    end
    local still = {}
    for _, s in ipairs(opening) do
        if live[s.addr] then
            still[#still + 1] = s
        end
    end
    opening = still
end

-- How far a spot is from piece i (a segment: its middle, its direction, its length), in the plane.
local function segDist(i, x, y)
    local w, t = layout.walls[i], trig[i]
    local dx, dy = x - w[1], y - w[2]
    local along, half = dx * t[1] + dy * t[2], w[3] / 2
    if along > half then along = half elseif along < -half then along = -half end
    local px, py = dx - along * t[1], dy - along * t[2]
    return math.sqrt(px * px + py * py)
end
W.segDist = segDist

local function raise(i, pawn)
    local w = layout.walls[i]
    local x, y, length, yaw = w[1], w[2], w[3], math.rad(w[4])
    local t = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
                Translation = { X = x, Y = y, Z = MID_Z_CM },
                Scale3D = { X = length / CUBE_CM, Y = THICK_CM / CUBE_CM, Z = HEIGHT_CM / CUBE_CM } }
    local a = gs:BeginDeferredActorSpawnFromClass(pawn, cls, t, SPAWN_ALWAYS, nil)
    if not a or not a:IsValid() then return false end
    gs:FinishSpawningActor(a, t)
    WALL_SKINS.skinNew(a, i)
    raised[i] = a
    raisedAt[i] = UTIL.addr(a)
    nRaised = nRaised + 1
    return true
end

-- Opening a wall: it shrinks to nothing (top and bottom towards its middle), stops blocking halfway, and is then
-- removed. It used to sink with K2_SetActorLocation, whose out-parameter FHitResult (a struct of structs, left
-- unfilled without a sweep) UE4SS copies back into Lua: that crashed the game twice on 2026-11-05, both times within
-- 2 s of a Region Pass, in UE4SS's nested push_structproperty (reading 0x7b and 0x0a). SetActorScale3D has no
-- out-parameters.
-- The red grid shows only around a wall that blocks, so a wall keeps blocking until it is halfway down. Stepped from the
-- core's 300 ms update, on the game thread: no loop of its own. dev.42-45 had a 33 ms LoopAsync for it and the glow;
-- LoopAsync's callback runs on another thread over the same Lua state, and with it running 30 times a second the game
-- crashed twice (stack 08E98397) and dev.45, its callback cut down to a flag and a prebuilt function, still logged
-- "Ref was not function" three times and a broken ipairs iterator: Lua's state corrupted.
-- A dissolving piece goes by the game's clock, the material's own, not by counting steps (dev.41 playtest: removed
-- at 80 to 85% dissolved; dev.46, its tail 0.8 s, still not quite through): blocking stops at DISSOLVE_S/2, the piece
-- goes at DISSOLVE_S + DISSOLVE_TAIL (the material's Time node may run behind GetTimeSeconds; the first one logs it).
local DISSOLVE_S, DISSOLVE_TAIL = 1.6, 2.4
-- One step of an opening piece at the game's time `now`: shrunk (unless it dissolves), let through halfway, destroyed
-- at the end. True while it is still opening.
local function stepOne(s, now)
    local a = s[1]
    local span = s.dissolving and DISSOLVE_S or SHRINK_S
    local half = not s.collisionOff and now >= s[4] + span / 2
    local done = now >= s[4] + span + (s.dissolving and DISSOLVE_TAIL or 0)
    if not s.dissolving then                     -- shrinking: top and bottom towards the middle
        local t = math.min(1, (now - s[4]) / SHRINK_S)
        local eased = t * t * (3 - 2 * t)        -- slow, fast, slow
        local height = math.max(MIN_SCALE, HEIGHT_CM / CUBE_CM * (1 - eased))
        pcall(function() a:SetActorScale3D({ X = s[2], Y = s[3], Z = height }) end)
    end
    if half then s.collisionOff = true; pcall(function() a:SetActorEnableCollision(false) end) end
    if not done then
        return true
    end
    if s.dissolving then
        once("dissolved", string.format("wall skin paws: an opened wall went %.2f s after it began dissolving"
            .. " (the game's clock; the dissolve is %.1f s), %d update(s)", now - s[4], DISSOLVE_S, s.steps))
    end
    pcall(function() a:K2_DestroyActor() end)
    return false
end
-- Each update: every opening piece one step on, by the game's clock (or the updates counted, when it can't be read).
local function stepOpeningPieces()
    local still = {}
    for _, s in ipairs(opening) do
        local a = s[1]
        if a:IsValid() then
            s.steps = (s.steps or 0) + 1
            local ok, now = pcall(function() return gs:GetTimeSeconds(a) end)
            if not (ok and type(now) == "number") then now = s[4] + s.steps * UTIL.UPDATE_MS / 1000 end
            if stepOne(s, now) then
                still[#still + 1] = s
            end
        end
    end
    opening = still
end
-- Takes every opening piece down at once (a change of cut, or an error in the opening step): a piece left in no list
-- would stand, still blocking, for good.
local function destroyOpening()
    for _, s in ipairs(opening) do
        pcall(function()
            if s[1]:IsValid() then
                s[1]:K2_DestroyActor()
            end
        end)
    end
    opening = {}
end
-- Each core update (game thread): the opening pieces stepped, then the glow told where the player is.
local function stepOpeningAndGlow()
    if #opening > 0 then
        local ok, err = pcall(stepOpeningPieces)
        if not ok then
            log("opening error: " .. tostring(err))
            destroyOpening()
        end
    end
    local ok, err = pcall(WALL_SKINS.glowTick)
    if not ok then once("glow", "wall glow error: " .. tostring(err)) end
end
-- Starts opening piece i: with the paws skin it dissolves (wall_skins.lua's dissolving: its material eats it away
-- over DISSOLVE_S by the game's clock, an edge glowing); otherwise it shrinks. Either way it stops blocking halfway
-- and then goes.
local function startOpening(i, pawn)
    local a, wore, addr = raised[i], WALL_SKINS.wornBy(i), raisedAt[i]
    forget(i)
    if not (a and a:IsValid()) then return end
    local ok, mid, start = pcall(WALL_SKINS.dissolving, wore, pawn)
    local m = ok and mid and WALL_SKINS.meshOf(a)
    if m then pcall(function() m:SetMaterial(0, mid) end) end
    local okT, now = pcall(function() return gs:GetTimeSeconds(a) end)
    now = (m and start) or (okT and type(now) == "number" and now) or 0
    opening[#opening + 1] = { a, layout.walls[i][3] / CUBE_CM, THICK_CM / CUBE_CM, now, addr = addr,
                              dissolving = m and true or nil, mid = m and mid or nil }
end


-- Walls the game removed (back to the title, another world) are noticed by checking a share of the pieces each
-- update, all of them every 14 updates (4 s): 6dd356e checked all 818 every update (an estimated 0.3-0.5 ms,
-- unmeasured). A new world is noticed at once anyway: main.lua resets on a new pawn.
local CHECK_PER_TICK = 60
local checkAt = 0
local function checkSome()
    local n = #layout.walls
    for _ = 1, math.min(CHECK_PER_TICK, n) do
        checkAt = checkAt % n + 1
        local a = raised[checkAt]
        if a and not a:IsValid() then forget(checkAt) end
    end
end
function W.oldSweep()                 -- 6dd356e's check of every piece (only for the perf probe's Ctrl+0 replay)
    for _, a in pairs(raised) do a:IsValid() end
end

-- Shows the raised pieces near the player and hides the rest (W.radius; a few at a time; a dissolving piece has left
-- raised already). Without the player's position, or with W.radius 0, every piece is shown.
local function showNear(pawn)
    local px, py = nil, nil
    if W.radius > 0 then
        local okL, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if okL and loc and loc.X then px, py = loc.X, loc.Y end
    end
    local budget = VIS_PER_TICK
    for i, a in pairs(raised) do
        if budget <= 0 then break end
        local d = px and segDist(i, px, py)
        local hide = (d and d > W.radius + HIDE_MARGIN) and true or nil
        if d and not hide and hiddenAt[i] and d > W.radius then hide = true end   -- between: as it was
        if hide ~= hiddenAt[i] then
            if a:IsValid() then
                pcall(function() a:SetActorHiddenInGame(hide == true) end)
                hiddenAt[i] = hide
                budget = budget - 1
            end
        end
    end
end

-- Brings the walls in line with the passes held: raises missing pieces of locked borders, takes down pieces whose
-- areas are both open (a few per call).
local catchingUp = false              -- back to full after a Ctrl+7 test state: log when every piece is up again
function W.update(enabled, passes, pawn)
    checkSome()
    lastPasses, lastPawn = passes, pawn
    if not ready() then
        once("noclass", "area locks: no walls: " .. missingForWalls() .. " was not found")
        return
    end
    local budget = PER_TICK
    local spawning = true                 -- false once a spawn gave nothing: the next would too, this update
    for i, w in ipairs(layout.walls) do
        if budget <= 0 then break end
        local up = enabled and AREAS.standing(w, passes)
        if up and not raised[i] and spawning then
            local ok, made = pcall(raise, i, pawn)
            -- One piece that fails does not hold up the others: the loop goes on (the try counts against the budget).
            if not ok then
                local err = tostring(made)
                -- Once per kind of error: a raise that fails fails again on every update (three lines a second).
                once("raise" .. err:gsub("0x%x+", ""):gsub("%d+", "#"), "could not raise wall " .. i .. ": " .. err)
            elseif not made then
                once("raisenil", "could not raise wall " .. i .. ": the spawn gave no actor")
                spawning = false
            end
            budget = budget - 1
        elseif not up and raised[i] then
            startOpening(i, pawn)
            budget = budget - 1
        end
    end
    showNear(pawn)
    WALL_SKINS.skinTick()
    WALL_SKINS.recolour(passes)
    stepOpeningAndGlow()
    if catchingUp and budget == PER_TICK then
        catchingUp = false
        P.wallsCaughtUp(nRaised)
    end
end

-- The perf probe's Ctrl+7 test states (test_tools=1 only): hidden (collision kept), nocoll (shown, no collision),
-- none (every raised piece removed at once, none opening), full (as normal; the update raises what is missing).
-- While the state is not full, main.lua neither raises nor lowers pieces nor sends anyone home.
function W.perfMode(mode)
    if mode == "none" then
        for _, a in pairs(raised) do
            if a:IsValid() then pcall(function() a:K2_DestroyActor() end) end
        end
        raised, nRaised, raisedAt, hiddenAt = {}, 0, {}, {}
        return
    end
    for _, a in pairs(raised) do
        if a:IsValid() then
            pcall(function() a:SetActorHiddenInGame(mode == "hidden") end)
            pcall(function() a:SetActorEnableCollision(mode ~= "nocoll") end)
        end
    end
    if mode == "full" then catchingUp = true end
end


-- The locked side of a wall row other than `here` (the area the player stands in), or nil; with both sides locked,
-- the second.
local function lockedSide(row, here, passes)
    local side = nil
    for _, k in ipairs({ row[5], row[6] }) do
        local name = layout.areas[k + 1]
        if name ~= here and not isOpen(name, passes) then side = name end
    end
    return side
end
-- The locked area across a wall within NEAR of a spot (a player walking up to it), or nil. A wall between two locked
-- areas names the one the player is not in.
local NEAR = 3000             -- 30 m
function W.lockedNear(x, y, passes)
    local here = W.areaAt(x, y)
    local best, bestD = nil, NEAR
    for i in pairs(raised) do
        local d = segDist(i, x, y)
        local side = d < bestD and lockedSide(layout.walls[i], here, passes)
        if side then
            best, bestD = side, d
        end
    end
    return best
end

function W.count()
    return nRaised, #layout.walls
end


-- The seed's cut of the map ("areas" for the 15 regions, "regions" for the 75 areas: the older words, see the top of
-- this file; main.lua reads it from the seed's Lock Size), set once a connection is ready and before any wall goes up.
-- A change takes every wall down at once (their piece numbers mean other pieces in the other cut) and forgets the map
-- pictures made for the old one; the update raises the new cut's walls.
function W.setLayout(name)
    name = name == "regions" and "regions" or "areas"
    if name == W.layout then return false end
    for _, a in pairs(raised) do pcall(function() if a:IsValid() then a:K2_DestroyActor() end end) end
    destroyOpening()
    raised, nRaised, raisedAt, hiddenAt = {}, 0, {}, {}
    WALL_SKINS.forgetAll()
    AREAS.useLayoutData(name)
    W.start, W.home = layout.start, layout.map.home
    W.layout = name
    buildTrig()
    MAP_PICTURE.forgetPictures()
    local parts = name == "regions" and " areas" or " regions"         -- in the players' words
    log("area locks: " .. (#layout.areas - 1) .. parts .. " (" .. #layout.walls .. " border pieces)")
    return true
end

-- What the skins part reads of the pieces. The tables are replaced as pieces come and go, so they are handed over by
-- function.
local pieces = {
    raised = function() return raised end,
    isHidden = function(i) return hiddenAt[i] end,
    opening = function() return opening end,
    count = function() return nRaised end,
    statics = function() return gs end,
    passes = function() return lastPasses end,
    pawn = function() return lastPawn end,
}
WALL_SKINS.install({ W = W, areas = AREAS, pieces = pieces, DISSOLVE_S = DISSOLVE_S })
W.SKINS, W.setSkin, W.cycleSkin = WALL_SKINS.SKINS, WALL_SKINS.setSkin, WALL_SKINS.cycleSkin
W.linearOf, W.modAsset, W.pieceSkin = WALL_SKINS.linearOf, WALL_SKINS.modAsset, WALL_SKINS.pieceSkin  -- (the harness)
MAP_ICONS.install({ W = W, areas = AREAS })
MAP_PICTURE.install({ W = W, areas = AREAS, icons = MAP_ICONS, fog = MAP_FOG })
MAP_FOG.install({ W = W, areas = AREAS, icons = MAP_ICONS, picture = MAP_PICTURE })
W.updateMap, W.mapShown, W.mapOff = MAP_PICTURE.updateMap, MAP_FOG.mapShown, MAP_FOG.mapOff
W.stampSize, W.worldAt = MAP_PICTURE.stampSize, MAP_ICONS.worldAt                              -- (for the harness)

return W
