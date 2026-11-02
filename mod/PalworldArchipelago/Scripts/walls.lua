-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red energy grid beside the World Tree gate),
-- stretched into pieces along every border between areas (area_walls.lua, from tools/area_walls.py). A piece stays up
-- while either area it separates is locked; an Area Pass opens its area. Open sea is never locked, so an area that
-- is locked is ringed from the sea as well.
local DATA = require("area_walls")
local MAP = require("area_map")

local W = {}
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
local cls, gs = nil, nil

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

-- A new world (another save, back from the title): its walls are gone with the old one; start over.
function W.reset()
    raised = {}
end

-- Test builds: the look of the walls, cycled with Ctrl+F8 through the game's own barrier materials.
local LOOKS = {
    { "Red grid (the game's air block)", "/Game/Pal/Material/Effect/MI_AirBlock_v2" },
    { "World Tree air block", "/Game/Pal/Material/Effect/MI_AirBlock_v2_WorldTreeArea" },
    { "Golden dungeon wall", "/Game/Pal/Model/Other/PalBox/old/MI_PalBox_Wall" },
    { "Tower hex shield", "/Game/Pal/Effect/Material/M_VFX_Dome_01_TF" },
    { "Wildlife Sanctuary dome", "/Game/Pal/Effect/Material_Instances/MI_Wildlife_Sanctuary_Dome" },
    { "Wildlife Sanctuary dome 2", "/Game/Pal/Effect/Material_Instances/MI_Wildlife_Sanctuary_Dome01" },
    { "Sky Island barrier", "/Game/Pal/Effect/Material_Instances/MI_AreaBarrier" },
    { "Sci-fi shield", "/Game/Others/VL_SciFiShield/Materials/Particles/MI_Shield" },
}
local look = 1
local lookMaterial = nil
local function meshes(a)
    local out = {}
    pcall(function()
        local list = a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
        local function add(e)
            local okg, obj = pcall(function() return e:get() end)
            out[#out + 1] = okg and obj or e
        end
        if type(list) == "table" then for _, e in ipairs(list) do add(e) end else list:ForEach(function(_, e) add(e) end) end
    end)
    return out
end
local function dress(a)
    if not lookMaterial then return end
    for _, m in ipairs(meshes(a)) do pcall(function() m:SetMaterial(0, lookMaterial) end) end
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
    raised[i] = a
    dress(a)
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
local function lower(i)
    local a = raised[i]
    raised[i] = nil
    if not (a and a:IsValid()) then return end
    local w = DATA.walls[i]
    sinking[#sinking + 1] = { a, w[1], w[2], 0 }
end

-- Brings the walls in line with the passes held: raises missing pieces of locked borders, takes down pieces whose
-- areas are both open (a few per call).
function W.update(enabled, passes, context)
    for i, a in pairs(raised) do                      -- walls the game removed (back to the title, another world)
        if not a:IsValid() then raised[i] = nil end
    end
    if not ready() then return end
    local budget = PER_TICK
    for i, w in ipairs(DATA.walls) do
        if budget <= 0 then break end
        local up = enabled and not (isOpen(DATA.areas[w[5] + 1], passes) and isOpen(DATA.areas[w[6] + 1], passes))
        if up and not raised[i] then
            local ok, err = pcall(raise, i, context)
            if not ok then log("could not raise wall " .. i .. ": " .. tostring(err)); return end
            budget = budget - 1
        elseif not up and raised[i] then
            lower(i)
            budget = budget - 1
        end
    end
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

-- Switches every wall to the next look; returns its name (or why not).
function W.nextLook()
    look = look % #LOOKS + 1
    local name, path = LOOKS[look][1], LOOKS[look][2]
    pcall(LoadAsset, path)
    local m = StaticFindObject(path .. "." .. path:match("([^/]+)$"))
    if not m or not m:IsValid() then return name .. ": not found in this game build" end
    lookMaterial = m
    W.keep(m)
    local n = 0
    for _, a in pairs(raised) do
        if a:IsValid() then dress(a); n = n + 1 end
    end
    return look .. "/" .. #LOOKS .. " " .. name .. " (" .. n .. " walls)"
end

-- The world map with locked areas greyed out: the map texture drawn into a render target with a grey wash over every
-- locked area's cells, shown in the map screen's map image (the exploration fog is a separate layer above it).
-- Redrawn when the set of locked areas changes.
local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
local RT_SIZE = 4096
local mapRT, mapKey, mapShownOn = nil, nil, nil
local function drawMap(ctx, passes)
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    pcall(LoadAsset, "/Game/Pal/Texture/UI/Map/T_WorldMap")
    local tex = StaticFindObject(MAP_TEXTURE)
    if not tex or not tex:IsValid() then return false end
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(ctx, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)  -- RTF_RGBA8_SRGB
        if not mapRT or not mapRT:IsValid() then return false end
        W.keep(mapRT)
    end
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(ctx, mapRT, canvasOut, contextOut, extra)
    local canvas = canvasOut.Canvas
    if not canvas then return false end
    canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
        { R = 1, G = 1, B = 1, A = 1 }, 0, 0, { X = 0.5, Y = 0.5 })
    local cell = RT_SIZE / MAP.size
    local grey = { R = 0.42, G = 0.42, B = 0.45, A = 0.72 }
    for r = 0, MAP.size - 1 do
        local col = 0
        for a, n in MAP.rows[r + 1]:gmatch("(%d+),(%d+)") do
            a, n = tonumber(a), tonumber(n)
            if not isOpen(DATA.areas[a + 1], passes) then
                canvas:K2_DrawTexture(nil, { X = col * cell, Y = r * cell }, { X = n * cell, Y = cell },
                    { X = 0, Y = 0 }, { X = 1, Y = 1 }, grey, 2, 0, { X = 0.5, Y = 0.5 })      -- BLEND_Translucent
            end
            col = col + n
        end
    end
    krl:EndDrawCanvasToRenderTarget(ctx, contextOut.RenderTarget and contextOut or extra)
    return true
end
function W.updateMap(enabled, passes, ctx)
    if not enabled then return end
    -- The game keeps a template of the map screen beside the real ones; only a real one has its map image. There may be
    -- more than one real one (different menus), and a map screen sets its own picture again when it opens, so every
    -- one is checked each time and given the greyed map whenever it shows anything else.
    local images = {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function() local i = b.Image_MapBody; return i:IsValid() and i or nil end)
        if b:IsValid() and ok and img then images[#images + 1] = img end
    end
    if #images == 0 then return end
    local locked = {}
    for _, name in ipairs(DATA.areas) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    local key = table.concat(locked, "|")
    local redrawn = false
    if key ~= mapKey then
        local ok, done = pcall(drawMap, ctx, passes)
        if not ok then log("map overlay error: " .. tostring(done)); mapKey = key; return end
        if not done then return end
        mapKey, redrawn = key, true
        log("map: " .. #locked .. " locked area(s) greyed")
    end
    local want = tostring(mapRT:GetAddress())
    for _, image in ipairs(images) do
        local okr, shown = pcall(function()
            local res = image.Brush.ResourceObject
            return res and res:IsValid() and res or nil
        end)
        local current = okr and shown and tostring(shown:GetAddress()) or nil
        if redrawn or current ~= want then
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
    local n = 0
    for _ in pairs(raised) do n = n + 1 end
    return n, #DATA.walls
end

return W
