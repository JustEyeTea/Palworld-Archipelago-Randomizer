-- Wall skins: the looks the Area Locks walls can wear (each region's own wall, the cream paws, the region colours, the
-- game's red grid), their materials, the dissolve of an opened wall and the glow near the player. A part of walls.lua,
-- which loads it (fresh for each copy of walls.lua) and hands it, by install, W (the table main.lua sees), the locks
-- part and what it reads of the pieces.
-- Tests: mod/test/tests/walls.lua, walls_fresh.lua, locks_hud.lua; groups "area locks", "walls and the map, on fresh
--   copies of walls.lua", "Lock Size: areas" (tools/lua_harness.sh, in CI).
local WALL_SKINS = {}
local UTIL = require("util")
local log = UTIL.log
local once = UTIL.onceIn("walls")
local owner = UTIL.gameInstance          -- (materials belong to the game instance, as walls.lua's map pictures do)
-- Handed over by install: W (settings: dir, keepAlive, keepInPlace, fade, tiling, scroll; data: beyond, layout), the
-- locks part's layout, isOpen, standing, REGION_COLOURS, slugOf and beyondSig, the pieces (raised(), isHidden(i),
-- opening(), count(), statics(), passes(), pawn()) and DISSOLVE_S.
local W, pieces, layout, isOpen, REGION_COLOURS, DISSOLVE_S, beyondSig = nil, nil, nil, nil, nil, nil, nil
local standing = nil           -- locks.lua's test of whether a piece stands (either lock it separates still locked)
local slugOf = nil             -- locks.lua's name in file-name form ("Bamboo Groves" -> "bamboo-groves")
local PALETTE, SEALED, TEAL = nil, nil, nil   -- locks.lua's palette, and its sealed grey and teal in linear light

-- The skins (wall_skin in config.txt, or Ctrl+F3 with test_tools=1 to cycle them):
-- regions (the default, WALL_SKINS.DEFAULT_SKIN): each region's own wall, a tile cooked into the
--   PalworldArchipelagoArt pak with mips (T_APWallRegion_<region>_<version>, from logicmod/art/walls by
--   logicmod/make_wall_material.py), on M_APWall over the region's colour at BACK_ALPHA, as the paws. The 15 regions
--   wear version 0; with the 75 areas each area wears its region's tile in the version wall_region_variants.lua gives
--   it (two areas of one region that touch never share one), with the paws' per-area scatter on top. Locks beyond the
--   goal wear the bunker grille (T_APWallSealed) over PALETTE.wallBunker at BUNKER_BACK_ALPHA. A pak built before the
--   region walls has none of them: paws instead (area without the pak).
-- paws (the default with such an older pak; area without the pak): cream paws (walls/ap-wall-paws-layer.png, cooked
--   into the pak as T_APWallPaws with mips) on our own material, M_APWall, from the PalworldArchipelagoArt pak
--   (logicmod/make_wall_material.py), over the colour of the lock each piece guards at BACK_ALPHA (the material's
--   Back and BackAlpha); sealed locks over the slate grey.
-- area: walls/ap-wall-pattern-pawholes.png (a coloured wall with see-through paw-shaped holes) in the colour of the
--   lock still locked that each piece keeps you out of, so the wall says which lock it guards: the colour of its
--   region's pass ticket (locks.lua's REGION_COLOURS); an area wears its region's (area_regions.lua). A piece between
--   two locks still locked wears the one that isn't beyond the goal. Locks beyond the seed's goal (sealed for good)
--   wear walls/ap-wall-pattern-sealed.png in grey. A piece changes colour when the lock it wore opens and the other
--   side is still locked. Where a pattern file or a piece's material is missing, the piece wears pattern a, the hex
--   lattice in teal (walls/ap-wall-pattern-a.png).
-- red: the game's own red grid, the material the game's barriers wear too.
-- The area skin's materials are dynamic copies of the walls' own material (MI_AirBlock_v2), owned by the game instance
-- like the map's render targets, set on each piece's mesh. Its parameters (from the server pak): MainTexture01 is the
-- pattern (T_DungeonGate02: linear, single channel); MainTexture02 is the engine's blue noise for the dither, left
-- alone; Color, DayColor and NightColor are the tint (night = 0.42 of day); TilingU_01/TilingV_01 default to 5 and 3,
-- ScrollingU_01/ScrollingV_01 to 0.
local SKINS = { "red", "area", "paws", "regions" }
local function onApWall(name) return name == "paws" or name == "regions" end    -- a skin on the pak's M_APWall
local function byArea(name) return name == "area" or onApWall(name) end        -- a skin in each lock's colour
-- A look (pieceSkin's name for one piece's material) made on M_APWall: paws:... or region:...
local function isApWallLook(name)
    return name ~= nil and (name:find("^paws:") ~= nil or name:find("^region:") ~= nil)
