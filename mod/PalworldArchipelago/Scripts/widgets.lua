-- Making and reading game widgets (UMG, the engine's UI system): the engine's enum values and the UMG class paths
-- every window file passes, with the engine's own names, and the small makers the window files share.
-- Tests: mod/test/tests/mailbox.lua, mod/test/tests/inventory_page.lua, mod/test/tests/title_menu.lua,
--   mod/test/tests/crates_run_style.lua; groups "the mailbox", "the Inventory page's mailbox button",
--   "the title menu's Archipelago menu", "the crate window" (tools/lua_harness.sh, in CI).
local WIDGETS = {}
local UTIL = require("util")

-- Engine enum values with the engine's own names. A window file never passes one of these as a bare digit.
WIDGETS.VISIBILITY = { visible = 0, collapsed = 1, hidden = 2, selfHitTestInvisible = 4 }   -- ESlateVisibility
WIDGETS.HALIGN = { fill = 0, left = 1, center = 2, right = 3 }                               -- EHorizontalAlignment
WIDGETS.VALIGN = { fill = 0, top = 1, center = 2, bottom = 3 }                               -- EVerticalAlignment
WIDGETS.JUSTIFY = { left = 0, center = 1, right = 2 }                                       -- ETextJustify
WIDGETS.COLOUR_RULE = { specified = 0 }       -- ESlateColorStylingMode: UseColor_Specified (the colour given)

-- The engine's panels a row of buttons can sit in.
WIDGETS.BOXES = { VerticalBox = true, ScrollBox = true, WrapBox = true, HorizontalBox = true }

-- The engine's widget classes the window files make.
WIDGETS.UMG = {
    textBlock = "/Script/UMG.TextBlock",
    image = "/Script/UMG.Image",
    sizeBox = "/Script/UMG.SizeBox",
    overlay = "/Script/UMG.Overlay",
    widgetLibrary = "/Script/UMG.Default__WidgetBlueprintLibrary",   -- makes Blueprint widgets (the game's buttons)
}
-- The game's widgets the window files make. After a Palworld update, check that each one still exists.
WIDGETS.GAME = {
    commonButton = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C",
    commonButtonLabel = "Text_Main",   -- the text inside the game's small labelled button (and the Esc menu's)
    titleButtonLabel = "Test_Content", -- a title button's label (the game's own spelling)
}
-- The game's title button, and the row of a list it sits in as the title menu's own buttons do.
WIDGETS.TITLE_BUTTON = {
    path = "/Game/Pal/Blueprint/UI/UserInterface/Title/WBP_Title_MenuButton.WBP_Title_MenuButton_C",
    height = 38,                       -- as the title buttons are
    gap = 3,                           -- below one in a list
}
WIDGETS.UMG.border = "/Script/UMG.Border"
WIDGETS.UMG.spacer = "/Script/UMG.Spacer"
WIDGETS.UMG.verticalBox = "/Script/UMG.VerticalBox"
WIDGETS.UMG.horizontalBox = "/Script/UMG.HorizontalBox"
WIDGETS.UMG.editableTextBox = "/Script/UMG.EditableTextBox"

local DEFAULT_FONT_SIZE = 24          -- a TextBlock's font size before it is set

-- A new widget of an engine class (one of WIDGETS.UMG), owned by `owner`.
function WIDGETS.construct(classPath, owner)
    return StaticConstructObject(StaticFindObject(classPath), owner)
end

-- Has a widget in a panel slot fill the slot both ways (an image otherwise keeps its brush's 32x32).
function WIDGETS.fill(slot)
    pcall(function()
        slot:SetHorizontalAlignment(WIDGETS.HALIGN.fill)
        slot:SetVerticalAlignment(WIDGETS.VALIGN.fill)
    end)
end

-- Sets a text block's font to `size` points; when the font can't be set, scales the text to that size about `pivot`
-- (0..1 of its box) instead. Whether the font was set.
function WIDGETS.setFontSize(block, size, pivot)
    local sized = pcall(function()
        local font = block.Font
        font.Size = size
        block:SetFont(font)
    end)
    if sized then return true end
    UTIL.took("widgets: text sizes", "scaled, as a text's font could not be set")
    pcall(function()
        block:SetRenderTransformPivot(pivot)
        block:SetRenderScale({ X = size / DEFAULT_FONT_SIZE, Y = size / DEFAULT_FONT_SIZE })
    end)
    return false
end

-- A line of text, `size` points, in `colour` (a linear colour), wrapping at its box's width. When the font can't be
-- set, the text is scaled from its top-left corner to the same size instead.
function WIDGETS.text(owner, words, size, colour)
    local block = WIDGETS.construct(WIDGETS.UMG.textBlock, owner)
    WIDGETS.setFontSize(block, size, { X = 0, Y = 0 })
    pcall(function()
        block:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = WIDGETS.COLOUR_RULE.specified })
    end)
    pcall(function() block:SetAutoWrapText(true) end)
    block:SetText(FText(words))
    return block
