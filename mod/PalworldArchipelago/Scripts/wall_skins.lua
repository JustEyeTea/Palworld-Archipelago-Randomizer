-- Wall skins: the looks the area-lock walls can wear (the game's red grid, the Art & Assets lane's patterns and
-- colour tiles, the area colours, the cream paws), their materials, the dissolve of an opened wall and the glow near
-- the player. A part of walls.lua, which loads it (fresh for each copy of walls.lua) and hands it, by install, W (the
-- table main.lua sees), the areas part and what it reads of the pieces.
-- Tests: mod/test/harness.lua, group "area locks".
local WALL_SKINS = {}
local UTIL = require("util")
local log = UTIL.log
local once = UTIL.onceIn("walls")
local owner = UTIL.gameInstance          -- (materials belong to the game instance, as walls.lua's map pictures do)
-- Handed over by install: W (settings: dir, keep, fade, tiling, scroll; data: beyond, layout), the areas part's layout,
-- isOpen and AREA_COLOURS, the pieces (raised(), isHidden(i), opening(), count(), statics()) and DISSOLVE_S.
local W, pieces, layout, isOpen, AREA_COLOURS, DISSOLVE_S = nil, nil, nil, nil, nil, nil
local dressedAs = {}           -- piece -> the material it wears with the area skin ("area:<colour>", "sealed", "a")

-- Wall skins (test builds: wall_skin=a, b, a3d or b3d in config.txt, or Ctrl+F3 with test_tools=1 to cycle them): the Art &
-- Assets lane's patterns (walls/ap-wall-pattern-<skin>.png, 512x512, greyscale) in AP teal on our walls only. One
-- dynamic copy of the walls' own material (MI_AirBlock_v2) per skin, owned by the game instance like the map's render
-- targets, set on each piece's mesh; the game's own barriers keep the shared red material. The material's parameters
-- (from the server pak): MainTexture01 is the pattern (T_DungeonGate02: linear, single channel); MainTexture02 is the
-- engine's blue noise for the dither, left alone; Color, DayColor and NightColor are the tint (night = 0.42 of day);
-- TilingU_01/TilingV_01 default to 5 and 3, ScrollingU_01/ScrollingV_01 to 0. Untested in game (2026-11-04).
-- a3d/b3d: the same, shaded as if raised (v0.13.5 playtest: a and b looked flat). <skin>-dense: that pattern tiled 10x6,
-- twice the material's 5x3, nearer the red grid's density (about 50 px a cell at 3 m against a3d's 100).
-- colour-<x>: full-colour tiles (walls/ap-wall-colour-<x>.png, RGBA) on our own material, M_APWall, from the
-- PalworldArchipelagoArt pak (logicmod/make_wall_material.py; the user, 2026-11-05: the game's material can show one
-- colour per piece, they want multicolour). Without the pak (or the file) such a skin is refused, logged, and skipped
-- by Ctrl+F3. colour-<x>-flow: that tile drifting sideways (FLOW tiles a second; the user's rainbow, 2026-11-05).
-- area (the default): walls/ap-wall-pattern-pawholes.png (the user, 2026-11-05: "an area-coloured wall with see-through
-- paw-shaped holes"; the hex lattice, pattern a, until that file exists) in the colour of the locked area each piece
-- keeps you out of (the user: "the region/area colored walls make WAAAAY more sense"), the colour of that area's pass ticket
-- (Art & Assets lane, area_shapes.COLOURS); a region wears its area's (area_parents_regions.lua). A piece between two
-- locked areas wears the one that isn't beyond the goal. Areas beyond the seed's goal (sealed for good) wear
-- walls/ap-wall-pattern-sealed.png in grey, or the lattice in grey until that file exists. A piece changes colour
-- when the area it wore opens and the other side is still locked.
-- paws (the default with the pak): the Art lane's cream paws (walls/ap-wall-paws-layer.png, cooked into the pak as
-- T_APWallPaws with mips) on M_APWall, over the same area colour at 0.34 (the material's Back and BackAlpha; the user's
-- pick C, 2026-11-05: "cream paws on the area colour"); sealed areas over the slate grey. Without the pak, area.
local SKINS = { "red", "colour-rainbow", "colour-rainbow-flow", "colour-paws", "colour-routes", "colour-grid",
                "a", "b", "a3d", "b3d", "a3d-dense", "b3d-dense", "area", "paws" }
local function byArea(name) return name == "area" or name == "paws" end
WALL_SKINS.SKINS = SKINS
local SEALED = { R = 0.3231, G = 0.3663, B = 0.4564, A = 1 }  -- slate grey #9AA3B5 (Art lane's suggestion; the user may pick)
local linearOf = UTIL.linear
WALL_SKINS.linearOf = linearOf                                    -- (for the harness's colour tests)
local FLOW = 0.05
local PAW_BACK, PAW_BRIGHT = 0.34, 1.1   -- the Art lane: emissive 1.0 to 1.2 (1.5 blooms the cream); raise the back first
local apWall = nil                                             -- M_APWall once loaded
local DENSE = { 10, 6 }
local TEAL = { R = 0.018, G = 0.745, B = 0.604, A = 1 }       -- sRGB #24E0CC, the user's pick
local MID_FLAGS = 0            -- EMIDCreationFlags::None, for CreateDynamicMaterialInstance
local GLOW_MOVE_CM = 5        -- the player moves this far before the walls' glow is told again
-- The paws' scatter: an Area's number turned into s, a fraction from 0 to 1 that looks random so neighbours differ
-- (frac(sin(n * SCATTER_A + 1) * SCATTER_B), a common hash); s moves the pattern by s * OFFSET_U_RATE and
-- s * OFFSET_V_RATE tiles, mirrors it past one half, and shades the back by BACK_SHADE + BACK_SHADE_RANGE * s.
local SCATTER_A, SCATTER_B = 12.9898, 43758.5453
local OFFSET_U_RATE, OFFSET_V_RATE = 7.13, 3.71
local BACK_SHADE, BACK_SHADE_RANGE = 0.88, 0.24
local NIGHT = 0.421875                                         -- the game's NightColor over its DayColor
local skin = { now = "red", want = "red", base = nil, mids = {}, failed = {} }
local sealedFile = nil         -- "sealed" when walls/ap-wall-pattern-sealed.png exists, else "a" (checked once)
local areaFile = nil           -- "pawholes" when walls/ap-wall-pattern-pawholes.png exists, else "a" (checked once)
local function patternOr(name)
    if UTIL.exists(W.dir .. "\\walls\\ap-wall-pattern-" .. name .. ".png") then return name end
    return "a"
end
local function meshOf(a)
    local ok, m = pcall(function() return a.Cube end)
    if ok and m and m:IsValid() then return m end
    local smc = StaticFindObject("/Script/Engine.StaticMeshComponent")
    ok, m = pcall(function() return a:GetComponentByClass(smc) end)
    if ok and m and m:IsValid() then return m end
end
WALL_SKINS.meshOf = meshOf
-- An asset of the PalworldArchipelagoArt pak: already loaded, else through the asset registry as BPModLoader loads the
-- pak's ModActor (AssetRegistryHelpers:GetAsset with PackageName and AssetName), else LoadAsset. 2026-11-08 dev.39
-- playtest: BPModLoader spawned the pak's ModActor in every level, yet LoadAsset + StaticFindObject found no M_APWall.
-- Each step is guarded; how it went is noted for the one-time probe line.
local function modAsset(pkg, name, notes)
    local full = pkg .. "." .. name
    local function found()
        local ok, o = pcall(StaticFindObject, full)
        return ok and o and o:IsValid() and o or nil
    end
    local o = found()
    if o then notes[#notes + 1] = name .. " already loaded"; return o end
    local ok, got = pcall(function()
        local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if not (helpers and helpers:IsValid()) then return "no AssetRegistryHelpers" end
        local function fname(s) return EFindName and FName(s, EFindName.FNAME_Add) or FName(s) end
        local a = helpers:GetAsset({ PackageName = fname(pkg), AssetName = fname(name) })
        return a and a:IsValid() and a or "GetAsset gave nothing"
    end)
    if ok and type(got) ~= "string" then notes[#notes + 1] = name .. " from the asset registry"; return got end
    notes[#notes + 1] = name .. " registry: " .. tostring(got)
    local okL, err = pcall(LoadAsset, full)
    o = found()
    if o then notes[#notes + 1] = name .. " from LoadAsset"; return o end
    notes[#notes + 1] = name .. " LoadAsset " .. (okL and "found nothing" or ("errored: " .. tostring(err)))
end
WALL_SKINS.modAsset = modAsset
local function fadeOn(mid)
    mid:SetScalarParameterValue(FName("FadeStart"), W.fade[1])
    mid:SetScalarParameterValue(FName("FadeEnd"), W.fade[2])
end
local apWallProbed = false
local function apWallMaterial()
    if apWall and apWall:IsValid() then return apWall end
    local notes = {}
    local m = modAsset("/Game/Mods/PalworldArchipelagoArt/M_APWall", "M_APWall", notes)
    if not apWallProbed then
        apWallProbed = true
        local okA, actor = pcall(StaticFindObject, "/Game/Mods/PalworldArchipelagoArt/ModActor.ModActor_C")
        local hasActor = okA and actor and actor:IsValid()
        log("wall material probe: " .. (m and "found" or "not found") .. " (" .. table.concat(notes, "; ") .. "); ModActor_C "
            .. (hasActor and "loaded" or "not loaded"))
    end
    if m then apWall = m; W.keep(m); return m end
end
local function colourMaterial(name, gi, krl, kml)
    local base = apWallMaterial()
    if not base then log("wall skin " .. name .. ": needs the PalworldArchipelagoArt pak (M_APWall not found)"); return nil end
    local flow = name:match("^(.-)%-flow$")
    local path = W.dir .. "\\walls\\ap-wall-" .. (flow or name) .. ".png"
    local tex = krl:ImportFileAsTexture2D(gi, path)
    if not (tex and tex:IsValid()) then log("wall skin " .. name .. ": could not load " .. path); return nil end
    W.keep(tex)                                                -- a colour picture: sRGB as imported
    local mid = kml:CreateDynamicMaterialInstance(gi, base, FName("None"), MID_FLAGS)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("Pattern"), tex)
    fadeOn(mid)
    local scroll = flow and { FLOW, 0 } or W.scroll
    if scroll then
        mid:SetScalarParameterValue(FName("ScrollU"), scroll[1])
        mid:SetScalarParameterValue(FName("ScrollV"), scroll[2])
    end
    skin.mids[name], skin.failed[name] = mid, nil
    log("wall skin " .. name .. ": material made on M_APWall" .. (scroll and (", scrolling " .. scroll[1] .. "," .. scroll[2]) or ""))
    return mid
end
-- The cream-paw layer: the pak's (with mips), else the PNG (none; the rims may shimmer far off). One for every area.
local pawLayer = nil
local function pawLayerTexture(gi, krl)
    if pawLayer and pawLayer:IsValid() then return pawLayer end
    local notes = {}
    local t, from = modAsset("/Game/Mods/PalworldArchipelagoArt/T_APWallPaws", "T_APWallPaws", notes), "the pak, with mips"
    if not (t and t:IsValid()) then
        t, from = krl:ImportFileAsTexture2D(gi, W.dir .. "\\walls\\ap-wall-paws-layer.png"), "walls\\ap-wall-paws-layer.png, no mips"
    end
    if not (t and t:IsValid()) then return nil end
    W.keep(t)
    pawLayer = t
    log("wall skin paws: the paw layer from " .. from)
    return t
end
-- paws:<hex> or paws:sealed: M_APWall with the paw layer over that colour (made, not kept in skin.mids).
local function makePaws(name, gi, krl, kml)
    local base = apWallMaterial()
    if not base then log("wall skin paws: needs the PalworldArchipelagoArt pak (M_APWall not found)"); return nil end
    local tex = pawLayerTexture(gi, krl)
    if not tex then log("wall skin paws: could not load walls\\ap-wall-paws-layer.png"); return nil end
    local hex, own = name:match("^paws:(%x%x%x%x%x%x):?(%d*)$")
    local back = hex and linearOf(hex) or SEALED
    local s = nil
    if own and own ~= "" then
        -- (The Art lane's scatter, above: never hue, rotation or scale.)
        local v = math.sin(tonumber(own) * SCATTER_A + 1.0) * SCATTER_B
        s = v - math.floor(v)
        local k = BACK_SHADE + BACK_SHADE_RANGE * s
        back = { R = back.R * k, G = back.G * k, B = back.B * k, A = 1 }
    end
    local mid = kml:CreateDynamicMaterialInstance(gi, base, FName("None"), MID_FLAGS)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("Pattern"), tex)
    mid:SetVectorParameterValue(FName("Back"), back)
    mid:SetScalarParameterValue(FName("BackAlpha"), PAW_BACK)
    mid:SetScalarParameterValue(FName("Brightness"), PAW_BRIGHT)
    if s then
        mid:SetScalarParameterValue(FName("OffsetU"), (s * OFFSET_U_RATE) % 1)
        mid:SetScalarParameterValue(FName("OffsetV"), (s * OFFSET_V_RATE) % 1)
        mid:SetScalarParameterValue(FName("MirrorU"), s > 0.5 and 1 or 0)
    end
    fadeOn(mid)
    if W.scroll then
        mid:SetScalarParameterValue(FName("ScrollU"), W.scroll[1])
        mid:SetScalarParameterValue(FName("ScrollV"), W.scroll[2])
    end
    return mid
end
local function pawsMaterial(name, gi, krl, kml)
    local mid = makePaws(name, gi, krl, kml)
    if not mid then return nil end
    skin.mids[name], skin.failed[name] = mid, nil
    log("wall skin " .. name .. ": material made on M_APWall")
    return mid
end
-- An opening piece's material: its paws, dissolving from now over DISSOLVE_S by the game's clock (M_APWall's
-- DissolveStart and DissolveTime against its Time node; an edge glows as it goes). One per look per second, so the
-- pieces an update opens share it; nil for any other skin (those shrink).
local dissolveMaterials, dissolveStarts = {}, {}
local glowAt = nil             -- where the player was last told to the M_APWall materials (W.glowTick, below)
function WALL_SKINS.dissolving(name, pawn)
    if not (name and name:find("^paws:")) then return nil end
    local ok, now = pcall(function() return pieces.statics():GetTimeSeconds(pawn) end)
    if not (ok and type(now) == "number") then return nil end
    local key = name .. "@" .. math.floor(now)
    local made = dissolveMaterials[key]
    if made and made:IsValid() then return made, dissolveStarts[key] end
    local gi = owner()
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if not (gi and krl and krl:IsValid() and kml and kml:IsValid()) then return nil end
    local mid = makePaws(name, gi, krl, kml)
    if not mid then return nil end
    mid:SetScalarParameterValue(FName("DissolveStart"), now)
    mid:SetScalarParameterValue(FName("DissolveTime"), DISSOLVE_S)
    if glowAt then mid:SetVectorParameterValue(FName("PlayerPos"), glowAt) end
    dissolveMaterials[key], dissolveStarts[key] = mid, now
    once("dissolve", "wall skin paws: an opened wall dissolves (" .. name .. " from " .. string.format("%.1f", now) .. " s)")
    return mid, now
end
-- The glow near the player (M_APWall's PlayerPos; dev.41 playtest: keyed to the camera it sat off to the side of the
-- character): the player's position on the M_APWall materials of pieces shown, each core update (300 ms; a faster
-- loop of our own corrupted Lua's state, see walls.lua's opening pieces), only when the player has moved. The pawn is
-- the core's, handed to W.update; checked each time.
function WALL_SKINS.glowing()
    if pieces.count() == 0 or not apWall then return false end
    return skin.now == "paws" or skin.now:find("^colour%-") ~= nil
end
function WALL_SKINS.glowTick()
    if not WALL_SKINS.glowing() then return end
    local pawn = W.lastContext
    if not (pawn and pawn:IsValid()) then return end
    local loc = pawn:K2_GetActorLocation()
    if not (loc and loc.X) then return end
    local moved = glowAt and math.abs(glowAt.R - loc.X) + math.abs(glowAt.G - loc.Y) + math.abs(glowAt.B - loc.Z)
    if moved and moved < GLOW_MOVE_CM then return end
    glowAt = { R = loc.X, G = loc.Y, B = loc.Z, A = 1 }
    -- Only the materials pieces shown now wear (dev.42 crash: every material ever made was called, those of the world
    -- before included), and the dissolving ones of pieces still there.
    local name, done = FName("PlayerPos"), {}
    local function tell(mid)
        if mid and not done[mid] and mid:IsValid() then done[mid] = true; mid:SetVectorParameterValue(name, glowAt) end
    end
    local wears = skin.now == "paws" and nil or skin.mids[skin.now]
    for i in pairs(pieces.raised()) do
        if not pieces.isHidden(i) then
            if wears then tell(wears); break end
            local n = dressedAs[i]
            if n then tell(skin.mids[n]) end
        end
    end
    for _, sk in ipairs(pieces.opening()) do if sk.dissolving and sk[1]:IsValid() then tell(sk.mid) end end
end
-- A new world (or the player's pawn changed): every material, texture and handle kept from before is let go, never
-- called again (dev.42 crash: the world before's materials, dead, called 30 times a second); made again when needed.
function WALL_SKINS.dropCaches()
    skin.mids, skin.failed = {}, {}                             -- (skin.base: the game's own red, an asset, kept)
    if skin.now ~= "red" then skin.now = "red" end           -- so skinTick dresses the new world's pieces again
    dissolveMaterials, dissolveStarts, glowAt, apWall, pawLayer = {}, {}, nil, nil, nil
end
-- The game instance and the rendering and material libraries a skin's material is made with, once the walls' own
-- material is known; nil while any of them is missing.
local function skinLibraries()
    local gi = owner()
    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if not (gi and skin.base and skin.base:IsValid() and krl and krl:IsValid() and kml and kml:IsValid()) then
        return nil
    end
    return gi, krl, kml
end
-- A pattern skin's tint, pattern file and tiling: the teal lattice and its variants, an area's colour, or sealed grey.
local function patternFor(name)
    local tint, file = TEAL, name:match("^(.-)%-dense$")
    local tiling = file and DENSE or W.tiling
    local hex = name:match("^area:(%x%x%x%x%x%x)$")
    if hex then
        areaFile = areaFile or patternOr("pawholes")
        tint, file = linearOf(hex), areaFile
    end
    if name == "sealed" then
        sealedFile = sealedFile or patternOr("sealed")
        tint, file = SEALED, sealedFile
    end
    return tint, file or name, tiling
end
-- A pattern skin's material: a dynamic copy of the walls' own material with the pattern and tint set; nil (logged)
-- when the pattern or the material cannot be made.
local function makePatternMaterial(name, gi, krl, kml)
    local tint, file, tiling = patternFor(name)
    local path = W.dir .. "\\walls\\ap-wall-pattern-" .. file .. ".png"
    local tex = krl:ImportFileAsTexture2D(gi, path)
    if not (tex and tex:IsValid()) then log("wall skin " .. name .. ": could not load " .. path); return nil end
    local srgb = pcall(function() tex.SRGB = false; tex:UpdateResource() end)   -- the game's pattern is linear
    W.keep(tex)
    local mid = kml:CreateDynamicMaterialInstance(gi, skin.base, FName("None"), MID_FLAGS)
    if not (mid and mid:IsValid()) then log("wall skin " .. name .. ": could not make the material"); return nil end
    W.keep(mid)
    mid:SetTextureParameterValue(FName("MainTexture01"), tex)
    local night = { R = tint.R * NIGHT, G = tint.G * NIGHT, B = tint.B * NIGHT, A = 1 }
    for k, c in pairs({ Color = tint, DayColor = tint, NightColor = night }) do mid:SetVectorParameterValue(FName(k), c) end
    if tiling then
        mid:SetScalarParameterValue(FName("TilingU_01"), tiling[1])
        mid:SetScalarParameterValue(FName("TilingV_01"), tiling[2])
    end
    if W.scroll then
        mid:SetScalarParameterValue(FName("ScrollingU_01"), W.scroll[1])
        mid:SetScalarParameterValue(FName("ScrollingV_01"), W.scroll[2])
    end
    skin.mids[name], skin.failed[name] = mid, nil
    -- Blueprint_GetSizeX/Y: Lua sees only UFunctions (v0.13.5 playtest: GetSurfaceWidth is C++ only, and the call errored).
    local okw, size = pcall(function() return tex:Blueprint_GetSizeX() .. "x" .. tex:Blueprint_GetSizeY() end)
    log("wall skin " .. name .. ": material made (" .. (okw and size or "size unknown")
        .. (srgb and ", linear" or ", sRGB: could not change") .. ", tiling "
        .. (tiling and (tiling[1] .. "x" .. tiling[2]) or "the material's") .. ")")
    return mid
end
-- A skin's material, made on first use; nil when it cannot be made (tried once a world: W.dropCaches empties failed).
local function skinMaterial(name)
    local mid = skin.mids[name]
    if mid and mid:IsValid() then return mid end
    if skin.failed[name] then return nil end
    skin.failed[name] = true                                   -- one try per skin per session; cleared on success
    local gi, krl, kml = skinLibraries()
    if not gi then
        log("wall skin " .. name .. ": no game instance, wall material or material library yet")
        skin.failed[name] = nil
        return nil
    end
    if name:find("^colour%-") then return colourMaterial(name, gi, krl, kml) end
    if name:find("^paws:") then return pawsMaterial(name, gi, krl, kml) end
    return makePatternMaterial(name, gi, krl, kml)
end
-- Puts the current skin on one piece (a new piece, or every raised one when the skin changes).
local function dress(a, mid)
    local m = meshOf(a)
    if not m then return false end
    if not skin.base then skin.base = m:GetMaterial(0); W.keep(skin.base) end   -- the red original, before any change
    m:SetMaterial(0, mid or skin.base)
    return true
end
-- The material a piece wears with the area skin (or paws), by name (see SKINS).
local function pieceSkin(i, passes, mode)
    local w = layout.walls[i]
    local a1, a2 = layout.areas[w[5] + 1], layout.areas[w[6] + 1]
    local l1, l2 = not isOpen(a1, passes), not isOpen(a2, passes)
    local area = (l1 and not l2) and a1 or (l2 and not l1) and a2 or (W.beyond[a1] and a2 or a1)
    local hex = AREA_COLOURS[W.parentOf(area)]
    if mode == "paws" then
        if W.beyond[area] then return "paws:sealed" end
        -- 75 Areas: each Area its Region's look, varied by its own number (pattern offset, mirror, Back shade).
        local own = ""
        if W.layout == "regions" and W.parentOf(area) ~= area then own = ":" .. (area == a1 and w[5] or w[6]) end
        return "paws:" .. (hex or "24E0CC") .. own             -- an area without a colour: the start island's teal
    end
    if W.beyond[area] then return "sealed" end
    return hex and ("area:" .. hex) or "a"
end
WALL_SKINS.pieceSkin = pieceSkin
-- With the area skin (or paws): that piece's own material (made on first use; the teal lattice if it can't be made).
local function areaDress(a, i, passes, mode)
    local name = pieceSkin(i, passes or {}, mode)
    local mid = skinMaterial(name)
    if not mid and name ~= "a" then name, mid = "a", skinMaterial("a") end
    if mid and dress(a, mid) then dressedAs[i] = name end
end
function WALL_SKINS.skinNew(a, i)
    local ok, err = true, nil
    if byArea(skin.now) then
        if i then ok, err = pcall(areaDress, a, i, W.lastPasses, skin.now) end
    elseif skin.now ~= "red" then
        ok, err = pcall(dress, a, skin.mids[skin.now])
    end
    if not ok then
        UTIL.onceErr("walls:skinnew", err, "wall skin " .. skin.now .. ": could not dress a new piece: " .. tostring(err))
    end
end
-- A pass that opens one side of a piece still up turns it to the other side's colour; so does the list of areas
-- beyond the goal arriving. A few pieces an update (RECOLOUR), only after something changed.
local RECOLOUR = 40
local recolourAt, passSig = nil, nil
function WALL_SKINS.recolour(passes)
    if not byArea(skin.now) then return end
    local n = 0
    for _ in pairs(passes) do n = n + 1 end
    local sig = n .. "/" .. (W.beyondSig or "")
    if sig ~= passSig then passSig, recolourAt = sig, 1 end
    if not recolourAt then return end
    local budget = RECOLOUR
    while recolourAt <= #layout.walls and budget > 0 do
        local i, a = recolourAt, pieces.raised()[recolourAt]
        if a and a:IsValid() and dressedAs[i] ~= pieceSkin(i, passes, skin.now) then
            local ok, err = pcall(areaDress, a, i, passes, skin.now)
            if not ok then
                UTIL.onceErr("walls:recolour", err, "wall skin " .. skin.now .. ": could not recolour piece " .. i .. ": "
                    .. tostring(err))
            end
            budget = budget - 1
        end
        recolourAt = recolourAt + 1
    end
    if recolourAt > #layout.walls then recolourAt = nil end
end
-- Empty or unset: paws (area without the pak); wall_skin=red for the game's own red grid.
WALL_SKINS.DEFAULT_SKIN = "paws"
function WALL_SKINS.setSkin(name)
    if name == "" or name == nil then name = WALL_SKINS.DEFAULT_SKIN end
    for _, s in ipairs(SKINS) do if s == name then skin.want = name; return end end
    log("wall skin " .. tostring(name) .. ": unknown (" .. table.concat(SKINS, ", ") .. ")")
end
-- The next skin, skipping any refused this session (no pak, no file): it would be refused again and the cycle would
-- stop there.
function WALL_SKINS.cycleSkin()
    local at = nil
    for k, name in ipairs(SKINS) do
        if name == skin.want then at = k end
    end
    if not at then return nil end
    for j = 1, #SKINS do
        local nxt = SKINS[(at + j - 1) % #SKINS + 1]
        if not skin.failed[nxt] then skin.want = nxt; return nxt end
    end
end
-- Dresses one raised piece in the skin wanted (mid: its material, for a skin that is not by area). True when it is
-- dressed; else false and the error, if there was one.
local function dressOne(a, i, mid)
    if byArea(skin.want) then
        local ok, err = pcall(areaDress, a, i, W.lastPasses, skin.want)
        return ok and dressedAs[i] ~= nil, not ok and err or nil
    end
    local ok, done = pcall(dress, a, mid)
    dressedAs[i] = nil
    return ok and done, not ok and done or nil
end
-- The walls' own red material, learnt from the first piece raised (the original, before any change). False until then.
local function learnBaseMaterial()
    if skin.base then return true end
    local _, a = next(pieces.raised())
    if not a then return false end
    local m = meshOf(a)
    skin.base = m and m:GetMaterial(0)
    if not skin.base then return false end
    W.keep(skin.base)
    return true
end
-- paws without the pak: area instead, and Ctrl+F3 skips paws from then on. False when that leaves nothing to change.
local function pawsOrArea()
    if skin.want ~= "paws" then return true end
    if apWallMaterial() then
        skin.failed.paws = nil
        return true
    end
    log("wall skin paws: needs the PalworldArchipelagoArt pak (M_APWall not found); the area colours instead")
    skin.failed.paws, skin.want = true, "area"
    return skin.want ~= skin.now
end
-- Dresses every raised piece in the skin wanted (mid: its material, for a skin not by area). Returns how many were
-- dressed, how many not, and the first error.
local function dressAll(mid)
    local n, bad, firstErr = 0, 0, nil
    for i, a in pairs(pieces.raised()) do
        if a:IsValid() then
            local done, err = dressOne(a, i, mid)
            if done then
                n = n + 1
            else
                bad, firstErr = bad + 1, firstErr or err
            end
        end
    end
    return n, bad, firstErr
end
-- The log of a skin change: the colours worn (a skin by area), and how many pieces were dressed and why not.
local function logSkin(n, bad, firstErr)
    if byArea(skin.now) then
        local kinds = {}
        for _, name in pairs(dressedAs) do kinds[name] = true end
        local list = {}
        for name in pairs(kinds) do list[#list + 1] = name end
        table.sort(list)
        log("wall skin " .. skin.now .. ": colours " .. table.concat(list, ", "))
    end
    local why = firstErr and (" (the first error: " .. tostring(firstErr) .. ")") or " (no mesh or no material)"
    log("wall skin " .. skin.now .. ": on " .. n .. " pieces" .. (bad > 0 and (", " .. bad .. " not dressed" .. why) or ""))
end
-- On the game thread (from W.update): the skin wanted, once the wall material is known (from the first piece raised).
function WALL_SKINS.skinTick()
    if skin.want == skin.now then return end
    if not learnBaseMaterial() then return end
    if not pawsOrArea() then return end
    local mid = nil
    if skin.want ~= "red" and not byArea(skin.want) then
        mid = skinMaterial(skin.want)
        if not mid then skin.want = skin.now; return end
    end
    local n, bad, firstErr = dressAll(mid)
    skin.now = skin.want
    logSkin(n, bad, firstErr)
end


-- Forgets what piece i wears (the piece was taken down or forgotten).
function WALL_SKINS.forget(i)
    dressedAs[i] = nil
end
-- Forgets what every piece wears (a change of cut: the piece numbers mean other pieces).
function WALL_SKINS.forgetAll()
    dressedAs = {}
end
-- The material piece i wears with the area skin, by name, or nil.
function WALL_SKINS.wornBy(i)
    return dressedAs[i]
end

-- Hands over what this part reads from walls.lua (see the top of the file), and sets W's skin settings to their
-- defaults until main.lua sets them from config.txt.
function WALL_SKINS.install(env)
    W, pieces, DISSOLVE_S = env.W, env.pieces, env.DISSOLVE_S
    layout, isOpen, AREA_COLOURS = env.areas.layout, env.areas.isOpen, env.areas.AREA_COLOURS
    W.tiling, W.scroll = nil, nil                                  -- { u, v } from config.txt, or the material's own
    -- M_APWall's fade (the user, 2026-11-08: dev.40's 9 to 15 m "loads in MUCH closer"): fully there within FADE[1] cm,
    -- gone at FADE[2] (config wall_fade=near,far in metres).
    W.fade = { 1500, 2500 }
end

return WALL_SKINS
