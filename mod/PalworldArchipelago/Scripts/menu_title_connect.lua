-- What the title menu's Archipelago menu says and does: the draft it will connect with (config.txt's connection when
-- the menu opens, then what is typed, picked or asked for in the text window), each kind of row's label, click and
-- when it shows, the saved servers shown under Server, Connect or Disconnect, and folding the menu once connected.
-- Used by menu_title.lua, which hands it main.lua's functions (CONNECT.install), and menu_title_rows.lua.
-- Tests: mod/test/tests/title_menu.lua; group "the title menu's Archipelago menu" (tools/lua_harness.sh, in CI).
local CONNECT = {}
local CONFIG = require("config")
local UTIL = require("util")
local WIDGETS = require("widgets")
local TEXT = require("text_window")
local NAMES = require("menu_names")
local BANNER = require("menu_title_banner")
local ROW_STEP = NAMES.ROW_STEP
local STARS_MAX = NAMES.STARS_MAX
local log, once = UTIL.log, UTIL.onceIn("menu")
local setLabel = WIDGETS.setLabel
local COLLAPSED = WIDGETS.VISIBILITY.collapsed

-- What main.lua hands over, through menu.lua and menu_title.lua (CONNECT.install): see menu.lua.
local api

function CONNECT.install(functions)
    api = functions
end

-- State: what the menu will connect with. Forgotten: each time the menu opens (setShowing).
local draft = nil             -- { scheme ("wss://", "ws://" or ""), host, port, slot, password }
-- State. Forgotten: never.
local remembered = nil        -- the server last handed to api.rememberServer
-- State: the pointer on the saved servers. Forgotten: when the pointer leaves, or a saved server is picked.
local pickHovered = nil       -- a saved server row's address while the pointer is on it

local splitServer = CONFIG.splitServer

-- What the menu will connect with, from config.txt's server, slot and password when the menu opened.
local function draftNow()
    if not draft then
        local scheme, host, port = splitServer(api.server())
        if host == "" then
            scheme, host = "", "archipelago.gg"
        end
        draft = { scheme = scheme, host = host, port = port, slot = api.slot(), password = api.password() }
    end
    return draft
end

-- The draft's server as the Server box shows it: the scheme, if one was given, and the host.
local function serverText(d)
    return d.scheme .. d.host
end

local function target(d)
    return serverText(d) .. (d.port ~= "" and (":" .. d.port) or "")
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
function CONNECT.showGame(m, show)
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
    writeEdit(m, "server", serverText(d))
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
    CONNECT.showGame(m, not showing)
    log("menu: Archipelago menu " .. (showing and "opened" or "closed"))
end

-- The rows' labels, by kind (rows with no button have none).
local function pickLabel(m, row)
    local host = m.pickHosts[row.index] or ""
    return "      " .. host .. (host == draftNow().host:lower() and "   (chosen)" or "")
end

local function serverLabel()
    local saved = #(api.servers and api.servers() or {})
    return "Server: " .. serverText(draftNow()) .. (saved > 1 and ("   (click: next of " .. saved .. ")") or "")
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
    if d.host == "" then return "Connect (type a server first)" end
    if d.slot == "" then return "Connect (set your slot name first)" end
    return "Connect to " .. target(d) .. " as " .. d.slot
end

-- What a click on each kind of row does.
local function pickServer(m, row)
    local host = m.pickHosts[row.index]
    if not host then return end
    local d = draftNow()
    d.scheme, d.host = "", host                 -- (a saved server is its host alone)
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
    d.scheme, d.host = "", saved[at % #saved + 1]
end

local function askAddress(_, _, button)
    local d = draftNow()
    TEXT.ask(button, TEXT.FIELDS.addr, target(d), function(answer)
        local scheme, host, port = splitServer(answer)
        if host ~= "" then
            d.scheme, d.host = scheme, host
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
function CONNECT.act(m, row, button)
    draftNow()
    local kind = ROW_KINDS[row.kind]
    if not kind or not kind.act then
        error("no action for a row of kind " .. tostring(row.kind))
    end
    kind.act(m, row, button)
end

-- Just under the Server box: the list's top (the Server row is its first while the menu shows) plus one row.
local function placePickPanel(m)
    local anchors, top = BANNER.listTop(m.list)
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

-- Whether a Server box's text names a port (host:port), which moves to the Port box.
local function namesPort(text)
    local _, _, port = splitServer(text)
    return port ~= ""
end

-- What each typed box does with its text, every update while the menu shows. A Server typed as host:port moves the
-- port to its own box once the Server box is left (not while typing in it).
local function typedServer(m, d, text, edit)
    local scheme, host, port = splitServer(text)
    d.scheme, d.host = scheme, host
    if port ~= "" then
        d.port = port
    end
    local okFocus, focus = pcall(function() return edit:HasKeyboardFocus() end)
    if port == "" or (okFocus and focus) then return end
    writeEdit(m, "server", serverText(d))
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
        elseif text ~= m.typed[kind] or (kind == "server" and namesPort(text)) then
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
        UTIL.onceErr("menu saved servers", err, "menu: placing the saved servers: " .. tostring(err))
    end
end

-- The rows as the menu stands: which show, their labels, the typed fields read back, the saved servers, the banner.
function CONNECT.refreshRows(m)
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
            local text = kind.label(m, row)
            if row.labelNow ~= text then           -- (written when it changes, not on every update)
                row.labelNow = text
                setLabel(row.button, text)
            end
        end
    end
    if m.pickPanel then
        refreshPickPanel(m, picking)
    end
    pcall(BANNER.refreshLook, m)
end

-- A click on one of a menu's buttons, run at the next game tick (claimSoon), so the menu opens at once rather than
-- at the next update; never inside the click's hook. While the text window is up, a click only refreshes the rows.
function CONNECT.onTitleClick(m, row)
    return function(button)
        if row.kind == "bannerButton" then
            BANNER.press()
        end
        if not m.live then return end
        if not TEXT.asking() then
            local ok, err = pcall(CONNECT.act, m, row, button)
            if not ok then
                log("menu: " .. row.kind .. " error: " .. tostring(err))
            end
        end
        CONNECT.refreshRows(m)
    end
end

-- The connection as it stands: after Connect, the menu folds once connected; a server connected to is remembered.
function CONNECT.followConnection(m)
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

-- The pointer (or focus) on or off a saved server's row: the panel stays open while it is on one.
function CONNECT.hoverPick(address, on)
    if on then
        pickHovered = address
    elseif pickHovered == address then
        pickHovered = nil
    end
end

return CONNECT
