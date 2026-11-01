-- Area locks: the game's own blocking wall (BP_PalBlockingVolume, the red energy grid beside the World Tree gate),
-- stretched into pieces along every border between areas (area_walls.lua, from tools/area_walls.py). A piece stays up
-- while either area it separates is locked; an Area Pass opens its area. Open sea is never locked, so an area that
-- is locked is ringed from the sea as well.
local DATA = require("area_walls")

local W = {}
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end

local WALL = "/Game/Pal/Blueprint/System/Volume/BP_PalBlockingVolume.BP_PalBlockingVolume_C"
local START = "Starting Zone"
local SEA = "Open sea"
local HEIGHT = 300000         -- 3 km of wall: from 1 km below sea level to 2 km above
local MID_Z = 50000
local THICK = 4               -- 4 m, so nothing fast slips through
local PER_TICK = 30           -- pieces raised or taken down per update, to spread the work

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
    return true
end

local function lower(i)
    local a = raised[i]
    raised[i] = nil
    if a and a:IsValid() then pcall(function() a:K2_DestroyActor() end) end
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

function W.count()
    local n = 0
    for _ in pairs(raised) do n = n + 1 end
    return n, #DATA.walls
end

return W
