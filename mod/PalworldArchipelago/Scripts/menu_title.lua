-- The title menu's Archipelago menu: the banner over the title buttons, and the rows it swaps in for them (the
-- connection's server, port, slot and password, Connect and Back). Wired by menu.lua (TITLE.install), whose
-- update calls it. Tests: mod/test/harness.lua, group "the title menu's Archipelago menu" (lua_harness.sh).
local TITLE = {}
local ART = require("art")
local CLICKS = require("clicks")
local UTIL = require("util")
local WIDGETS = require("widgets")
local SURVEY = require("menu_survey")
local TEXT = require("text_window")
local NAMES = require("menu_names")
local GAME = NAMES.GAME
local EVERY = NAMES.EVERY
local FAILS_BEFORE_BACKOFF = NAMES.FAILS_BEFORE_BACKOFF
local LOGGED_FAILURES = NAMES.LOGGED_FAILURES
local MENU_WIDTH = NAMES.MENU_WIDTH
local BANNER_HEIGHT = NAMES.BANNER_HEIGHT
local BANNER_GAP = NAMES.BANNER_GAP
local PICK_WIDTH = NAMES.PICK_WIDTH
local ROW_HEIGHT = NAMES.ROW_HEIGHT
local ROW_GAP = NAMES.ROW_GAP
local ROW_STEP = NAMES.ROW_STEP
local PAD_TOP = NAMES.PAD_TOP
local PAD_BOTTOM = NAMES.PAD_BOTTOM
local LABEL_FONT = NAMES.LABEL_FONT
local LABEL_GAP = NAMES.LABEL_GAP
local PICK_PANEL_Z = NAMES.PICK_PANEL_Z
local PICK_PANEL_PAD = NAMES.PICK_PANEL_PAD
local PICKS = NAMES.PICKS
local STARS_MAX = NAMES.STARS_MAX
local LIST_LEVELS = NAMES.LIST_LEVELS
local BRUSH_BOX = NAMES.BRUSH_BOX
local SIZE_FILL = NAMES.SIZE_FILL
local TITLE_OWNER = NAMES.TITLE_OWNER
local log, once = UTIL.log, UTIL.onceIn("menu")
local className, nameOf, setLabel = WIDGETS.className, WIDGETS.nameOf, WIDGETS.setLabel
local COLLAPSED = WIDGETS.VISIBILITY.collapsed
local HALIGN, VALIGN = WIDGETS.HALIGN, WIDGETS.VALIGN

-- What main.lua hands over, through menu.lua (TITLE.install): see menu.lua.
local api

function TITLE.install(functions)
    api = functions
end

-- The title menu's Archipelago menu. Clicking the banner (an all-but-invisible title button over it) swaps the title's
-- own buttons for ours, in the same list: Server, Port, Slot and Password typed in the game's own text box, styled as
-- the world-name window's; while the Server box has the keyboard, the saved servers show under it to pick from; then
-- Connect or Disconnect, and Back. The banner brightens while the pointer (or the keyboard's focus) is on it.
--
-- Two layouts of one menu. The typed layout is built first. If any of its rows can't be made, everything is taken out
-- and the window layout is built instead: each field is a row that opens the game's text window alone, and Server
-- steps through the saved servers. A menu record's `edits` is nil in the window layout.

local TYPED_LAYOUT = { "server", "port", "slot", "password", "go", "back" }   -- the saved servers go under Server,
                                                                               -- in a panel of their own (PICKS)
local WINDOW_LAYOUT = { "server", "addr", "port", "slot", "password", "go", "back" }
local TYPED_LABELS = { server = "Server", port = "Port", slot = "Slot", password = "Password" }   -- the typed rows
local BACKED = { go = true, back = true }    -- the button rows with a dark backing (the typed rows all have one)

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
local TEXT_COLOUR = UTIL.linear("#E8F4F2")
-- The banner waits a little dim, and is full (and a little bigger: a pop about its centre) while the pointer or the
-- keyboard is on it, with the hover picture (art/ap-title-banner-hover.png) when there is one: so it shows it can be
-- clicked.
local BANNER_DIM = { R = 0.78, G = 0.78, B = 0.78, A = 1 }
local BANNER_LIT = { R = 1, G = 1, B = 1, A = 1 }
local BANNER_POP, BANNER_REST = { X = 1.04, Y = 1.04 }, { X = 1, Y = 1 }
local BANNER_BUTTON_OPACITY = 0.02   -- the banner's button: the banner shows through, the button still takes the click

-- A dark backing behind each row, so the fields read: each row in a Border, ROW_STEP high with no gap between, so
-- together they read as one panel. The Border's brush is a feathered piece (art/ap-menu-panel-<edge>.png, made by
-- tools/menu_panel_art.py) drawn as a Box, so the feather keeps its width: every row soft at the sides, the top end
-- soft at the top, the bottom end at the bottom. The brush is the Border's own, written field by field in place:
-- never assign a struct property from one object to another from Lua (the game crashes). Plain colour without the
-- pieces; the bare row when a Border can't be made.
local PANEL_COLOUR = { R = 0.012, G = 0.035, B = 0.045 }   -- linear; chosen in game, so it has no hex source
local function withAlpha(colour, alpha)
    return { R = colour.R, G = colour.G, B = colour.B, A = alpha }
