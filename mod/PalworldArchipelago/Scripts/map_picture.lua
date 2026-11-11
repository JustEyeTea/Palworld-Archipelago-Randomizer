-- The world map: the picture with the locked areas (composed by the C++ part, or drawn here without it), the C++ map
-- screen, the explored mask, the chart and the fog picture, and the locked areas' icons on the map screen. A part of
-- walls.lua, which loads it (fresh for each copy of walls.lua) and hands it, by install, W (the table main.lua sees,
-- with the map's settings) and the areas part.
-- Tests: mod/test/harness.lua, group "the world map".
local MAP_PICTURE = {}
local UTIL = require("util")
local MAP_ICONS = nil            -- the icons part (map_icons.lua; install)
local MAP_FOG = nil              -- the C++ map screen and fog part (map_fog.lua; install)
local log = UTIL.log
local once = UTIL.onceIn("walls")
-- Handed over by install: W, and the areas part's layout, isOpen, SEA, AREA_COLOURS and lists.
local W, layout, isOpen, SEA, AREA_COLOURS = nil, nil, nil, nil, nil
local slugOf, lockedList, lockedIndexes, openList, standing, beyondSig = nil, nil, nil, nil, nil, nil

-- The world map with locked areas in greyscale: the game's map drawn into a render target, then each locked area's
-- outline (area_shapes.lua: smoothed, cut into triangles) drawn over it from a greyscale copy of the map, darkening
-- softly toward its edge (a narrow band whose corners are shaded dark at the edge); shown in the map screen's map image (the exploration fog is a separate layer above it). Redrawn when
-- the set of locked areas changes.
-- The greyscale copy is made once on the player's machine and kept in the mod folder (it is the game's own art, so it
-- is never shipped): the map is drawn into a render target, saved as a PNG, turned grey by the C++ part
-- (AP_GreyscalePNG; the saved PNG is in linear light, hence the gamma) and loaded back. Without the C++ part, locked
-- areas are a dimmed copy of the colour map instead.
-- Render targets are owned by the game instance, never by something in the world: an object kept alive for the
-- session that belongs to the world stops the world being freed when leaving it, and the game crashes on the way back
-- to the title (v0.4.0 to v0.4.5).
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
-- The area labels of the cut in use (area_labels*.png, shipped: which area each pixel of the map is in).
local function labelsFile() return W.dir .. "\\area_labels" .. layout.suffix .. ".png" end
local RT_SIZE = 4096
-- Engine enum values passed as numbers, with the engine's own name for each.
local RTF_RGBA8 = 2           -- ETextureRenderTargetFormat::RTF_RGBA8 (linear: what is exported to a PNG)
local RTF_RGBA8_SRGB = 3      -- ETextureRenderTargetFormat::RTF_RGBA8_SRGB (the map picture, shown on screen)
local BLEND_OPAQUE = 0        -- EBlendMode::BLEND_Opaque
local BLEND_TRANSLUCENT = 2   -- EBlendMode::BLEND_Translucent
-- The gamma (1 / 2.2) the C++ part applies to the PNGs the engine exports, which are in linear light.
local GAMMA = "0.4545"
local FIELD_SIZE = 4096       -- px: a Territories picture made from the distance field (area_field*.png is made for it)
local mapRT, mapKey, mapShownOn, greyTex, greyTried = nil, nil, nil, nil, false
local FADE = { R = 0.38, G = 0.40, B = 0.46, A = 1 }      -- the locked areas' tint without a greyscale copy
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local EDGE_SHADE = 0.45      -- how dark the band is at the very edge (1: not at all)
local owner = UTIL.gameInstance          -- (render targets and materials belong to it: see above)
-- Draws into a render target: draw(canvas) between the engine's Begin and End. Begin's context comes back in
-- contextOut, or (as UE4SS passes the out-parameters) in the table after it; End is given whichever holds it.
local function drawInto(krl, gi, target, draw)
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, target, canvasOut, contextOut, extra)
    draw(canvasOut.Canvas)
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
end
-- Draws a whole texture over a w x h canvas (blend: the engine's blend mode).
local function drawWhole(canvas, tex, w, h, blend)
    canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, blend, 0,
        { X = 0.5, Y = 0.5 })
end
-- The map picture's render target, made (and kept for the session) when there is none; nil if it cannot be made.
local function mapTarget(krl, gi)
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, RTF_RGBA8_SRGB, { R = 0, G = 0, B = 0, A = 1 }, false)
        if not mapRT or not mapRT:IsValid() then return nil end
        W.keep(mapRT)
    end
    return mapRT
