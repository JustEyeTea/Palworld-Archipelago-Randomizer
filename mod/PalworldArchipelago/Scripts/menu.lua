-- The mod's buttons in the game's menus: the title screen's Archipelago menu (opened from its banner), the
-- "Archipelago Mailbox" button on the Esc menu and on the Inventory page, and the game's text window the title menu
-- falls back to. Built from the game's own widgets, so they look and work like the game's. Wired by main.lua.
-- Tests: mod/test/harness.lua, groups "the title menu's Archipelago menu", "the Inventory page's mailbox button" and
-- the Esc menu's tests in "the mailbox" (run by tools/lua_harness.sh).
local M = {}
local ART = require("art")
local CLICKS = require("clicks")
local UTIL = require("util")
local WIDGETS = require("widgets")
local log, once = UTIL.log, UTIL.onceIn("menu")
local className, nameOf, setLabel = WIDGETS.className, WIDGETS.nameOf, WIDGETS.setLabel
local COLLAPSED = WIDGETS.VISIBILITY.collapsed
local HALIGN, VALIGN = WIDGETS.HALIGN, WIDGETS.VALIGN

-- Where the game's names below come from: "kdump", a tool that reads the game's Blueprints (widget trees, bound
-- events, script) out of the dedicated server's pak files as JSON; how to run it is in the palworld-modding skill's
-- references/research-and-testing.md. The client's widgets can differ from the server's: where a name was read from
-- kdump and not yet seen in the client, the untested-in-game list below says so.
--
-- Untested in game (each mark is about this file only):
--   * the Inventory page's mailbox button, placed on the page's name bar as the server's files lay it out;
--   * whether a controller can reach that button (the focus logs below report it);
--   * Close() on the in-game main menu from Lua, which the Inventory page's button uses to close the menu.

local TITLE_FOLDER = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local TITLE_BUTTON = WIDGETS.TITLE_BUTTON.path
local TITLE_EVENT = ":BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_"
local TEXT_WINDOW = TITLE_FOLDER .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C"
local ESC_BUTTON = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C"
-- Calls on the game's own fields and functions go through UTIL.attempt (or WIDGETS.setLabel, setBoundText and show),
-- which log once when one fails: then the game is not as the mod expects. The plain pcalls left are styling
-- (padding, alignment, colours, fonts, opacity): a failure there is harmless, the widget only looks plainer.

-- The game's names this file depends on. After a Palworld update, check that each one still exists.
local GAME = {
    titleMenuClass = "WBP_TitleMenu_C",                   -- the title screen's menu (its live copy, not its template)
    titleButton = TITLE_BUTTON,                           -- the title menu's own button
    titleButtonClass = "WBP_Title_MenuButton_C",
    -- A title button's click, hover and unhover: component events 0, 1 and 2 (kdump: OnButtonBaseClicked,
    -- OnButtonBaseHovered, OnButtonBaseUnhovered), all three ending in CommonButtonBaseClicked.
    titleClick = TITLE_BUTTON .. TITLE_EVENT .. "0_CommonButtonBaseClicked__DelegateSignature",
    titleHover = TITLE_BUTTON .. TITLE_EVENT .. "1_CommonButtonBaseClicked__DelegateSignature",
    titleUnhover = TITLE_BUTTON .. TITLE_EVENT .. "2_CommonButtonBaseClicked__DelegateSignature",
    startButtons = { "WBP_Title_MenuButton_StartLocalGame", "WBP_Title_MenuButton_StartMultiGame_InviteCode",
                     "WBP_Title_MenuButton_ExitGame" },  -- the title menu's buttons whose panel is the button list
    exitButton = "WBP_Title_MenuButton_ExitGame",         -- Quit Game
    fallbackList = "VerticalBox_0",                       -- the server's files' button list (the client lays it out
                                                          -- differently: the last of three ways to find the list)
    textWindow = TEXT_WINDOW,                             -- the world-name window, used for one field at a time
    textWindowOk = TEXT_WINDOW .. ":BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_"
        .. "ComponentBoundEvent_5_OnClicked__DelegateSignature",
    textWindowParameter = TITLE_FOLDER .. "BP_HUDDispatchParameter_WorldNameInput."
        .. "BP_HUDDispatchParameter_WorldNameInput_C",
    windowHeading = "Text_Head",                          -- the text window's heading (bound to the text table)
    windowTextBox = "PalEditableTextBox_0",               -- the text window's text box
    escMenuClass = "WBP_MenuESC_C",                       -- the client's Esc menu (kdump), by its exact class
    escButton = ESC_BUTTON,                               -- the Esc menu's own small button
    escClick = ESC_BUTTON .. ":BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_"
        .. "CommonButtonBaseClicked__DelegateSignature",
    -- The game's small labelled button's click: component event 3 (4 and 5 are its hover and unhover; kdump: the
    -- class's ComponentDelegateBinding). It fires for every one in the game: clicks.lua notes only claimed ones.
    commonClick = WIDGETS.GAME.commonButton .. ":BndEvt__WBP_CommonButton_WBP_PalInvisibleButton_K2Node_"
        .. "ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature",
    mainMenuClass = "WBP_InGameMainMenu_C",               -- the in-game main menu: its tabs hold the Esc menu and more
    inventoryTab = "WBP_InventoryEquipment_ForDisplay_C", -- the main menu's Inventory tab (a new one per visit)
    inventoryPage = "WBP_InventoryEquipment",             -- the tab's page, a designer child of it
    nameBarFrom = { "SizeBox_NameEdit", "Text_CharacterName" },   -- the page's widgets in its name bar's row
    editName = "WBP_CommonButton_NameEdit",               -- the page's own Edit Name button
    focusTarget = "WBP_PalInvisibleButton",               -- the part of a game button that takes the focus
    inputSubsystem = "CommonInputSubsystem",
    palUtility = "/Script/Pal.Default__PalUtility",
    gameplayStatics = "/Script/Engine.Default__GameplayStatics",
    palTextBox = "/Script/Pal.PalEditableTextBox",        -- the game's own text box class
    userWidgetClass = "UserWidget",
}
-- Game functions called: GetHUDService, Push, GetWidget, SpawnObject, CloseAction, Close, CloseOwnerStackableUI,
-- GetCurrentInputType, Create, and the UMG widgets' own functions.

