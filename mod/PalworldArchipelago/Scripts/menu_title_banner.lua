-- The title menu's banner: its art above the title buttons, the connection in its status pill (a dot tinted by state
-- and a line of text), its tint and pop under the pointer, and its place over the button list. Used by menu_title.lua.
-- Tests: mod/test/tests/title_menu.lua; group "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local BANNER = {}
local ART = require("art")
local UTIL = require("util")
local WIDGETS = require("widgets")
local NAMES = require("menu_names")
local MENU_WIDTH = NAMES.MENU_WIDTH
local BANNER_HEIGHT = NAMES.BANNER_HEIGHT
local BANNER_GAP = NAMES.BANNER_GAP
local log = UTIL.log
local className, nameOf = WIDGETS.className, WIDGETS.nameOf
local HALIGN, VALIGN = WIDGETS.HALIGN, WIDGETS.VALIGN

-- What main.lua hands over, through menu.lua and menu_title.lua (BANNER.install): see menu.lua.
local api

function BANNER.install(functions)
    api = functions
end

-- The banner (art/ap-title-banner.png) above the title buttons, with the connection in its pill: a dot
-- (art/ap-status-dot.png) tinted by state and a line of text, at the art's own places (the pill spans x 140-575,
-- y 107-133 at 600x150; the dot is centred at 155,120 and the text starts at 167). It goes on the canvas the list sits
-- in (CanvasPanelMenu on the client), its bottom BANNER_GAP above the list's top, worked out from the list's slot each
-- update (our Disconnect row changes the list's height): in the list it would go after the game's buttons too and push
-- ours off the screen. Only when the list is not on a canvas (or is stretched across it) does it go in the list.
local DOT_SIZE = 12
local DOT_AT = { x = 149, y = 114 }                           -- the dot's top-left corner on the banner
local TEXT_AT = { x = 167, y = 111, right = 24 }              -- the status text's place on the banner
local BANNER_TEXT_SIZE = 13
local DOT = { connected = UTIL.linear("#4DD07A"), connecting = UTIL.linear("#ECBE6E"), other = UTIL.linear("#EF6A5B") }
BANNER.TEXT_COLOUR = UTIL.linear("#E8F4F2")      -- the banner's status text, and the typed rows' labels
-- The banner waits a little dim, and is full (and a little bigger: a pop about its centre) while the pointer or the
-- keyboard is on it, with the hover picture (art/ap-title-banner-hover.png) when there is one: so it shows it can be
-- clicked.
local BANNER_DIM = { R = 0.78, G = 0.78, B = 0.78, A = 1 }
local BANNER_LIT = { R = 1, G = 1, B = 1, A = 1 }
local BANNER_POP, BANNER_REST = { X = 1.04, Y = 1.04 }, { X = 1, Y = 1 }

-- State: the pointer and the banner. Forgotten: bannerPressed at the end of every update (BANNER.endPress);
-- bannerHovered when the pointer leaves.
local bannerPressed = false   -- the banner was just clicked: its pressed picture until the end of the update
local bannerHovered = nil     -- the banner button's address while the pointer (or focus) is on it

-- A banner's record, with every field it has.
local function newBanner(box, list, over, picture)
    return {
        box = box,              -- its size box, MENU_WIDTH x BANNER_HEIGHT
        list = list,            -- the button list it sits above
        over = over,            -- the overlay inside it: the picture, the dot, the text, the button
        picture = picture,
        dot = nil,              -- the status dot's image, or nil without its file
        text = nil,             -- the status text
        slot = nil,             -- its canvas slot, or nil when it is in the list
        at = nil,               -- where it was last placed on the canvas
        textNow = nil,          -- the status text shown
        stateNow = nil,         -- the connection state the dot shows
        lit = nil,              -- it is lit (the pointer on it)
        pictureNow = nil,       -- the art shown: the banner, its hover or its pressed picture
    }
end

-- The top-centre point of the button list on its canvas, with the list's anchors. Raises an error when the list's slot
-- can't tell (no canvas slot, or anchors stretched across the canvas).
function BANNER.listTop(list)
    local listSlot = list.Slot
    local anchors, alignment, position = listSlot:GetAnchors(), listSlot:GetAlignment(), listSlot:GetPosition()
    if anchors.Minimum.X ~= anchors.Maximum.X or anchors.Minimum.Y ~= anchors.Maximum.Y then
        error("the button list is stretched on its canvas")
    end
    local size = list:GetDesiredSize()
    local copy = { Minimum = { X = anchors.Minimum.X, Y = anchors.Minimum.Y },
                   Maximum = { X = anchors.Maximum.X, Y = anchors.Maximum.Y } }
    return copy, { X = position.X + (0.5 - alignment.X) * size.X, Y = position.Y - alignment.Y * size.Y }
end

-- Where the banner's bottom-centre goes: BANNER_GAP above the list's top.
local function bannerSpot(list)
    local anchors, top = BANNER.listTop(list)
    return anchors, { X = top.X, Y = top.Y - BANNER_GAP }
end

local function placeBanner(banner)
    if not banner.slot then return end
    local anchors, at = bannerSpot(banner.list)
    if banner.at and banner.at.X == at.X and banner.at.Y == at.Y then return end
    banner.slot:SetAnchors(anchors)
    banner.slot:SetAlignment({ X = 0.5, Y = 1 })
    banner.slot:SetPosition(at)
    banner.at = at
end

-- The banner's picture in an overlay of its own, filling it (not the brush's 32x32); nil without the art.
local function makeBanner(menu, list)
    local box, picture = ART.box(menu, "ap-title-banner", MENU_WIDTH, BANNER_HEIGHT)
    if not box then return nil end
    local over = WIDGETS.construct(WIDGETS.UMG.overlay, menu)
    box:RemoveChild(picture)
    box:AddChild(over)
    WIDGETS.fill(over:AddChild(picture))
    pcall(function() picture:SetColorAndOpacity(BANNER_DIM) end)
    return newBanner(box, list, over, picture)
