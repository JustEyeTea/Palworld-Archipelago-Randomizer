-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red energy grid beside the World Tree gate),
-- stretched into pieces along every border between areas (area_walls.lua, from tools/area_walls.py). A piece stays up
-- while either area it separates is locked; an Area Pass opens its area. Open sea is never locked, so an area that
-- is locked is ringed from the sea as well.
local DATA = require("area_walls")
local MAP = require("area_map")

local W = {}
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end

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

local function ready()
    if cls and cls:IsValid() and gs and gs:IsValid() then return true end
    pcall(LoadAsset, (WALL:gsub("_C$", "")))
    cls = StaticFindObject(WALL)
    gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return cls ~= nil and cls:IsValid() and gs ~= nil and gs:IsValid()
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
local sinking = {}            -- wall actor -> { x, y, step }
local sinkLoop = false
local function sinkStep()
    local busy = false
    for a, s in pairs(sinking) do
        if not a:IsValid() then
            sinking[a] = nil
        else
            s[3] = s[3] + 1
            local t = s[3] / SINK_STEPS
            local eased = t * t * (3 - 2 * t)            -- slow, fast, slow
            pcall(function() a:K2_SetActorLocation({ X = s[1], Y = s[2], Z = MID_Z - HEIGHT * eased }, false, {}, true) end)
            if s[3] >= SINK_STEPS then
                sinking[a] = nil
                pcall(function() a:K2_DestroyActor() end)
            else
                busy = true
            end
        end
    end
    return busy
end
local function lower(i)
    local a = raised[i]
    raised[i] = nil
    if not (a and a:IsValid()) then return end
    pcall(function() a:SetActorEnableCollision(false) end)
    local w = DATA.walls[i]
    sinking[a] = { w[1], w[2], 0 }
    if not sinkLoop then
        sinkLoop = true
        LoopAsync(33, function()
            local done = false
            ExecuteInGameThread(function()
                local ok, busy = pcall(sinkStep)
                if not ok or not busy then sinkLoop = false; done = true end
            end)
            return done
        end)
    end
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
    local n = 0
    for _, a in pairs(raised) do
        if a:IsValid() then dress(a); n = n + 1 end
    end
    return look .. "/" .. #LOOKS .. " " .. name .. " (" .. n .. " walls)"
end

function W.count()
    local n = 0
    for _ in pairs(raised) do n = n + 1 end
    return n, #DATA.walls
end

return W
