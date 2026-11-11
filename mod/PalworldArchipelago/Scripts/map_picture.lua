-- The world map: the picture with the locked areas (composed by the C++ part, or drawn here without it), the C++ map
-- screen, the explored mask, the chart and the fog picture, and the locked areas' icons on the map screen. A part of
-- walls.lua, which loads it (fresh for each copy of walls.lua) and hands it, by install, W (the table main.lua sees,
-- with the map's settings) and the areas part.
-- Tests: mod/test/harness.lua, group "the world map".
local MAP_PICTURE = {}
local UTIL = require("util")
local MAP_ICONS = nil            -- the icons part (map_icons.lua; install)
local log = UTIL.log
local once = UTIL.onceIn("walls")
-- Handed over by install: W, and the areas part's layout, isOpen, SEA, AREA_COLOURS and lists.
local W, layout, isOpen, SEA, AREA_COLOURS = nil, nil, nil, nil, nil
local slugOf, lockedList, lockedIndexes, openList = nil, nil, nil, nil

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
local GREY_FILE = "map-grey-1.png"
local RT_SIZE = 4096
local mapRT, mapKey, mapShownOn, greyTex, greyTried = nil, nil, nil, nil, false
local FADE = { R = 0.38, G = 0.40, B = 0.46, A = 1 }      -- the locked areas' tint without a greyscale copy
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local EDGE_SHADE = 0.45      -- how dark the band is at the very edge (1: not at all)
local owner = UTIL.gameInstance          -- (render targets and materials belong to it: see above)

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
local function drawStamps(canvas, krl, gi, locked)
    if iconsActive() then once("stampsicons", "map: locked areas are shown as map icons, not drawn on the picture"); return end
    local n = 0
    for _, k in ipairs(locked) do
        local c = layout.centres[k]
        local tex = c and stampTexture(k)
        if tex then
            local u, v = c[3] or c[1], c[4] or c[2]
            local px = stampSize(c)
            canvas:K2_DrawTexture(tex, { X = u * RT_SIZE - px / 2, Y = v * RT_SIZE - px / 2 },
                { X = px, Y = px }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, WHITE, 2, 0, { X = 0.5, Y = 0.5 })
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
        local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
        local canvasOut, contextOut, extra = {}, {}, {}
        krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
        canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
            { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
        krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
        krl:ExportRenderTarget(gi, rt, W.dir, "map-colour.png")
        local err = AP_GreyscalePNG(W.dir .. "\\map-colour.png", path, "0.4545")
        os.remove(W.dir .. "\\map-colour.png")
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
local function drawMap(ctx, passes)
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    pcall(LoadAsset, MAP_TEXTURE)                         -- LoadAsset wants the full Package.Object path
    local tex = StaticFindObject(MAP_TEXTURE)
    if not tex or not tex:IsValid() then return false end
    local gi = owner()
    if not gi then return false end
    local okg, grey = pcall(greyscaleMap, krl, tex)
    if not okg then log("map: greyscale copy failed: " .. tostring(grey)); grey = nil end
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8_SRGB
        if not mapRT or not mapRT:IsValid() then return false end
        W.keep(mapRT)
    end
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
    local canvas = canvasOut.Canvas
    if not canvas then return false end
    canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
        WHITE, 0, 0, { X = 0.5, Y = 0.5 })
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
    local okS, errS = pcall(drawStamps, canvas, krl, gi, lockedList(passes))
    if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    return true
end
-- With the C++ compositor (AP_ComposeMap): the whole picture is made on the player's machine in the background, from
-- the colour map (saved once, map-colour-1.png) and area_labels.png, with soft anti-aliased boundaries and an inner
-- shadow; when it is ready it is loaded and drawn into the render target. The picture is the game's own art: it stays
-- in the mod folder and is never shipped.
local COLOUR_FILE = "map-colour-1.png"
local composing, composedKey, failedKey = nil, nil, nil   -- the locked set being composed / last composed / last failed
local composingList = {}                                  -- that set's area indexes (for the stamps)
-- A fingerprint of the map the game shows: 16 pixels of it drawn small. A mod that replaces the map's art changes it, so
-- the saved colour map is made again (once a session, cheaply, instead of exporting the whole map every time).
local printChecked, printNow = false, nil
local colourSaved = false      -- colourMap saved the colour map again this session (the game's map changed)
local function mapPrint(krl, tex, gi)
    local rt = krl:CreateRenderTarget2D(gi, 16, 16, 2, { R = 0, G = 0, B = 0, A = 1 }, false)
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = 16, Y = 16 }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    local parts = {}
    for i = 0, 15 do
        local c = krl:ReadRenderTargetPixel(gi, rt, (i % 4) * 4 + 2, (i // 4) * 4 + 2)
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
    local rt = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 2, { R = 0, G = 0, B = 0, A = 1 }, false)   -- RTF_RGBA8
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, rt, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    krl:ExportRenderTarget(gi, rt, W.dir, COLOUR_FILE)
    colourSaved = true
    if printNow then
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
local TERR_OVERLAY, TERR_FOG, TERR_SIZE = "map-territories.png", "map-territories-fog.png", 2048
local TERR_FOG_COLOUR = "0E1A24"
local START_COLOUR, SEALED_COLOUR = "24E0CC", "5A6472"
-- The walls: "glow colour,alpha,core colour,alpha,glow px,blur sigma,core px" (px of a 4096 map). The Art lane's colours;
-- see-through (dev.32 playtest, 2026-11-08: "I like the brightness, but perhaps we should add some translucence?"; the
-- core was solid, the glow 0.55).
local TERR_WALLS = "FFE9B0,0.35,FFF4DC,0.6,10,3,5"
local terr = { composing = nil, done = nil, failed = nil, size = nil, whole = false }
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
        if not (isOpen(layout.areas[w[5] + 1], passes) and isOpen(layout.areas[w[6] + 1], passes)) then
            local u, v = (w[2] - y0) / (y1 - y0), (x1 - w[1]) / (x1 - x0)
            local half = w[3] / 2 / (x1 - x0)
            local yaw = math.rad(w[4])
            local du, dv = math.sin(yaw) * half, -math.cos(yaw) * half
            out[#out + 1] = string.format("%.5f,%.5f,%.5f,%.5f", u - du, v - dv, u + du, v + dv)
        end
    end
    return table.concat(out, ";")
end
MAP_PICTURE.areaSpec, MAP_PICTURE.wallSpec = areaSpec, wallSpec
-- Draws the finished Territories picture into the map picture; true when it is the look for `key`, "failed" when a
-- file could not be loaded.
local function drawTerritories(krl, gi, k, key)
    local over = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. TERR_OVERLAY)
    local map = over                          -- the whole picture has the map in it; an overlay goes over the game's
    if not terr.whole then
        pcall(LoadAsset, MAP_TEXTURE)
        map = StaticFindObject(MAP_TEXTURE)
    end
    if not (map and map:IsValid() and over and over:IsValid()) then
        log("map territories: could not load " .. (map and map:IsValid() and TERR_OVERLAY or "the game's map")); terr.failed = k; return "failed"
    end
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)
        W.keep(mapRT)
    end
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(map, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    if not terr.whole then
        canvasOut.Canvas:K2_DrawTexture(over, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
            { X = 1, Y = 1 }, WHITE, 2, 0, { X = 0.5, Y = 0.5 })
    end
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    terr.done = k
    once("terrdrawn" .. tostring(terr.whole), terr.whole and "map territories: drawn (the player's map, locked areas greyscale)"
        or "map territories: drawn over the game's map")
    return k == key
end
-- As composeMap: true once the map picture holds this key's look, "failed" once composing it failed.
local function composeTerritories(ctx, passes, key)
    if not terr.composing then
        if terr.done == key then return true end
        if terr.failed == key then return "failed" end
    end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return false end
    if terr.composing then
        local st = AP_TerritoriesStatus()
        if st == "busy" then return false end
        local k = terr.composing
        terr.composing = nil
        if st ~= "done" then log("map territories: composing failed: " .. tostring(st)); terr.failed = k; return "failed" end
        -- A picture that cannot be drawn is not composed again: it would fail the same way on every update.
        local okD, drawn = pcall(drawTerritories, krl, gi, k, key)
        if okD then
            return drawn
        end
        log("map territories: could not draw the picture (" .. tostring(drawn) .. "); not composed again")
        terr.failed = k
        return "failed"
    end
    -- From the Art lane's distance field when the DLL has it (dev.34: smooth at 4096, where the 2048 label map gave stairs
    -- and octagons; area_field*.png, made from the label maps by tools/map_fields.py), else from the label map at 2048.
    local field = W.dir .. "\\area_field" .. layout.suffix .. ".png"
    local hasField = AP_ComposeField and UTIL.exists(field)
    local err, size, whole
    if hasField then
        -- With the colour map (the player's own map, saved once; the user, dev.33: locked areas' "interior should be the
        -- greyscale"): the whole map picture, greyscale where locked, the walls there in the area's colour.
        local colour = W.dir .. "\\" .. COLOUR_FILE
        local hasColour = UTIL.exists(colour)
        if not hasColour then
            pcall(LoadAsset, MAP_TEXTURE)
            local tex = StaticFindObject(MAP_TEXTURE)
            if tex and tex:IsValid() then
                local okc, path = pcall(colourMap, krl, tex, gi)
                hasColour = okc and path and UTIL.exists(path) or false
            end
        end
        size, whole = 4096, hasColour
        err = AP_ComposeField(field, areaSpec(passes), wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY,
            W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR, tostring(size), whole and colour or "", "0.4545")
    else
        size = TERR_SIZE
        err = AP_ComposeTerritories(W.dir .. "\\area_labels" .. layout.suffix .. ".png", areaSpec(passes),
            wallSpec(passes), TERR_WALLS, W.dir .. "\\" .. TERR_OVERLAY, W.dir .. "\\" .. TERR_FOG, TERR_FOG_COLOUR,
            tostring(size))
    end
    if err == "" then
        terr.composing, terr.size, terr.whole = key, size, whole or false
        once("terrfrom" .. size, "map territories: composing "
            .. (hasField and "from the distance field" or "from the label map") .. " at " .. size)
    elseif err ~= "busy" then once("terr" .. err, "map territories: could not compose: " .. err) end
    return false
end

-- At the first opening, once: the game's map checked against the saved colour map's fingerprint, and saved again if it
-- changed. True when that saved it, so the picture is made again from the new colour map.
local function colourMapRenewed()
    if printChecked then
        return false
    end
    pcall(LoadAsset, MAP_TEXTURE)
    local tex = StaticFindObject(MAP_TEXTURE)
    local gi = owner()
    if not (tex and tex:IsValid() and gi) then
        return false
    end
    colourMap(StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"), tex, gi)
    return colourSaved
end
-- Draws the finished composition into the map picture, the stamps on it; false (with failedKey set) when it could not
-- be loaded. A picture that errors while drawn is not composed again either (composeMap): it would fail the same way.
local function drawComposed(krl, gi, done)
    local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\map-composed.png")
    if not tex or not tex:IsValid() then log("map: could not load the composed map; drawing it without the compositor"); failedKey = done; return false end
    if not mapRT or not mapRT:IsValid() then
        mapRT = krl:CreateRenderTarget2D(gi, RT_SIZE, RT_SIZE, 3, { R = 0, G = 0, B = 0, A = 1 }, false)
        W.keep(mapRT)
    end
    local canvasOut, contextOut, extra = {}, {}, {}
    krl:BeginDrawCanvasToRenderTarget(gi, mapRT, canvasOut, contextOut, extra)
    canvasOut.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = RT_SIZE, Y = RT_SIZE }, { X = 0, Y = 0 },
        { X = 1, Y = 1 }, WHITE, 0, 0, { X = 0.5, Y = 0.5 })
    local okS, errS = pcall(drawStamps, canvasOut.Canvas, krl, gi, composingList)
    if not okS then once("stamperr", "map: stamps failed: " .. tostring(errS)) end
    krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
    composedKey = done
    return true
end
-- Starts or finishes a composition; true once the render target holds the picture for this locked set, "failed" once
-- composing it failed. It runs from the start, not when the map first opens (dev.16 playtest, 2026-11-07: the picture
-- was only started once a map screen was found, so the first opening showed the game's map for a second or two while
-- it was made, and C++ had nothing to show yet). Until the map opens, the colour map saved in an earlier session is used
-- as it is, without loading the game's 8192 px map; at the first opening the game's map is checked against it once
-- (the fingerprint) and, if it changed (another mod), saved again and the picture made again.
local function composeMap(ctx, passes, key, open)
    if territories() then
        -- (Only a picture made from the colour map: the overlay alone is drawn over the game's own map each time.)
        if open and terr.whole and not terr.composing and colourMapRenewed() then
            terr.done = nil
        end
        return composeTerritories(ctx, passes, key)
    end
    if not composing then                    -- the usual case: nothing to do, nothing to look up
        if composedKey == key then
            if open and colourMapRenewed() then
                composedKey = nil                    -- made again from the new colour map
                return false
            end
            return true
        end
        if failedKey == key then return "failed" end
    end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local gi = owner()
    if not gi then return false end
    if composing then
        local st = AP_ComposeStatus()
        if st == "busy" then return false end
        local done = composing
        composing = nil
        -- A failure is not a picture: the render target still holds the last one. That set is not composed again (no
        -- retry loop); the map is drawn without the compositor instead.
        if st ~= "done" then log("map: composing failed: " .. tostring(st) .. "; drawing it without the compositor"); failedKey = done; return false end
        local okD, drawn = pcall(drawComposed, krl, gi, done)
        if not okD then
            log("map: could not draw the composed map (" .. tostring(drawn) .. "); drawing it without the compositor")
            failedKey = done
            return false
        end
        return drawn and done == key
    end
    local colour = W.dir .. "\\" .. COLOUR_FILE
    local saved = UTIL.exists(colour)
    if open or printChecked or not saved then
        pcall(LoadAsset, MAP_TEXTURE)
        local tex = StaticFindObject(MAP_TEXTURE)
        if not tex or not tex:IsValid() then return false end
        colour = colourMap(krl, tex, gi)
    end
    local err = AP_ComposeMap(colour, W.dir .. "\\area_labels" .. layout.suffix .. ".png", lockedIndexes(passes),
        W.dir .. "\\map-composed.png", "0.4545")
    if err == "" then composing, composingList = key, lockedList(passes) elseif err ~= "busy" then once("compose" .. err, "map: could not compose: " .. err) end
    return false
end

local mapShownAt = 0           -- map screens on screen at the last update (an opening is one coming on screen)
function MAP_PICTURE.mapShown() return mapShownAt > 0 end
-- A new world: its map has not been on screen yet, so its first showing is an opening.
function MAP_PICTURE.resetMapShown() mapShownAt = 0 end
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
-- PROBE BUILD (untested in game): a parchment fog (FOG_TEST, linear light, alpha 0.6) to see whether the fog's colour
-- alpha lets the map and the stamps show through; the explored mask is exported once (fog-mask.png) to see which way
-- round it is, for the explorer's-chart fog (unexplored areas drawn as a chart, the user's idea).
local FOG_TEST = "0.815,0.693,0.434,0.6"
-- What C++ was told: body is the picture's path (forgotten by W.mapOff, so it is told again), fog whether it was
-- switched on and given the fog colour; opened and fixes count map openings and pictures Lua put back, for the log.
local cpp = { body = nil, fog = false, opened = 0, fixes = 0, maskDone = false }
-- The fog colour C++ gives the screen until there is a fog picture: "" keeps the game's own dark fog. FOG_TEST only
-- with the test tools, in the chart look with its fog on; config.txt says map_chart=0 keeps the game's fog.
local function fogColour()
    if W.testFogColour and not territories() and not W.chartOff then
        return FOG_TEST
    end
    return ""
end
local function tellCpp()
    if not AP_MapScreen then return end
    if not cpp.fog then
        cpp.fog = true
        AP_MapScreen("enable", W.cppOff and "0" or "1")
        AP_MapScreen("fog", fogColour())
    end
    if mapRT and mapRT:IsValid() then
        local path = UTIL.objectPath(mapRT)
        if path ~= cpp.body then cpp.body = path; AP_MapScreen("body", path) end
    end
end
-- Switches the C++ map screen off where the mod's map does not belong (a seed without area locks, a world that is
-- not the seed's): C++ would otherwise show the seed's picture and fog there. Told once; tellCpp switches it on again.
function MAP_PICTURE.mapOff()
    if not (AP_MapScreen and cpp.fog) then
        return
    end
    cpp.fog, cpp.body = false, nil
    AP_MapScreen("enable", "0")
    log("map screen (C++): switched off, the game's own map here")
end
-- What the fog is made of, and its explored mask exported (once a session).
local function probeMask(screen)
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
    local gi = owner()
    -- (With the chart on, its own step exports the mask: not twice in one opening.)
    if rt and gi and (W.chartOff or not AP_ComposeFog) then
        local ok, err = pcall(function()
            StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary"):ExportRenderTarget(gi, rt, W.dir, "fog-mask.png")
        end)
        info = info .. (ok and "; exported to fog-mask.png" or ("; export failed: " .. tostring(err)))
    end
    -- The default mask (a texture, what every player sees uncovered): drawn into a render target of its size to export.
    if def and gi then
        local ok, err = pcall(function()
            local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            local w, h = def:Blueprint_GetSizeX(), def:Blueprint_GetSizeY()
            local drt = krl:CreateRenderTarget2D(gi, w, h, 2, { R = 0, G = 0, B = 0, A = 0 }, false)
            local canvasOut, contextOut, extra = {}, {}, {}
            krl:BeginDrawCanvasToRenderTarget(gi, drt, canvasOut, contextOut, extra)
            canvasOut.Canvas:K2_DrawTexture(def, { X = 0, Y = 0 }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 },
                WHITE, 0, 0, { X = 0.5, Y = 0.5 })
            krl:EndDrawCanvasToRenderTarget(gi, contextOut.RenderTarget and contextOut or extra)
            krl:ExportRenderTarget(gi, drt, W.dir, "fog-default-mask.png")
            return w .. "x" .. h
        end)
        info = info .. (ok and ("; default mask " .. tostring(err) .. " exported to fog-default-mask.png")
            or ("; default mask export failed: " .. tostring(err)))
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
local CHART_FILE, FOG_FILE = "map-chart.png", "map-fog.png"
-- Each look keeps its own fog picture (dev.32 playtest, 2026-11-08: the first opening showed dev.31's chart, the last
-- session's map-fog.png, until the territories' one was made).
local function fogFile() return territories() and "map-fog-territories.png" or FOG_FILE end
local EXPORT_GAP = UTIL.updates(60)        -- a minute between exports of the explored mask
-- Before the map first opens, the explored mask is read from the world's map data every EARLY_MASK_EVERY, at most
-- EARLY_MASK_TRIES times (the map data may not be there yet just after a world loads).
local EARLY_MASK_EVERY = UTIL.updates(6)
local EARLY_MASK_TRIES = 10
local chart = { state = "none", fog = "idle", spec = nil, ticks = 0, exportedAt = nil, tex = nil, stampKey = nil,
                old = false, keptAt = nil }            -- keptAt: the fog picture's place in the kept objects
