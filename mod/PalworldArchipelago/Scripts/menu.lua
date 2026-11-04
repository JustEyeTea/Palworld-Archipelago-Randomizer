-- The title menu's Archipelago buttons: one shows the connection and, clicked, asks for the server, the slot and the
-- password in the game's own text window (the world-name window), then connects; a second disconnects while connected.
-- In a world, the Esc menu gets an "Archipelago Mailbox" button (mailbox.lua).
-- Built from the game's own widgets: a WBP_Title_MenuButton added to the title menu's button list, and a
-- WBP_MenuESC_Button_S (the Esc menu's own small button) in the Esc menu, so they look and work like the game's.
local M = {}
local function log(msg) print("[PalworldAP] " .. msg .. "\n") end
local reported = {}
local function once(key, msg) if not reported[key] then reported[key] = true; log(msg) end end

local UI = "/Game/Pal/Blueprint/UI/UserInterface/Title/"
local MENU = UI .. "WBP_TitleMenu.WBP_TitleMenu_C"
local BUTTON = UI .. "WBP_Title_MenuButton.WBP_Title_MenuButton_C"
local CLICK = BUTTON .. ":BndEvt__WBP_Title_MenuButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local WINDOW = UI .. "WBP_Title_WorldSettings_NameWindow.WBP_Title_WorldSettings_NameWindow_C"
local WINDOW_OK = WINDOW .. ":BndEvt__WBP_Title_WorldSettings_NameWindow_WBP_CommonButton_K2Node_ComponentBoundEvent_5_OnClicked__DelegateSignature"
local PARAM = UI .. "BP_HUDDispatchParameter_WorldNameInput.BP_HUDDispatchParameter_WorldNameInput_C"
local ESC_BUTTON = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button_S.WBP_MenuESC_Button_S_C"
local ESC_CLICK = ESC_BUTTON .. ":BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature"
local NOTHING = "\1"           -- what the window's result holds until OK is pressed

local api                      -- status(), server(), slot(), password(), connect(server, slot, password), disconnect(),
                               -- mailboxLabel(), openMailbox(context)
local menus = {}               -- title menu address -> { connect = button, disconnect = button }
local escMenus = {}            -- Esc menu address -> { mailbox = button, menu = the Esc menu }
local ours = {}                -- our button address -> "connect" | "disconnect" | "mailbox"
local closeEsc = nil           -- the mailbox button was pressed: { menu, button }, handled on the next update
local mainMenuLook = nil       -- updates until the mod looks whether the main menu closed (a diagnostic)
local hooked = {}
local asking = nil             -- the text-window chain: { step, values, param, id, hud }

local function find(path)
    local o = StaticFindObject(path)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, (path:gsub("_C$", "")))              -- the full "/Game/Dir/Asset.Asset" (a class path may not load)
    o = StaticFindObject(path)
    return o and o:IsValid() and o or nil
end

local function label()
    local st = api.status()
    if st == "connected" then return "Archipelago: connected as " .. api.slot() end
    if st == "connecting" then return "Archipelago: connecting..." end
    if st == "refused" then return "Archipelago: refused (click to change)" end
    return "Archipelago: not connected"
end

