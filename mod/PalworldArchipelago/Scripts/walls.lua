-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red grid by the World Tree gate) stretched into
-- pieces along every border between locked parts of the map; a piece stays up while either part it separates is locked.
-- This file keeps the pieces (raising, hiding, opening, forgetting) and is the table main.lua sees (W). Its parts:
-- locks.lua (the cut of the map, what is open), wall_skins.lua (the looks), map_picture, map_icons, map_fog (the map).
-- Tests: mod/test/tests/walls.lua, mod/test/tests/map.lua; groups "area locks", "the world map"
--   (tools/lua_harness.sh, in CI).
-- W, the table main.lua sees. Its fields:
--   handed over by main.lua (W.install, from config.txt): keepAlive, keepInPlace, dir, radius, fade, tiling, scroll,
--     mapStyle, cppOff, testFogColour, chartOff, iconsOff, chartBordersOff, visited (main.lua's own set, again through
--     setVisited for a new seed), and beyond (slot data, through setBeyond); each part sets its own defaults at
--     install. The harness sets them on its copies directly
--   called by main.lua and its other modules: install, setVisited, update, updateMap, reset, setLayout, setBeyond,
--     setSkin, cycleSkin, perfMode, count, lockedNear, lockedAround, lockAt, passName, regionOf, slugOf, mapShown,
--     mapOff, oldSweep;
--     read: layout (the cut's name), start, home, SKINS
--   for the harness only: segDist, stampSize, worldAt, linearOf, modAsset, pieceSkin, REGION_COLOURS
local W = {}
W.layout = "regions"
-- walls.lua is made of parts, one topic each. Each keeps state for this copy of walls.lua: the game loads walls.lua
-- once, and the harness loads it again (dofile) for each test that wants a fresh start, so each part is loaded afresh
-- with it (require alone would hand back the copy already loaded).
local function freshPart(name)
    package.loaded[name] = nil
    return require(name)
end
-- The fields W.install takes: what main.lua hands over (the header's list).
local HANDED_OVER = {
    keepAlive = true, keepInPlace = true, dir = true, visited = true, radius = true, fade = true, tiling = true,
    scroll = true, mapStyle = true, cppOff = true, testFogColour = true, chartOff = true, iconsOff = true,
    chartBordersOff = true,
}

-- Takes what main.lua hands over, each as the field of its name that the parts read. A name not in the list is an
-- error; a setting left out keeps its default.
function W.install(env)
    for name, value in pairs(env) do
        if not HANDED_OVER[name] then
            error("walls: W.install was handed an unknown field: " .. tostring(name))
        end
        W[name] = value
    end
end

-- The locks the player has stood in: main.lua's own set (in its save), handed over again when a new seed replaces it.
function W.setVisited(set)
    W.visited = set
end

local LOCKS = freshPart("locks")
LOCKS.install(W)
local WALL_SKINS = freshPart("wall_skins")
local MAP_PICTURE = freshPart("map_picture")
local MAP_ICONS = freshPart("map_icons")
local MAP_FOG = freshPart("map_fog")
local layout, isOpen = LOCKS.layout, LOCKS.isOpen
W.passName, W.lockAt, W.lockedAround, W.regionOf = LOCKS.passName, LOCKS.lockAt, LOCKS.lockedAround, LOCKS.regionOf
W.setBeyond, W.slugOf = LOCKS.setBeyond, LOCKS.slugOf
W.start, W.home = layout.start, layout.map.home
-- Where a player found in a closed lock (or hit by a Teleport Trap) is sent: the layout's home as a location in cm.
function W.homeLocation()
    return { X = W.home[1], Y = W.home[2], Z = W.home[3] }
end
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
-- Every piece is raised at world load, so the borders are all there from the start; only those near the player are
-- shown, so fewer walls are drawn and the frame rate stays up: shown within W.radius, hidden (the game's own
-- SetActorHiddenInGame; collision stays) past W.radius + HIDE_MARGIN, so a piece at the edge doesn't flicker.
-- Pieces are not raised and destroyed as the player moves: that crashed the game at a wall (a dead object called), and
-- spawning and destroying all the time only makes more dead objects. 0: every piece shown.
W.radius = 7500               -- 75 m (config wall_radius, in metres)
local HIDE_MARGIN = 2500      -- 25 m
local VIS_PER_TICK = 120      -- pieces shown or hidden an update (a teleport changes many at once)

-- State: the pieces. Forgotten: a piece's entries when it is taken down or found gone (forget), those of a world that
-- is gone at W.reset, and all at a change of cut (W.setLayout) or in the Ctrl+7 "none" test state.
local raised = {}             -- piece index -> wall actor
local raisedAt = {}           -- piece index -> its actor's address, to tell it is still there without calling it
local hiddenAt = {}           -- piece index -> true while hidden by distance
local nRaised = 0             -- how many raised holds (counted as it changes: W.count ran every update)
-- The pieces opening, each { actor, scaleX, scaleY, startedAt (game s), addr = its address, dissolving, material (its
-- dissolving one), collisionOff (it no longer blocks), steps (updates stepped) }. Forgotten: a piece when it is
-- destroyed, those of a world that is gone at W.reset, all at a change of cut.
local opening = {}
-- State: what main.lua handed W.update last (new pieces are dressed for those passes; the glow follows that pawn).
-- Replaced every update; the pawn is forgotten at W.reset.
local lastPasses, lastPawn = nil, nil
-- The wall class and GameplayStatics. Forgotten: never: they are not of a world, and ready() checks them with IsValid.
local cls, statics = nil, nil
local trig = {}               -- piece index -> its direction { cos, sin }; made again for each cut (buildTrig)
local checkAt = 0             -- the piece checkSome looks at next; forgotten: never (it wraps round)
local catchingUp = false      -- back to full after a Ctrl+7 test state: log when every piece is up again
local function buildTrig()
    trig = {}
    for i, w in ipairs(layout.walls) do
        local yaw = math.rad(w[4])
        trig[i] = { cos = math.cos(yaw), sin = math.sin(yaw) }
    end
end
buildTrig()


-- The wall class (and the walls' material) are kept loaded for the whole session through W.keepAlive (set by the core):
-- left alone, the game frees them on the way back to the title, and reloading them while a world loads in was the
-- likely cause of a crash on re-entering a world.
W.keepAlive = function() end
-- The core's keepInPlace(place, obj): keeps obj in place of what was kept at that place; returns the place.
W.keepInPlace = function(place) return place end
local function ready()
    if cls and cls:IsValid() and statics and statics:IsValid() then return true end
    pcall(LoadAsset, (WALL:gsub("_C$", "")))
    cls = StaticFindObject(WALL)
    statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if cls and cls:IsValid() then W.keepAlive(cls) end
    return cls ~= nil and cls:IsValid() and statics ~= nil and statics:IsValid()
end
-- What ready() did not find, for the log: the wall class (a game update could rename it) or the spawning library.
local function missingForWalls()
    if not (cls and cls:IsValid()) then
        return "the wall class " .. WALL
    end
    return "GameplayStatics"
end

-- Forgets piece i was raised, with its look: a new actor raised for it starts shown and undressed. forget and
-- forgetAll are the only code that removes a piece from raised, so what goes with it (address, look, hidden) goes too.
local function forget(i)
    if raised[i] then raised[i], nRaised = nil, nRaised - 1 end
    raisedAt[i] = nil
    WALL_SKINS.forget(i)
    hiddenAt[i] = nil
end
-- Forgets every piece, as forget does one (the actors are destroyed by the caller, or went with their world).
local function forgetAll()
    raised, nRaised, raisedAt, hiddenAt = {}, 0, {}, {}
    WALL_SKINS.forgetAll()
end
-- The addresses of the walls the game still has. FindAllOf lists live objects only, so a wall of a world that is gone
-- is told apart without calling it (IsValid included: its memory may be freed).
local function liveWallAddresses()
    local live = {}
    for _, actor in ipairs(FindAllOf(WALL_CLASS) or {}) do
        local addr = UTIL.addr(actor)
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
    local along, half = dx * t.cos + dy * t.sin, w[3] / 2
    if along > half then along = half elseif along < -half then along = -half end
    local px, py = dx - along * t.cos, dy - along * t.sin
    return math.sqrt(px * px + py * py)
end
W.segDist = segDist

-- Raises piece i: the game's blocking cube, scaled to its length x 4 m x 3 km and turned by its yaw about the
-- vertical (as a quaternion: Z = sin(yaw/2), W = cos(yaw/2)), its middle 500 m above sea level. False when the spawn
-- gave no actor.
local function raise(i, pawn)
    local w = layout.walls[i]
    local x, y, length, yaw = w[1], w[2], w[3], math.rad(w[4])
    local t = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
                Translation = { X = x, Y = y, Z = MID_Z_CM },
                Scale3D = { X = length / CUBE_CM, Y = THICK_CM / CUBE_CM, Z = HEIGHT_CM / CUBE_CM } }
    local actor = statics:BeginDeferredActorSpawnFromClass(pawn, cls, t, SPAWN_ALWAYS, nil)
    if not actor or not actor:IsValid() then return false end
    statics:FinishSpawningActor(actor, t)
    WALL_SKINS.skinNew(actor, i)
    raised[i] = actor
    raisedAt[i] = UTIL.addr(actor)
    nRaised = nRaised + 1
    return true
end

-- Opening a wall: it shrinks to nothing (top and bottom towards its middle), stops blocking halfway, and is then
-- removed. It does not sink with K2_SetActorLocation, whose out-parameter FHitResult (a struct of structs, left
-- unfilled without a sweep) UE4SS copies back into Lua: that crashed the game twice, both times within 2 s of a Region
-- Pass, in UE4SS's nested push_structproperty (reading 0x7b and 0x0a). SetActorScale3D has no out-parameters.
-- The red grid shows only around a wall that blocks, so a wall keeps blocking until it is halfway down. Stepped from
-- the core's 300 ms update, on the game thread: no loop of its own. A 33 ms LoopAsync for it and the glow runs its
-- callback on another thread over the same Lua state: running 30 times a second, it crashed the game twice (stack
-- 08E98397), and with its callback cut down to a flag and a prebuilt function it still logged "Ref was not function"
-- three times and a broken ipairs iterator: Lua's state corrupted.
-- A dissolving piece goes by the game's clock, the material's own, not by counting steps (counted, a piece went at
-- 80 to 85% dissolved): blocking stops at DISSOLVE_S/2, the piece goes at DISSOLVE_S + DISSOLVE_TAIL (the material's
-- Time node may run behind GetTimeSeconds, so a 0.8 s tail was not quite enough; the first one logs it).
local DISSOLVE_S, DISSOLVE_TAIL = 1.6, 2.4
-- One step of an opening piece at the game's time `now`: shrunk (unless it dissolves), let through halfway, destroyed
-- at the end. An opened piece stops blocking halfway through its time and is destroyed at the end: SHRINK_S for a
-- shrink, DISSOLVE_S plus a DISSOLVE_TAIL for a dissolve. True while it is still opening.
local function stepOne(s, now)
    local actor = s.actor
    local span = s.dissolving and DISSOLVE_S or SHRINK_S
    local half = not s.collisionOff and now >= s.startedAt + span / 2
    local done = now >= s.startedAt + span + (s.dissolving and DISSOLVE_TAIL or 0)
    if not s.dissolving then                     -- shrinking: top and bottom towards the middle
        local t = math.min(1, (now - s.startedAt) / SHRINK_S)
        local eased = t * t * (3 - 2 * t)        -- slow, fast, slow
        local height = math.max(MIN_SCALE, HEIGHT_CM / CUBE_CM * (1 - eased))
        pcall(function() actor:SetActorScale3D({ X = s.scaleX, Y = s.scaleY, Z = height }) end)
    end
    if half then
        s.collisionOff = true
        pcall(function() actor:SetActorEnableCollision(false) end)
    end
    if not done then
        return true
    end
    if s.dissolving then
        once("dissolved", string.format("wall skin paws: an opened wall went %.2f s after it began dissolving"
            .. " (the game's clock; the dissolve is %.1f s), %d update(s)", now - s.startedAt, DISSOLVE_S, s.steps))
    end
    pcall(function() actor:K2_DestroyActor() end)
    return false
end
-- Each update: every opening piece one step on, by the game's clock (or the updates counted, when it can't be read).
local function stepOpeningPieces()
    local still = {}
    for _, s in ipairs(opening) do
        local actor = s.actor
        if actor:IsValid() then
            s.steps = s.steps + 1
            local ok, now = pcall(function() return statics:GetTimeSeconds(actor) end)
            if not (ok and type(now) == "number") then
                UTIL.took("walls: an opening piece's clock", "the updates counted (the game's clock could not be read)")
                now = s.startedAt + s.steps * UTIL.UPDATE_MS / 1000
            end
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
            if s.actor:IsValid() then
                s.actor:K2_DestroyActor()
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
            log("walls: the opening step failed (" .. tostring(err) .. "); " .. #opening
                .. " opening piece(s) taken down at once")
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
    local actor, wore, addr = raised[i], WALL_SKINS.wornBy(i), raisedAt[i]
    forget(i)
    if not (actor and actor:IsValid()) then return end
    local ok, material, start = pcall(WALL_SKINS.dissolving, wore, pawn)
    local m = ok and material and WALL_SKINS.meshOf(actor)
    if m then pcall(function() m:SetMaterial(0, material) end) end
    local okT, now = pcall(function() return statics:GetTimeSeconds(actor) end)
    now = (m and start) or (okT and type(now) == "number" and now) or nil
    if not now then
        UTIL.took("walls: an opening piece's start", "0 s (the game's clock could not be read)")
        now = 0
    end
    opening[#opening + 1] = { actor = actor, scaleX = layout.walls[i][3] / CUBE_CM, scaleY = THICK_CM / CUBE_CM,
                              startedAt = now, addr = addr, dissolving = m and true or nil,
                              material = m and material or nil, collisionOff = nil, steps = 0 }
end


-- Walls the game removed (back to the title, another world) are noticed by checking CHECK_PER_TICK pieces each update:
-- all of them every 14 updates (4 s) for the 818 pieces of the 15 regions, every 22 for the 1,294 of the 75 areas.
-- Checking all 818 every update costs an estimated 0.3-0.5 ms (unmeasured; W.oldSweep does it for the perf probe). A
-- new world is noticed at once anyway: main.lua resets on a new pawn.
local CHECK_PER_TICK = 60
local function checkSome()
    local n = #layout.walls
    for _ = 1, math.min(CHECK_PER_TICK, n) do
        checkAt = checkAt % n + 1
        local actor = raised[checkAt]
        if actor and not actor:IsValid() then forget(checkAt) end
    end
end
function W.oldSweep()                 -- every piece checked at once (only for the perf probe's Ctrl+0 replay)
    for _, actor in pairs(raised) do actor:IsValid() end
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
    for i, actor in pairs(raised) do
        if budget <= 0 then break end
        local d = px and segDist(i, px, py)
        local hide = (d and d > W.radius + HIDE_MARGIN) and true or nil
        if d and not hide and hiddenAt[i] and d > W.radius then hide = true end   -- between: as it was
        if hide ~= hiddenAt[i] then
            if actor:IsValid() then
                pcall(function() actor:SetActorHiddenInGame(hide == true) end)
                hiddenAt[i] = hide
                budget = budget - 1
            end
        end
    end
end

-- Each update (main.lua): checks a share of the pieces, raises missing pieces of locked borders and starts opening
-- pieces whose locks are both open (a few per call), then hides the far ones, puts on the skin wanted, recolours
-- pieces whose side opened and steps the opening pieces and the glow.
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
        local up = enabled and LOCKS.standing(w, passes)
        if up and not raised[i] and spawning then
            local ok, made = pcall(raise, i, pawn)
            -- One piece that fails does not hold up the others: the loop goes on (the try counts against the budget).
            if not ok then
                -- Once per kind of error: a raise that fails fails again on every update (three lines a second).
                UTIL.onceErr("walls raise", made, "could not raise wall " .. i .. ": " .. tostring(made))
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
        for _, actor in pairs(raised) do
            if actor:IsValid() then pcall(function() actor:K2_DestroyActor() end) end
        end
        forgetAll()
        return
    end
    for _, actor in pairs(raised) do
        if actor:IsValid() then
            pcall(function() actor:SetActorHiddenInGame(mode == "hidden") end)
            pcall(function() actor:SetActorEnableCollision(mode ~= "nocoll") end)
        end
    end
    if mode == "full" then catchingUp = true end
end


-- The locked side of a wall row other than `here` (the lock the player stands in), or nil; with both sides locked,
-- the second.
local function lockedSide(row, here, passes)
    local side = nil
    for _, k in ipairs({ row[5], row[6] }) do
        local name = layout.locks[k + 1]
        if name ~= here and not isOpen(name, passes) then side = name end
    end
    return side
end
-- The lock across a wall within NEAR of a spot (a player walking up to it) while it is locked, or nil. A wall locked
-- on both sides names the lock the player is not in.
local NEAR = 3000             -- 30 m
function W.lockedNear(x, y, passes)
    local here = W.lockAt(x, y)
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

-- How many pieces are raised, and how many the cut has in all.
function W.count()
    return nRaised, #layout.walls
end


-- The seed's cut of the map ("regions" for the 15 regions, "areas" for the 75 areas, as the seed's Lock Size, which
-- connection.lua reads), set once a connection is ready and before any wall goes up.
-- A change takes every wall down at once (their piece numbers mean other pieces in the other cut) and forgets the map
-- pictures made for the old one; the update raises the new cut's walls.
function W.setLayout(name)
    name = name == "areas" and "areas" or "regions"
    if name == W.layout then return false end
    for _, actor in pairs(raised) do pcall(function() if actor:IsValid() then actor:K2_DestroyActor() end end) end
    destroyOpening()
    forgetAll()
    LOCKS.useLayoutData(name)
    W.start, W.home = layout.start, layout.map.home
    W.layout = name
    buildTrig()
    MAP_PICTURE.forgetPictures()
    log("area locks: " .. (#layout.locks - 1) .. " " .. name .. " (" .. #layout.walls .. " border pieces)")
    return true
end

-- What the skins part reads of the pieces. The tables are replaced as pieces come and go, so they are handed over by
-- function.
local pieces = {
    raised = function() return raised end,
    isHidden = function(i) return hiddenAt[i] end,
    opening = function() return opening end,
    count = function() return nRaised end,
    statics = function() return statics end,
    passes = function() return lastPasses end,
    pawn = function() return lastPawn end,
}
WALL_SKINS.install({ W = W, locks = LOCKS, pieces = pieces, DISSOLVE_S = DISSOLVE_S })
W.SKINS, W.setSkin, W.cycleSkin = WALL_SKINS.SKINS, WALL_SKINS.setSkin, WALL_SKINS.cycleSkin
W.linearOf, W.modAsset, W.pieceSkin = WALL_SKINS.linearOf, WALL_SKINS.modAsset, WALL_SKINS.pieceSkin  -- (the harness)
MAP_ICONS.install({ W = W, locks = LOCKS })
MAP_PICTURE.install({ W = W, locks = LOCKS, icons = MAP_ICONS, fog = MAP_FOG })
MAP_FOG.install({ W = W, locks = LOCKS, icons = MAP_ICONS, picture = MAP_PICTURE })
W.updateMap, W.mapShown, W.mapOff = MAP_PICTURE.updateMap, MAP_FOG.mapShown, MAP_FOG.mapOff
W.stampSize, W.worldAt = MAP_PICTURE.stampSize, MAP_ICONS.worldAt                              -- (for the harness)

return W