end

-- A box of plain colour, w x h; the box and its image.
function WIDGETS.plain(owner, width, height, colour)
    local image = WIDGETS.construct(WIDGETS.UMG.image, owner)
    pcall(function() image:SetColorAndOpacity(colour) end)
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, owner)
    box:SetWidthOverride(width)
    box:SetHeightOverride(height)
    WIDGETS.fill(box:AddChild(image))
    return box, image
end

-- `child` in a box `width` wide and, when `height` is given, that high.
function WIDGETS.sized(owner, child, width, height)
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, owner)
    box:SetWidthOverride(width)
    if height then
        box:SetHeightOverride(height)
    end
    WIDGETS.fill(box:AddChild(child))
    return box
end

-- Puts `widget` on an overlay at x, y from its top-left corner; its slot.
function WIDGETS.place(over, widget, x, y)
    local slot = over:AddChild(widget)
    pcall(function()
        slot:SetHorizontalAlignment(WIDGETS.HALIGN.left)
        slot:SetVerticalAlignment(WIDGETS.VALIGN.top)
    end)
    pcall(function() slot:SetPadding({ Left = x, Top = y, Right = 0, Bottom = 0 }) end)
    return slot
end

-- One of the game's own Blueprint widgets (a button), made from its class path, loading the class if need be; nil
-- when the class or the widget can't be had.
function WIDGETS.create(owner, classPath)
    local class = UTIL.findClass(classPath)
    local library = StaticFindObject(WIDGETS.UMG.widgetLibrary)
    if not class or not library then return nil end
    local widget = library:Create(owner, class, nil)
    if not widget or not widget:IsValid() then return nil end
    return widget
end

-- `content` in a size box at the end of a vertical `list`: `height` high, `width` wide (none set when nil), with `gap`
-- below it and filling the list's width. The size box.
function WIDGETS.addToList(owner, list, content, height, gap, width)
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, owner)
    if width then
        box:SetWidthOverride(width)
    end
    box:SetHeightOverride(height)
    box:AddChild(content)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = gap }) end)
    pcall(function() slot:SetHorizontalAlignment(WIDGETS.HALIGN.fill) end)
    return box
end

-- The game's own small labelled button (WBP_CommonButton_C, as the Inventory page's Edit Name). Raises an error
-- when the game's button class can't be had.
function WIDGETS.makeButton(owner, label)
    local button = WIDGETS.create(owner, WIDGETS.GAME.commonButton)
    if not button then
        error("no WBP_CommonButton_C")
    end
    pcall(function() button[WIDGETS.GAME.commonButtonLabel]:SetText(FText(label)) end)
    return button
end

-- Shows or collapses a widget (logged once when the game's widget won't take it).
function WIDGETS.show(widget, shown)
    UTIL.attempt("widgets: show or fold a widget", function()
        widget:SetVisibility(shown and WIDGETS.VISIBILITY.visible or WIDGETS.VISIBILITY.collapsed)
    end)
end

-- A widget's class name ("?" when it can't be read).
function WIDGETS.className(object)
    local ok, name = pcall(function() return object:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

-- A widget's own name ("?" when it can't be read).
function WIDGETS.nameOf(object)
    local ok, name = pcall(function() return object:GetFName():ToString() end)
    return ok and name or "?"
end

-- Whether `object` is a real, living object: valid, and not the default object the engine keeps for each class.
function WIDGETS.isLive(object)
    local okName, fullName = pcall(function() return object:GetFullName() end)
    return object:IsValid() and not (okName and tostring(fullName):find("Default__", 1, true))
end

-- Calls fn(widget, depth) for every widget in a user widget's own tree, from WidgetTree.RootWidget down through
-- panels (GetChildrenCount and GetChildAt), to `maxDepth` (30 when left out). UWidgetTree:GetAllWidgets is C++ only,
-- not a UFunction: from Lua it raises an error. Stops at nested user widgets, which have trees of their own.
function WIDGETS.eachWidget(widget, fn, maxDepth)
    local okRoot, root = pcall(function() return widget.WidgetTree.RootWidget end)
    if not okRoot or not root then return end
    local deepest = maxDepth or 30
    local function walk(object, depth)
        if not object or not object:IsValid() or depth > deepest then return end
        fn(object, depth)
        local okCount, count = pcall(function() return object:GetChildrenCount() end)
        if not okCount or type(count) ~= "number" then return end
        for index = 0, count - 1 do
            local okChild, child = pcall(function() return object:GetChildAt(index) end)
            if okChild and child then
                walk(child, depth + 1)
            end
        end
    end
    walk(root, 0)
end

-- Sets the text of a text block the game binds to a row of its text table, which it would put back when the widget
-- is rebuilt: the binding is undone first.
function WIDGETS.setBoundText(block, words)
    UTIL.attempt("widgets: unbind a text from the game's text table", function()
        block.IsAutoTextSetWhenWidgetRebuilt = false
        block.BindTextDatatableHandle.RowName = FName("None")
    end)
    UTIL.attempt("widgets: set a bound text", function() block:SetText(FText(words)) end)
