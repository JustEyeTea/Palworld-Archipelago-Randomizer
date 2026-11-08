-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red energy grid beside the World Tree gate),
-- stretched into pieces along every border between areas (area_walls.lua, from tools/area_walls.py). A piece stays up
-- while either area it separates is locked; an Area Pass opens its area. Open sea is never locked, so an area that
-- is locked is ringed from the sea as well.
-- Two cuts of the map (the seed's area_size option, W.setLayout): "areas", the 15 areas (area_walls.lua and the rest);
-- "regions", every named region of the game (the same files with _regions). The areas' are loaded at start.
local DATA = require("area_walls")
local MAP = require("area_map")
local SHAPES = nil            -- area_shapes(_regions).lua: only for a map drawn without the compositor, loaded then
local SUFFIX = ""

local W = {}
W.layout = "areas"
local P = require("perf")
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

local WALL = "/Game/Pal/Blueprint/System/Volume/BP_PalBlockingVolume.BP_PalBlockingVolume_C"
local START = DATA.start
local SEA = "Open sea"
local HEIGHT = 300000         -- 3 km of wall: from 1 km below sea level to 2 km above
local MID_Z = 50000
local THICK = 4               -- 4 m, so nothing fast slips through
local PER_TICK = 30           -- pieces raised or taken down per update, to spread the work
local SINK_STEPS = 60         -- an opened wall sinks into the ground over 60 steps of 33 ms (2 s), then goes

local raised = {}             -- piece index -> wall actor
local nRaised = 0             -- how many raised holds (counted as it changes: W.count ran every update)
local cls, gs = nil, nil
-- Each piece's direction, worked out once (lockedNear did it for every raised piece every 7th update).
local trig = {}
local function buildTrig()
    trig = {}
    for i, w in ipairs(DATA.walls) do
        local yaw = math.rad(w[4])
        trig[i] = { math.cos(yaw), math.sin(yaw) }
    end
end
buildTrig()

-- The item that opens an area: an Area Pass, or with area_size regions a Region Pass.
function W.passName(area)
    return (W.layout == "regions" and "Region Pass: " or "Area Pass: ") .. area
end

local function isOpen(area, passes)
    return area == SEA or area == START or passes[area] == true
end

-- The wall class (and the walls' material) are kept loaded for the whole session through W.keep (set by the core):
-- left alone, the game frees them on the way back to the title, and reloading them while a world loads in was the
-- likely cause of a crash on re-entering a world.
W.keep = function() end
local function ready()
    if cls and cls:IsValid() and gs and gs:IsValid() then return true end
    pcall(LoadAsset, (WALL:gsub("_C$", "")))
    cls = StaticFindObject(WALL)
    gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if cls and cls:IsValid() then W.keep(cls) end
    return cls ~= nil and cls:IsValid() and gs ~= nil and gs:IsValid()
end

-- A new world (another save, back from the title): its walls are gone with the old one; start over. Only walls that
-- are really gone are forgotten: the core's world key is the pawn, which also changes (or reads nil for a moment) in
-- the same world, and a wall forgotten while still standing could never be taken down.
function W.reset()
    for i, a in pairs(raised) do
        local ok, valid = pcall(function() return a:IsValid() end)
        if not (ok and valid) then raised[i], nRaised = nil, nRaised - 1 end
    end
end

local function raise(i, context)
    local w = DATA.walls[i]
    local x, y, length, yaw = w[1], w[2], w[3], math.rad(w[4])
    local t = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) },
                Translation = { X = x, Y = y, Z = MID_Z },
                Scale3D = { X = length / 100, Y = THICK, Z = HEIGHT / 100 } }
    local a = gs:BeginDeferredActorSpawnFromClass(context, cls, t, 1, nil)
    if not a or not a:IsValid() then return false end
    gs:FinishSpawningActor(a, t)
    W.skinNew(a, i)
    raised[i] = a
    nRaised = nRaised + 1
    return true
end