end
local ROW_BG = withAlpha(PANEL_COLOUR, 0.82)
local PICK_PANEL_BG = withAlpha(PANEL_COLOUR, 0.92)      -- the saved servers' panel: the same colour, darker
local PANEL_PIECE_PX = 64                                -- the feathered pieces' size
local PANEL_SIDE, PANEL_END = 28 / PANEL_PIECE_PX, 16 / PANEL_PIECE_PX   -- their feathered margins, as fractions
local SOFT_PAD, PLAIN_PAD, ROW_PAD_Y = 22, 10, 1.5      -- a backed row's padding: sides (soft or plain), top/bottom
-- The typed rows' text boxes keep their own look; only their colours are written, into the box's own WidgetStyle, as
-- plain numbers field by field (FSlateColor's SpecifiedColor R/G/B/A and its rule): nothing assigned from another
-- object, no brush touched. A line goes to the log just before the first, so a crash there would point at it.
local EDIT_COLOUR = { R = 0.86, G = 0.95, B = 0.94, A = 1 }   -- the text: light (linear, chosen in game)
local EDIT_BG = { R = 0.0, G = 0.006, B = 0.01, A = 0.97 }    -- the box: near black (linear, chosen in game)

-- State: the title menus. Forgotten: an entry when its menu is no longer found or its rows are gone (dropTitleMenu).
-- A record's life: made (buildTitleMenu: our rows collapsed, the banner on) -> showing (the banner clicked: the game's
-- buttons fold away) -> closed again (Back, Esc, or connected after Connect) -> given up (dropTitleMenu), after which
-- nothing touches it again: a remake is a new record.
local menus = {}              -- a title menu's address -> its record (newTitleMenu)
local fails = {}              -- a title menu's address -> builds that failed in a row (FAILS_BEFORE_BACKOFF);
                              --   forgotten when the menu is no longer found (a new one may get its address)
-- State: what the menu will connect with. Forgotten: each time the menu opens (setShowing).
local draft = nil             -- { host, port, slot, password }
-- State. Forgotten: never.
local remembered = nil        -- the server last handed to api.rememberServer
local buildFailures = 0       -- builds that failed in a row, on any menu (the first LOGGED_FAILURES are logged)
local lookUpdates = 0         -- updates since the start (the title menu's lookups count them)
local titleInWorld = false    -- a title menu was found in a world: from then it is looked for every update
local rowsEverMade = false    -- our rows were made on a title menu (then no survey is needed)
local coloured = false        -- a text box was coloured (for the log)
-- State: the pointer and the banner. Forgotten: bannerPressed at the end of every update; the others when the
-- pointer leaves.
local bannerPressed = false   -- the banner was just clicked: its pressed picture until the end of the update
local bannerHovered = nil     -- the banner button's address while the pointer (or focus) is on it
local pickHovered = nil       -- a saved server row's address while the pointer is on it

-- A title menu's record, with every field it has.
local function newTitleMenu(list)
    return {
        list = list,            -- the game's button list our rows are in
        rows = {},              -- row key ("server", "pick3", "padTop", ...) -> { kind, index, box, button, shown }
        owns = {},              -- a button's address -> its row (the banner's button included): our buttons here
        edits = nil,            -- a typed row's kind -> its text box, in the typed layout; nil in the window layout
        editClass = nil,        -- the text boxes' class name (for the log)
        typed = {},             -- a typed row's kind -> what its box held at the last read
        pickPanel = nil,        -- the saved servers' panel on the canvas: { box, list, slot, at, shown }, or nil
        pickHosts = {},         -- the saved servers offered now, by their row's index
        padTop = 0,             -- the soft top end's height above Server (0 without it)
        banner = nil,           -- the banner record (newBanner), or nil without one
        bannerButton = nil,     -- the banner's own button, or nil (then a row of its own opens the menu)
        bannerKey = nil,        -- that button's address (the hover events name it)
        showing = false,        -- the Archipelago menu is up, the game's buttons folded away
        hidden = nil,           -- the game's buttons it folded away: { widget, visibility } to give back
        closeOnConnect = nil,   -- Connect was pressed: fold the menu once the connection is up
        live = false,           -- found by the last lookup; false once given up
    }
end

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

-- The panel the game's own title buttons sit in: up from the Start Game button to the first box (the client's title
-- menu lays its buttons out differently from the server's files). Then any other title button's; VerticalBox_0 last.
local function boxAbove(button)
    local widget = button
    for _ = 1, LIST_LEVELS do
        local okParent, parent = pcall(function() return widget:GetParent() end)
        if not okParent or not parent or not parent:IsValid() then return nil end
        if WIDGETS.BOXES[className(parent)] then return parent end
        widget = parent
    end
end

local function buttonList(menu)
    for _, name in ipairs(GAME.startButtons) do
        local ok, button = pcall(function()
            local found = menu[name]
            return found and found:IsValid() and found or nil
        end)
        local box = ok and button and boxAbove(button)
        if box then
            UTIL.took("menu: the button list", "the panel above " .. name)
            return box
        end
    end
    for _, button in ipairs(FindAllOf(GAME.titleButtonClass) or {}) do
        local box = button:IsValid() and not CLICKS.isClaimed(button) and boxAbove(button)
        if box then
            UTIL.took("menu: the button list", "the panel above another title button")
            return box
        end
    end
    local ok, box = pcall(function()
        local found = menu[GAME.fallbackList]
        return found:IsValid() and found or nil
    end)
    if not (ok and box) then return nil end
    UTIL.took("menu: the button list", GAME.fallbackList)
    return box
end

-- The top-centre point of the button list on its canvas, with the list's anchors. Raises an error when the list's slot
-- can't tell (no canvas slot, or anchors stretched across the canvas).
local function listTop(list)
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
    local anchors, top = listTop(list)
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
        text:SetColorAndOpacity({ SpecifiedColor = TEXT_COLOUR, ColorUseRule = WIDGETS.COLOUR_RULE.specified })
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
    placeBanner(banner)
    return "on " .. nameOf(canvas) .. " at " .. math.floor(banner.at.X + 0.5) .. "," .. math.floor(banner.at.Y + 0.5)
        .. " (its bottom edge, centred over the buttons)"
end

local function putBannerInList(banner, list)
    local slot = list:AddChild(banner.box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = BANNER_GAP }) end)
    pcall(function() slot:SetHorizontalAlignment(HALIGN.fill) end)
end

-- The banner over the list, with its status dot and text; its record, or nil without the art.
local function addBanner(menu, list)
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
local function bannerStatus(banner)
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
local function bannerHover(m)
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

-- Which way a row's backing is soft: the first row at the top and the last at the bottom, unless the panel has soft
-- ends of its own (`padded`).
local function edgeOf(kind, padded)
    if kind == "server" then return padded and "mid" or "top" end
    if kind == "back" then return padded and "mid" or "bottom" end
    return "mid"
