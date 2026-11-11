-- Making and reading game widgets (UMG, the engine's UI system): the engine's enum values and the UMG class paths
-- every window file passes, with the engine's own names, and the small makers the window files share.
-- Tests: mod/test/harness.lua, the groups of the files that use it: "the mailbox", "the Inventory page's mailbox
-- button", "the title menu's Archipelago menu" and "the crate window" (run by tools/lua_harness.sh).
local WIDGETS = {}
local UTIL = require("util")

-- Engine enum values with the engine's own names. A window file never passes one of these as a bare digit.
WIDGETS.VISIBILITY = { visible = 0, collapsed = 1, hidden = 2, selfHitTestInvisible = 4 }   -- ESlateVisibility
WIDGETS.HALIGN = { fill = 0, left = 1, center = 2, right = 3 }                               -- EHorizontalAlignment
WIDGETS.VALIGN = { fill = 0, top = 1, center = 2, bottom = 3 }                               -- EVerticalAlignment
WIDGETS.COLOUR_RULE = { specified = 0 }       -- ESlateColorStylingMode: UseColor_Specified (the colour given)

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
    commonButtonLabel = "Text_Main",   -- the text inside the game's small labelled button
}

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

-- A line of text, `size` points, in `colour` (a linear colour), wrapping at its box's width. When the font can't be
-- set, the text is scaled from its top-left corner to the same size instead.
function WIDGETS.text(owner, words, size, colour)
    local block = WIDGETS.construct(WIDGETS.UMG.textBlock, owner)
    local sized = pcall(function()
        local font = block.Font
        font.Size = size
        block:SetFont(font)
    end)
    if not sized then
        pcall(function()
            block:SetRenderTransformPivot({ X = 0, Y = 0 })
            block:SetRenderScale({ X = size / DEFAULT_FONT_SIZE, Y = size / DEFAULT_FONT_SIZE })
        end)
    end
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

-- The game's own small labelled button (WBP_CommonButton_C, as the Inventory page's Edit Name). Raises an error
-- when the game's button class can't be had.
function WIDGETS.makeButton(owner, label)
    local class = UTIL.findClass(WIDGETS.GAME.commonButton)
    local library = StaticFindObject(WIDGETS.UMG.widgetLibrary)
    if not (class and library) then
        error("no WBP_CommonButton_C")
    end
    local button = library:Create(owner, class, nil)
    pcall(function() button[WIDGETS.GAME.commonButtonLabel]:SetText(FText(label)) end)
    return button
end

return WIDGETS
