-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red energy grid beside the World Tree gate),
-- stretched into pieces along every border between areas (area_walls.lua, from tools/area_walls.py). A piece stays up
-- while either area it separates is locked; an Area Pass opens its area. Open sea is never locked, so an area that
-- is locked is ringed from the sea as well.
local DATA = require("area_walls")
local MAP = require("area_map")
local SHAPES = require("area_shapes")

local W = {}
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
for i, w in ipairs(DATA.walls) do
    local yaw = math.rad(w[4])
    trig[i] = { math.cos(yaw), math.sin(yaw) }
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
    W.skinNew(a)
    raised[i] = a
    nRaised = nRaised + 1
    return true
end

-- Opening a wall: it stops blocking at once, sinks out of sight (top first, so it reads as the barrier going down)
-- and is then removed.
-- The red grid shows only around a wall that blocks, so a wall keeps blocking until it is halfway down. One loop for
-- the session, made when this module loads (UE4SS cannot start one from inside a game-thread callback); it idles while
-- nothing sinks.
local sinking = {}            -- list of { actor, x, y, step }
local function sinkStep()
    local still = {}
    for _, s in ipairs(sinking) do
        local a = s[1]
        if a:IsValid() then
            s[4] = s[4] + 1
            local t = s[4] / SINK_STEPS
            local eased = t * t * (3 - 2 * t)            -- slow, fast, slow
            pcall(function() a:K2_SetActorLocation({ X = s[2], Y = s[3], Z = MID_Z - HEIGHT * eased }, false, {}, true) end)
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
local function forget(i)
    if raised[i] then raised[i], nRaised = nil, nRaised - 1 end
end
local function lower(i)
    local a = raised[i]
    forget(i)
    if not (a and a:IsValid()) then return end
    local w = DATA.walls[i]
    sinking[#sinking + 1] = { a, w[1], w[2], 0 }
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
local SKINS = { "red", "colour-rainbow", "colour-rainbow-flow", "colour-paws", "colour-routes", "colour-grid",
                "a", "b", "a3d", "b3d", "a3d-dense", "b3d-dense" }
local FLOW = 0.05
local AP_WALL = "/Game/Mods/PalworldArchipelagoArt/M_APWall.M_APWall"
local apWall = nil                                             -- M_APWall once loaded
local DENSE = { 10, 6 }
local TEAL = { R = 0.018, G = 0.745, B = 0.604, A = 1 }       -- sRGB #24E0CC, the user's pick
local NIGHT = 0.421875                                         -- the game's NightColor over its DayColor
local skin = { now = "red", want = "red", base = nil, mids = {}, failed = {} }
W.tiling, W.scroll = nil, nil                                  -- { u, v } from config.txt, or the material's own
local function meshOf(a)
    local ok, m = pcall(function() return a.Cube end)
    if ok and m and m:IsValid() then return m end
    local smc = StaticFindObject("/Script/Engine.StaticMeshComponent")
    ok, m = pcall(function() return a:GetComponentByClass(smc) end)
    if ok and m and m:IsValid() then return m end
end
local function apWallMaterial()
    if apWall and apWall:IsValid() then return apWall end
    pcall(LoadAsset, AP_WALL)
    local m = StaticFindObject(AP_WALL)
    if m and m:IsValid() then apWall = m; W.keep(m); return m end
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
    local file = name:match("^(.-)%-dense$")
    local tiling = file and DENSE or W.tiling
    local path = W.dir .. "\\walls\\ap-wall-pattern-" .. (file or name) .. ".png"
    local tex = krl:ImportFileAsTexture2D(gi, path)
    if not (tex and tex:IsValid()) then log("wall skin " .. name .. ": could not load " .. path); return nil end
    local srgb = pcall(function() tex.SRGB = false; tex:UpdateResource() end)   -- the game's pattern is linear
    W.keep(tex)
    mid = kml:CreateDynamicMaterialInstance(gi, skin.base, FName("None"), 0)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("MainTexture01"), tex)
    local night = { R = TEAL.R * NIGHT, G = TEAL.G * NIGHT, B = TEAL.B * NIGHT, A = 1 }
    for k, c in pairs({ Color = TEAL, DayColor = TEAL, NightColor = night }) do mid:SetVectorParameterValue(FName(k), c) end
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
function W.skinNew(a)
    if skin.now ~= "red" then pcall(dress, a, skin.mids[skin.now]) end