end

local function softEdges(border, edge)
    local texture = ART.texture("ap-menu-panel-" .. edge)
    if not texture then return false end
    local ok = pcall(function()
        local brush = border.Background
        brush.DrawAs = BRUSH_BOX
        brush.Margin.Left, brush.Margin.Right = PANEL_SIDE, PANEL_SIDE
        brush.Margin.Top = edge == "top" and PANEL_END or 0
        brush.Margin.Bottom = edge == "bottom" and PANEL_END or 0
        brush.ImageSize.X, brush.ImageSize.Y = PANEL_PIECE_PX, PANEL_PIECE_PX
    end)
    if not ok then return false end
    return (pcall(function() border:SetBrushFromTexture(texture) end))
end

-- `child` in a dark Border (see above); the Border and true, or the child alone and false when no Border can be had.
local function backed(menu, child, edge)
    local class = StaticFindObject(WIDGETS.UMG.border)
    if not (class and class:IsValid()) then
        once("rowbg", "menu: no Border class; the rows have no backing")
        return child, false
    end
    local okBorder, border = pcall(StaticConstructObject, class, menu)
    if not (okBorder and border and border:IsValid()) then
        once("rowbg", "menu: could not make a Border; the rows have no backing")
        return child, false
    end
    local soft = softEdges(border, edge or "mid")
    if not soft then
        once("rowsoft", "menu: the panel's soft edges could not be had; plain rows")
    end
    pcall(function() border:SetBrushColor(ROW_BG) end)
    local side = soft and SOFT_PAD or PLAIN_PAD
    pcall(function() border:SetPadding({ Left = side, Top = ROW_PAD_Y, Right = side, Bottom = ROW_PAD_Y }) end)
    if not pcall(function() border:AddChild(child) end) then
        once("rowbg", "menu: a Border would not take a row; the rows have no backing")
        return child, false
    end
    return border, true
end

-- A row's content at the end of the list: ROW_HEIGHT high with a gap below, or ROW_STEP high with none when backed.
local function putRowInList(menu, list, content, isBacked, width)
    return WIDGETS.addToList(menu, list, content, isBacked and ROW_STEP or ROW_HEIGHT, isBacked and 0 or ROW_GAP, width)
end

