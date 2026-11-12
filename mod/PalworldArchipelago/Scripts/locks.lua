-- The locks of the map and whether each is open: the seed's cut of the map (its walls, names and grid), which lock a
-- spot is in, the locks beyond the goal, and the lists of locked and open locks the walls and the map draw from. A part
-- of walls.lua, which loads it (fresh for each copy of walls.lua) and hands it W, the table main.lua sees, by install.
-- Tests: mod/test/tests/walls.lua, mod/test/tests/map.lua; groups "area locks", "the world map"
--   (tools/lua_harness.sh, in CI).
local LOCKS = {}
local W = nil                 -- walls.lua's public table (install): settings and data main.lua sets there
local SEA = "Open sea"

-- Two cuts, named as the seed's Lock Size (W.setLayout): "regions", the 15 regions (Region Passes, the region_*.lua
-- files), and "areas", the game's 75 named areas (Area Passes, the area_*.lua files). A lock is a locked part of the
-- cut in use, a region or an area. The 15 regions' cut is loaded at start.
-- The seed's cut of the map, as data. Its fields change when the seed's Lock Size arrives (W.setLayout), so they are
-- read through this table, never kept elsewhere: walls (the border pieces, *_walls.lua), locks (the locks' names by
-- index), start (the starting lock), map (*_map.lua: which lock each spot of the map is in), bounds (the map's xMin,
-- xMax, yMin, yMax in world units), centres (*_centres.lua, by lock index: deepU, deepV its deepest point, stampU,
-- stampV its stamp's place on the map square, room how far that is from the edge), shapes (*_shapes.lua, loaded when
-- first needed: only for a map drawn without the compositor) and prefix (of the cut's file names).
-- Forgotten: layout and decoded are made again at a change of cut (useLayoutData); beyondNames when the set beyond the
-- goal arrives; regionOfArea never (a data file, the same for every seed).
local layout = {}
local regionOfArea = nil                                       -- area -> its region (areas cut only; loaded once)
local beyondNames = ""         -- the locks beyond the goal, sorted and joined: changes when the set does (setBeyond)
local decoded = {}             -- map row -> its runs, decoded when first used (lockIndexAt)
local function useLayoutData(name)
    local prefix = name == "areas" and "area_" or "region_"    -- each cut's files: region_walls.lua, area_walls.lua
    local walls = require(prefix .. "walls")
    layout.prefix, layout.walls, layout.locks, layout.start = prefix, walls.walls, walls.locks, walls.start
    layout.map, layout.shapes = require(prefix .. "map"), nil
    layout.bounds = layout.map.bounds
    layout.centres = require(prefix .. "centres")    -- rows by name, as tools/lock_centres.py writes them (see above)
    decoded = {}
end

-- The item that opens a lock: a Region Pass for one of the 15 regions, an Area Pass for one of the 75 areas.
function LOCKS.passName(lock)
    return (W.layout == "areas" and "Area Pass: " or "Region Pass: ") .. lock
end

-- Open sea is never locked, so a lock is ringed from the sea as well.
local function isOpen(lock, passes)
    return lock == SEA or lock == layout.start or passes[lock] == true
end

-- Whether a wall piece (a row of *_walls.lua) stands: while either lock it separates is locked.
local function standing(wall, passes)
    return not (isOpen(layout.locks[wall.lockA + 1], passes) and isOpen(layout.locks[wall.lockB + 1], passes))
end

-- Which lock a spot is in (nil off the main map: the World Tree's own map). The map's rows are decoded when first used.
local function lockIndexAt(r, c)
    if r < 0 or c < 0 or r >= layout.map.size or c >= layout.map.size then return nil end
    local runs = decoded[r]
    if not runs then
        runs = {}
        for k, n in layout.map.rows[r + 1]:gmatch("(%d+),(%d+)") do
            runs[#runs + 1] = { lock = tonumber(k), count = tonumber(n) }   -- (a run: count cells of one lock)
        end
        decoded[r] = runs
    end
    local col = 0
    for _, run in ipairs(runs) do
        col = col + run.count
        if c < col then return run.lock end
    end
end
-- The map grid's cell at a world spot: rows run north to south (world X falling), columns west to east (world Y
-- rising); the grid is square, so one cell size serves both.
local function cellOf(x, y)
    local x0, x1, y0, y1 = layout.bounds.xMin, layout.bounds.xMax, layout.bounds.yMin, layout.bounds.yMax
    local size = (x1 - x0) / layout.map.size
    return math.floor((x1 - x) / size), math.floor((y - y0) / size)
end
function LOCKS.lockAt(x, y)
    local k = lockIndexAt(cellOf(x, y))
    return k and layout.locks[k + 1]
end

-- The lock a player stands well inside (every cell around them in it) while it is locked, or nil. Near a border, the
-- player is given the benefit of the doubt: the walls are there.
function LOCKS.lockedAround(x, y, passes)
    local r, c = cellOf(x, y)
    local here = lockIndexAt(r, c)
    if not here then return nil end
    local name = layout.locks[here + 1]
    if isOpen(name, passes) then return nil end
    for dr = -1, 1 do
        for dc = -1, 1 do
            if lockIndexAt(r + dr, c + dc) ~= here then return nil end
        end
    end
    return name
end

-- Each region's colour (its pass ticket's); an area wears its region's (regionOf).
local REGION_COLOURS = {
    ["Bamboo Groves"] = "8CCB3A", ["Sea Breeze Archipelago"] = "3FC1D9", ["Isles of Silence"] = "A3ADC9",
    ["Marsh Island"] = "8F9B4A", ["Crescent Moon Shore"] = "7A6FE0", ["Volcano Foothills"] = "F08A3C",
    ["Mount Obsidian"] = "D2453F", ["Verdant Stream"] = "2FB3A0", ["Desiccated Dunes"] = "E3B860",
    ["Astral Mountains"] = "A8E0F0", ["Sakurajima"] = "F28FB5", ["Feybreak"] = "B266D9",
    ["Sky Islands"] = "5B9BF0", ["World Tree"] = "2E8B57",
}
-- The region (one of the 15) a lock belongs to: an area's region, or with the regions' cut the region itself.
function LOCKS.regionOf(lock)
    if W.layout ~= "areas" then return lock end
    regionOfArea = regionOfArea or require("area_regions")
    return regionOfArea[lock] or lock
end
-- Locks beyond the seed's goal (a set of names; main.lua at connect): their walls wear the sealed look.
function LOCKS.setBeyond(set)
    W.beyond = set or {}
    local names = {}
    for name in pairs(W.beyond) do names[#names + 1] = name end
    table.sort(names)
    beyondNames = table.concat(names, "|")
end

local function slugOf(name) return (name:lower():gsub("[^%w]+", "-")) end
local function lockedList(passes)
    local out = {}
    for k, name in ipairs(layout.locks) do
        if not isOpen(name, passes) then out[#out + 1] = k - 1 end
    end
    return out
end
local function lockedIndexes(passes)
    local out = {}
    for k, name in ipairs(layout.locks) do
        if not isOpen(name, passes) then out[#out + 1] = tostring(k - 1) end
    end
    return table.concat(out, ",")
end
-- Unlocked locks not stood in yet (W.visited, main.lua's set of locks stood in, kept in its save), by index.
local function openList(passes)
    local out = {}
    for k, name in ipairs(layout.locks) do
        local waiting = passes[name] and not W.beyond[name] and not W.visited[name]
        if name ~= SEA and name ~= layout.start and waiting then
            out[#out + 1] = k - 1
        end
    end
    return out
end

-- Hands over walls.lua's public table, and loads the 15 regions' cut, the one in use until the seed says otherwise.
function LOCKS.install(walls)
    W = walls
    W.beyond, W.visited = {}, {}
    W.REGION_COLOURS = REGION_COLOURS                                -- (for the harness's colour tests)
    useLayoutData("regions")
end

-- The project's other colours, as sRGB "RRGGBB"; the walls and the map turn them into what they draw with.
LOCKS.PALETTE = {
    teal = "24E0CC",        -- the AP teal: the pattern skins, and the start island (its map colour, its paws)
    wallSealed = "9AA3B5",  -- slate grey: the walls of a lock beyond the goal
    mapSealed = "5A6472",   -- the map's colour of a lock beyond the goal
    noColour = "9AA3B5",    -- the map's colour of a lock with no colour of its own
    fog = "0E1A24",         -- the Territories fog over the unexplored map
}
LOCKS.layout, LOCKS.SEA, LOCKS.REGION_COLOURS = layout, SEA, REGION_COLOURS
LOCKS.useLayoutData, LOCKS.isOpen, LOCKS.slugOf, LOCKS.standing = useLayoutData, isOpen, slugOf, standing
LOCKS.lockedList, LOCKS.lockedIndexes, LOCKS.openList = lockedList, lockedIndexes, openList
-- The locks beyond the goal as one text, for the keys that must change when they do.
function LOCKS.beyondSig()
    return beyondNames
end
return LOCKS
