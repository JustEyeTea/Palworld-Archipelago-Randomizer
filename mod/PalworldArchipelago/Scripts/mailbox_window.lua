-- The mailbox's own window, from the LogicMod PalworldArchipelagoUI (logicmod/): one row per item; pick a row to take
-- it, or Take all. The mod only fills the window and answers its buttons' AP_Clicked event (which each button's
-- OnClicked calls). Wired by mailbox.lua (WINDOW.install), whose update calls it.
-- Tests: mod/test/harness.lua, group "the mailbox" (its LogicMod part; run by tools/lua_harness.sh).
local WINDOW = {}
local UTIL = require("util")
local WIDGETS = require("widgets")
local CLICKS = require("clicks")
local BAG = require("bag")
local log = UTIL.log

-- What mailbox.lua hands over (WINDOW.install).
--   list                  the mailbox module: its queue, count(), take(id), takeAll() and TITLE
--   once(key, msg)        the mailbox's log-once for this world
--   notify(text)          shows a line to the player
--   guardedHook(name, fn) optional: a hook callback that no update can run inside
local env, LIST, once

function WINDOW.install(handedOver)
    env, LIST, once = handedOver, handedOver.list, handedOver.once
end

local WINDOW_FOLDER = "/Game/Mods/PalworldArchipelagoUI/"
local WINDOW_OWNER = "mailbox"         -- the window's name as the owner of its buttons in clicks.lua
local WINDOW_GAME = {
    window = WINDOW_FOLDER .. "WBP_APMailbox.WBP_APMailbox_C",   -- the window: Title, Summary, List, TakeAll, Close
    row = WINDOW_FOLDER .. "WBP_APButton.WBP_APButton_C",        -- a row and a button: Btn, Icon, Label
    rowClick = WINDOW_FOLDER .. "WBP_APButton.WBP_APButton_C:AP_Clicked",
    parts = { "Title", "Summary", "List", "TakeAll", "Close" },  -- the names the LogicMod must give its widgets
    dispatchParameter = "/Script/Pal.PalHUDDispatchParameterBase",
    gameplayStatics = "/Script/Engine.Default__GameplayStatics",
    systemLibrary = "/Script/Engine.Default__KismetSystemLibrary",   -- loads an item's icon
    widgetLibrary = "/Script/UMG.Default__WidgetBlueprintLibrary",
}
-- Game functions called: GetHUDService, Push, GetWidget, Close, SpawnObject, Create, LoadAsset_Blocking,
-- SetBrushFromTexture, SetKeyboardFocus.

-- State. Forgotten: when the HUD no longer has the window, on a new world, on a new seed (WINDOW.forget()).
-- Its buttons are claimed in clicks.lua as the owner WINDOW_OWNER, each with what it does: { kind = "take", id = item
-- id }, { kind = "takeAll" } or { kind = "close" } (WINDOW_ACTIONS); released whenever the window is filled again.
local window = nil            -- the window: { id = its HUD id, hud = the HUD service }
-- State. Forgotten: never.
local iconsFailed = false     -- an icon could not be shown: the game's item data has none, so none are tried again

local function setLabel(button, text)
    pcall(function() button.Label:SetText(FText(text)) end)
end

local function setIcon(button, id)
    if iconsFailed then return end
    local ok, err = pcall(function()
        local _, playerState = BAG.player()
        local data = BAG.palUtility():GetItemIDManager(playerState):GetStaticItemData(FName(id))
        local texture = StaticFindObject(WINDOW_GAME.systemLibrary):LoadAsset_Blocking(data.IconTexture)
        button.Icon:SetBrushFromTexture(texture, false)
        button.Icon:SetVisibility(WIDGETS.VISIBILITY.selfHitTestInvisible)
    end)
    if not ok then
        iconsFailed = true
        log("mailbox: no item icons: " .. tostring(err))
    end
end

-- Logs once each widget the LogicMod's window should have and does not.
local function checkParts(widget)
    for _, part in ipairs(WINDOW_GAME.parts) do
        local ok, found = pcall(function() return widget[part] end)
        if not ok or found == nil then
            once("part" .. part, "mailbox: the LogicMod window has no widget named " .. part)
        end
    end
end

local doAction                         -- (below: what a button does, given its action record)

