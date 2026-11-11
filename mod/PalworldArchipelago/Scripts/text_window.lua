-- The game's text window (the world-name window), for one field at a time: the title menu's window layout uses
-- it. Wired by menu.lua (its update and its OK hook).
-- Tests: mod/test/tests/title_menu.lua; group "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local TEXT = {}
local UTIL = require("util")
local WIDGETS = require("widgets")
local SURVEY = require("menu_survey")
local NAMES = require("menu_names")
local GAME = NAMES.GAME
local log, once = UTIL.log, UTIL.onceIn("menu")

local NOTHING = "\1"                -- what the window's result holds until OK is pressed

-- The fields the window layout edits in the text window.
TEXT.FIELDS = {
    addr = { title = "Server address (host, or host:port)" },
    port = { title = "Port (the number after the colon in the room's address)" },
    slot = { title = "Your slot name" },
    password = { title = "Room password (empty if none)", hidden = true },
}

-- State: the field asked for. Forgotten: when the window closes (TEXT.update), or when it can't be opened.
-- Its life: TEXT.ask opens the window -> the player types -> OK (its hook) notes the answer -> the window closes ->
-- the next update hands the answer to `done`. Closed without OK, it is cancelled.
local asking = nil   -- { field, value = what the window starts with, done = function(answer), parameter, hud, id,
                     --   answer = what OK gave (nil before OK), headingLogs = updates its heading was logged }

-- Sets the window's heading. It is bound to a text-table row ("WorldName"), which it puts back on rebuild.
local function setHeading(window, title)
    local okHeading, heading = pcall(function() return window[GAME.windowHeading] end)
    if okHeading and heading then
        WIDGETS.setBoundText(heading, title)
        return
    end
    once("noheading", "menu: the text window has no " .. GAME.windowHeading .. "; its heading is the game's")
end

local function openWindow(context)
    local hud = StaticFindObject(GAME.palUtility):GetHUDService(context)
    local parameterClass = UTIL.findClass(GAME.textWindowParameter)
    local parameter = StaticFindObject(GAME.gameplayStatics):SpawnObject(parameterClass, hud)
    parameter.DefaultInputName = asking.value or ""
    parameter.OutString = NOTHING
    asking.parameter, asking.hud = parameter, hud
    asking.id = hud:Push(UTIL.findClass(GAME.textWindow), parameter)
    local window = hud:GetWidget(asking.id)
    if not (window and window:IsValid()) then return end
    setHeading(window, asking.field.title)
    if asking.field.hidden then
        pcall(function() window[GAME.windowTextBox]:SetIsPassword(true) end)
    end
end

-- Opens the text window for one field; done(answer) gets what was typed, once the window has closed after OK.
function TEXT.ask(button, field, value, done)
    asking = { field = field, value = value, done = done, headingLogs = 0 }
    local ok, err = pcall(openWindow, button)
    if not ok then
        log("menu: could not open the text window: " .. tostring(err))
        asking = nil
    end
end

-- Whether the text window is up for a field.
function TEXT.asking()
    return asking ~= nil
end

-- The OK button's hook: notes the answer (the window closes by itself; the next update hands it on).
local function okPressed()
    if not asking or not asking.parameter or not asking.parameter:IsValid() then return end
    local text = asking.parameter.OutString
    text = tostring(text and text.ToString and text:ToString() or text)
    if text == NOTHING then return end
    asking.answer = text:match("^%s*(.-)%s*$")
    asking.parameter = nil
end

function TEXT.onOk()
    local ok, err = pcall(okPressed)
    if not ok then
        log("menu OK error: " .. tostring(err))
    end
end

-- Every update while a field is asked for: keeps the window's heading, and once the window closes hands the answer on
-- (or says it was cancelled). Before the title menus' update, so a value typed shows in the rows in the same update.
function TEXT.update()
    if not asking then return end
    local open, window = false, nil
    pcall(function()
        window = asking.hud:GetWidget(asking.id)
        open = window and window:IsValid()
    end)
    if open and not asking.answer then
        setHeading(window, asking.field.title)
        asking.headingLogs = asking.headingLogs + 1
        SURVEY.headingOnce(window, asking.headingLogs)
    end
    if open then return end
    local answer, done, field = asking.answer, asking.done, asking.field
    asking = nil
    if not answer then
        log("menu: the \"" .. field.title .. "\" window was closed without OK")
        return
    end
    local ok, err = pcall(done, answer)
    if not ok then
        log("menu: field error: " .. tostring(err))
    end
end

return TEXT