-- The clock (UTIL.updates turns seconds into updates of 300 ms).
local WAIT = {
    surveyMenuNoButtons = UTIL.updates(6),   -- the title menu is up this long without our rows: survey the screen
    surveyNoMenu = UTIL.updates(30),         -- no title menu found this long at the title: survey the screen
    mainMenuLook = UTIL.updates(0.6),        -- after closing the main menu for the mailbox, look whether it went
}
local EVERY = {
    titleLookInWorld = UTIL.updates(3),      -- in a world, a title menu is looked for only this often
    escFallbackLook = UTIL.updates(1.2),     -- until a main menu is seen, the Esc menu is looked for this often
    failedMenuRetry = UTIL.updates(3),       -- a title menu whose rows keep failing is tried again this often
}
local FAILS_BEFORE_BACKOFF = 10    -- failed builds in a row before a menu is tried only every EVERY.failedMenuRetry
local LOGGED_FAILURES = 5          -- failed builds logged in a row (the next run of failures is logged again)

-- Sizes, in screen units at the game's UI scale.
local MENU_WIDTH = 600              -- the title buttons' width: our rows and the banner match it
local BANNER_HEIGHT = 150           -- the banner (art/ap-title-banner.png, 1200x300, shown at half size)
local BANNER_GAP = 8                -- between the banner's bottom and the button list's top
local PICK_WIDTH = 420              -- a saved server's row, narrower than the menu: it sits in its own panel
local ROW_HEIGHT = WIDGETS.TITLE_BUTTON.height   -- a row of ours, as the title buttons are
local ROW_GAP = WIDGETS.TITLE_BUTTON.gap         -- below a row that has no backing
local ROW_STEP = ROW_HEIGHT + ROW_GAP   -- from one row to the next; a backed row is this high, with no gap, so the
                                        -- backings meet and read as one panel
local PAD_TOP, PAD_BOTTOM = 24, 16  -- the panel's soft ends, in rows of their own above Server and below Back
local BAR_BUTTON = { w = 230, h = 28 }   -- the Inventory page's buttons: Edit Name's height; the label fits in 216
local INVENTORY_EMBLEM = 24         -- the mailbox emblem's side, beside the Inventory page's button
local EMBLEM_RIGHT = BAR_BUTTON.w + 6   -- the emblem's right padding: just left of the mailbox button
local CRATE_RIGHT = EMBLEM_RIGHT + INVENTORY_EMBLEM + 8   -- the crate button's: just left of the emblem
local ESC_BUTTON_GAP = 10           -- above each of the Esc menu's buttons, as the game spaces them
local LABEL_FONT = 20               -- a typed row's label
local LABEL_GAP = 12                -- between a typed row's label and its text box
local PICK_PANEL_Z = 20             -- the saved servers' panel's ZOrder: over the rows below the Server box
local PICK_PANEL_PAD = { Left = 8, Top = 4, Right = 8, Bottom = 4 }
local PICKS = 6                     -- saved servers offered under the Server box, at most
local STARS_MAX = 12                -- a password shows as at most this many stars
local LIST_LEVELS = 5               -- how far above a title button its button list is looked for

