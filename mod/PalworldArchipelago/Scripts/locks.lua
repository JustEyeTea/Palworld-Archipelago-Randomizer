-- The areas of the map and whether each is open: the seed's cut of the map (its walls, names and grid), which area a
-- spot is in, the areas beyond the goal, and the lists of locked and open areas the walls and the map draw from. A part
-- of walls.lua, which loads it (fresh for each copy of walls.lua) and hands it W, the table main.lua sees, by install.
-- Tests: mod/test/tests/walls.lua, mod/test/tests/map.lua; groups "area locks", "the world map"
--   (tools/lua_harness.sh, in CI).
local AREAS = {}
local W = nil                 -- walls.lua's public table (install): settings and data main.lua sets there
local SEA = "Open sea"

-- Two cuts (the seed's Lock Size, W.setLayout). Players call the 15 parts regions (Region Passes) and the 75 areas
-- (Area Passes); the code uses the older words the other way round, until the code tour renames them: "areas" is the
-- 15 regions (area_walls.lua and the rest), "regions" the 75 areas (the same files with _regions). "Area" here means a
-- locked part of either cut. The 15 regions' cut is loaded at start.
-- The seed's cut of the map, as data. Its fields change when the seed's Lock Size arrives (W.setLayout), so they are
-- read through this table, never kept elsewhere: walls (the border pieces, area_walls*.lua), areas (the parts' names
-- by index), start (the starting part), map (area_map*.lua: which part each spot of the map is in), bounds (the map's
-- xMin, xMax, yMin, yMax in world units), centres (area_centres*.lua, by area index: deepU, deepV its deepest point,
-- stampU, stampV its stamp's place on the map square, room how far that is from the edge), shapes (area_shapes*.lua,
-- loaded when first needed: only for a map drawn without the compositor) and prefix (of the cut's file names).
-- Forgotten: layout and decoded are made again at a change of cut (useLayoutData); beyondNames when the set beyond the
-- goal arrives; parents never (a data file, the same for every seed).
local layout = {}
local parents = nil                                            -- region -> area (regions layout only; loaded once)
local beyondNames = ""         -- the areas beyond the goal, sorted and joined: changes when the set does (setBeyond)
local decoded = {}             -- map row -> its runs, decoded when first used (areaIndexAt)
local function useLayoutData(name)
    local prefix = name == "regions" and "area_" or "region_"  -- each cut's files: region_walls.lua, area_walls.lua
    local walls = require(prefix .. "walls")
    layout.prefix, layout.walls, layout.areas, layout.start = prefix, walls.walls, walls.locks, walls.start
    layout.map, layout.shapes = require(prefix .. "map"), nil
    local b = layout.map.bounds
    layout.bounds = { xMin = b[1], xMax = b[2], yMin = b[3], yMax = b[4] }
    layout.centres = {}
    for k, row in pairs(require(prefix .. "centres")) do
        layout.centres[k] = { deepU = row[1], deepV = row[2], stampU = row[3] or row[1], stampV = row[4] or row[2],
                              room = row[5] }
    end
    decoded = {}
end

-- The item that opens a locked part: a Region Pass for one of the 15 regions, an Area Pass for one of the 75 areas.
function AREAS.passName(area)
    return (W.layout == "regions" and "Area Pass: " or "Region Pass: ") .. area
end

-- Open sea is never locked, so a locked part is ringed from the sea as well.
local function isOpen(area, passes)
    return area == SEA or area == layout.start or passes[area] == true
end

-- Whether a wall row stands: while either area it separates is locked.
local function standing(row, passes)
    return not (isOpen(layout.areas[row[5] + 1], passes) and isOpen(layout.areas[row[6] + 1], passes))
end

-- Which area a spot is in (nil off the main map: the World Tree's own map). The map's rows are decoded when first used.
local function areaIndexAt(r, c)
    if r < 0 or c < 0 or r >= layout.map.size or c >= layout.map.size then return nil end
    local runs = decoded[r]
    if not runs then
        runs = {}
        for a, n in layout.map.rows[r + 1]:gmatch("(%d+),(%d+)") do
            runs[#runs + 1] = { area = tonumber(a), count = tonumber(n) }   -- (a run: count cells of one area)
        end
        decoded[r] = runs
    end
    local col = 0
    for _, run in ipairs(runs) do
        col = col + run.count
        if c < col then return run.area end
    end
end
-- The map grid's cell at a world spot: rows run north to south (world X falling), columns west to east (world Y
-- rising); the grid is square, so one cell size serves both.
local function cellOf(x, y)
    local x0, x1, y0, y1 = layout.bounds.xMin, layout.bounds.xMax, layout.bounds.yMin, layout.bounds.yMax
    local size = (x1 - x0) / layout.map.size
    return math.floor((x1 - x) / size), math.floor((y - y0) / size)
end
function AREAS.areaAt(x, y)
    local k = areaIndexAt(cellOf(x, y))
    return k and layout.areas[k + 1]
end

-- The locked area a player stands well inside (every cell around them in it), or nil. Near a border, the player is
-- given the benefit of the doubt: the walls are there.
function AREAS.lockedAround(x, y, passes)
    local r, c = cellOf(x, y)
    local here = areaIndexAt(r, c)
    if not here then return nil end
    local name = layout.areas[here + 1]
    if isOpen(name, passes) then return nil end
    for dr = -1, 1 do
        for dc = -1, 1 do
            if areaIndexAt(r + dr, c + dc) ~= here then return nil end
        end
    end
    return name
end

local AREA_COLOURS = {
    ["Bamboo Groves"] = "8CCB3A", ["Sea Breeze Archipelago"] = "3FC1D9", ["Isles of Silence"] = "A3ADC9",
    ["Marsh Island"] = "8F9B4A", ["Crescent Moon Shore"] = "7A6FE0", ["Volcano Foothills"] = "F08A3C",
    ["Mount Obsidian"] = "D2453F", ["Verdant Stream"] = "2FB3A0", ["Desiccated Dunes"] = "E3B860",
    ["Astral Mountains"] = "A8E0F0", ["Sakurajima"] = "F28FB5", ["Feybreak"] = "B266D9",
    ["Sky Islands"] = "5B9BF0", ["World Tree"] = "2E8B57",
}
-- The region (one of the 15) an area of the 75 belongs to; with the 15 regions' cut, the region itself.
function AREAS.parentOf(area)
    if W.layout ~= "regions" then return area end
    parents = parents or require("area_regions")
    return parents[area] or area
end
-- Areas beyond the seed's goal (a set of names; main.lua at connect): their walls wear the sealed look.
function AREAS.setBeyond(set)
    W.beyond = set or {}
    local names = {}
    for a in pairs(W.beyond) do names[#names + 1] = a end
    table.sort(names)
    beyondNames = table.concat(names, "|")
end

local function slugOf(name) return (name:lower():gsub("[^%w]+", "-")) end
local function lockedList(passes)
    local out = {}
    for k, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then out[#out + 1] = k - 1 end
    end
    return out
end
local function lockedIndexes(passes)
    local out = {}
    for k, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then out[#out + 1] = tostring(k - 1) end
    end
    return table.concat(out, ",")
end
-- Unlocked areas not stood in yet (W.visited, main.lua's set of areas stood in, kept in its save), by index.
local function openList(passes)
    local out = {}
    for k, name in ipairs(layout.areas) do
        local waiting = passes[name] and not W.beyond[name] and not W.visited[name]
        if name ~= SEA and name ~= layout.start and waiting then
            out[#out + 1] = k - 1
        end
    end
    return out
end

-- Hands over walls.lua's public table, and loads the 15 regions' cut, the one in use until the seed says otherwise.
function AREAS.install(walls)
    W = walls
    W.beyond, W.visited = {}, {}
    W.AREA_COLOURS = AREA_COLOURS                                    -- (for the harness's colour tests)
    useLayoutData("areas")
end

-- The project's other colours, as sRGB "RRGGBB"; the walls and the map turn them into what they draw with.
AREAS.PALETTE = {
    teal = "24E0CC",        -- the AP teal: the pattern skins, and the start island (its map colour, its paws)
    wallSealed = "9AA3B5",  -- slate grey: the walls of an area beyond the goal
    mapSealed = "5A6472",   -- the map's colour of an area beyond the goal
    noColour = "9AA3B5",    -- the map's colour of an area with no colour of its own
    fog = "0E1A24",         -- the Territories fog over the unexplored map
}
AREAS.layout, AREAS.SEA, AREAS.AREA_COLOURS = layout, SEA, AREA_COLOURS
AREAS.useLayoutData, AREAS.isOpen, AREAS.slugOf, AREAS.standing = useLayoutData, isOpen, slugOf, standing
AREAS.lockedList, AREAS.lockedIndexes, AREAS.openList = lockedList, lockedIndexes, openList
-- The areas beyond the goal as one text, for the keys that must change when they do.
function AREAS.beyondSig()
    return beyondNames
end
return AREAS
