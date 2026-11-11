-- The walls and the map on fresh copies of walls.lua, driven directly: world changes, opening walls, the
-- Territories map across sessions, and the fallbacks. No core update runs here.

group("walls and the map, on fresh copies of walls.lua", function()
    local WD = shared.WD
    local function hiddenOf(walls)
        local n = 0
        for _, a in ipairs(walls) do if a.hidden then n = n + 1 end end
        return n
    end
    local SETTLE_UPDATES = 60          -- enough updates to raise every piece of a cut (30 an update) and hide it (120)
    -- A colour map saved by an earlier session, with its fingerprint of the game's map art `art`. Returns a function that
    -- puts back what was there before.
    local colourFile = MOD .. "\\map-colour-1.png"                  -- (the mod's Windows path, as a file name here)
    local function savedColourMap(art)
        local had = io.open(colourFile, "rb")
        if had then had:close() end
        local f = io.open(colourFile, "w"); f:write("png"); f:close()
        local print16 = {}
        for _ = 1, 16 do print16[#print16 + 1] = art .. ",90,60" end
        f = io.open(colourFile .. ".txt", "w"); f:write(table.concat(print16, ";")); f:close()
        return function()
            os.remove(colourFile .. ".txt")
            if not had then os.remove(colourFile) end
        end
    end

    do  -- Return to title and a new world: the new world's far pieces are hidden again (no hidden flag kept from before)
        local W, mine = h.freshWalls()
        W.radius = 7500
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local first = mine()
        local hidden1 = hiddenOf(first)
        h.wallsGo(first)
        W.reset()
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local second = mine()
        local hidden2 = hiddenOf(second)
        expect(#first > 100 and hidden1 == #first and #second == #first and hidden2 == #second,
               "a new world hides its far pieces again: " .. hidden1 .. " of " .. #first .. " hidden in the first world, "
               .. hidden2 .. " of " .. #second .. " in the second")
        W.perfMode("none")                                          -- Ctrl+7 "none" removes every piece, then "full"
        W.perfMode("full")
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local third = mine()
        expect(#third == #first and hiddenOf(third) == #third,
               "after the test state that removes every piece, the pieces raised again are hidden again: "
               .. hiddenOf(third) .. " of " .. #third)
        W.setLayout("regions")                                     -- the other cut: every piece taken down, others raised
        for _ = 1, 2 * SETTLE_UPDATES do W.update(true, {}, offMap) end
        local regions = mine()
        expect(#regions > #first and hiddenOf(regions) == #regions,
               "after a change of cut the new cut's far pieces are hidden: " .. hiddenOf(regions) .. " of " .. #regions)
        h.wallsGo(regions)
        end
    do  -- Walls opening when the pawn reads nil for a moment (same world) still open; when the world goes, none of its
        -- walls is called again (IsValid included), opening ones neither
        local W, mine = h.freshWalls()
        W.radius = 0
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local beside = {}                                         -- two areas next to the start
        for _, w in ipairs(WD.walls) do
            local a1, a2 = WD.areas[w[5] + 1], WD.areas[w[6] + 1]
            local other = (a1 == WD.start and a2) or (a2 == WD.start and a1)
            if other and other ~= "Open sea" and other ~= beside[1] then beside[#beside + 1] = other end
            if #beside == 2 then break end
        end
        local passes = { [beside[1]] = true }
        W.update(true, passes, offMap)                            -- a pass: its pieces begin to open
        local opening = {}
        for _, a in ipairs(mine()) do if a.shrunkTo then opening[#opening + 1] = a end end
        W.reset()                                                 -- the core: the pawn read nil, then came back
        for _ = 1, 20 do gameSeconds = gameSeconds + 0.3; W.update(true, passes, offMap) end
        local stillUp = 0
        for _, a in ipairs(opening) do if not a.gone then stillUp = stillUp + 1 end end
        expect(#opening > 0 and stillUp == 0,
               "a moment without a pawn: walls that were opening still go: " .. stillUp .. " of " .. #opening
               .. " still up")
        passes[beside[2]] = true
        W.update(true, passes, offMap)                            -- another pass: more pieces begin to open
        local calls, old, openingNow = 0, mine(), 0
        for _, a in ipairs(old) do
            if a.shrunkTo then openingNow = openingNow + 1 end
            local function dead() calls = calls + 1; return false end
            a.IsValid, a.SetActorScale3D, a.SetActorEnableCollision, a.K2_DestroyActor = dead, dead, dead, dead
            a.SetActorHiddenInGame = dead
        end
        h.wallsGo(old)
        W.reset()                                                 -- the core, on the new world's pawn
        for _ = 1, 3 do gameSeconds = gameSeconds + 0.3; W.update(true, passes, offMap) end
        expect(openingNow > 0 and calls == 0,
               "after a world change no wall of the world that went is called: " .. calls .. " calls on " .. #old
               .. " old walls, " .. openingNow .. " of them opening")
        h.wallsGo(mine())
    end
    do  -- The locked-area icons on the map: a moment without a pawn (same world, same screen) adds none twice; a new
        -- world's screen gets new ones, and the last world's are forgotten without a call (IsValid included)
        mapBody.icons, mapBody.iconUpdates = {}, 0
        local W = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        game.mapOpen = true
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        local placed = #mapBody.icons
        W.reset()
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        expect(placed >= 10 and #mapBody.icons == placed,
               "a moment without a pawn: the map icons stay, none added twice: " .. #mapBody.icons .. " for " .. placed)
        local old, deadCalls = mapBody.icons, 0
        for _, icon in ipairs(old) do
            icon.IsValid = function() deadCalls = deadCalls + 1; return false end
            icon.GetParent = function() deadCalls = deadCalls + 1; return nil end
            icon.RemoveFromParent = function() deadCalls = deadCalls + 1 end
        end
        mapBody.icons = {}
        local screenAddress = mapBody.GetAddress
        mapBody.GetAddress = function() return 177 end            -- the new world's map screen
        W.reset()
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        expect(deadCalls == 0 and #mapBody.icons == placed,
               "a new world: its map screen gets the icons and the last world's are never called: " .. deadCalls
               .. " calls on " .. #old .. " old icons, " .. #mapBody.icons .. " new")
        mapBody.GetAddress, mapBody.icons, game.mapOpen = screenAddress, {}, false
    end
    do  -- Ten passes in one session: no map overlay is kept (it is drawn into the map picture and done with), and the fog
        -- pictures keep one place among the kept objects, not one more each
        local calls = {}
        local takeAway = plugInTerritories(calls)
        local putBack = savedColourMap(game.mapArt)
        local W = h.freshWalls()
        local core = require("walls")                        -- (the core gave its keepAlive and keepInPlace to this one)
        W.keepAlive, W.keepInPlace = core.keepAlive, core.keepInPlace
        local function keptOf(path)
            local n = 0
            for _, obj in pairs(kept) do if type(obj) == "table" and obj.path == path then n = n + 1 end end
            return n
        end
        local overlays0, fogs0 = keptOf("map-territories"), keptOf("map-fog-territories")
        game.mapOpen = true
        local passes = {}
        for _ = 1, 45 do W.updateMap(true, passes, pawn) end
        local fogsFirst = keptOf("map-fog-territories") - fogs0
        local made = fieldJobs or 0
        for n = 3, 12 do                                           -- ten passes, one at a time
            passes[WD.areas[n]] = true
            for _ = 1, 8 do W.updateMap(true, passes, pawn) end
        end
        local overlays, fogs = keptOf("map-territories") - overlays0, keptOf("map-fog-territories") - fogs0
        expect(fogsFirst == 1 and (fieldJobs or 0) - made >= 10 and overlays == 0 and fogs == 1,
               "ten passes make the map ten times, and keep no overlay and one fog picture: " .. overlays
               .. " overlay(s) and " .. fogs .. " fog picture(s) kept after " .. ((fieldJobs or 0) - made)
               .. " pictures made")
        game.mapOpen = false
        takeAway()
        putBack()
    end
    do  -- The Territories look, as the chart look above: a map mod (or a game update) changed the game's map art since the
        -- colour map was saved; at the first opening it is saved again and the picture made again from it
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        local artBefore = game.mapArt
        game.mapArt = game.mapArt + 7
        local W = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 5 do W.updateMap(true, {}, pawn) end
        local made = fieldJobs or 0
        game.mapOpen = true
        for _ = 1, 10 do W.updateMap(true, {}, pawn) end
        local f = io.open(colourFile .. ".txt", "rb")
        local savedPrint = f and f:read("*a") or ""
        if f then f:close() end
        local madeAgain = (fieldJobs or 0) - made
        expect(savedPrint:find("^" .. game.mapArt .. ",90,60;") and madeAgain > 0,
               "Territories: a changed map art found at the first opening: the colour map is saved again and the picture "
               .. "made again: saved print " .. savedPrint:sub(1, 12) .. ".., " .. madeAgain .. " made again")
        game.mapArt, game.mapOpen = artBefore, false
        takeAway()
        putBack()
    end
    do  -- The map screen stays listed from its first opening until Return to title: an opening is the screen coming on
        -- screen, so each later opening reads the explored mask again (the fog picture follows what the player explored)
        local calls = {}
        local takeAway = plugInTerritories(calls)
        local putBack = savedColourMap(game.mapArt)
        local maskExports = 0
        local realExport = renderLib.ExportRenderTarget
        renderLib.ExportRenderTarget = function(lib, gi, rt, dir, name)
            if name == "fog-mask.png" then maskExports = maskExports + 1 end
            return realExport(lib, gi, rt, dir, name)
        end
        local onScreen = true
        mapBody.IsVisible = function() return onScreen end
        local W = h.freshWalls()
        game.mapOpen = true                                            -- the first opening: the screen is built
        for _ = 1, 10 do W.updateMap(true, {}, pawn) end
        local first = maskExports
        for _ = 1, 3 do                                           -- closed for 3 minutes of exploring, opened again
            onScreen = false
            for _ = 1, 600 do W.updateMap(true, {}, pawn) end
            onScreen = true
            for _ = 1, 10 do W.updateMap(true, {}, pawn) end
        end
        expect(first == 1 and maskExports == first + 3,
               "the explored mask is read again at each later opening of the same map screen: " .. first
               .. " by the first opening, " .. maskExports .. " after three more")
        local statuses, callsBefore = 0, #calls
        local W2 = h.freshWalls()
        for _ = 1, 2 do W2.updateMap(true, {}, pawn) end         -- the map on screen as the world goes
        W2.reset()
        for _ = 1, 2 do W2.updateMap(true, {}, pawn) end         -- the next world's map, opened at once
        for i = callsBefore + 1, #calls do if calls[i]:find("^status=") then statuses = statuses + 1 end end
        expect(statuses == 2, "a map on screen in the first update of a new world is an opening too: C++'s status"
               .. " logged at " .. statuses .. " of 2 openings")
        renderLib.ExportRenderTarget, mapBody.IsVisible, game.mapOpen = realExport, nil, false
        takeAway()
        putBack()
    end
    do  -- A seed with area locks, then one without in the same session: C++ is told to leave the map screen alone, once,
        -- and switched on again with the picture when area locks are back
        local calls = {}
        local takeAway = plugInTerritories(calls)
        local putBack = savedColourMap(game.mapArt)
        local W = h.freshWalls()
        for _ = 1, 6 do W.updateMap(true, {}, pawn) end
        local n = #calls
        for _ = 1, 6 do W.updateMap(false, {}, pawn) end
        local after = table.concat(calls, " | ", n + 1)
        for _ = 1, 6 do W.updateMap(true, {}, pawn) end
        local again = table.concat(calls, " | ", n + 1)
        local onAgain = again:find("enable=0 | enable=1", 1, true) and again:find("body=", 1, true)
        expect(n >= 2 and after == "enable=0" and onAgain,
               "with area locks off C++ is told once to leave the map screen alone, and on again after: " .. again)
        takeAway()
        putBack()
    end
    do  -- Walls that cannot be made are reported: a spawn that gives no actor (logged once, and no more spawns tried in
        -- that update), and a wall class that cannot be found (a game update renamed it)
        local tries = 0
        local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
        gameplay.BeginDeferredActorSpawnFromClass = function()
            tries = tries + 1
            return { IsValid = function() return false end }
        end
        local W = h.freshWalls()
        for _ = 1, 20 do W.update(true, {}, offMap) end
        gameplay.BeginDeferredActorSpawnFromClass = realSpawn
        expect(logged("could not raise wall %d+: the spawn gave no actor") and tries == 20,
               "a spawn that gives no actor is logged, and only one is tried an update: " .. tries .. " in 20 updates")
        local realFind = StaticFindObject
        StaticFindObject = function(path)
            if path:find("BP_PalBlockingVolume", 1, true) then return nil end
            return realFind(path)
        end
        local W2, mine = h.freshWalls()
        for _ = 1, 40 do W2.update(true, {}, offMap) end
        StaticFindObject = realFind
        expect(#mine() == 0 and logged("area locks: no walls: the wall class .*BP_PalBlockingVolume_C was not found"),
               "a wall class that cannot be found is logged")
    end
    do  -- A finished picture that errors while it is drawn (here the engine gives no canvas) is not composed again on
        -- every update: the key is marked failed, for both looks
        local realBegin = renderLib.BeginDrawCanvasToRenderTarget
        renderLib.BeginDrawCanvasToRenderTarget = function(_, _, _, _, contextOut) contextOut.RenderTarget = true end
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        local made = fieldJobs or 0
        local W = h.freshWalls()
        for _ = 1, 12 do W.updateMap(true, {}, pawn) end
        local territoriesMade = (fieldJobs or 0) - made
        takeAway()
        putBack()
        local jobs = #composeJobs
        local W2 = h.freshWalls()
        W2.mapStyle = "chart"
        for _ = 1, 12 do W2.updateMap(true, {}, pawn) end
        local chartMade = #composeJobs - jobs
        renderLib.BeginDrawCanvasToRenderTarget = realBegin
        expect(territoriesMade == 1 and chartMade == 1 and logged("map territories: could not draw the picture")
               and logged("map: could not draw the composed map"),
               "a picture that cannot be drawn is composed once, not again each update: Territories "
               .. territoriesMade .. "x, chart " .. chartMade .. "x in 12 updates")
    end
    do  -- Territories with the saved colour map, the map never opened: the game's 8192 px map is never loaded
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        local wasLoaded = loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"]
        loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = nil
        local made = fieldJobs or 0
        local W = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 6 do W.updateMap(true, {}, pawn) end
        expect((fieldJobs or 0) > made and not loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"],
               "Territories from the saved colour map: the picture is made without loading the game's map")
        loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = wasLoaded
        takeAway()
        putBack()
    end
    do  -- The second world of a session: its explored mask is read from its map data before its map opens, as the
        -- first world's was
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        local reads = 0
        local realExport = renderLib.ExportRenderTarget
        renderLib.ExportRenderTarget = function(lib, gi, rt, dir, name)
            if name == "fog-mask.png" then reads = reads + 1 end
            return realExport(lib, gi, rt, dir, name)
        end
        util.GetLocalWorldMapData = function() return { IsValid = function() return true end,
            GetRenderTargetByMapName = function() return { IsValid = function() return true end } end } end
        local W = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 45 do W.updateMap(true, {}, pawn) end
        local first = reads
        W.reset()                                                 -- Return to title, another world loaded
        for _ = 1, 45 do W.updateMap(true, {}, pawn) end
        expect(first == 1 and reads == 2, "the second world's explored mask is read before its map opens too: " .. first
               .. " read(s) in the first world, " .. (reads - first) .. " in the second")
        util.GetLocalWorldMapData, renderLib.ExportRenderTarget = nil, realExport
        takeAway()
        putBack()
    end
    do  -- One piece whose spawn raises an error holds up no other piece, and the rest of the update still runs
        local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
        local first, firstAt                                      -- the first piece that stands with no pass held
        for k, w in ipairs(WD.walls) do
            local function open(a) local nm = WD.areas[a + 1]; return nm == "Open sea" or nm == WD.start end
            if not first and not (open(w[5]) and open(w[6])) then first, firstAt = w, k end
        end
        gameplay.BeginDeferredActorSpawnFromClass = function(self, ctx, cls, t, ...)
            if t.Translation.X == first[1] and t.Translation.Y == first[2] then error("spawn failed for this piece") end
            return realSpawn(self, ctx, cls, t, ...)
        end
        local W, mine = h.freshWalls()
        W.radius = 7500
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        gameplay.BeginDeferredActorSpawnFromClass = realSpawn
        local up = mine()
        expect(#up >= 800 and hiddenOf(up) == #up and logged("could not raise wall " .. firstAt .. ": .*spawn failed"),
               "a piece whose spawn errors is logged and the others go up and are hidden as usual: " .. #up .. " up, "
               .. hiddenOf(up) .. " hidden")
        h.wallsGo(up)
    end
    do  -- One explored-mask reading that tells nothing apart does not switch the fog picture off for the session: a later
        -- opening reads it again
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        local apart = AP_SamplePNG
        AP_SamplePNG = function() return "0,0,0,40" end           -- the player and the world's edge read the same
        local onScreen = true
        mapBody.IsVisible = function() return onScreen end
        local W = h.freshWalls()
        game.mapOpen = true
        for _ = 1, 10 do W.updateMap(true, {}, pawn) end
        local fogsBefore = fogJobs or 0
        AP_SamplePNG = apart
        onScreen = false
        for _ = 1, 210 do W.updateMap(true, {}, pawn) end         -- a minute and more with the map closed
        onScreen = true
        for _ = 1, 10 do W.updateMap(true, {}, pawn) end
        expect(logged("read again at a later opening") and (fogJobs or 0) > fogsBefore,
               "a mask reading that tells nothing apart is tried again at a later opening, and the fog picture made")
        mapBody.IsVisible, game.mapOpen = nil, false
        takeAway()
        putBack()
    end
    do  -- Walls that are opening when the cut of the map changes, or when the opening step errors, are taken down, not
        -- left standing in no list
        local function openingAfterAPass(W, mine)
            for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
            W.update(true, { [WD.areas[4]] = true }, offMap)
            local list = {}
            for _, a in ipairs(mine()) do if a.shrunkTo then list[#list + 1] = a end end
            return list
        end
        local function standing(list)
            local n = 0
            for _, a in ipairs(list) do if not a.gone then n = n + 1 end end
            return n
        end
        local W, mine = h.freshWalls()
        local opening = openingAfterAPass(W, mine)
        W.setLayout("regions")
        local afterCut = standing(opening)
        h.wallsGo(mine())
        local W2, mine2 = h.freshWalls()
        local opening2 = openingAfterAPass(W2, mine2)
        opening2[1].IsValid = function() error("the opening step errors") end
        W2.update(true, { [WD.areas[4]] = true }, offMap)
        local afterError = standing(opening2) - 1                 -- (the piece that errors cannot be taken down)
        expect(logged("walls: the opening step failed %(.*the opening step errors%); %d+ opening piece%(s%) taken down"),
               "an error in the opening step is logged with how many opening pieces were taken down")
        expect(#opening > 0 and afterCut == 0 and #opening2 > 1 and afterError == 0,
               "opening walls are taken down at a change of cut (" .. afterCut .. " of " .. #opening .. " left) and after an"
               .. " error in the opening step (" .. afterError .. " of " .. (#opening2 - 1) .. " left)")
        h.wallsGo(mine2())
    end
    do  -- The game's template of the map screen (no map image, no player) is not taken for a screen of the last world
        local asked = 0
        local realFAO = FindAllOf
        FindAllOf = function(class)
            local list = realFAO(class)
            if class == "WBP_Map_Body_C" and list and list[1] and list[1] ~= mapBody then
                list[1].GetOwningPlayer = function() asked = asked + 1; return nil end
            end
            return list
        end
        local W = h.freshWalls()
        game.mapOpen = true
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        FindAllOf, game.mapOpen = realFAO, false
        expect(asked == 0, "the map screen's template is not asked for its player: asked " .. asked .. "x")
    end
    do  -- The chart look's parchment fog colour is sent only with the test tools, and never with map_chart=0
        local function fogSent(testTools, chartOff)
            local calls = {}
            recordMapScreen(calls)
            local W = h.freshWalls()
            W.mapStyle, W.testFogColour, W.chartOff = "chart", testTools, chartOff
            W.updateMap(true, {}, pawn)
            AP_MapScreen = nil
            for _, c in ipairs(calls) do if c:find("^fog=") then return c end end
        end
        local plain, tools, toolsNoChart = fogSent(false, false), fogSent(true, false), fogSent(true, true)
        expect(plain == "fog=" and tools == "fog=0.815,0.693,0.434,0.6" and toolsNoChart == "fog=",
               "the parchment fog colour only with test_tools=1 and the chart fog on: " .. tostring(plain) .. ", "
               .. tostring(tools) .. ", " .. tostring(toolsNoChart))
    end
    do  -- The chart look with its stamps drawn in (map_icons=0): while nothing changes, the map update opens no file
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        AP_ComposeChart = function(_, _, _, _, out) local h = io.open(out, "w"); h:write("png"); h:close(); return "" end
        for _ = 1, 3 do AP_ComposeStatus() end                    -- (an earlier copy's composition, finished)
        local W = h.freshWalls()
        W.mapStyle, W.iconsOff = "chart", true
        game.mapOpen = true
        for _ = 1, 30 do W.updateMap(true, {}, pawn) end         -- the chart, the first fog picture
        local opens, realOpen = 0, io.open
        io.open = function(...) opens = opens + 1; return realOpen(...) end
        for _ = 1, 20 do W.updateMap(true, {}, pawn) end
        io.open = realOpen
        expect(opens == 0, "the chart look's idle map update opens no file: " .. opens .. " opens in 20 updates")
        game.mapOpen = false
        os.remove(MOD .. "/map-chart.png"); os.remove(MOD .. "/map-fog.png")
        takeAway()
        putBack()
    end
    do  -- A wall piece that cannot be dressed in a skin is logged with the error, not counted as "without a mesh"
        local W, mine = h.freshWalls()
        W.radius = 0
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local up = mine()
        up[1].Cube.SetMaterial = function() error("the material was refused") end
        W.setSkin("a")
        W.update(true, {}, offMap)
        local realSpawn = gameplay.BeginDeferredActorSpawnFromClass
        gameplay.BeginDeferredActorSpawnFromClass = function(...)
            local a = realSpawn(...)
            a.Cube.SetMaterial = function() error("a new piece's material was refused") end
            return a
        end
        up[2]:K2_DestroyActor()                                   -- (gone: the update raises a new piece in its place)
        for _ = 1, 20 do W.update(true, {}, offMap) end           -- (a gone piece is noticed within 14 updates)
        gameplay.BeginDeferredActorSpawnFromClass = realSpawn
        expect(logged("wall skin a: on %d+ pieces, 1 not dressed %(the first error: .*the material was refused%)")
               and logged("wall skin a: could not dress a new piece: .*a new piece's material was refused"),
               "a piece that cannot be dressed is logged with its error, at a skin change and when it is raised")
        h.wallsGo(mine())
    end
    do  -- With two live main-map screens (two menus), each gets the locked-area icons
        local second = { IsValid = function() return true end, GetAddress = function() return 88 end, icons = {},
                         MapName = FNameOf("MainMap"),
                         Image_MapBody = { IsValid = function() return true end, Brush = {} } }
        function second.Image_MapBody:SetBrushResourceObject(rt) self.Brush.ResourceObject = rt end
        second["Add Icon By Location"] = mapBody["Add Icon By Location"]
        second["Update Map Icons"] = function() end
        second.Canvas_ForIcon_NoMask = mapBody.Canvas_ForIcon_NoMask
        second.Canvas_ForIcon_Mask = mapBody.Canvas_ForIcon_Mask
        local realFAO = FindAllOf
        FindAllOf = function(class)
            local list = realFAO(class)
            if class == "WBP_Map_Body_C" and list then list[#list + 1] = second end
            return list
        end
        mapBody.icons = {}
        local W = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        game.mapOpen = true
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        local first, other = #mapBody.icons, #second.icons
        for _ = 1, 3 do W.updateMap(true, {}, pawn) end
        expect(first >= 10 and other == first and #mapBody.icons == first and #second.icons == other,
               "two live main-map screens each get the icons, once: " .. first .. " and " .. other)
        FindAllOf, game.mapOpen, mapBody.icons = realFAO, false, {}
    end
    do  -- A fallback that is taken says so once: a wall's mesh found the second way, an opening piece without the game's
        -- clock, the explored mask from the world map data's current render target
        local W, mine = h.freshWalls()
        W.radius = 0
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        local odd = mine()[1]
        local mesh = odd.Cube
        odd.Cube = nil
        odd.GetComponentByClass = function() return mesh end
        W.setSkin("a")
        W.update(true, {}, offMap)
        local realClock = gameplay.GetTimeSeconds
        gameplay.GetTimeSeconds = function() error("no clock") end
        for _ = 1, 3 do W.update(true, { [WD.areas[4]] = true }, offMap) end
        gameplay.GetTimeSeconds = realClock
        W.setSkin("red")
        W.update(true, {}, offMap)
        h.wallsGo(mine())
        local takeAway = plugInTerritories({})
        local putBack = savedColourMap(game.mapArt)
        util.GetLocalWorldMapData = function() return { IsValid = function() return true end,
            GetRenderTargetByMapName = function() return nil end,
            GetCurrentRenderTarget = function() return { IsValid = function() return true end } end } end
        local M = h.freshWalls()
        game.mapOpen = false
        for _ = 1, 45 do M.updateMap(true, {}, pawn) end
        util.GetLocalWorldMapData = nil
        takeAway()
        putBack()
        expect(logged("wall skins: a wall's mesh: found by GetComponentByClass")
               and logged("walls: an opening piece's start: 0 s %(the game's clock could not be read%)")
               and logged("walls: an opening piece's clock: the updates counted")
               and logged("map chart: the explored mask: from GetCurrentRenderTarget"),
               "fallbacks taken are logged once: the mesh, the opening clock, the explored mask")
    end
    do  -- A skin that cannot be made yet names what is missing
        local W, mine = h.freshWalls()
        local realFind = StaticFindObject
        StaticFindObject = function(path)
            if path:find("KismetMaterialLibrary", 1, true) then return nil end
            return realFind(path)
        end
        for _ = 1, 3 do W.update(true, {}, offMap) end
        W.setSkin("b")
        W.update(true, {}, offMap)
        StaticFindObject = realFind
        expect(logged("wall skin b: no KismetMaterialLibrary yet; tried again later"),
               "a skin that cannot be made yet names what is missing")
        h.wallsGo(mine())
    end
    do  -- The Ctrl+7 "none" test state forgets what every piece wore, as a change of cut does: a later skin change by area
        -- lists only the colours of pieces that are up
        local hadPak = game.logicMod
        game.logicMod = true
        local W, mine = h.freshWalls()
        W.setSkin("area")
        for _ = 1, SETTLE_UPDATES do W.update(true, {}, offMap) end
        W.perfMode("none")
        local since = #printed
        W.setSkin("paws")
        W.update(false, {}, offMap)                               -- (area locks off: nothing raised again yet)
        local stale = false
        for i = since + 1, #printed do
            if printed[i]:find("wall skin paws: colours %S") then stale = true end
        end
        expect(not stale, "after the test state that removes every piece, no piece is still listed as wearing a colour")
        game.logicMod = hadPak
        h.wallsGo(mine())
    end
end)
