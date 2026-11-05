-- The title menu's Archipelago buttons: one shows the connection and, clicked, asks for the server, the slot and the
-- password in the game's own text window (the world-name window), then connects; a second disconnects while connected.
-- In a world, the Esc menu and the Inventory page each get an "Archipelago Mailbox" button (mailbox.lua).
-- Built from the game's own widgets: a WBP_Title_MenuButton added to the title menu's button list, a
-- WBP_MenuESC_Button_S (the Esc menu's own small button) in the Esc menu, and a WBP_CommonButton (the class of the
-- Inventory page's own Edit Name button) at the right end of that page's name bar, so they look and work like the
-- game's. The Inventory button is untested in game: it is placed from the dedicated server's pak (kdump, 2026-11-04).
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
-- The game's small labelled button (the Inventory page's Edit Name is one). Its click is component event 3; 4 and 5 are
-- hover and unhover, and all three end in CommonButtonBaseClicked (kdump: the class's ComponentDelegateBinding).
local COMMON_BUTTON = "/Game/Pal/Blueprint/UI/UserInterface/Common/WBP_CommonButton.WBP_CommonButton_C"
local COMMON_CLICK = COMMON_BUTTON .. ":BndEvt__WBP_CommonButton_WBP_PalInvisibleButton_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature"
local MAIN_MENU = "WBP_InGameMainMenu_C"
local INVENTORY_TAB = "WBP_InventoryEquipment_ForDisplay_C"
local NOTHING = "\1"           -- what the window's result holds until OK is pressed

local api                      -- status(), server(), slot(), password(), connect(server, slot, password), disconnect(),
                               -- mailboxLabel(), openMailbox(context)
local menus = {}               -- title menu address -> { connect = button, disconnect = button }
local escMenus = {}            -- Esc menu address -> { mailbox = button, menu = the Esc menu }
local invPages = {}            -- Inventory page address -> { mailbox = button, page = the page, main = its main menu }
local ours = {}                -- our button address -> "connect" | "disconnect" | "mailbox" | "inventory"
local closing = nil            -- a mailbox button was pressed: { from = "esc" | "inventory", menu or main, button },
                               -- handled on the next update
local mainMenuLook = nil       -- updates until the mod looks whether the main menu closed (a diagnostic)
local lookFrom = nil           -- the button that look follows: "esc" | "inventory"
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

-- The title banner (Art & Assets lane, round 1: art/ap-title-banner.png, 1200x300 shown at 600x150, the width of the
-- title buttons) above the title buttons, with the connection in its pill: a dot (art/ap-status-dot.png) tinted by
-- state and a line of text. Positions are the art's own (the pill spans x 140-575, y 107-133 at 600x150; the dot is
-- centred at 155,120 and the text starts at 167). v0.13.5 playtest: in the button list it went below Credits (the list
-- holds the game's buttons too) and pushed ours off the screen, and its picture kept the brush's 32x32. So it goes on
-- the canvas the list sits in (CanvasPanelMenu on the client), its bottom 8 above the list's top, and the picture
-- fills it. The list's top is worked out from its canvas slot each update (our Disconnect button changes its height).
-- Only when the list is not on a canvas (or is stretched across it) does the banner go in the list, after our buttons.
local ART = require("art")
local DOT = { connected = { R = 0.074, G = 0.631, B = 0.195, A = 1 },      -- #4DD07A, as linear colours
              connecting = { R = 0.839, G = 0.515, B = 0.155, A = 1 },     -- #ECBE6E
              other = { R = 0.863, G = 0.144, B = 0.105, A = 1 } }         -- #EF6A5B
local TEXT_COLOUR = { R = 0.807, G = 0.905, B = 0.888, A = 1 }            -- #E8F4F2
-- Where the banner goes on the list's canvas: centred over the list, its bottom 8 above the list's top. Errors when
-- the list's slot can't tell (no canvas slot, or anchors stretched across the canvas).
local function bannerSpot(list)
    local ls = list.Slot
    local a, al, pos = ls:GetAnchors(), ls:GetAlignment(), ls:GetPosition()
    if a.Minimum.X ~= a.Maximum.X or a.Minimum.Y ~= a.Maximum.Y then error("the button list is stretched on its canvas") end
    local size = list:GetDesiredSize()
    return { Minimum = { X = a.Minimum.X, Y = a.Minimum.Y }, Maximum = { X = a.Maximum.X, Y = a.Maximum.Y } },
        { X = pos.X + (0.5 - al.X) * size.X, Y = pos.Y - al.Y * size.Y - 8 }
end
local function placeBanner(b)
    if not b.slot then return end
    local anchors, at = bannerSpot(b.list)
    if b.at and b.at.X == at.X and b.at.Y == at.Y then return end
    b.slot:SetAnchors(anchors)
    b.slot:SetAlignment({ X = 0.5, Y = 1 })
    b.slot:SetPosition(at)
    b.at = at
end
local function addBanner(menu, list)
    local box, img = ART.box(menu, "ap-title-banner", 600, 150)
    if not box then return nil end
    local over = StaticConstructObject(StaticFindObject("/Script/UMG.Overlay"), menu)
    box:RemoveChild(img)
    box:AddChild(over)
    local s0 = over:AddChild(img)
    pcall(function() s0:SetHorizontalAlignment(0); s0:SetVerticalAlignment(0) end)   -- Fill, Fill: not the brush's 32x32
    local b = { box = box, list = list }
    local dotBox, dot = ART.box(menu, "ap-status-dot", 12, 12)
    if dotBox then
        local s = over:AddChild(dotBox)
        pcall(function() s:SetHorizontalAlignment(1); s:SetVerticalAlignment(1) end)   -- Left, Top
        pcall(function() s:SetPadding({ Left = 149, Top = 114, Right = 0, Bottom = 0 }) end)
        b.dot = dot
    end
    local text = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), menu)
    local sized = pcall(function() local f = text.Font; f.Size = 13; text:SetFont(f) end)
    if not sized then                                          -- the default font is 24: scale it down instead
        pcall(function() text:SetRenderTransformPivot({ X = 0, Y = 0.5 }); text:SetRenderScale({ X = 13 / 24, Y = 13 / 24 }) end)
    end
    pcall(function() text:SetColorAndOpacity({ SpecifiedColor = TEXT_COLOUR, ColorUseRule = 0 }) end)
    local s = over:AddChild(text)
    pcall(function() s:SetHorizontalAlignment(1); s:SetVerticalAlignment(1) end)
    pcall(function() s:SetPadding({ Left = 167, Top = 111, Right = 24, Bottom = 0 }) end)
    b.text = text
    local okp, canvas = pcall(function() return list:GetParent() end)
    local where
    if okp and canvas and canvas:IsValid() and className(canvas) == "CanvasPanel" then
        pcall(function() list:ForceLayoutPrepass() end)          -- our buttons just went in: the list's size with them
        local oks, why = pcall(bannerSpot, list)
        if oks then
            b.slot = canvas:AddChildToCanvas(box)
            pcall(function() b.slot:SetAutoSize(false); b.slot:SetSize({ X = 600, Y = 150 }) end)
            placeBanner(b)
            where = "on " .. nameOf(canvas) .. " at " .. math.floor(b.at.X + 0.5) .. "," .. math.floor(b.at.Y + 0.5)
                .. " (its bottom edge, centred over the buttons)"
        else
            where = "in the button list (" .. tostring(why):gsub("^.-:%d+: ", "") .. ")"
        end
    else
        where = "in the button list (it is not on a canvas)"
    end
    if not b.slot then
        local slot = list:AddChild(box)
        pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 8 }) end)
        pcall(function() slot:SetHorizontalAlignment(0) end)
    end
    log("menu: title banner added " .. where .. " (" .. (sized and "13 pt text" or "text scaled down")
        .. (b.dot and "" or ", no status dot") .. ")")
    return b