local exists = UTIL.exists
local artFile = ART.file
-- "explored" in the mask: the channel that differs most between the player (explored) and a corner beyond the world's
-- edge (never), and which way. nil (and why) when no channel tells them apart.
local function maskSpec(ctx)
    local okp, at = pcall(function() return ctx:K2_GetActorLocation() end)
    if not (okp and at) then return nil, "no player position" end
    local x0, x1, y0, y1 = layout.map.bounds[1], layout.map.bounds[2], layout.map.bounds[3], layout.map.bounds[4]
    local u, v = (at.Y - y0) / (y1 - y0), (x1 - at.X) / (x1 - x0)
    local mask = W.dir .. "\\fog-mask.png"
    local here, corner = AP_SamplePNG(mask, tostring(u), tostring(v)), AP_SamplePNG(mask, "0.02", "0.02")
    local a, b = {}, {}
    for n in tostring(here):gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in tostring(corner):gmatch("%d+") do b[#b + 1] = tonumber(n) end
    local info = string.format("at the player (%.3f, %.3f) %s, beyond the world's edge %s", u, v, tostring(here), tostring(corner))
    if #a ~= 4 or #b ~= 4 then return nil, info end
    local best, diff = nil, 0
    for c = 1, 4 do if math.abs(a[c] - b[c]) > math.abs(diff) then best, diff = c, a[c] - b[c] end end
    if math.abs(diff) < 64 then return nil, info .. ": no channel tells them apart" end
    return ("rgba"):sub(best, best) .. (diff > 0 and "+" or "-"), info
end
local function exportMask(screen, krl, gi)
    local dmi = screen.MaskTextureMaterial
    if not (dmi and dmi:IsValid()) then return "no fog material" end
    local rt = dmi:K2_GetTextureParameterValue(FName("TargetTexture"))
    if not (rt and rt:IsValid()) then return "no explored mask" end
    krl:ExportRenderTarget(gi, rt, W.dir, "fog-mask.png")
    return true
end
-- The explored mask without the map screen (dev.34 playtest: the first opening showed the last session's fog picture,
-- and a second opening the game made without Setup kept it, so the new look showed about a minute in): the player's own
-- world map data holds it (UPalWorldMapUIData:GetRenderTargetByMapName "MainMap", the render target the screen's fog
-- shows), so it is read once the fog art is ready, before the map ever opens. nil while there is none.
local function worldMask(ctx)
    local ok, rt = pcall(function()
        local util = StaticFindObject("/Script/Pal.Default__PalUtility")
        local wmd = util and util:IsValid() and util:GetLocalWorldMapData(ctx)
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
            if path ~= "" then parts[#parts + 1] = table.concat({ path, c[3] or c[1], c[4] or c[2], stampSize(c) }, "|") end
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
    return table.concat({ W.dir .. "\\area_labels" .. layout.suffix .. ".png", lockedIndexes(passes),
        artFile("ap-chart-hatch"),
        REGION_INK, tostring(REGION_WIDTH), tostring(REGION_DASH), tostring(REGION_GAP), tostring(REGION_HATCH),
        exists(W.dir .. "\\" .. COLOUR_FILE) and (W.dir .. "\\" .. COLOUR_FILE) or "", "0.4545" }, "|")
end
MAP_PICTURE.regionSpec = regionSpec
local function startFog(stamps, regions, tag)
    local def = W.dir .. "\\fog-default-mask.png"
    local art = territories() and TERR_FOG or CHART_FILE
    local size = territories() and terr.size or CHART_SIZE                  -- (the fog art's own size: its 8-bit path)
    local err = AP_ComposeFog(W.dir .. "\\" .. art, W.dir .. "\\fog-mask.png", exists(def) and def or "", chart.spec,
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
local function chartTick(ctx, screens, opening, passes, key)
    if W.chartOff or not (AP_ComposeChart and AP_ComposeFog and AP_SamplePNG and AP_MapScreen) then return end
    chart.ticks = chart.ticks + 1
    if opening then chart.want = true end                                    -- read the mask on this opening
    if #screens == 0 then chart.want = false end                             -- (closed before it was read)
    local gi = owner()
    if not gi then return end
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    if chart.state == "none" and territories() then                          -- 1. (the territories' fog art)
        if terr.done and exists(W.dir .. "\\" .. TERR_FOG) then chart.state = "ready"; log("map territories: the fog art is ready") end
        return
    elseif chart.state == "none" then                                        -- 1. the chart
        local colour = W.dir .. "\\" .. COLOUR_FILE
        if not exists(colour) then return end
        local err = AP_ComposeChart(colour, artFile("ap-chart-paper"), artFile("ap-chart-sea"), artFile("ap-chart-compass"),
            W.dir .. "\\" .. CHART_FILE, tostring(CHART_SIZE), "0.4545")
        if err == "" then chart.state = "composing"
        elseif err ~= "busy" then chart.state = "failed"; log("map chart: could not start: " .. err) end
        return
    elseif chart.state == "composing" then
        local st = AP_ChartStatus()
        if st == "busy" then return end
        if st ~= "done" then chart.state = "failed"; log("map chart: failed: " .. tostring(st)); return end
        chart.state = "ready"
        log("map chart: drawn (" .. CHART_SIZE .. " px)")
    end
    if chart.state ~= "ready" then return end
    local load = false
    if chart.fog == "composing" then                                         -- 2. the fog picture
        local st = AP_FogStatus()
        if st == "busy" then return end
        chart.fog = "idle"
        if st ~= "done" then once("fogerr" .. tostring(st), "map chart: the fog failed: " .. tostring(st)); return end
        load = true
    elseif not chart.old and not chart.tex and exists(W.dir .. "\\" .. fogFile()) then
        chart.old, load = true, true                                         -- the last session's, until a new one
    end
    if chart.fog == "idle" and not load then
        local tagged = territories()
        local stamps, regions = fogStampsAndRegions(key, passes)
        local tag = tagged and ("#territories " .. tostring(terr.done)) or ""   -- (made again with the overlay)
        if not chart.exportedAt and not chart.want and (chart.early or 0) < EARLY_MASK_TRIES
           and UTIL.isDue(chart.ticks, EARLY_MASK_EVERY) then
            chart.early = (chart.early or 0) + 1                              -- (before the map opens: see worldMask)
            local rt = worldMask(ctx)
            local okE = rt and pcall(function() krl:ExportRenderTarget(gi, rt, W.dir, "fog-mask.png") end)
            local spec, info = chart.spec, nil
            if okE and not spec then spec, info = maskSpec(ctx) end
            if okE and spec then
                chart.spec, chart.exportedAt = spec, chart.ticks
                log("map chart: the explored mask read before the map opened" .. (info and (": " .. info) or ""))
                startFog(stamps, regions, tag)
            elseif chart.early == EARLY_MASK_TRIES then
                log("map chart: the explored mask could not be read before the map opened (" .. (rt and tostring(info) or "no world map data")
                    .. "); from the first opening instead")
            end
        elseif chart.want and screens[#screens] and (not chart.exportedAt or chart.ticks - chart.exportedAt >= EXPORT_GAP) then
            chart.exportedAt, chart.want = chart.ticks, false
            local ok, res = pcall(exportMask, screens[#screens], krl, gi)
            if not ok or res ~= true then once("fogexp" .. tostring(res), "map chart: could not export the explored mask: " .. tostring(res)); return end
            if not chart.spec then
                local spec, info = maskSpec(ctx)
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
        elseif chart.spec and chart.stampKey and stamps .. "\n" .. regions .. tag ~= chart.stampKey then
            startFog(stamps, regions, tag)                                   -- a pass: the same mask, new stamps, hatch or look
        end
    end
    if load then                                                             -- 3. shown from the next opening
        local tex = krl:ImportFileAsTexture2D(gi, W.dir .. "\\" .. fogFile())
        if not (tex and tex:IsValid()) then once("fogload", "map chart: could not load " .. fogFile()); return end
        chart.keptAt = W.keepInPlace(chart.keptAt, tex)          -- (only the newest fog picture is shown)
        chart.tex = tex
        AP_MapScreen("fogpic", UTIL.objectPath(tex))
        log("map chart: the fog picture is ready (" .. (chart.old and chart.fog == "idle" and not chart.stampKey and "last session's" or "new") .. ")")
    end
end
MAP_PICTURE.chartStatus = function() return chart end
-- A new world: its explored mask is read again before its map opens; what the last world's reads found says nothing
-- of this one. (chart.spec, which channel of the mask means explored, holds for every world and is kept.)
function MAP_PICTURE.resetMaskReads()
    chart.exportedAt, chart.early, chart.want = nil, nil, false
end

function MAP_PICTURE.updateMap(enabled, passes, ctx)
    local wasShown = mapShownAt > 0                  -- whether the map was on screen at the last update
    mapShownAt = 0
    if not enabled then
        MAP_PICTURE.mapOff()
        return
    end
    -- The game keeps a template of the map screen beside the real ones; only a real one has its map image. There may be
    -- more than one real one (different menus), and a map screen sets its own picture again when it opens, so every
    -- one is checked each time and given the greyed map whenever it shows anything else.
    -- Only the main world's screen: the game also builds the World Tree's (MapName "Tree"), which shows T_WorldMap for a
    -- moment as it is set up (dev.17 log, 2026-11-07); a screen whose name can't be read is kept, as before.
    -- Not the last world's (dev.35 playtest: after Return to title and a second world load, the first world's screens
    -- were still about until collected, and the icons went on one of them): a screen whose owning player is gone is left
    -- alone; one whose owner can't be read is kept.
    local images, screens = {}, {}
    for _, b in ipairs(FindAllOf("WBP_Map_Body_C") or {}) do
        local ok, img = pcall(function() local i = b.Image_MapBody; return i:IsValid() and i or nil end)
        local okn, mapName = pcall(function() return b.MapName:ToString() end)
        local main = not (okn and type(mapName) == "string" and mapName ~= "" and mapName ~= "None") or mapName:find("Main", 1, true)
        local gone = false
        if ok and img then                    -- (the game's template has no map image and no player: not a last world's)
            gone = UTIL.ownerGone(b)
        end
        if gone then once("stalescreen", "map: a map screen of the last world left alone (its player is gone)") end
        if b:IsValid() and ok and img and main and not gone then images[#images + 1] = img; screens[#screens + 1] = b end
    end
    mapShownAt = screensOnScreen(screens)
    local opening = mapShownAt > 0 and not wasShown
    local locked = {}
    for _, name in ipairs(layout.areas) do
        if not isOpen(name, passes) then locked[#locked + 1] = name end
    end
    -- The stamps differ for areas beyond the goal; and the picture has them drawn in only without the icons (so a
    -- failure of the icons, or map_icons=0, makes the picture and the chart fog again with the stamps).
    local been = {}
    if territories() then for area in pairs(W.visited) do been[#been + 1] = area end; table.sort(been) end
    local key = table.concat(locked, "|") .. "#" .. (W.beyondSig or "") .. (iconsActive() and "#icons" or "#stamps")
        .. (territories() and ("#territories#" .. table.concat(been, "|")) or "")
    -- The chart is drawn in the background from the start; the mask is read while the map is open.
    local okt, errt = pcall(chartTick, ctx, screens, opening, passes, key)
    if not okt then once("charterr" .. tostring(errt), "map chart error: " .. tostring(errt)) end
    -- C++ is switched on from the start, not once the picture is ready (dev.16 playtest, 2026-11-07: the map opened
    -- 3 s before the picture was, and C++ logged "OFF; Setup ran 0x" though its hook saw Setup run).
    local okc0, errc0 = pcall(tellCpp)
    if not okc0 then once("cpperr", "map screen (C++): " .. tostring(errc0)) end
    if AP_MapScreen and opening then
        cpp.opened = cpp.opened + 1
        if cpp.opened <= 3 then
            log("map screen (C++): " .. tostring(AP_MapScreen("status", "")) .. "; Lua put the picture back " .. cpp.fixes .. "x")
        end
        if not cpp.maskDone then
            cpp.maskDone = true
            local ok, info = pcall(probeMask, screens[#screens])
            log("map fog: " .. tostring(info))
        end
    end
    local redrawn = false
    local compose = AP_ComposeMap and AP_ComposeStatus
    if compose then
        local ok, ready = pcall(composeMap, ctx, passes, key, #images > 0)
        if not ok then once("composeerr" .. tostring(ready), "map error: " .. tostring(ready)); ready = false end
        if ready == "failed" then
            compose = false
        else
            if ready and key ~= mapKey then
                mapKey, redrawn = key, true
                log("map: " .. #locked .. " locked area(s) greyed")
            end
            if not mapKey or not mapRT then return end    -- nothing composed yet: the game's own map stays
        end
    end
    if not compose and key ~= mapKey then
        if #images == 0 then return end          -- without the compositor the map is drawn when it opens, as before
        local ok, done = pcall(drawMap, ctx, passes)
        if not ok then log("map overlay error: " .. tostring(done)); mapKey = key; return end
        if not done then return end
        mapKey, redrawn = key, true
        log("map: " .. #locked .. " locked area(s) greyed")
    end
    if not mapRT or not mapRT:IsValid() then return end
    local okc, errc = pcall(tellCpp)
    if not okc then once("cpperr", "map screen (C++): " .. tostring(errc)) end
    if #images == 0 then return end
    MAP_ICONS.show(screens, passes, key)
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
                cpp.fixes = cpp.fixes + 1
                if cpp.fixes <= 3 then log("map: Lua put the picture back (" .. cpp.fixes .. "x; C++ had not set it)") end
            end
            local ok, err = pcall(function() image:SetBrushResourceObject(mapRT) end)
            if not ok then once("mapshow", "map overlay: could not show it: " .. tostring(err)) end
        end
    end
end


-- A change of cut: the pictures made for the old one, and the shapes drawn from it, are forgotten.
function MAP_PICTURE.forgetPictures()
    triangles, bands = {}, {}
    mapKey, composing, composedKey, failedKey, composingList = nil, nil, nil, nil, {}
end

-- Hands over what this part reads from walls.lua (see the top of the file), and sets W's map settings to their
-- defaults until main.lua sets them from config.txt.
function MAP_PICTURE.install(env)
    W, MAP_ICONS = env.W, env.icons
    iconsActive, stampTexture = MAP_ICONS.active, MAP_ICONS.stampTexture
    local areas = env.areas
    layout, isOpen, SEA, AREA_COLOURS = areas.layout, areas.isOpen, areas.SEA, areas.AREA_COLOURS
    slugOf, lockedList, lockedIndexes, openList = areas.slugOf, areas.lockedList, areas.lockedIndexes, areas.openList
    W.dir = "."
    W.iconsOff = false
    W.mapStyle = "territories"
    W.cppOff = false             -- config.txt map_cpp=0 (main.lua): C++ leaves the screen alone; Lua alone, as before
    W.testFogColour = false      -- config.txt test_tools=1 (main.lua): the chart look sends FOG_TEST as the fog colour
    W.chartOff = false
    W.regionsOff = false
end

return MAP_PICTURE
