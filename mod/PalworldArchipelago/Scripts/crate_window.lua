-- The Palworld Crates window, drawn over the mailbox's chest window (which already has the cursor and the input): a
-- row per crate kind waiting (its icon, its count, a button to open one), the chosen kind in the details pane, and the
-- last crate opened in the contents cells. Closed, a small "Open Palworld Crates (N)" button brings it back. Every
-- image falls back to a plain box without its file. Untested in game: the window's look and its buttons.
-- Tests: mod/test/harness.lua, group "the crate window" (run by tools/lua_harness.sh).
local CW = {}
local ART = require("art")
local BAG = require("bag")
local CLICKS = require("clicks")
local CRATES = require("crates")
local MAIL = require("mailbox")
local UTIL = require("util")
local WIDGETS = require("widgets")
local log, once = UTIL.log, UTIL.onceIn("crate_window")
local place, sized = WIDGETS.place, WIDGETS.sized

-- What main.lua hands over (CW.install).
--   chestWidget()     the chest window the mailbox has open, or nil
--   openCrate(kind)   opens one crate of a kind into the mailbox: the kind opened and its contents { id, n }, or nil
local env = nil

-- The window's buttons are the game's WBP_CommonButton_C, claimed in clicks.lua under this owner. menu.lua's hook on
-- that class notes their clicks; CW.update runs them.
local OWNER = "crate window"

-- The art plate (art/ap-mailbox-window.png, 1600x1000) is shown at half size; its slots below are the art's own
-- coordinates halved, in the window's units: x, y from the plate's top-left corner, w and h.
local PLATE = { w = 800, h = 500 }
local SLOT = {
    title = { x = 32, y = 26 },                         -- the window's name, when the plate (which has it) is missing
    close = { x = 734, y = 17, w = 46, h = 38 },
    listHeader = { x = 32, y = 98, w = 356, h = 22 },
    list = { x = 32, y = 126 },                         -- the first row's top-left corner
    row = { w = 360, h = 48 },                          -- art/ap-mailbox-row.png
    rowIcon = { x = 6, y = 4, w = 40, h = 40 },         -- these four are inside a row
    rowName = { x = 54, y = 6, w = 210, h = 20 },
    rowCount = { x = 54, y = 27, w = 210, h = 15 },
    rowButton = { x = 276, y = 7, w = 78, h = 34 },
    icon = { x = 436, y = 106, w = 112, h = 112 },      -- the details pane: the chosen kind's icon on its glow
    reveal = { x = 396, y = 66, w = 192, h = 192 },     -- art/ap-mailbox-reveal.png
    name = { x = 562, y = 111, w = 202, h = 28 },
    line2 = { x = 562, y = 143, w = 202, h = 18 },
    line3 = { x = 562, y = 165, w = 202, h = 48 },
    contentsHeader = { x = 436, y = 234, w = 328, h = 20 },
    contents = { x = 436, y = 262 },                    -- the first cell's top-left corner
    cell = { w = 60, h = 60 },                          -- art/ap-mailbox-cell.png
    open = { x = 604, y = 420, w = 160, h = 44 },       -- the big Open button
}
local ROW_STRIDE = 52                 -- from one row's top to the next
local CELL_STRIDE = 68                -- from one cell's corner to the next, both ways
local CONTENTS_CELLS = 10             -- the most of the last crate's contents shown: two rows of five
local CELLS_PER_ROW = 5
local CELL_INSET = 5                  -- the text inside a cell keeps this far from its edges
local NAME_MAX_CHARS = 22             -- a longer item name is cut, so it fits a cell
local EMPTY_NOTE_INSET = 8            -- "No crates waiting." sits this far into the list
local TOGGLE = { w = 300, h = 36, top = 130 }   -- the small button: top centre, above the inventory and chest panels
local OVER_CHEST = 1000               -- the canvas ZOrder that puts the window over everything on the chest window
local CANVAS_DEPTH = 4                -- how deep under the chest window's root its canvas is looked for
local FONT = { title = 22, header = 12, rowName = 12, rowCount = 9, name = 16, detail = 10, contentsHeader = 11,
               cell = 8 }             -- point sizes
local CENTRE, TOP_CENTRE = { X = 0.5, Y = 0.5 }, { X = 0.5, Y = 0 }   -- anchors and alignments on a canvas

