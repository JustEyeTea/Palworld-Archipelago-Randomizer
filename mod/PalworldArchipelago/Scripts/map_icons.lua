-- The locks still locked as icons on the map screen: a stamp at each, an open stamp at each lock unlocked but not
-- yet stood in, added with the screen's own Add Icon By Location so they keep one size at every zoom. A part of
-- walls.lua (with map_picture.lua, which calls it each map update), loaded fresh for each copy of walls.lua.
-- Tests: mod/test/tests/map.lua; group "the world map" (tools/lua_harness.sh, in CI).
local MAP_ICONS = {}
local UTIL = require("util")
local ART = require("art")
local log = UTIL.log
local HIT_TEST_INVISIBLE = 3  -- ESlateVisibility::HitTestInvisible: hovering would open the game's empty info box

-- State: the icons. Forgotten: iconsFailed never (after a failure the stamps are drawn for the session).
-- The locks still locked are shown as the map's own icons (placeIcons, below) unless config.txt has map_icons=0 or
-- the icons failed; then the stamps are drawn into the picture and the chart fog.
local iconsFailed = false
-- The icons on each live main-map screen: its key (screenKey) -> { key = the look they show, list = the icon
-- widgets }. Forgotten: a screen's entry once the screen is no longer listed (forgetIconsOfGoneScreens), every entry
-- once the icons fail. A screen is known by its address and its owning player's, since the engine reuses addresses:
-- a new world's screen at the old one's address has a new owner, and a screen gone is never called again.
local mapIcons = {}
-- Handed over by install: W (settings: iconsOff; data: beyond, visited), and the locks part's layout and lists.
local W, layout, slugOf, lockedList, openList = nil, nil, nil, nil, nil

local function iconsActive() return not W.iconsOff and not iconsFailed end
-- A lock beyond the goal: the sealed stamp; a lock: its region's (an area wears its region's); the shared one when
-- there is none.
local function stampTexture(k)
    local name = layout.locks[k + 1]
    if not name then return nil end
    return (W.beyond[name] and ART.texture("ap-map-stamp-sealed"))
        or (not W.beyond[name] and ART.texture("ap-map-stamp-" .. slugOf(W.regionOf(name))))
        or ART.texture("ap-map-stamp")
end

local ICON_ASSET = "/Game/Pal/Blueprint/UI/WorldMap/IconWidgets/WBP_WorldMap_IconBase_OnlyIcon."
    .. "WBP_WorldMap_IconBase_OnlyIcon"
-- Unlocked locks the player has not stood in yet get an open stamp, so the map shows a lock is unlocked even while it
-- is unexplored: ap-map-stamp-open-<region>.png (or ap-map-stamp-open.png), none until there is one. W.visited: the
-- core's set of locks stood in (in its save).
local function openTexture(k)
    local name = layout.locks[k + 1]
    local own = name and ("ap-map-stamp-open-" .. slugOf(W.regionOf(name)))
    if own and ART.file(own) ~= "" then return ART.texture(own) end
    if ART.file("ap-map-stamp-open") ~= "" then return ART.texture("ap-map-stamp-open") end
    return nil
end
-- A map point (0-1 across and down the map square) as a world location, from the map's bounds (layout.bounds, as
-- *_map.lua writes them): world X runs from xMax at the top down to xMin, world Y from yMin at the left across to yMax.
local function worldAt(u, v)
    local b = layout.bounds
    return { X = b.xMax - v * (b.xMax - b.xMin), Y = b.yMin + u * (b.yMax - b.yMin), Z = 0 }