end

local function addStatusDot(banner, menu)
    local dotBox, dot = ART.box(menu, "ap-status-dot", DOT_SIZE, DOT_SIZE)
    if not dotBox then return end
    WIDGETS.place(banner.over, dotBox, DOT_AT.x, DOT_AT.y)
    banner.dot = dot
end

-- The status text; whether its font could be set (else it is scaled down from the default size).
local function addStatusText(banner, menu)
    local text = WIDGETS.construct(WIDGETS.UMG.textBlock, menu)
    local sized = WIDGETS.setFontSize(text, BANNER_TEXT_SIZE, { X = 0, Y = 0.5 })
    pcall(function()
        text:SetColorAndOpacity({ SpecifiedColor = BANNER.TEXT_COLOUR, ColorUseRule = WIDGETS.COLOUR_RULE.specified })
    end)
    local slot = banner.over:AddChild(text)
    pcall(function()
        slot:SetHorizontalAlignment(HALIGN.left)
        slot:SetVerticalAlignment(VALIGN.top)
    end)
    pcall(function() slot:SetPadding({ Left = TEXT_AT.x, Top = TEXT_AT.y, Right = TEXT_AT.right, Bottom = 0 }) end)
    banner.text = text
    return sized
end

-- Puts the banner on the list's canvas; where it went, for the log.
local function putBannerOnCanvas(banner, list)
    local okParent, canvas = pcall(function() return list:GetParent() end)
    if not (okParent and canvas and canvas:IsValid() and className(canvas) == "CanvasPanel") then
        return "in the button list (it is not on a canvas)"
    end
    pcall(function() list:ForceLayoutPrepass() end)          -- our buttons just went in: the list's size with them
    local okSpot, why = pcall(bannerSpot, list)
    if not okSpot then return "in the button list (" .. tostring(why):gsub("^.-:%d+: ", "") .. ")" end
    banner.slot = canvas:AddChildToCanvas(banner.box)
    pcall(function()
        banner.slot:SetAutoSize(false)
        banner.slot:SetSize({ X = MENU_WIDTH, Y = BANNER_HEIGHT })
    end)
    -- A banner left on the canvas when it can't be placed would have no record to take it away, and every remake of
    -- the rows would add one more: it is taken off again and goes in the list.
    local okPlace, whyNot = pcall(placeBanner, banner)
    if not okPlace then
        pcall(function() banner.box:RemoveFromParent() end)
        banner.slot, banner.at = nil, nil
        return "in the button list (it could not be placed on the canvas: "
            .. tostring(whyNot):gsub("^.-:%d+: ", "") .. ")"
    end
    return "on " .. nameOf(canvas) .. " at " .. math.floor(banner.at.X + 0.5) .. "," .. math.floor(banner.at.Y + 0.5)
        .. " (its bottom edge, centred over the buttons)"
