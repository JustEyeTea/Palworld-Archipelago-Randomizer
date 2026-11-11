-- The title menu's Archipelago menu: one record per title menu, and its life. Each update it finds the title menus,
-- builds our rows (menu_title_rows.lua) and the banner (menu_title_banner.lua) on a new one, brings each up to date
-- (menu_title_connect.lua), and gives one up when it goes. It also answers the title buttons' hover hooks and Esc.
-- Wired by menu.lua (TITLE.install), whose update calls it.
-- Tests: mod/test/tests/title_menu.lua; group "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local TITLE = {}
local CLICKS = require("clicks")
local UTIL = require("util")
local WIDGETS = require("widgets")
local SURVEY = require("menu_survey")
local NAMES = require("menu_names")
local GAME = NAMES.GAME
local EVERY = NAMES.EVERY
local FAILS_BEFORE_BACKOFF = NAMES.FAILS_BEFORE_BACKOFF
local LOGGED_FAILURES = NAMES.LOGGED_FAILURES
local MENU_WIDTH = NAMES.MENU_WIDTH
local LIST_LEVELS = NAMES.LIST_LEVELS
local TITLE_OWNER = NAMES.TITLE_OWNER
local log, once = UTIL.log, UTIL.onceIn("menu")
local className, nameOf = WIDGETS.className, WIDGETS.nameOf
-- The menu's other parts, a file each: the banner, the rows' building, and what the rows say and do.
local BANNER = require("menu_title_banner")
local ROWS = require("menu_title_rows")
local CONNECT = require("menu_title_connect")

-- What main.lua hands over, through menu.lua (TITLE.install): see menu.lua. The banner and the rows' clicks use it.
function TITLE.install(functions)
    BANNER.install(functions)
    CONNECT.install(functions)
end

-- The title menu's Archipelago menu. Clicking the banner (an all-but-invisible title button over it) swaps the title's
-- own buttons for ours, in the same list: Server, Port, Slot and Password typed in the game's own text box, styled as
-- the world-name window's; while the Server box has the keyboard, the saved servers show under it to pick from; then
-- Connect or Disconnect, and Back. The banner brightens while the pointer (or the keyboard's focus) is on it.

-- State: the title menus. Forgotten: an entry when its menu is no longer found or its rows are gone (dropTitleMenu).
-- A record's life: made (buildTitleMenu: our rows collapsed, the banner on) -> showing (the banner clicked: the game's
-- buttons fold away) -> closed again (Back, Esc, or connected after Connect) -> given up (dropTitleMenu), after which
-- nothing touches it again: a remake is a new record.
local menus = {}              -- a title menu's address -> its record (newTitleMenu)
local fails = {}              -- a title menu's address -> builds that failed in a row (FAILS_BEFORE_BACKOFF);
                              --   forgotten when the menu is no longer found (a new one may get its address)
-- State. Forgotten: never.
local buildFailures = 0       -- builds that failed in a row, on any menu (the first LOGGED_FAILURES are logged)
local lookUpdates = 0         -- updates since the start (the title menu's lookups count them)
local titleInWorld = false    -- a title menu was found in a world: from then it is looked for every update
local rowsEverMade = false    -- our rows were made on a title menu (then no survey is needed)

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
        banner = nil,           -- the banner record (newBanner, in menu_title_banner.lua), or nil without one
        bannerButton = nil,     -- the banner's own button, or nil (then a row of its own opens the menu)
        bannerKey = nil,        -- that button's address (the hover events name it)
        showing = false,        -- the Archipelago menu is up, the game's buttons folded away
        hidden = nil,           -- the game's buttons it folded away: { widget, visibility } to give back
        closeOnConnect = nil,   -- Connect was pressed: fold the menu once the connection is up
        live = false,           -- found by the last lookup; false once given up
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

-- After the rows: the banner and its button (else a row of its own opens the menu), Quit Game last, and the logs.
-- After, not before: a menu whose rows failed would otherwise get a new banner on every try.
local function finishTitleMenu(m, menu, list)
    local okBanner, banner = pcall(BANNER.add, menu, list)
    if okBanner then
        m.banner = banner
    else
        log("menu: title banner error: " .. tostring(banner))
    end
    local okButton, why = pcall(ROWS.addBannerButton, menu, m)
    if not okButton then
        local okRow, button, box = pcall(ROWS.addTitleButton, menu, list, MENU_WIDTH, nil)
        if okRow and button then
            ROWS.addRow(m, "bannerButton", "bannerButton", nil, box, button)
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
    local okTyped, whyTyped = pcall(ROWS.buildTyped, m, menu, list)
    if not okTyped then
        ROWS.undoTyped(m, list)
        m = newTitleMenu(list)
        local why = tostring(whyTyped):gsub("^.-:%d+: ", "")           -- (the message, not where)
        logBuildFailure("menu: typed fields not made (" .. why .. "); the text window instead")
        local err = ROWS.buildWindow(m, menu, list)
        if err then
            ROWS.undoWindow(m)
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
                pcall(CONNECT.showGame, m, true)
            end
            dropTitleMenu(key, m, true)
        end
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
    CONNECT.followConnection(m)
    if m.banner then
        pcall(BANNER.showConnection, m.banner)
    end
    CONNECT.refreshRows(m)
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
    BANNER.endPress()                                   -- (the pressed picture shows from the click until now)
end

-- The pointer (or focus) on or off the banner's button: the banner lights at the next game tick.
local function hoverBanner(m, address, on)
    BANNER.pointerOn(address, on)
    if not ExecuteInGameThread then return end
    ExecuteInGameThread(function()
        if m.live then
            pcall(CONNECT.refreshRows, m)
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
            CONNECT.hoverPick(address, on)
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
            local ok, err = pcall(CONNECT.act, m, { kind = "back" })
            if not ok then
                log("menu: Esc error: " .. tostring(err))
            end
            CONNECT.refreshRows(m)
            once("esc", "menu: Esc closes the Archipelago menu (as Back)")
        end
    end
end

return TITLE