-- A title button in a box in `list`, `width` wide, backed with `edge` (no backing when nil). The button and its size
-- box (the button's parent is its Border when backed), or nil when the game's button can't be made.
local function addTitleButton(menu, list, width, edge)
    local button = WIDGETS.create(menu, GAME.titleButton)
    if not button then return nil end
    local content, isBacked = button, false
    if edge then
        content, isBacked = backed(menu, button, edge)
    end
    return button, putRowInList(menu, list, content, isBacked, width)
end

-- Our buttons go in after the game's last one: Quit Game (its size box) moves back to the end of the list, keeping
-- its slot's padding and alignment. True when it moved, or nil and why not.
local function quitLast(menu, list)
    local quit = menu[GAME.exitButton]
    if not quit or not quit:IsValid() then return nil, "no Quit Game button" end
    local wrap = quit:GetParent()
    if not wrap or not wrap:IsValid() or wrap == list then return nil, "Quit Game is not in a size box" end
    local okParent, parent = pcall(function() return wrap:GetParent() end)
    if not okParent or not parent or UTIL.addr(parent) ~= UTIL.addr(list) then
        return nil, "Quit Game is not in our list"
    end
    local padding, alignment = nil, nil
    pcall(function()
        local was = wrap.Slot.Padding
        padding = { Left = was.Left, Top = was.Top, Right = was.Right, Bottom = was.Bottom }
        alignment = wrap.Slot.HorizontalAlignment
    end)
    list:RemoveChild(wrap)
    local slot = list:AddChild(wrap)
    if padding then
        UTIL.attempt("menu: Quit Game's padding", function() slot:SetPadding(padding) end)
    end
    if alignment then
        UTIL.attempt("menu: Quit Game's alignment", function() slot:SetHorizontalAlignment(alignment) end)
    end
    return true
end

local function splitServer(server)
    local host, port = (server or ""):match("^%s*([^:%s]*):?(%d*)%s*$")
    return host or "", port or ""
end

-- What the menu will connect with, from config.txt's server, slot and password when the menu opened.
local function draftNow()
    if not draft then
        local host, port = splitServer(api.server())
        draft = { host = host ~= "" and host or "archipelago.gg", port = port, slot = api.slot(),
                  password = api.password() }
    end
    return draft
end

local function target(d)
    return d.host .. (d.port ~= "" and (":" .. d.port) or "")
end

-- Connected, and the menu still shows that same server and slot: its last row disconnects. Otherwise it connects (and
-- a connection to another server or slot replaces the one there is).
local function isCurrent(d)
    return api.status() == "connected" and target(d):lower() == api.server():lower() and d.slot == api.slot()
end

local function giveGameButtonsBack(m)
    for _, entry in ipairs(m.hidden or {}) do
        pcall(function()
            if entry.widget:IsValid() then
                entry.widget:SetVisibility(entry.visibility)
            end
        end)
    end
    m.hidden = nil
end

-- The game's own title buttons fold away while the menu shows, and get their own visibility back after.
local function showGame(m, show)
    if show then
        giveGameButtonsBack(m)
        return
    end
    local ours = {}
    for _, row in pairs(m.rows) do
        ours[UTIL.addr(row.box) or ""] = true
    end
    m.hidden = {}
    for index = 0, m.list:GetChildrenCount() - 1 do
        local child = m.list:GetChildAt(index)
        local visibility = child and child:IsValid() and not ours[UTIL.addr(child) or ""] and child:GetVisibility()
        if visibility and visibility ~= COLLAPSED then
            m.hidden[#m.hidden + 1] = { widget = child, visibility = visibility }
            child:SetVisibility(COLLAPSED)
        end
    end
end

-- A typed row's text box gets `value` (nothing in the window layout).
local function writeEdit(m, kind, value)
    local edit = m.edits and m.edits[kind]
    if not edit then return end
    pcall(function() edit:SetText(FText(value)) end)
    m.typed[kind] = value
end

-- Puts the draft into the boxes as the menu opens.
local function fillEdits(m)
    local d = draftNow()
    writeEdit(m, "server", d.host)
    writeEdit(m, "port", d.port)
    writeEdit(m, "slot", d.slot)
    writeEdit(m, "password", d.password)
end

-- Shows or folds the Archipelago menu. Opening starts from config.txt's connection again.
local function setShowing(m, showing)
    if m.showing == showing then return end
    m.showing = showing
    if showing then
        draft = nil
        draftNow()
        if m.edits then
            m.typed = {}
            fillEdits(m)
        end
    end
    showGame(m, not showing)
    log("menu: Archipelago menu " .. (showing and "opened" or "closed"))
end

-- The rows' labels, by kind (rows with no button have none).
local function pickLabel(m, row)
    local host = m.pickHosts[row.index] or ""
    return "      " .. host .. (host == draftNow().host:lower() and "   (chosen)" or "")
end

local function serverLabel()
    local saved = #(api.servers and api.servers() or {})
    return "Server: " .. draftNow().host .. (saved > 1 and ("   (click: next of " .. saved .. ")") or "")
end

local function portLabel()
    local port = draftNow().port
    return "Port: " .. (port ~= "" and port or "none (the server's default)")
end

local function slotLabel()
    local slot = draftNow().slot
    return "Slot: " .. (slot ~= "" and slot or "(click to set your slot name)")
end

local function passwordLabel()
    local password = draftNow().password
    return "Password: " .. (password == "" and "none" or string.rep("*", math.min(#password, STARS_MAX)))
end

local function goLabel()
    local d = draftNow()
    if isCurrent(d) then return "Disconnect (connected as " .. api.slot() .. ")" end
    if api.status() == "connecting" then return "Connecting to " .. api.server() .. "..." end
    if d.slot == "" then return "Connect (set your slot name first)" end
    return "Connect to " .. target(d) .. " as " .. d.slot
end

-- What a click on each kind of row does.
local function pickServer(m, row)
    local host = m.pickHosts[row.index]
    if not host then return end
    draftNow().host = host
    writeEdit(m, "server", host)
    pickHovered = nil
end

local function nextServer()
    local d = draftNow()
    local saved = api.servers and api.servers() or { d.host }
    local at = 0
    for index, host in ipairs(saved) do
        if host == d.host:lower() then
            at = index
        end
    end
    d.host = saved[at % #saved + 1]
end

local function askAddress(_, _, button)
    local d = draftNow()
    TEXT.ask(button, TEXT.FIELDS.addr, target(d), function(answer)
        local host, port = splitServer(answer)
        if host ~= "" then
            d.host = host
        end
        if port ~= "" then
            d.port = port
        end
    end)
end

local function askPort(_, _, button)
    local d = draftNow()
    TEXT.ask(button, TEXT.FIELDS.port, d.port, function(answer) d.port = (answer or ""):match("^(%d*)") or "" end)
end

local function askSlot(_, _, button)
    local d = draftNow()
    TEXT.ask(button, TEXT.FIELDS.slot, d.slot, function(answer) d.slot = answer or "" end)
end

local function askPassword(_, _, button)
    local d = draftNow()
    TEXT.ask(button, TEXT.FIELDS.password, d.password, function(answer) d.password = answer or "" end)
end

local function connectOrDisconnect(m)
    local d = draftNow()
    if isCurrent(d) then
        api.disconnect()
    elseif d.host ~= "" and d.slot ~= "" and api.status() ~= "connecting" then
        m.closeOnConnect = true                    -- back to the title's buttons once it connects
        api.connect(target(d), d.slot, d.password)
    end
end

-- When each kind of row shows.
local function whileShowing(m)
    return m.showing == true
end

local function whileFolded(m)
    return not m.showing
end

local function whilePicking(m, row, picking)
    return picking and m.pickHosts[row.index] ~= nil
end

-- Every kind of row of the Archipelago menu: its label (rows without a button have none), what a click on it does,
-- and when it shows. "bannerButton" is the banner's button, or, without a banner, a row of its own standing in for it.
local ROW_KINDS = {
    bannerButton = { label = function() return "Archipelago..." end,
                     act = function(m) setShowing(m, true) end, shows = whileFolded },
    server = { label = serverLabel, act = nextServer, shows = whileShowing },
    pick = { label = pickLabel, act = pickServer, shows = whilePicking },
    addr = { label = function() return "Type a server address..." end, act = askAddress, shows = whileShowing },
    port = { label = portLabel, act = askPort, shows = whileShowing },
    slot = { label = slotLabel, act = askSlot, shows = whileShowing },
    password = { label = passwordLabel, act = askPassword, shows = whileShowing },
    go = { label = goLabel, act = connectOrDisconnect, shows = whileShowing },
    back = { label = function() return "Back" end, act = function(m) setShowing(m, false) end, shows = whileShowing },
    padTop = { shows = whileShowing },
    padBottom = { shows = whileShowing },
}

-- Does what a click on a row stands for. A kind ROW_KINDS does not name, or one with no action, is an error.
local function act(m, row, button)
    draftNow()
    local kind = ROW_KINDS[row.kind]
    if not kind or not kind.act then
        error("no action for a row of kind " .. tostring(row.kind))
    end
    kind.act(m, row, button)
end

-- The colours of a text box's own style, written in place (see EDIT_COLOUR).
local function setColour(slate, colour)
    local specified = slate.SpecifiedColor
    specified.R, specified.G, specified.B, specified.A = colour.R, colour.G, colour.B, colour.A
    slate.ColorUseRule = WIDGETS.COLOUR_RULE.specified
end

local function colourEdit(edit)
    if not coloured then
        log("menu: colouring the text boxes (their own style's colours, in place)")
    end
    local style = edit.WidgetStyle
    setColour(style.BackgroundColor, EDIT_BG)
    setColour(style.ForegroundColor, EDIT_COLOUR)
    setColour(style.FocusedForegroundColor, EDIT_COLOUR)
    if not coloured then
        coloured = true
        log("menu: text boxes coloured")
    end
end

-- A pad: the panel's soft end (edge "top" or "bottom"), `height` high, with nothing in it; nil when not backed.
local function addPad(menu, list, edge, height)
    local spacer = WIDGETS.construct(WIDGETS.UMG.spacer, menu)
    local content, isBacked = backed(menu, spacer, edge)
    if not isBacked then return nil end
    return WIDGETS.addToList(menu, list, content, height, 0, MENU_WIDTH)
end

-- The game's own text box (UPalEditableTextBox; UMG's EditableTextBox without that class), coloured; the box and its
-- class name. Raises an error when no box can be made.
local function makeTextBox(menu, kind)
    local class, what = StaticFindObject(GAME.palTextBox), "PalEditableTextBox"
    if not (class and class:IsValid()) then
        class, what = StaticFindObject(WIDGETS.UMG.editableTextBox), "EditableTextBox"
    end
    if not (class and class:IsValid()) then
        error("no text box class")
    end
    local edit = StaticConstructObject(class, menu)
    if not (edit and edit:IsValid()) then
        error("could not make a " .. what)
    end
    local okColour, errColour = pcall(colourEdit, edit)
    if not okColour then
        once("colour", "menu: could not colour a text box: " .. tostring(errColour))
    end
    pcall(function() edit:SetForegroundColor(EDIT_COLOUR) end)
    if kind == "password" then
        pcall(function() edit:SetIsPassword(true) end)
    end
    return edit, what
end

-- Adds a widget to a horizontal box; its slot. Raises an error naming both when the box won't take it.
local function addToRow(row, widget)
    local ok, slot = pcall(function() return row:AddChild(widget) end)
    if not ok then
        local why = tostring(slot):gsub("^.-:%d+: ", "")
        error("AddChild(" .. className(widget) .. ") on " .. className(row) .. ": " .. why)
    end
    return slot
end

-- The label before a typed row's box, sizing its own font.
local function makeRowLabel(menu, kind)
    local label = WIDGETS.construct(WIDGETS.UMG.textBlock, menu)
    pcall(function() label:SetText(FText(TYPED_LABELS[kind] .. ":")) end)
    pcall(function()
        local font = label.Font
        font.Size = LABEL_FONT
        label:SetFont(font)
    end)
    pcall(function()
        label:SetColorAndOpacity({ SpecifiedColor = TEXT_COLOUR, ColorUseRule = WIDGETS.COLOUR_RULE.specified })
    end)
    return label
end

-- A field typed in the menu: a label and the game's own text box in a row as wide and tall as the title buttons.
-- Its size box, the text box and its class name; raises an error when a box can't be made (the menu then uses the
-- window layout).
local function addTextRow(menu, list, kind, edge)
    local edit, what = makeTextBox(menu, kind)
    local row = WIDGETS.construct(WIDGETS.UMG.horizontalBox, menu)
    local labelSlot = addToRow(row, makeRowLabel(menu, kind))
    pcall(function()
        labelSlot:SetVerticalAlignment(VALIGN.center)
        labelSlot:SetPadding({ Left = 0, Top = 0, Right = LABEL_GAP, Bottom = 0 })
    end)
    local editSlot = addToRow(row, edit)
    pcall(function()
        editSlot:SetSize({ SizeRule = SIZE_FILL, Value = 1 })
        editSlot:SetVerticalAlignment(VALIGN.center)
    end)
    local content, isBacked = backed(menu, row, edge)
    return putRowInList(menu, list, content, isBacked, MENU_WIDTH), edit, what
end

-- The saved servers' panel: on the canvas the button list sits on, over the rows below the Server box (in the list
-- they would push the rest down), a dark backing under its rows. nil when the list is not on a canvas (the saved
-- servers then go in the list); raises an error when the list's slot can't say where the list is.
local function makePickPanel(menu, list)
    local canvas = list:GetParent()
    if not (canvas and canvas:IsValid() and className(canvas) == "CanvasPanel") then return nil end
    listTop(list)
    local over = WIDGETS.construct(WIDGETS.UMG.overlay, menu)
    local backing = WIDGETS.construct(WIDGETS.UMG.image, menu)
    pcall(function() backing:SetColorAndOpacity(PICK_PANEL_BG) end)
    WIDGETS.fill(over:AddChild(backing))                          -- the whole panel
    local rows = WIDGETS.construct(WIDGETS.UMG.verticalBox, menu)
    local rowsSlot = over:AddChild(rows)
    pcall(function() rowsSlot:SetPadding(PICK_PANEL_PAD) end)
    local slot = canvas:AddChildToCanvas(over)
    pcall(function()
        slot:SetAutoSize(true)
        slot:SetZOrder(PICK_PANEL_Z)
    end)
    WIDGETS.show(over, false)
    return { box = over, list = rows, slot = slot }
end

-- Just under the Server box: the list's top (the Server row is its first while the menu shows) plus one row.
local function placePickPanel(m)
    local anchors, top = listTop(m.list)
    local y = top.Y + m.padTop + ROW_STEP
    local panel = m.pickPanel
    if panel.at and panel.at.X == top.X and panel.at.Y == y then return end
    panel.slot:SetAnchors(anchors)
    panel.slot:SetAlignment({ X = 0.5, Y = 0 })
    panel.slot:SetPosition({ X = top.X, Y = y })
    panel.at = { X = top.X, Y = y }
end

-- What a text box holds now (nil when it can't be read).
local function readEdit(edit)
    local ok, text = pcall(function() return edit.Text:ToString() end)
    if ok and type(text) == "string" then
        UTIL.took("menu: a text box's text", "its Text field")
        return text
    end
    ok, text = pcall(function() return edit:GetText():ToString() end)
    if ok and type(text) == "string" then
        UTIL.took("menu: a text box's text", "GetText()")
        return text
    end
    return nil
end

-- What each typed box does with its text, every update while the menu shows. A Server typed as host:port moves the
-- port to its own box once the Server box is left (not while typing in it).
local function typedServer(m, d, text, edit)
    local host, port = splitServer(text)
    d.host = host
    if port ~= "" then
        d.port = port
    end
    local okFocus, focus = pcall(function() return edit:HasKeyboardFocus() end)
    if not text:find(":", 1, true) or (okFocus and focus) then return end
    writeEdit(m, "server", host)
    writeEdit(m, "port", d.port)
end

local TYPED_INTO = {
    server = typedServer,
    port = function(_, d, text) d.port = text:match("^(%d*)") or "" end,
    slot = function(_, d, text) d.slot = text end,
    password = function(_, d, text) d.password = text end,
}

-- Reads the boxes back into the draft, every update while the menu shows.
local function readEdits(m)
    local d = draftNow()
    for kind, edit in pairs(m.edits) do
        local text = readEdit(edit)
        if text == nil then
            once("editread", "menu: a text box can't be read back from Lua")
        elseif text ~= m.typed[kind] or (kind == "server" and text:find(":", 1, true)) then
            m.typed[kind] = text
            TYPED_INTO[kind](m, d, text:match("^%s*(.-)%s*$"), edit)
        end
    end
end

-- The saved servers show while the Server box has the keyboard, or while the pointer is on one of them (pressing it
-- takes the keyboard from the box before the click lands). Otherwise they go at the next update.
local function pickOpen(m)
    local edit = m.edits and m.edits.server
    local ok, focus = pcall(function() return edit:HasKeyboardFocus() end)
    if ok and focus then return true end
    return pickHovered ~= nil and m.owns[pickHovered] ~= nil
end

local function refreshPickPanel(m, picking)
    local panel = m.pickPanel
    local show = picking and #m.pickHosts > 0
    if panel.shown ~= show then
        panel.shown = show
        WIDGETS.show(panel.box, show)
    end
    if not show then return end
    local ok, err = pcall(placePickPanel, m)
    if not ok then
        UTIL.onceErr("menu saved servers", err, "menu: placing the saved servers: " .. tostring(err))
    end
end

-- The rows as the menu stands: which show, their labels, the typed fields read back, the saved servers, the banner.
local function refreshRows(m)
    if m.showing and m.edits then
        local ok, err = pcall(readEdits, m)
        if not ok then
            once("readedits", "menu: reading the text boxes: " .. tostring(err))
        end
    end
    m.pickHosts = (m.showing and m.edits and api.servers) and api.servers() or {}
    local picking = m.showing and m.edits ~= nil and pickOpen(m)
    for _, row in pairs(m.rows) do
        local kind = ROW_KINDS[row.kind]
        local show = kind.shows(m, row, picking)
        if row.shown ~= show then
            row.shown = show
            WIDGETS.show(row.box, show)
        end
        if show and row.button then
            setLabel(row.button, kind.label(m, row))
        end
    end
    if m.pickPanel then
        refreshPickPanel(m, picking)
    end
    pcall(bannerHover, m)
end

-- A click on one of a menu's buttons, run at the next game tick (claimSoon), so the menu opens at once rather than
-- at the next update; never inside the click's hook. While the text window is up, a click only refreshes the rows.
local function onTitleClick(m, row)
    return function(button)
        if row.kind == "bannerButton" then
            bannerPressed = true
        end
        if not m.live then return end
        if not TEXT.asking() then
            local ok, err = pcall(act, m, row, button)
            if not ok then
                log("menu: " .. row.kind .. " error: " .. tostring(err))
            end
        end
        refreshRows(m)
    end
end

-- Claims a button of a menu for its row.
local function ownButton(m, button, row)
    local address = UTIL.addr(button)
    if address then
        m.owns[address] = row
    end
    CLICKS.claimSoon(button, TITLE_OWNER, onTitleClick(m, row))
end

-- A row of a menu: its record, collapsed until the menu opens; its button (if any) claimed.
local function addRow(m, key, kind, index, box, button)
    local row = { kind = kind, index = index, box = box, button = button, shown = nil }
    m.rows[key] = row
    if button then
        ownButton(m, button, row)
    end
    WIDGETS.show(box, false)
    return row
end

-- A button row; raises an error when its button can't be made.
local function addButtonRow(m, menu, list, kind, index, width, edge)
    local button, box = addTitleButton(menu, list, width, edge)
    if not button then
        error("no button for " .. kind .. (index or ""))
    end
    addRow(m, kind .. (index or ""), kind, index, box, button)
end

-- One of the panel's soft ends; whether it was made.
local function addPadRow(m, menu, list, key, edge, height)
    local ok, box = pcall(addPad, menu, list, edge, height)
    if not (ok and box) then
        once("pad", "menu: the panel's " .. edge .. " pad not made (" .. tostring(box) .. ")")
        return false
    end
    addRow(m, key, key, nil, box, nil)
    return true
end

-- The typed layout (see the top of this part). Raises an error when a row can't be made.
local function buildTypedRows(m, menu, list)
    local padded = ART.texture("ap-menu-panel-top") ~= nil and ART.texture("ap-menu-panel-bottom") ~= nil
    if padded then
        padded = addPadRow(m, menu, list, "padTop", "top", PAD_TOP)
    end
    m.padTop = padded and PAD_TOP or 0
    m.edits = {}
    for _, kind in ipairs(TYPED_LAYOUT) do
        if TYPED_LABELS[kind] then
            local box, edit, what = addTextRow(menu, list, kind, edgeOf(kind, padded))
            addRow(m, kind, kind, nil, box, nil)
            m.edits[kind], m.editClass = edit, what
        else
            addButtonRow(m, menu, list, kind, nil, MENU_WIDTH, BACKED[kind] and edgeOf(kind, padded) or nil)
        end
    end
    if padded then
        addPadRow(m, menu, list, "padBottom", "bottom", PAD_BOTTOM)
    end
    local okPanel, panel = pcall(makePickPanel, menu, list)    -- once the rows are in
    m.pickPanel = okPanel and panel or nil
    for index = 1, PICKS do
        addButtonRow(m, menu, m.pickPanel and m.pickPanel.list or list, "pick", index, PICK_WIDTH, nil)
    end
end

-- Takes every row of a failed typed build back out of the list (and the saved servers' panel off the canvas), and
-- releases its buttons.
local function undoTypedRows(m, list)
    if m.pickPanel then
        pcall(function() m.pickPanel.box:RemoveFromParent() end)
    end
    for _, row in pairs(m.rows) do
        pcall(function() list:RemoveChild(row.box) end)
        if row.button then
            pcall(CLICKS.release, row.button)
        end
    end
end

-- Takes the rows of a failed window build away, and releases their buttons.
local function undoWindowRows(m)
    for _, row in pairs(m.rows) do
        pcall(function() row.box:RemoveFromParent() end)
        pcall(CLICKS.release, row.button)
    end
end

-- The window layout; nil, or why it could not be made.
local function buildWindowRows(m, menu, list)
    for _, kind in ipairs(WINDOW_LAYOUT) do
        local edge = BACKED[kind] and edgeOf(kind, false) or nil
        local ok, button, box = pcall(addTitleButton, menu, list, MENU_WIDTH, edge)
        if not (ok and button) then return button or "no button" end
        addRow(m, kind, kind, nil, box, button)
    end
    return nil
end

-- The banner's own button: an all-but-invisible title button over the whole banner, so a click on the banner opens
-- the menu (and a controller can reach it as it reaches the other title buttons). Raises an error without a banner.
local function addBannerButton(menu, m)
    local banner = m.banner
    if not (banner and banner.over) then
        error("no banner")
    end
    local button = WIDGETS.create(menu, GAME.titleButton)
    if not button then
        error("could not make the banner's button")
    end
    WIDGETS.fill(banner.over:AddChild(button))                    -- the whole banner
    pcall(function() button:SetRenderOpacity(BANNER_BUTTON_OPACITY) end)
    m.bannerButton, m.bannerKey = button, UTIL.addr(button)
    ownButton(m, button, { kind = "bannerButton" })
end

-- After the rows: the banner and its button (else a row of its own opens the menu), Quit Game last, and the logs.
-- After, not before: a menu whose rows failed would otherwise get a new banner on every try.
local function finishTitleMenu(m, menu, list)
    local okBanner, banner = pcall(addBanner, menu, list)
    if okBanner then
        m.banner = banner
    else
        log("menu: title banner error: " .. tostring(banner))
    end
    local okButton, why = pcall(addBannerButton, menu, m)
    if not okButton then
        local okRow, button, box = pcall(addTitleButton, menu, list, MENU_WIDTH, nil)
        if okRow and button then
            addRow(m, "bannerButton", "bannerButton", nil, box, button)
        end
        log("menu: no button on the banner (" .. tostring(why) .. "): an \"Archipelago...\" row instead")
    end
    local okQuit, moved, whyNot = pcall(quitLast, menu, list)
    if not (okQuit and moved) then
        log("menu: Quit Game left where it was: " .. tostring(okQuit and whyNot or moved))
    end
    pcall(SURVEY.logLayout, menu, m.rows.server and m.rows.server.button)
    log("menu: Archipelago menu added to the title menu (" .. className(list) .. " " .. nameOf(list) .. ")"
        .. (m.bannerButton and "; the banner opens it" or "")
        .. (m.edits and ("; fields typed in " .. tostring(m.editClass)) or "; fields in the text window"))
end

local function logBuildFailure(text)
    buildFailures = buildFailures + 1
    if buildFailures <= LOGGED_FAILURES then
        log(text .. " (try " .. buildFailures .. ")")
    end
end

-- Our rows on a title menu: the typed layout, else the window layout. Its record, or nil when neither could be made.
local function buildTitleMenu(menu, list, key)
    local m = newTitleMenu(list)
    local okTyped, whyTyped = pcall(buildTypedRows, m, menu, list)
    if not okTyped then
        undoTypedRows(m, list)
        m = newTitleMenu(list)
        local why = tostring(whyTyped):gsub("^.-:%d+: ", "")           -- (the message, not where)
        logBuildFailure("menu: typed fields not made (" .. why .. "); the text window instead")
        local err = buildWindowRows(m, menu, list)
        if err then
            undoWindowRows(m)
            fails[key] = fails[key] + 1
            logBuildFailure("menu: could not add the Archipelago menu's rows: " .. tostring(err))
            return nil
        end
    end
    menus[key] = m
    rowsEverMade = true
    buildFailures = 0                                      -- (the next run of failures is logged again)
    fails[key] = 0
    finishTitleMenu(m, menu, list)
    return m
end

-- Gives a menu's record up: its buttons released, never acted on again, and with `removeWidgets` its banner and saved
-- servers' panel taken away (a remake adds its own, and two would stack, the lower one dead).
local function dropTitleMenu(key, m, removeWidgets)
    m.live = false
    for _, row in pairs(m.rows) do
        if row.button then
            pcall(CLICKS.release, row.button)
        end
    end
    if m.bannerButton then
        pcall(CLICKS.release, m.bannerButton)
    end
    menus[key] = nil
    if not removeWidgets then return end
    local bannerBox = m.banner and m.banner.box
    local okBanner, bannerThere = pcall(function() return bannerBox and bannerBox:IsValid() end)
    if okBanner and bannerThere and pcall(function() bannerBox:RemoveFromParent() end) then
        log("menu: the old banner taken away")
    end
    local panel = m.pickPanel and m.pickPanel.box
    local okPanel, panelThere = pcall(function() return panel and panel:IsValid() end)
    if okPanel and panelThere then
        pcall(function() panel:RemoveFromParent() end)
    end
end

-- Whether a menu's rows are still there. Every layout has a Connect row, so it stands for all of them.
local function rowsAlive(m)
    local ok, alive = pcall(function() return m.rows.go.button:IsValid() end)
    return ok and alive
end

-- The live title menus, and whether they were looked for this update. At the title they are looked for every
-- update; in a world (playerInWorld, the one test of it) only every EVERY.titleLookInWorld, as a lookup walks the
-- whole object array and the menu is never there. If one is found in a world all the same, the in-world test is
-- wrong for this game: that is logged and the menu is looked for every update from then on.
function TITLE.find(inWorld)
    lookUpdates = lookUpdates + 1
    if inWorld and not titleInWorld and not UTIL.isDue(lookUpdates, EVERY.titleLookInWorld) then return false, {} end
    -- Live title menus only: FindAllOf also gives the class's default object and the template the title screen's
    -- asset keeps; a template can't own new buttons, and its widget tree must not be touched. A live one is under
    -- /Engine/Transient.
    local found = {}
    for _, menu in ipairs(FindAllOf(GAME.titleMenuClass) or {}) do
        local ok, fullName = pcall(function() return menu:GetFullName() end)
        fullName = ok and tostring(fullName) or ""
        if fullName:find("Default__", 1, true) or fullName:find(" /Game/", 1, true) then
            once("template" .. fullName, "menu: not a live title menu (a template), left alone: " .. fullName)
        else
            found[#found + 1] = menu
        end
    end
    if inWorld and #found > 0 and not titleInWorld then
        titleInWorld = true
        log("menu: a title menu was found with the player's pawn in a world; looking for it every update again")
    end
    return true, found
end

-- Whether our rows were ever made on a title menu.
function TITLE.rowsEverMade()
    return rowsEverMade
end

-- Title menus gone (into a world) or rebuilt: given up, as with the Esc menu, so a game title button made later at
-- a freed address of ours does not connect or disconnect when clicked. Only on an update that looked for them: one
-- that did not knows nothing about them, and giving up a menu still there would add its rows a second time.
function TITLE.forgetGone(looked, found)
    if not looked then return end
    local live = {}
    for _, menu in ipairs(found) do
        pcall(function() live[UTIL.addr(menu)] = menu:IsValid() end)
    end
    for key in pairs(fails) do
        if not live[key] then fails[key] = nil end
    end
    for key, m in pairs(menus) do
        if not live[key] then
            dropTitleMenu(key, m, false)
        elseif not rowsAlive(m) then
            -- Our rows gone while the title menu is still there (after Options and the Survival Guide): say what is
            -- left, give the game's buttons back if the menu had them folded away, and take ours away.
            local okList, listThere = pcall(function() return m.list:IsValid() end)
            log("menu: our rows are gone from a title menu still there (its list "
                .. ((okList and listThere) and "valid" or "gone") .. "; the menu was "
                .. (m.showing and "open" or "closed") .. "): making them again")
            if m.showing and okList and listThere then
                pcall(showGame, m, true)
            end
            dropTitleMenu(key, m, true)
        end
    end
end

-- The connection as it stands: after Connect, the menu folds once connected; a server connected to is remembered.
local function followConnection(m)
    local status = api.status()
    if status == "connected" then
        if m.closeOnConnect then
            m.closeOnConnect = nil
            pcall(setShowing, m, false)
        end
        if api.rememberServer and remembered ~= api.server() then
            remembered = api.server()
            api.rememberServer(api.server())
        end
    elseif status ~= "connecting" then
        m.closeOnConnect = nil
    end
end

-- One title menu found up: our rows made if it has none (a menu that keeps failing is tried only every
-- EVERY.failedMenuRetry), then brought up to date.
local function updateTitleMenu(menu, list)
    local key = UTIL.addr(menu)
    local m = menus[key]
    fails[key] = fails[key] or 0
    local due = fails[key] < FAILS_BEFORE_BACKOFF or UTIL.isDue(lookUpdates, EVERY.failedMenuRetry)
    -- Made again: the old record is never touched again, even if this fails (the old rows were once still used
    -- after a failed remake, and the game crashed on the title).
    if m and not rowsAlive(m) then
        dropTitleMenu(key, m, true)
        m = nil
    end
    if not m and due then
        m = buildTitleMenu(menu, list, key)
    end
    if not m then return end
    m.live = true                                        -- (checked this update: its clicks may act on it)
    followConnection(m)
    if m.banner then
        pcall(bannerStatus, m.banner)
    end
    refreshRows(m)
end

-- Every update: the clicks not yet run, then each title menu found up.
function TITLE.update(found)
    CLICKS.run(TITLE_OWNER)
    for _, menu in ipairs(found) do
        local okList, list = pcall(buttonList, menu)
        if menu:IsValid() and okList and list then
            updateTitleMenu(menu, list)
        end
    end
    bannerPressed = false                               -- (the pressed picture shows from the click until now)
end

-- The pointer (or focus) on or off a saved server's row: the panel stays open while it is on one.
local function hoverPick(address, on)
    if on then
        pickHovered = address
    elseif pickHovered == address then
        pickHovered = nil
    end
end

-- The pointer (or focus) on or off the banner's button: the banner lights at the next game tick.
local function hoverBanner(m, address, on)
    if on then
        bannerHovered = address
    elseif bannerHovered == address then
        bannerHovered = nil
    end
    if not ExecuteInGameThread then return end
    ExecuteInGameThread(function()
        if m.live then
            pcall(refreshRows, m)
        end
    end)
end

-- The pointer (or focus) on or off a title button: only ours are answered.
local function hovered(button, on)
    local address = UTIL.addr(button)
    if not address then return end
    for _, m in pairs(menus) do
        local row = m.owns[address]
        if row and row.kind == "pick" then
            hoverPick(address, on)
            return
        end
        if row and row.kind == "bannerButton" then
            hoverBanner(m, address, on)
            return
        end
    end
end

function TITLE.onHover(self)
    pcall(hovered, self:get(), true)
end

function TITLE.onUnhover(self)
    pcall(hovered, self:get(), false)
end

-- Esc closes the Archipelago menu as Back does: a UE4SS key bind (it fires whatever has the keyboard, a text box
-- too), acted on at the next game tick for each live menu that shows; Esc anywhere else is left to the game.
function TITLE.escape()
    for _, m in pairs(menus) do
        if m.live and m.showing then
            local ok, err = pcall(act, m, { kind = "back" })
            if not ok then
                log("menu: Esc error: " .. tostring(err))
            end
            refreshRows(m)
            once("esc", "menu: Esc closes the Archipelago menu (as Back)")
        end
    end
end

return TITLE