-- A title button's label is Test_Content; the Esc menu's small button's is Text_Main, a text block the button fills
-- from the game's text table: unbind it first (as with the text window's heading), then set ours.
local function setText(button, text)
    local okm, main = pcall(function() local t = button.Text_Main; return t and t:IsValid() and t or nil end)
    if okm and main then
        pcall(function() main.IsAutoTextSetWhenWidgetRebuilt = false end)
        pcall(function() main.BindTextDatatableHandle.RowName = FName("None") end)
        pcall(function() main:SetText(FText(text)) end)
        return
    end
    pcall(function() button.Test_Content:SetText(FText(text)) end)
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end
local function nameOf(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

-- The panel the game's own title buttons sit in: walk up from the menu's Start Game button to the first box. (v0.10.1
-- playtest: the client's title menu has a VerticalBox_0, as the server's files do, but buttons added to it never
-- showed: the client lays its menu out differently.) Then any other game title button; VerticalBox_0 last.
local BOXES = { VerticalBox = true, ScrollBox = true, WrapBox = true, HorizontalBox = true }
local START_BUTTONS = { "WBP_Title_MenuButton_StartLocalGame", "WBP_Title_MenuButton_StartMultiGame_InviteCode",
                        "WBP_Title_MenuButton_ExitGame" }
local function boxAbove(button)
    local w = button
    for _ = 1, 5 do
        local okp, parent = pcall(function() return w:GetParent() end)
        if not okp or not parent or not parent:IsValid() then return nil end
        if BOXES[className(parent)] then return parent end
        w = parent
    end
end
local function buttonList(menu)
    for _, name in ipairs(START_BUTTONS) do
        local ok, b = pcall(function() local v = menu[name]; return v and v:IsValid() and v or nil end)
        local box = ok and b and boxAbove(b)
        if box then return box end
    end
    for _, button in ipairs(FindAllOf("WBP_Title_MenuButton_C") or {}) do
        if button:IsValid() and not ours[tostring(button:GetAddress())] then
            local box = boxAbove(button)
            if box then return box end
        end
    end
    local ok, b = pcall(function() local v = menu.VerticalBox_0; return v:IsValid() and v or nil end)
    if ok and b then return b end
end

-- One line per widget chain: each parent's name, class and visibility (0 visible, 1 collapsed, 2 hidden).
local function chainText(w)
    local parts = {}
    for _ = 1, 8 do
        local okp, parent = pcall(function() return w:GetParent() end)
        if not okp or not parent or not parent:IsValid() then break end
        local okv, vis = pcall(function() return parent:GetVisibility() end)
        parts[#parts + 1] = nameOf(parent) .. ":" .. className(parent) .. (okv and ("/" .. tostring(vis)) or "")
        w = parent
    end
    return table.concat(parts, " < ")
end
local layoutLogged = false
local function logLayout(menu, ourButton)
    if layoutLogged then return end
    layoutLogged = true
    for _, name in ipairs(START_BUTTONS) do
        local ok, b = pcall(function() local v = menu[name]; return v and v:IsValid() and v or nil end)
        log("menu layout: " .. name .. (ok and b and (" | " .. chainText(b)) or ": not on this menu"))
    end
    if ourButton then log("menu layout: our button | " .. chainText(ourButton)) end
end

local function addButton(menu, list, kind)
    local class = find(BUTTON)
    local sizeClass = StaticFindObject("/Script/UMG.SizeBox")
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not class or not sizeClass or not wbl then return nil end
    local button = wbl:Create(menu, class, nil)
    if not button or not button:IsValid() then return nil end
    local box = StaticConstructObject(sizeClass, menu)
    if kind ~= "mailbox" then box:SetWidthOverride(600) end   -- the Esc menu's column is narrower: fill it instead
    box:SetHeightOverride(38)
    box:AddChild(button)
    local slot = list:AddChild(box)
    pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 3 }) end)
    pcall(function() slot:SetHorizontalAlignment(0) end)
    ours[tostring(button:GetAddress())] = kind
    return button
end

-- The Esc menu's own small button (WBP_MenuESC_Button_S, as Emergency Respawn and Return to Title), straight in the
-- box with the game's spacing (each sits in a vertical box slot with 10 above it). The menu binds its buttons' clicks
-- when it is built, so ours stays unbound and only our hook answers it; its MenuType is set to 0 (Continue: close the
-- menu) all the same. Without that class, a title button as before.
local function addEscButton(menu, list)
    local class = find(ESC_BUTTON)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not class or not wbl then
        once("escstyle", "menu: no Esc menu button class; using a title button")
        return addButton(menu, list, "mailbox")
    end
    local button = wbl:Create(menu, class, nil)
    if not button or not button:IsValid() then return nil end
    pcall(function() button.MenuType = 0 end)
    local slot = list:AddChild(button)
    pcall(function() slot:SetPadding({ Left = 0, Top = 10, Right = 0, Bottom = 0 }) end)
    ours[tostring(button:GetAddress())] = "mailbox"
    return button
end

