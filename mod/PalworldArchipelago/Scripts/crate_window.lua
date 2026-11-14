-- The Palworld Crates window, drawn over the mailbox's chest window (which already has the cursor and the input): a
-- row per crate kind waiting (its icon, its count, a button to open one), the chosen kind in the details pane, and the
-- last crate opened in the contents cells. Closed, a small button brings it back whenever the chest window is open:
-- "Open Palworld Crates (N)" while crates wait, "Palworld Crates" (to see the last crate opened) when none do. In a
-- seed without Palworld Crates (the YAML's option) neither shows while none wait. Every image falls back to a plain box
-- without its file. Untested in game: the reopen button, where it is now.
-- Tests: mod/test/tests/crates_run_style.lua; group "the crate window" (tools/lua_harness.sh, in CI).
local CW = {}
local ART = require("art")
local BAG = require("bag")
local CLICKS = require("clicks")
local CRATES = require("crates")
local MAIL = require("mailbox")
local NAMES = require("menu_names")
local UTIL = require("util")
local WIDGETS = require("widgets")
local log, once = UTIL.log, UTIL.onceIn("crate_window")
local place, sized = WIDGETS.place, WIDGETS.sized

-- What main.lua hands over (CW.install).
--   chestWidget()     the chest window the mailbox has open, or nil
--   openCrate(kind)   opens one crate of a kind into the mailbox: the kind opened and its contents { id, n }, or nil
--   cratesInSeed()    whether the seed has Palworld Crates
--   guardedHook(name, fn)  optional: a hook callback that no update can run inside
local env = nil

-- The window's buttons are the game's WBP_CommonButton_C, claimed in clicks.lua under this owner. menu.lua's hook on
-- that class notes their clicks (CW.update asks for the same hook while the chest window is open, should menu.lua
-- not have it yet); CW.update runs them.
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
local TOGGLE = { w = 300, h = 36 }    -- the small button that brings the window back
-- Where the small button goes: centred on the canvas as the window is, moved up so its top edge is the window's top
-- edge (a negative offset is above the centre). Centred is the one place over the chest window known in game to show
-- and take clicks: the window's own buttons work there. Nearer the canvas's top, its size and anchors are unknown.
local TOGGLE_FROM_CENTRE = -(PLATE.h - TOGGLE.h) // 2
local BUILD_TRIES = 10                -- a draw that fails is tried on this many updates (3 s), then waits for a change
local OVER_CHEST = 1000               -- the canvas ZOrder that puts the window over everything on the chest window
local CANVAS_DEPTH = 4                -- how deep under the chest window's root its canvas is looked for
local FONT = { title = 22, header = 12, rowName = 12, rowCount = 9, name = 16, detail = 10, contentsHeader = 11,
               cell = 8 }             -- point sizes
local CENTRE = { X = 0.5, Y = 0.5 }    -- an anchor and alignment on a canvas
local SLATE_LIBRARY = "/Script/UMG.Default__SlateBlueprintLibrary"   -- reads where a widget was laid out

local CREAM, MUTED, NAVY = UTIL.linear("FFF4DC"), UTIL.linear("A3ADC9"), UTIL.linear("17324D")
local GLOW = { sphere = UTIL.linear("3FC1D9"), food = UTIL.linear("ECBE6E"), common = UTIL.linear("C8B79A"),
               rare = UTIL.linear("8B6FD6"), jackpot = UTIL.linear("F2C14E") }   -- each crate kind's colour

-- State: what is drawn over the chest window. Forgotten: when the chest window goes (CW.update). Its buttons are
-- released whenever it is drawn again, and when it goes (hide()).
-- { widgetAddress = the chest window's address, panel, toggle, signature = what the drawn part shows (nil until a
-- draw works), triedSignature = what the draws being tried would show, tries = how many have failed }
local overlay = nil
-- State: the player's choices in the window. Forgotten: when a new chest window opens (a fresh mailbox).
local choice = nil            -- "closed" (the player closed the window), "open" (asked for it or opened a crate in it)
local selected = nil          -- the kind in the details pane
-- State. Forgotten: never (the last crate opened can be seen again on a later mailbox).
local last = nil              -- the last crate opened: { kind, out = its contents { id, n }, stamp = +1 a crate }
local layoutLogged = false    -- the reopen button's place as laid out was logged (once a session)
local layoutLooks = 0         -- updates its layout was looked at while the canvas had no size yet

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
        choice = "closed"
    end,
    show = function()
        once("cwshowclick", "crate window: the reopen button's click arrived; the window comes back")
        choice = "open"
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
        choice = "open"                                   -- the window stays up, also once the last crate is open
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
        .. "|" .. tostring(choice)
end

-- Whether the window shows (else the small button does): as the player chose, or, until they do, while crates wait.
local function windowWanted()
    if choice then return choice == "open" end
    return CRATES.count() > 0
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

-- Whether the buttons' click hook (menu.lua's, also asked for by CW.update) is in place: logged once each way.
local function logClickHookOnce()
    if UTIL.isHooked(NAMES.GAME.commonClick) then
        once("cwhooked", "crate window: the buttons' click hook is in place")
        return
    end
    once("cwnothooked", "crate window: the buttons' click hook is not in place yet; a click on the reopen button is "
        .. "lost until it is")
end