end
-- The game's own world map (8192 px), loaded when needed; nil when it cannot be found.
local function gameMapTexture()
    pcall(LoadAsset, MAP_TEXTURE)                         -- LoadAsset wants the full Package.Object path
    local tex = StaticFindObject(MAP_TEXTURE)
    return tex and tex:IsValid() and tex or nil
end

-- The locked-area stamps (Art & Assets lane: art/ap-map-stamp-<area>.png per area, round 2; art/ap-map-stamp.png when
-- an area has none), 256x256 tickets with a padlock, drawn on each locked area STAMP_PX across on the 4096 map, a whole
-- stamp inside the area on its side nearest the starting area (area_centres.lua, from tools/area_centres.py). v0.13.5
-- playtest: at each area's deepest point all 14 sat under the map's fog of war, which a locked area never clears.
local ART = require("art")
local STAMP_PX = 88
-- A region too small for the whole stamp gets a smaller one, about as wide as the region (its fifth field: how far the
-- stamp's point is from the region's edge), but never under STAMP_MIN_PX. 2026-11-06 run: the full 88 px padlock buried
-- Small Settlement's village. Data without the field (older area_centres files) keeps the full size.
local STAMP_MIN_PX = 28
local function stampSize(c)
    local room = c[5]
    if not room then return STAMP_PX end
    return math.max(STAMP_MIN_PX, math.min(STAMP_PX, math.floor(2 * room)))
end
MAP_PICTURE.stampSize = stampSize                                 -- (for the harness)
local iconsActive, stampTexture = nil, nil   -- (the icons part's: install)
local function drawStamps(canvas, locked)
    if iconsActive() then once("stampsicons", "map: locked areas are shown as map icons, not drawn on the picture"); return end
    local n = 0
    for _, k in ipairs(locked) do
        local c = layout.centres[k]
        local tex = c and stampTexture(k)
        if tex then
            local u, v = c[3] or c[1], c[4] or c[2]
            local px = stampSize(c)
            canvas:K2_DrawTexture(tex, { X = u * RT_SIZE - px / 2, Y = v * RT_SIZE - px / 2 },
                { X = px, Y = px }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, BLEND_TRANSLUCENT, 0,
                { X = 0.5, Y = 0.5 })
            n = n + 1
        end
    end
    once("stamps" .. n, "map: " .. n .. " locked-area stamp(s) drawn")
end
local function greyscaleMap(krl, tex)
    if greyTex and greyTex:IsValid() then return greyTex end
    if greyTried or not AP_GreyscalePNG then return nil end
    greyTried = true
    local gi = owner()
    if not gi then greyTried = false; return nil end
    local path = W.dir .. "\\" .. GREY_FILE
    if not UTIL.exists(path) then
        local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, RTF_RGBA8, { R = 0, G = 0, B = 0, A = 1 }, false)
        drawInto(krl, gi, rt, function(canvas) drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE) end)
        krl:ExportRenderTarget(gi, rt, W.dir, TEMP_COLOUR_FILE)
        local err = AP_GreyscalePNG(W.dir .. "\\" .. TEMP_COLOUR_FILE, path, GAMMA)
        os.remove(W.dir .. "\\" .. TEMP_COLOUR_FILE)
        if err ~= "" then log("map: no greyscale copy: " .. tostring(err)); return nil end
        log("map: made the greyscale copy " .. path)
    end
    greyTex = krl:ImportFileAsTexture2D(gi, path)
    if not greyTex or not greyTex:IsValid() then log("map: could not load " .. path); greyTex = nil; return nil end
    W.keep(greyTex)
    return greyTex