end
WALL_SKINS.SKINS = SKINS
WALL_SKINS.linearOf = UTIL.linear                                 -- (for the harness's colour tests)
-- On M_APWall (the paws and the region walls): how solid the lock's colour under the layer is (BackAlpha), and the
-- brightness, emissive 1.0 to 1.2 (1.5 blooms the cream); raise the back first.
local BACK_ALPHA, BRIGHTNESS = 0.34, 1.1
-- The bunker grille's back (locks beyond the goal, regions skin): more solid than BACK_ALPHA, so the dark red-grey
-- reads between the bars as a wall that stays.
local BUNKER_BACK_ALPHA = 0.55
local ART_PAK = "/Game/Mods/PalworldArchipelagoArt/"         -- the PalworldArchipelagoArt pak's folder of assets
local BUNKER_TILE = "T_APWallSealed"                          -- the bunker grille's texture in the pak
local MID_FLAGS = 0            -- EMIDCreationFlags::None, for CreateDynamicMaterialInstance
WALL_SKINS.MID_FLAGS = MID_FLAGS  -- (glow_pieces.lua makes its looks with it too)
local GLOW_MOVE_CM = 5        -- the player moves this far before the walls' glow is told again
-- The paws' scatter: an Area's number turned into s, a fraction from 0 to 1 that looks random so neighbours differ
-- (frac(sin(n * SCATTER_A + 1) * SCATTER_B), a common hash); s moves the pattern by s * OFFSET_U_RATE and
-- s * OFFSET_V_RATE tiles, mirrors it past one half, and shades the back by BACK_SHADE + BACK_SHADE_RANGE * s.
local SCATTER_A, SCATTER_B = 12.9898, 43758.5453
local OFFSET_U_RATE, OFFSET_V_RATE = 7.13, 3.71
local BACK_SHADE, BACK_SHADE_RANGE = 0.88, 0.24
local NIGHT = 0.421875                                         -- the game's NightColor over its DayColor

-- State: the skins. Forgotten at a new world (WALL_SKINS.dropCaches, from W.reset): skin.mids and skin.failed (each
-- skin's material, and those refused), apWall, pawLayer, regionTiles, the dissolve materials and glowAt, all of the
-- world that went; skin.now goes back to red so the new world's pieces are dressed again. Never: skin.want and
-- skin.base (the game's own red material, an asset), sealedFile and areaFile (whether a file exists), apWallProbed (a
-- once-a-session log), areaVersions (a data file), and recolourAt and passSig (recolouring starts again when the
-- passes or the locks beyond the goal change).
local skin = { now = "red", want = "red", base = nil, mids = {}, failed = {} }
local dressedAs = {}           -- piece -> the material it wears with the area skin; forgotten with the piece (forget)
local sealedFile = nil         -- "sealed" when walls/ap-wall-pattern-sealed.png exists, else "a" (checked once)
local areaFile = nil           -- "pawholes" when walls/ap-wall-pattern-pawholes.png exists, else "a" (checked once)
local apWall = nil             -- M_APWall once loaded
local apWallProbed = false     -- the wall material probe line was logged
local pawLayer = nil           -- the cream-paw layer texture
local regionTiles = {}         -- a region wall's texture name in the pak -> its texture
local areaVersions = nil       -- wall_region_variants.lua (area -> its region wall's version), loaded when first needed
local dissolveMaterials, dissolveStarts = {}, {}   -- a look and second -> its dissolving material, and when it began
-- State: what the skins keep alive, and the pattern textures. Forgotten: never. Both are owned by the game instance,
-- which lasts the session: a material made again (after a pawn change, or each second while pieces dissolve) takes
-- the kept place of the one before, so the kept objects do not grow; a pattern file is loaded once.
local keptPlaces = {}          -- what is kept ("material area:...", "dissolve paws:...", "pattern a") -> its place
local patternTextures = {}     -- pattern file -> { texture, linear = whether it could be made linear }
local glowAt = nil             -- where the player was last told to the M_APWall materials (glowTick)
local recolourAt, passSig = nil, nil   -- the next piece to recolour, and the trigger it was started for
-- Keeps obj alive in the place kept for `key` (W.keepInPlace), in place of what was kept there before.
local function keepAs(key, obj)
    keptPlaces[key] = W.keepInPlace(keptPlaces[key], obj)
end
local function patternOr(name)
    if UTIL.exists(W.dir .. "\\walls\\ap-wall-pattern-" .. name .. ".png") then return name end
    return "a"
end
local function meshOf(actor)
    local ok, m = pcall(function() return actor.Cube end)
    if ok and m and m:IsValid() then return m end
    local meshClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
    ok, m = pcall(function() return actor:GetComponentByClass(meshClass) end)
    if ok and m and m:IsValid() then
        UTIL.took("wall skins: a wall's mesh", "found by GetComponentByClass (the actor has no Cube)")
        return m
    end
end
WALL_SKINS.meshOf = meshOf
-- An asset of the PalworldArchipelagoArt pak: already loaded, else through the asset registry as BPModLoader loads the
-- pak's ModActor (AssetRegistryHelpers:GetAsset with PackageName and AssetName), else LoadAsset. In game,
-- BPModLoader spawned the pak's ModActor in every level, yet LoadAsset + StaticFindObject found no M_APWall.
-- Each step is guarded; how it went is noted for the one-time probe line.
local function modAsset(pkg, name, notes)
    local full = pkg .. "." .. name
    local function found()
        local ok, o = pcall(StaticFindObject, full)
        return ok and o and o:IsValid() and o or nil
    end
    local o = found()
    if o then
        notes[#notes + 1] = name .. " already loaded"
        return o
    end
    local ok, got = pcall(function()
        local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if not (helpers and helpers:IsValid()) then return "no AssetRegistryHelpers" end
        local function fname(s) return EFindName and FName(s, EFindName.FNAME_Add) or FName(s) end
        local actor = helpers:GetAsset({ PackageName = fname(pkg), AssetName = fname(name) })
        return actor and actor:IsValid() and actor or "GetAsset gave nothing"
    end)
    if ok and type(got) ~= "string" then
        notes[#notes + 1] = name .. " from the asset registry"
        return got
    end
    notes[#notes + 1] = name .. " registry: " .. tostring(got)
    local okL, err = pcall(LoadAsset, full)
    o = found()
    if o then
        notes[#notes + 1] = name .. " from LoadAsset"
        return o
    end
    notes[#notes + 1] = name .. " LoadAsset " .. (okL and "found nothing" or ("errored: " .. tostring(err)))
end
WALL_SKINS.modAsset = modAsset
-- An asset of the PalworldArchipelagoArt pak by its name (M_APWall, T_APWallPaws, ...), as modAsset finds it.
local function artPakAsset(name, notes)
    return modAsset(ART_PAK .. name, name, notes)
end
local function fadeOn(material)
    material:SetScalarParameterValue(FName("FadeStart"), W.fade[1])
    material:SetScalarParameterValue(FName("FadeEnd"), W.fade[2])
end
local function apWallMaterial()
    if apWall and apWall:IsValid() then return apWall end
    local notes = {}
    local m = artPakAsset("M_APWall", notes)
    if not apWallProbed then
        apWallProbed = true
        local okA, actor = pcall(StaticFindObject, ART_PAK .. "ModActor.ModActor_C")
        local hasActor = okA and actor and actor:IsValid()
        log("wall material probe: " .. (m and "found" or "not found") .. " (" .. table.concat(notes, "; ")
            .. "); ModActor_C " .. (hasActor and "loaded" or "not loaded"))
    end
    if m then
        apWall = m
        keepAs("M_APWall", m)
        return m
    end
end
-- The cream-paw layer: the pak's (with mips), else the PNG (none; the rims may shimmer far off). One for every lock.
local function pawLayerTexture(gameInstance, rendering)
    if pawLayer and pawLayer:IsValid() then return pawLayer end
    local notes = {}
    local t = artPakAsset("T_APWallPaws", notes)
    local from = "the pak, with mips"
    if not (t and t:IsValid()) then
        t = rendering:ImportFileAsTexture2D(gameInstance, W.dir .. "\\walls\\ap-wall-paws-layer.png")
        from = "walls\\ap-wall-paws-layer.png, no mips"
    end
    if not (t and t:IsValid()) then return nil end
    keepAs("paw layer", t)
    pawLayer = t
    log("wall skin paws: the paw layer from " .. from)
    return t
end
-- The pak's name for a region's wall tile, as logicmod/make_wall_material.py names it from
-- logicmod/art/walls/ap-wall-region-<slug>-<version>.png: T_APWallRegion_<slug with _ for ->_<version>.
local function regionTileName(slug, version)
    return "T_APWallRegion_" .. (slug:gsub("%-", "_")) .. "_" .. version
end
-- A region wall's texture from the pak (a region tile or the bunker grille), found once a world; nil when the pak has
-- none (one built before the region walls).
local function regionTile(name)
    local tex = regionTiles[name]
    if tex and tex:IsValid() then return tex end
    tex = artPakAsset(name, {})
    if not (tex and tex:IsValid()) then return nil end
    keepAs("region wall " .. name, tex)
    regionTiles[name] = tex
    return tex
end
-- What a paws look wears (paws:<hex>[:<area>] or paws:sealed): the paw layer over that colour, or the slate grey.
local function pawsLook(name, gameInstance, rendering)
    local tex = pawLayerTexture(gameInstance, rendering)
    if not tex then
        log("wall skin paws: could not load walls\\ap-wall-paws-layer.png")
        return nil
    end
    local hex, own = name:match("^paws:(%x%x%x%x%x%x):?(%d*)$")
    return { texture = tex, back = hex and UTIL.linear(hex) or SEALED, backAlpha = BACK_ALPHA, own = own }
end
-- What a regions look wears (region:<slug>-<version>:<hex>[:<area>] or region:sealed): that region tile over that
-- colour, or the bunker grille; nil (logged) when the pak does not have it.
local function regionLook(name)
    local look
    if name == "region:sealed" then
        look = { texture = regionTile(BUNKER_TILE), back = UTIL.linear(PALETTE.wallBunker),
                 backAlpha = BUNKER_BACK_ALPHA }
    else
        local slug, version, hex, own = name:match("^region:([%w%-]+)%-(%d+):(%x%x%x%x%x%x):?(%d*)$")
        look = { texture = slug and regionTile(regionTileName(slug, version)), back = hex and UTIL.linear(hex),
                 backAlpha = BACK_ALPHA, own = own }
    end
    if not look.texture then
        log("wall skin " .. name .. ": not in the PalworldArchipelagoArt pak (a pak built before the region walls?)")
        return nil
    end
    return look
end
-- The scatter of an area's own number (see SCATTER_A): a fraction from 0 to 1, or nil for a look without one.
local function scatterOf(own)
    if not (own and own ~= "") then return nil end
    local v = math.sin(tonumber(own) * SCATTER_A + 1.0) * SCATTER_B
    return v - math.floor(v)
end
-- Sets a look's layer, back colour (shaded by its scatter), offset and mirror, the fade and the scroll on an M_APWall
-- material. (The scatter, above: never hue, rotation or scale.)
local function putLookOn(material, look)
    local s, back = scatterOf(look.own), look.back
    if s then
        local k = BACK_SHADE + BACK_SHADE_RANGE * s
        back = { R = back.R * k, G = back.G * k, B = back.B * k, A = 1 }
    end
    material:SetTextureParameterValue(FName("Pattern"), look.texture)
    material:SetVectorParameterValue(FName("Back"), back)
    material:SetScalarParameterValue(FName("BackAlpha"), look.backAlpha)
    material:SetScalarParameterValue(FName("Brightness"), BRIGHTNESS)
    if s then
        material:SetScalarParameterValue(FName("OffsetU"), (s * OFFSET_U_RATE) % 1)
        material:SetScalarParameterValue(FName("OffsetV"), (s * OFFSET_V_RATE) % 1)
        material:SetScalarParameterValue(FName("MirrorU"), s > 0.5 and 1 or 0)
    end
    fadeOn(material)
    if W.scroll then
        material:SetScalarParameterValue(FName("ScrollU"), W.scroll[1])
        material:SetScalarParameterValue(FName("ScrollV"), W.scroll[2])
    end
end
-- An M_APWall look (paws:... or region:...): a new copy of M_APWall wearing it (not kept in skin.mids), kept alive in
-- the place for `keepKey`; nil (logged) without the pak or the look's layer.
local function makeApWallMaterial(name, gameInstance, rendering, materials, keepKey)
    local base = apWallMaterial()
    if not base then
        log("wall skin " .. name .. ": needs the PalworldArchipelagoArt pak (M_APWall not found)")
        return nil
    end
    local look
    if name:find("^region:") then
        look = regionLook(name)
    else
        look = pawsLook(name, gameInstance, rendering)
    end
    if not look then return nil end
    local material = materials:CreateDynamicMaterialInstance(gameInstance, base, FName("None"), MID_FLAGS)
    if not (material and material:IsValid()) then
        log("wall skin " .. name .. ": could not make the material")
        return nil
    end
    keepAs(keepKey, material)
    putLookOn(material, look)
    return material
end
local function apWallSkinMaterial(name, gameInstance, rendering, materials)
    local material = makeApWallMaterial(name, gameInstance, rendering, materials, "material " .. name)
    if not material then return nil end
    skin.mids[name], skin.failed[name] = material, nil
    log("wall skin " .. name .. ": material made on M_APWall")
    return material
end
-- An opening piece's material: its M_APWall look (paws or a region wall), dissolving from now over DISSOLVE_S by the
-- game's clock (M_APWall's DissolveStart and DissolveTime against its Time node; an edge glows as it goes). One per
-- look per second, so the pieces an update opens share it; nil for any other skin (those shrink).
function WALL_SKINS.dissolving(name, pawn)
    if not isApWallLook(name) then return nil end
    local ok, now = pcall(function() return pieces.statics():GetTimeSeconds(pawn) end)
    if not (ok and type(now) == "number") then return nil end
    local key = name .. "@" .. math.floor(now)
    local made = dissolveMaterials[key]
    if made and made:IsValid() then return made, dissolveStarts[key] end
    local gameInstance = owner()
    local rendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local materials = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local ready = gameInstance and rendering and rendering:IsValid() and materials and materials:IsValid()
    if not ready then return nil end
    local material = makeApWallMaterial(name, gameInstance, rendering, materials, "dissolve " .. name)
    if not material then return nil end
    material:SetScalarParameterValue(FName("DissolveStart"), now)
    material:SetScalarParameterValue(FName("DissolveTime"), DISSOLVE_S)
    if glowAt then material:SetVectorParameterValue(FName("PlayerPos"), glowAt) end
    dissolveMaterials[key], dissolveStarts[key] = material, now
    once("dissolve", "wall skins: an opened wall dissolves (" .. name .. " from " .. string.format("%.1f", now)
        .. " s)")
    return material, now
end
-- The glow near the player (M_APWall's PlayerPos; keyed to the camera, it sat off to the side of the character): the
-- player's position on the M_APWall materials of pieces shown, each core update (300 ms; a faster loop of our own
-- corrupted Lua's state, see walls.lua's opening pieces), only when the player has moved. The pawn is the core's,
-- handed to W.update; checked each time.
function WALL_SKINS.glowing()
    if pieces.count() == 0 or not apWall then return false end
    return onApWall(skin.now)
end
function WALL_SKINS.glowTick()
    if not WALL_SKINS.glowing() then return end
    local pawn = pieces.pawn()
    if not (pawn and pawn:IsValid()) then return end
    local loc = pawn:K2_GetActorLocation()
    if not (loc and loc.X) then return end
    local moved = glowAt and math.abs(glowAt.R - loc.X) + math.abs(glowAt.G - loc.Y) + math.abs(glowAt.B - loc.Z)
    if moved and moved < GLOW_MOVE_CM then return end
    glowAt = { R = loc.X, G = loc.Y, B = loc.Z, A = 1 }
    -- Only the materials pieces shown now wear (calling every material ever made, those of the world before included,
    -- crashed the game), and the dissolving ones of pieces still there.
    local name, done = FName("PlayerPos"), {}
    local function tell(material)
        if material and not done[material] and material:IsValid() then
            done[material] = true
            material:SetVectorParameterValue(name, glowAt)
        end
    end
    for i in pairs(pieces.raised()) do
        local n = dressedAs[i]
        if n and not pieces.isHidden(i) then
            tell(skin.mids[n])
        end
    end
    for _, piece in ipairs(pieces.opening()) do
        if piece.dissolving and piece.actor:IsValid() then
            tell(piece.material)
        end
    end
end
-- A new world (or the player's pawn changed): every material and handle kept from before is let go, never called
-- again (the world before's materials, dead, called 30 times a second, crashed the game); made again when needed,
-- each in the kept place of the one before (keepAs). The pattern textures stay: the game instance owns them.
function WALL_SKINS.dropCaches()
    skin.mids, skin.failed = {}, {}                             -- (skin.base: the game's own red, an asset, kept)
    skin.now = "red"                                           -- so skinTick dresses the new world's pieces again
    dissolveMaterials, dissolveStarts, glowAt, apWall, pawLayer, regionTiles = {}, {}, nil, nil, nil, {}
end
-- The game instance and the rendering and material libraries a skin's material is made with, once the walls' own
-- material is known; nil and what is missing while any of them is.
local function skinLibraries()
    local gameInstance = owner()
    local rendering = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local materials = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    if not gameInstance then return nil, "no game instance" end
    if not (skin.base and skin.base:IsValid()) then return nil, "the walls' own material is not known yet" end
    if not (rendering and rendering:IsValid()) then return nil, "no KismetRenderingLibrary" end
    if not (materials and materials:IsValid()) then return nil, "no KismetMaterialLibrary" end
    return gameInstance, rendering, materials
end
-- An area material's tint and pattern file, by its name (see pieceSkin): a lock's colour, sealed grey, or the teal
-- lattice (a).
local function patternFor(name)
    local hex = name:match("^area:(%x%x%x%x%x%x)$")
    if hex then
        areaFile = areaFile or patternOr("pawholes")
        return UTIL.linear(hex), areaFile
    end
    if name == "sealed" then
        sealedFile = sealedFile or patternOr("sealed")
        return SEALED, sealedFile
    end
    if name == "a" then
        return TEAL, "a"
    end
    error("wall skin: no pattern for " .. tostring(name))
end
-- A pattern file's texture, loaded once a session (owned by the game instance, kept alive), and whether it could be
-- made linear (the game's pattern is); nil (logged for `name`) when it cannot be loaded.
local function patternTexture(name, file, gameInstance, rendering)
    local loaded = patternTextures[file]
    if loaded and UTIL.isValid(loaded.texture) then return loaded.texture, loaded.linear end
    local path = W.dir .. "\\walls\\ap-wall-pattern-" .. file .. ".png"
    local tex = rendering:ImportFileAsTexture2D(gameInstance, path)
    if not (tex and tex:IsValid()) then
        log("wall skin " .. name .. ": could not load " .. path)
        return nil
    end
    local linear = pcall(function()
        tex.SRGB = false
        tex:UpdateResource()
    end)
    keepAs("pattern " .. file, tex)
    patternTextures[file] = { texture = tex, linear = linear }
    return tex, linear
end
-- An area material: a dynamic copy of the walls' own material with the pattern and tint set; nil (logged)
-- when the pattern or the material cannot be made.
local function makePatternMaterial(name, gameInstance, rendering, materials)
    local tint, file = patternFor(name)
    local tiling = W.tiling
    local tex, srgb = patternTexture(name, file, gameInstance, rendering)
    if not tex then return nil end
    local material = materials:CreateDynamicMaterialInstance(gameInstance, skin.base, FName("None"), MID_FLAGS)
    if not (material and material:IsValid()) then
        log("wall skin " .. name .. ": could not make the material")
        return nil
    end
    keepAs("material " .. name, material)
    material:SetTextureParameterValue(FName("MainTexture01"), tex)
    local night = { R = tint.R * NIGHT, G = tint.G * NIGHT, B = tint.B * NIGHT, A = 1 }
    for param, colour in pairs({ Color = tint, DayColor = tint, NightColor = night }) do
        material:SetVectorParameterValue(FName(param), colour)
    end
    if tiling then
        material:SetScalarParameterValue(FName("TilingU_01"), tiling[1])
        material:SetScalarParameterValue(FName("TilingV_01"), tiling[2])
    end
    if W.scroll then
        material:SetScalarParameterValue(FName("ScrollingU_01"), W.scroll[1])
        material:SetScalarParameterValue(FName("ScrollingV_01"), W.scroll[2])
    end
    skin.mids[name], skin.failed[name] = material, nil
    -- Blueprint_GetSizeX/Y: Lua sees only UFunctions (GetSurfaceWidth is C++ only, and calling it from Lua
    -- errors).
    local okw, size = pcall(function() return tex:Blueprint_GetSizeX() .. "x" .. tex:Blueprint_GetSizeY() end)
    log("wall skin " .. name .. ": material made (" .. (okw and size or "size unknown")
        .. (srgb and ", linear" or ", sRGB: could not change") .. ", tiling "
        .. (tiling and (tiling[1] .. "x" .. tiling[2]) or "the material's") .. ")")
    return material
end
-- A skin's material, made on first use; nil when it cannot be made (tried once a world: W.dropCaches empties failed).
local function skinMaterial(name)
    local material = skin.mids[name]
    if material and material:IsValid() then return material end
    if skin.failed[name] then return nil end
    skin.failed[name] = true                                   -- one try per skin per world; cleared on success
    local gameInstance, rendering, materials = skinLibraries()
    if not gameInstance then
        log("wall skin " .. name .. ": " .. rendering .. " yet; tried again later")
        skin.failed[name] = nil
        return nil
    end
    if isApWallLook(name) then return apWallSkinMaterial(name, gameInstance, rendering, materials) end
    return makePatternMaterial(name, gameInstance, rendering, materials)
end
-- Puts the current skin on one piece (a new piece, or every raised one when the skin changes).
local function dress(actor, material)
    local m = meshOf(actor)
    if not m then return false end
    -- the red original, before any change
    if not skin.base then
        skin.base = m:GetMaterial(0)
        W.keepAlive(skin.base)
    end
    m:SetMaterial(0, material or skin.base)
    return true
end
-- The lock whose colour a piece between a1 and a2 wears: the locked side when only one is locked; otherwise (both
-- locked, or neither: such a piece is not standing) a1, unless a1 is beyond the goal: then a2.
local function wornLock(a1, a2, passes)
    local locked1, locked2 = not isOpen(a1, passes), not isOpen(a2, passes)
    if locked1 and not locked2 then return a1 end
    if locked2 and not locked1 then return a2 end
    if W.beyond[a1] then return a2 end
    return a1
end
-- The version of its region's wall an area wears (75 areas), from wall_region_variants.lua; 0, said once, for an area
-- the table does not have.
local function areaVersion(area)
    areaVersions = areaVersions or require("wall_region_variants")
    local row = areaVersions[area]
    if row then return row.version end
    UTIL.took("wall skin regions: " .. area .. "'s version", "0 (not in wall_region_variants.lua)")
    return 0
end
-- A regions look's name for a piece wearing `lock` (lockIndex: its number in the cut):
-- region:<region slug>-<version>:<hex>[:<lockIndex>], or region:sealed beyond the goal. The 15 regions wear version 0;
-- an area its own version, and its number for the scatter as paws (not the area named as its region).
local function regionLookName(lock, lockIndex)
    if W.beyond[lock] then return "region:sealed" end
    local region = W.regionOf(lock)
    local version, own = 0, ""
    if W.layout == "areas" then
        version = areaVersion(lock)
        if region ~= lock then own = ":" .. lockIndex end
    end
    local hex = REGION_COLOURS[region] or PALETTE.teal                -- a lock without a colour: the start's teal
    return "region:" .. slugOf(region) .. "-" .. version .. ":" .. hex .. own
end
-- The material a piece wears with a skin by area, by name: region:... (see regionLookName), paws:<hex>[:<area>],
-- paws:sealed, area:<hex>, sealed, or a (a lock without a colour).
local function pieceSkin(i, passes, mode)
    local wall = layout.walls[i]
    local a1, a2 = layout.locks[wall.lockA + 1], layout.locks[wall.lockB + 1]
    local lock = wornLock(a1, a2, passes)
    if mode == "regions" then return regionLookName(lock, lock == a1 and wall.lockA or wall.lockB) end
    local hex = REGION_COLOURS[W.regionOf(lock)]
    if mode == "paws" then
        if W.beyond[lock] then return "paws:sealed" end
        -- 75 Areas: each Area its Region's look, varied by its own number (pattern offset, mirror, Back shade).
        local own = ""
        if W.layout == "areas" and W.regionOf(lock) ~= lock then
            own = ":" .. (lock == a1 and wall.lockA or wall.lockB)
        end
        return "paws:" .. (hex or PALETTE.teal) .. own         -- a lock without a colour: the start island's teal
    end
    if W.beyond[lock] then return "sealed" end
    return hex and ("area:" .. hex) or "a"
end
WALL_SKINS.pieceSkin = pieceSkin
-- With a skin by area: that piece's own material (made on first use; the teal lattice if it can't be made).
local function areaDress(actor, i, passes, mode)
    local name = pieceSkin(i, passes or {}, mode)
    local material = skinMaterial(name)
    if not material and name ~= "a" then
        UTIL.took("wall skin " .. name, "the teal lattice (a) instead: its own material could not be made")
        name, material = "a", skinMaterial("a")
    end
    if material and dress(actor, material) then dressedAs[i] = name end
end
-- Dresses a piece just raised (i: its index) in the skin worn now (red needs nothing: a new piece wears it); an error
-- is logged once, not raised.
function WALL_SKINS.skinNew(actor, i)
    if not (byArea(skin.now) and i) then return end
    local ok, err = pcall(areaDress, actor, i, pieces.passes(), skin.now)
    if not ok then
        UTIL.onceErr("walls:skinnew", err, "wall skin " .. skin.now .. ": could not dress a new piece: "
            .. tostring(err))
    end
end
-- A pass that opens one side of a piece still up turns it to the other side's colour; so does the list of locks
-- beyond the goal arriving. A few pieces an update (RECOLOUR), only after something changed: the trigger is the number
-- of passes held and the locks beyond the goal (passes are only ever added, so a new one changes the count).
-- A piece with both sides open is left as it is: walls.lua is about to open it (a few an update, so this pass can get
-- there first), and its dissolve takes the colour it wears, the one the player saw.
local RECOLOUR = 40
function WALL_SKINS.recolour(passes)
    if not byArea(skin.now) then return end
    local n = 0
    for _ in pairs(passes) do n = n + 1 end
    local sig = n .. "/" .. beyondSig()
    if sig ~= passSig then passSig, recolourAt = sig, 1 end
    if not recolourAt then return end
    local budget = RECOLOUR
    while recolourAt <= #layout.walls and budget > 0 do
        local i, actor = recolourAt, pieces.raised()[recolourAt]
        recolourAt = i + 1                 -- before the calls that can fail: a piece that errors is passed over
        local stillUp = standing(layout.walls[i], passes)
        if stillUp and actor and actor:IsValid() and dressedAs[i] ~= pieceSkin(i, passes, skin.now) then
            local ok, err = pcall(areaDress, actor, i, passes, skin.now)
            if not ok then
                UTIL.onceErr("walls:recolour", err, "wall skin " .. skin.now .. ": could not recolour piece " .. i
                    .. ": " .. tostring(err))
            end
            budget = budget - 1
        end
    end
    if recolourAt > #layout.walls then recolourAt = nil end
end
-- Empty or unset: regions (paws with a pak built before the region walls, area without the pak); wall_skin=red for the
-- game's own red grid.
WALL_SKINS.DEFAULT_SKIN = "regions"
local function isSkin(name)
    for _, known in ipairs(SKINS) do
        if known == name then return true end
    end
    return false
end
-- The skin config.txt asks for (wall_skin), put on at the next update. A name that is not a skin (a typo, or one
-- this mod no longer has) is logged and the default worn instead.
function WALL_SKINS.setSkin(name)
    if name == "" or name == nil then name = WALL_SKINS.DEFAULT_SKIN end
    if not isSkin(name) then
        log("wall skin " .. tostring(name) .. ": unknown (" .. table.concat(SKINS, ", ") .. "); the default, "
            .. WALL_SKINS.DEFAULT_SKIN .. ", instead")
        name = WALL_SKINS.DEFAULT_SKIN
    end
    skin.want = name
end
-- The next skin, skipping any refused in this world (regions without the region walls in the pak, paws without the
-- pak): it would be refused again and the cycle would stop there.
function WALL_SKINS.cycleSkin()
    local at = nil
    for k, name in ipairs(SKINS) do
        if name == skin.want then at = k end
    end
    if not at then return nil end
    for j = 1, #SKINS do
        local nxt = SKINS[(at + j - 1) % #SKINS + 1]
        if not skin.failed[nxt] then
            skin.want = nxt
            return nxt
        end
    end
end
-- Dresses one raised piece in the skin wanted (red: the walls' own material). True when it is dressed; else false
-- and the error, if there was one.
local function dressOne(actor, i)
    if byArea(skin.want) then
        local ok, err = pcall(areaDress, actor, i, pieces.passes(), skin.want)
        return ok and dressedAs[i] ~= nil, not ok and err or nil
    end
    local ok, done = pcall(dress, actor, nil)
    dressedAs[i] = nil
    return ok and done, not ok and done or nil
end
-- The walls' own red material, learnt from the first piece raised (the original, before any change). False until then.
local function learnBaseMaterial()
    if skin.base then return true end
    local _, actor = next(pieces.raised())
    if not actor then return false end
    local m = meshOf(actor)
    skin.base = m and m:GetMaterial(0)
    if not skin.base then return false end
    W.keepAlive(skin.base)
    return true
end
-- regions without the region walls in the pak (one built before them, or no pak): paws instead, and Ctrl+F3 skips
-- regions from then on. False when that leaves nothing to change.
local function regionsOrPaws()
    if skin.want ~= "regions" then return true end
    if apWallMaterial() and regionTile(BUNKER_TILE) then
        skin.failed.regions = nil
        return true
    end
    log("wall skin regions: the PalworldArchipelagoArt pak has no region walls (or is not there); paws instead")
    skin.failed.regions, skin.want = true, "paws"
    return skin.want ~= skin.now
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
-- Dresses every raised piece in the skin wanted. Returns how many were dressed, how many not, and the first error.
local function dressAll()
    local n, bad, firstErr = 0, 0, nil
    for i, actor in pairs(pieces.raised()) do
        if actor:IsValid() then
            local done, err = dressOne(actor, i)
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
    log("wall skin " .. skin.now .. ": on " .. n .. " pieces"
        .. (bad > 0 and (", " .. bad .. " not dressed" .. why) or ""))
end
-- On the game thread (from W.update): the skin wanted, once the wall material is known (from the first piece raised).
function WALL_SKINS.skinTick()
    if skin.want == skin.now then return end
    if not learnBaseMaterial() then return end
    if not regionsOrPaws() then return end
    if not pawsOrArea() then return end
    local n, bad, firstErr = dressAll()
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
    layout, isOpen, REGION_COLOURS = env.locks.layout, env.locks.isOpen, env.locks.REGION_COLOURS
    beyondSig, standing, slugOf = env.locks.beyondSig, env.locks.standing, env.locks.slugOf
    PALETTE = env.locks.PALETTE
    SEALED, TEAL = UTIL.linear(PALETTE.wallSealed), UTIL.linear(PALETTE.teal)
    W.tiling, W.scroll = nil, nil                                  -- { u, v } from config.txt, or the material's own
    -- M_APWall's fade, far enough out that a wall does not seem to load in right beside the player: fully there within
    -- W.fade[1] cm, gone at W.fade[2] (config wall_fade=near,far in metres).
    W.fade = { 1500, 2500 }
end

return WALL_SKINS