-- Engine enum values this file passes that widgets.lua does not name.
local ESC_CONTINUE = 0              -- EPalESCMenuType Continue: what a click does if the menu ever binds our button
local BRUSH_BOX = 1                 -- ESlateBrushDrawType::Box: a brush drawn with its margins kept their width
local SIZE_FILL = 1                 -- ESlateSizeRule::Fill (a horizontal box's slot takes the room left)

-- The owners of this file's buttons in clicks.lua: the title menus' rows run at the next game tick (claimSoon); the
-- in-world mailbox buttons at the end of an update; the Inventory page's crate button at its start.
local TITLE_OWNER, WORLD_OWNER, CRATE_OWNER = "menu title", "menu world", "menu crate"

-- What main.lua hands over (M.install).
--   status()                        the connection: "connected", "connecting", or another word for neither
--   server(), slot(), password()    what config.txt holds
--   connect(server, slot, password) connects, replacing any connection there is
--   disconnect()
--   openMailbox()                   asks the mailbox to open (it waits for the menu to close)
--   servers()                       optional: the saved servers offered under the Server box
--   rememberServer(server)          optional: saves a server connected to
--   mailboxLabel()                  optional: the mailbox buttons' label; without it there are no in-world buttons
--   crateLabel()                    optional: the crate button's label, or nil to fold it away
--   openCrate()                     optional: opens the next crate
--   guardedHook(name, fn)           optional: a hook callback that no update can run inside
local api
-- State. Forgotten: never (made once, in M.install).
local hookCallbacks = {}      -- hook path -> its callback (the hover, unhover and text window OK hooks)

------------------------------------------------------------------------------------------------------------------------
-- Diagnostics: logs that let a playtest's log say what the client's menus are made of.

local SURVEY = {}
do -- (each part keeps its locals to itself: one chunk can hold only 200, and the parts become files of their own)
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
end

------------------------------------------------------------------------------------------------------------------------
-- The game's text window (the world-name window), for one field at a time: the title menu's window layout uses it.

local TEXT = {}
do -- (each part keeps its locals to itself: one chunk can hold only 200, and the parts become files of their own)
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
end

------------------------------------------------------------------------------------------------------------------------
-- In a world: an "Archipelago Mailbox" button on the Esc menu and on the Inventory page, and the crate button beside
-- the latter. The game makes a new Esc menu and a new Inventory page each time they open, so each is known by its
-- address and forgotten (its buttons released) when it is no longer found: the engine reuses an address once its
-- widget is gone.

local WORLD = {}
do -- (each part keeps its locals to itself: one chunk can hold only 200, and the parts become files of their own)
local BOXES = WIDGETS.BOXES
local ESC_BUTTONS_MIN = 3           -- a box of at least this many buttons of one class is the Esc menu's button box

-- State: the Esc menus with our button. Forgotten: an entry when its menu is no longer found (forgetGoneEscMenus).
local escMenus = {}           -- an Esc menu's address -> { mailbox = our button, menu = the Esc menu, label }
-- State: the Inventory pages with our buttons. Forgotten: an entry when its page is no longer found (forgetGonePages).
local pages = {}              -- a page's address -> { mailbox, page, main = the main menu showing it (kept fresh),
                              --   crate = { button, box } or nil, label, crateLabel }
local pagesFailed = {}        -- a page's address -> true: adding the buttons failed there (each try makes a widget)
-- State: the in-game main menu. Forgotten: mainMenuNow at every look, mainMenuLook when it is done; the rest never.
local mainMenuNow = nil       -- whether a live main menu was up at this update's look (nil: not looked yet)
local mainMenuSeen = false    -- a main menu was ever seen (until then the Esc menu is also looked for by its class)
local fallbackUpdates = 0     -- updates the Esc menu was looked for without a main menu
local mainMenuLook = nil      -- updates until the look whether the main menu closed for the mailbox (a diagnostic)
local lookFrom = nil          -- which button that look follows: "esc" | "inventory"
-- State: log-once flags and counts. Forgotten: never.
local escLogged, pageLogged, noBarSaid = false, false, false
local escAdds, pageAdds = 0, 0   -- buttons added (the first is logged with where it went)

-- The class of a box's child, looking inside a size box or overlay that wraps it.
local function buttonClassOf(child)
    local class = className(child)
    if class ~= "SizeBox" and class ~= "Overlay" then return class end
    local okInner, inner = pcall(function() return child:GetChildAt(0) end)
    if okInner and inner and inner:IsValid() then return className(inner) end
    return class
