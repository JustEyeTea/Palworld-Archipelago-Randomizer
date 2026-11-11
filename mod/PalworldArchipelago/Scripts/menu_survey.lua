-- The menus' diagnostics: logs that let a playtest's log say what the client's menus are made of (a survey of
-- the title screen, the layout around our buttons, which button has the focus, whether a heading sticks).
-- Used by menu.lua's parts.
-- Tests: mod/test/tests/title_menu.lua, mod/test/tests/inventory_page.lua; groups
--   "the title menu's Archipelago menu", "the Inventory page's mailbox button" (tools/lua_harness.sh, in CI).
local SURVEY = {}
local UTIL = require("util")
local WIDGETS = require("widgets")
local NAMES = require("menu_names")
local GAME = NAMES.GAME
local WAIT = NAMES.WAIT
local log, once = UTIL.log, UTIL.onceIn("menu")
local className, nameOf = WIDGETS.className, WIDGETS.nameOf

local CHAIN_LEVELS = 8              -- how many parents chainText names
local SURVEY_PARENT_LEVELS = 6      -- how many parents the survey names for each title button
local SURVEY_WIDGETS_MAX = 120      -- how many of the Inventory page's widgets the no-name-bar log names
local SURVEY_PAGE_DEPTH = 4         -- how deep into the page that log looks
local HEADING_LOGS = 3              -- how many updates the text window's heading is logged for
local INPUT_TYPES = { [0] = "mouse and keyboard", [1] = "gamepad", [2] = "touch" }   -- ECommonInputType

-- State. Forgotten: never (each is a once-a-session diagnostic).
local surveyed = false              -- the title screen was surveyed, or never needs it (our rows were made)
local titleUpdates = 0              -- updates at the title without our rows (the survey waits on it)
local layoutLogged = false          -- the title menu's layout was logged
local focusLogged = {}              -- "ours" | "edit" -> true: that Inventory page button's focus was logged

