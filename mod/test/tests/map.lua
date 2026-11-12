-- The world map: the picture composed before the map opens, the fog of war, the locked areas' stamps and icons,
-- and the Territories look. Tests walls.lua's map part, map_picture.lua, map_fog.lua, map_icons.lua.

group("the world map", function()
    -- Composed only once the map opened, the first opening would show the game's map for ~3 s.
    local jobs0 = #composeJobs
    expect(jobs0 >= 1 and composeJobs[jobs0].labels:find("region_labels.png")
           and composeJobs[jobs0].colour:find("map%-colour%-1.png"),
           "the picture is composed in the background, from the colour map and the region labels, before the map "
           .. "ever opens")
    game.mapOpen = true
    run(1)
    expect(mapBody.Image_MapBody.shown and mapBody.Image_MapBody.shown.rt,
           "so the first opening has the composed map at once")
    do  -- stamps at each region's deepest point sat under the fog of war, so they go on the side facing home
        local c = require("region_centres")[3]                        -- Sea Breeze Archipelago, still locked
        local at = stampAt["ap-map-stamp-sea-breeze-archipelago"]
        expect(at and c.stampU and math.abs(at.X - (c.stampU * 4096 - 44)) < 0.01
               and math.abs(at.Y - (c.stampV * 4096 - 44)) < 0.01 and (c.stampU ~= c.deepU or c.stampV ~= c.deepV),
               "a locked region's stamp goes on its side nearest the start, not its middle")
    end
    do  -- the full 88 px stamp buried a small area (Small Settlement), so a small one is drawn smaller
        local liveWalls = require("walls")
        expect(liveWalls.stampSize({}) == 88 and liveWalls.stampSize({ room = 120 }) == 88,
               "a lock with room (or data without the field) keeps the full 88 px stamp")
        expect(liveWalls.stampSize({ room = 30 }) == 60 and liveWalls.stampSize({ room = 9 }) == 28,
               "a small lock's stamp is about as wide as the lock, but at least 28 px")
        local small, tiny = 0, 0
        for _, c in pairs(dofile(MOD .. "/Scripts/area_centres.lua")) do
            expect(c.room, "every area's centre carries its room")
            if c.room and liveWalls.stampSize({ room = c.room }) < 88 then
                small = small + 1
            end
            if c.room and c.room < 14 then
                tiny = tiny + 1
            end
        end
        expect(small > 0 and tiny > 0, "the areas set has small areas that get a smaller stamp")
    end
    local lockedFirst = composeJobs[jobs0].locked
    expect(select(2, lockedFirst:gsub(",", "")) == 12 and not lockedFirst:find("^1,") and not lockedFirst:find(",2,"),
           "locked regions passed by index: " .. lockedFirst)
    pushItem({ name = "Region Pass: Marsh Island" })
    run(3)
    expect(#composeJobs == jobs0 + 1 and select(2, composeJobs[jobs0 + 1].locked:gsub(",", "")) == 11,
           "a pass recomposes with one fewer")
    run(3)
    expect(#composeJobs == jobs0 + 1, "and not again while nothing changes")
    local owned = true
    for _, o in ipairs(rtOwners) do
        if o ~= gameInstance then
            owned = false
        end
    end
    expect(owned and #rtOwners >= 2 and exports == 1,
           "render targets belong to the game instance; colour map saved once")
    mapBody.Image_MapBody.Brush.ResourceObject = gameMapPicture(9)
    run(1)
    expect(mapBody.Image_MapBody.Brush.ResourceObject.rt, "when the map screen puts its own picture back, ours returns")
    local TREE_MAP = "Texture2D /Game/Pal/Texture/UI/Map/T_TreeMap.T_TreeMap"      -- the World Tree's own map
    mapBody.Image_MapBody.Brush.ResourceObject = gameMapPicture(10, TREE_MAP)
    run(1)
    expect(not mapBody.Image_MapBody.Brush.ResourceObject.rt, "the World Tree's own map is left alone")
    -- A later session: the same map picture keeps the saved colour map; a mod that replaces the map art gets it saved
    -- again.
    local function nextSession()
        local W2 = h.freshWalls()
        for _ = 1, 3 do
            W2.updateMap(true, {}, pawn)
        end
    end
    nextSession()
    expect(exports == 1, "next session, same map picture: the saved colour map is reused")
    game.mapArt = 200
    nextSession()
    expect(exports == 2 and logged("map picture changed"),
           "a mod changed the map picture: the colour map is saved again")
    nextSession()
    expect(exports == 2, "and then reused")
    -- The compositor fails (its file locked): the map is drawn without it, not left on an old picture logged as
    -- current.
    game.composeFails = true
    mapBody.Image_MapBody.Brush.ResourceObject = gameMapPicture(11)
    local W3 = h.freshWalls()
    local drawn = greyBoxes
    for _ = 1, 4 do
        W3.updateMap(true, {}, pawn)
    end
    game.composeFails = false
    expect(logged("composing failed: error: could not write") and greyBoxes > drawn
           and mapBody.Image_MapBody.Brush.ResourceObject.rt,
           "a failed composition: the map is drawn without the compositor")
    -- The map screen from C++ (map_screen.cpp, AP_MapScreen): Lua hands it the picture (by path) and the fog colour,
    -- logs its status when the map opens, and probes the fog once (its material, the explored mask exported to
    -- fog-mask.png).
    do
        local calls = {}
        recordMapScreen(calls, "hooked; Setup ran 1x, picture set 1x, fog set 1x")
        local maskRT = { IsValid = function() return true end, SizeX = 1024, SizeY = 1024, RenderTargetFormat = 2,
                         GetFullName = function() return "TextureRenderTarget2D " ..
                                                         "/Engine/Transient.TextureRenderTarget2D_9" end }
        mapBody.MaskTextureMaterial = { IsValid = function() return true end,
            GetFullName = function() return "MaterialInstanceDynamic /Engine/Transient.MaterialInstanceDynamic_1" end,
            K2_GetTextureParameterValue = function(_, name)
                if name:ToString() == "TargetTexture" then return maskRT end
                if name:ToString() == "DefaultMaskTexture" then
                    return { IsValid = function() return true end, Blueprint_GetSizeX = function() return 512 end,
                             Blueprint_GetSizeY = function() return 512 end,
                             GetFullName = function()
                                 return "Texture2D /Game/Pal/Texture/UI/Map/T_MainWorld5_DefaultMask."
                                     .. "T_MainWorld5_DefaultMask"
                             end }
                end
            end }
        local W5 = h.freshWalls()
        local exportsBefore = exports
        for _ = 1, 4 do
            W5.updateMap(true, {}, pawn)
        end
        local callsText = table.concat(calls, " | ")
        expect(callsText:find("enable=1", 1, true), "C++ is switched on (config.txt has no map_cpp=0)")
        expect(callsText:find("fog= |", 1, true)
               and callsText:find("body=/Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3", 1, true),
               "C++ is told the fog colour (none: the game's own) and the picture's path (without its class): "
               .. callsText)
        expect(logged("map screen %(C%+%+%): hooked; Setup ran 1x")
               and logged("map fog: fog material .*MaterialInstanceDynamic_1; mask .*1024x1024.*exported to " ..
                          "fog%-mask%.png")
               and logged("default mask 512x512 exported to fog%-default%-mask%.png")
               and exports == exportsBefore + 2,
               "the map's opening logs C++'s status, and the fog is probed and both masks exported once")
        for _ = 1, 3 do
            W5.updateMap(true, {}, pawn)
        end
        local bodies = 0
        for _, c in ipairs(calls) do
            if c:find("^body=") then
                bodies = bodies + 1
            end
        end
        expect(bodies == 1 and exports == exportsBefore + 2,
               "told the picture once, not every update; the masks exported once")
        local statuses = 0
        for _, c in ipairs(calls) do
            if c:find("^status=") then
                statuses = statuses + 1
            end
        end
        expect(statuses == 1, "C++'s status is logged when the map opens, not every update: " .. statuses)
        AP_MapScreen, mapBody.MaskTextureMaterial = nil, nil
    end
    -- The explorer's-chart fog: the chart drawn once from the colour map with the chart art; when the map opens
    -- the explored mask is exported, read once at the player and beyond the world's edge (which channel, which way
    -- round), the fog picture made with the locked areas' stamps, loaded and handed to C++ for the next opening; a pass
    -- remakes it from the same mask with one stamp fewer.
    do
        local calls, jobs = {}, {}
        recordMapScreen(calls)
        AP_ComposeChart = function(colour, paper, sea, compass, out, size, gamma)
            jobs[#jobs + 1] = { kind = "chart", colour = colour, paper = paper, compass = compass, out = out,
                                size = size }
            local f = io.open(out, "w")
            f:write("chart")
            f:close()
            return ""
        end
        AP_ChartStatus = function() return "done" end
        AP_ComposeFog = function(chartFile, mask, def, spec, out, size, stamps, borders)
            jobs[#jobs + 1] = { kind = "fog", chart = chartFile, mask = mask, spec = spec, out = out, stamps = stamps,
                                borders = borders }
            local f = io.open(out, "w")
            f:write("fog")
            f:close()
            return ""
        end
        AP_FogStatus = function() return "done" end
        local sampled = {}
        AP_SamplePNG = function(path, u, v)
            sampled[#sampled + 1] = u .. "," .. v
            return u == "0.02" and "0,0,0,255" or "0,0,0,40"         -- explored where alpha is LOW (the made-up mask)
        end
        os.remove(MOD .. "/map-fog.png")
        mapBody.MaskTextureMaterial = maskMaterial("MaterialInstanceDynamic_2")
        local W6 = h.freshWalls()
        W6.iconsOff = true                                           -- (the stamps drawn on the fog: map_icons=0)
        game.mapOpen = false
        W6.updateMap(true, {}, pawn)                                 -- closed: the chart is drawn in the background
        W6.updateMap(true, {}, pawn)
        local chartJob = jobs[1]
        expect(chartJob and chartJob.kind == "chart" and chartJob.colour:find("map%-colour%-1%.png")
               and chartJob.paper:find("ap%-chart%-paper%.png")
               and chartJob.compass:find("ap%-chart%-compass%.png") and chartJob.size == "2048"
               and logged("map chart: drawn"),
               "the chart is drawn once from the saved colour map with the Art lane's paper, sea and compass")
        game.mapOpen = true
        for _ = 1, 4 do   -- the map opens
            W6.updateMap(true, {}, pawn)
        end
        local fog
        for _, j in ipairs(jobs) do
            if j.kind == "fog" then
                fog = fog or j
            end
        end
        expect(fog and fog.spec == "a-" and fog.mask:find("fog%-mask%.png") and logged("explored reads a%-"),
               "the mask is read at the player and beyond the edge: explored is alpha low here (a-)")
        -- The fog's borders argument, by name: image_tools.hpp, compose_fog.
        local BORDER_FIELDS = { "labels", "locked", "hatch", "ink", "width", "dash", "gap", "hatchOpacity", "colour",
                                "gamma" }
        local parts, borders = {}, {}
        for part in ((fog and fog.borders or "") .. "|"):gmatch("([^|]*)|") do
            parts[#parts + 1] = part
        end
        for i, name in ipairs(BORDER_FIELDS) do
            borders[name] = parts[i] or ""
        end
        expect(#parts == #BORDER_FIELDS and borders.labels:find("region_labels%.png$")
               and select(2, borders.locked:gsub(",", "")) >= 9,
               "the fog is made with the regions' borders, from the region labels, the locked regions listed: "
               .. tostring(fog and fog.borders))
        expect(borders.ink == "59,42,26,210" and tonumber(borders.width) == 3 and tonumber(borders.dash) == 14
               and tonumber(borders.gap) == 8,
               "the borders in the ink 59,42,26 at 210, 3 px wide, dashes 14 and gaps 8")
        expect(tonumber(borders.hatchOpacity) == 0.28 and borders.gamma == "0.4545",
               "the locked regions' hatch at 0.28, kept to land by the colour map read at gamma 0.4545")
        local stamps = select(2, (fog and fog.stamps or ""):gsub("ap%-map%-stamp", ""))
        expect(stamps >= 10 and (fog.stamps or ""):find("|88", 1, true), "the locked regions' stamps go on the fog: "
               .. stamps)
        local fogpic
        for _, c in ipairs(calls) do
            if c:find("^fogpic=") then
                fogpic = c
            end
        end
        expect(fogpic and fogpic:find("map%-fog", 1) and logged("the fog picture is ready"),
               "the fog picture is loaded and handed to C++ for the next opening: " .. tostring(fogpic))
        local fogs = 0
        for _, j in ipairs(jobs) do
            if j.kind == "fog" then
                fogs = fogs + 1
            end
        end
        for _ = 1, 10 do
            W6.updateMap(true, {}, pawn)
        end
        local again = 0
        for _, j in ipairs(jobs) do
            if j.kind == "fog" then
                again = again + 1
            end
        end
        expect(again == fogs, "while the map stays open nothing is remade")
        local open1 = {}
        for _, a in ipairs(require("region_walls").locks) do
            open1[a] = true
        end
        W6.updateMap(true, { [require("region_walls").locks[4]] = true }, pawn)
        W6.updateMap(true, { [require("region_walls").locks[4]] = true }, pawn)
        local last
        for _, j in ipairs(jobs) do
            if j.kind == "fog" then
                last = j
            end
        end
        local fewer = select(2, (last and last.stamps or ""):gsub("ap%-map%-stamp", ""))
        expect(last ~= fog and fewer == stamps - 1,
               "a pass remakes the fog from the same mask with one stamp fewer: " .. fewer)
        local function lockedIn(j) return select(2, ((j.borders or ""):match("^[^|]*|([^|]*)")
                                                     or ""):gsub(",", "")) + 1 end
        expect(lockedIn(last) == lockedIn(fog) - 1, "and its hatch over one locked region fewer")
        local nChart = 0
        for _, j in ipairs(jobs) do
            if j.kind == "chart" then
                nChart = nChart + 1
            end
        end
        expect(nChart == 1, "the chart itself is drawn once a session")
        AP_MapScreen, AP_ComposeChart, AP_ChartStatus, AP_ComposeFog, AP_FogStatus, AP_SamplePNG = nil, nil, nil, nil,
            nil, nil
        mapBody.MaskTextureMaterial = nil
    end
    game.mapOpen = false
    -- Started only once the map opened, the picture left the first opening on the game's map for ~3 s, with C++
    -- still off ("OFF; Setup ran 0x"). So before the map ever opens: C++ is switched on, the picture is composed from
    -- the colour map saved in an earlier session (the game's 8192 px map not loaded), and C++ is told its path; at the
    -- first opening the game's map is checked against the saved one once, and nothing is redone.
    do
        local calls = {}
        recordMapScreen(calls)
        local saved = MOD .. "\\map-colour-1.png"                    -- (the mod's Windows path, as a file name here)
        local f = io.open(saved, "w")
        f:write("png")
        f:close()
        local fp = {}
        for _ = 1, 16 do
            fp[#fp + 1] = game.mapArt .. ",90,60"
        end
        f = io.open(saved .. ".txt", "w")
        f:write(table.concat(fp, ";"))
        f:close()
        loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = nil
        local jobsBefore = #composeJobs
        local W7 = h.freshWalls()
        W7.updateMap(true, {}, pawn)
        local callsText = table.concat(calls, " | ")
        expect(callsText:find("enable=1", 1, true),
               "C++ is switched on at the first update, before any picture or map: " .. callsText)
        for _ = 1, 3 do
            W7.updateMap(true, {}, pawn)
        end
        callsText = table.concat(calls, " | ")
        local job = composeJobs[jobsBefore + 1]
        expect(job and job.colour == saved and not loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"],
               "the map closed: the picture is composed from the saved colour map, without loading the game's map")
        expect(callsText:find("body=/Engine/Transient.PalGameInstance_0:TextureRenderTarget2D_3", 1, true),
               "and C++ has the picture before the map first opens: " .. callsText)
        game.mapOpen = true
        for _ = 1, 3 do
            W7.updateMap(true, {}, pawn)
        end
        expect(loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] and #composeJobs == jobsBefore + 1,
               "at the first opening the game's map is checked against the saved one, and an unchanged map is not " ..
               "composed again")
        game.mapOpen = false
        game.mapArt = game.mapArt + 1 -- another session, another mod's map art
        local W8 = h.freshWalls()
        for _ = 1, 3 do
            W8.updateMap(true, {}, pawn)
        end
        local early = #composeJobs
        game.mapOpen = true
        for _ = 1, 4 do
            W8.updateMap(true, {}, pawn)
        end
        expect(#composeJobs == early + 1 and composeJobs[#composeJobs].colour == saved
               and logged("the game's map picture changed"),
               "a changed map art found at the first opening: the colour map is saved again and the picture made again")
        game.mapOpen, AP_MapScreen = false, nil
        game.mapArt = game.mapArt - 1
        os.remove(saved)
        os.remove(saved .. ".txt")
    end
    -- The locked regions as the map's own icons (stamps drawn into the picture grow with the zoom and sit in odd
    -- places): one WBP_WorldMap_IconBase_OnlyIcon per locked region, added with the screen's Add Icon By Location at
    -- the region's deepest point, ignoring the fog's mask, then Update Map Icons; nothing drawn into the picture.
    -- Only the main map's screen: the World Tree's keeps its own picture and gets none.
    do
        local calls = {}
        recordMapScreen(calls)
        mapBody.icons, mapBody.iconUpdates = {}, 0
        treeBody.icons, treeBody.Image_MapBody.shown = {}, nil
        local stampsBefore = {}
        for k, v in pairs(stampAt) do
            stampsBefore[k] = v
        end
        local W9 = h.freshWalls()
        for _ = 1, 3 do   -- the map not built yet: the picture is made, no icons
            W9.updateMap(true, {}, pawn)
        end
        expect(#mapBody.icons == 0, "no icons before the map screen exists")
        -- After Return to title and a second world load, the first world's screen can still be about (last in
        -- FindAllOf here); its player is gone, so it is left alone and the icons go on the live one.
        game.staleBody = { IsValid = function() return true end, GetAddress = function() return 79 end, icons = {},
                           MapName = FNameOf("MainMap"),
                      Image_MapBody = { IsValid = function() return true end },
                      GetOwningPlayer = function() return { IsValid = function() return false end } end }
        game.staleBody["Add Icon By Location"] = function(self, icon) self.icons[#self.icons + 1] = icon end
        game.staleBody["Update Map Icons"] = function() end
        game.mapOpen, game.treeOpen = true, true
        for _ = 1, 2 do
            W9.updateMap(true, {}, pawn)
        end
        local job = composeJobs[#composeJobs]
        local nLocked = job and select(2, job.locked:gsub(",", "")) + 1 or 0
        local CENTRES = require("region_centres")
        local first = mapBody.icons[1]
        local locked1 = job and tonumber(job.locked:match("^(%d+)"))
        local c = locked1 and CENTRES[locked1] -- (keyed by the 0-based lock index, as drawStamps)
        local at = c and W9.worldAt(c.deepU, c.deepV)
        expect(#mapBody.icons == nLocked and nLocked >= 10, "one icon per locked region: " .. #mapBody.icons .. " of "
               .. nLocked)
        expect(#game.staleBody.icons == 0 and logged("a map screen of the last world left alone"),
               "the last world's screen (its player gone) is left alone; the icons go on the live one")
        game.staleBody = nil
        expect(first and first.tex and tostring(first.tex.path):find("ap%-map%-stamp") and first.ignoreMask == true
               and first.priority == false and first.visibility == 3 and first.parent == mapBody.Canvas_ForIcon_NoMask,
               "each shows its region's stamp, on the canvas the fog never hides, and ignores the pointer")
        expect(at and first.loc and math.abs(first.loc.X - at.X) < 1 and math.abs(first.loc.Y - at.Y) < 1
               and first.loc.Z == 0,
               "at the region's deepest point, as a world location")
        expect(mapBody.iconUpdates == 1 and logged("map icons: " .. nLocked
                                                   .. " locked area%(s%) added on Canvas_ForIcon_NoMask"),
               "then the screen sizes them for its zoom, and the log says where they went")
        local drawnNow = 0
        for k, v in pairs(stampAt) do
            if stampsBefore[k] ~= v then
                drawnNow = drawnNow + 1
            end
        end
        expect(drawnNow == 0 and logged("locked areas are shown as map icons, not drawn on the picture"),
               "with the icons, no stamp is drawn into the picture")
        expect(#treeBody.icons == 0 and not treeBody.Image_MapBody.shown,
               "the World Tree's screen gets no icons and keeps its picture")
        for _ = 1, 4 do
            W9.updateMap(true, {}, pawn)
        end
        expect(#mapBody.icons == nLocked and mapBody.iconUpdates == 1, "added once, not every update")
        local region4 = require("region_walls").locks[4]
        for _ = 1, 3 do
            W9.updateMap(true, { [region4] = true }, pawn)
        end
        expect(first.removed and #mapBody.icons == 2 * nLocked and logged("1 open not yet visited"),
               "a pass: the old icons go; one locked stamp fewer comes back, and an open one where the pass is " ..
               "(art/ap-map-stamp-open-*)")
        -- An unlocked region not stood in yet: an open stamp there (art/ap-map-stamp-open, once the mod has it).
        local openArt = require("art").dir .. "\\art\\ap-map-stamp-open.png"   -- (where the mod looks for its art)
        local fa = io.open(openArt, "w")
        fa:write("png")
        fa:close()
        local count = #mapBody.icons
        local region5 = require("region_walls").locks[5]
        W9.visited = {}
        for _ = 1, 3 do   -- (a second pass: icons made again)
            W9.updateMap(true, { [region4] = true, [region5] = true }, pawn)
        end
        local newest = mapBody.icons[#mapBody.icons]
        expect(#mapBody.icons == count + nLocked and tostring(newest.tex.path):find("ap%-map%-stamp%-open")
               and logged("2 open not yet visited"),
               "unlocked regions not yet visited get an open stamp: " .. tostring(newest.tex.path))
        W9.visited[region4] = true
        count = #mapBody.icons
        local standing = logMark()
        for _ = 1, 3 do
            W9.updateMap(true, { [region4] = true, [region5] = true }, pawn)
        end
        expect(#mapBody.icons == count + nLocked - 1 and loggedSince(standing, "1 open not yet visited"),
               "once stood in, its open stamp goes")
        os.remove(openArt)
        -- The icons failing (here: the screen without the function): the stamps are drawn into the picture again.
        mapBody.icons = {}
        local add = mapBody["Add Icon By Location"]
        mapBody["Add Icon By Location"] = nil
        local W10 = h.freshWalls()
        local jobs = #composeJobs
        for _ = 1, 4 do
            W10.updateMap(true, {}, pawn)
        end
        expect(logged("map icons: could not add them") and #composeJobs > jobs
               and composeJobs[#composeJobs].locked ~= nil,
               "if the icons can't be added, the log says why and the picture is made again")
        for _ = 1, 3 do
            W10.updateMap(true, {}, pawn)
        end
        local drawnAgain = 0
        for k, v in pairs(stampAt) do
            if stampsBefore[k] ~= v then
                drawnAgain = drawnAgain + 1
            end
        end
        expect(drawnAgain > 0, "with the stamps drawn in, as before: " .. drawnAgain)
        mapBody["Add Icon By Location"] = add
        game.mapOpen, game.treeOpen, AP_MapScreen = false, false, nil
    end
end)

group("the world map: the Territories look", function()
    -- "Territories": the C++ part composes an overlay from each region's state and colour and the standing walls; the
    -- map picture is the game's own map with it drawn over; the fog picture is made from its fog art. Visiting a region
    -- makes it again; map_style=chart keeps the explorer's chart.
    local jobs, fogArt = {}, nil
    AP_ComposeTerritories = function(labels, areas, walls, style, out, fogart, fog, size)
        jobs[#jobs + 1] = { labels = labels, areas = areas, walls = walls, style = style, out = out, fogart = fogart,
                            fog = fog, size = size }
        for _, f in ipairs({ out, fogart }) do
            local h = io.open(f, "w")
            h:write("png")
            h:close()
        end
        return ""
    end
    AP_TerritoriesStatus = function() return "done" end
    local pics = {}
    AP_MapScreen = function(what, arg)
        if what == "fogpic" then
            pics[#pics + 1] = arg
        end
        return ""
    end
    local fogSize
    AP_ComposeFog = function(chartFile, _, _, _, out, size)
        fogArt, fogSize = chartFile, size
        writeFile(out, "png")
        return ""
    end
    AP_FogStatus = function() return "done" end
    AP_ComposeChart = function() error("Territories draws no chart") end
    AP_ChartStatus = function() return "done" end
    AP_SamplePNG = function(_, u) return u == "0.02" and "0,0,0,255" or "0,0,0,40" end
    mapBody.MaskTextureMaterial = maskMaterial("MaterialInstanceDynamic_3")
    local AW = require("region_walls")
    local region4, sealedRegion = AW.locks[4], AW.locks[16]
    local T = h.freshWalls()
    T.beyond = { [sealedRegion] = true }
    T.visited = {}
    local passes = { [region4] = true }
    local stale = io.open(MOD .. "/map-fog.png", "w")   -- (a chart fog left from a last session)
    stale:write("png")
    stale:close()
    os.remove(MOD .. "/map-fog-territories.png")
    game.mapOpen, drawLog = false, {}
    for _ = 1, 3 do
        T.updateMap(true, passes, pawn)
    end
    local job = jobs[#jobs]
    local st = {}
    for item in (job and job.areas or ""):gmatch("[^,]+") do
        local i, s, c = item:match("^(%d+):(%a):(%x+)$")
        st[tonumber(i)] = { s = s, c = c }
    end
    expect(job and job.labels:find("region_labels%.png$") and job.size == "2048" and job.fog == "0E1A24"
           and job.style == "FFE9B0,0.35,FFF4DC,0.6,10,3,5",
           "the overlay is composed from the region labels at 2048, with the dark fog colour and the Art lane's "
           .. "walls, see-through")
    expect(st[1] and st[1].s == "v" and st[1].c == "24E0CC",
           "states: the start visited, teal: " .. tostring(st[1] and st[1].s) .. " " .. tostring(st[1] and st[1].c))
    expect(st[3] and st[3].s == "u" and st[2] and st[2].s == "l",
           "a region with its pass unlocked and not yet visited; the rest locked")
    expect(st[15] and st[15].s == "s" and st[15].c == "5A6472" and st[0] == nil,
           "a region beyond the goal sealed, slate; the sea not listed")
    local standing = 0
    local function open(region) return region == "Open sea" or region == AW.start or passes[region] end
    for _, wall in ipairs(AW.walls) do
        local nameA, nameB = h.lockNamesOf(wall, AW)
        if not (open(nameA) and open(nameB)) then
            standing = standing + 1
        end
    end
    local segs, inside = 0, true
    for s in (job and job.walls or ""):gmatch("[^;]+") do
        segs = segs + 1
        for v in s:gmatch("[^,]+") do
            v = tonumber(v)
            if not v or v < -0.01 or v > 1.01 then
                inside = false
            end
        end
    end
    expect(segs == standing and segs > 100 and inside, "the standing walls only, as segments on the map square: "
           .. segs .. " of " .. #AW.walls)
    local overDrawn = false
    for i = 2, #drawLog do
        if tostring(drawLog[i - 1].path):find("T_WorldMap") and drawLog[i - 1].blend == 0
            and tostring(drawLog[i].path):find("map%-territories")
           and drawLog[i].blend == 2 then overDrawn = true end
    end
    expect(overDrawn and logged("map territories: drawn over the game's map"),
           "the map picture: the game's map, the overlay drawn over it")
    game.mapOpen = true
    for _ = 1, 4 do
        T.updateMap(true, passes, pawn)
    end
    expect(fogArt and fogArt:find("map%-territories%-fog%.png$"),
           "the fog picture is made from the territories' fog art: " .. tostring(fogArt))
    local chartPic = false
    for _, p in ipairs(pics) do
        if not tostring(p):find("territories") then
            chartPic = true
        end
    end
    expect(#pics > 0 and not chartPic and tostring(pics[#pics]):find("map%-fog%-territories"),
           "the territories' own fog picture, never the chart's from the last session: " .. table.concat(pics, " "))
    local n = #jobs
    T.visited[region4] = true
    for _ = 1, 3 do
        T.updateMap(true, passes, pawn)
    end
    expect(#jobs == n + 1 and jobs[#jobs].areas:find("3:v:", 1, true),
           "visiting a region makes the overlay again, the region visited")
    expect(fogSize == "2048" and logged("map territories: composing from the label map at 2048"),
           "an older DLL (no AP_ComposeField): the label map at 2048, the fog at 2048")
    game.mapOpen = false
    -- With the DLL's AP_ComposeField: from the shipped distance field at 4096, the fog at 4096.
    local fjobs = {}
    AP_ComposeField = function(field, areas, walls, style, out, fogart, fog, size, colour, gamma)
        fjobs[#fjobs + 1] = { field = field, areas = areas, walls = walls, style = style, size = size, colour = colour,
                              gamma = gamma }
        for _, f in ipairs({ out, fogart }) do
            local h = io.open(f, "w")
            h:write("png")
            h:close()
        end
        return ""
    end
    local colourFile = MOD .. "\\map-colour-1.png"                  -- (the mod's Windows path, as a file name here)
    local hadColour = io.open(colourFile, "rb")
    if hadColour then
        hadColour:close()
    end
    local cf = io.open(colourFile, "w")
    cf:write("png")
    cf:close()
    -- The explored mask from the player's world map data, so the fog picture is new before the map opens.
    local askedMap
    local mapData = { IsValid = function() return true end }
    function mapData.GetRenderTargetByMapName(_, name)
        askedMap = name:ToString()
        return { IsValid = function() return true end }
    end
    util.GetLocalWorldMapData = function() return mapData end
    local F = h.freshWalls()
    F.beyond, F.visited = { [sealedRegion] = true }, {}
    n = #jobs
    drawLog = {}
    local picsBefore = #pics
    for _ = 1, 3 do
        F.updateMap(true, passes, pawn)
    end
    local whole = #drawLog > 0
    for _, d in ipairs(drawLog) do
        if not (tostring(d.path):find("map%-territories") and d.blend == 0) then
            whole = false
        end
    end
    expect(fjobs[1] and fjobs[1].colour == colourFile and fjobs[1].gamma == "0.4545" and whole
           and logged("map, locked areas greyscale"),
           "with the saved colour map: the whole picture from it (locked regions greyscale), drawn alone, not over "
           .. "the game's map")
    for _ = 1, 25 do
        F.updateMap(true, passes, pawn)
    end
    local earlyPic = false
    for i = picsBefore + 1, #pics do
        if tostring(pics[i]):find("map%-fog%-territories") then
            earlyPic = true
        end
    end
    expect(askedMap == "MainMap" and earlyPic and logged("the explored mask read before the map opened"),
           "the map never opened: the explored mask read from the world's map data and the fog picture made and " ..
           "handed over")
    util.GetLocalWorldMapData = nil
    game.mapOpen = true
    for _ = 1, 4 do
        F.updateMap(true, passes, pawn)
    end
    local fj = fjobs[#fjobs]
    local shipped = io.open(MOD .. "/region_field.png", "rb")
    if shipped then
        shipped:close()
    end
    expect(shipped and fj and fj.field:find("region_field%.png$") and fj.size == "4096" and #jobs == n
           and logged("map territories: composing from the distance field at 4096"),
           "with AP_ComposeField: the shipped distance field at 4096, not the label map: " .. tostring(fj and fj.field))
    expect(fj and fj.style == job.style and fj.areas == job.areas and fj.walls == job.walls,
           "the same regions, walls and look as from the label map")
    expect(fogSize == "4096", "and the fog at 4096: " .. tostring(fogSize))
    -- No colour map (and no game map to save one from): the overlay, drawn over the game's map.
    os.remove(colourFile)
    local G2 = h.freshWalls()
    G2.beyond, G2.visited = { [sealedRegion] = true }, {}
    local savedLoad = loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"]
    game.mapOpen, drawLog = false, {}
    local nf = #fjobs
    for _ = 1, 3 do
        G2.updateMap(true, passes, pawn)
    end
    local overGame = false
    for i = 2, #drawLog do
        if tostring(drawLog[i - 1].path):find("T_WorldMap") and tostring(drawLog[i].path):find("map%-territories")
            and drawLog[i].blend == 2 then
            overGame = true
        end
    end
    expect(#fjobs > nf and (fjobs[#fjobs].colour == "" or fjobs[#fjobs].colour == colourFile)
           and (fjobs[#fjobs].colour ~= "" or overGame),
           "without a saved colour map: the overlay over the game's map (or the colour map saved from it first)")
    loaded["/Game/Pal/Texture/UI/Map/T_WorldMap"] = savedLoad
    if hadColour then
        cf = io.open(colourFile, "w")
        cf:write("png")
        cf:close()
    else
        os.remove(colourFile)
    end
    AP_ComposeField = nil
    game.mapOpen = false
    local C = h.freshWalls()
    C.mapStyle = "chart"
    n = #jobs
    for _ = 1, 3 do
        C.updateMap(true, {}, pawn)
    end
    expect(#jobs == n, "map_style=chart: no territories")
    AP_ComposeTerritories, AP_TerritoriesStatus, AP_MapScreen, AP_ComposeFog, AP_FogStatus = nil, nil, nil, nil, nil
    AP_ComposeChart, AP_ChartStatus, AP_SamplePNG = nil, nil, nil
    mapBody.MaskTextureMaterial = nil
    os.remove(MOD .. "/map-fog.png")
    os.remove(MOD .. "/map-fog-territories.png")
end)