end

-- How many of a box's children are buttons of each class (ours not counted).
local function buttonCounts(box)
    local counts = {}
    local okCount, count = pcall(function() return box:GetChildrenCount() end)
    for index = 0, (okCount and count or 0) - 1 do
        local okChild, child = pcall(function() return box:GetChildAt(index) end)
        if okChild and child and child:IsValid() then
            local class = buttonClassOf(child)
            if class:match("Button.*_C$") and not CLICKS.isClaimed(child) then
                counts[class] = (counts[class] or 0) + 1
            end
        end
    end
    return counts
end

-- The box in the Esc menu whose children are mostly buttons of one class; nil below ESC_BUTTONS_MIN.
local function escButtonBox(menu)
    local best, bestCount = nil, ESC_BUTTONS_MIN - 1
    WIDGETS.eachWidget(menu, function(object)
        if not BOXES[className(object)] then return end
        for _, count in pairs(buttonCounts(object)) do
            if count > bestCount then
                best, bestCount = object, count
            end
        end
    end)
    return best
end

-- The live Esc menus (only the client has one). The first time one is found, where its buttons are is logged.
local function findEscMenus()
    local found = {}
    for _, widget in ipairs(FindAllOf(GAME.escMenuClass) or {}) do
        if WIDGETS.isLive(widget) then
            found[#found + 1] = widget
        end
    end
    if found[1] and not escLogged then
        escLogged = true
        local okBox, box = pcall(escButtonBox, found[1])
        log("menu: the Esc menu is " .. GAME.escMenuClass .. " (" .. #found .. " found; buttons in "
            .. (okBox and box and (className(box) .. " " .. nameOf(box)) or ("none: " .. tostring(box))) .. ")")
    end
    return found
end

-- The Inventory page of an in-game main menu, through the tab it shows (CurrentContentWidget). Returns the page and
-- the tab's class, or nil, the tab's class (or "nothing") and why there is no page.
local function readTab(mainMenu)
    local tab = mainMenu.CurrentContentWidget
    if not tab or not tab:IsValid() then return nil, "nothing" end
    local class = className(tab)
    if class ~= GAME.inventoryTab then return nil, class end
    local page = tab[GAME.inventoryPage]
    if page and page:IsValid() then return page, class end
    return nil, class, "has no valid " .. GAME.inventoryPage
end

-- Logs once each tab class the main menu shows (readTab's answer), so a missing button has a reason in the log.
local function logTabOnce(ok, page, tabClass, why, tabType)
    if not ok then
        once("mmerr", "menu: could not read the main menu's tab: " .. tostring(page))
        return
    end
    once("mmtab" .. tabClass, "menu: main menu content is " .. tabClass .. " (tab " .. tabType .. ")")
    if not why then return end
    once("invnopage", "menu: the main menu's " .. tabClass .. " " .. why .. "; no mailbox button there")
end

-- The Inventory pages up now: { page, main } for each main menu showing one. A tab the menu let go of stays valid
-- until it is collected, so only a menu's current tab counts; FindAllOf on the page's class would find the wrapper's
-- template too. Each tab class the main menu shows is logged once, so a missing button has a reason in the log.
local function inventoryPagesOf(mainMenus)
    local found = {}
    for _, mainMenu in ipairs(mainMenus) do
        local ok, page, tabClass, why = pcall(readTab, mainMenu)
        local okTab, tabType = pcall(function() return mainMenu.CurrentTabType end)
        tabType = tostring(okTab and tabType or "?")
        logTabOnce(ok, page, tabClass, why, tabType)
        if ok and page then
            found[#found + 1] = { page = page, main = mainMenu }
            if not pageLogged then
                pageLogged = true
                log("menu: the inventory page is " .. className(page)
                    .. " (via the main menu's CurrentContentWidget, tab " .. tabType .. ")")
            end
        end
    end
    return found
end

-- One object scan per update while the main menu is closed (FindAllOf walks the whole object array): the main menu,
-- and only while one is up the Esc menu (its Options tab) and the Inventory page (its tab, no scan of its own). Until
-- a main menu was ever seen, the Esc menu is also looked for by its class every EVERY.escFallbackLook, in case the
-- client names the main menu differently. Returns whether the Esc menus were looked for, the ones found (empty when
-- none is up) and the Inventory pages up.
local function menusUp()
    local mainMenus = {}
    for _, mainMenu in ipairs(FindAllOf(GAME.mainMenuClass) or {}) do
        if WIDGETS.isLive(mainMenu) then
            mainMenus[#mainMenus + 1] = mainMenu
        end
    end
    if mainMenus[1] then
        mainMenuSeen = true
    end
    mainMenuNow = mainMenus[1] ~= nil
    local escLooked, escFound = true, {}
    if mainMenus[1] then
        escFound = findEscMenus()
    elseif not mainMenuSeen then
        fallbackUpdates = fallbackUpdates + 1
        escLooked = UTIL.isDue(fallbackUpdates, EVERY.escFallbackLook, 1)
        escFound = escLooked and findEscMenus() or {}
        if escFound[1] then
            once("escnomain", "menu: the Esc menu is up but no " .. GAME.mainMenuClass
                .. " was found (looking by its class every 4th update)")
        end
    end
    return escLooked, escFound, inventoryPagesOf(mainMenus)
end

-- The mailbox button was clicked (after its hook): the menu it is on closes, then the mailbox opens. The Esc menu is
-- one tab of the main menu: its own CloseAction (what backing out of it does) closes the whole menu; its Close shuts
-- only its tab. From the Inventory page, Close() on the main menu itself: what its X button and the Inventory tab's
-- cancel call (kdump); not OnCancelAction, which during a status-point edit cancels the edit and leaves the menu open.
local function closeMenuForMailbox(from, menu, mainMenu, button)
    local how = nil
    if from == "inventory" then
        if mainMenu and mainMenu:IsValid() and pcall(function() mainMenu:Close() end) then
            how = "Close"
        end
    elseif menu and menu:IsValid() then
        if pcall(function() menu:CloseAction() end) then
            how = "CloseAction"
        elseif pcall(function() menu:Close() end) then
            how = "Close"
        end
    end
    if not how then
        pcall(function() StaticFindObject(GAME.palUtility):GetHUDService(button):CloseOwnerStackableUI(button) end)
        how = "CloseOwnerStackableUI"
    end
    log(from == "inventory" and ("menu: main menu closed for the mailbox from the inventory (" .. how .. ")")
        or ("menu: Esc menu closed for the mailbox (" .. how .. ")"))
    mainMenuLook, lookFrom = WAIT.mainMenuLook, from
    api.openMailbox()
end

-- The Esc menu's own small button (WBP_MenuESC_Button_S, as Emergency Respawn and Return to Title), straight in the
-- box with the game's spacing. The menu binds its buttons' clicks when it is built, so ours stays unbound and only
-- our hook answers it; its MenuType is set to Continue (close the menu) all the same. Without that class, a title
-- button in a row of its own.
local function addEscButton(menu, list)
    if not UTIL.findClass(GAME.escButton) then
        once("escstyle", "menu: no Esc menu button class; using a title button")
        local button = WIDGETS.create(menu, GAME.titleButton)
        if button then
            WIDGETS.addToList(menu, list, button, ROW_HEIGHT, ROW_GAP, nil)
        end
        return button
    end
    local button = WIDGETS.create(menu, GAME.escButton)
    if not button then return nil end
    pcall(function() button.MenuType = ESC_CONTINUE end)
    local slot = list:AddChild(button)
    pcall(function() slot:SetPadding({ Left = 0, Top = ESC_BUTTON_GAP, Right = 0, Bottom = 0 }) end)
    return button
end

-- The addresses of the widgets found this update.
local function foundNow(found, widgetOf)
    local set = {}
    for _, item in ipairs(found) do
        set[UTIL.addr(widgetOf(item)) or ""] = true
    end
    return set
end

-- Sets a mailbox button's label when the mailbox's count changed.
local function refreshLabel(entry)
    local text = api.mailboxLabel()
    if entry.label == text then return end
    entry.label = text
    setLabel(entry.mailbox, text)
end

local function forgetGoneEscMenus(found)
    local live = foundNow(found, function(menu) return menu end)
    for key, entry in pairs(escMenus) do
        if not live[key] or not entry.menu:IsValid() then
            pcall(CLICKS.release, entry.mailbox)
            escMenus[key] = nil
        end
    end
end

-- Adds the mailbox button to an Esc menu; its record, or nil when it could not be added.
local function addEscMailbox(menu, key)
    local okBox, list = pcall(escButtonBox, menu)
    local okAdd, button = false, nil
    if okBox and list then
        okAdd, button = pcall(addEscButton, menu, list)
    end
    if not (okAdd and button) then
        once("escadd", "menu: could not add the mailbox button: " .. tostring(button or list))
        return nil
    end
    local entry = { mailbox = button, menu = menu }
    CLICKS.claim(button, WORLD_OWNER, function(clicked) closeMenuForMailbox("esc", entry.menu, nil, clicked) end)
    escMenus[key] = entry
    escAdds = escAdds + 1
    if escAdds == 1 then
        log("menu: Archipelago Mailbox button added to the Esc menu (" .. className(button) .. ") | "
            .. SURVEY.chainText(button))
    end
    return entry
end

-- Every update the main menu is up, so the button is there as the menu opens: a menu's tree is only walked when it is
-- new, and the label only set when it changes. `found` is the Esc menus up now (none when no main menu is).
local function updateEsc(found)
    forgetGoneEscMenus(found)
    for _, menu in ipairs(found) do
        if menu:IsValid() then
            local key = UTIL.addr(menu)
            local entry = escMenus[key]
            if not entry or not entry.mailbox:IsValid() then
                entry = addEscMailbox(menu, key)
            end
            if entry then
                refreshLabel(entry)
            end
        end
    end
end

-- The page's name bar (CanvasPanelChara > Overlay_0, 996x32; kdump). Its row (HorizontalBox_0) holds the game's Edit
-- Name button in SizeBox_NameEdit, then the player's name, both on the left: the bar's right end is empty. The bar is
-- not a variable of the page, so it is reached from the row's widgets. Returns the bar, or nil and why.
local function nameBar(page)
    local why = {}
    for _, field in ipairs(GAME.nameBarFrom) do
        local ok, bar, miss = pcall(function()
            local widget = page[field]
            if not widget or not widget:IsValid() then return nil, "no " .. field end
            local row = widget:GetParent()
            if not row or not row:IsValid() or className(row) ~= "HorizontalBox" then
                return nil, field .. " is in " .. (row and className(row) or "nothing")
            end
            local found = row:GetParent()
            if not found or not found:IsValid() or className(found) ~= "Overlay" then
                return nil, field .. "'s row is in " .. (found and className(found) or "nothing")
            end
            return found
        end)
        if ok and bar then return bar end
        why[#why + 1] = ok and tostring(miss) or tostring(bar)
    end
    return nil, table.concat(why, "; ")
end

-- One of the game's small buttons at the bar's right end, BAR_BUTTON big, `rightPadding` in from it; the button and
-- its box, or nil when it was not made. An Overlay slot starts at Left/Top: Right, and Fill as the Edit Name row is.
local function makeBarButton(page, bar, rightPadding)
    local button = WIDGETS.create(page, WIDGETS.GAME.commonButton)
    if not button then return nil end
    local box = WIDGETS.construct(WIDGETS.UMG.sizeBox, page)
    box:SetWidthOverride(BAR_BUTTON.w)
    box:SetHeightOverride(BAR_BUTTON.h)
    box:AddChild(button)
    local slot = bar:AddChild(box)
    pcall(function() slot:SetHorizontalAlignment(HALIGN.right) end)
    pcall(function() slot:SetVerticalAlignment(VALIGN.fill) end)
    if rightPadding then
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = rightPadding, Bottom = 0 }) end)
    end
    return button, box
end

-- The mailbox emblem (art/ap-mailbox-emblem-64.png) just left of the mailbox button.
local function addPageEmblem(page, bar)
    local okEmblem, emblem = pcall(ART.box, page, "ap-mailbox-emblem-64", INVENTORY_EMBLEM, INVENTORY_EMBLEM)
    if not (okEmblem and emblem) then return end
    local slot = bar:AddChild(emblem)
    pcall(function()
        slot:SetHorizontalAlignment(HALIGN.right)
        slot:SetVerticalAlignment(VALIGN.center)
    end)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = EMBLEM_RIGHT, Bottom = 0 }) end)
