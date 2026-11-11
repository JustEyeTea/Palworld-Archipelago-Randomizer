-- In a world: the "Archipelago Mailbox" button on the Esc menu and on the Inventory page, and the crate button
-- beside the latter. Wired by menu.lua (WORLD.install), whose update calls it.
-- Tests: mod/test/tests/inventory_page.lua, mod/test/tests/mailbox.lua; groups "the Inventory page's mailbox button",
--   "the mailbox" (tools/lua_harness.sh, in CI).
local WORLD = {}
local ART = require("art")
local CLICKS = require("clicks")
local UTIL = require("util")
local WIDGETS = require("widgets")
local SURVEY = require("menu_survey")
local NAMES = require("menu_names")
local GAME = NAMES.GAME
local WAIT = NAMES.WAIT
local EVERY = NAMES.EVERY
local ROW_HEIGHT = NAMES.ROW_HEIGHT
local ROW_GAP = NAMES.ROW_GAP
local BAR_BUTTON = NAMES.BAR_BUTTON
local INVENTORY_EMBLEM = NAMES.INVENTORY_EMBLEM
local EMBLEM_RIGHT = NAMES.EMBLEM_RIGHT
local CRATE_RIGHT = NAMES.CRATE_RIGHT
local ESC_BUTTON_GAP = NAMES.ESC_BUTTON_GAP
local ESC_CONTINUE = NAMES.ESC_CONTINUE
local WORLD_OWNER = NAMES.WORLD_OWNER
local CRATE_OWNER = NAMES.CRATE_OWNER
local log, once = UTIL.log, UTIL.onceIn("menu")
local className, nameOf, setLabel = WIDGETS.className, WIDGETS.nameOf, WIDGETS.setLabel
local HALIGN, VALIGN = WIDGETS.HALIGN, WIDGETS.VALIGN

-- Untested in game (the only marks for the menu files):
--   * the Inventory page's mailbox button, placed on the page's name bar as the server's files lay it out;
--   * whether a controller can reach that button (SURVEY.focusOnce logs it);
--   * Close() on the in-game main menu from Lua, which the Inventory page's button uses to close the menu.

-- What main.lua hands over, through menu.lua (WORLD.install): see menu.lua.
local api

function WORLD.install(functions)
    api = functions
end

-- In a world: an "Archipelago Mailbox" button on the Esc menu and on the Inventory page, and the crate button beside
-- the latter. The game makes a new Esc menu and a new Inventory page each time they open, so each is known by its
-- address and forgotten (its buttons released) when it is no longer found: the engine reuses an address once its
-- widget is gone.

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
            UTIL.onceErr("menu main menu", err, "menu: main menu error: " .. tostring(err))
        end
    else
        CLICKS.releaseAll(WORLD_OWNER)
    end
    if escLooked then
        local ok, err = pcall(updateEsc, escFound)
        if not ok then
            UTIL.onceErr("menu Esc menu", err, "menu: Esc menu error: " .. tostring(err))
        end
    end
    local ok, err = pcall(updatePages, pagesFound)
    if not ok then
        UTIL.onceErr("menu inventory page", err, "menu: inventory page error: " .. tostring(err))
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

return WORLD
