-- The world map: the picture with the locks still locked (composed by the C++ part, or drawn here without it), the C++
-- map screen, the explored mask, the chart and the fog picture, and their icons on the map screen. A part of
-- walls.lua, which loads it (fresh for each copy of walls.lua) and hands it, by install, W (the table main.lua sees,
-- with the map's settings) and the locks part.
-- Tests: mod/test/tests/map.lua; group "the world map" (tools/lua_harness.sh, in CI).
local MAP_PICTURE = {}
local UTIL = require("util")
local MAP_ICONS = nil            -- the icons part (map_icons.lua; install)
local MAP_FOG = nil              -- the C++ map screen and fog part (map_fog.lua; install)
local log = UTIL.log
local once = UTIL.onceIn("walls")
-- Handed over by install: W, and the locks part's layout, isOpen, SEA, REGION_COLOURS and lists.
local W, layout, isOpen, SEA, REGION_COLOURS = nil, nil, nil, nil, nil
local slugOf, lockedList, lockedIndexes, openList, standing, beyondSig = nil, nil, nil, nil, nil, nil
local PALETTE = nil           -- locks.lua's colours

-- Render targets are owned by the game instance, never by something in the world: an object kept alive for the
-- session that belongs to the world stops the world being freed when leaving it, and the game crashes on the way back
-- to the title.
local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
-- Files this part writes into the mod folder: the game's own art, made on the player's machine and never shipped.
--   GREY_FILE         the map in greyscale (drawn without the compositor); made once, then kept
--   COLOUR_FILE       the player's colour map, what every picture is made from; made again when the game's map
--                     changes, which its fingerprint, COLOUR_FILE .. ".txt", tells (colourMap)
--   TEMP_COLOUR_FILE  the colour map on its way to the greyscale one; removed at once
--   COMPOSED_FILE     the chart look's picture (AP_ComposeMap), made again for each new look
--   TERR_OVERLAY      the Territories picture, or its overlay over the game's map, made again for each new look
--   TERR_FOG          the Territories fog art, made with it (map_fog.lua makes the fog picture from it)
-- The "-1" in two names is part of the name only: a new number would make every player's copy again. map_fog.lua
-- lists its own files.
local GREY_FILE = "map-grey-1.png"
local COLOUR_FILE = "map-colour-1.png"
local TEMP_COLOUR_FILE = "map-colour.png"
local COMPOSED_FILE = "map-composed.png"
local TERR_OVERLAY, TERR_FOG = "map-territories.png", "map-territories-fog.png"
-- The lock labels of the cut in use (region_labels.png or area_labels.png, shipped: which lock each pixel is in).
local function labelsFile() return W.dir .. "\\" .. layout.prefix .. "labels.png" end
local RT_SIZE = 4096
-- Engine enum values passed as numbers, with the engine's own name for each.
local RTF_RGBA8 = 2           -- ETextureRenderTargetFormat::RTF_RGBA8 (linear: what is exported to a PNG)
local RTF_RGBA8_SRGB = 3      -- ETextureRenderTargetFormat::RTF_RGBA8_SRGB (the map picture, shown on screen)
local BLEND_OPAQUE = 0        -- EBlendMode::BLEND_Opaque
local BLEND_TRANSLUCENT = 2   -- EBlendMode::BLEND_Translucent
-- The gamma (1 / 2.2) the C++ part applies to the PNGs the engine exports, which are in linear light.
local GAMMA = "0.4545"
local FIELD_SIZE = 4096       -- px: a Territories picture made from the distance field (*_field.png is made for it)
local FADE = { R = 0.38, G = 0.40, B = 0.46, A = 1 }      -- tint of locks still locked, no greyscale copy
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local BLACK = { R = 0, G = 0, B = 0, A = 1 }  -- a new render target's colour, before anything is drawn into it
local EDGE_SHADE = 0.45      -- how dark the band is at the very edge (1: not at all)

-- State: the map picture. Forgotten at a change of cut (forgetPictures): mapKey, greyJob, the shapes' triangles and
-- bands. Never: mapRT (owned by the game instance, which lives all session; checked with IsValid on use), greyTex and
-- greyTried (the greyscale copy is the game's own map, the same in every world), terr (keyed by its look, which a new
-- cut changes), the fingerprint (the game's map does not change while it runs), and mapShownOn (a once-a-session log).
local mapRT, mapKey, mapShownOn, greyTex, greyTried = nil, nil, nil, nil, false
local triangles = {}          -- lock index .. tint -> FCanvasUVTri list, built when first needed
local bands = {}              -- lock index .. tint -> FCanvasUVTri list of its edge band
-- The two picture jobs, one per look (greyJob for map_style=chart, terr for Territories), keep the same three keys:
-- composing (the look being composed in the background), done (the look last drawn into the map picture) and failed
-- (a look whose composition failed, not tried again). A job answers "ready" (the map picture holds the look asked
-- for), "busy" (not yet) or "failed" (it will not: the map is drawn without the compositor).
-- greyJob also keeps the composing look's indexes of locks still locked, for the stamps (locked); terr the picture's
-- size and whether it is the whole map (made from the colour map) or an overlay.
local greyJob = { composing = nil, done = nil, failed = nil, locked = {} }
local terr = { composing = nil, done = nil, failed = nil, size = nil, whole = false }
local printChecked, printNow = false, nil   -- the fingerprint was read this session, and what it read
local colourSaved = false      -- colourMap saved the colour map again this session (the game's map changed)
local owner = UTIL.gameInstance          -- (render targets and materials belong to it: see above)
-- Draws into a render target: draw(canvas) between the engine's Begin and End. Begin's context comes back in
-- contextOut, or (as UE4SS passes the out-parameters) in the table after it; End is given whichever holds it.
local function drawInto(rendering, gameInstance, target, draw)
    local canvasOut, contextOut, extra = {}, {}, {}
    rendering:BeginDrawCanvasToRenderTarget(gameInstance, target, canvasOut, contextOut, extra)
    draw(canvasOut.Canvas)
    rendering:EndDrawCanvasToRenderTarget(gameInstance, contextOut.RenderTarget and contextOut or extra)
end
-- Draws a whole texture over a w x h canvas (blend: the engine's blend mode).
local function drawWhole(canvas, tex, w, h, blend)
    canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, blend, 0,
        { X = 0.5, Y = 0.5 })
end
-- The map picture's render target, made (and kept for the session) when there is none; nil if it cannot be made.
local function mapTarget(rendering, gameInstance)
    if not mapRT or not mapRT:IsValid() then
        mapRT = rendering:CreateRenderTarget2D(gameInstance, RT_SIZE, RT_SIZE, RTF_RGBA8_SRGB, BLACK, false)
        if not mapRT or not mapRT:IsValid() then return nil end
        W.keepAlive(mapRT)
    end
    return mapRT
end
-- The game's own world map (8192 px), loaded when needed; nil when it cannot be found.
local function gameMapTexture()
    pcall(LoadAsset, MAP_TEXTURE)                         -- LoadAsset wants the full Package.Object path
    local tex = StaticFindObject(MAP_TEXTURE)
    return tex and tex:IsValid() and tex or nil
end

-- The stamps of locks still locked (art/ap-map-stamp-<region>.png per region, which its areas wear too;
-- art/ap-map-stamp.png when a region has none), 256x256 tickets with a padlock, drawn on each such lock STAMP_PX across
-- on the 4096 map, a whole stamp inside the lock on its side nearest the starting lock (*_centres.lua, from
-- tools/lock_centres.py): at each lock's deepest point all 14 sat under the map's fog of war, which a lock never
-- clears while it is locked.
local ART = require("art")
local STAMP_PX = 88
-- A lock too small for the whole stamp gets a smaller one, about as wide as the lock (its fifth field: how far the
-- stamp's point is from the lock's edge), but never under STAMP_MIN_PX: the full 88 px padlock buried
-- Small Settlement's village. Data without the field (older *_centres files) keeps the full size.
local STAMP_MIN_PX = 28
local function stampSize(c)
    local room = c.room
    if not room then return STAMP_PX end
    return math.max(STAMP_MIN_PX, math.min(STAMP_PX, math.floor(2 * room)))
end
MAP_PICTURE.stampSize = stampSize                                 -- (for the harness)
local iconsActive, stampTexture = nil, nil   -- (the icons part's: install)
local function drawStamps(canvas, locked)
    if iconsActive() then
        once("stampsicons", "map: locked areas are shown as map icons, not drawn on the picture")
        return
    end
    local n = 0
    for _, k in ipairs(locked) do
        local centre = layout.centres[k]
        local tex = centre and stampTexture(k)
        if tex then
            local u, v = centre.stampU, centre.stampV
            local px = stampSize(centre)
            canvas:K2_DrawTexture(tex, { X = u * RT_SIZE - px / 2, Y = v * RT_SIZE - px / 2 },
                { X = px, Y = px }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, BLEND_TRANSLUCENT, 0,
                { X = 0.5, Y = 0.5 })
            n = n + 1
        end
    end
    once("stamps" .. n, "map: " .. n .. " locked-area stamp(s) drawn")
end
-- The greyscale copy of the map, for drawMap: made once on the player's machine and kept in the mod folder (it is the
-- game's own art, so it is never shipped): the map is drawn into a render target, saved as a PNG, turned grey by the
-- C++ part (AP_GreyscalePNG; the saved PNG is in linear light, hence the gamma) and loaded back. nil without the C++
-- part: locks still locked are then a dimmed copy of the colour map.
local function greyscaleMap(rendering, tex)
    if greyTex and greyTex:IsValid() then return greyTex end
    if greyTried or not AP_GreyscalePNG then return nil end
    greyTried = true
    local gameInstance = owner()
    if not gameInstance then
        greyTried = false
        return nil
    end
    local path = W.dir .. "\\" .. GREY_FILE
    if not UTIL.exists(path) then
        local rt = rendering:CreateRenderTarget2D(gameInstance, RT_SIZE, RT_SIZE, RTF_RGBA8, BLACK, false)
        drawInto(rendering, gameInstance, rt, function(canvas)
            drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
        end)
        rendering:ExportRenderTarget(gameInstance, rt, W.dir, TEMP_COLOUR_FILE)
        local err = AP_GreyscalePNG(W.dir .. "\\" .. TEMP_COLOUR_FILE, path, GAMMA)
        os.remove(W.dir .. "\\" .. TEMP_COLOUR_FILE)
        if err ~= "" then
            log("map: no greyscale copy: " .. tostring(err))
            return nil
        end
        log("map: made the greyscale copy " .. path)
    end
    greyTex = rendering:ImportFileAsTexture2D(gameInstance, path)
    if not greyTex or not greyTex:IsValid() then
        log("map: could not load " .. path)
        greyTex = nil
        return nil
    end
    W.keepAlive(greyTex)
    return greyTex
end
-- A lock's shape as the canvas's triangles (*_shapes.lua: 6 numbers a triangle, u, v of each of its 3 corners,
-- on the map square), tinted.
local function trianglesOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if triangles[key] then return triangles[key] end
    layout.shapes = layout.shapes or require(layout.prefix .. "shapes")
    local corners, out = layout.shapes.locks[k] or {}, {}
    for t = 1, #corners - 5, 6 do
        local tri = {}
        for j = 0, 2 do
            local u, v = corners[t + 2 * j], corners[t + 2 * j + 1]
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = v * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = v }
            tri["V" .. j .. "_Color"] = tint
        end
        out[#out + 1] = tri
    end
    triangles[key] = out
    return out
end
-- A lock's edge band as triangles (*_shapes.lua edges: 9 numbers a triangle, u, v and shade of each corner),
-- darkened toward the edge by the shade.
local function bandOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if bands[key] then return bands[key] end
    layout.shapes = layout.shapes or require(layout.prefix .. "shapes")
    local corners, out = (layout.shapes.edges or {})[k] or {}, {}
    for t = 1, #corners - 8, 9 do
        local tri = {}
        for j = 0, 2 do
            local u, v, shade = corners[t + 3 * j], corners[t + 3 * j + 1], corners[t + 3 * j + 2]
            local f = EDGE_SHADE + (1 - EDGE_SHADE) * shade
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = v * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = v }
            tri["V" .. j .. "_Color"] = { R = tint.R * f, G = tint.G * f, B = tint.B * f, A = 1 }
        end
        out[#out + 1] = tri
    end
    bands[key] = out
    return out
end
-- The map picture drawn here, without the compositor: the game's map drawn into the render target, then the outline of
-- each lock still locked (*_shapes.lua: smoothed, cut into triangles) drawn over it from the greyscale copy, darkening
-- softly toward its edge (a narrow band whose corners are shaded dark at the edge). True once drawn; drawn again when
-- the set of locks still locked changes. (The exploration fog is a separate layer above the map image.)
local function drawMap(passes)
    local rendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = gameMapTexture()
    if not tex then return false end
    local gameInstance = owner()
    if not gameInstance then return false end
    local okg, grey = pcall(greyscaleMap, rendering, tex)
    if not okg then
        log("map: greyscale copy failed: " .. tostring(grey))
        grey = nil
    end
    if not mapTarget(rendering, gameInstance) then return false end
    -- (Not through drawInto: with no canvas this gives up before End, and the map is drawn at a later update.)
    local canvasOut, contextOut, extra = {}, {}, {}
    rendering:BeginDrawCanvasToRenderTarget(gameInstance, mapRT, canvasOut, contextOut, extra)
    local canvas = canvasOut.Canvas
    if not canvas then return false end
    drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
    for k, name in ipairs(layout.locks) do
        if not isOpen(name, passes) then
            local tris = trianglesOf(k - 1, grey and WHITE or FADE)
            if #tris > 0 then canvas:K2_DrawTriangle(grey or tex, tris) end
        end
    end
    for k, name in ipairs(layout.locks) do
        if not isOpen(name, passes) then
            local band = bandOf(k - 1, grey and WHITE or FADE)
            if #band > 0 then canvas:K2_DrawTriangle(grey or tex, band) end
        end
    end
    local okS, errS = pcall(drawStamps, canvas, lockedList(passes))
    if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    rendering:EndDrawCanvasToRenderTarget(gameInstance, contextOut.RenderTarget and contextOut or extra)
    return true
end
-- With the C++ compositor (AP_ComposeMap): the whole picture is made on the player's machine in the background, from
-- the colour map (saved once, map-colour-1.png) and the lock labels, with soft anti-aliased boundaries and an inner
-- shadow; when it is ready it is loaded and drawn into the render target. The picture is the game's own art: it stays
-- in the mod folder and is never shipped.
-- A fingerprint of the map the game shows: PRINT_GRID x PRINT_GRID pixels of it drawn PRINT_PX across. A mod that
-- replaces the map's art changes it, so the saved colour map is made again (once a session, cheaply, instead of
-- exporting the whole map every time).
local PRINT_PX = 16           -- the map drawn this small for its fingerprint
local PRINT_GRID = 4          -- that many pixels a row and a column are read, each in the middle of its cell
local function mapPrint(rendering, tex, gameInstance)
    local rt = rendering:CreateRenderTarget2D(gameInstance, PRINT_PX, PRINT_PX, RTF_RGBA8, BLACK, false)
    drawInto(rendering, gameInstance, rt, function(canvas) drawWhole(canvas, tex, PRINT_PX, PRINT_PX, BLEND_OPAQUE) end)
    local parts = {}
    local cell = PRINT_PX // PRINT_GRID
    for i = 0, PRINT_GRID * PRINT_GRID - 1 do
        local x, y = (i % PRINT_GRID) * cell + cell // 2, (i // PRINT_GRID) * cell + cell // 2
        local c = rendering:ReadRenderTargetPixel(gameInstance, rt, x, y)
        parts[#parts + 1] = string.format("%d,%d,%d", c.R, c.G, c.B)
    end
    return table.concat(parts, ";")
end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function colourMap(rendering, tex, gameInstance)
    local path = W.dir .. "\\" .. COLOUR_FILE
    if not printChecked then
        printChecked = true
        local ok, fp = pcall(mapPrint, rendering, tex, gameInstance)
        if ok then
            printNow = fp
        else
            log("map: no fingerprint (" .. tostring(fp) .. "): keeping the saved colour map")
        end
    end
    local saved = readFile(path .. ".txt")
    if UTIL.exists(path) then
        if not printNow or saved == printNow then return path end
        if saved then log("map: the game's map picture changed (another mod?): saving it again")
        else log("map: saving the colour map again with a fingerprint (made before map changes were checked)") end
    end
    local rt = rendering:CreateRenderTarget2D(gameInstance, RT_SIZE, RT_SIZE, RTF_RGBA8, BLACK, false)
    drawInto(rendering, gameInstance, rt, function(canvas) drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE) end)
    rendering:ExportRenderTarget(gameInstance, rt, W.dir, COLOUR_FILE)
    colourSaved = true
    if printNow then                     -- the fingerprint: PRINT_GRID^2 pixels as "r,g,b;...", compared whole
        local out = io.open(path .. ".txt", "wb")
        if out then
            out:write(printNow)
            out:close()
        end
    end
    log("map: saved the colour map " .. path)
    return path
end
-- The "Territories" look (the default): the game's own
-- map and fog underneath; every lock tinted in its colour by its state, with a soft rim inside its edge, over land and
-- sea alike (locks take in their waters, and so do their walls); the standing walls as a cream glow and core, drawn
-- from their own positions. The C++ part composes it (AP_ComposeTerritories) from the layout's labels, the locks'
-- states and the standing walls: an overlay for the map picture (drawn over the game's map) and the same over a dark
-- fog for the unexplored parts (the fog picture C++ shows). config.txt map_style=chart: the explorer's chart and
-- greyscale instead.
local TERR_SIZE = 2048        -- px: a Territories picture from the label map (an older DLL, without AP_ComposeField)
-- The walls' look. Format: image_tools.hpp, compose_territories, argument style. Bright but see-through, so the map
-- shows through the walls.
local TERR_WALLS = "FFE9B0,0.35,FFF4DC,0.6,10,3,5"
local function territories() return W.mapStyle == "territories" and AP_ComposeTerritories ~= nil end
-- Each lock's state and colour. Format: image_tools.hpp, compose_territories, argument areas (these locks).
local function lockSpec(passes)
    local out = {}
    for k, name in ipairs(layout.locks) do
        if name ~= SEA then
            local st
            if W.beyond[name] then st = "s"
            elseif isOpen(name, passes) then st = (name == layout.start or W.visited[name]) and "v" or "u"
            else st = "l" end
            local region = W.regionOf(name)
            local hex = st == "s" and PALETTE.mapSealed or REGION_COLOURS[region]
                or (region == layout.start and PALETTE.teal) or PALETTE.noColour
            out[#out + 1] = (k - 1) .. ":" .. st .. ":" .. hex
        end
    end
    return table.concat(out, ",")
end
-- The standing walls (up unless both sides are open; open sea counts as open), each as its two ends on the map square.
-- Format: image_tools.hpp, compose_territories, argument walls. A piece runs along its yaw: (sin yaw, -cos yaw) in map
-- u, v (which lines them up with the labels).
local function wallSpec(passes)
    local x0, x1, y0, y1 = layout.bounds.xMin, layout.bounds.xMax, layout.bounds.yMin, layout.bounds.yMax
    local out = {}
    for _, w in ipairs(layout.walls) do
        if standing(w, passes) then
            local u, v = (w[2] - y0) / (y1 - y0), (x1 - w[1]) / (x1 - x0)
            local half = w[3] / 2 / (x1 - x0)
            local yaw = math.rad(w[4])
            local du, dv = math.sin(yaw) * half, -math.cos(yaw) * half
            out[#out + 1] = string.format("%.5f,%.5f,%.5f,%.5f", u - du, v - dv, u + du, v + dv)
        end
    end
    return table.concat(out, ";")
end
-- Draws the finished Territories picture into the map picture: "ready" when it is the look for `key` ("busy" when
-- another is wanted by now), "failed" when a file could not be loaded.
local function drawTerritories(rendering, gameInstance, k, key)
    local over = rendering:ImportFileAsTexture2D(gameInstance, W.dir .. "\\" .. TERR_OVERLAY)
    local map = over                          -- the whole picture has the map in it; an overlay goes over the game's
    if not terr.whole then
        map = gameMapTexture()
    end
    if not (map and map:IsValid() and over and over:IsValid()) then
        log("map territories: could not load " .. (map and map:IsValid() and TERR_OVERLAY or "the game's map"))
        terr.failed = k
        return "failed"
    end
    drawInto(rendering, gameInstance, mapTarget(rendering, gameInstance), function(canvas)
        drawWhole(canvas, map, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
        if not terr.whole then
            drawWhole(canvas, over, RT_SIZE, RT_SIZE, BLEND_TRANSLUCENT)
        end
    end)
    terr.done = k
    once("terrdrawn" .. tostring(terr.whole), terr.whole
        and "map territories: drawn (the player's map, locked areas greyscale)"
        or "map territories: drawn over the game's map")
    return k == key and "ready" or "busy"
end
-- As composeMap: true once the map picture holds this key's look, "failed" once composing it failed.
-- A Territories composition finished: its picture drawn into the map picture. As composeTerritories returns.
local function finishTerritories(rendering, gameInstance, key)
    local st = AP_TerritoriesStatus()
    if st == "busy" then return "busy" end
    local k = terr.composing
    terr.composing = nil
    if st ~= "done" then
        log("map territories: composing failed: " .. tostring(st))
        terr.failed = k
        return "failed"
    end
    -- A picture that cannot be drawn is not composed again: it would fail the same way on every update.
    local okD, drawn = pcall(drawTerritories, rendering, gameInstance, k, key)
    if okD then
        return drawn
    end
    log("map territories: could not draw the picture (" .. tostring(drawn) .. "); not composed again")
    terr.failed = k
    return "failed"
end
-- Whether the saved colour map is there to compose from (the player's own map, saved once, so locks still
-- locked show the map in greyscale), saving it from the game's map first if it is not.
local function haveColourMap(rendering, gameInstance)
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local hasColour = UTIL.exists(colour)
    if not hasColour then
        local tex = gameMapTexture()
        if tex then
            local okc, path = pcall(colourMap, rendering, tex, gameInstance)
            hasColour = okc and path and UTIL.exists(path) or false
        end
    end
    return hasColour, colour
end
-- Starts a Territories composition for `key` in the background. From the distance field when the DLL has it (smooth at
-- 4096, where the 2048 label map gave stairs and octagons; *_field.png, made from the label maps by
-- tools/map_fields.py), else from the label map at 2048.
local function startTerritories(rendering, gameInstance, passes, key)
    local field = W.dir .. "\\" .. layout.prefix .. "field.png"
    local hasField = AP_ComposeField and UTIL.exists(field)
    local err, size, whole
    if hasField then
        -- With the colour map: the whole map picture, greyscale where locked, the walls there in the lock's colour.
        local colour
        whole, colour = haveColourMap(rendering, gameInstance)
        size = FIELD_SIZE
        -- AP_ComposeField(field, areas, walls, style, out, fogart, fog colour, size, colour, gamma): dllmain.cpp's list
        err = AP_ComposeField(field, lockSpec(passes), wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY,
            W.dir .. "\\" .. TERR_FOG, PALETTE.fog, tostring(size), whole and colour or "", GAMMA)
    else
        size = TERR_SIZE
        -- AP_ComposeTerritories(labels, areas, walls, style, out, fogart, fog colour, size): dllmain.cpp's list
        err = AP_ComposeTerritories(labelsFile(), lockSpec(passes),
            wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY, W.dir .. "\\" .. TERR_FOG, PALETTE.fog,
            tostring(size))
    end
    if err == "" then
        terr.composing, terr.size, terr.whole = key, size, whole or false
        once("terrfrom" .. size, "map territories: composing "
            .. (hasField and "from the distance field" or "from the label map") .. " at " .. size)
    elseif err ~= "busy" then once("terr" .. err, "map territories: could not compose: " .. err) end
end
-- The Territories job: "ready", "busy" or "failed" (see greyJob).
local function composeTerritories(passes, key)
    if not terr.composing then
        if terr.done == key then return "ready" end
        if terr.failed == key then return "failed" end
    end
    local rendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gameInstance = owner()
    if not gameInstance then return "busy" end
    if terr.composing then
        return finishTerritories(rendering, gameInstance, key)
    end
    startTerritories(rendering, gameInstance, passes, key)
    return "busy"
end

-- At the first opening, once: the game's map checked against the saved colour map's fingerprint, and saved again if it
-- changed. True when that saved it, so the picture is made again from the new colour map.
local function colourMapRenewed()
    if printChecked then
        return false
    end
    local tex = gameMapTexture()
    local gameInstance = owner()
    if not (tex and gameInstance) then
        return false
    end
    colourMap(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), tex, gameInstance)
    return colourSaved
end
-- Draws the finished composition into the map picture, the stamps on it; false (with greyJob.failed set) when it
-- could not be loaded. A picture that errors while drawn is not composed again either (composeMap): it would fail the
-- same way.
local function drawComposed(rendering, gameInstance, done)
    local tex = rendering:ImportFileAsTexture2D(gameInstance, W.dir .. "\\" .. COMPOSED_FILE)
    if not tex or not tex:IsValid() then
        log("map: could not load the composed map; drawing it without the compositor")
        greyJob.failed = done
        return false
    end
    drawInto(rendering, gameInstance, mapTarget(rendering, gameInstance), function(canvas)
        drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
        local okS, errS = pcall(drawStamps, canvas, greyJob.locked)
        if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    end)
    greyJob.done = done
    return true
end
-- A composition finished: its picture drawn into the map picture. As composeMap answers.
local function finishCompose(rendering, gameInstance, key)
    local st = AP_ComposeStatus()
    if st == "busy" then return "busy" end
    local done = greyJob.composing
    greyJob.composing = nil
    -- A failure is not a picture: the render target still holds the last one. That set is not composed again (no
    -- retry loop); the map is drawn without the compositor instead.
    if st ~= "done" then
        log("map: composing failed: " .. tostring(st) .. "; drawing it without the compositor")
        greyJob.failed = done
        return "busy"
    end
    local okD, drawn = pcall(drawComposed, rendering, gameInstance, done)
    if not okD then
        log("map: could not draw the composed map (" .. tostring(drawn) .. "); drawing it without the compositor")
        greyJob.failed = done
        return "busy"
    end
    return drawn and done == key and "ready" or "busy"
end
-- Starts a composition for `key` in the background, from the saved colour map (saved again from the game's map at the
-- first opening, or when there is none) and the lock labels.
local function startCompose(rendering, gameInstance, passes, key, open)
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local saved = UTIL.exists(colour)
    if open or printChecked or not saved then
        local tex = gameMapTexture()
        if not tex then return end
        colour = colourMap(rendering, tex, gameInstance)
    end
    -- AP_ComposeMap(colour, labels, locked lock indexes, out, gamma): dllmain.cpp's list; image_tools.hpp, compose_map
    local err = AP_ComposeMap(colour, labelsFile(), lockedIndexes(passes), W.dir .. "\\" .. COMPOSED_FILE, GAMMA)
    if err == "" then
        greyJob.composing, greyJob.locked = key, lockedList(passes)
    elseif err ~= "busy" then
        once("compose" .. err, "map: could not compose: " .. err)
    end
end
-- Starts or finishes a composition: "ready" once the render target holds the picture for this look, "failed" once
-- composing it failed, else "busy". It runs from the start, not when the map first opens:
-- started once a map screen was found, the first opening showed the game's map for a second or two while the picture
-- was made, and C++ had nothing to show yet. Until the map opens, the colour map saved in an earlier
-- session is used as it is, without loading the game's 8192 px map; at the first opening the game's map is checked
-- against it once (the fingerprint) and, if it changed (another mod), saved again and the picture made again.
local function composeMap(passes, key, open)
    if territories() then
        -- (Only a picture made from the colour map: the overlay alone is drawn over the game's own map each time.)
        if open and terr.whole and not terr.composing and colourMapRenewed() then
            terr.done = nil
        end
        return composeTerritories(passes, key)
    end
    if not greyJob.composing then            -- the usual case: nothing to do, nothing to look up
        if greyJob.done == key then
            if open and colourMapRenewed() then
                greyJob.done = nil                   -- made again from the new colour map
                return "busy"
            end
            return "ready"
        end
        if greyJob.failed == key then return "failed" end
    end
    local rendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gameInstance = owner()
    if not gameInstance then return "busy" end
    if greyJob.composing then
        return finishCompose(rendering, gameInstance, key)
    end
    startCompose(rendering, gameInstance, passes, key, open)
    return "busy"
end

-- The main world's live map screens, and their map images. The game keeps a template of the map screen beside the real
-- ones; only a real one has its map image. There may be more than one real one (different menus), and a map screen
-- sets its own picture again when it opens, so every one is checked each time and given the greyed map whenever it
-- shows anything else.
-- Only the main world's screen: the game also builds the World Tree's (MapName "Tree"), which shows T_WorldMap for a
-- moment as it is set up; a screen whose name can't be read is kept.
-- Not the last world's (after Return to title and a second world load, the first world's screens
-- were still about until collected, and the icons went on one of them): a screen whose owning player is gone is left
-- alone; one whose owner can't be read is kept.
local function mainMapScreens()
    local images, screens = {}, {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function()
            local image = b.Image_MapBody
            return image:IsValid() and image or nil
        end)
        local okn, mapName = pcall(function() return b.MapName:ToString() end)
        local named = okn and type(mapName) == "string" and mapName ~= "" and mapName ~= "None"
        local main = not named or mapName:find("Main", 1, true)
        local playerGone = false
        if ok and img then              -- (the game's template has no map image and no player: not a last world's)
            playerGone = UTIL.ownerGone(b)
        end
        if playerGone then
            once("stalescreen", "map: a map screen of the last world left alone (its player is gone)")
        end
        if b:IsValid() and ok and img and main and not playerGone then
            images[#images + 1], screens[#screens + 1] = img, b
        end
    end
    return images, screens
end

-- The look the map picture must show, as a key that changes whenever the picture must be made again; and how many
-- locks are locked.
local function pictureKey(passes)
    local locked = {}
    for _, name in ipairs(layout.locks) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    -- The stamps differ for locks beyond the goal; and the picture has them drawn in only without the icons (so a
    -- failure of the icons, or map_icons=0, makes the picture and the chart fog again with the stamps).
    local been = {}
    if territories() then
        for lock in pairs(W.visited) do
            been[#been + 1] = lock
        end
        table.sort(been)
    end
    local key = table.concat(locked, "|") .. "#" .. beyondSig() .. (iconsActive() and "#icons" or "#stamps")
        .. (territories() and ("#territories#" .. table.concat(been, "|")) or "")
    return key, #locked
end

-- Makes the picture for `key` if it is not made yet: composed by the C++ part in the background, or (without it, or
-- after it failed) drawn here once a map screen is open. Returns whether there is a picture, and whether it was made
-- just now.
local function makePicture(passes, key, open, nLocked)
    local redrawn = false
    local compose = AP_ComposeMap and AP_ComposeStatus
    if compose then
        local ok, pictureReady = pcall(composeMap, passes, key, open)
        if not ok then
            once("composeerr" .. tostring(pictureReady), "map error: " .. tostring(pictureReady))
            pictureReady = "busy"
        end
        if pictureReady == "failed" then
            compose = false
        else
            if pictureReady == "ready" and key ~= mapKey then
                mapKey, redrawn = key, true
                log("map: " .. nLocked .. " locked area(s) greyed")
            end
            if not mapKey or not mapRT then return false end    -- nothing composed yet: the game's own map stays
        end
    end
    if not compose and key ~= mapKey then
        if not open then return false end          -- without the compositor the map is drawn when it opens
        local ok, done = pcall(drawMap, passes)
        if not ok then
            log("map overlay error: " .. tostring(done))
            mapKey = key
            return false
        end
        if not done then return false end
        mapKey, redrawn = key, true
        log("map: " .. nLocked .. " locked area(s) greyed")
    end
    return true, redrawn
end

-- Puts the picture on every map image that shows the game's world map instead (the screen sets its own when it opens,
-- unless C++ did it first), and on every one when the picture was made again.
local function putPictureBack(images, redrawn)
    local want = UTIL.addr(mapRT)
    for _, image in ipairs(images) do
        local okr, shown = pcall(function()
            local res = image.Brush.ResourceObject
            return res and res:IsValid() and res or nil
        end)
        local current = okr and shown and UTIL.addr(shown) or nil
        -- Only the main world's map is replaced: the World Tree has a map screen of its own (T_TreeMap).
        local name = okr and shown and select(2, pcall(function() return shown:GetFullName() end)) or ""
        local mainMap = current == want or tostring(name):find("T_WorldMap", 1, true) ~= nil
        if mainMap and (redrawn or current ~= want) then
            if okr and shown and current ~= want and not mapShownOn then
                mapShownOn = true
                local _, showing = pcall(function() return shown:GetFullName() end)
                log("map: the map screen was showing " .. tostring(showing))
            end
            if AP_MapScreen and not redrawn and current ~= want then
                MAP_FOG.notePictureFixed()
            end
            local ok, err = pcall(function() image:SetBrushResourceObject(mapRT) end)
            if not ok then once("mapshow", "map overlay: could not show it: " .. tostring(err)) end
        end
    end
end

-- Each update (main.lua): the map picture, the C++ map screen, the fog and the icons brought in line with the passes
-- held. With Area Locks off (enabled false) C++ is switched off and nothing else is done.
function MAP_PICTURE.updateMap(enabled, passes, pawn)
    local wasShown = MAP_FOG.forgetShown()        -- whether the map was on screen at the last update
    if not enabled then
        MAP_FOG.mapOff()
        return
    end
    local images, screens = mainMapScreens()
    local opening = MAP_FOG.noteShown(screens) > 0 and not wasShown
    local key, nLocked = pictureKey(passes)
    MAP_FOG.step(pawn, screens, opening, passes, key)
    local made, redrawn = makePicture(passes, key, #images > 0, nLocked)
    if not made or not mapRT or not mapRT:IsValid() then return end
    local okc, errc = pcall(MAP_FOG.tellCpp)
    if not okc then once("cpperr", "map screen (C++): " .. tostring(errc)) end
    if #images == 0 then return end
    MAP_ICONS.show(screens, passes, key)
    putPictureBack(images, redrawn)
end


-- A change of cut: the pictures made for the old one, and the shapes drawn from it, are forgotten.
function MAP_PICTURE.forgetPictures()
    triangles, bands = {}, {}
    mapKey, greyJob = nil, { composing = nil, done = nil, failed = nil, locked = {} }
end

-- Hands over what this part reads from walls.lua (see the top of the file), and sets W's map settings to their
-- defaults until main.lua sets them from config.txt.
function MAP_PICTURE.install(env)
    W, MAP_ICONS, MAP_FOG = env.W, env.icons, env.fog
    iconsActive, stampTexture = MAP_ICONS.active, MAP_ICONS.stampTexture
    local locks = env.locks
    layout, isOpen, SEA, REGION_COLOURS = locks.layout, locks.isOpen, locks.SEA, locks.REGION_COLOURS
    slugOf, lockedList, lockedIndexes, openList = locks.slugOf, locks.lockedList, locks.lockedIndexes, locks.openList
    standing, beyondSig, PALETTE = locks.standing, locks.beyondSig, locks.PALETTE
    W.dir = "."
    W.iconsOff = false
    W.mapStyle = "territories"
    W.cppOff = false             -- config.txt map_cpp=0 (main.lua): C++ leaves the screen alone; Lua swaps the picture
    W.testFogColour = false      -- config.txt test_tools=1 (main.lua): the chart look's parchment fog colour is sent
    W.chartOff = false
    W.chartBordersOff = false
end

-- What the fog part reads of the picture: the render target is replaced when it is made again, so it goes by function.
MAP_PICTURE.target = function() return mapRT end
MAP_PICTURE.territories, MAP_PICTURE.terr, MAP_PICTURE.TERR_FOG = territories, terr, TERR_FOG
MAP_PICTURE.GAMMA, MAP_PICTURE.RTF_RGBA8, MAP_PICTURE.BLEND_OPAQUE = GAMMA, RTF_RGBA8, BLEND_OPAQUE
MAP_PICTURE.labelsFile = labelsFile
MAP_PICTURE.COLOUR_FILE, MAP_PICTURE.drawInto, MAP_PICTURE.drawWhole = COLOUR_FILE, drawInto, drawWhole
return MAP_PICTURE