end

-- The crate button (crates.lua), left of the emblem, collapsed until there is a crate; { button, box }, or nil.
local function addCrateButton(page, bar)
    local crate = nil
    local ok = pcall(function()
        local button, box = makeBarButton(page, bar, CRATE_RIGHT)
        if not button then
            error("the crate button was not made")
        end
        WIDGETS.show(box, false)
        crate = { button = button, box = box }
    end)
    if not ok then
        once("cratebtn", "menu: could not add the crate button to the inventory page")
    end
    return crate
end

-- The page's buttons at the right end of its name bar: the mailbox button, its emblem and the crate button. The page
-- binds only its own Edit Name's OnClicked, so ours stay unbound and only our hook answers them. Returns the mailbox
-- button and the crate { button, box } (or nil), or nil and why.
local function addPageButtons(page, bar)
    if not UTIL.findClass(WIDGETS.GAME.commonButton) then return nil, "no WBP_CommonButton_C" end
    local button = makeBarButton(page, bar, nil)
    if not button then return nil, "the button was not made" end
    addPageEmblem(page, bar)
    return button, addCrateButton(page, bar)
end

local function forgetGonePages(found)
    local live = foundNow(found, function(entry) return entry.page end)
    for key, entry in pairs(pages) do
        if not live[key] or not entry.page:IsValid() then
            pcall(CLICKS.release, entry.mailbox)
            if entry.crate then
                pcall(CLICKS.release, entry.crate.button)
            end
            pages[key] = nil
        end
    end
    for key in pairs(pagesFailed) do
        -- a later page may reuse the address
        if not live[key] then
            pagesFailed[key] = nil
        end
    end