end
local triangles = {}          -- area index .. tint -> FCanvasUVTri list, built when first needed
local function trianglesOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if triangles[key] then return triangles[key] end
    layout.shapes = layout.shapes or require("area_shapes" .. layout.suffix)
    local v, out = layout.shapes.areas[k] or {}, {}
    for t = 1, #v - 5, 6 do
        local tri = {}
        for j = 0, 2 do
            local u, w = v[t + 2 * j], v[t + 2 * j + 1]
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = w * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = w }
            tri["V" .. j .. "_Color"] = tint
        end
        out[#out + 1] = tri
    end
    triangles[key] = out
    return out
end
local bands = {}              -- area index .. tint -> FCanvasUVTri list of its edge band
local function bandOf(k, tint)
    local key = k .. (tint == WHITE and "w" or "f")
    if bands[key] then return bands[key] end
    layout.shapes = layout.shapes or require("area_shapes" .. layout.suffix)
    local v, out = (layout.shapes.edges or {})[k] or {}, {}
    for t = 1, #v - 8, 9 do
        local tri = {}
        for j = 0, 2 do
            local u, w, sh = v[t + 3 * j], v[t + 3 * j + 1], v[t + 3 * j + 2]
            local f = EDGE_SHADE + (1 - EDGE_SHADE) * sh
            tri["V" .. j .. "_Pos"] = { X = u * RT_SIZE, Y = w * RT_SIZE }
            tri["V" .. j .. "_UV"] = { X = u, Y = w }
            tri["V" .. j .. "_Color"] = { R = tint.R * f, G = tint.G * f, B = tint.B * f, A = 1 }
        end
        out[#out + 1] = tri
    end
    bands[key] = out
    return out
end
local function drawMap(passes)
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = gameMapTexture()
    if not tex then return false end
    local gi = owner()
    if not gi then return false end
    local okg, grey = pcall(greyscaleMap, krl, tex)
    if not okg then log("map: greyscale copy failed: " .. tostring(grey)); grey = nil end
    if not mapTarget(krl, gi) then return false end
    -- (Not through drawInto: with no canvas this gives up before End, and the map is drawn at a later update.)
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
    local canvas = canvasOut.Canvas
    if not canvas then return false end
    drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
    for k, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then
            local tris = trianglesOf(k - 1, grey and WHITE or FADE)
            if #tris > 0 then canvas:K2_DrawTriangle(grey or tex, tris) end
        end
    end
    for k, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then
            local band = bandOf(k - 1, grey and WHITE or FADE)
            if #band > 0 then canvas:K2_DrawTriangle(grey or tex, band) end
        end
    end
    local okS, errS = pcall(drawStamps, canvas, lockedList(passes))
    if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    return true
end
-- With the C++ compositor (AP_ComposeMap): the whole picture is made on the player's machine in the background, from
-- the colour map (saved once, map-colour-1.png) and area_labels.png, with soft anti-aliased boundaries and an inner
-- shadow; when it is ready it is loaded and drawn into the render target. The picture is the game's own art: it stays
-- in the mod folder and is never shipped.
-- The two picture jobs, one per look (greyJob for map_style=chart, terr for Territories), keep the same three keys:
-- composing (the look being composed in the background), done (the look last drawn into the map picture) and failed
-- (a look whose composition failed, not tried again). A job answers "ready" (the map picture holds the look asked
-- for), "busy" (not yet) or "failed" (it will not: the map is drawn without the compositor).
-- greyJob also keeps the composing look's locked area indexes, for the stamps (locked).
local greyJob = { composing = nil, done = nil, failed = nil, locked = {} }
-- A fingerprint of the map the game shows: PRINT_GRID x PRINT_GRID pixels of it drawn PRINT_PX across. A mod that
-- replaces the map's art changes it, so the saved colour map is made again (once a session, cheaply, instead of
-- exporting the whole map every time).
local PRINT_PX = 16           -- the map drawn this small for its fingerprint
local PRINT_GRID = 4          -- that many pixels a row and a column are read, each in the middle of its cell
local printChecked, printNow = false, nil
local colourSaved = false      -- colourMap saved the colour map again this session (the game's map changed)
local function mapPrint(krl, tex, gi)
    local rt = krl:CreateRenderTarget2D(gi, PRINT_PX, PRINT_PX, RTF_RGBA8, { R = 0, G = 0, B = 0, A = 1 }, false)
    drawInto(krl, gi, rt, function(canvas) drawWhole(canvas, tex, PRINT_PX, PRINT_PX, BLEND_OPAQUE) end)
    local parts = {}
    local cell = PRINT_PX // PRINT_GRID
    for i = 0, PRINT_GRID * PRINT_GRID - 1 do
        local x, y = (i % PRINT_GRID) * cell + cell // 2, (i // PRINT_GRID) * cell + cell // 2
        local c = krl:ReadRenderTargetPixel(gi, rt, x, y)
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
local function colourMap(krl, tex, gi)
    local path = W.dir .. "\\" .. COLOUR_FILE
    if not printChecked then
        printChecked = true
        local ok, fp = pcall(mapPrint, krl, tex, gi)
        if ok then printNow = fp else log("map: no fingerprint (" .. tostring(fp) .. "): keeping the saved colour map") end
    end
    local saved = readFile(path .. ".txt")
    if UTIL.exists(path) then
        if not printNow or saved == printNow then return path end
        if saved then log("map: the game's map picture changed (another mod?): saving it again")
        else log("map: saving the colour map again with a fingerprint (made before map changes were checked)") end
    end
    local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, RTF_RGBA8, { R = 0, G = 0, B = 0, A = 1 }, false)
    drawInto(krl, gi, rt, function(canvas) drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE) end)
    krl:ExportRenderTarget(gi, rt, W.dir, COLOUR_FILE)
    colourSaved = true
    if printNow then                     -- the fingerprint: PRINT_GRID^2 pixels as "r,g,b;...", compared whole
        local out = io.open(path .. ".txt", "wb")
        if out then out:write(printNow); out:close() end
    end
    log("map: saved the colour map " .. path)
    return path
