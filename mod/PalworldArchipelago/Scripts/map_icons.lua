-- The locked areas as icons on the map screen: a stamp at each locked area, an open stamp at each area unlocked but not
-- yet stood in, added with the screen's own Add Icon By Location so they keep one size at every zoom. A part of
-- walls.lua (with map_picture.lua, which calls it each map update), loaded fresh for each copy of walls.lua.
-- Tests: mod/test/harness.lua, group "the world map".
local MAP_ICONS = {}
local UTIL = require("util")
local ART = require("art")
local log = UTIL.log
-- Handed over by install: W (settings: iconsOff; data: beyond, visited), and the areas part's layout and lists.
local W, layout, slugOf, lockedList, openList = nil, nil, nil, nil, nil

-- The locked areas are shown as the map's own icons (placeIcons, below) unless config.txt has map_icons=0 or the icons
-- failed; then the stamps are drawn into the picture and the chart fog, as before.
local iconsFailed = false
local function iconsActive() return not W.iconsOff and not iconsFailed end
-- An area beyond the goal: the sealed stamp; a region: its area's; the shared one when there is none.
local function stampTexture(k)
    local name = layout.areas[k + 1]
    if not name then return nil end
    return (W.beyond[name] and ART.texture("ap-map-stamp-sealed"))
        or (not W.beyond[name] and ART.texture("ap-map-stamp-" .. slugOf(W.parentOf(name))))
        or ART.texture("ap-map-stamp")
end