end
local function bannerStatus(b)
    local st, server = api.status(), api.server()
    local text = st == "connected" and ("Connected | " .. server .. " | Slot: " .. api.slot())
        or st == "connecting" and ("Connecting to " .. server .. "...")
        or (server ~= "" and ("Not connected | " .. server) or "Not connected")
    if b.slot then pcall(placeBanner, b) end
    if b.shown ~= text then b.shown = text; pcall(function() b.text:SetText(FText(text)) end) end
    if b.dot and b.state ~= st then b.state = st; pcall(function() b.dot:SetColorAndOpacity(DOT[st] or DOT.other) end) end
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
        closing = { from = "esc", menu = menu, button = button }
        return
    end
    if kind == "inventory" then
        -- The same for the Inventory page's button: only noted here; the main menu closes on the next update.
        local main
        for _, m in pairs(invPages) do if m.mailbox:IsValid() and m.mailbox:GetAddress() == button:GetAddress() then main = m.main end end
        closing = { from = "inventory", main = main, button = button }
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
-- Stops at nested user widgets, which have trees of their own, and below maxDepth (30 if not given).
local function eachWidget(w, fn, maxDepth)
    local okr, root = pcall(function() return w.WidgetTree.RootWidget end)
    if not okr or not root then return end
    local function walk(o, depth)
        if not o or not o:IsValid() or depth > (maxDepth or 30) then return end
        fn(o, depth)
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
-- Every update the main menu is up, so the button is there as the menu opens (v0.11.4 playtest: every 4th update
-- took about a second); a menu's tree is only walked when it is new, and the label only set when it changes. found is
-- the Esc menus up now (empty when no main menu is: then every entry is dropped).
local escAdds = 0
local function updateEsc(found)
    -- The game makes a new Esc menu each time it opens: forget the ones gone (v0.11.3 log: one per visit).
    local live = {}
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
            if m then
                local text = api.mailboxLabel()
                if m.label ~= text then m.label = text; setText(m.mailbox, text) end
            end
        end
    end