local CREAM, MUTED, NAVY = UTIL.linear("FFF4DC"), UTIL.linear("A3ADC9"), UTIL.linear("17324D")
local GLOW = { sphere = UTIL.linear("3FC1D9"), food = UTIL.linear("ECBE6E"), common = UTIL.linear("C8B79A"),
               rare = UTIL.linear("8B6FD6"), jackpot = UTIL.linear("F2C14E") }   -- each crate kind's colour

-- State: what is drawn over the chest window. Forgotten: when the chest window goes (CW.update). Its buttons are
-- released whenever it is drawn again, and when it goes (hide()).
local overlay = nil           -- { widgetAddress = the chest window's address, panel, toggle, signature }
-- State: the player's choices in the window. Forgotten: when a new chest window opens (a fresh mailbox).
local dismissed = false       -- the player closed the crate window
local selected = nil          -- the kind in the details pane
local last = nil              -- the last crate opened: { kind, out = its contents { id, n }, stamp = +1 a crate }

local function valid(object)
    local ok, answer = pcall(function() return object:IsValid() end)
    return ok and answer
end

-- The first CanvasPanel at or under a widget's root (as the HUD layout's: a SafeZone may hold it).
local function canvasOf(widget)
    local root = nil
    pcall(function() root = widget.WidgetTree.RootWidget end)
    for _ = 1, CANVAS_DEPTH do
        if not (root and valid(root)) then return nil end
        local okClass, class = pcall(function() return root:GetClass():GetFName():ToString() end)
        if okClass and class == "CanvasPanel" then return root end
        local okChild, child = pcall(function() return root:GetChildAt(0) end)
        root = okChild and child or nil
    end
end

local function text(owner, words, size, colour)
    return WIDGETS.text(owner, words, size, colour or CREAM)
end

-- An image of art `name` w x h, or a plain box of `colour` without the file.
local function picture(owner, name, width, height, colour)
    local box, image = ART.box(owner, name, width, height)
    if box then return box, image end
    once("noart" .. name, "crate window: no " .. name .. ".png; a plain box instead")
    return WIDGETS.plain(owner, width, height, colour or NAVY)
end

-- What each button does. A button names one of these, with a value for "open" (the kind).
local ACTIONS = {
    close = function()
        dismissed = true
    end,
    show = function()
        dismissed = false
    end,
    open = function(kind)
        local opened, out = env.openCrate(kind)
        if not opened then
            log("crate window: no " .. tostring(CRATES.NAMES[kind] or kind) .. " was opened (none of that kind left, "
                .. "or no player in a world)")
            return
        end
        last = { kind = opened, out = out, stamp = (last and last.stamp or 0) + 1 }
        selected = opened
    end,
}

local function runAction(name, value)
    local run = ACTIONS[name]
    if not run then
        log("crate window: a button with an unknown action (" .. tostring(name) .. ") was clicked; nothing done")
        return
    end
    run(value)
end

-- The game's own small button, w x h, labelled; a click on it runs ACTIONS[action](value) after the click's hook.
-- Its box, and the button.
local function button(owner, label, width, height, action, value)
    local made = WIDGETS.makeButton(owner, label)
    CLICKS.claim(made, OWNER, function() runAction(action, value) end)
    return sized(owner, made, width, height), made
end