end

local function openCrate()
    if api.openCrate then
        api.openCrate()
    end
end

-- Adds the buttons to a page found up; its record, or nil.
local function addToPage(found, key)
    local bar, why = nameBar(found.page)
    if not bar then
        if noBarSaid then return nil end
        noBarSaid = true
        log("menu: the inventory page has no name bar (" .. tostring(why)
            .. "); no mailbox button there (the Esc menu has one)")
        SURVEY.inventoryPage(found.page)
        return nil
    end
    local ok, button, crate = pcall(addPageButtons, found.page, bar)
    if not (ok and button) then
        pagesFailed[key] = true
        once("invadd", "menu: could not add the inventory mailbox button: " .. tostring(ok and crate or button))
        return nil
    end
    local entry = { mailbox = button, page = found.page, crate = crate }
    CLICKS.claim(button, WORLD_OWNER, function(clicked) closeMenuForMailbox("inventory", nil, entry.main, clicked) end)
    if crate then
        CLICKS.claim(crate.button, CRATE_OWNER, openCrate)
    end
    pages[key] = entry
    pageAdds = pageAdds + 1
    if pageAdds == 1 then
        log("menu: Archipelago Mailbox button added to the inventory page (" .. className(button) .. ") | "
            .. SURVEY.chainText(button))
    end
    return entry