end

-- The Inventory page: the main menu's Inventory tab. All of this is read from the dedicated server's pak (kdump,
-- 2026-11-04) and untested in game. The menu makes a new WBP_InventoryEquipment_ForDisplay_C each time the tab is
-- picked (SelectInventoryEquipmentTab) and keeps it in CurrentContentWidget; the page itself is its
-- WBP_InventoryEquipment. Never FindAllOf("WBP_InventoryEquipment_C"): the page is a designer child of that wrapper,
-- so the wrapper's template has one with no "Default__" in its name (the WBP_Map_Body_C trap). A tab the menu let go
-- stays valid until collected, so only a menu's current one counts. No fallback by the wrapper's class: the client's
-- main menu is WBP_InGameMainMenu_C (2026-11-03 log, "in-world widget class WBP_InGameMainMenu_C" as it opened).
local function notDefault(o)
    local okd, full = pcall(function() return o:GetFullName() end)
    return o:IsValid() and not (okd and tostring(full):find("Default__", 1, true))
end
local pageLogged = false
local function inventoryPages(mains)
    local out = {}
    for _, mm in ipairs(mains) do
        local ok, page, tabClass, why = pcall(function()
            local tab = mm.CurrentContentWidget
            if not tab or not tab:IsValid() then return nil, "nothing" end
            local cn = className(tab)
            if cn ~= INVENTORY_TAB then return nil, cn end
            local p = tab.WBP_InventoryEquipment
            if p and p:IsValid() then return p, cn end
            return nil, cn, "has no valid WBP_InventoryEquipment"
        end)
        local okt, tabType = pcall(function() return mm.CurrentTabType end)
        tabType = tostring(okt and tabType or "?")
        -- Which tab widgets the client's main menu shows, once each, so a missing button has a reason in the log.
        if not ok then
            once("mmerr", "menu: could not read the main menu's tab: " .. tostring(page))
        else
            once("mmtab" .. tabClass, "menu: main menu content is " .. tabClass .. " (tab " .. tabType .. ")")
            if why then once("invnopage", "menu: the main menu's " .. tabClass .. " " .. why .. "; no mailbox button there") end
        end
        if ok and page then
            out[#out + 1] = { page = page, main = mm }
            if not pageLogged then
                pageLogged = true
                log("menu: the inventory page is " .. className(page) .. " (via the main menu's CurrentContentWidget, tab " .. tabType .. ")")
            end
        end
    end
    return out
end

-- The page's name bar (CanvasPanelChara > Overlay_0, 996x32; kdump). Its row (HorizontalBox_0) holds the game's Edit
-- Name button in SizeBox_NameEdit, then the player's name, both on the left: the bar's right end is empty. The bar is
-- not a variable of the page, so it is reached from the row's widgets. Returns the bar, or nil and why.
local NAME_BAR_FROM = { "SizeBox_NameEdit", "Text_CharacterName" }
local function nameBar(page)
    local why = {}
    for _, field in ipairs(NAME_BAR_FROM) do
        local ok, bar, miss = pcall(function()
            local w = page[field]
            if not w or not w:IsValid() then return nil, "no " .. field end
            local row = w:GetParent()
            if not row or not row:IsValid() or className(row) ~= "HorizontalBox" then
                return nil, field .. " is in " .. (row and className(row) or "nothing")
            end
            local b = row:GetParent()
            if not b or not b:IsValid() or className(b) ~= "Overlay" then
                return nil, field .. "'s row is in " .. (b and className(b) or "nothing")
            end
            return b
        end)
        if ok and bar then return bar end
        why[#why + 1] = ok and tostring(miss) or tostring(bar)
    end
    return nil, table.concat(why, "; ")
end

-- The game's own small button, 230x28 (28 is Edit Name's height; its label is at most 216 wide and scales itself down
-- to fit), at the right end of the bar. An Overlay slot starts at Left/Top: Right, and Fill as the Edit Name row is.
-- The page binds only its own Edit Name's OnClicked, so ours stays unbound and only our hook answers it.
local function addInventoryButton(page, bar)
    local class = find(COMMON_BUTTON)
    local sizeClass = StaticFindObject("/Script/UMG.SizeBox")
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not class or not sizeClass or not wbl then return nil, "no " .. (class and (sizeClass and "WidgetBlueprintLibrary" or "SizeBox") or "WBP_CommonButton_C") end
    local button = wbl:Create(page, class, nil)
    if not button or not button:IsValid() then return nil, "the button was not made" end
    local box = StaticConstructObject(sizeClass, page)
    box:SetWidthOverride(230)
    box:SetHeightOverride(28)
    box:AddChild(button)
    local slot = bar:AddChild(box)
    pcall(function() slot:SetHorizontalAlignment(3) end)      -- HAlign_Right
    pcall(function() slot:SetVerticalAlignment(0) end)        -- VAlign_Fill
    -- The mailbox emblem (art/ap-mailbox-emblem-64.png) just left of the button, 24 high.
    local okE, emblem = pcall(ART.box, page, "ap-mailbox-emblem-64", 24, 24)
    if okE and emblem then
        local es = bar:AddChild(emblem)
        pcall(function() es:SetHorizontalAlignment(3); es:SetVerticalAlignment(2) end)   -- Right, Center
        pcall(function() es:SetPadding({ Left = 0, Top = 0, Right = 236, Bottom = 0 }) end)
    end
    ours[tostring(button:GetAddress())] = "inventory"
    return button
end

-- Does a game button have focus? Its inner WBP_PalInvisibleButton is what takes it (the class's GetFocusTarget).
local function focused(button)
    local ok, yes = pcall(function()
        local inner = button.WBP_PalInvisibleButton
        return inner and inner:IsValid() and (inner:HasAnyUserFocus() or inner:HasFocusedDescendants())
    end)
    return ok and yes == true
end
local INPUT_TYPES = { [0] = "mouse and keyboard", [1] = "gamepad", [2] = "touch" }   -- ECommonInputType
local function inputType()
    for _, s in ipairs(FindAllOf("CommonInputSubsystem") or {}) do
        local ok, t = pcall(function() return notDefault(s) and s:GetCurrentInputType() or nil end)
        if ok and t ~= nil then return tostring(t) .. " " .. (INPUT_TYPES[tonumber(t)] or "?") end
    end
    return "unknown"
end

-- Every update, as the Esc menu: a page is new each visit, so key by its address and forget the ones gone. found is
-- the pages up now (empty when no main menu is).
local invAdds = 0
local invFailed = {}           -- page addresses where adding the button failed
local focusLogged = {}
local function updateInventory(found)
    local live = {}
    for _, e in ipairs(found) do live[tostring(e.page:GetAddress())] = true end
    for key, m in pairs(invPages) do
        if not live[key] or not m.page:IsValid() then
            pcall(function() ours[tostring(m.mailbox:GetAddress())] = nil end)
            invPages[key] = nil
        end
    end
    for key in pairs(invFailed) do if not live[key] then invFailed[key] = nil end end   -- a later page may reuse the address
    for _, e in ipairs(found) do
        local key = tostring(e.page:GetAddress())
        local m = invPages[key]
        if (not m or not m.mailbox:IsValid()) and not invFailed[key] then
            local bar, why = nameBar(e.page)
            if bar then
                local okc, b, err = pcall(addInventoryButton, e.page, bar)
                if okc and b then
                    m = { mailbox = b, page = e.page }
                    invPages[key] = m
                    invAdds = invAdds + 1
                    if invAdds == 1 then
                        log("menu: Archipelago Mailbox button added to the inventory page (" .. className(b) .. ") | " .. chainText(b))
                    end
                else
                    invFailed[key] = true                      -- not again for this page: each try makes a widget
                    once("invadd", "menu: could not add the inventory mailbox button: " .. tostring(okc and err or b))
                end
            elseif not reported["invnobar"] then
                once("invnobar", "menu: the inventory page has no name bar (" .. tostring(why) .. "); no mailbox button there (the Esc menu has one)")
                local parts = {}
                pcall(eachWidget, e.page, function(o, depth)
                    if #parts < 120 then parts[#parts + 1] = depth .. ":" .. nameOf(o) .. ":" .. className(o) end
                end, 4)
                log("menu survey: inventory page | " .. table.concat(parts, ", "))
            end
        end
        if m then
            m.main = e.main                                    -- kept fresh: the close goes to the menu showing it
            local text = api.mailboxLabel()
            if m.label ~= text then m.label = text; setText(m.mailbox, text) end
            -- Can a controller reach it? A mouse click focuses too, so the input type tells them apart (untested).
            if not focusLogged.ours and focused(m.mailbox) then
                focusLogged.ours = true
                log("menu: the inventory mailbox button has focus (input " .. inputType() .. ")")
            end
            if not focusLogged.edit then
                local oke, edit = pcall(function() return e.page.WBP_CommonButton_NameEdit end)
                if oke and edit and focused(edit) then
                    focusLogged.edit = true
                    log("menu: the game's Edit Name button has focus (input " .. inputType() .. ")")
                end
            end
        end
    end
end

-- One object scan per update while the main menu is closed (UE4SS's FindAllOf walks the whole object array, and the
-- 2026-11-03 FPS drop is still unexplained): look for WBP_InGameMainMenu_C, and only while one is up for the Esc menu
-- (it shows as the main menu's Options tab) and the Inventory page (its CurrentContentWidget, no scan of its own).
-- Until a main menu was ever seen, the Esc menu is also looked for by its class every 4th update, in case the client
-- names the main menu differently: the Esc button would then come up to a second late, not never.
local mainMenuSeen, fallbackTicks = false, 0
local function menusUp()
    local mains = {}
    for _, mm in ipairs(FindAllOf(MAIN_MENU) or {}) do
        if notDefault(mm) then mains[#mains + 1] = mm end
    end
    if mains[1] then mainMenuSeen = true end
    local esc = {}                                         -- nil: not looked this update, keep what we have
    if mains[1] then
        esc = findEscMenus()
    elseif not mainMenuSeen then
        fallbackTicks = fallbackTicks + 1
        if fallbackTicks % 4 == 1 then
            esc = findEscMenus()
            if esc[1] then once("escnomain", "menu: the Esc menu is up but no " .. MAIN_MENU .. " was found (looking by its class every 4th update)") end
        else
            esc = nil
        end
    end
    return esc, inventoryPages(mains)
end

-- The title menu is looked for every update at the title, but in a world (the player's pawn there) only every 10th
-- update: 6dd356e walked the object array for it every update in a world, where it never is (an estimated 2-15 ms a
-- walk, unmeasured). If one is ever found in a world all the same, the in-world test is wrong for this game: it is
-- logged and the menu is looked for every update again.
local titleLooks, titleInWorld = 0, false
local function titleMenus(ctx, inWorld)
    titleLooks = titleLooks + 1
    if ctx and ctx.pawn and not titleInWorld and titleLooks % 10 ~= 0 then return nil end   -- not looked this update
    local found = FindAllOf("WBP_TitleMenu_C") or {}
    if ctx and ctx.pawn and #found > 0 and not titleInWorld then
        titleInWorld = true
        log("menu: a title menu was found with the player's pawn in a world; looking for it every update again")
    end
    return found
end

-- Called from the mod's update loop (game thread). ctx: this update's player (main.lua): ctx.pc, the first live
-- controller, as FindFirstOf("PalPlayerController") found it; ctx.hasPawn, what its K2_GetPawn gave (an object).
function M.update(ctx)
    -- In a world: a live controller whose pawn lookup answered (6dd356e's test, now from the shared lookup).
    local inWorld = false
    if ctx then
        inWorld = ctx.pc ~= nil and ctx.hasPawn == true
    else
        pcall(function() local pc = FindFirstOf("PalPlayerController"); inWorld = pc and pc:IsValid() and pc:K2_GetPawn() ~= nil end)
    end
    local titles = titleMenus(ctx, inWorld)            -- one lookup for both uses below (nil: not looked this update)
    if not surveyed then
        local found = titles ~= nil and #titles > 0
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
    if api.mailboxLabel then
        local escFound, invFound = {}, {}
        if inWorld then
            local okf, err = pcall(function() escFound, invFound = menusUp() end)
            if not okf then once("mm" .. tostring(err), "menu: main menu error: " .. tostring(err)) end
        else
            -- Out of a world, nothing of ours is up: drop it all (below, with nothing found), so a stale address can't
            -- match a new button at the title (the WBP_CommonButton click hook stays and fires there too).
            closing = nil
        end
        if escFound then
            local oke, erre = pcall(updateEsc, escFound)
            if not oke then once("esc" .. tostring(erre), "menu: Esc menu error: " .. tostring(erre)) end
        end
        local oki, erri = pcall(updateInventory, invFound)
        if not oki then once("inv" .. tostring(erri), "menu: inventory page error: " .. tostring(erri)) end
    end
    hookOnce(CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
    if inWorld then
        hookOnce(ESC_CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
        -- Fires for every WBP_CommonButton_C in the game (dialogs, Edit Name, Quick Stack); clicked() ignores all but ours.
        hookOnce(COMMON_CLICK, function(self) local ok, err = pcall(clicked, self:get()); if not ok then log("menu click error: " .. tostring(err)) end end)
    end
    hookOnce(WINDOW_OK, function() local ok, err = pcall(okPressed); if not ok then log("menu OK error: " .. tostring(err)) end end)
    -- Title menus gone (into a world) or rebuilt: forget them and their buttons' addresses, as with the Esc menu. A
    -- game title button made later at a freed address of ours would otherwise connect or disconnect when clicked. Only
    -- on an update that looked for them: one that did not (in a world, 9 in 10) knows nothing about them, and forgetting
    -- a menu still there would add its buttons a second time when it is next seen.
    if titles then
        local live = {}
        for _, menu in ipairs(titles) do pcall(function() live[tostring(menu:GetAddress())] = menu:IsValid() end) end
        for key, m in pairs(menus) do
            local okv, valid = pcall(function() return m.connect:IsValid() and m.disconnect:IsValid() end)
            if not live[key] or not (okv and valid) then
                for _, k in ipairs(m.keys) do ours[k] = nil end
                menus[key] = nil
            end
        end
    end
    for _, menu in ipairs(titles or {}) do
        local okb, list = pcall(buttonList, menu)
        if menu:IsValid() and okb and list then
            local key = tostring(menu:GetAddress())
            local m = menus[key]
            if not m or not m.connect:IsValid() then
                local okc, c = pcall(addButton, menu, list, "connect")
                local okd, d = pcall(addButton, menu, list, "disconnect")
                if okc and c and okd and d then
                    m = { connect = c, disconnect = d, keys = { tostring(c:GetAddress()), tostring(d:GetAddress()) } }
                    menus[key] = m
                    added = true
                    -- After the buttons, once they are in (v0.13.5 playtest: before them, a menu whose buttons failed
                    -- got a new banner every update, 1,042 in five minutes).
                    local okB, banner = pcall(addBanner, menu, list)
                    if okB then m.banner = banner else log("menu: title banner error: " .. tostring(banner)) end
                    local okq, why = pcall(quitLast, menu, list)
                    if not okq or why then log("menu: Quit Game left where it was: " .. tostring(why)) end
                    pcall(logLayout, menu, c)
                    log("menu: Archipelago buttons added to the title menu (" .. className(list) .. " " .. nameOf(list) .. ")")
                else
                    once("menuadd", "menu: could not add the buttons: " .. tostring(c) .. " / " .. tostring(d))
                end
            end
            if m then
                if m.banner then pcall(bannerStatus, m.banner) end
                setText(m.connect, label())
                setText(m.disconnect, "Disconnect from Archipelago")
                pcall(function() m.disconnect:SetVisibility(api.status() == "connected" and 0 or 1) end)  -- Visible / Collapsed
            end
        end
    end
    -- The Esc menu is one tab of the in-game main menu (WBP_InGameMainMenu_C): its own CloseAction (what backing out
    -- of it does) tells the main menu to close (v0.11.3 playtest: Close shut only the tab; the menu stayed behind the
    -- chest window). Then a look at whether the main menu really went.
    -- From the Inventory page, Close() on the main menu itself: what its X button, the Inventory tab's cancel and
    -- OnTryClose_Inventory all call (kdump bytecode; untested from Lua on this class). Not OnCancelAction: during a
    -- status-point edit it cancels the edit and leaves the menu open.
    if closing then
        local c = closing
        closing = nil
        local how = nil
        if c.from == "inventory" then
            if c.main and c.main:IsValid() and pcall(function() c.main:Close() end) then how = "Close" end
        elseif c.menu and c.menu:IsValid() then
            if pcall(function() c.menu:CloseAction() end) then how = "CloseAction"
            elseif pcall(function() c.menu:Close() end) then how = "Close" end
        end
        if not how then
            pcall(function() StaticFindObject("/Script/Pal.Default__PalUtility"):GetHUDService(c.button):CloseOwnerStackableUI(c.button) end)
            how = "CloseOwnerStackableUI"
        end
        log(c.from == "inventory" and ("menu: main menu closed for the mailbox from the inventory (" .. how .. ")")
            or ("menu: Esc menu closed for the mailbox (" .. how .. ")"))
        mainMenuLook, lookFrom = 2, c.from
        api.openMailbox(c.button)
    elseif mainMenuLook then
        mainMenuLook = mainMenuLook - 1
        if mainMenuLook == 0 then
            mainMenuLook = nil
            local up = 0
            for _, w in ipairs(FindAllOf(MAIN_MENU) or {}) do
                local ok, shown = pcall(function() return w:IsValid() and w:IsVisible() and w:IsInViewport() end)
                if ok and shown then up = up + 1 end
            end
            local from = lookFrom == "inventory" and " from the inventory" or ""
            once("mainmenu" .. from .. up, "menu: in-game main menu after closing" .. from .. ": " .. (up == 0 and "gone" or (up .. " still shown")))
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