-- Our buttons go in after the game's last one; move Quit Game (its size box) back to the end of the list, keeping its
-- slot's padding and alignment (v0.11.2 playtest: the Archipelago buttons sat below Quit Game).
local function quitLast(menu, list)
    local quit = menu.WBP_Title_MenuButton_ExitGame
    if not quit or not quit:IsValid() then return "no Quit Game button" end
    local wrap = quit:GetParent()
    if not wrap or not wrap:IsValid() or wrap == list then return "Quit Game is not in a size box" end
    local okp, parent = pcall(function() return wrap:GetParent() end)
    if not okp or not parent or tostring(parent:GetAddress()) ~= tostring(list:GetAddress()) then return "Quit Game is not in our list" end
    local pad, align = nil, nil
    pcall(function()
        local p = wrap.Slot.Padding
        pad = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }
        align = wrap.Slot.HorizontalAlignment
    end)
    list:RemoveChild(wrap)
    local slot = list:AddChild(wrap)
    if pad then pcall(function() slot:SetPadding(pad) end) end
    if align then pcall(function() slot:SetHorizontalAlignment(align) end) end
    return nil
end

-- The next window of the chain: server, slot, password.
local STEPS = {
    { key = "server", title = "Archipelago server (host:port)" },
    { key = "slot", title = "Your slot name" },
    { key = "password", title = "Room password (empty if none)", hidden = true },
}
-- The window's heading is a PalTextBlockBase bound to a text-table row (BindTextDatatableHandle -> "WorldName"),
-- which it puts back on rebuild; unbind it, then set ours.
local function setHeading(w, title)
    pcall(function() w.Text_Head.IsAutoTextSetWhenWidgetRebuilt = false end)
    pcall(function() w.Text_Head.BindTextDatatableHandle.RowName = FName("None") end)
    pcall(function() w.Text_Head:SetText(FText(title)) end)
end

local function openWindow(context)
    local step = STEPS[asking.step]
    local hud = StaticFindObject("/Script/Pal.Default__PalUtility"):GetHUDService(context)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local param = gs:SpawnObject(find(PARAM), hud)
    param.DefaultInputName = asking.values[step.key] or ""
    param.OutString = NOTHING
    asking.param, asking.hud = param, hud
    asking.id = hud:Push(find(WINDOW), param)
    local w = hud:GetWidget(asking.id)
    if w and w:IsValid() then
        setHeading(w, step.title)
        if step.hidden then pcall(function() w.PalEditableTextBox_0:SetIsPassword(true) end) end
    end
    asking.title = step.title
end

local function clicked(button)
    local kind = ours[tostring(button:GetAddress())]
    if not kind then return end
    if kind == "disconnect" then
        api.disconnect()
        return
    end
    if kind == "mailbox" then
        -- Closing the Esc menu waits for the next update, outside this click's hook; the mailbox opens a tick later.
        local menu
        for _, m in pairs(escMenus) do if m.mailbox:IsValid() and m.mailbox:GetAddress() == button:GetAddress() then menu = m.menu end end
        closeEsc = { menu = menu, button = button }
        return
    end
    if asking then return end
    asking = { step = 1, context = button, values = { server = api.server(), slot = api.slot(), password = api.password() } }
    local ok, err = pcall(openWindow, button)
    if not ok then log("menu: could not open the text window: " .. tostring(err)); asking = nil end
end

local function okPressed()
    if not asking or not asking.param or not asking.param:IsValid() then return end
    local text = asking.param.OutString
    text = tostring(text and text.ToString and text:ToString() or text)
    if text == NOTHING then return end
    local step = STEPS[asking.step]
    asking.values[step.key] = text:match("^%s*(.-)%s*$")
    asking.step = asking.step + 1
    asking.param = nil
    asking.reopen = true                       -- the next window opens on the next update, once this one has closed
end

-- Hooks a function once its class is loaded. A failed attempt is retried every 10 calls (v0.10.3 playtest: the text
-- window's OK hook failed with "UFunction::Func: 0x0" while its class was still loading, and was never retried, so
-- every Confirm read as a cancel).
local hookTries = {}
local function hookOnce(path, fn)
    if hooked[path] then return end
    local cls = StaticFindObject((path:gsub(":.*$", "")))
    if not cls or not cls:IsValid() then return end
    hookTries[path] = (hookTries[path] or 0) + 1
    if hookTries[path] > 1 and hookTries[path] % 10 ~= 1 then return end
    local ok, err = pcall(RegisterHook, path, fn)
    if ok then
        hooked[path] = true
        log("menu: hooked " .. path:match("[^:]+$") .. (hookTries[path] > 1 and (" (try " .. hookTries[path] .. ")") or ""))
    elseif hookTries[path] == 1 then
        log("menu: could not hook " .. path:match("[^:]+$") .. " yet (will retry): " .. tostring(err):match("^[^\n]*"))
    end