end
MAP_ICONS.worldAt = worldAt                                       -- (for the harness)
-- A live screen's key in mapIcons: its address and its owning player's ("?" when that can't be read). A pawn change
-- in the same world keeps its player controller, so the icons are not added twice then.
local function screenKey(screen)
    local okOwner, owner = pcall(function() return screen:GetOwningPlayer() end)
    return (UTIL.addr(screen) or "") .. "@" .. ((okOwner and UTIL.addr(owner)) or "?")
end
-- Forgets the icons, without calling them, of every screen that is not among this update's live screens: they went
-- with the last world (Return to title). Not on the core's reset: that also runs when the pawn reads nil for a moment
-- in the same world, where the icons are still on the screen and would be added twice.
local function forgetIconsOfGoneScreens(screens)
    local live = {}
    for _, b in ipairs(screens) do
        live[screenKey(b)] = true
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
-- The locks still locked as the map's own icons, because stamps drawn into the picture grew and shrank with the zoom,
-- unlike the game's icons, and many sat in odd places. The map screen's "Add Icon By Location" (pak) puts an icon at a
-- world location on one of its icon canvases at 64x64, and its "Update Map Icons" (run on every scroll and zoom) scales
-- everything on those canvases by 1 / the map's scale, so icons keep one size on screen. IgnoreMask puts it on the
-- canvas the fog never hides. The icon is the game's plain one (WBP_WorldMap_IconBase_OnlyIcon: an image and an
-- invisible button; ChangeTexture sets the image). Each goes at its lock's deepest point (the fog no longer hides it,
-- so it no longer needs the side nearest the start). It ignores the pointer: hovering would open the game's info box
-- with nothing in it. The map screen lasts until the world closes (built at the first opening, destroyed at Return to
-- title), so the icons are added once per screen, and again when a pass changes the locked set or the game drops them.
-- If anything fails, the stamps are drawn into the picture again (iconsFailed).
-- The game's plain map icon class, loaded when first needed; raises an error when it cannot be found.
local function iconClass()
    local class = StaticFindObject(ICON_ASSET .. "_C")
    if not (class and class:IsValid()) then
        pcall(LoadAsset, ICON_ASSET)
        class = StaticFindObject(ICON_ASSET .. "_C")
    end
    if not (class and class:IsValid()) then error("no icon class " .. ICON_ASSET .. "_C") end
    return class
end
-- Adds an icon showing `tex` at a lock's centre to the screen and to icons.list; true when the
-- screen says it is shown. Raises an error when the icon cannot be made.
local function addIcon(screen, icons, class, widgetLibrary, centre, tex)
    local icon = widgetLibrary:Create(screen, class, nil)
    if not (icon and icon:IsValid()) then error("could not make a map icon") end
    icon:ChangeTexture(tex)
    local out = {}
    screen["Add Icon By Location"](screen, icon, worldAt(centre.deepU, centre.deepV), true, false, out)
    pcall(function() icon:SetVisibility(HIT_TEST_INVISIBLE) end)
    icons.list[#icons.list + 1] = icon
    return out.Added
end
-- Puts this look's icons on one screen, unless they are there already: a locked stamp at each lock still locked, an
-- open stamp at each lock unlocked but not stood in. Raises an error when an icon cannot be made.
local function placeIcons(screen, passes, key)
    local addr = screenKey(screen)
    local icons = mapIcons[addr]
    if icons and iconsStillShown(icons, key) then
        return
    end
    if icons then
        clearIcons(icons)
    end
    icons = { key = key, list = {} }
    mapIcons[addr] = icons
    local class = iconClass()
    local widgetLibrary = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local added, shown = 0, 0
    for _, k in ipairs(lockedList(passes)) do
        local centre, tex = layout.centres[k], stampTexture(k)
        if centre and tex then
            if addIcon(screen, icons, class, widgetLibrary, centre, tex) then shown = shown + 1 end
            added = added + 1
        end
    end
    local opened = 0
    for _, k in ipairs(openList(passes)) do
        local centre, tex = layout.centres[k], openTexture(k)
        if centre and tex then
            addIcon(screen, icons, class, widgetLibrary, centre, tex)
            opened = opened + 1
        end
    end
    screen["Update Map Icons"](screen)   -- each icon's scale for the current zoom (the game does it on scroll and zoom)
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
    local locks = env.locks
    layout, slugOf, lockedList, openList = locks.layout, locks.slugOf, locks.lockedList, locks.openList
end

MAP_ICONS.active, MAP_ICONS.stampTexture = iconsActive, stampTexture
return MAP_ICONS
