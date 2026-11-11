-- The map screen from C++ and the fog: what C++ is told (switched on, the picture, the fog colour and picture),
-- when the map is on screen, the explored mask, the explorer's chart and the fog picture made from them. A part of
-- walls.lua (with map_picture.lua, which calls it each map update), loaded fresh for each copy of walls.lua.
-- Tests: mod/test/harness.lua, group "the world map".
local MAP_FOG = {}
local UTIL = require("util")
local ART = require("art")
local log = UTIL.log
local once = UTIL.onceIn("walls")
local owner = UTIL.gameInstance
-- Handed over by install: W (settings: dir, keepInPlace, cppOff, testFogColour, chartOff, regionsOff; data: beyond),
-- the areas part's layout and lists, the icons part's active and the picture part (target(), territories(), terr,
-- TERR_FOG, COLOUR_FILE, stampSize, drawInto, drawWhole).
local W, layout, slugOf, lockedList, lockedIndexes, iconsActive, picture = nil, nil, nil, nil, nil, nil, nil
local territories, terr, TERR_FOG, COLOUR_FILE, stampSize = nil, nil, nil, nil, nil
local GAMMA, RTF_RGBA8, BLEND_OPAQUE = nil, nil, nil
-- Files this part writes into the mod folder (the game's own art, made on the player's machine, never shipped):
--   CHART_FILE         the explorer's chart, drawn once a session from the colour map (the chart look)
--   FOG_FILE           the chart look's fog picture; TERR_FOG_FILE the Territories' (each look keeps its own)
--   MASK_FILE          the explored mask, exported for the fog composer and read here to learn its channel
--   DEFAULT_MASK_FILE  what every player sees uncovered, exported once a session for the fog composer
local CHART_FILE, FOG_FILE, TERR_FOG_FILE = "map-chart.png", "map-fog.png", "map-fog-territories.png"
local MASK_FILE, DEFAULT_MASK_FILE = "fog-mask.png", "fog-default-mask.png"
local LOG_FIRST = 3           -- openings and pictures put back that are logged; after that they are only counted
-- Which channel of the explored mask means explored: the mask sampled at the player and at EDGE_UV (map u and v, a
-- point beyond the world's edge, never explored); a channel tells them apart by at least MIN_CHANNEL_GAP (of 255).
local EDGE_UV = "0.02"
local MIN_CHANNEL_GAP = 64

local mapShownAt = 0           -- map screens on screen at the last update (an opening is one coming on screen)
function MAP_FOG.mapShown() return mapShownAt > 0 end
-- A new world: its map has not been on screen yet, so its first showing is an opening.
function MAP_FOG.resetMapShown() mapShownAt = 0 end
-- How many of the live map screens are on screen. A screen lasts from its first opening until Return to title, so
-- being listed is not being open. One whose visibility cannot be read counts as on screen. Untested in game: that
-- IsVisible reads false while the map is closed (if it reads true, an opening is seen once per world, as before).
local function screensOnScreen(screens)
    local n = 0
    for _, b in ipairs(screens) do
        local ok, visible = pcall(function() return b:IsVisible() end)
        if not ok or visible then
            n = n + 1
        end
    end
    return n
end

-- The map screen from C++ (APConnector's AP_MapScreen, map_screen.cpp; the user, 2026-11-06: Lua's swaps show, do the
-- map in C++). It changes the screen inside the game's own Setup, before the screen draws; Lua hands it the picture and
-- the fog's colour. Lua still puts the picture back as before when it finds the game's, but with C++ working it should
-- never have to: each time it does is counted and logged (the swap the player sees).
-- At the first opening of a session the fog's material and masks are logged, and its default mask (what every player
-- sees uncovered) is exported to fog-default-mask.png, which startFog hands the C++ fog composer.
-- The chart look's parchment fog colour (linear light, alpha 0.6, to see whether the colour's alpha lets the map show
-- through), sent only with the test tools (fogColour). Untested in game: how the screen shows it.
local CHART_FOG_COLOUR = "0.815,0.693,0.434,0.6"
-- What C++ was told: body is the picture's path (forgotten by W.mapOff, so it is told again), told whether it was
-- switched on and given the fog colour; opened and fixes count map openings and pictures Lua put back, for the log.
local cpp = { body = nil, told = false, opened = 0, fixes = 0, maskDone = false }
-- The fog colour C++ gives the screen until there is a fog picture: "" keeps the game's own dark fog.
-- CHART_FOG_COLOUR only with the test tools, in the chart look with its fog on; config.txt says map_chart=0 keeps the
-- game's fog.
local function fogColour()
    if W.testFogColour and not territories() and not W.chartOff then
        return CHART_FOG_COLOUR
    end
    return ""