-- The locked areas as the map's own icons (the user, 2026-11-07: stamps drawn into the picture grew and shrank with
-- the zoom, unlike the game's icons, and many sat in odd places). The map screen's "Add Icon By Location" (pak, 2026-11-07)
-- puts an icon at a world location on one of its icon canvases at 64x64, and its "Update Map Icons" (run on every scroll
-- and zoom) scales everything on those canvases by 1 / the map's scale, so icons keep one size on screen. IgnoreMask
-- puts it on the canvas the fog never hides. The icon is the game's plain one (WBP_WorldMap_IconBase_OnlyIcon: an image
-- and an invisible button; ChangeTexture sets the image). Each goes at its area's deepest point (the fog no longer hides
-- it, so it no longer needs the side nearest the start). It ignores the pointer: hovering would open the game's info box
-- with nothing in it. The map screen lasts until the world closes (dev.17 log: built at the first opening, destroyed at
-- Return to title), so the icons are added once per screen, and again when a pass changes the locked set or the game
-- drops them. UNTESTED IN GAME: if anything fails, the stamps are drawn into the picture again (iconsFailed).
local ICON_ASSET = "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_WorldMap_IconBase_OnlyIcon.WBP_WorldMap_IconBase_OnlyIcon"
-- Unlocked areas the player has not stood in yet get an open stamp (the user, 2026-11-07: "some other image type ... to
-- show that a region has been unlocked, even when it is unexplored"; go): the Art lane's ap-map-stamp-open-<area>.png
-- (or ap-map-stamp-open.png), none until there is one. W.visited: the core's set of areas stood in (in its save).
local function openTexture(k)
    local name = layout.areas[k + 1]
    local own = name and ("ap-map-stamp-open-" .. slugOf(W.parentOf(name)))
    if own and ART.file(own) ~= "" then return ART.texture(own) end
    if ART.file("ap-map-stamp-open") ~= "" then return ART.texture("ap-map-stamp-open") end
    return nil
end
-- The icons on each live main-map screen: its address -> { key = the look they show, list = the icon widgets }.
-- Forgotten: a screen's entry once the screen is no longer listed (forgetIconsOfGoneScreens), every entry once the
-- icons fail. A screen is known by its address, which the engine reuses; a screen gone is never called again.
local mapIcons = {}
-- A map point (0-1 across and down the 4096 map) as a world location (game-systems: pixel = ((Y + 724400) / 1448800,
-- (349400 - X) / 1448800) of the map's width).
local function worldAt(u, v) return { X = 349400 - v * 1448800, Y = u * 1448800 - 724400, Z = 0 } end
MAP_ICONS.worldAt = worldAt                                       -- (for the harness)
-- Forgets the icons, without calling them, of every screen that is not among this update's live screens: they went
-- with the last world (Return to title). Not on the core's reset: that also runs when the pawn reads nil for a moment
-- in the same world, where the icons are still on the screen and would be added twice.
local function forgetIconsOfGoneScreens(screens)
    local live = {}
    for _, b in ipairs(screens) do
        live[UTIL.addr(b) or ""] = true
    end
    for addr in pairs(mapIcons) do
        if not live[addr] then
            mapIcons[addr] = nil
        end
    end
end
-- Takes one screen's icons off it (live widgets only: forgetIconsOfGoneScreens has dropped the gone ones).
local function clearIcons(icons)
    for _, icon in ipairs(icons.list) do
        pcall(function()
            if icon:IsValid() then
                icon:RemoveFromParent()
            end
        end)
    end
end
-- Whether a screen's icons are for this key and still on it (the game can drop them).
local function iconsStillShown(icons, key)
    if icons.key ~= key then
        return false
    end
    local first = icons.list[1]
    if not first then
        return true
    end
    local ok, still = pcall(function() return first:IsValid() and first:GetParent():IsValid() end)
    return ok and still
end
-- The game's plain map icon class, loaded when first needed; raises an error when it cannot be found.
local function iconClass()
    local cls = StaticFindObject(ICON_ASSET .. "_C")
    if not (cls and cls:IsValid()) then pcall(LoadAsset, ICON_ASSET); cls = StaticFindObject(ICON_ASSET .. "_C") end
    if not (cls and cls:IsValid()) then error("no icon class " .. ICON_ASSET .. "_C") end
    return cls
end
-- Adds an icon showing `tex` at the point c (an area's centre row) to the screen and to icons.list; true when the
-- screen says it is shown. Raises an error when the icon cannot be made.
local function addIcon(screen, icons, cls, wbl, c, tex)
    local icon = wbl:Create(screen, cls, nil)
    if not (icon and icon:IsValid()) then error("could not make a map icon") end
    icon:ChangeTexture(tex)
    local out = {}
    screen["Add Icon By Location"](screen, icon, worldAt(c[1], c[2]), true, false, out)
    pcall(function() icon:SetVisibility(3) end)        -- HitTestInvisible
    icons.list[#icons.list + 1] = icon
    return out.Added
end
-- Puts this look's icons on one screen, unless they are there already: a locked stamp at each locked area, an open
-- stamp at each area unlocked but not stood in. Raises an error when an icon cannot be made.
local function placeIcons(screen, passes, key)
    local addr = UTIL.addr(screen)
    local icons = mapIcons[addr]
    if icons and iconsStillShown(icons, key) then
        return
    end
    if icons then
        clearIcons(icons)
    end
    icons = { key = key, list = {} }
    mapIcons[addr] = icons
    local cls = iconClass()
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local added, shown = 0, 0
    for _, k in ipairs(lockedList(passes)) do
        local c, tex = layout.centres[k], stampTexture(k)
        if c and tex then
            if addIcon(screen, icons, cls, wbl, c, tex) then shown = shown + 1 end
            added = added + 1
        end
    end
    local opened = 0
    for _, k in ipairs(openList(passes)) do
        local c, tex = layout.centres[k], openTexture(k)
        if c and tex then
            addIcon(screen, icons, cls, wbl, c, tex)
            opened = opened + 1
        end
    end
    screen["Update Map Icons"](screen)          -- each icon's scale for the current zoom (the game does it on scroll/zoom)
    local where = ""
    local okw, parent = pcall(function() return icons.list[1] and icons.list[1]:GetParent():GetFName():ToString() end)
    if okw and parent then where = " on " .. parent end
    log("map icons: " .. added .. " locked area(s) added" .. where .. " (" .. shown .. " said visible), " .. opened
        .. " open not yet visited")
end

-- Each map update with a live main-map screen: the icons on every such screen, for this look (key). If they cannot be
-- added, they are taken off and the stamps are drawn into the picture instead, for the session.
function MAP_ICONS.show(screens, passes, key)
    if not iconsActive() then
        return
    end
    forgetIconsOfGoneScreens(screens)
    local iconKey = key .. "#open:" .. table.concat(openList(passes), ",")
    local oki, erri = pcall(function()
        for _, b in ipairs(screens) do
            placeIcons(b, passes, iconKey)
        end
    end)
    if not oki then
        iconsFailed = true
        for _, icons in pairs(mapIcons) do
            clearIcons(icons)
        end
        mapIcons = {}
        log("map icons: could not add them (" .. tostring(erri) .. "); drawing the stamps on the map instead")
    end
end

-- Hands over what this part reads (see the top of the file).
function MAP_ICONS.install(env)
    W = env.W
    local areas = env.areas
    layout, slugOf, lockedList, openList = areas.layout, areas.slugOf, areas.lockedList, areas.openList
end

MAP_ICONS.active, MAP_ICONS.stampTexture = iconsActive, stampTexture
return MAP_ICONS
