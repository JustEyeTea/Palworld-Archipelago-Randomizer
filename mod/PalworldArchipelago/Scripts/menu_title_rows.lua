-- The title menu's Archipelago menu, built on a title menu: its rows in the typed layout (the fields typed in the
-- game's own text box, the saved servers' panel under Server, Connect and Back), else in the window layout; each
-- row's dark backing; and every button claimed for its click (menu_title_connect.lua says what a click does).
-- Used by menu_title.lua.
-- Tests: mod/test/tests/title_menu.lua; group "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local ROWS = {}
local ART = require("art")
local CLICKS = require("clicks")
local UTIL = require("util")
local WIDGETS = require("widgets")
local NAMES = require("menu_names")
local BANNER = require("menu_title_banner")
local CONNECT = require("menu_title_connect")
local GAME = NAMES.GAME
local MENU_WIDTH = NAMES.MENU_WIDTH
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
local BRUSH_BOX = NAMES.BRUSH_BOX
local SIZE_FILL = NAMES.SIZE_FILL
local TITLE_OWNER = NAMES.TITLE_OWNER
local log, once = UTIL.log, UTIL.onceIn("menu")
local className = WIDGETS.className
local VALIGN = WIDGETS.VALIGN

-- Two layouts of one menu. The typed layout is built first. If any of its rows can't be made, everything is taken out
-- and the window layout is built instead: each field is a row that opens the game's text window alone, and Server
-- steps through the saved servers. A menu record's `edits` is nil in the window layout.

local TYPED_LAYOUT = { "server", "port", "slot", "password", "go", "back" }   -- the saved servers go under Server,
                                                                               -- in a panel of their own (PICKS)
local WINDOW_LAYOUT = { "server", "addr", "port", "slot", "password", "go", "back" }
local TYPED_LABELS = { server = "Server", port = "Port", slot = "Slot", password = "Password" }   -- the typed rows
local BACKED = { go = true, back = true }    -- the button rows with a dark backing (the typed rows all have one)

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

-- State. Forgotten: never.
local coloured = false        -- a text box was coloured (for the log)

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
function ROWS.addTitleButton(menu, list, width, edge)
    local button = WIDGETS.create(menu, GAME.titleButton)
    if not button then return nil end
    local content, isBacked = button, false
    if edge then
        content, isBacked = backed(menu, button, edge)
    end
    return button, putRowInList(menu, list, content, isBacked, width)
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
        label:SetColorAndOpacity({ SpecifiedColor = BANNER.TEXT_COLOUR, ColorUseRule = WIDGETS.COLOUR_RULE.specified })
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
    BANNER.listTop(list)
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

-- Claims a button of a menu for its row.
local function ownButton(m, button, row)
    local address = UTIL.addr(button)
    if address then
        m.owns[address] = row
    end
    CLICKS.claimSoon(button, TITLE_OWNER, CONNECT.onTitleClick(m, row))
end

-- A row of a menu: its record, collapsed until the menu opens; its button (if any) claimed.
function ROWS.addRow(m, key, kind, index, box, button)
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
    local button, box = ROWS.addTitleButton(menu, list, width, edge)
    if not button then
        error("no button for " .. kind .. (index or ""))
    end
    ROWS.addRow(m, kind .. (index or ""), kind, index, box, button)
end

-- One of the panel's soft ends; whether it was made.
local function addPadRow(m, menu, list, key, edge, height)
    local ok, box = pcall(addPad, menu, list, edge, height)
    if not (ok and box) then
        once("pad", "menu: the panel's " .. edge .. " pad not made (" .. tostring(box) .. ")")
        return false
    end
    ROWS.addRow(m, key, key, nil, box, nil)
    return true
end

-- The typed layout (see the two layouts above TYPED_LAYOUT). Raises an error when a row can't be made.
function ROWS.buildTyped(m, menu, list)
    local padded = ART.texture("ap-menu-panel-top") ~= nil and ART.texture("ap-menu-panel-bottom") ~= nil
    if padded then
        padded = addPadRow(m, menu, list, "padTop", "top", PAD_TOP)
    end
    m.padTop = padded and PAD_TOP or 0
    m.edits = {}
    for _, kind in ipairs(TYPED_LAYOUT) do
        if TYPED_LABELS[kind] then
            local box, edit, what = addTextRow(menu, list, kind, edgeOf(kind, padded))
            ROWS.addRow(m, kind, kind, nil, box, nil)
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
function ROWS.undoTyped(m, list)
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
function ROWS.undoWindow(m)
    for _, row in pairs(m.rows) do
        pcall(function() row.box:RemoveFromParent() end)
        pcall(CLICKS.release, row.button)
    end
end

-- The window layout; nil, or why it could not be made.
function ROWS.buildWindow(m, menu, list)
    for _, kind in ipairs(WINDOW_LAYOUT) do
        local edge = BACKED[kind] and edgeOf(kind, false) or nil
        local ok, button, box = pcall(ROWS.addTitleButton, menu, list, MENU_WIDTH, edge)
        if not (ok and button) then return button or "no button" end
        ROWS.addRow(m, kind, kind, nil, box, button)
    end
    return nil
end

-- The banner's own button: an all-but-invisible title button over the whole banner, so a click on the banner opens
-- the menu (and a controller can reach it as it reaches the other title buttons). Raises an error without a banner.
function ROWS.addBannerButton(menu, m)
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

return ROWS
