-- Helpers more than one test group uses, in one table, h. A helper that only one group needs stays in that group.
-- They drive the stand-ins (fakes.lua) and read the log through the kit (harness.lua).
h = {}

-- The path of the mod's save file for a seed and slot (seed 12345 and slot Tester if none are given).
function h.saveFile(seed, slot)
    return MOD .. "/save-" .. (seed or "12345") .. "-" .. (slot or "Tester") .. ".txt"
end

-- The save file of a seed and slot (12345 and Tester if none are given), as text.
function h.saveText(seed, slot)
    return io.open(h.saveFile(seed, slot)):read("*a")
end

-- Whether any notice shown in chat so far holds the text.
function h.told(text)
    return table.concat(announced, "|"):find(text, 1, true) ~= nil
end

-- Runs one update at a time until a line matching the pattern is logged, at most `max` updates (400 if none).
-- Returns how many updates it took, or nil.
function h.updatesUntil(pattern, max)
    for n = 1, max or 400 do
        run(1)
        if logged(pattern) then return n end
    end
end

-- As updatesUntil, for a line already logged earlier: until it is logged once more.
function h.updatesUntilAgain(pattern, max)
    local before = countLogged(pattern)
    for n = 1, max or 400 do
        run(1)
        if countLogged(pattern) > before then return n end
    end
end

-- The connection drops and comes back, as slot `slot`. The server then sends every item again: h.replayItems().
function h.reconnect(slot)
    push("status", "disconnected")
    push("status", "connected", slot)
end

-- The server sends every item of the run again, as it does on every connection.
function h.replayItems()
    for _, line in ipairs(itemHistory) do
        events[#events + 1] = line
    end
end

-- Quitting and starting again: the mod's state for seed 12345 comes back from its save file only (another seed is
-- connected in between, which forgets everything), and the server sends every item again.
function h.reload()
    slotData.seed = "99999"
    push("status", "connected", "Tester")
    run(1)
    slotData.seed = "12345"
    push("status", "connected", "Tester")
    h.replayItems()
    run(1)
end

-- Connects to another seed as slot Other, and says yes to playing it in this world (the world already has progress).
-- Its slot data is the first seed's (SLOT_DATA_START) with `changes`: no option of an earlier seed is kept.
function h.switchSeed(seed, changes)
    slotData = {}
    for k, v in pairs(SLOT_DATA_START) do
        slotData[k] = v
    end
    for k, v in pairs(changes) do
        slotData[k] = v
    end
    slotData.seed = seed
    nextItemIndex = 0
    push("status", "connected", "Other")
    run(14)
    keyBinds[Key.H]()
    run(14)
end

-- The techs the player has researched now, as a set of names.
function h.unlockedTechs()
    local have = {}
    unlocked:ForEach(function(_, e) have[e:get():ToString()] = true end)
    return have
end

-- A value as UE4SS hands a hook its parameters: an object whose get() returns it.
function h.param(v)
    return { get = function() return v end }
end

-- The world went: these walls (every one standing, if none are given) went with it. The game destroyed them; nothing
-- destroyed them through the mod.
function h.wallsGo(walls)
    if not walls then
        walls = {}
        for a in pairs(wallsUp) do
            walls[#walls + 1] = a
        end
    end
    for _, a in ipairs(walls) do
        a.gone = true
        wallsUp[a] = nil
    end
end

-- A world loads again (after Return to title): the last one's walls are gone, and the player has a new pawn. `dir`
-- is the world's save folder, if it is another world.
function h.loadWorld(dir)
    if dir then
        game.worldDir = dir
    end
    newPawn()
    h.wallsGo()
end

-- A click on a game's WBP_CommonButton_C, as the game calls the hook on its click (if the mod hooked it).
function h.clickCommonButton(button)
    if hooks[GAME_PATH.commonClick] then
        hooks[GAME_PATH.commonClick](h.param(button))
    end
end

-- The player closes the chest window shown last.
function h.closeChestWindow()
    hudWindows["chest" .. #chestWindowsShown].gone = true
end

-- Closes the chest window shown last, as the player does: one update while it is open (followed first), then closed.
function h.closeChest()
    run(1)
    h.closeChestWindow()
    run(2)
end

-- A click on the Esc menu's button (the mailbox's), as the game calls the hook on its click.
function h.clickEscButton(button)
    hooks[GAME_PATH.escClick](h.param(button))
end

-- A walls module of its own (a fresh copy of walls.lua), driven directly: no core update runs it. Also returns
-- mine(), which lists the walls it raised: those standing now that were not standing when it was made.
function h.freshWalls()
    local walls = dofile(MOD .. "/Scripts/walls.lua")
    walls.dir, walls.keepAlive = MOD, function() end
    local before = {}
    for a in pairs(wallsUp) do
        before[a] = true
    end
    local function mine()
        local out = {}
        for a in pairs(wallsUp) do
            if not before[a] then
                out[#out + 1] = a
            end
        end
        return out
    end
    return walls, mine
end

-- Whether two linear colours (R, G, B) are the same, to the precision the mod writes them.
local COLOUR_PRECISION = 1e-3
function h.sameColour(c, d)
    return c and d and math.abs(c.R - d.R) < COLOUR_PRECISION and math.abs(c.G - d.G) < COLOUR_PRECISION
        and math.abs(c.B - d.B) < COLOUR_PRECISION
end

-- A row of a generated walls file (region_walls.lua, area_walls_regions.lua), by name: its middle (x, y, game units),
-- its length, its yaw (degrees, along the wall), and the names of the areas on its two sides. `data` is the file's
-- table (shared.WD if none is given).
function h.wallRow(w, data)
    data = data or shared.WD
    return { x = w[1], y = w[2], length = w[3], yaw = w[4], areaA = data.areas[w[5] + 1], areaB = data.areas[w[6] + 1] }
end

-- The area on the other side of a wall from the start, or nil if the wall does not touch the start.
function h.otherSideOfStart(row)
    local start = shared.WD.start
    return (row.areaA == start and row.areaB) or (row.areaB == start and row.areaA) or nil
end

local SPOT_FROM_WALL = 1500                              -- game units: close enough for the wall's notice
local LONG_WALL = 5000                                   -- game units: a spot beside its middle is beside it alone
-- A spot on the start's side of a long wall between the start and an area `wanted(area, row)` accepts (the first
-- such wall in the file). Returns the spot (a location), the area, and the wall's row as the file has it.
function h.spotBesideStart(wanted)
    local start, liveWalls = shared.WD.start, require("walls")
    for _, w in ipairs(shared.WD.walls) do
        local row = h.wallRow(w)
        local other = h.otherSideOfStart(row)
        if other and row.length > LONG_WALL and wanted(other, row) then
            local yaw, spot = math.rad(row.yaw), nil
            for _, side in ipairs({ 1, -1 }) do
                local x = row.x - side * math.sin(yaw) * SPOT_FROM_WALL
                local y = row.y + side * math.cos(yaw) * SPOT_FROM_WALL
                if liveWalls.areaAt(x, y) == start then
                    spot = { X = x, Y = y, Z = 0 }
                end
            end
            if spot then return spot, other, w end
        end
    end
end