end

-- Sets a game button's label: the small labelled button's (and the Esc menu's) Text_Main, a text block bound to the
-- game's text table; else a title button's Test_Content.
function WIDGETS.setLabel(button, words)
    local okMain, main = pcall(function()
        local block = button[WIDGETS.GAME.commonButtonLabel]
        return block and block:IsValid() and block or nil
    end)
    if okMain and main then
        UTIL.took("widgets: a button's label", WIDGETS.GAME.commonButtonLabel)
        WIDGETS.setBoundText(main, words)
        return
    end
    local okTitle, title = pcall(function() return button[WIDGETS.GAME.titleButtonLabel] end)
    if not (okTitle and title) then
        UTIL.once("widgets nolabel", "widgets: a button has neither " .. WIDGETS.GAME.commonButtonLabel .. " nor "
            .. WIDGETS.GAME.titleButtonLabel .. "; its label is not set")
        return
    end
    UTIL.took("widgets: a button's label", WIDGETS.GAME.titleButtonLabel)
    UTIL.attempt("widgets: set a title button's label", function() title:SetText(FText(words)) end)
end

------------------------------------------------------------------------------------------------------------------------
-- The HUD: the hint plate, the goal banner, the debuff icons and the test tools' HUD probe sit on the HUD layout's
-- canvas (WBP_PalHUDLayout_C: SafeZone_0 > CanvasPanel, found by the Ctrl+F4 probe and seen working in game).
WIDGETS.HUD_LAYOUT = "WBP_PalHUDLayout_C"   -- the game's HUD layout, the one widget they are all put on
WIDGETS.OVER_HUD_Z = 1000                   -- the canvas Z order that puts a widget over the HUD's own widgets
local HUD_DEPTH = 3                         -- how deep under the HUD layout's root the canvas is looked for

-- The canvas of the HUD layout the player sees, and that layout; or nil, nil and why. Not the last world's, which can
-- still be listed and read visible after Return to title and another load (UTIL.ownerGone tells them apart; untested
-- in game: that the last world's HUD layout is still listed and reads visible).
function WIDGETS.hudCanvas()
    local layout
    for _, candidate in ipairs(FindAllOf(WIDGETS.HUD_LAYOUT) or {}) do
        local ok, visible = pcall(function() return candidate:IsValid() and candidate:IsVisible() end)
        if ok and visible and not UTIL.ownerGone(candidate) then
            layout = candidate
            break
        end
    end
    if not layout then return nil, nil, "no HUD layout on screen" end
    local root = layout.WidgetTree.RootWidget
    for _ = 1, HUD_DEPTH do
        if not (root and root:IsValid()) then break end
        if WIDGETS.className(root) == "CanvasPanel" then return root, layout end
        local ok, child = pcall(function() return root:GetChildAt(0) end)
        root = ok and child or nil
    end
    return nil, nil, "no canvas in the HUD layout"
end

-- A width x height box on the HUD layout with an Overlay in it, for layers (art, text, a bar). Returns both.
function WIDGETS.hudBox(layout, width, height)
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, layout)
    box:SetWidthOverride(width)
    box:SetHeightOverride(height)
    local over = WIDGETS.construct(WIDGETS.UMG.overlay, layout)
    box:AddChild(over)
    return box, over
end

-- Puts a box on the HUD's canvas, never taking a click. `place`: anchor (0..1 of the screen across and down),
-- alignment (which point of the box sits there, 0..1 of its size), position (px from there) and z (its Z order).
-- Returns the canvas slot.
function WIDGETS.pinToCanvas(canvas, box, place)
    local slot = canvas:AddChildToCanvas(box)
    pcall(function() slot:SetAnchors({ Minimum = place.anchor, Maximum = place.anchor }) end)
    pcall(function() slot:SetAlignment(place.alignment) end)
    pcall(function() slot:SetPosition(place.position) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(place.z) end)
    pcall(function() box:SetVisibility(WIDGETS.VISIBILITY.selfHitTestInvisible) end)
    return slot
end

-- A line of text that does not wrap (the HUD's lines are short and placed by hand).
function WIDGETS.textLine(owner, words, size, colour)
    local block = WIDGETS.text(owner, words, size, colour)
    pcall(function() block:SetAutoWrapText(false) end)
    return block
end

-- Whether the HUD layout at this address (UTIL.addr) is still listed by FindAllOf, which lists only live objects. A
-- file that keeps a widget on the HUD asks this before any call to it: after Return to title the old world's
-- widgets are freed, and calling one, IsValid included, can crash the game.
function WIDGETS.hudLive(address)
    for _, layout in ipairs(FindAllOf(WIDGETS.HUD_LAYOUT) or {}) do
        local ok, same = pcall(function() return UTIL.addr(layout) == address and layout:IsValid() end)
        if ok and same then return true end
    end
    return false
end

return WIDGETS