end
local function tellCpp()
    if not AP_MapScreen then return end
    if not cpp.told then
        cpp.told = true
        AP_MapScreen("enable", W.cppOff and "0" or "1")
        AP_MapScreen("fog", fogColour())
    end
    if picture.target() and picture.target():IsValid() then
        local path = UTIL.objectPath(picture.target())
        if path ~= cpp.body then cpp.body = path; AP_MapScreen("body", path) end
    end
end
-- Switches the C++ map screen off where the mod's map does not belong (a seed without area locks, a world that is
-- not the seed's): C++ would otherwise show the seed's picture and fog there. Told once; tellCpp switches it on again.
function MAP_FOG.mapOff()
    if not (AP_MapScreen and cpp.told) then
        return
    end
    cpp.told, cpp.body = false, nil
    AP_MapScreen("enable", "0")
    log("map screen (C++): switched off, the game's own map here")
end
-- The fog's material and its two masks (the explored mask, a render target, and the default mask, a texture), as words
-- for the log, and the two masks; or the reason there is no fog material.
local function fogMasks(screen)
    local dmi = screen.MaskTextureMaterial
    if not (dmi and dmi:IsValid()) then return "no fog material" end
    local function tex(param)
        local ok, t = pcall(function() return dmi:K2_GetTextureParameterValue(FName(param)) end)
        return ok and t and t:IsValid() and t or nil
    end
    local rt, def = tex("TargetTexture"), tex("DefaultMaskTexture")
    local info = "fog material " .. dmi:GetFullName() .. "; mask " .. (rt and (rt:GetFullName() .. " " .. tostring(rt.SizeX)
        .. "x" .. tostring(rt.SizeY) .. " format " .. tostring(rt.RenderTargetFormat)) or "none")
        .. "; default mask " .. (def and def:GetFullName() or "none")
    return info, rt, def
end
-- The default mask exported to fog-default-mask.png: drawn into a render target of its size, then saved. The words
-- for the log.
local function exportDefaultMask(def, gi)
    local ok, err = pcall(function()
        local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        local w, h = def:Blueprint_GetSizeX(), def:Blueprint_GetSizeY()
        local drt = krl:CreateRenderTarget2D(gi, w, h, RTF_RGBA8, { R = 0, G = 0, B = 0, A = 0 }, false)
        picture.drawInto(krl, gi, drt, function(canvas) picture.drawWhole(canvas, def, w, h, BLEND_OPAQUE) end)
        krl:ExportRenderTarget(gi, drt, W.dir, DEFAULT_MASK_FILE)
        return w .. "x" .. h
    end)
    return ok and ("; default mask " .. tostring(err) .. " exported to " .. DEFAULT_MASK_FILE)
        or ("; default mask export failed: " .. tostring(err))