-- Opening a wall: it shrinks to nothing (top and bottom towards its middle), stops blocking halfway, and is then
-- removed. It used to sink with K2_SetActorLocation, whose out-parameter FHitResult (a struct of structs, left
-- unfilled without a sweep) UE4SS copies back into Lua: that crashed the game twice on 2026-11-05, both times within
-- 2 s of a Region Pass, in UE4SS's nested push_structproperty (reading 0x7b and 0x0a). SetActorScale3D has no
-- out-parameters.
-- The red grid shows only around a wall that blocks, so a wall keeps blocking until it is halfway down. One loop for
-- the session, made when this module loads (UE4SS cannot start one from inside a game-thread callback); it idles while
-- nothing sinks.
local sinking = {}            -- list of { actor, scale X, scale Y, step }
local function sinkStep()
    local still = {}
    for _, s in ipairs(sinking) do
        local a = s[1]
        if a:IsValid() then
            s[4] = s[4] + 1
            local t = s[4] / SINK_STEPS
            local eased = t * t * (3 - 2 * t)            -- slow, fast, slow
            pcall(function() a:SetActorScale3D({ X = s[2], Y = s[3], Z = math.max(0.01, HEIGHT / 100 * (1 - eased)) }) end)
            if s[4] == SINK_STEPS // 2 then pcall(function() a:SetActorEnableCollision(false) end) end
            if s[4] >= SINK_STEPS then
                pcall(function() a:K2_DestroyActor() end)
            else
                still[#still + 1] = s
            end
        end
    end
    sinking = still
end
if LoopAsync then
    LoopAsync(33, function()
        if #sinking > 0 then
            ExecuteInGameThread(function()
                local ok, err = pcall(sinkStep)
                if not ok then log("sinking error: " .. tostring(err)); sinking = {} end
            end)
        end
        return false
    end)
end
local dressedAs = {}           -- piece -> the material it wears with the area skin ("area:<colour>", "sealed", "a")
local function forget(i)
    if raised[i] then raised[i], nRaised = nil, nRaised - 1 end
    dressedAs[i] = nil
end
local function lower(i)
    local a = raised[i]
    forget(i)
    if not (a and a:IsValid()) then return end
    sinking[#sinking + 1] = { a, DATA.walls[i][3] / 100, THICK, 0 }
end

-- Walls the game removed (back to the title, another world) are noticed by checking a share of the pieces each
-- update, all of them every 14 updates (4 s): 6dd356e checked all 818 every update (an estimated 0.3-0.5 ms,
-- unmeasured). A new world is noticed at once anyway: main.lua resets on a new pawn.
local CHECK_PER_TICK = 60
local checkAt = 0
local function checkSome()
    local n = #DATA.walls
    for _ = 1, math.min(CHECK_PER_TICK, n) do
        checkAt = checkAt % n + 1
        local a = raised[checkAt]
        if a and not a:IsValid() then forget(checkAt) end
    end
end
function W.oldSweep()                 -- 6dd356e's check of every piece (only for the perf probe's Ctrl+0 replay)
    for _, a in pairs(raised) do a:IsValid() end
end

-- Brings the walls in line with the passes held: raises missing pieces of locked borders, takes down pieces whose
-- areas are both open (a few per call).
local catchingUp = false              -- back to full after a Ctrl+7 test state: log when every piece is up again
function W.update(enabled, passes, context)
    checkSome()
    W.lastPasses = passes
    if not ready() then return end
    local budget = PER_TICK
    for i, w in ipairs(DATA.walls) do
        if budget <= 0 then break end
        local up = enabled and not (isOpen(DATA.areas[w[5] + 1], passes) and isOpen(DATA.areas[w[6] + 1], passes))
        if up and not raised[i] then
            local ok, err = pcall(raise, i, context)
            if not ok then
                -- Once per kind of error: a raise that fails fails again on every update (three lines a second).
                once("raise" .. tostring(err):gsub("0x%x+", ""):gsub("%d+", "#"), "could not raise wall " .. i .. ": " .. tostring(err))
                return
            end
            budget = budget - 1
        elseif not up and raised[i] then
            lower(i)
            budget = budget - 1
        end
    end
    W.skinTick()
    W.recolour(passes)
    if catchingUp and budget == PER_TICK then
        catchingUp = false
        P.wallsCaughtUp(nRaised)
    end
end

-- The perf probe's Ctrl+7 test states (test_tools=1 only): hidden (collision kept), nocoll (shown, no collision),
-- none (every raised piece removed at once, no sinking), full (as normal; the update raises what is missing).
-- While the state is not full, main.lua neither raises nor lowers pieces nor sends anyone home.
function W.perfMode(mode)
    if mode == "none" then
        for _, a in pairs(raised) do
            if a:IsValid() then pcall(function() a:K2_DestroyActor() end) end
        end
        raised, nRaised = {}, 0
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

-- Which area a spot is in (nil off the main map: the World Tree's own map). The map's rows are decoded when first used.
local decoded = {}
local function areaIndexAt(r, c)
    if r < 0 or c < 0 or r >= MAP.size or c >= MAP.size then return nil end
    local runs = decoded[r]
    if not runs then
        runs = {}
        for a, n in MAP.rows[r + 1]:gmatch("(%d+),(%d+)") do runs[#runs + 1] = { tonumber(a), tonumber(n) } end
        decoded[r] = runs
    end
    local col = 0
    for _, run in ipairs(runs) do
        col = col + run[2]
        if c < col then return run[1] end
    end
end
local function cellOf(x, y)
    local x0, x1, y0, y1 = MAP.bounds[1], MAP.bounds[2], MAP.bounds[3], MAP.bounds[4]
    local size = (x1 - x0) / MAP.size
    return math.floor((x1 - x) / size), math.floor((y - y0) / size)
end
function W.areaAt(x, y)
    local k = areaIndexAt(cellOf(x, y))
    return k and DATA.areas[k + 1]
end

-- The locked area a player stands well inside (every cell around them in it), or nil. Near a border, the player is
-- given the benefit of the doubt: the walls are there.
function W.lockedAround(x, y, passes)
    local r, c = cellOf(x, y)
    local here = areaIndexAt(r, c)
    if not here then return nil end
    local name = DATA.areas[here + 1]
    if isOpen(name, passes) then return nil end
    for dr = -1, 1 do
        for dc = -1, 1 do
            if areaIndexAt(r + dr, c + dc) ~= here then return nil end
        end
    end
    return name
end
W.home = MAP.home
W.start = START

-- The locked area across a wall within NEAR of a spot (a player walking up to it), or nil. A wall between two locked
-- areas names the one the player is not in.
local NEAR = 3000             -- 30 m
function W.lockedNear(x, y, passes)
    local here = W.areaAt(x, y)
    local best, bestD = nil, NEAR
    for i, a in pairs(raised) do
        local w = DATA.walls[i]
        local cos, sin = trig[i][1], trig[i][2]
        local dx, dy = x - w[1], y - w[2]
        local along = dx * cos + dy * sin
        local across = -dx * sin + dy * cos
        local over = math.max(0, math.abs(along) - w[3] / 2)
        local d = math.sqrt(over * over + across * across)
        if d < bestD then
            for _, k in ipairs({ w[5], w[6] }) do
                local name = DATA.areas[k + 1]
                if name ~= here and not isOpen(name, passes) then best, bestD = name, d end
            end
        end
    end
    return best
end

-- The world map with locked areas in greyscale: the game's map drawn into a render target, then each locked area's
-- outline (area_shapes.lua: smoothed, cut into triangles) drawn over it from a greyscale copy of the map, darkening
-- softly toward its edge (a narrow band whose corners are shaded dark at the edge); shown in the map screen's map image (the exploration fog is a separate layer above it). Redrawn when
-- the set of locked areas changes.
-- The greyscale copy is made once on the player's machine and kept in the mod folder (it is the game's own art, so it
-- is never shipped): the map is drawn into a render target, saved as a PNG, turned grey by the C++ part
-- (AP_GreyscalePNG; the saved PNG is in linear light, hence the gamma) and loaded back. Without the C++ part, locked
-- areas are a dimmed copy of the colour map instead.
-- Render targets are owned by the game instance, never by something in the world: an object kept alive for the
-- session that belongs to the world stops the world being freed when leaving it, and the game crashes on the way back
-- to the title (v0.4.0 to v0.4.5).
local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
local GREY_FILE = "map-grey-1.png"
local RT_SIZE = 4096
local mapRT, mapKey, mapShownOn, greyTex, greyTried = nil, nil, nil, nil, false
local FADE = { R = 0.38, G = 0.40, B = 0.46, A = 1 }      -- the locked areas' tint without a greyscale copy
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local EDGE_SHADE = 0.45      -- how dark the band is at the very edge (1: not at all)
W.dir = "."
-- The game instance lives all session (skill: GameInstance-owned objects); kept, and looked up again only if it is
-- no longer valid. 6dd356e looked it up on every update while a map screen existed.
local ownerGi = nil
local function owner()
    if ownerGi and ownerGi:IsValid() then return ownerGi end
    local gi = FindFirstOf("PalGameInstance") or FindFirstOf("GameInstance")
    ownerGi = gi and gi:IsValid() and gi or nil
    return ownerGi
end

-- Wall skins (test builds: wall_skin=a, b, a3d or b3d in config.txt, or Ctrl+F3 with test_tools=1 to cycle them): the Art &
-- Assets lane's patterns (walls/ap-wall-pattern-<skin>.png, 512x512, greyscale) in AP teal on our walls only. One
-- dynamic copy of the walls' own material (MI_AirBlock_v2) per skin, owned by the game instance like the map's render
-- targets, set on each piece's mesh; the game's own barriers keep the shared red material. The material's parameters
-- (from the server pak): MainTexture01 is the pattern (T_DungeonGate02: linear, single channel); MainTexture02 is the
-- engine's blue noise for the dither, left alone; Color, DayColor and NightColor are the tint (night = 0.42 of day);
-- TilingU_01/TilingV_01 default to 5 and 3, ScrollingU_01/ScrollingV_01 to 0. Untested in game (2026-11-04).
-- a3d/b3d: the same, shaded as if raised (v0.13.5 playtest: a and b looked flat). <skin>-dense: that pattern tiled 10x6,
-- twice the material's 5x3, nearer the red grid's density (about 50 px a cell at 3 m against a3d's 100).
-- colour-<x>: full-colour tiles (walls/ap-wall-colour-<x>.png, RGBA) on our own material, M_APWall, from the
-- PalworldArchipelagoArt pak (logicmod/make_wall_material.py; the user, 2026-11-05: the game's material can show one
-- colour per piece, they want multicolour). Without the pak (or the file) such a skin is refused, logged, and skipped
-- by Ctrl+F3. colour-<x>-flow: that tile drifting sideways (FLOW tiles a second; the user's rainbow, 2026-11-05).
-- area (the default): walls/ap-wall-pattern-pawholes.png (the user, 2026-11-05: "an area-coloured wall with see-through
-- paw-shaped holes"; the hex lattice, pattern a, until that file exists) in the colour of the locked area each piece
-- keeps you out of (the user: "the region/area colored walls make WAAAAY more sense"), the colour of that area's pass ticket
-- (Art & Assets lane, area_shapes.COLOURS); a region wears its area's (area_parents_regions.lua). A piece between two
-- locked areas wears the one that isn't beyond the goal. Areas beyond the seed's goal (sealed for good) wear
-- walls/ap-wall-pattern-sealed.png in grey, or the lattice in grey until that file exists. A piece changes colour
-- when the area it wore opens and the other side is still locked.
-- paws (the default with the pak): the Art lane's cream paws (walls/ap-wall-paws-layer.png, cooked into the pak as
-- T_APWallPaws with mips) on M_APWall, over the same area colour at 0.34 (the material's Back and BackAlpha; the user's
-- pick C, 2026-11-05: "cream paws on the area colour"); sealed areas over the slate grey. Without the pak, area.
local SKINS = { "red", "colour-rainbow", "colour-rainbow-flow", "colour-paws", "colour-routes", "colour-grid",
                "a", "b", "a3d", "b3d", "a3d-dense", "b3d-dense", "area", "paws" }
local function byArea(name) return name == "area" or name == "paws" end
local AREA_COLOURS = {
    ["Bamboo Groves"] = "8CCB3A", ["Sea Breeze Archipelago"] = "3FC1D9", ["Isles of Silence"] = "A3ADC9",
    ["Marsh Island"] = "8F9B4A", ["Crescent Moon Shore"] = "7A6FE0", ["Volcano Foothills"] = "F08A3C",
    ["Mount Obsidian"] = "D2453F", ["Verdant Stream"] = "2FB3A0", ["Desiccated Dunes"] = "E3B860",
    ["Astral Mountains"] = "A8E0F0", ["Sakurajima"] = "F28FB5", ["Feybreak"] = "B266D9",
    ["Sky Islands"] = "5B9BF0", ["World Tree"] = "2E8B57",
}
local SEALED = { R = 0.3231, G = 0.3663, B = 0.4564, A = 1 }  -- slate grey #9AA3B5 (Art lane's suggestion; the user may pick)
W.beyond = {}                                                  -- areas beyond the seed's goal (main.lua, slot data)
local PARENTS = nil                                            -- region -> area (regions layout only)
function W.parentOf(area)
    if W.layout ~= "regions" then return area end
    PARENTS = PARENTS or require("area_parents_regions")
    return PARENTS[area] or area
end
-- An sRGB #RRGGBB as the linear colour the material's tint parameters take.
local function linearOf(hex)
    local c = {}
    for k, at in pairs({ R = 1, G = 3, B = 5 }) do
        local v = tonumber(hex:sub(at, at + 1), 16) / 255
        c[k] = v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
    end
    c.A = 1
    return c
end
W.linearOf, W.AREA_COLOURS = linearOf, AREA_COLOURS
local FLOW = 0.05
local PAW_BACK, PAW_BRIGHT = 0.34, 1.1   -- the Art lane: emissive 1.0 to 1.2 (1.5 blooms the cream); raise the back first
local apWall = nil                                             -- M_APWall once loaded
local DENSE = { 10, 6 }
local TEAL = { R = 0.018, G = 0.745, B = 0.604, A = 1 }       -- sRGB #24E0CC, the user's pick
local NIGHT = 0.421875                                         -- the game's NightColor over its DayColor
local skin = { now = "red", want = "red", base = nil, mids = {}, failed = {} }
local sealedFile = nil         -- "sealed" when walls/ap-wall-pattern-sealed.png exists, else "a" (checked once)
local areaFile = nil           -- "pawholes" when walls/ap-wall-pattern-pawholes.png exists, else "a" (checked once)
local function patternOr(name)
    local f = io.open(W.dir .. "\\walls\\ap-wall-pattern-" .. name .. ".png", "rb")
    if f then f:close(); return name end
    return "a"
end
W.tiling, W.scroll = nil, nil                                  -- { u, v } from config.txt, or the material's own
local function meshOf(a)
    local ok, m = pcall(function() return a.Cube end)
    if ok and m and m:IsValid() then return m end
    local smc = StaticFindObject("/Script/Engine.StaticMeshComponent")
    ok, m = pcall(function() return a:GetComponentByClass(smc) end)
    if ok and m and m:IsValid() then return m end
end
-- An asset of the PalworldArchipelagoArt pak: already loaded, else through the asset registry as BPModLoader loads the
-- pak's ModActor (AssetRegistryHelpers:GetAsset with PackageName and AssetName), else LoadAsset. 2026-11-08 dev.39
-- playtest: BPModLoader spawned the pak's ModActor in every level, yet LoadAsset + StaticFindObject found no M_APWall.
-- Each step is guarded; how it went is noted for the one-time probe line.
local function modAsset(pkg, name, notes)
    local full = pkg .. "." .. name
    local function found()
        local ok, o = pcall(StaticFindObject, full)
        return ok and o and o:IsValid() and o or nil
    end
    local o = found()
    if o then notes[#notes + 1] = name .. " already loaded"; return o end
    local ok, got = pcall(function()
        local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if not (helpers and helpers:IsValid()) then return "no AssetRegistryHelpers" end
        local function fname(s) return EFindName and FName(s, EFindName.FNAME_Add) or FName(s) end
        local a = helpers:GetAsset({ PackageName = fname(pkg), AssetName = fname(name) })
        return a and a:IsValid() and a or "GetAsset gave nothing"
    end)
    if ok and type(got) ~= "string" then notes[#notes + 1] = name .. " from the asset registry"; return got end
    notes[#notes + 1] = name .. " registry: " .. tostring(got)
    local okL, err = pcall(LoadAsset, full)
    o = found()
    if o then notes[#notes + 1] = name .. " from LoadAsset"; return o end
    notes[#notes + 1] = name .. " LoadAsset " .. (okL and "found nothing" or ("errored: " .. tostring(err)))
end
W.modAsset = modAsset
local apWallProbed = false
local function apWallMaterial()
    if apWall and apWall:IsValid() then return apWall end
    local notes = {}
    local m = modAsset("/Game/Mods/PalworldArchipelagoArt/M_APWall", "M_APWall", notes)
    if not apWallProbed then
        apWallProbed = true
        local okA, actor = pcall(StaticFindObject, "/Game/Mods/PalworldArchipelagoArt/ModActor.ModActor_C")
        local hasActor = okA and actor and actor:IsValid()
        log("wall material probe: " .. (m and "found" or "not found") .. " (" .. table.concat(notes, "; ") .. "); ModActor_C "
            .. (hasActor and "loaded" or "not loaded"))
    end
    if m then apWall = m; W.keep(m); return m end
end
local function colourMaterial(name, gi, krl, kml)
    local base = apWallMaterial()
    if not base then log("wall skin " .. name .. ": needs the PalworldArchipelagoArt pak (M_APWall not found)"); return nil end
    local flow = name:match("^(.-)%-flow$")
    local path = W.dir .. "\\walls\\ap-wall-" .. (flow or name) .. ".png"
    local tex = krl:ImportFileAsTexture2D(gi, path)
    if not (tex and tex:IsValid()) then log("wall skin " .. name .. ": could not load " .. path); return nil end
    W.keep(tex)                                                -- a colour picture: sRGB as imported
    local mid = kml:CreateDynamicMaterialInstance(gi, base, FName("None"), 0)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("Pattern"), tex)
    local scroll = flow and { FLOW, 0 } or W.scroll
    if scroll then
        mid:SetScalarParameterValue(FName("ScrollU"), scroll[1])
        mid:SetScalarParameterValue(FName("ScrollV"), scroll[2])
    end
    skin.mids[name], skin.failed[name] = mid, nil
    log("wall skin " .. name .. ": material made on M_APWall" .. (scroll and (", scrolling " .. scroll[1] .. "," .. scroll[2]) or ""))
    return mid
end
-- The cream-paw layer: the pak's (with mips), else the PNG (none; the rims may shimmer far off). One for every area.
local pawLayer = nil
local function pawLayerTexture(gi, krl)
    if pawLayer and pawLayer:IsValid() then return pawLayer end
    local notes = {}
    local t, from = modAsset("/Game/Mods/PalworldArchipelagoArt/T_APWallPaws", "T_APWallPaws", notes), "the pak, with mips"
    if not (t and t:IsValid()) then
        t, from = krl:ImportFileAsTexture2D(gi, W.dir .. "\\walls\\ap-wall-paws-layer.png"), "walls\\ap-wall-paws-layer.png, no mips"
    end
    if not (t and t:IsValid()) then return nil end
    W.keep(t)
    pawLayer = t
    log("wall skin paws: the paw layer from " .. from)
    return t
end
-- paws:<hex> or paws:sealed: M_APWall with the paw layer over that colour.
local function pawsMaterial(name, gi, krl, kml)
    local base = apWallMaterial()
    if not base then log("wall skin paws: needs the PalworldArchipelagoArt pak (M_APWall not found)"); return nil end
    local tex = pawLayerTexture(gi, krl)
    if not tex then log("wall skin paws: could not load walls\\ap-wall-paws-layer.png"); return nil end
    local hex = name:match("^paws:(%x%x%x%x%x%x)$")
    local back = hex and linearOf(hex) or SEALED
    local mid = kml:CreateDynamicMaterialInstance(gi, base, FName("None"), 0)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("Pattern"), tex)
    mid:SetVectorParameterValue(FName("Back"), back)
    mid:SetScalarParameterValue(FName("BackAlpha"), PAW_BACK)
    mid:SetScalarParameterValue(FName("Brightness"), PAW_BRIGHT)
    if W.scroll then
        mid:SetScalarParameterValue(FName("ScrollU"), W.scroll[1])
        mid:SetScalarParameterValue(FName("ScrollV"), W.scroll[2])
    end
    skin.mids[name], skin.failed[name] = mid, nil
    log("wall skin " .. name .. ": material made on M_APWall")
    return mid
end
local function skinMaterial(name)
    local mid = skin.mids[name]
    if mid and mid:IsValid() then return mid end
    if skin.failed[name] then return nil end
    skin.failed[name] = true                                   -- one try per skin per session; cleared on success
    local gi = owner()
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if not (gi and skin.base and skin.base:IsValid() and krl and krl:IsValid() and kml and kml:IsValid()) then
        log("wall skin " .. name .. ": no game instance, wall material or material library yet")
        skin.failed[name] = nil
        return nil
    end
    if name:find("^colour%-") then return colourMaterial(name, gi, krl, kml) end
    if name:find("^paws:") then return pawsMaterial(name, gi, krl, kml) end
    local tint, file = TEAL, name:match("^(.-)%-dense$")
    local tiling = file and DENSE or W.tiling
    local hex = name:match("^area:(%x%x%x%x%x%x)$")
    if hex then
        areaFile = areaFile or patternOr("pawholes")
        tint, file = linearOf(hex), areaFile
    end
    if name == "sealed" then
        sealedFile = sealedFile or patternOr("sealed")
        tint, file = SEALED, sealedFile
    end
    local path = W.dir .. "\\walls\\ap-wall-pattern-" .. (file or name) .. ".png"
    local tex = krl:ImportFileAsTexture2D(gi, path)
    if not (tex and tex:IsValid()) then log("wall skin " .. name .. ": could not load " .. path); return nil end
    local srgb = pcall(function() tex.SRGB = false; tex:UpdateResource() end)   -- the game's pattern is linear
    W.keep(tex)
    mid = kml:CreateDynamicMaterialInstance(gi, skin.base, FName("None"), 0)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("MainTexture01"), tex)
    local night = { R = tint.R * NIGHT, G = tint.G * NIGHT, B = tint.B * NIGHT, A = 1 }
    for k, c in pairs({ Color = tint, DayColor = tint, NightColor = night }) do mid:SetVectorParameterValue(FName(k), c) end
    if tiling then
        mid:SetScalarParameterValue(FName("TilingU_01"), tiling[1])
        mid:SetScalarParameterValue(FName("TilingV_01"), tiling[2])
    end
    if W.scroll then
        mid:SetScalarParameterValue(FName("ScrollingU_01"), W.scroll[1])
        mid:SetScalarParameterValue(FName("ScrollingV_01"), W.scroll[2])
    end
    skin.mids[name], skin.failed[name] = mid, nil
    -- Blueprint_GetSizeX/Y: Lua sees only UFunctions (v0.13.5 playtest: GetSurfaceWidth is C++ only, and the call errored).
    local okw, size = pcall(function() return tex:Blueprint_GetSizeX() .. "x" .. tex:Blueprint_GetSizeY() end)
    log("wall skin " .. name .. ": material made (" .. (okw and size or "size unknown")
        .. (srgb and ", linear" or ", sRGB: could not change") .. ", tiling "
        .. (tiling and (tiling[1] .. "x" .. tiling[2]) or "the material's") .. ")")
    return mid
end
-- Puts the current skin on one piece (a new piece, or every raised one when the skin changes).
local function dress(a, mid)
    local m = meshOf(a)
    if not m then return false end
    if not skin.base then skin.base = m:GetMaterial(0); W.keep(skin.base) end   -- the red original, before any change
    m:SetMaterial(0, mid or skin.base)
    return true
end
-- The material a piece wears with the area skin (or paws), by name (see SKINS).
local function pieceSkin(i, passes, mode)
    local w = DATA.walls[i]
    local a1, a2 = DATA.areas[w[5] + 1], DATA.areas[w[6] + 1]
    local l1, l2 = not isOpen(a1, passes), not isOpen(a2, passes)
    local area = (l1 and not l2) and a1 or (l2 and not l1) and a2 or (W.beyond[a1] and a2 or a1)
    local hex = AREA_COLOURS[W.parentOf(area)]
    if mode == "paws" then
        if W.beyond[area] then return "paws:sealed" end
        return "paws:" .. (hex or "24E0CC")                    -- an area without a colour: the start island's teal
    end
    if W.beyond[area] then return "sealed" end
    return hex and ("area:" .. hex) or "a"
end
W.pieceSkin = pieceSkin
-- With the area skin (or paws): that piece's own material (made on first use; the teal lattice if it can't be made).
local function areaDress(a, i, passes, mode)
    local name = pieceSkin(i, passes or {}, mode)
    local mid = skinMaterial(name)
    if not mid and name ~= "a" then name, mid = "a", skinMaterial("a") end
    if mid and dress(a, mid) then dressedAs[i] = name end
end
function W.skinNew(a, i)
    if byArea(skin.now) then
        if i then pcall(areaDress, a, i, W.lastPasses, skin.now) end
    elseif skin.now ~= "red" then
        pcall(dress, a, skin.mids[skin.now])
    end
end
-- A pass that opens one side of a piece still up turns it to the other side's colour; so does the list of areas
-- beyond the goal arriving. A few pieces an update (RECOLOUR), only after something changed.
local RECOLOUR = 40
local recolourAt, passSig = nil, nil
function W.recolour(passes)
    if not byArea(skin.now) then return end
    local n = 0
    for _ in pairs(passes) do n = n + 1 end
    local sig = n .. "/" .. (W.beyondSig or "")
    if sig ~= passSig then passSig, recolourAt = sig, 1 end
    if not recolourAt then return end
    local budget = RECOLOUR
    while recolourAt <= #DATA.walls and budget > 0 do
        local i, a = recolourAt, raised[recolourAt]
        if a and a:IsValid() and dressedAs[i] ~= pieceSkin(i, passes, skin.now) then
            pcall(areaDress, a, i, passes, skin.now)
            budget = budget - 1
        end
        recolourAt = recolourAt + 1
    end
    if recolourAt > #DATA.walls then recolourAt = nil end
end
-- Areas beyond the seed's goal (a set of names; main.lua at connect): their walls wear the sealed look.
function W.setBeyond(set)
    W.beyond = set or {}
    local names = {}
    for a in pairs(W.beyond) do names[#names + 1] = a end
    table.sort(names)
    W.beyondSig = table.concat(names, "|")
end
-- Empty or unset: paws (area without the pak); wall_skin=red for the game's own red grid.
W.DEFAULT_SKIN = "paws"
function W.setSkin(name)
    if name == "" or name == nil then name = W.DEFAULT_SKIN end
    for _, s in ipairs(SKINS) do if s == name then skin.want = name; return end end
    log("wall skin " .. tostring(name) .. ": unknown (" .. table.concat(SKINS, ", ") .. ")")
end
-- The next skin, skipping any refused this session (no pak, no file): it would be refused again and the cycle would
-- stop there.
function W.cycleSkin()
    for k, s in ipairs(SKINS) do
        if s == skin.want then
            for j = 1, #SKINS do
                local nxt = SKINS[(k + j - 1) % #SKINS + 1]
                if not skin.failed[nxt] then skin.want = nxt; return nxt end
            end
        end
    end
end
-- On the game thread (from W.update): the skin wanted, once the wall material is known (from the first piece raised).
function W.skinTick()
    if skin.want == skin.now then return end
    if not skin.base then
        local _, a = next(raised)
        if not a then return end
        local m = meshOf(a)
        skin.base = m and m:GetMaterial(0)
        if not skin.base then return end
        W.keep(skin.base)
    end
    -- paws without the pak: area instead, and Ctrl+F3 skips paws from then on.
    if skin.want == "paws" then
        if apWallMaterial() then
            skin.failed.paws = nil
        else
            log("wall skin paws: needs the PalworldArchipelagoArt pak (M_APWall not found); the area colours instead")
            skin.failed.paws, skin.want = true, "area"
            if skin.want == skin.now then return end
        end
    end
    local mid = nil
    if skin.want ~= "red" and not byArea(skin.want) then
        mid = skinMaterial(skin.want)
        if not mid then skin.want = skin.now; return end
    end
    local n, bad = 0, 0
    for i, a in pairs(raised) do
        if a:IsValid() then
            local ok, done
            if byArea(skin.want) then
                ok = pcall(areaDress, a, i, W.lastPasses, skin.want)
                done = dressedAs[i] ~= nil
            else
                ok, done = pcall(dress, a, mid)
                dressedAs[i] = nil
            end
            if ok and done then n = n + 1 else bad = bad + 1 end
        end
    end
    skin.now = skin.want
    if byArea(skin.now) then
        local kinds = {}
        for _, name in pairs(dressedAs) do kinds[name] = true end
        local list = {}
        for name in pairs(kinds) do list[#list + 1] = name end
        table.sort(list)
        log("wall skin " .. skin.now .. ": colours " .. table.concat(list, ", "))
    end
    log("wall skin " .. skin.now .. ": on " .. n .. " pieces" .. (bad > 0 and (", " .. bad .. " without a mesh") or ""))
end

-- The locked-area stamps (Art & Assets lane: art/ap-map-stamp-<area>.png per area, round 2; art/ap-map-stamp.png when
-- an area has none), 256x256 tickets with a padlock, drawn on each locked area STAMP_PX across on the 4096 map, a whole
-- stamp inside the area on its side nearest the starting area (area_centres.lua, from tools/area_centres.py). v0.13.5
-- playtest: at each area's deepest point all 14 sat under the map's fog of war, which a locked area never clears.
local ART = require("art")
local CENTRES = require("area_centres")    -- area_centres_regions.lua with the regions (W.setLayout)
local STAMP_PX = 88
-- A region too small for the whole stamp gets a smaller one, about as wide as the region (its fifth field: how far the
-- stamp's point is from the region's edge), but never under STAMP_MIN_PX. 2026-11-06 run: the full 88 px padlock buried
-- Small Settlement's village. Data without the field (older area_centres files) keeps the full size.
local STAMP_MIN_PX = 28
local function stampSize(c)
    local room = c[5]
    if not room then return STAMP_PX end
    return math.max(STAMP_MIN_PX, math.min(STAMP_PX, math.floor(2 * room)))
end
W.stampSize = stampSize
local function slugOf(name) return (name:lower():gsub("[^%w]+", "-")) end
W.slugOf = slugOf
local function lockedList(passes)
    local out = {}
    for k, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then out[#out + 1] = k - 1 end
    end
    return out
end
-- The locked areas are shown as the map's own icons (placeIcons, below) unless config.txt has map_icons=0 or the icons
-- failed; then the stamps are drawn into the picture and the chart fog, as before.
W.iconsOff = false
local iconsFailed = false
local function iconsActive() return not W.iconsOff and not iconsFailed end
-- An area beyond the goal: the sealed stamp; a region: its area's; the shared one when there is none.
local function stampTexture(k)
    local name = DATA.areas[k + 1]
    if not name then return nil end
    return (W.beyond[name] and ART.texture("ap-map-stamp-sealed"))
        or (not W.beyond[name] and ART.texture("ap-map-stamp-" .. slugOf(W.parentOf(name))))
        or ART.texture("ap-map-stamp")
end
local function drawStamps(canvas, krl, gi, locked)
    if iconsActive() then once("stampsicons", "map: locked areas are shown as map icons, not drawn on the picture"); return end
    local n = 0
    for _, k in ipairs(locked) do
        local c = CENTRES[k]
        local tex = c and stampTexture(k)
        if tex then
            local u, v = c[3] or c[1], c[4] or c[2]
            local px = stampSize(c)
            canvas:K2_DrawTexture(tex, { X = u * RT_SIZE - px / 2, Y = v * RT_SIZE - px / 2 },
                { X = px, Y = px }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, 2, 0, { X = 0.5, Y = 0.5 })
            n = n + 1
        end
    end
    once("stamps" .. n, "map: " .. n .. " locked-area stamp(s) drawn")
end
local function greyscaleMap(krl, tex)
    if greyTex and greyTex:IsValid() then return greyTex end
    if greyTried or not AP_GreyscalePNG then return nil end
    greyTried = true
    local gi = owner()
    if not gi then greyTried = false; return nil end
    local path = W.dir .. "\\" .. GREY_FILE
    local f = io.open(path, "rb")
    if f then
        f:close()
    else
        local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
        local canvasOut, contextOut, extra = {}, {}, {}
        krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
        canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
            { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
        krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
        krl:ExportRenderTarget(gi, rt, W.dir, "map-colour.png")
        local err = AP_GreyscalePNG(W.dir .. "\\map-colour.png", path, "0.4545")
        os.remove(W.dir .. "\\map-colour.png")
        if err ~= "" then log("map: no greyscale copy: " .. tostring(err)); return nil end
        log("map: made the greyscale copy " .. path)
    end
    greyTex = krl:ImportFileAsTexture2D(gi, path)
    if not greyTex or not greyTex:IsValid() then log("map: could not load " .. path); greyTex = nil; return nil end
    W.keep(greyTex)
    return greyTex
end
local triangles = {}          -- area index .. tint -> FCanvasUVTri list, built when first needed
local function trianglesOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if triangles[key] then return triangles[key] end
    SHAPES = SHAPES or require("area_shapes" .. SUFFIX)
    local v, out = SHAPES.areas[k] or {}, {}
    for t = 1, #v - 5, 6 do
        local tri = {}
        for j = 0, 2 do
            local u, w = v[t + 2 * j], v[t + 2 * j + 1]
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = w * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = w }
            tri["V" .. j .. "_Color"] = tint
        end
        out[#out + 1] = tri
    end
    triangles[key] = out
    return out
end
local bands = {}              -- area index .. tint -> FCanvasUVTri list of its edge band
local function bandOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if bands[key] then return bands[key] end
    SHAPES = SHAPES or require("area_shapes" .. SUFFIX)
    local v, out = (SHAPES.edges or {})[k] or {}, {}
    for t = 1, #v - 8, 9 do
        local tri = {}
        for j = 0, 2 do
            local u, w, sh = v[t + 3 * j], v[t + 3 * j + 1], v[t + 3 * j + 2]
            local f = EDGE_SHADE + (1 - EDGE_SHADE) * sh
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = w * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = w }
            tri["V" .. j .. "_Color"] = { R = tint.R * f, G = tint.G * f, B = tint.B * f, A = 1 }
        end
        out[#out + 1] = tri
    end
    bands[key] = out
    return out
end
local function drawMap(ctx, passes)
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    pcall(LoadAsset, MAP_TEXTURE)                         -- LoadAsset wants the full Package.Object path
    local tex = StaticFindObject(MAP_TEXTURE)
    if not tex or not tex:IsValid() then return false end
    local gi = owner()
    if not gi then return false end
    local okg, grey = pcall(greyscaleMap, krl, tex)
    if not okg then log("map: greyscale copy failed: " .. tostring(grey)); grey = nil end
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8_SRGB
        if not mapRT or not mapRT:IsValid() then return false end
        W.keep(mapRT)
    end
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
    local canvas = canvasOut.Canvas
    if not canvas then return false end
    canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
        WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    for k, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then
            local tris = trianglesOf(k - 1, grey and WHITE or FADE)
            if #tris > 0 then canvas:K2_DrawTriangle(grey or tex, tris) end
        end
    end
    for k, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then
            local band = bandOf(k - 1, grey and WHITE or FADE)
            if #band > 0 then canvas:K2_DrawTriangle(grey or tex, band) end
        end
    end
    local okS, errS = pcall(drawStamps, canvas, krl, gi, lockedList(passes))
    if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    return true
end
-- With the C++ compositor (AP_ComposeMap): the whole picture is made on the player's machine in the background, from
-- the colour map (saved once, map-colour-1.png) and area_labels.png, with soft anti-aliased boundaries and an inner
-- shadow; when it is ready it is loaded and drawn into the render target. The picture is the game's own art: it stays
-- in the mod folder and is never shipped.
local COLOUR_FILE = "map-colour-1.png"
local composing, composedKey, failedKey = nil, nil, nil   -- the locked set being composed / last composed / last failed
local composingList = {}                                  -- that set's area indexes (for the stamps)
-- A fingerprint of the map the game shows: 16 pixels of it drawn small. A mod that replaces the map's art changes it, so
-- the saved colour map is made again (once a session, cheaply, instead of exporting the whole map every time).
local printChecked, printNow = false, nil
local colourSaved = false      -- colourMap saved the colour map again this session (the game's map changed)
local function mapPrint(krl, tex, gi)
    local rt = krl:CreateRenderTarget2D(gi, 16, 16, 2, { R = 0, G = 0, B = 0, A = 1 }, false)
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = 16, Y = 16 }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    local parts = {}
    for i = 0, 15 do
        local c = krl:ReadRenderTargetPixel(gi, rt, (i % 4) * 4 + 2, (i // 4) * 4 + 2)
        parts[#parts + 1] = string.format("%d,%d,%d", c.R, c.G, c.B)
    end
    return table.concat(parts, ";")
end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function colourMap(krl, tex, gi)
    local path = W.dir .. "\\" .. COLOUR_FILE
    if not printChecked then
        printChecked = true
        local ok, fp = pcall(mapPrint, krl, tex, gi)
        if ok then printNow = fp else log("map: no fingerprint (" .. tostring(fp) .. "): keeping the saved colour map") end
    end
    local saved = readFile(path .. ".txt")
    local f = io.open(path, "rb")
    if f then
        f:close()
        if not printNow or saved == printNow then return path end
        if saved then log("map: the game's map picture changed (another mod?): saving it again")
        else log("map: saving the colour map again with a fingerprint (made before map changes were checked)") end
    end
    local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    krl:ExportRenderTarget(gi, rt, W.dir, COLOUR_FILE)
    colourSaved = true
    if printNow then
        local out = io.open(path .. ".txt", "wb")
        if out then out:write(printNow); out:close() end
    end
    log("map: saved the colour map " .. path)
    return path
end
local function lockedIndexes(passes)
    local out = {}
    for k, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then out[#out + 1] = tostring(k - 1) end
    end
    return table.concat(out, ",")
end
-- The "Territories" look (the user's direction 1, worked out with the Art & Assets lane, 2026-11-07; their lean, tweaks
-- may follow): the game's own map and fog underneath; every area tinted in its colour by its state, with a soft rim
-- inside its edge, over land and sea alike (areas take in their waters, and so do their walls); the standing walls as a
-- cream glow and core, drawn from their own positions. The C++ part composes it (AP_ComposeTerritories) from the
-- layout's labels, the areas' states and the standing walls: an overlay for the map picture (drawn over the game's map)
-- and the same over a dark fog for the unexplored parts (the fog picture C++ shows). config.txt map_style=chart: the
-- explorer's chart and greyscale instead.
W.mapStyle = "territories"
local TERR_OVERLAY, TERR_FOG, TERR_SIZE = "map-territories.png", "map-territories-fog.png", 2048
local TERR_FOG_COLOUR = "0E1A24"
local START_COLOUR, SEALED_COLOUR = "24E0CC", "5A6472"
-- The walls: "glow colour,alpha,core colour,alpha,glow px,blur sigma,core px" (px of a 4096 map). The Art lane's colours;
-- see-through (dev.32 playtest, 2026-11-08: "I like the brightness, but perhaps we should add some translucence?"; the
-- core was solid, the glow 0.55).
local TERR_WALLS = "FFE9B0,0.35,FFF4DC,0.6,10,3,5"
local terr = { composing = nil, done = nil, failed = nil, size = nil, whole = false }
local function territories() return W.mapStyle == "territories" and AP_ComposeTerritories ~= nil end
-- "index:state:RRGGBB,...": v visited, u unlocked not yet visited, l locked, s sealed (beyond the goal).
local function areaSpec(passes)
    local out = {}
    for k, name in ipairs(DATA.areas) do
        if name ~= SEA then
            local st
            if W.beyond[name] then st = "s"
            elseif isOpen(name, passes) then st = (name == START or W.visited[name]) and "v" or "u"
            else st = "l" end
            local parent = W.parentOf(name)
            local hex = st == "s" and SEALED_COLOUR or AREA_COLOURS[parent] or (parent == START and START_COLOUR) or "9AA3B5"
            out[#out + 1] = (k - 1) .. ":" .. st .. ":" .. hex
        end
    end
    return table.concat(out, ",")
end
-- The standing walls (up unless both sides are open; open sea counts as open) as "u1,v1,u2,v2;..." on the map square.
-- A piece runs along its yaw: (sin yaw, -cos yaw) in map u, v (the Art lane's mock lined them up with the labels so).
local function wallSpec(passes)
    local x0, x1, y0, y1 = MAP.bounds[1], MAP.bounds[2], MAP.bounds[3], MAP.bounds[4]
    local out = {}
    for _, w in ipairs(DATA.walls) do
        if not (isOpen(DATA.areas[w[5] + 1], passes) and isOpen(DATA.areas[w[6] + 1], passes)) then
            local u, v = (w[2] - y0) / (y1 - y0), (x1 - w[1]) / (x1 - x0)
            local half = w[3] / 2 / (x1 - x0)
            local yaw = math.rad(w[4])
            local du, dv = math.sin(yaw) * half, -math.cos(yaw) * half
            out[#out + 1] = string.format("%.5f,%.5f,%.5f,%.5f", u - du, v - dv, u + du, v + dv)
        end
    end
    return table.concat(out, ";")
end
W.areaSpec, W.wallSpec = areaSpec, wallSpec
-- As composeMap: true once the map picture holds this key's look, "failed" once composing it failed.
local function composeTerritories(ctx, passes, key)
    if not terr.composing then
        if terr.done == key then return true end
        if terr.failed == key then return "failed" end
    end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return false end
    if terr.composing then
        local st = AP_TerritoriesStatus()
        if st == "busy" then return false end
        local k = terr.composing
        terr.composing = nil
        if st ~= "done" then log("map territories: composing failed: " .. tostring(st)); terr.failed = k; return "failed" end
        pcall(LoadAsset, MAP_TEXTURE)
        local map = StaticFindObject(MAP_TEXTURE)
        local over = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. TERR_OVERLAY)
        if terr.whole then map = over end                                    -- (the whole picture: the map in it)
        if not (map and map:IsValid() and over and over:IsValid()) then
            log("map territories: could not load " .. (map and map:IsValid() and TERR_OVERLAY or "the game's map")); terr.failed = k; return "failed"
        end
        W.keep(over)
        if not mapRT or not mapRT:IsValid() then
            mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)
            W.keep(mapRT)
        end
        local canvasOut, contextOut, extra = {}, {}, {}
        krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
        canvasOut.Canvas:K2_DrawTexture(map, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
            { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
        if not terr.whole then
            canvasOut.Canvas:K2_DrawTexture(over, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
                { X = 1, Y = 1 }, WHITE, 2, 0, { X = 0.5, Y = 0.5 })
        end
        krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
        terr.done = k
        once("terrdrawn" .. tostring(terr.whole), terr.whole and "map territories: drawn (the player's map, locked areas greyscale)"
            or "map territories: drawn over the game's map")
        return k == key
    end
    -- From the Art lane's distance field when the DLL has it (dev.34: smooth at 4096, where the 2048 label map gave stairs
    -- and octagons; area_field*.png, made from the label maps by tools/map_fields.py), else from the label map at 2048.
    local field = W.dir .. "\\area_field" .. SUFFIX .. ".png"
    local fh = AP_ComposeField and io.open(field, "rb")
    if fh then fh:close() end
    local err, size, whole
    if fh then
        -- With the colour map (the player's own map, saved once; the user, dev.33: locked areas' "interior should be the
        -- greyscale"): the whole map picture, greyscale where locked, the walls there in the area's colour.
        local colour = W.dir .. "\\" .. COLOUR_FILE
        local ch = io.open(colour, "rb")
        if ch then ch:close()
        else
            pcall(LoadAsset, MAP_TEXTURE)
            local tex = StaticFindObject(MAP_TEXTURE)
            if tex and tex:IsValid() then
                local okc, path = pcall(colourMap, krl, tex, gi)
                ch = okc and path and io.open(path, "rb")
                if ch then ch:close() end
            end
        end
        size, whole = 4096, ch and true or false
        err = AP_ComposeField(field, areaSpec(passes), wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY,
            W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR, tostring(size), whole and colour or "", "0.4545")
    else
        size = TERR_SIZE
        err = AP_ComposeTerritories(W.dir .. "\\area_labels" .. SUFFIX .. ".png", areaSpec(passes), wallSpec(passes), TERR_WALLS,
            W.dir .. "\\" .. TERR_OVERLAY, W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR, tostring(size))
    end
    if err == "" then
        terr.composing, terr.size, terr.whole = key, size, whole or false
        once("terrfrom" .. size, "map territories: composing " .. (fh and "from the distance field" or "from the label map") .. " at " .. size)
    elseif err ~= "busy" then once("terr" .. err, "map territories: could not compose: " .. err) end
    return false
end

-- Starts or finishes a composition; true once the render target holds the picture for this locked set, "failed" once
-- composing it failed. It runs from the start, not when the map first opens (dev.16 playtest, 2026-11-07: the picture
-- was only started once a map screen was found, so the first opening showed the game's map for a second or two while
-- it was made, and C++ had nothing to show yet). Until the map opens, the colour map saved in an earlier session is used
-- as it is, without loading the game's 8192 px map; at the first opening the game's map is checked against it once
-- (the fingerprint) and, if it changed (another mod), saved again and the picture made again.
local function composeMap(ctx, passes, key, open)
    if territories() then return composeTerritories(ctx, passes, key) end
    if not composing then                    -- the usual case: nothing to do, nothing to look up
        if composedKey == key then
            if open and not printChecked then
                pcall(LoadAsset, MAP_TEXTURE)
                local tex = StaticFindObject(MAP_TEXTURE)
                local gi = owner()
                if tex and tex:IsValid() and gi then
                    colourMap(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), tex, gi)
                    if colourSaved then composedKey = nil; return false end     -- made again from the new colour map
                end
            end
            return true
        end
        if failedKey == key then return "failed" end
    end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return false end
    if composing then
        local st = AP_ComposeStatus()
        if st == "busy" then return false end
        local done = composing
        composing = nil
        -- A failure is not a picture: the render target still holds the last one. That set is not composed again (no
        -- retry loop); the map is drawn without the compositor instead.
        if st ~= "done" then log("map: composing failed: " .. tostring(st) .. "; drawing it without the compositor"); failedKey = done; return false end
        local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\map-composed.png")
        if not tex or not tex:IsValid() then log("map: could not load the composed map; drawing it without the compositor"); failedKey = done; return false end
        if not mapRT or not mapRT:IsValid() then
            mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)
            W.keep(mapRT)
        end
        local canvasOut, contextOut, extra = {}, {}, {}
        krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
        canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
            { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
        local okS, errS = pcall(drawStamps, canvasOut.Canvas, krl, gi, composingList)
        if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
        krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
        composedKey = done
        return done == key
    end
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local saved = io.open(colour, "rb")
    if saved then saved:close() end
    if open or printChecked or not saved then
        pcall(LoadAsset, MAP_TEXTURE)
        local tex = StaticFindObject(MAP_TEXTURE)
        if not tex or not tex:IsValid() then return false end
        colour = colourMap(krl, tex, gi)
    end
    local err = AP_ComposeMap(colour, W.dir .. "\\area_labels" .. SUFFIX .. ".png", lockedIndexes(passes),
        W.dir .. "\\map-composed.png", "0.4545")
    if err == "" then composing, composingList = key, lockedList(passes) elseif err ~= "busy" then once("compose" .. err, "map: could not compose: " .. err) end
    return false
end

local mapShownAt = 0           -- map screens with a map image found on the last update (for the perf probe's replay)
function W.mapShown() return mapShownAt > 0 end

-- The map screen from C++ (APConnector's AP_MapScreen, map_screen.cpp; the user, 2026-11-06: Lua's swaps show, do the
-- map in C++). It changes the screen inside the game's own Setup, before the screen draws; Lua hands it the picture and
-- the fog's colour. Lua still puts the picture back as before when it finds the game's, but with C++ working it should
-- never have to: each time it does is counted and logged (the swap the player sees).
-- PROBE BUILD (untested in game): a parchment fog (FOG_TEST, linear light, alpha 0.6) to see whether the fog's colour
-- alpha lets the map and the stamps show through; the explored mask is exported once (fog-mask.png) to see which way
-- round it is, for the explorer's-chart fog (unexplored areas drawn as a chart, the user's idea).
local FOG_TEST = "0.815,0.693,0.434,0.6"
local cpp = { body = nil, fog = false, opened = 0, fixes = 0, maskDone = false }
W.cppOff = false                     -- config.txt map_cpp=0 (main.lua): C++ leaves the screen alone; Lua alone, as before
local function tellCpp()
    if not AP_MapScreen then return end
    if not cpp.fog then
        cpp.fog = true
        AP_MapScreen("enable", W.cppOff and "0" or "1")
        AP_MapScreen("fog", territories() and "" or FOG_TEST)   -- (Territories: the game's own fog until its picture)
    end
    if mapRT and mapRT:IsValid() then
        local full = mapRT:GetFullName()
        local path = full:match("^%S+%s+(.+)$") or full            -- "Class /Path.Object" -> "/Path.Object"
        if path ~= cpp.body then cpp.body = path; AP_MapScreen("body", path) end
    end
end
-- What the fog is made of, and its explored mask exported (once a session).
local function probeMask(screen)
    local dmi = screen.MaskTextureMaterial
    if not (dmi and dmi:IsValid()) then return "no fog material" end
    local function tex(param)
        local ok, t = pcall(function() return dmi:K2_GetTextureParameterValue(FName(param)) end)
        return ok and t and t:IsValid() and t or nil
    end
    local rt, def = tex("TargetTexture"), tex("DefaultMaskTexture")
    local info = "fog material " .. dmi:GetFullName() .. "; mask " .. (rt and (rt:GetFullName() .. " " .. tostring(rt.SizeX)
        .. "x" .. tostring(rt.SizeY) .. " format " .. tostring(rt.RenderTargetFormat)) or "none")
        .. "; default mask " .. (def and def:GetFullName() or "none")
    local gi = owner()
    -- (With the chart on, its own step exports the mask: not twice in one opening.)
    if rt and gi and (W.chartOff or not AP_ComposeFog) then
        local ok, err = pcall(function()
            StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ExportRenderTarget(gi, rt, W.dir, "fog-mask.png")
        end)
        info = info .. (ok and "; exported to fog-mask.png" or ("; export failed: " .. tostring(err)))
    end
    -- The default mask (a texture, what every player sees uncovered): drawn into a render target of its size to export.
    if def and gi then
        local ok, err = pcall(function()
            local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            local w, h = def:Blueprint_GetSizeX(), def:Blueprint_GetSizeY()
            local drt = krl:CreateRenderTarget2D(gi, w, h, 2, { R = 0, G = 0, B = 0, A = 0 }, false)
            local canvasOut, contextOut, extra = {}, {}, {}
            krl:BeginDrawCanvasToRenderTarget(gi, drt, canvasOut, contextOut, extra)
            canvasOut.Canvas:K2_DrawTexture(def, { X = 0, Y = 0 }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
                WHITE, 0, 0, { X = 0.5, Y = 0.5 })
            krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
            krl:ExportRenderTarget(gi, drt, W.dir, "fog-default-mask.png")
            return w .. "x" .. h
        end)
        info = info .. (ok and ("; default mask " .. tostring(err) .. " exported to fog-default-mask.png")
            or ("; default mask export failed: " .. tostring(err)))
    end
    return info
end

-- The explorer's-chart fog (the user, 2026-11-06: the black fog replaced by a basic map drawn like an explorer's chart,
-- with the locked-area stamps on it; art: the Art lane's ap-chart-*.png, the user's pick A). All drawn on the player's
-- machine by the C++ part from the game's own map (never shipped):
--   1. the chart, once a session, from the saved colour map (compose_chart);
--   2. when the map opens (at most every EXPORT_GAP updates) the explored mask is exported and the fog picture made from
--      it: the chart where unexplored, clear where explored, the stamps on it (compose_fog); which channel of the mask
--      means explored, and which way round, is read once from the mask at the player and beyond the world's edge;
--   3. the fog picture is handed to C++ (AP_MapScreen "fogpic"), which shows it in the fog image inside the screen's
--      own Setup: from the next opening, never swapped in view. The last session's picture is used until a new one.
-- UNTESTED IN GAME. config.txt map_chart=0 keeps the game's fog.
local CHART_SIZE = 2048
local CHART_FILE, FOG_FILE = "map-chart.png", "map-fog.png"
-- Each look keeps its own fog picture (dev.32 playtest, 2026-11-08: the first opening showed dev.31's chart, the last
-- session's map-fog.png, until the territories' one was made).
local function fogFile() return territories() and "map-fog-territories.png" or FOG_FILE end
local EXPORT_GAP = 200                     -- updates (about a minute) between exports of the explored mask
W.chartOff = false
local chart = { state = "none", fog = "idle", spec = nil, ticks = 0, exportedAt = nil, tex = nil, stampKey = nil,
                old = false }
local function exists(path) local f = io.open(path, "rb"); if f then f:close(); return true end return false end
local function artFile(name)
    local path = ART.dir .. "\\art\\" .. name .. ".png"
    return exists(path) and path or ""
end
-- "explored" in the mask: the channel that differs most between the player (explored) and a corner beyond the world's
-- edge (never), and which way. nil (and why) when no channel tells them apart.
local function maskSpec(ctx)
    local okp, at = pcall(function() return ctx:K2_GetActorLocation() end)
    if not (okp and at) then return nil, "no player position" end
    local x0, x1, y0, y1 = MAP.bounds[1], MAP.bounds[2], MAP.bounds[3], MAP.bounds[4]
    local u, v = (at.Y - y0) / (y1 - y0), (x1 - at.X) / (x1 - x0)
    local mask = W.dir .. "\\fog-mask.png"
    local here, corner = AP_SamplePNG(mask, tostring(u), tostring(v)), AP_SamplePNG(mask, "0.02", "0.02")
    local a, b = {}, {}
    for n in tostring(here):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(corner):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    local info = string.format("at the player (%.3f, %.3f) %s, beyond the world's edge %s", u, v, tostring(here), tostring(corner))
    if #a ~= 4 or #b ~= 4 then return nil, info end
    local best, diff = nil, 0
    for c = 1, 4 do if math.abs(a[c] - b[c]) > math.abs(diff) then best, diff = c, a[c] - b[c] end end
    if math.abs(diff) < 64 then return nil, info .. ": no channel tells them apart" end
    return ("rgba"):sub(best, best) .. (diff > 0 and "+" or "-"), info
end
local function exportMask(screen, krl, gi)
    local dmi = screen.MaskTextureMaterial
    if not (dmi and dmi:IsValid()) then return "no fog material" end
    local rt = dmi:K2_GetTextureParameterValue(FName("TargetTexture"))
    if not (rt and rt:IsValid()) then return "no explored mask" end
    krl:ExportRenderTarget(gi, rt, W.dir, "fog-mask.png")
    return true
end
-- The explored mask without the map screen (dev.34 playtest: the first opening showed the last session's fog picture,
-- and a second opening the game made without Setup kept it, so the new look showed about a minute in): the player's own
-- world map data holds it (UPalWorldMapUIData:GetRenderTargetByMapName "MainMap", the render target the screen's fog
-- shows), so it is read once the fog art is ready, before the map ever opens. nil while there is none.
local function worldMask(ctx)
    local ok, rt = pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local wmd = util and util:IsValid() and util:GetLocalWorldMapData(ctx)
        if not (wmd and wmd:IsValid()) then return nil end
        local r = wmd:GetRenderTargetByMapName(FName("MainMap"))
        if r and r:IsValid() then return r end
        r = wmd:GetCurrentRenderTarget()
        return r and r:IsValid() and r or nil
    end)
    return ok and rt or nil
end
-- The stamps for the fog picture: "path|u|v|px;..." (as drawStamps places them on the 4096 map).
local function stampList(locked)
    if iconsActive() then return "" end
    local parts = {}
    for _, k in ipairs(locked) do
        local c, name = CENTRES[k], DATA.areas[k + 1]
        if c and name then
            local file = W.beyond[name] and "ap-map-stamp-sealed" or ("ap-map-stamp-" .. slugOf(W.parentOf(name)))
            local path = artFile(file)
            if path == "" then path = artFile("ap-map-stamp") end
            if path ~= "" then parts[#parts + 1] = table.concat({ path, c[3] or c[1], c[4] or c[2], stampSize(c) }, "|") end
        end
    end
    return table.concat(parts, ";")
end
-- The areas on the chart (the user, 2026-11-07: "should the regions on the unexplored map have better boundaries?";
-- go): a border between neighbouring areas and a hatch over locked ones, drawn by the C++ compositor from the area
-- labels (dev.29's DLL; an older one ignores it). The user's picks in the Art lane (2026-11-07): "dashed brown ink"
-- (59,42,26 at 210, 3 px, dash 14 / gap 8 at the 2048 chart) and the single diagonal hatch (art/ap-chart-hatch.png; a
-- plain hatch in the ink if the file is missing). dev.30 test: both ran out over the sea (an area's labels take in its
-- waters), the hatch made the map busy, and the line stair-stepped zoomed in: now on land only (the colour map tells
-- land from sea, as for the chart), the hatch at 0.28 (was 0.45), and the line's edge softened (dev.31's DLL).
-- config.txt map_regions=0: none.
W.regionsOff = false
local REGION_INK, REGION_WIDTH, REGION_DASH, REGION_GAP, REGION_HATCH = "59,42,26,210", 3, 14, 8, 0.28
local function regionSpec(passes)
    if W.regionsOff then return "" end
    return table.concat({ W.dir .. "\\area_labels" .. SUFFIX .. ".png", lockedIndexes(passes), artFile("ap-chart-hatch"),
        REGION_INK, tostring(REGION_WIDTH), tostring(REGION_DASH), tostring(REGION_GAP), tostring(REGION_HATCH),
        exists(W.dir .. "\\" .. COLOUR_FILE) and (W.dir .. "\\" .. COLOUR_FILE) or "", "0.4545" }, "|")
end
W.regionSpec = regionSpec
local function startFog(stamps, regions, tag)
    local def = W.dir .. "\\fog-default-mask.png"
    local art = territories() and TERR_FOG or CHART_FILE
    local size = territories() and terr.size or CHART_SIZE                  -- (the fog art's own size: its 8-bit path)
    local err = AP_ComposeFog(W.dir .. "\\" .. art, W.dir .. "\\fog-mask.png", exists(def) and def or "", chart.spec,
        W.dir .. "\\" .. fogFile(), tostring(size), stamps, regions)
    if err == "" then chart.fog, chart.stampKey = "composing", stamps .. "\n" .. regions .. (tag or "")
    elseif err ~= "busy" then once("fogstart" .. err, "map chart: could not make the fog: " .. err) end
end
local function chartTick(ctx, screens, opening, passes)
    if W.chartOff or not (AP_ComposeChart and AP_ComposeFog and AP_SamplePNG and AP_MapScreen) then return end
    chart.ticks = chart.ticks + 1
    if opening then chart.want = true end                                    -- read the mask on this opening
    if #screens == 0 then chart.want = false end                             -- (closed before it was read)
    local gi = owner()
    if not gi then return end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if chart.state == "none" and territories() then                          -- 1. (the territories' fog art)
        if terr.done and exists(W.dir .. "\\" .. TERR_FOG) then chart.state = "ready"; log("map territories: the fog art is ready") end
        return
    elseif chart.state == "none" then                                        -- 1. the chart
        local colour = W.dir .. "\\" .. COLOUR_FILE
        if not exists(colour) then return end
        local err = AP_ComposeChart(colour, artFile("ap-chart-paper"), artFile("ap-chart-sea"), artFile("ap-chart-compass"),
            W.dir .. "\\" .. CHART_FILE, tostring(CHART_SIZE), "0.4545")
        if err == "" then chart.state = "composing"
        elseif err ~= "busy" then chart.state = "failed"; log("map chart: could not start: " .. err) end
        return
    elseif chart.state == "composing" then
        local st = AP_ChartStatus()
        if st == "busy" then return end
        if st ~= "done" then chart.state = "failed"; log("map chart: failed: " .. tostring(st)); return end
        chart.state = "ready"
        log("map chart: drawn (" .. CHART_SIZE .. " px)")
    end
    if chart.state ~= "ready" then return end
    local load = false
    if chart.fog == "composing" then                                         -- 2. the fog picture
        local st = AP_FogStatus()
        if st == "busy" then return end
        chart.fog = "idle"
        if st ~= "done" then once("fogerr" .. tostring(st), "map chart: the fog failed: " .. tostring(st)); return end
        load = true
    elseif not chart.old and not chart.tex and exists(W.dir .. "\\" .. fogFile()) then
        chart.old, load = true, true                                         -- the last session's, until a new one
    end
    if chart.fog == "idle" and not load then
        local tagged = territories()
        local stamps = tagged and "" or stampList(lockedList(passes))
        local regions = tagged and "" or regionSpec(passes)
        local tag = tagged and ("#territories " .. tostring(terr.done)) or ""   -- (made again with the overlay)
        if not chart.exportedAt and not chart.want and (chart.early or 0) < 10 and chart.ticks % 20 == 0 then
            chart.early = (chart.early or 0) + 1                              -- (before the map opens: see worldMask)
            local rt = worldMask(ctx)
            local okE = rt and pcall(function() krl:ExportRenderTarget(gi, rt, W.dir, "fog-mask.png") end)
            local spec, info = chart.spec, nil
            if okE and not spec then spec, info = maskSpec(ctx) end
            if okE and spec then
                chart.spec, chart.exportedAt = spec, chart.ticks
                log("map chart: the explored mask read before the map opened" .. (info and (": " .. info) or ""))
                startFog(stamps, regions, tag)
            elseif chart.early == 10 then
                log("map chart: the explored mask could not be read before the map opened (" .. (rt and tostring(info) or "no world map data")
                    .. "); from the first opening instead")
            end
        elseif chart.want and screens[#screens] and (not chart.exportedAt or chart.ticks - chart.exportedAt >= EXPORT_GAP) then
            chart.exportedAt, chart.want = chart.ticks, false
            local ok, res = pcall(exportMask, screens[#screens], krl, gi)
            if not ok or res ~= true then once("fogexp" .. tostring(res), "map chart: could not export the explored mask: " .. tostring(res)); return end
            if not chart.spec then
                local spec, info = maskSpec(ctx)
                log("map chart: the explored mask " .. info .. (spec and (": explored reads " .. spec) or ""))
                if not spec then chart.state = "failed"; return end
                chart.spec = spec
            end
            startFog(stamps, regions, tag)
        elseif chart.spec and chart.stampKey and stamps .. "\n" .. regions .. tag ~= chart.stampKey then
            startFog(stamps, regions, tag)                                   -- a pass: the same mask, new stamps, hatch or look
        end
    end
    if load then                                                             -- 3. shown from the next opening
        local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. fogFile())
        if not (tex and tex:IsValid()) then once("fogload", "map chart: could not load " .. fogFile()); return end
        W.keep(tex)
        chart.tex = tex
        local full = tex:GetFullName()
        AP_MapScreen("fogpic", full:match("^%S+%s+(.+)$") or full)
        log("map chart: the fog picture is ready (" .. (chart.old and chart.fog == "idle" and not chart.stampKey and "last session's" or "new") .. ")")
    end
end
W.chartStatus = function() return chart end

-- The locked areas as the map's own icons (the user, 2026-11-07: stamps drawn into the picture grew and shrank with
-- the zoom, unlike the game's icons, and many sat in odd places). The map screen's "Add Icon By Location" (pak, 2026-11-07)
-- puts an icon at a world location on one of its icon canvases at 64x64, and its "Update Map Icons" (run on every scroll
-- and zoom) scales everything on those canvases by 1 / the map's scale, so icons keep one size on screen. IgnoreMask
-- puts it on the canvas the fog never hides. The icon is the game's plain one (WBP_WorldMap_IconBase_OnlyIcon: an image
-- and an invisible button; ChangeTexture sets the image). Each goes at its area's deepest point (the fog no longer hides
-- it, so it no longer needs the side nearest the start). It ignores the pointer: hovering would open the game's info box
-- with nothing in it. The map screen lasts until the world closes (dev.17 log: built at the first opening, destroyed at
-- Return to title), so the icons are added once per screen, and again when a pass changes the locked set or the game
-- drops them. UNTESTED IN GAME: if anything fails, the stamps are drawn into the picture again (iconsFailed).
local ICON_ASSET = "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_WorldMap_IconBase_OnlyIcon.WBP_WorldMap_IconBase_OnlyIcon"
-- Unlocked areas the player has not stood in yet get an open stamp (the user, 2026-11-07: "some other image type ... to
-- show that a region has been unlocked, even when it is unexplored"; go): the Art lane's ap-map-stamp-open-<area>.png
-- (or ap-map-stamp-open.png), none until there is one. W.visited: the core's set of areas stood in (in its save).
W.visited = {}
local function openList(passes)
    local out = {}
    for k, name in ipairs(DATA.areas) do
        if name ~= SEA and name ~= START and passes[name] and not W.beyond[name] and not W.visited[name] then out[#out + 1] = k - 1 end
    end
    return out
end
local function openTexture(k)
    local name = DATA.areas[k + 1]
    local own = name and ("ap-map-stamp-open-" .. slugOf(W.parentOf(name)))
    if own and artFile(own) ~= "" then return ART.texture(own) end
    if artFile("ap-map-stamp-open") ~= "" then return ART.texture("ap-map-stamp-open") end
    return nil
end
local mapIcons = { screen = nil, key = nil, list = {} }
-- A map point (0-1 across and down the 4096 map) as a world location (game-systems: pixel = ((Y + 724400) / 1448800,
-- (349400 - X) / 1448800) of the map's width).
local function worldAt(u, v) return { X = 349400 - v * 1448800, Y = u * 1448800 - 724400, Z = 0 } end
W.worldAt = worldAt
local function placeIcons(screen, passes, key)
    local addr = tostring(screen:GetAddress())
    local first = mapIcons.list[1]
    local okp, still = pcall(function() return first:IsValid() and first:GetParent():IsValid() end)
    if mapIcons.screen == addr and mapIcons.key == key and (not first or (okp and still)) then return end
    for _, icon in ipairs(mapIcons.list) do pcall(function() if icon:IsValid() then icon:RemoveFromParent() end end) end
    mapIcons.list, mapIcons.screen, mapIcons.key = {}, addr, key
    local cls = StaticFindObject(ICON_ASSET .. "_C")
    if not (cls and cls:IsValid()) then pcall(LoadAsset, ICON_ASSET); cls = StaticFindObject(ICON_ASSET .. "_C") end
    if not (cls and cls:IsValid()) then error("no icon class " .. ICON_ASSET .. "_C") end
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local added, shown = 0, 0
    for _, k in ipairs(lockedList(passes)) do
        local c, tex = CENTRES[k], stampTexture(k)
        if c and tex then
            local icon = wbl:Create(screen, cls, nil)
            if not (icon and icon:IsValid()) then error("could not make a map icon") end
            icon:ChangeTexture(tex)
            local out = {}
            screen["Add Icon By Location"](screen, icon, worldAt(c[1], c[2]), true, false, out)
            pcall(function() icon:SetVisibility(3) end)        -- HitTestInvisible
            mapIcons.list[#mapIcons.list + 1] = icon
            added = added + 1
            if out.Added then shown = shown + 1 end
        end
    end
    local opened = 0
    for _, k in ipairs(openList(passes)) do
        local c, tex = CENTRES[k], openTexture(k)
        if c and tex then
            local icon = wbl:Create(screen, cls, nil)
            if not (icon and icon:IsValid()) then error("could not make a map icon") end
            icon:ChangeTexture(tex)
            screen["Add Icon By Location"](screen, icon, worldAt(c[1], c[2]), true, false, {})
            pcall(function() icon:SetVisibility(3) end)
            mapIcons.list[#mapIcons.list + 1] = icon
            opened = opened + 1
        end
    end
    screen["Update Map Icons"](screen)          -- each icon's scale for the current zoom (the game does it on scroll/zoom)
    local where = ""
    local okw, parent = pcall(function() return mapIcons.list[1] and mapIcons.list[1]:GetParent():GetFName():ToString() end)
    if okw and parent then where = " on " .. parent end
    log("map icons: " .. added .. " locked area(s) added" .. where .. " (" .. shown .. " said visible), " .. opened
        .. " open not yet visited")
end

function W.updateMap(enabled, passes, ctx)
    local wasShown = mapShownAt > 0                  -- whether the map was open at the last update
    mapShownAt = 0
    if not enabled then return end
    -- The game keeps a template of the map screen beside the real ones; only a real one has its map image. There may be
    -- more than one real one (different menus), and a map screen sets its own picture again when it opens, so every
    -- one is checked each time and given the greyed map whenever it shows anything else.
    -- Only the main world's screen: the game also builds the World Tree's (MapName "Tree"), which shows T_WorldMap for a
    -- moment as it is set up (dev.17 log, 2026-11-07); a screen whose name can't be read is kept, as before.
    -- Not the last world's (dev.35 playtest: after Return to title and a second world load, the first world's screens
    -- were still about until collected, and the icons went on one of them): a screen whose owning player is gone is left
    -- alone; one whose owner can't be read is kept.
    local images, screens = {}, {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function() local i = b.Image_MapBody; return i:IsValid() and i or nil end)
        local okn, mapName = pcall(function() return b.MapName:ToString() end)
        local main = not (okn and type(mapName) == "string" and mapName ~= "" and mapName ~= "None") or mapName:find("Main", 1, true)
        local okp, owner = pcall(function() return b:GetOwningPlayer() end)
        local gone = okp and not (owner and owner:IsValid())
        if gone then once("stalescreen", "map: a map screen of the last world left alone (its player is gone)") end
        if b:IsValid() and ok and img and main and not gone then images[#images + 1] = img; screens[#screens + 1] = b end
    end
    mapShownAt = #images
    -- The chart is drawn in the background from the start; the mask is read while the map is open.
    local okt, errt = pcall(chartTick, ctx, screens, #images > 0 and not wasShown, passes)
    if not okt then once("charterr" .. tostring(errt), "map chart error: " .. tostring(errt)) end
    -- C++ is switched on from the start, not once the picture is ready (dev.16 playtest, 2026-11-07: the map opened
    -- 3 s before the picture was, and C++ logged "OFF; Setup ran 0x" though its hook saw Setup run).
    local okc0, errc0 = pcall(tellCpp)
    if not okc0 then once("cpperr", "map screen (C++): " .. tostring(errc0)) end
    if AP_MapScreen and #images > 0 and not wasShown then
        cpp.opened = cpp.opened + 1
        if cpp.opened <= 3 then
            log("map screen (C++): " .. tostring(AP_MapScreen("status", "")) .. "; Lua put the picture back " .. cpp.fixes .. "x")
        end
        if not cpp.maskDone then
            cpp.maskDone = true
            local ok, info = pcall(probeMask, screens[#screens])
            log("map fog: " .. tostring(info))
        end
    end
    local locked = {}
    for _, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    -- The stamps differ for areas beyond the goal; and the picture has them drawn in only without the icons (so a
    -- failure of the icons, or map_icons=0, makes the picture and the chart fog again with the stamps).
    local been = {}
    if territories() then for area in pairs(W.visited) do been[#been + 1] = area end; table.sort(been) end
    local key = table.concat(locked, "|") .. "#" .. (W.beyondSig or "") .. (iconsActive() and "#icons" or "#stamps")
        .. (territories() and ("#territories#" .. table.concat(been, "|")) or "")
    local redrawn = false
    local compose = AP_ComposeMap and AP_ComposeStatus
    if compose then
        local ok, ready = pcall(composeMap, ctx, passes, key, #images > 0)
        if not ok then once("composeerr" .. tostring(ready), "map error: " .. tostring(ready)); ready = false end
        if ready == "failed" then
            compose = false
        else
            if ready and key ~= mapKey then
                mapKey, redrawn = key, true
                log("map: " .. #locked .. " locked area(s) greyed")
            end
            if not mapKey or not mapRT then return end    -- nothing composed yet: the game's own map stays
        end
    end
    if not compose and key ~= mapKey then
        if #images == 0 then return end          -- without the compositor the map is drawn when it opens, as before
        local ok, done = pcall(drawMap, ctx, passes)
        if not ok then log("map overlay error: " .. tostring(done)); mapKey = key; return end
        if not done then return end
        mapKey, redrawn = key, true
        log("map: " .. #locked .. " locked area(s) greyed")
    end
    if not mapRT or not mapRT:IsValid() then return end
    local okc, errc = pcall(tellCpp)
    if not okc then once("cpperr", "map screen (C++): " .. tostring(errc)) end
    if #images == 0 then return end
    if iconsActive() then
        local oki, erri = pcall(placeIcons, screens[#screens], passes, key .. "#open:" .. table.concat(openList(passes), ","))
        if not oki then
            iconsFailed = true
            for _, icon in ipairs(mapIcons.list) do pcall(function() if icon:IsValid() then icon:RemoveFromParent() end end) end
            mapIcons.list = {}
            log("map icons: could not add them (" .. tostring(erri) .. "); drawing the stamps on the map instead")
        end
    end
    local want = tostring(mapRT:GetAddress())
    for _, image in ipairs(images) do
        local okr, shown = pcall(function()
            local res = image.Brush.ResourceObject
            return res and res:IsValid() and res or nil
        end)
        local current = okr and shown and tostring(shown:GetAddress()) or nil
        -- Only the main world's map is replaced: the World Tree has a map screen of its own (T_TreeMap).
        local name = okr and shown and select(2, pcall(function() return shown:GetFullName() end)) or ""
        local mainMap = current == want or tostring(name):find("T_WorldMap", 1, true) ~= nil
        if mainMap and (redrawn or current ~= want) then
            if okr and shown and current ~= want and not mapShownOn then
                mapShownOn = true
                log("map: the map screen was showing " .. tostring(select(2, pcall(function() return shown:GetFullName() end))))
            end
            if AP_MapScreen and not redrawn and current ~= want then
                cpp.fixes = cpp.fixes + 1
                if cpp.fixes <= 3 then log("map: Lua put the picture back (" .. cpp.fixes .. "x; C++ had not set it)") end
            end
            local ok, err = pcall(function() image:SetBrushResourceObject(mapRT) end)
            if not ok then once("mapshow", "map overlay: could not show it: " .. tostring(err)) end
        end
    end
end

function W.count()
    return nRaised, #DATA.walls
end


-- The seed's cut of the map (slot data options.area_size: 0 areas, 1 regions), set once a connection is ready and
-- before any wall goes up. A change takes every wall down at once (their piece numbers mean other pieces in the other
-- cut) and forgets the map pictures made for the old one; the update raises the new cut's walls.
function W.setLayout(name)
    name = name == "regions" and "regions" or "areas"
    if name == W.layout then return false end
    for _, a in pairs(raised) do pcall(function() if a:IsValid() then a:K2_DestroyActor() end end) end
    raised, nRaised, sinking, dressedAs = {}, 0, {}, {}
    SUFFIX = name == "regions" and "_regions" or ""
    DATA, MAP, SHAPES = require("area_walls" .. SUFFIX), require("area_map" .. SUFFIX), nil
    CENTRES = require("area_centres" .. SUFFIX)
    START, W.start, W.home = DATA.start, DATA.start, MAP.home
    W.layout = name
    buildTrig()
    decoded, triangles, bands = {}, {}, {}
    mapKey, composing, composedKey, failedKey, composingList = nil, nil, nil, nil, {}
    log("area locks: " .. name .. " (" .. (#DATA.areas - 1) .. " " .. name .. ", " .. #DATA.walls .. " border pieces)")
    return true
end

return W