end

-- Every widget in a menu's own tree, from WidgetTree.RootWidget down through panels (GetChildrenCount/GetChildAt).
-- UWidgetTree:GetAllWidgets is C++ only, not a UFunction: from Lua it errors (v0.11.1 playtest: no Esc button).
-- Stops at nested user widgets, which have trees of their own.
local function eachWidget(w, fn)
    local okr, root = pcall(function() return w.WidgetTree.RootWidget end)
    if not okr or not root then return end
    local function walk(o, depth)
        if not o or not o:IsValid() or depth > 30 then return end
        fn(o)
        local okn, n = pcall(function() return o:GetChildrenCount() end)
        if not okn or type(n) ~= "number" then return end
        for i = 0, n - 1 do
            local okc, c = pcall(function() return o:GetChildAt(i) end)
            if okc and c then walk(c, depth + 1) end
        end
    end
    walk(root, 0)
end

-- Diagnostics (v0.8.1): the title menu mapped from the dedicated server's files was not on the client's title screen.
-- Once on the title screen, log every user widget whose class names a title or menu, with its child widgets, so the
-- client's real title menu can be found from a log.
local surveyed, titleTicks, added = false, 0, false
local function survey()
    local seen = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        local ok, name = pcall(function() return w:GetClass():GetFName():ToString() end)
        if ok and w:IsValid() and (name:find("Title") or name:find("Menu")) and not seen[name] then
            seen[name] = true
            local children = {}
            pcall(eachWidget, w, function(o)
                local okc, cn = pcall(function() return o:GetFName():ToString() .. ":" .. o:GetClass():GetFName():ToString() end)
                if okc then children[#children + 1] = cn end
            end)
            log("menu survey: " .. tostring(select(2, pcall(function() return w:GetFullName() end))) .. " | children: "
                .. table.concat(children, ", "))
        end
    end
    for _, button in ipairs(FindAllOf("WBP_Title_MenuButton_C") or {}) do
        local chain, w = {}, button
        for _ = 1, 6 do
            local okp, parent = pcall(function() return w:GetParent() end)
            if not okp or not parent or not parent:IsValid() then break end
            chain[#chain + 1] = nameOf(parent) .. ":" .. className(parent)
            w = parent
        end
        log("menu survey: title button " .. tostring(select(2, pcall(function() return button:GetFullName() end)))
            .. " | parents: " .. table.concat(chain, " < "))
    end
    log("menu survey: done (" .. (function() local n = 0; for _ in pairs(seen) do n = n + 1 end; return n end)() .. " classes)")
end


-- The Esc menu, found by its class name the first time it is up (only the client has it): a user widget named like an
-- Esc, pause or system menu whose widget tree holds a box of at least 3 buttons of one class. Until it is found, new
-- in-world widget classes named like menus are logged, so a log can tell what the client calls it.
-- The client's Esc menu, by its exact class (kdump; v0.11.2 log). Matching class names loosely picked the HUD's mission
-- list (WBP_IngameMenu_Task_SimpleList_C: "ingamemenu" holds "gamemenu") and put buttons in each of its copies.
local ESC_CLASS = "WBP_MenuESC_C"
local escLogged = false
-- The box whose children are mostly buttons of one class (each maybe wrapped in a size box); nil below 3.
local function escButtonBox(menu)
    local best, bestCount = nil, 2
    eachWidget(menu, function(o)
        if not BOXES[className(o)] then return end
        local counts = {}
        local okn, n = pcall(function() return o:GetChildrenCount() end)
        for i = 0, (okn and n or 0) - 1 do
            local okc, child = pcall(function() return o:GetChildAt(i) end)
            if okc and child and child:IsValid() then
                local cn = className(child)
                if cn == "SizeBox" or cn == "Overlay" then
                    local okg, inner = pcall(function() return child:GetChildAt(0) end)
                    if okg and inner and inner:IsValid() then cn = className(inner) end
                end
                if cn:match("Button.*_C$") and not ours[tostring(child:GetAddress())] then counts[cn] = (counts[cn] or 0) + 1 end
            end
        end
        for _, c in pairs(counts) do
            if c > bestCount then best, bestCount = o, c end
        end
    end)
    return best
end
local function findEscMenus()
    local out = {}
    for _, w in ipairs(FindAllOf(ESC_CLASS) or {}) do
        local okd, full = pcall(function() return w:GetFullName() end)
        if w:IsValid() and not (okd and tostring(full):find("Default__", 1, true)) then out[#out + 1] = w end
    end
    if out[1] and not escLogged then
        escLogged = true
        local okb, box = pcall(escButtonBox, out[1])
        log("menu: the Esc menu is " .. ESC_CLASS .. " (" .. #out .. " found; buttons in "
            .. (okb and box and (className(box) .. " " .. nameOf(box)) or ("none: " .. tostring(box))) .. ")")
    end
    return out
end
local escTicks, escAdds = 0, 0
local function updateEsc()
    escTicks = escTicks + 1
    if escTicks % 4 ~= 0 then return end
    -- The game makes a new Esc menu each time it opens: forget the ones gone (v0.11.3 log: one per visit).
    local live = {}
    local found = findEscMenus()
    for _, menu in ipairs(found) do live[tostring(menu:GetAddress())] = true end
    for key, m in pairs(escMenus) do
        if not live[key] or not m.menu:IsValid() then
            pcall(function() ours[tostring(m.mailbox:GetAddress())] = nil end)
            escMenus[key] = nil
        end
    end
    for _, menu in ipairs(found) do
        if menu:IsValid() then
            local key = tostring(menu:GetAddress())
            local m = escMenus[key]
            if not m or not m.mailbox:IsValid() then
                local okb, list = pcall(escButtonBox, menu)
                local okc, b = false, nil
                if okb and list then okc, b = pcall(addEscButton, menu, list) end
                if okc and b then
                    m = { mailbox = b, menu = menu }
                    escMenus[key] = m
                    escAdds = escAdds + 1
                    if escAdds == 1 then
                        log("menu: Archipelago Mailbox button added to the Esc menu (" .. className(b) .. ") | " .. chainText(b))
                    end
                else
                    once("escadd", "menu: could not add the mailbox button: " .. tostring(b or list))
                end
            end
            if m then setText(m.mailbox, api.mailboxLabel()) end
        end
    end
end

-- Called from the mod's update loop (game thread).
function M.update()
    if not surveyed then
        local inWorld = false
        pcall(function() local pc = FindFirstOf("PalPlayerController"); inWorld = pc and pc:IsValid() and pc:K2_GetPawn() ~= nil end)
        local found = #(FindAllOf("WBP_TitleMenu_C") or {}) > 0
        if not inWorld and not added then titleTicks = titleTicks + 1 else titleTicks = 0 end
        if added then
            surveyed = true
        elseif (found and titleTicks >= 20) or titleTicks >= 100 then   -- the menu up 6 s without our buttons, or 30 s without it
            surveyed = true
            log(found and "menu: the title menu is here but its button list was not found; surveying"
                or "menu: the expected title menu (WBP_TitleMenu_C) is not on this title screen; surveying")
            local ok, err = pcall(survey)
            if not ok then log("menu survey error: " .. tostring(err)) end
        end
    end
    local inWorld = false
    pcall(function() local pc = FindFirstOf("PalPlayerController"); inWorld = pc and pc:IsValid() and pc:K2_GetPawn() ~= nil end)
    if inWorld and api.mailboxLabel then
        local oke, erre = pcall(updateEsc)
        if not oke then once("esc" .. tostring(erre), "menu: Esc menu error: " .. tostring(erre)) end
    end
    hookOnce(CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
    if inWorld then
        hookOnce(ESC_CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
    end
    hookOnce(WINDOW_OK, function() local ok, err = pcall(okPressed); if not ok then log("menu OK error: " .. tostring(err)) end end)
    for _, menu in ipairs(FindAllOf("WBP_TitleMenu_C") or {}) do
        local okb, list = pcall(buttonList, menu)
        if menu:IsValid() and okb and list then
            local key = tostring(menu:GetAddress())
            local m = menus[key]
            if not m or not m.connect:IsValid() then
                local okc, c = pcall(addButton, menu, list, "connect")
                local okd, d = pcall(addButton, menu, list, "disconnect")
                if okc and c and okd and d then
                    m = { connect = c, disconnect = d }
                    menus[key] = m
                    added = true
                    local okq, why = pcall(quitLast, menu, list)
                    if not okq or why then log("menu: Quit Game left where it was: " .. tostring(why)) end
                    pcall(logLayout, menu, c)
                    log("menu: Archipelago buttons added to the title menu (" .. className(list) .. " " .. nameOf(list) .. ")")
                else
                    once("menuadd", "menu: could not add the buttons: " .. tostring(c) .. " / " .. tostring(d))
                end
            end
            if m then
                setText(m.connect, label())
                setText(m.disconnect, "Disconnect from Archipelago")
                pcall(function() m.disconnect:SetVisibility(api.status() == "connected" and 0 or 1) end)  -- Visible / Collapsed
            end
        end
    end
    -- The Esc menu is one tab of the in-game main menu (WBP_InGameMainMenu_C): its own CloseAction (what backing out
    -- of it does) tells the main menu to close (v0.11.3 playtest: Close shut only the tab; the menu stayed behind the
    -- chest window). Then a look at whether the main menu really went.
    if closeEsc then
        local c = closeEsc
        closeEsc = nil
        local how = nil
        if c.menu and c.menu:IsValid() then
            if pcall(function() c.menu:CloseAction() end) then how = "CloseAction"
            elseif pcall(function() c.menu:Close() end) then how = "Close" end
        end
        if not how then
            pcall(function() StaticFindObject("/Script/Pal.Default__PalUtility"):GetHUDService(c.button):CloseOwnerStackableUI(c.button) end)
            how = "CloseOwnerStackableUI"
        end
        log("menu: Esc menu closed for the mailbox (" .. how .. ")")
        mainMenuLook = 2
        api.openMailbox(c.button)
    elseif mainMenuLook then
        mainMenuLook = mainMenuLook - 1
        if mainMenuLook == 0 then
            mainMenuLook = nil
            local up = 0
            for _, w in ipairs(FindAllOf("WBP_InGameMainMenu_C") or {}) do
                local ok, shown = pcall(function() return w:IsValid() and w:IsVisible() and w:IsInViewport() end)
                if ok and shown then up = up + 1 end
            end
            once("mainmenu" .. up, "menu: in-game main menu after closing: " .. (up == 0 and "gone" or (up .. " still shown")))
        end
    end
    -- The text-window chain: open the next window once the last one closed; a window closed without OK cancels.
    if asking then
        local open, w = false, nil
        pcall(function() w = asking.hud:GetWidget(asking.id); open = w and w:IsValid() end)
        -- The heading is bound to the game's text table ("World Name") and puts that back when the window rebuilds:
        -- set ours again while it is open (v0.10.2 playtest: every window still read "World Name").
        if open and asking.title and not asking.reopen then
            setHeading(w, asking.title)
            asking.headLogs = (asking.headLogs or 0) + 1
            if asking.headLogs <= 3 then                 -- does our heading stick? (diagnostic, first window ticks)
                local okt, t = pcall(function()
                    local h = w.Text_Head
                    return h.Text:ToString() .. " (row " .. h.BindTextDatatableHandle.RowName:ToString() .. ")"
                end)
                log("menu: window heading reads '" .. tostring(okt and t or ("? " .. tostring(t))) .. "'"
                    .. (hooked[WINDOW_OK] and "" or " (OK not hooked yet)"))
            end
        end
        if asking.reopen and not open then
            asking.reopen = false
            if asking.step > #STEPS then
                local v = asking.values
                asking = nil
                if v.server ~= "" and v.slot ~= "" then api.connect(v.server, v.slot, v.password) end
            else
                local ok, err = pcall(openWindow, asking.context)
                if not ok then log("menu: could not open the text window: " .. tostring(err)); asking = nil end
            end
        elseif not asking.reopen and not open then
            log("menu: cancelled")
            asking = nil
        end
    end
end

function M.install(functions) api = functions end

return M