end
-- At the first opening of a session: the fog's material and masks as words for the log, with the default mask exported
-- (and, with the chart off, the explored mask too, for the log: with the chart on, its own step exports it).
local function logFogMaterial(screen)
    local info, rt, def = fogMasks(screen)
    local gi = owner()
    if rt and gi and (W.chartOff or not AP_ComposeFog) then
        local ok, err = pcall(function()
            local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            krl:ExportRenderTarget(gi, rt, W.dir, MASK_FILE)
        end)
        info = info .. (ok and ("; exported to " .. MASK_FILE) or ("; export failed: " .. tostring(err)))
    end
    if def and gi then
        info = info .. exportDefaultMask(def, gi)
    end
    return info
end

-- The explorer's-chart fog (the user, 2026-11-06: the black fog replaced by a basic map drawn like an explorer's chart,
-- with the locked-area stamps on it; art: the Art lane's ap-chart-*.png, the user's pick A). All drawn on the player's
-- machine by the C++ part from the game's own map (never shipped):
--   1. the chart, once a session, from the saved colour map (compose_chart);
--   2. when the map opens (at most every EXPORT_GAP updates) the explored mask is exported and the fog picture made from
--      it: the chart where unexplored, clear where explored, the stamps on it (compose_fog); which channel of the mask
--      means explored, and which way round, is read once from the mask at the player and beyond the world's edge;
--   3. the fog picture is handed to C++ (AP_MapScreen "fogpic"), which shows it in the fog image inside the screen's
--      own Setup: from the next opening, never swapped in view. The last session's picture is used until a new one.
-- UNTESTED IN GAME. config.txt map_chart=0 keeps the game's fog.
local CHART_SIZE = 2048
-- Each look keeps its own fog picture (dev.32 playtest, 2026-11-08: the first opening showed dev.31's chart, the last
-- session's map-fog.png, until the territories' one was made).
local function fogFile() return territories() and TERR_FOG_FILE or FOG_FILE end
local EXPORT_GAP = UTIL.updates(60)        -- a minute between exports of the explored mask
-- Before the map first opens, the explored mask is read from the world's map data every EARLY_MASK_EVERY, at most
-- EARLY_MASK_TRIES times (the map data may not be there yet just after a world loads).
local EARLY_MASK_EVERY = UTIL.updates(6)
local EARLY_MASK_TRIES = 10
-- State: the chart and the fog picture. Forgotten: the mask reads at a new world (MAP_FOG.resetMaskReads); the rest
-- never (the chart and the fog picture are files and textures kept for the session).
--   state  none -> composing   AP_ComposeChart started (the chart look)
--          composing -> ready  AP_ChartStatus says done
--          none -> ready       the Territories look, as soon as its fog art exists
--          any -> failed       the chart could not start or failed (failChart), for the rest of the session
--   fog    idle -> composing   startFog started AP_ComposeFog
--          composing -> idle   AP_FogStatus is no longer busy (done: the picture is loaded)
local chart = {
    state = "none",
    fog = "idle",
    spec = nil,         -- which channel of the explored mask means explored, and which way ("a-": alpha low)
    ticks = 0,          -- chart updates counted (the clock of the mask reads)
    exportedAt = nil,   -- the tick the explored mask was last read; nil before the first read in this world
    want = false,       -- the map opened: read the mask at the next chance (at most every EXPORT_GAP)
    early = nil,        -- reads of the mask before the map opened, in this world (at most EARLY_MASK_TRIES)
    tex = nil,          -- the fog picture loaded last, handed to C++
    stampKey = nil,     -- the stamps, borders and look the last fog picture was started with
    old = false,        -- the last session's fog picture was loaded (until a new one)
    keptAt = nil,       -- the fog picture's place in the kept objects (W.keepInPlace)
}
-- The chart cannot be made: the state is failed for the rest of the session, and why is logged.
local function failChart(why)
    chart.state = "failed"
    log("map chart: " .. why)
