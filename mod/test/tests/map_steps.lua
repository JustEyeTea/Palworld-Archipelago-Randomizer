-- The map update's own steps: icons only on a screen that is on screen, a fog picture made out of date while it was
-- made (not loaded, made again), and a long map update logged with each step's time. Tests map_picture.lua,
-- map_fog.lua and map_icons.lua on fresh copies of walls.lua.

-- A screen listed but not on screen (closed) gets no icons; on screen it gets them, and the log says why.
local function iconsOnlyOnScreen()
    local calls = {}
    recordMapScreen(calls)
    mapBody.icons, mapBody.iconUpdates = {}, 0
    local W1 = h.freshWalls()
    mapBody.IsVisible = function() return false end
    game.mapOpen = true
    for _ = 1, 3 do
        W1.updateMap(true, {}, pawn)
    end
    expect(#mapBody.icons == 0, "a map screen listed but not on screen (closed) gets no icons")
    local mark = logMark()
    mapBody.IsVisible = function() return true end
    W1.updateMap(true, {}, pawn)
    expect(#mapBody.icons > 0 and loggedSince(mark, "map icons: %d+ locked area%(s%) added.*; a new screen"),
           "on screen, it gets them, and the log says why: a new screen")
    mark = logMark()
    mapBody.icons[1].parent = { IsValid = function() return false end }
    W1.updateMap(true, {}, pawn)
    expect(loggedSince(mark, "map icons: .*; the game dropped them"), "icons the game dropped are added again, said so")
    mapBody.IsVisible, game.mapOpen, AP_MapScreen = nil, false, nil
end

-- The fog pictures handed to C++ so far (AP_MapScreen "fogpic" calls).
local function fogPicsIn(calls)
    local n = 0
    for _, c in ipairs(calls) do
        if c:find("^fogpic=") then
            n = n + 1
        end
    end
    return n
end

-- A fog picture whose look changed while it was made (a pass arrived: the Territories picture made again) is not
-- loaded; the next is started at once, and that one is loaded.
local function outdatedFogSkipped()
    local calls = {}
    local unplug = plugInTerritories(calls)
    local fogBusy = true
    AP_FogStatus = function() return fogBusy and "busy" or "done" end
    local AW = require("region_walls")
    local F = h.freshWalls()
    F.beyond, F.visited = {}, {}
    game.mapOpen = true
    for _ = 1, 4 do            -- the map opens: the mask is read and a fog picture started, still being made
        F.updateMap(true, {}, pawn)
    end
    local started = fogJobs
    for _ = 1, 3 do            -- a pass arrives meanwhile: the Territories picture (and its fog art) made again
        F.updateMap(true, { [AW.locks[4]] = true }, pawn)
    end
    local mark, pics = logMark(), fogPicsIn(calls)
    fogBusy = false
    F.updateMap(true, { [AW.locks[4]] = true }, pawn)
    expect(started > 0 and fogPicsIn(calls) == pics and fogJobs == started + 1
           and loggedSince(mark, "a fog picture not loaded, what it shows changed while it was made; made again %(1 this"
                           .. " session %(the first 3 are logged%)%)"),
           "a fog picture made out of date while it was made is not loaded, and the next is started at once")
    F.updateMap(true, { [AW.locks[4]] = true }, pawn)
    expect(fogPicsIn(calls) == pics + 1 and fogJobs == started + 1, "that next one is loaded")
    game.mapOpen = false
    unplug()
end

-- A map update over 40 ms is logged with its steps and what the map was doing; a quick one is not.
local function longUpdateLogged()
    local F = h.freshWalls()
    local mark = logMark()
    game.mapOpen = false
    F.updateMap(true, {}, pawn)
    expect(not loggedSince(mark, "map: a long update"), "a quick map update is not logged")
    local realClock = os.clock
    local fake = realClock()
    os.clock = function()           -- (each reading 30 ms after the last: every step looks slow)
        fake = fake + 0.03
        return fake
    end
    local ok, err = pcall(F.updateMap, true, {}, pawn)
    os.clock = realClock
    expect(ok and loggedSince(mark, "map: a long update, %d+ ms at the map closed: screens %d+, fog %d+, picture %d+"
                              .. ".*%(1 this session; the first 10 are logged%)"),
           "a long one is logged with each step's time and the moment: " .. tostring(err))
end

group("the map's steps: icons on screen only, an outdated fog picture, long updates", function()
    iconsOnlyOnScreen()
    outdatedFogSkipped()
    longUpdateLogged()
end)