end

local function putBannerInList(banner, list)
    local slot = list:AddChild(banner.box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = BANNER_GAP }) end)
    pcall(function() slot:SetHorizontalAlignment(HALIGN.fill) end)
end

-- The banner over the list, with its status dot and text; its record, or nil without the art.
function BANNER.add(menu, list)
    local banner = makeBanner(menu, list)
    if not banner then return nil end
    addStatusDot(banner, menu)
    local sized = addStatusText(banner, menu)
    local where = putBannerOnCanvas(banner, list)
    if not banner.slot then
        putBannerInList(banner, list)
    end
    log("menu: title banner added " .. where .. " (" .. (sized and "13 pt text" or "text scaled down")
        .. (banner.dot and "" or ", no status dot") .. ")")
    return banner
end

-- The banner's text and dot as the connection stands, and its place as the list's height changes.
function BANNER.showConnection(banner)
    local status, server = api.status(), api.server()
    local text = status == "connected" and ("Connected | " .. server .. " | Slot: " .. api.slot())
        or status == "connecting" and ("Connecting to " .. server .. "...")
        or (server ~= "" and ("Not connected | " .. server .. " | click to set up"))
        or "Not connected | click to set up"
    if banner.slot then
        pcall(placeBanner, banner)
    end
    if banner.textNow ~= text then
        banner.textNow = text
        pcall(function() banner.text:SetText(FText(text)) end)
    end
    if banner.dot and banner.stateNow ~= status then
        banner.stateNow = status
        pcall(function() banner.dot:SetColorAndOpacity(DOT[status] or DOT.other) end)
    end
end

-- The banner's tint follows its button's own hover and unhover events (hooked, never polled: a menu the game has
-- dropped is never touched). The picture: pressed for a moment after a click, the hover picture while lit, the banner
-- itself otherwise; without those files, the banner itself with the tint and the pop alone.
function BANNER.refreshLook(m)
    local banner = m.banner
    if not (banner and banner.picture and m.bannerKey) then return end
    local lit = bannerHovered == m.bannerKey and not m.showing
    if banner.lit ~= lit then
        banner.lit = lit
        pcall(function() banner.picture:SetColorAndOpacity(lit and BANNER_LIT or BANNER_DIM) end)
        pcall(function() banner.box:SetRenderScale(lit and BANNER_POP or BANNER_REST) end)
    end
    local wanted = bannerPressed and "ap-title-banner-pressed" or (lit and "ap-title-banner-hover") or "ap-title-banner"
    if banner.pictureNow == wanted then return end
    banner.pictureNow = wanted
    local texture = ART.texture(wanted) or ART.texture("ap-title-banner")
    if texture then
        pcall(function() banner.picture:SetBrushFromTexture(texture, false) end)
    end
end

-- The banner was just clicked: its pressed picture shows until the end of the update.
function BANNER.press()
    bannerPressed = true
end

-- The update is over: the banner's pressed picture goes at its next refresh.
function BANNER.endPress()
    bannerPressed = false
end

-- The pointer (or focus) on or off the banner's button.
function BANNER.pointerOn(address, on)
    if on then
        bannerHovered = address
    elseif bannerHovered == address then
        bannerHovered = nil
    end
end

return BANNER