-- What the window shows now; when this changes, the window is drawn again.
local function signature()
    local counts, parts = CRATES.counts(), {}
    for _, kind in ipairs(CRATES.KINDS) do
        parts[#parts + 1] = kind .. (counts[kind] or 0)
    end
    return table.concat(parts, ",") .. "|" .. tostring(selected) .. "|" .. tostring(last and last.stamp)
        .. "|" .. tostring(dismissed)
end

-- The plate, its title when the plate is missing, the Close button and the list's header.
local function addPlateAndClose(over, owner)
    local plate = picture(owner, "ap-mailbox-window", PLATE.w, PLATE.h)
    WIDGETS.fill(over:AddChild(plate))
    if not ART.texture("ap-mailbox-window") then
        place(over, text(owner, MAIL.TITLE, FONT.title), SLOT.title.x, SLOT.title.y)
    end
    place(over, (button(owner, "X", SLOT.close.w, SLOT.close.h, "close")), SLOT.close.x, SLOT.close.y)
    place(over, text(owner, "Palworld Crates", FONT.header, MUTED), SLOT.listHeader.x, SLOT.listHeader.y)
end

-- One row: its plate, the kind's icon, name and count, and its Open button.
local function addCrateRow(over, owner, kind, count, top)
    local left = SLOT.list.x
    local plate = kind == selected and "ap-mailbox-row-selected" or "ap-mailbox-row"
    place(over, (picture(owner, plate, SLOT.row.w, SLOT.row.h)), left, top)
    local icon = picture(owner, CRATES.ICONS[kind], SLOT.rowIcon.w, SLOT.rowIcon.h, GLOW[kind])
    place(over, icon, left + SLOT.rowIcon.x, top + SLOT.rowIcon.y)
    place(over, text(owner, CRATES.NAMES[kind], FONT.rowName), left + SLOT.rowName.x, top + SLOT.rowName.y)
    place(over, text(owner, count .. " waiting", FONT.rowCount, MUTED), left + SLOT.rowCount.x, top + SLOT.rowCount.y)
    local open = button(owner, "Open", SLOT.rowButton.w, SLOT.rowButton.h, "open", kind)
    place(over, open, left + SLOT.rowButton.x, top + SLOT.rowButton.y)
end

-- One row per kind waiting, in the kinds' order; a note when none waits.
local function addCrateRows(over, owner, counts)
    local rows = 0
    for _, kind in ipairs(CRATES.KINDS) do
        local count = counts[kind] or 0
        if count > 0 then
            addCrateRow(over, owner, kind, count, SLOT.list.y + rows * ROW_STRIDE)
            rows = rows + 1
        end
    end
    if rows == 0 then
        local note = text(owner, "No crates waiting.", FONT.header, MUTED)
        place(over, note, SLOT.list.x + EMPTY_NOTE_INSET, SLOT.list.y + EMPTY_NOTE_INSET)
    end
end

-- The details pane: a kind's icon on its glow, its name, how many wait, what it holds, and the big Open button.
local function addDetails(over, owner, kind, counts)
    local glowBox, glow = picture(owner, "ap-mailbox-reveal", SLOT.reveal.w, SLOT.reveal.h, GLOW[kind])
    pcall(function() glow:SetColorAndOpacity(GLOW[kind]) end)
    place(over, glowBox, SLOT.reveal.x, SLOT.reveal.y)
    place(over, (picture(owner, CRATES.ICONS[kind], SLOT.icon.w, SLOT.icon.h, GLOW[kind])), SLOT.icon.x, SLOT.icon.y)
    local count = counts[kind] or 0
    place(over, sized(owner, text(owner, CRATES.NAMES[kind], FONT.name), SLOT.name.w), SLOT.name.x, SLOT.name.y)
    local waiting = text(owner, count .. " waiting", FONT.detail, MUTED)
    place(over, sized(owner, waiting, SLOT.line2.w), SLOT.line2.x, SLOT.line2.y)
    local about = text(owner, CRATES.ABOUT[kind], FONT.detail)
    place(over, sized(owner, about, SLOT.line3.w, SLOT.line3.h), SLOT.line3.x, SLOT.line3.y)
    if count == 0 then return end
    local open = button(owner, "Open " .. CRATES.NAMES[kind], SLOT.open.w, SLOT.open.h, "open", kind)
    place(over, open, SLOT.open.x, SLOT.open.y)
end

-- An item's name cut to fit a cell.
local function cellName(id)
    local name = BAG.nameOf(id)
    if #name > NAME_MAX_CHARS then
        name = name:sub(1, NAME_MAX_CHARS - 1) .. "."
    end
    return name
end

-- The last crate opened: its contents, one cell each (name and count as text), at most CONTENTS_CELLS.
local function addLastOpened(over, owner, opened)
    local header = text(owner, "Last opened: " .. CRATES.NAMES[opened.kind], FONT.contentsHeader, MUTED)
    place(over, header, SLOT.contentsHeader.x, SLOT.contentsHeader.y)
    local inner = SLOT.cell.w - 2 * CELL_INSET
    for index, entry in ipairs(opened.out) do
        if index > CONTENTS_CELLS then break end
        local x = SLOT.contents.x + ((index - 1) % CELLS_PER_ROW) * CELL_STRIDE
        local y = SLOT.contents.y + ((index - 1) // CELLS_PER_ROW) * CELL_STRIDE
        place(over, (picture(owner, "ap-mailbox-cell", SLOT.cell.w, SLOT.cell.h)), x, y)
        local label = text(owner, cellName(entry.id) .. "\nx" .. entry.n, FONT.cell)
        place(over, sized(owner, label, inner, inner), x + CELL_INSET, y + CELL_INSET)
    end
end

-- The whole window, PLATE.w x PLATE.h.
local function buildPanel(owner)
    local root = WIDGETS.construct(WIDGETS.UMG.sizeBox, owner)
    root:SetWidthOverride(PLATE.w)
    root:SetHeightOverride(PLATE.h)
    local over = WIDGETS.construct(WIDGETS.UMG.overlay, owner)
    root:AddChild(over)
    local counts = CRATES.counts()
    addPlateAndClose(over, owner)
    addCrateRows(over, owner, counts)
    local kind = selected or (last and last.kind)          -- the chosen kind, or the last one opened
    if kind then
        addDetails(over, owner, kind, counts)
    end
    if last then
        addLastOpened(over, owner, last)
    end
    return root
end

-- Takes down what is drawn and releases its buttons.
local function hide()
    CLICKS.releaseAll(OWNER)
    if not overlay then return end
    for _, part in ipairs({ "panel", "toggle" }) do
        local widget = overlay[part]
        if widget then
            pcall(function() widget:RemoveFromParent() end)
        end
    end
    overlay.panel, overlay.toggle = nil, nil
end

-- Puts a widget on the chest window's canvas, at `anchor` (also its alignment) and `offsetY` below it, over the rest.
local function putOnCanvas(canvas, widget, anchor, offsetY)
    local slot = canvas:AddChildToCanvas(widget)
    pcall(function() slot:SetAnchors({ Minimum = anchor, Maximum = anchor }) end)
    pcall(function() slot:SetAlignment(anchor) end)
    pcall(function() slot:SetPosition({ X = 0, Y = offsetY }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(OVER_CHEST) end)
end

-- Draws what should show over `widget` now: the window (crates waiting, or one just opened, and not closed) or the
-- small button that brings it back.
local function build(widget)
    local canvas = canvasOf(widget)
    if not canvas then
        once("cwnocanvas", "crate window: the chest window has no canvas; crates open from the Inventory page")
        return
    end
    hide()
    if not dismissed and (CRATES.count() > 0 or last ~= nil) then
        overlay.panel = buildPanel(widget)
        putOnCanvas(canvas, overlay.panel, CENTRE, 0)
        once("cwshown", "crate window: shown over the mailbox (" .. CRATES.count() .. " crate(s))")
    elseif CRATES.count() > 0 then
        local label = "Open Palworld Crates (" .. CRATES.count() .. ")"
        overlay.toggle = button(widget, label, TOGGLE.w, TOGGLE.h, "show")
        putOnCanvas(canvas, overlay.toggle, TOP_CENTRE, TOGGLE.top)
    end
end

-- The first kind with a crate waiting, when the chosen kind has none left.
local function keepSelectionValid()
    local counts = CRATES.counts()
    if selected and (counts[selected] or 0) > 0 then return end
    selected = nil
    for _, kind in ipairs(CRATES.KINDS) do
        if (counts[kind] or 0) > 0 then
            selected = kind
            return
        end
    end
end

-- Every update: runs the buttons' clicks, follows the mailbox's chest window, and draws the window again when the
-- crates, the choice or the last crate opened change.
function CW.update()
    CLICKS.run(OWNER)
    local widget = env and env.chestWidget()
    if not (widget and valid(widget)) then
        if overlay then
            hide()
        end
        overlay = nil
        return
    end
    if not overlay or overlay.widgetAddress ~= UTIL.addr(widget) then
        overlay = { widgetAddress = UTIL.addr(widget) }
        dismissed, last, selected = false, nil, nil       -- a fresh mailbox: the window again, no old contents
    end
    keepSelectionValid()
    local now = signature()
    if overlay.signature == now then return end
    overlay.signature = now
    local ok, err = pcall(build, widget)
    if not ok then
        once("cwbuild" .. tostring(err), "crate window error: " .. tostring(err))
    end
end

-- Takes what main.lua hands over (see env above).
function CW.install(handedOver)
    env = handedOver
end

return CW