-- Claims a button for the window: a click on it does `action` (a record of WINDOW_ACTIONS' kinds) after the hook.
local function claimButton(button, action)
    CLICKS.claim(button, WINDOW_OWNER, function() doAction(action) end)
end

-- One row per item in the list; the first row made, or nil.
local function addRows(widget)
    local rowClass = UTIL.findClass(WINDOW_GAME.row)
    local library = StaticFindObject(WINDOW_GAME.widgetLibrary)
    local first
    for _, entry in ipairs(LIST.queue) do
        local row = library:Create(widget, rowClass, nil)
        if row and row:IsValid() then
            setLabel(row, BAG.nameOf(entry.id) .. "  x" .. entry.n)
            setIcon(row, entry.id)
            widget.List:AddChild(row)
            claimButton(row, { kind = "take", id = entry.id })
            first = first or row
        end
    end
    return first
end

local function setTexts(widget)
    local kinds, items = LIST.count()
    local summary = items == 0 and "Nothing waiting. Items you receive from the multiworld arrive here."
        or (items .. " item(s) of " .. kinds .. " kind(s). Pick one to take it into your bag.")
    pcall(function() widget.Title:SetText(FText(LIST.TITLE)) end)
    pcall(function() widget.Summary:SetText(FText(summary)) end)
    setLabel(widget.TakeAll, "Take all")
    setLabel(widget.Close, "Close")
end

-- Fills the window from the list again: rows, texts and the buttons' actions.
local function refreshWindow()
    local widget = window and window.hud:GetWidget(window.id)
    if not widget or not widget:IsValid() then return end
    checkParts(widget)
    widget.List:ClearChildren()
    CLICKS.releaseAll(WINDOW_OWNER)
    local first = addRows(widget)
    setTexts(widget)
    claimButton(widget.TakeAll, { kind = "takeAll" })
    claimButton(widget.Close, { kind = "close" })
    pcall(function() (first or widget.TakeAll).Btn:SetKeyboardFocus() end)   -- a controller starts on the first row
end

-- Takes everything into the bag and says how much went in.
local function takeAllAndTell()
    local took, left = LIST.takeAll()
    if took == 0 then return end
    local rest = left > 0 and (" (" .. left .. " left: your bag is full)") or ""
    env.notify("Took " .. took .. " item(s) from the mailbox" .. rest .. ".")
end

-- What each kind of button does. All but Close fill the window again afterwards.
local WINDOW_ACTIONS = {
    take = function(action) LIST.take(action.id) end,
    takeAll = takeAllAndTell,
    close = function() pcall(function() window.hud:Close(window.id) end) end,
}

-- Does what a clicked button stands for (one of WINDOW_ACTIONS).
doAction = function(action)
    if not window then return end
    local run = WINDOW_ACTIONS[action.kind]
    if not run then
        log("mailbox: a button with an unknown action (" .. tostring(action.kind) .. ") was clicked; nothing done")
        return
    end
    run(action)
    if action.kind ~= "close" then
        refreshWindow()
    end
end

-- Hooks the buttons' click once the LogicMod's button class is loaded. Called every update: it is retried every 3 s
-- until it works, so a window already open gets working buttons too.
function WINDOW.hookButtons()
    CLICKS.hookClass(WINDOW_GAME.rowClick, "mailbox", env.guardedHook)
end

-- Whether the LogicMod's window can be shown (it is installed, and config.txt does not ask for the chest).
function WINDOW.available(cfg)
    if cfg.mailbox_view == "chest" then return false end
    return UTIL.findClass(WINDOW_GAME.window) ~= nil and UTIL.findClass(WINDOW_GAME.row) ~= nil
end

-- Opens the window over `pawn`'s HUD and fills it. Raises an error when the HUD can't show it.
function WINDOW.open(pawn)
    local hud = BAG.palUtility():GetHUDService(pawn)
    WINDOW.hookButtons()                   -- (the first try: the button class has just loaded)
    local parameter
    pcall(function()
        local parameterClass = StaticFindObject(WINDOW_GAME.dispatchParameter)
        parameter = StaticFindObject(WINDOW_GAME.gameplayStatics):SpawnObject(parameterClass, hud)
    end)
    local id = hud:Push(UTIL.findClass(WINDOW_GAME.window), parameter)
    window = { id = id, hud = hud }
    refreshWindow()
    log("mailbox: window open (" .. #LIST.queue .. " kind(s))")
end

-- Whether the window is up (as far as the last update saw).
function WINDOW.isOpen()
    return window ~= nil
end

-- Forgets the window once the HUD no longer has it (the player closed it).
function WINDOW.follow()
    if not window then return end
    local open = false
    pcall(function()
        local widget = window.hud:GetWidget(window.id)
        open = widget and widget:IsValid()
    end)
    if not open then
        WINDOW.forget()
    end
end

-- Does the work of the buttons clicked since the last update.
function WINDOW.runClicks()
    CLICKS.run(WINDOW_OWNER)
end

-- Forgets the window, its buttons and their clicks not yet run (it closed, or a new world or seed: they belong to the
-- old one).
function WINDOW.forget()
    window = nil
    CLICKS.releaseAll(WINDOW_OWNER)
end

return WINDOW
