-- Which seed and slot each world save is played in (worlds.txt, beside the save files), so a game started without a
-- connection still knows the loaded world's seed and can queue shop purchases for it (CONNECTION.knowSeedOffline).
-- Kept in step by save.lua: every save written with a world= line names its world here.
-- An index file, not a look through the save files: Lua cannot list a folder, and a shell command to list it would
-- flash a console window over the game on Windows.
-- Tests: mod/test/tests/core.lua, mod/test/tests/goals.lua; groups "loading the mod", "connect and receive",
--   "the save file" (tools/lua_harness.sh, in CI).
local WORLD_SEEDS = {}
local UTIL = require("util")
local log, once = UTIL.log, UTIL.once

-- What save.lua hands over (WORLD_SEEDS.install).
--   dir     the mod's folder, where worlds.txt is
local env

-- Takes what save.lua hands over.
function WORLD_SEEDS.install(handedOver)
    env = handedOver
end

-- worlds.txt holds one line per world, sorted by world folder, its three fields separated by a tab:
--   <world folder>	<seed>	<slot name>
-- The slot name is as the player typed it (save.lua's file name replaces some of its characters). A world played with
-- another seed later has its line replaced: the seed played there last is the one an offline start takes.
local function indexPath()
    return env.dir .. "\\worlds.txt"
end

-- The index as a table: world folder -> { seed =, slot = }. Empty when there is no file yet.
local function readIndex()
    local worlds = {}
    local f = io.open(indexPath(), "r")
    if not f then return worlds end
    for line in f:lines() do
        local world, seed, slot = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
        if world then
            worlds[world] = { seed = seed, slot = slot }
        end
    end
    f:close()
    return worlds
end

-- The index's text: one line per world, sorted by world folder.
local function indexText(worlds)
    local folders = {}
    for world in pairs(worlds) do
        folders[#folders + 1] = world
    end
    table.sort(folders)
    local lines = {}
    for _, world in ipairs(folders) do
        lines[#lines + 1] = world .. "\t" .. worlds[world].seed .. "\t" .. worlds[world].slot .. "\n"
    end
    return table.concat(lines)
end

local lastRemembered = nil    -- state: the line remembered last (written or not), so a save written every cycle
                              -- reads no file
-- Notes that `world` is played with `seed` as `slot`, writing worlds.txt when that is new to it.
function WORLD_SEEDS.remember(world, seed, slot)
    local line = world .. "\t" .. seed .. "\t" .. slot
    if line == lastRemembered then return end
    if (world .. seed .. slot):find("[\t\n]") then
        once("worldseedtab", "worlds.txt: a tab or line break in world " .. world .. ", seed " .. seed .. " or slot "
            .. slot .. ": not kept, so this world's seed is not known when the game starts offline")
        return
    end
    lastRemembered = line
    local worlds = readIndex()
    local known = worlds[world]
    if known and known.seed == seed and known.slot == slot then return end
    worlds[world] = { seed = seed, slot = slot }
    local ok, step, why = UTIL.replaceFile(indexPath(), indexText(worlds))
    if not ok then
        once("worldseedwrite", "could not write " .. indexPath() .. " (" .. tostring(step) .. ": " .. tostring(why)
            .. "): this world's seed is not known when the game starts offline")
        return
    end
    log("worlds.txt: world " .. world .. " is played with seed " .. seed .. " as " .. slot)
end

-- The seed and slot `world` was last played with, read from worlds.txt; nil when it has none.
function WORLD_SEEDS.lookUp(world)
    local known = readIndex()[world]
    if not known then return nil end
    return known.seed, known.slot
end

return WORLD_SEEDS