end
-- Empty or unset: the teal hex lattice, a (the user, 2026-11-05: "stick with the hex layout"); wall_skin=red for the
-- game's own red grid.
W.DEFAULT_SKIN = "a"
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
    local mid = nil
    if skin.want ~= "red" then
        mid = skinMaterial(skin.want)
        if not mid then skin.want = skin.now; return end
    end
    local n, bad = 0, 0
    for _, a in pairs(raised) do
        if a:IsValid() then
            local ok, done = pcall(dress, a, mid)
            if ok and done then n = n + 1 else bad = bad + 1 end
        end
    end
    skin.now = skin.want
    log("wall skin " .. skin.now .. ": on " .. n .. " pieces" .. (bad > 0 and (", " .. bad .. " without a mesh") or ""))
end

-- The locked-area stamps (Art & Assets lane: art/ap-map-stamp-<area>.png per area, round 2; art/ap-map-stamp.png when
-- an area has none), 256x256 tickets with a padlock, drawn on each locked area STAMP_PX across on the 4096 map, a whole
-- stamp inside the area on its side nearest the starting area (area_centres.lua, from tools/area_centres.py). v0.13.5
-- playtest: at each area's deepest point all 14 sat under the map's fog of war, which a locked area never clears.
local ART = require("art")
local CENTRES = require("area_centres")
local STAMP_PX = 88
local function slugOf(name) return (name:lower():gsub("[^%w]+", "-")) end
W.slugOf = slugOf
local function lockedList(passes)
    local out = {}
    for k, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then out[#out + 1] = k - 1 end
    end
    return out
end
local function drawStamps(canvas, krl, gi, locked)
    local n = 0
    for _, k in ipairs(locked) do
        local c, name = CENTRES[k], DATA.areas[k + 1]
        local tex = c and name and (ART.texture("ap-map-stamp-" .. slugOf(name)) or ART.texture("ap-map-stamp"))
        if tex then
            local u, v = c[3] or c[1], c[4] or c[2]
            canvas:K2_DrawTexture(tex, { X = u * RT_SIZE - STAMP_PX / 2, Y = v * RT_SIZE - STAMP_PX / 2 },
                { X = STAMP_PX, Y = STAMP_PX }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, 2, 0, { X = 0.5, Y = 0.5 })
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
-- Starts or finishes a composition; true once the render target holds the picture for this locked set, "failed" once
-- composing it failed.
local function composeMap(ctx, passes, key)
    if not composing then                    -- the usual case: nothing to do, nothing to look up
        if composedKey == key then return true end
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
    pcall(LoadAsset, MAP_TEXTURE)
    local tex = StaticFindObject(MAP_TEXTURE)
    if not tex or not tex:IsValid() then return false end
    local colour = colourMap(krl, tex, gi)
    local err = AP_ComposeMap(colour, W.dir .. "\\area_labels.png", lockedIndexes(passes),
        W.dir .. "\\map-composed.png", "0.4545")
    if err == "" then composing, composingList = key, lockedList(passes) elseif err ~= "busy" then once("compose" .. err, "map: could not compose: " .. err) end
    return false
end

local mapShownAt = 0           -- map screens with a map image found on the last update (for the perf probe's replay)
function W.mapShown() return mapShownAt > 0 end
function W.updateMap(enabled, passes, ctx)
    mapShownAt = 0
    if not enabled then return end
    -- The game keeps a template of the map screen beside the real ones; only a real one has its map image. There may be
    -- more than one real one (different menus), and a map screen sets its own picture again when it opens, so every
    -- one is checked each time and given the greyed map whenever it shows anything else.
    local images = {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function() local i = b.Image_MapBody; return i:IsValid() and i or nil end)
        if b:IsValid() and ok and img then images[#images + 1] = img end
    end
    mapShownAt = #images
    if #images == 0 then return end
    local locked = {}
    for _, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    local key = table.concat(locked, "|")
    local redrawn = false
    local compose = AP_ComposeMap and AP_ComposeStatus
    if compose then
        local ok, ready = pcall(composeMap, ctx, passes, key)
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
        local ok, done = pcall(drawMap, ctx, passes)
        if not ok then log("map overlay error: " .. tostring(done)); mapKey = key; return end
        if not done then return end
        mapKey, redrawn = key, true
        log("map: " .. #locked .. " locked area(s) greyed")
    end
    if not mapRT or not mapRT:IsValid() then return end
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
            local ok, err = pcall(function() image:SetBrushResourceObject(mapRT) end)
            if not ok then once("mapshow", "map overlay: could not show it: " .. tostring(err)) end
        end
    end
end

function W.count()
    return nRaised, #DATA.walls
end

return W