end

-- The labels on a page's buttons, and the crate button shown only while there is a crate.
local function refreshPageLabels(entry, found)
    entry.main = found.main                    -- kept fresh: the close goes to the menu showing it
    refreshLabel(entry)
    if not (entry.crate and api.crateLabel) then return end
    local label = api.crateLabel()
    if entry.crateLabel == label then return end
    entry.crateLabel = label
    WIDGETS.show(entry.crate.box, label ~= nil)
    if label then
        setLabel(entry.crate.button, label)
    end
end

-- Every update, as for the Esc menu: a page is new each visit, so it is known by its address and forgotten when
-- gone. `found` is the pages up now (none when no main menu is).
local function updatePages(found)
    forgetGonePages(found)
    for _, item in ipairs(found) do
        local key = UTIL.addr(item.page)
        local entry = pages[key]
        if (not entry or not entry.mailbox:IsValid()) and not pagesFailed[key] then
            entry = addToPage(item, key)
        end
        if entry then
            refreshPageLabels(entry, item)
            SURVEY.focusOnce(entry, item.page)
        end
    end
end

-- Every update: the in-world buttons. Out of a world nothing of ours is up: all of it is dropped (as with nothing
-- found), so an address of ours can't match a new button at the title (the WBP_CommonButton click hook stays).
function WORLD.update(inWorld)
    if not api.mailboxLabel then return end
    local escLooked, escFound, pagesFound = true, {}, {}
    if inWorld then
        local ok, err = pcall(function() escLooked, escFound, pagesFound = menusUp() end)
        if not ok then
            once("mm" .. tostring(err), "menu: main menu error: " .. tostring(err))
        end
    else
        CLICKS.releaseAll(WORLD_OWNER)
    end
    if escLooked then
        local ok, err = pcall(updateEsc, escFound)
        if not ok then
            once("esc" .. tostring(err), "menu: Esc menu error: " .. tostring(err))
        end
    end
    local ok, err = pcall(updatePages, pagesFound)
    if not ok then
        once("inv" .. tostring(err), "menu: inventory page error: " .. tostring(err))
    end
end

-- After closing the main menu for the mailbox: whether it really went, logged once each way (a diagnostic).
local function checkMainMenuClosed()
    if not mainMenuLook then return end
    mainMenuLook = mainMenuLook - 1
    if mainMenuLook > 0 then return end
    mainMenuLook = nil
    local up = 0
    for _, widget in ipairs(FindAllOf(GAME.mainMenuClass) or {}) do
        local ok, showing = pcall(function()
            return widget:IsValid() and widget:IsVisible() and widget:IsInViewport()
        end)
        if ok and showing then
            up = up + 1
        end
    end
    local from = lookFrom == "inventory" and " from the inventory" or ""
    once("mainmenu" .. from .. up, "menu: in-game main menu after closing" .. from .. ": "
        .. (up == 0 and "gone" or (up .. " still shown")))