end
local exists = UTIL.exists
local artFile = ART.file
-- "explored" in the mask: the channel that differs most between the player (explored) and a corner beyond the world's
-- edge (never), and which way. nil (and why) when no channel tells them apart.
local function maskSpec(pawn)
    local okp, at = pcall(function() return pawn:K2_GetActorLocation() end)
    if not (okp and at) then return nil, "no player position" end
    local x0, x1, y0, y1 = layout.bounds.xMin, layout.bounds.xMax, layout.bounds.yMin, layout.bounds.yMax
    local u, v = (at.Y - y0) / (y1 - y0), (x1 - at.X) / (x1 - x0)
    local mask = W.dir .. "\\" .. MASK_FILE
    local here, corner = AP_SamplePNG(mask, tostring(u), tostring(v)), AP_SamplePNG(mask, EDGE_UV, EDGE_UV)
    local a, b = {}, {}
    for n in tostring(here):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(corner):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    local info = string.format("at the player (%.3f, %.3f) %s, beyond the world's edge %s", u, v, tostring(here), tostring(corner))
    if #a ~= 4 or #b ~= 4 then return nil, info end
    local best, diff = nil, 0
    for c = 1, 4 do if math.abs(a[c] - b[c]) > math.abs(diff) then best, diff = c, a[c] - b[c] end end
    if math.abs(diff) < MIN_CHANNEL_GAP then return nil, info .. ": no channel tells them apart" end
    return ("rgba"):sub(best, best) .. (diff > 0 and "+" or "-"), info
end
local function exportMask(screen, krl, gi)
    local dmi = screen.MaskTextureMaterial
    if not (dmi and dmi:IsValid()) then return "no fog material" end
    local rt = dmi:K2_GetTextureParameterValue(FName("TargetTexture"))
    if not (rt and rt:IsValid()) then return "no explored mask" end
    krl:ExportRenderTarget(gi, rt, W.dir, MASK_FILE)
    return true
end
-- The explored mask without the map screen (dev.34 playtest: the first opening showed the last session's fog picture,
-- and a second opening the game made without Setup kept it, so the new look showed about a minute in): the player's own
-- world map data holds it (UPalWorldMapUIData:GetRenderTargetByMapName "MainMap", the render target the screen's fog
-- shows), so it is read once the fog art is ready, before the map ever opens. nil while there is none.
local function worldMask(pawn)
    local ok, rt = pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local wmd = util and util:IsValid() and util:GetLocalWorldMapData(pawn)
        if not (wmd and wmd:IsValid()) then return nil end
        local r = wmd:GetRenderTargetByMapName(FName("MainMap"))
        if r and r:IsValid() then return r end
        r = wmd:GetCurrentRenderTarget()
        return r and r:IsValid() and r or nil
    end)
    return ok and rt or nil