-- The small button that brings the window back (TOGGLE_FROM_CENTRE says where, and why there). Untested in game.
local function addToggle(widget, canvas)
    local count = CRATES.count()
    local label = count > 0 and ("Open Palworld Crates (" .. count .. ")") or "Palworld Crates"
    overlay.toggle = button(widget, label, TOGGLE.w, TOGGLE.h, "show")
    putOnCanvas(canvas, overlay.toggle, CENTRE, TOGGLE_FROM_CENTRE)
    once("cwtoggleplaced", "crate window: reopen button placed on " .. WIDGETS.nameOf(canvas) .. ", centred "
        .. -TOGGLE_FROM_CENTRE .. " above its centre (the window's top edge), ZOrder " .. OVER_CHEST)
    logClickHookOnce()
end

-- Draws what should show over `widget` now: the window, or the small button that brings it back. Whether it was
-- drawn (not while the chest window has no canvas).
local function build(widget)
    local canvas = canvasOf(widget)
    if not canvas then
        once("cwnocanvas", "crate window: the chest window has no canvas; crates open from the Inventory page")
        return false
    end
    hide()
    if windowWanted() then
        overlay.panel = buildPanel(widget)
        putOnCanvas(canvas, overlay.panel, CENTRE, 0)
        once("cwshown", "crate window: shown over the mailbox (" .. CRATES.count() .. " crate(s))")
    else
        addToggle(widget, canvas)
    end
    return true
end

-- Whether the part drawn is still on the chest window (the game may rebuild the window under it). An answer that
-- can't be read counts as yes.
local function drawnStillUp()
    local part = overlay.panel or overlay.toggle
    if not part then return false end
    local ok, parent = pcall(function() return part:GetParent() end)
    return not ok or (parent ~= nil and valid(parent))
end

-- Draws again when what should show has changed or what was drawn is gone. A draw that fails (no canvas yet, a
-- widget the game would not make) is tried on the next updates too, up to BUILD_TRIES times for the same signature.
local function redrawIfNeeded(widget)
    local now = signature()
    if overlay.signature == now then
        if drawnStillUp() then return end
        once("cwgone", "crate window: what was drawn is gone from the chest window; drawn again")
    end
    if overlay.triedSignature ~= now then
        overlay.triedSignature, overlay.tries = now, 0
    end
    if overlay.tries >= BUILD_TRIES then return end
    overlay.signature = nil
    local ok, drawn = pcall(build, widget)
    if ok and drawn then
        overlay.signature, overlay.tries = now, 0
        return
    end
    overlay.tries = overlay.tries + 1
    if not ok then
        once("cwbuild" .. tostring(drawn), "crate window error: " .. tostring(drawn))
    end
end

-- Where a widget was laid out, in the screen's units: "x,y wxh", or "?" when it can't be read.
local function screenBox(widget)
    local ok, box = pcall(function()
        local geometry = widget:GetCachedGeometry()
        local slate = StaticFindObject(SLATE_LIBRARY)
        local at, size = slate:LocalToAbsolute(geometry, { X = 0, Y = 0 }), slate:GetAbsoluteSize(geometry)
        return string.format("%.0f,%.0f %.0fx%.0f", at.X, at.Y, size.X, size.Y)
    end)
    return ok and box or "?"
end

-- Once a session, once the game has laid the reopen button out (its canvas has a size: one update after it was drawn,
-- in game, the canvas was still 0x0), or after LAYOUT_LOOKS updates: what it sits on, whether it shows, and where it
-- is beside that canvas.
local LAYOUT_LOOKS = 10      -- updates to wait for the canvas to have a size before logging what is there anyway
local function logToggleLayoutOnce()
    if layoutLogged or not (overlay and overlay.toggle) then return end
    local toggle = overlay.toggle
    local okParent, canvas = pcall(function() return toggle:GetParent() end)
    layoutLooks = layoutLooks + 1
    local canvasBox = okParent and screenBox(canvas) or "?"
    if canvasBox:find(" 0x0$") and layoutLooks < LAYOUT_LOOKS then return end
    layoutLogged = true
    local okShown, shown = pcall(function() return toggle:IsVisible() end)
    log("crate window: reopen button as laid out (after " .. UTIL.counted(layoutLooks, "update") .. "): on "
        .. (okParent and WIDGETS.nameOf(canvas) or "?") .. ", visible " .. (okShown and tostring(shown) or "?")
        .. ", at " .. screenBox(toggle) .. " on a canvas at " .. canvasBox)
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

-- Whether the window or its small button belongs on the chest window: in a seed with Palworld Crates, and in one
-- without them only while crates wait all the same.
local function cratesBelong()
    return env.cratesInSeed() or CRATES.count() > 0
end

-- Every update: runs the buttons' clicks, follows the mailbox's chest window, and draws the window or its small
-- button again when the crates, the choice or the last crate opened change, or what was drawn has gone.
function CW.update()
    CLICKS.run(OWNER)
    local widget = env and env.chestWidget()
    if not (widget and valid(widget) and cratesBelong()) then
        if overlay then
            hide()
        end
        overlay = nil
        return
    end
    CLICKS.hookClass(NAMES.GAME.commonClick, OWNER, env.guardedHook)
    if not overlay or overlay.widgetAddress ~= UTIL.addr(widget) then
        overlay = { widgetAddress = UTIL.addr(widget), tries = 0 }
        choice, selected = nil, nil                       -- a fresh mailbox: the window again if crates wait
    end
    keepSelectionValid()
    logToggleLayoutOnce()
    redrawIfNeeded(widget)
end

-- Takes what main.lua hands over (see env above).
function CW.install(handedOver)
    env = handedOver
end

return CW
