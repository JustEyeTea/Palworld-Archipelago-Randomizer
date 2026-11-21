-- The mailbox's hidden chest window's heading: set to the mailbox's name, with the mailbox emblem beside it where
-- the window is surely the mailbox's (HEADING.dress, every update while the window shows). Used by mailbox_chest.lua.
-- Tests: mod/test/tests/mailbox.lua; group "the mailbox" (tools/lua_harness.sh, in CI).
local HEADING = {}
local UTIL = require("util")
local WIDGETS = require("widgets")
local log = UTIL.log

-- What mailbox.lua hands over, through mailbox_chest.lua (HEADING.install): see mailbox_chest.lua.
local LIST, once

function HEADING.install(handedOver)
    LIST, once = handedOver.list, handedOver.once
end

-- State: none of its own. The chest view is mailbox_chest.lua's, handed to HEADING.dress.

local HEADING_GAME = {
    chestMenuClass = "WBP_IngameMenu_Chest_C",            -- the part of the chest window that holds the heading
    chestMenu = "WBP_IngameMenu_Chest",                   -- that part, as a field of the HUD's widget
    heading = "Text_TargetContainerName",                 -- the chest window's heading
    emblemArt = "ap-mailbox-emblem-64",                   -- art/ap-mailbox-emblem-64.png beside the heading
}
local EMBLEM_SIZE = 32               -- the emblem's side beside the heading, in the window's units
local EMBLEM_GAP = 8                 -- between the heading and the emblem
local HEADING_ROW_LEVELS = 3         -- how far above the heading the row it sits in is looked for

-- The mailbox emblem (art/ap-mailbox-emblem-64.png) beside the heading, once a view, only where the heading sits in a
-- horizontal box within HEADING_ROW_LEVELS above it (it sits in a SizeBox; the row is further up); the chain of
-- parents is logged either way. Untested in game: whether the emblem shows beside the heading.
local function addEmblemOnce(view, heading)
    if view.emblem then return end
    view.emblem = true
    local row, widget, chain = nil, heading, {}
    for _ = 1, HEADING_ROW_LEVELS do
        local okParent, parent = pcall(function() return widget:GetParent() end)
        if not (okParent and parent and parent:IsValid()) then break end
        local okName, kind = pcall(function()
            return parent:GetFName():ToString() .. ":" .. parent:GetClass():GetFName():ToString()
        end)
        chain[#chain + 1] = okName and kind or "?"
        if okName and kind:find(":HorizontalBox$") then
            row = parent
            break
        end
        widget = parent
    end
    if not row then
        log("mailbox: no row above the heading (" .. table.concat(chain, " < ") .. "); no emblem")
        return
    end
    local box = require("art").box(row, HEADING_GAME.emblemArt, EMBLEM_SIZE, EMBLEM_SIZE)
    if not box then return end
    local slot = row:AddChild(box)
    pcall(function() slot:SetVerticalAlignment(WIDGETS.VALIGN.center) end)
    pcall(function() slot:SetPadding({ Left = EMBLEM_GAP, Top = 0, Right = 0, Bottom = 0 }) end)
    log("mailbox: emblem added beside the heading (" .. table.concat(chain, " < ") .. ")")
end

-- Whether a widget answers as valid. An IsValid that raises counts as valid too: the heading is there, Lua just
-- can't ask it.
local function answersValid(widget)
    return widget and select(2, pcall(function() return widget:IsValid() end))
end

-- The chest window's heading, and whether it was found through the mailbox's own HUD widget (chests share the window
-- class, so only that one is surely ours); else any chest window's heading that shows.
local function findHeading(view)
    local heading = nil
    pcall(function() heading = view.hud:GetWidget(view.id)[HEADING_GAME.chestMenu][HEADING_GAME.heading] end)
    if answersValid(heading) then
        UTIL.took("mailbox: the chest window's heading", "found by the HUD's id")
        return heading, true
    end
    for _, widget in ipairs(FindAllOf(HEADING_GAME.chestMenuClass) or {}) do
        local ok, found = pcall(function()
            return widget:IsValid() and widget:IsVisible() and widget[HEADING_GAME.heading]
        end)
        if ok and found then
            UTIL.took("mailbox: the chest window's heading", "found by its class " .. HEADING_GAME.chestMenuClass)
            return found, false
        end
    end
    return nil, false
end

-- Sets the heading to the mailbox's name. The heading is bound to the game's text table, which puts its own text back
-- when the window rebuilds: it is unbound first.
local function nameTheChestWindow(heading)
    local okRead, now = pcall(function() return heading:GetText():ToString() end)
    if okRead and now == LIST.TITLE then return end
    WIDGETS.setBoundText(heading, LIST.TITLE)
    once("heading", "mailbox: chest window heading was '" .. tostring(okRead and now or "?") .. "'; set to ours")
end

-- The view's chest window's heading named, and the emblem beside it where the window is surely the mailbox's.
function HEADING.dress(view)
    local heading, ours = findHeading(view)
    if ours then
        local ok, err = pcall(addEmblemOnce, view, heading)
        if not ok then
            once("emblem", "mailbox: emblem error: " .. tostring(err))
        end
    end
    if not heading then
        once("noheading", "mailbox: no chest window heading found")
        return
    end
    nameTheChestWindow(heading)
end

return HEADING