end
-- The "Territories" look (the user's direction 1, worked out with the Art & Assets lane, 2026-11-07; their lean, tweaks
-- may follow): the game's own map and fog underneath; every area tinted in its colour by its state, with a soft rim
-- inside its edge, over land and sea alike (areas take in their waters, and so do their walls); the standing walls as a
-- cream glow and core, drawn from their own positions. The C++ part composes it (AP_ComposeTerritories) from the
-- layout's labels, the areas' states and the standing walls: an overlay for the map picture (drawn over the game's map)
-- and the same over a dark fog for the unexplored parts (the fog picture C++ shows). config.txt map_style=chart: the
-- explorer's chart and greyscale instead.
local TERR_SIZE = 2048        -- px: a Territories picture from the label map (an older DLL, without AP_ComposeField)
local TERR_FOG_COLOUR = "0E1A24"
local START_COLOUR, SEALED_COLOUR = "24E0CC", "5A6472"
-- The walls: "glow colour,alpha,core colour,alpha,glow px,blur sigma,core px" (px of a 4096 map). The Art lane's colours;
-- see-through (dev.32 playtest, 2026-11-08: "I like the brightness, but perhaps we should add some translucence?"; the
-- core was solid, the glow 0.55).
local TERR_WALLS = "FFE9B0,0.35,FFF4DC,0.6,10,3,5"
local terr = { composing = nil, done = nil, failed = nil, size = nil, whole = false }   -- (and the picture's size, and
                                                                                     -- whether it is the whole map)
local function territories() return W.mapStyle == "territories" and AP_ComposeTerritories ~= nil end
-- "index:state:RRGGBB,...": v visited, u unlocked not yet visited, l locked, s sealed (beyond the goal).
local function areaSpec(passes)
    local out = {}
    for k, name in ipairs(layout.areas) do
        if name ~= SEA then
            local st
            if W.beyond[name] then st = "s"
            elseif isOpen(name, passes) then st = (name == layout.start or W.visited[name]) and "v" or "u"
            else st = "l" end
            local parent = W.parentOf(name)
            local hex = st == "s" and SEALED_COLOUR or AREA_COLOURS[parent]
                or (parent == layout.start and START_COLOUR) or "9AA3B5"
            out[#out + 1] = (k - 1) .. ":" .. st .. ":" .. hex
        end
    end
    return table.concat(out, ",")
end
-- The standing walls (up unless both sides are open; open sea counts as open) as "u1,v1,u2,v2;..." on the map square.
-- A piece runs along its yaw: (sin yaw, -cos yaw) in map u, v (the Art lane's mock lined them up with the labels so).
local function wallSpec(passes)
    local x0, x1, y0, y1 = layout.map.bounds[1], layout.map.bounds[2], layout.map.bounds[3], layout.map.bounds[4]
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
local function drawTerritories(krl, gi, k, key)
    local over = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. TERR_OVERLAY)
    local map = over                          -- the whole picture has the map in it; an overlay goes over the game's
    if not terr.whole then
        map = gameMapTexture()
    end
    if not (map and map:IsValid() and over and over:IsValid()) then
        log("map territories: could not load " .. (map and map:IsValid() and TERR_OVERLAY or "the game's map")); terr.failed = k; return "failed"
    end
    drawInto(krl, gi, mapTarget(krl, gi), function(canvas)
        drawWhole(canvas, map, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
        if not terr.whole then
            drawWhole(canvas, over, RT_SIZE, RT_SIZE, BLEND_TRANSLUCENT)
        end
    end)
    terr.done = k
    once("terrdrawn" .. tostring(terr.whole), terr.whole and "map territories: drawn (the player's map, locked areas greyscale)"
        or "map territories: drawn over the game's map")
    return k == key and "ready" or "busy"
end
-- As composeMap: true once the map picture holds this key's look, "failed" once composing it failed.
-- A Territories composition finished: its picture drawn into the map picture. As composeTerritories returns.
local function finishTerritories(krl, gi, key)
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
    local okD, drawn = pcall(drawTerritories, krl, gi, k, key)
    if okD then
        return drawn
    end
    log("map territories: could not draw the picture (" .. tostring(drawn) .. "); not composed again")
    terr.failed = k
    return "failed"
end
-- Whether the saved colour map is there to compose from (the player's own map, saved once; the user, dev.33: locked
-- areas' "interior should be the greyscale"), saving it from the game's map first if it is not.
local function haveColourMap(krl, gi)
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local hasColour = UTIL.exists(colour)
    if not hasColour then
        local tex = gameMapTexture()
        if tex then
            local okc, path = pcall(colourMap, krl, tex, gi)
            hasColour = okc and path and UTIL.exists(path) or false
        end
    end
    return hasColour, colour
end
-- Starts a Territories composition for `key` in the background. From the Art lane's distance field when the DLL has it
-- (dev.34: smooth at 4096, where the 2048 label map gave stairs and octagons; area_field*.png, made from the label maps
-- by tools/map_fields.py), else from the label map at 2048.
local function startTerritories(krl, gi, passes, key)
    local field = W.dir .. "\\area_field" .. layout.suffix .. ".png"
    local hasField = AP_ComposeField and UTIL.exists(field)
    local err, size, whole
    if hasField then
        -- With the colour map: the whole map picture, greyscale where locked, the walls there in the area's colour.
        local colour
        whole, colour = haveColourMap(krl, gi)
        size = FIELD_SIZE
        err = AP_ComposeField(field, areaSpec(passes), wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY,
            W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR, tostring(size), whole and colour or "", GAMMA)
    else
        size = TERR_SIZE
        err = AP_ComposeTerritories(labelsFile(), areaSpec(passes),
            wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY, W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR,
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
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return "busy" end
    if terr.composing then
        return finishTerritories(krl, gi, key)
    end
    startTerritories(krl, gi, passes, key)
    return "busy"
end

-- At the first opening, once: the game's map checked against the saved colour map's fingerprint, and saved again if it
-- changed. True when that saved it, so the picture is made again from the new colour map.
local function colourMapRenewed()
    if printChecked then
        return false
    end
    local tex = gameMapTexture()
    local gi = owner()
    if not (tex and gi) then
        return false
    end
    colourMap(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), tex, gi)
    return colourSaved
end
-- Draws the finished composition into the map picture, the stamps on it; false (with greyJob.failed set) when it
-- could not be loaded. A picture that errors while drawn is not composed again either (composeMap): it would fail the
-- same way.
local function drawComposed(krl, gi, done)
    local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. COMPOSED_FILE)
    if not tex or not tex:IsValid() then
        log("map: could not load the composed map; drawing it without the compositor")
        greyJob.failed = done
        return false
    end
    drawInto(krl, gi, mapTarget(krl, gi), function(canvas)
        drawWhole(canvas, tex, RT_SIZE, RT_SIZE, BLEND_OPAQUE)
        local okS, errS = pcall(drawStamps, canvas, greyJob.locked)
        if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    end)
    greyJob.done = done
    return true
end
-- A composition finished: its picture drawn into the map picture. As composeMap answers.
local function finishCompose(krl, gi, key)
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
    local okD, drawn = pcall(drawComposed, krl, gi, done)
    if not okD then
        log("map: could not draw the composed map (" .. tostring(drawn) .. "); drawing it without the compositor")
        greyJob.failed = done
        return "busy"
    end
    return drawn and done == key and "ready" or "busy"
end
-- Starts a composition for `key` in the background, from the saved colour map (saved again from the game's map at the
-- first opening, or when there is none) and the area labels.
local function startCompose(krl, gi, passes, key, open)
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local saved = UTIL.exists(colour)
    if open or printChecked or not saved then
        local tex = gameMapTexture()
        if not tex then return end
        colour = colourMap(krl, tex, gi)
    end
    local err = AP_ComposeMap(colour, labelsFile(), lockedIndexes(passes), W.dir .. "\\" .. COMPOSED_FILE, GAMMA)
    if err == "" then
        greyJob.composing, greyJob.locked = key, lockedList(passes)
    elseif err ~= "busy" then
        once("compose" .. err, "map: could not compose: " .. err)
    end
end
-- Starts or finishes a composition: "ready" once the render target holds the picture for this look, "failed" once
-- composing it failed, else "busy". It runs from the start, not when the map first opens (dev.16 playtest, 2026-11-07:
-- the picture was only started once a map screen was found, so the first opening showed the game's map for a second or
-- two while it was made, and C++ had nothing to show yet). Until the map opens, the colour map saved in an earlier
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
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return "busy" end
    if greyJob.composing then
        return finishCompose(krl, gi, key)
    end
    startCompose(krl, gi, passes, key, open)
    return "busy"
end

-- The main world's live map screens, and their map images. The game keeps a template of the map screen beside the real
-- ones; only a real one has its map image. There may be more than one real one (different menus), and a map screen
-- sets its own picture again when it opens, so every one is checked each time and given the greyed map whenever it
-- shows anything else.
-- Only the main world's screen: the game also builds the World Tree's (MapName "Tree"), which shows T_WorldMap for a
-- moment as it is set up (dev.17 log, 2026-11-07); a screen whose name can't be read is kept, as before.
-- Not the last world's (dev.35 playtest: after Return to title and a second world load, the first world's screens
-- were still about until collected, and the icons went on one of them): a screen whose owning player is gone is left
-- alone; one whose owner can't be read is kept.
local function mainMapScreens()
    local images, screens = {}, {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function() local i = b.Image_MapBody; return i:IsValid() and i or nil end)
        local okn, mapName = pcall(function() return b.MapName:ToString() end)
        local main = not (okn and type(mapName) == "string" and mapName ~= "" and mapName ~= "None") or mapName:find("Main", 1, true)
        local playerGone = false
        if ok and img then                    -- (the game's template has no map image and no player: not a last world's)
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
-- areas are locked.
local function pictureKey(passes)
    local locked = {}
    for _, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    -- The stamps differ for areas beyond the goal; and the picture has them drawn in only without the icons (so a
    -- failure of the icons, or map_icons=0, makes the picture and the chart fog again with the stamps).
    local been = {}
    if territories() then for area in pairs(W.visited) do been[#been + 1] = area end; table.sort(been) end
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
        if not open then return false end          -- without the compositor the map is drawn when it opens, as before
        local ok, done = pcall(drawMap, passes)
        if not ok then log("map overlay error: " .. tostring(done)); mapKey = key; return false end
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
                log("map: the map screen was showing " .. tostring(select(2, pcall(function() return shown:GetFullName() end))))
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
-- held. With area locks off (enabled false) C++ is switched off and nothing else is done.
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
    local areas = env.areas
    layout, isOpen, SEA, AREA_COLOURS = areas.layout, areas.isOpen, areas.SEA, areas.AREA_COLOURS
    slugOf, lockedList, lockedIndexes, openList = areas.slugOf, areas.lockedList, areas.lockedIndexes, areas.openList
    standing, beyondSig = areas.standing, areas.beyondSig
    W.dir = "."
    W.iconsOff = false
    W.mapStyle = "territories"
    W.cppOff = false             -- config.txt map_cpp=0 (main.lua): C++ leaves the screen alone; Lua alone, as before
    W.testFogColour = false      -- config.txt test_tools=1 (main.lua): the chart look's parchment fog colour is sent
    W.chartOff = false
    W.regionsOff = false
end

-- What the fog part reads of the picture: the render target is replaced when it is made again, so it goes by function.
MAP_PICTURE.target = function() return mapRT end
MAP_PICTURE.territories, MAP_PICTURE.terr, MAP_PICTURE.TERR_FOG = territories, terr, TERR_FOG
MAP_PICTURE.GAMMA, MAP_PICTURE.RTF_RGBA8, MAP_PICTURE.BLEND_OPAQUE = GAMMA, RTF_RGBA8, BLEND_OPAQUE
MAP_PICTURE.labelsFile = labelsFile
MAP_PICTURE.COLOUR_FILE, MAP_PICTURE.drawInto, MAP_PICTURE.drawWhole = COLOUR_FILE, drawInto, drawWhole
return MAP_PICTURE