end

-- At the end of every update: the mailbox buttons' clicks (each closes its menu and opens the mailbox), or else the
-- look whether the main menu closed.
function WORLD.closeForMailbox()
    if CLICKS.run(WORLD_OWNER) > 0 then return end
    checkMainMenuClosed()
end

-- Whether the in-game main menu was up at the last look; nil before the first look.
function WORLD.mainMenuUp()
    return mainMenuNow
end
end

------------------------------------------------------------------------------------------------------------------------
-- The title menu's Archipelago menu. Clicking the banner (an all-but-invisible title button over it) swaps the title's
-- own buttons for ours, in the same list: Server, Port, Slot and Password typed in the game's own text box, styled as
-- the world-name window's; while the Server box has the keyboard, the saved servers show under it to pick from; then
-- Connect or Disconnect, and Back. The banner brightens while the pointer (or the keyboard's focus) is on it.
--
-- Two layouts of one menu. The typed layout is built first. If any of its rows can't be made, everything is taken out
-- and the window layout is built instead: each field is a row that opens the game's text window alone, and Server
-- steps through the saved servers. A menu record's `edits` is nil in the window layout.

local TITLE = {}
do -- (each part keeps its locals to itself: one chunk can hold only 200, and the parts become files of their own)
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
        once("drop" .. tostring(err), "menu: placing the saved servers: " .. tostring(err))
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
end

------------------------------------------------------------------------------------------------------------------------
-- The update, and what main.lua calls.

-- In a world: a live controller whose pawn lookup answered. The one test of it: the title menu's lookup and the
-- in-world buttons both use it.
local function playerInWorld(ctx)
    return ctx.pc ~= nil and ctx.hasPawn == true
end

-- The hooks, registered once their classes load (UTIL.hookWhenLoaded retries while they load: an OK hook that failed
-- once and was never tried again made every Confirm read as a cancel).
local function registerHooks(inWorld)
    CLICKS.hookClass(GAME.titleClick, "menu", api.guardedHook)
    UTIL.hookWhenLoaded(GAME.titleHover, hookCallbacks[GAME.titleHover], "menu")
    UTIL.hookWhenLoaded(GAME.titleUnhover, hookCallbacks[GAME.titleUnhover], "menu")
    if inWorld then
        CLICKS.hookClass(GAME.escClick, "menu", api.guardedHook)
        CLICKS.hookClass(GAME.commonClick, "menu", api.guardedHook)
    end
    UTIL.hookWhenLoaded(GAME.textWindowOk, hookCallbacks[GAME.textWindowOk], "menu")
end

-- Called from the mod's update loop (game thread). ctx: this update's player (main.lua): ctx.pc, the first live
-- controller; ctx.hasPawn, whether its K2_GetPawn answered with an object; ctx.pawn, that pawn when it is valid.
function M.update(ctx)
    CLICKS.run(CRATE_OWNER)
    local inWorld = playerInWorld(ctx)
    local looked, titles = TITLE.find(inWorld)
    SURVEY.ifNoMenu(looked, titles, inWorld, TITLE.rowsEverMade())
    WORLD.update(inWorld)
    registerHooks(inWorld)
    TITLE.forgetGone(looked, titles)
    TEXT.update()
    TITLE.update(titles)
    WORLD.closeForMailbox()
end

-- Whether the in-game main menu (its tabs hold the Technology menu and the Esc menu) was up at the last look; nil
-- before the first look. main.lua forgets the hovered shop card once it is closed.
function M.mainMenuUp()
    return WORLD.mainMenuUp()
end

local escBound = false                  -- state, forgotten: never (Esc is bound once a session)
-- Takes what main.lua hands over (see api above), makes the hook callbacks, and binds Esc.
function M.install(functions)
    api = functions
    local function guarded(path, fn)
        return api.guardedHook and api.guardedHook(path, fn) or fn
    end
    hookCallbacks[GAME.titleHover] = guarded(GAME.titleHover, TITLE.onHover)
    hookCallbacks[GAME.titleUnhover] = guarded(GAME.titleUnhover, TITLE.onUnhover)
    hookCallbacks[GAME.textWindowOk] = guarded(GAME.textWindowOk, TEXT.onOk)
    if escBound or not (RegisterKeyBind and Key and Key.ESCAPE and ExecuteInGameThread) then return end
    escBound = true
    -- A key bind runs off the game thread: it only hands over this function, made once.
    local function escKey()
        pcall(TITLE.escape)
    end
    RegisterKeyBind(Key.ESCAPE, function() ExecuteInGameThread(escKey) end)
end

return M