end
-- The stamps for the fog picture: "path|u|v|px;..." (as drawStamps places them on the 4096 map).
local function stampList(locked)
    if iconsActive() then return "" end
    local parts = {}
    for _, k in ipairs(locked) do
        local c, name = layout.centres[k], layout.areas[k + 1]
        if c and name then
            local file = W.beyond[name] and "ap-map-stamp-sealed" or ("ap-map-stamp-" .. slugOf(W.parentOf(name)))
            local path = artFile(file)
            if path == "" then path = artFile("ap-map-stamp") end
            if path ~= "" then
                parts[#parts + 1] = table.concat({ path, c.stampU, c.stampV, stampSize(c) }, "|")
            end
        end
    end
    return table.concat(parts, ";")
end
-- The areas on the chart (the user, 2026-11-07: "should the regions on the unexplored map have better boundaries?";
-- go): a border between neighbouring areas and a hatch over locked ones, drawn by the C++ compositor from the area
-- labels (dev.29's DLL; an older one ignores it). The user's picks in the Art lane (2026-11-07): "dashed brown ink"
-- (59,42,26 at 210, 3 px, dash 14 / gap 8 at the 2048 chart) and the single diagonal hatch (art/ap-chart-hatch.png; a
-- plain hatch in the ink if the file is missing). dev.30 test: both ran out over the sea (an area's labels take in its
-- waters), the hatch made the map busy, and the line stair-stepped zoomed in: now on land only (the colour map tells
-- land from sea, as for the chart), the hatch at 0.28 (was 0.45), and the line's edge softened (dev.31's DLL).
-- config.txt map_regions=0: none.
local REGION_INK, REGION_WIDTH, REGION_DASH, REGION_GAP, REGION_HATCH = "59,42,26,210", 3, 14, 8, 0.28
local function regionSpec(passes)
    if W.regionsOff then return "" end
    return table.concat({ picture.labelsFile(), lockedIndexes(passes),
        artFile("ap-chart-hatch"),
        REGION_INK, tostring(REGION_WIDTH), tostring(REGION_DASH), tostring(REGION_GAP), tostring(REGION_HATCH),
        exists(W.dir .. "\\" .. COLOUR_FILE) and (W.dir .. "\\" .. COLOUR_FILE) or "", GAMMA }, "|")
end
local function startFog(stamps, regions, tag)
    local def = W.dir .. "\\" .. DEFAULT_MASK_FILE
    local art = territories() and TERR_FOG or CHART_FILE
    local size = territories() and terr.size or CHART_SIZE                  -- (the fog art's own size: its 8-bit path)
    local err = AP_ComposeFog(W.dir .. "\\" .. art, W.dir .. "\\" .. MASK_FILE, exists(def) and def or "", chart.spec,
        W.dir .. "\\" .. fogFile(), tostring(size), stamps, regions)
    if err == "" then chart.fog, chart.stampKey = "composing", stamps .. "\n" .. regions .. (tag or "")
    elseif err ~= "busy" then once("fogstart" .. err, "map chart: could not make the fog: " .. err) end
end
-- The stamps and area borders for the fog picture, made again only when the map's key changes: they test art files,
-- which would otherwise be opened on every update while nothing changes.
local fogParts = { key = nil, stamps = "", regions = "" }
local function fogStampsAndRegions(key, passes)
    if fogParts.key ~= key then
        local tagged = territories()
        fogParts = { key = key, stamps = tagged and "" or stampList(lockedList(passes)),
                     regions = tagged and "" or regionSpec(passes) }
    end
    return fogParts.stamps, fogParts.regions
end
-- 1. The fog art: the Territories' own (made with its overlay), or the chart, drawn once a session. True once it is
-- ready (from the next update, when it became ready just now in Territories).
local function stepChartArt()
    if chart.state == "none" and territories() then                          -- (the territories' fog art)
        if terr.done and exists(W.dir .. "\\" .. TERR_FOG) then chart.state = "ready"; log("map territories: the fog art is ready") end
        return false
    elseif chart.state == "none" then                                        -- the chart
        local colour = W.dir .. "\\" .. COLOUR_FILE
        if not exists(colour) then return false end
        local err = AP_ComposeChart(colour, artFile("ap-chart-paper"), artFile("ap-chart-sea"), artFile("ap-chart-compass"),
            W.dir .. "\\" .. CHART_FILE, tostring(CHART_SIZE), GAMMA)
        if err == "" then chart.state = "composing"
        elseif err ~= "busy" then failChart("could not start: " .. err) end
        return false
    elseif chart.state == "composing" then
        local st = AP_ChartStatus()
        if st == "busy" then return false end
        if st ~= "done" then
            failChart("failed: " .. tostring(st))
            return false
        end
        chart.state = "ready"
        log("map chart: drawn (" .. CHART_SIZE .. " px)")
    end
    return chart.state == "ready"
end
-- 2. A fog picture being made: true once it is done and is to be loaded, nil while busy or after it failed, false
-- otherwise. The last session's picture, when there is one, is loaded once until a new one is made.
local function finishFog()
    if chart.fog == "composing" then
        local st = AP_FogStatus()
        if st == "busy" then return nil end
        chart.fog = "idle"
        if st ~= "done" then
            once("fogerr" .. tostring(st), "map chart: the fog failed: " .. tostring(st))
            return nil
        end
        return true
    elseif not chart.old and not chart.tex and exists(W.dir .. "\\" .. fogFile()) then
        chart.old = true                                                     -- the last session's, until a new one
        return true
    end
    return false
end
-- Before the map opens: the explored mask read from the world's map data (worldMask) and the fog picture made.
local function readMaskEarly(pawn, krl, gi, stamps, regions, tag)
    chart.early = (chart.early or 0) + 1
    local rt = worldMask(pawn)
    local okE = rt and pcall(function() krl:ExportRenderTarget(gi, rt, W.dir, MASK_FILE) end)
    local spec, info = chart.spec, nil
    if okE and not spec then spec, info = maskSpec(pawn) end
    if okE and spec then
        chart.spec, chart.exportedAt = spec, chart.ticks
        log("map chart: the explored mask read before the map opened" .. (info and (": " .. info) or ""))
        startFog(stamps, regions, tag)
    elseif chart.early == EARLY_MASK_TRIES then
        log("map chart: the explored mask could not be read before the map opened ("
            .. (rt and tostring(info) or "no world map data") .. "); from the first opening instead")
    end
end
-- At a map opening: the explored mask exported from the screen, read once to learn which channel means explored, and
-- the fog picture made.
local function readMaskOnOpening(pawn, screen, krl, gi, stamps, regions, tag)
    chart.exportedAt, chart.want = chart.ticks, false
    local ok, res = pcall(exportMask, screen, krl, gi)
    if not ok or res ~= true then
        once("fogexp" .. tostring(res), "map chart: could not export the explored mask: " .. tostring(res))
        return
    end
    if not chart.spec then
        local spec, info = maskSpec(pawn)
        -- One reading that tells nothing apart (the player at the world's edge, no position yet) does not end the
        -- fog picture: the next export, EXPORT_GAP later, reads again.
        log("map chart: the explored mask " .. info .. (spec and (": explored reads " .. spec)
            or "; read again at a later opening"))
        if not spec then
            return
        end
        chart.spec = spec
    end
    startFog(stamps, regions, tag)
end
-- A new fog picture when the mask is to be read (before the map opens, or at an opening) or when the stamps, the area
-- borders or the look changed (a pass: the same mask).
local function remakeFog(pawn, screens, passes, key, krl, gi)
    local tagged = territories()
    local stamps, regions = fogStampsAndRegions(key, passes)
    local tag = tagged and ("#territories " .. tostring(terr.done)) or ""   -- (made again with the overlay)
    if not chart.exportedAt and not chart.want and (chart.early or 0) < EARLY_MASK_TRIES
       and UTIL.isDue(chart.ticks, EARLY_MASK_EVERY) then
        readMaskEarly(pawn, krl, gi, stamps, regions, tag)
    elseif chart.want and screens[#screens]
           and (not chart.exportedAt or chart.ticks - chart.exportedAt >= EXPORT_GAP) then
        readMaskOnOpening(pawn, screens[#screens], krl, gi, stamps, regions, tag)
    elseif chart.spec and chart.stampKey and stamps .. "\n" .. regions .. tag ~= chart.stampKey then
        startFog(stamps, regions, tag)
    end
end
-- 3. The fog picture loaded and handed to C++, which shows it from the next opening.
local function loadFogPicture(krl, gi)
    local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. fogFile())
    if not (tex and tex:IsValid()) then once("fogload", "map chart: could not load " .. fogFile()); return end
    chart.keptAt = W.keepInPlace(chart.keptAt, tex)          -- (only the newest fog picture is shown)
    chart.tex = tex
    AP_MapScreen("fogpic", UTIL.objectPath(tex))
    local whose = chart.old and chart.fog == "idle" and not chart.stampKey and "last session's" or "new"
    log("map chart: the fog picture is ready (" .. whose .. ")")
end
-- Each map update: the fog art, then the fog picture (finished, made again, loaded) step by step.
local function chartTick(pawn, screens, opening, passes, key)
    if W.chartOff or not (AP_ComposeChart and AP_ComposeFog and AP_SamplePNG and AP_MapScreen) then return end
    chart.ticks = chart.ticks + 1
    if opening then chart.want = true end                                    -- read the mask on this opening
    if #screens == 0 then chart.want = false end                             -- (closed before it was read)
    local gi = owner()
    if not gi then return end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if not stepChartArt() then return end
    local load = finishFog()
    if load == nil then return end
    if chart.fog == "idle" and not load then
        remakeFog(pawn, screens, passes, key, krl, gi)
    end
    if load then
        loadFogPicture(krl, gi)
    end
end
-- A new world: its explored mask is read again before its map opens; what the last world's reads found says nothing
-- of this one. (chart.spec, which channel of the mask means explored, holds for every world and is kept.)
function MAP_FOG.resetMaskReads()
    chart.exportedAt, chart.early, chart.want = nil, nil, false
end

-- Each map update: the chart and the fog picture stepped, C++ told the picture and switched on, and at an opening
-- C++'s status logged and the fog probed (once).
function MAP_FOG.step(pawn, screens, opening, passes, key)
    -- The chart is drawn in the background from the start; the mask is read while the map is open.
    local okt, errt = pcall(chartTick, pawn, screens, opening, passes, key)
    if not okt then once("charterr" .. tostring(errt), "map chart error: " .. tostring(errt)) end
    -- C++ is switched on from the start, not once the picture is ready (dev.16 playtest, 2026-11-07: the map opened
    -- 3 s before the picture was, and C++ logged "OFF; Setup ran 0x" though its hook saw Setup run).
    local okc0, errc0 = pcall(tellCpp)
    if not okc0 then once("cpperr", "map screen (C++): " .. tostring(errc0)) end
    if AP_MapScreen and opening then
        cpp.opened = cpp.opened + 1
        if cpp.opened <= LOG_FIRST then
            log("map screen (C++): " .. tostring(AP_MapScreen("status", "")) .. "; Lua put the picture back " .. cpp.fixes .. "x")
        end
        if not cpp.maskDone then
            cpp.maskDone = true
            local ok, info = pcall(logFogMaterial, screens[#screens])
            log("map fog: " .. tostring(info))
        end
    end
end
-- At the start of each map update: whether the map was on screen at the last update; it counts as not, until
-- noteShown has looked again.
function MAP_FOG.forgetShown()
    local was = mapShownAt > 0
    mapShownAt = 0
    return was
end
-- How many of this update's live main-map screens are on screen, kept for the next update and for W.mapShown.
function MAP_FOG.noteShown(screens)
    mapShownAt = screensOnScreen(screens)
    return mapShownAt
end
-- Lua found the game's own picture on a screen and put ours back: counted, and the first three logged.
function MAP_FOG.notePictureFixed()
    cpp.fixes = cpp.fixes + 1
    if cpp.fixes <= LOG_FIRST then log("map: Lua put the picture back (" .. cpp.fixes .. "x; C++ had not set it)") end
end

-- Hands over what this part reads (see the top of the file).
function MAP_FOG.install(env)
    W, picture, iconsActive = env.W, env.picture, env.icons.active
    local areas = env.areas
    layout, slugOf, lockedList, lockedIndexes = areas.layout, areas.slugOf, areas.lockedList, areas.lockedIndexes
    territories, terr, TERR_FOG = picture.territories, picture.terr, picture.TERR_FOG
    COLOUR_FILE, stampSize = picture.COLOUR_FILE, picture.stampSize
    GAMMA, RTF_RGBA8, BLEND_OPAQUE = picture.GAMMA, picture.RTF_RGBA8, picture.BLEND_OPAQUE
end

MAP_FOG.tellCpp = tellCpp
return MAP_FOG