-- One line per widget chain: each parent's name, class and visibility (0 visible, 1 collapsed, 2 hidden).
function SURVEY.chainText(widget)
    local parts = {}
    for _ = 1, CHAIN_LEVELS do
        local okParent, parent = pcall(function() return widget:GetParent() end)
        if not okParent or not parent or not parent:IsValid() then break end
        local okVisibility, visibility = pcall(function() return parent:GetVisibility() end)
        parts[#parts + 1] = nameOf(parent) .. ":" .. className(parent)
            .. (okVisibility and ("/" .. tostring(visibility)) or "")
        widget = parent
    end
    return table.concat(parts, " < ")
end

-- Logs once where the title menu's own buttons sit, and where ours went.
function SURVEY.logLayout(menu, ourButton)
    if layoutLogged then return end
    layoutLogged = true
    for _, name in ipairs(GAME.startButtons) do
        local ok, button = pcall(function()
            local found = menu[name]
            return found and found:IsValid() and found or nil
        end)
        log("menu layout: " .. name .. (ok and button and (" | " .. SURVEY.chainText(button)) or ": not on this menu"))
    end
    if ourButton then
        log("menu layout: our button | " .. SURVEY.chainText(ourButton))
    end
end

-- The names and classes of a widget's children, for the survey.
local function childrenOf(widget)
    local children = {}
    pcall(WIDGETS.eachWidget, widget, function(object)
        local ok, child = pcall(function()
            return object:GetFName():ToString() .. ":" .. object:GetClass():GetFName():ToString()
        end)
        if ok then
            children[#children + 1] = child
        end
    end)
    return children
end

-- Logs every user widget whose class names a title or a menu, with its child widgets; how many classes.
local function surveyUserWidgets()
    local seen, classes = {}, 0
    for _, widget in ipairs(FindAllOf(GAME.userWidgetClass) or {}) do
        local ok, name = pcall(function() return widget:GetClass():GetFName():ToString() end)
        if ok and widget:IsValid() and (name:find("Title") or name:find("Menu")) and not seen[name] then
            seen[name] = true
            classes = classes + 1
            log("menu survey: " .. tostring(select(2, pcall(function() return widget:GetFullName() end)))
                .. " | children: " .. table.concat(childrenOf(widget), ", "))
        end
    end
    return classes
end

-- Logs every title button with its parents.
local function surveyTitleButtons()
    for _, button in ipairs(FindAllOf(GAME.titleButtonClass) or {}) do
        local chain, widget = {}, button
        for _ = 1, SURVEY_PARENT_LEVELS do
            local okParent, parent = pcall(function() return widget:GetParent() end)
            if not okParent or not parent or not parent:IsValid() then break end
            chain[#chain + 1] = nameOf(parent) .. ":" .. className(parent)
            widget = parent
        end
        log("menu survey: title button " .. tostring(select(2, pcall(function() return button:GetFullName() end)))
            .. " | parents: " .. table.concat(chain, " < "))
    end
end

local function survey()
    local classes = surveyUserWidgets()
    surveyTitleButtons()
    log("menu survey: done (" .. classes .. " classes)")
end

-- At the title, once: if the title menu stays up without our rows, or no title menu is found at all, the screen is
-- surveyed, so the client's real title menu can be found from a log. `looked` and `found` are this update's lookup
-- of the title menus; `rowsEverMade` whether our rows were ever made on one.
function SURVEY.ifNoMenu(looked, found, inWorld, rowsEverMade)
    if surveyed then return end
    if rowsEverMade then
        surveyed = true
        return
    end
    if inWorld then
        titleUpdates = 0
    else
        titleUpdates = titleUpdates + 1
    end
    local menuFound = looked and #found > 0
    local waited = menuFound and titleUpdates >= WAIT.surveyMenuNoButtons or titleUpdates >= WAIT.surveyNoMenu
    if not waited then return end
    surveyed = true
    log(menuFound and "menu: the title menu is here but its button list was not found; surveying"
        or "menu: the expected title menu (" .. GAME.titleMenuClass .. ") is not on this title screen; surveying")
    local ok, err = pcall(survey)
    if not ok then
        log("menu survey error: " .. tostring(err))
    end
end

-- Logs the Inventory page's widgets once, when it has no name bar to put the buttons on.
function SURVEY.inventoryPage(page)
    local parts = {}
    pcall(WIDGETS.eachWidget, page, function(object, depth)
        if #parts >= SURVEY_WIDGETS_MAX then return end
        parts[#parts + 1] = depth .. ":" .. nameOf(object) .. ":" .. className(object)
    end, SURVEY_PAGE_DEPTH)
    log("menu survey: inventory page | " .. table.concat(parts, ", "))
end

-- Whether a game button has focus: its inner WBP_PalInvisibleButton is what takes it (the class's GetFocusTarget).
local function focused(button)
    local ok, yes = pcall(function()
        local inner = button[GAME.focusTarget]
        return inner and inner:IsValid() and (inner:HasAnyUserFocus() or inner:HasFocusedDescendants())
    end)
    return ok and yes == true
end

local function inputType()
    for _, subsystem in ipairs(FindAllOf(GAME.inputSubsystem) or {}) do
        local ok, kind = pcall(function()
            return WIDGETS.isLive(subsystem) and subsystem:GetCurrentInputType() or nil
        end)
        if ok and kind ~= nil then return tostring(kind) .. " " .. (INPUT_TYPES[tonumber(kind)] or "?") end
    end
    return "unknown"
end

-- Can a controller reach the Inventory page's button? Logs once when it, and once when the page's own Edit Name, has
-- the focus, with the input type (a mouse click focuses too).
function SURVEY.focusOnce(entry, page)
    if not focusLogged.ours and focused(entry.mailbox) then
        focusLogged.ours = true
        log("menu: the inventory mailbox button has focus (input " .. inputType() .. ")")
    end
    if focusLogged.edit then return end
    local okEdit, edit = pcall(function() return page[GAME.editName] end)
    if okEdit and edit and focused(edit) then
        focusLogged.edit = true
        log("menu: the game's Edit Name button has focus (input " .. inputType() .. ")")
    end
end

-- Whether our heading sticks on the text window: logged for its first HEADING_LOGS updates.
function SURVEY.headingOnce(window, logsSoFar)
    if logsSoFar > HEADING_LOGS then return end
    local ok, reads = pcall(function()
        local heading = window[GAME.windowHeading]
        -- GetText(), not the Text field: the field comes back as a value with no ToString.
        return heading:GetText():ToString() .. " (row " .. heading.BindTextDatatableHandle.RowName:ToString() .. ")"
    end)
    log("menu: window heading reads '" .. tostring(ok and reads or ("? " .. tostring(reads))) .. "'"
        .. (UTIL.isHooked(GAME.textWindowOk) and "" or " (OK not hooked yet)"))
end

return SURVEY
